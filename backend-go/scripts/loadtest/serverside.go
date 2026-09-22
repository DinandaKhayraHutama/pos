package main

import (
	"bufio"
	"context"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// serverSide is what the SERVER thought the same requests cost.
//
// The harness measures from outside: its number includes connection reuse, the
// generator's own scheduling, and whatever else sits between the two
// processes. The server's histogram measures from the first middleware to the
// last byte written. Reporting both is what makes "the server is slow" and
// "the generator could not keep up" different findings instead of one
// argument.
type serverSide struct {
	Route  string  `json:"route"`
	Count  float64 `json:"requests"`
	MeanMS float64 `json:"mean_ms"`
}

// authCache is where the bindings came from while a run was happening.
//
// It answers a question latency alone cannot: a phase that is slower than a
// busier one is usually not overloaded, it is cold. Entries live five minutes,
// so any till that speaks less often than that pays the full device chain
// read every time — and a morning spread over six minutes is exactly that
// shape.
type authCache struct {
	Hit   float64 `json:"hit"`
	Miss  float64 `json:"miss"`
	Stale float64 `json:"stale"`
	Error float64 `json:"error"`
}

func (a authCache) total() float64 { return a.Hit + a.Miss + a.Stale + a.Error }

func (a authCache) hitRatio() float64 {
	if a.total() == 0 {
		return 0
	}
	return a.Hit / a.total()
}

func (a authCache) minus(before authCache) authCache {
	return authCache{
		Hit: a.Hit - before.Hit, Miss: a.Miss - before.Miss,
		Stale: a.Stale - before.Stale, Error: a.Error - before.Error,
	}
}

func readAuthCache(ctx context.Context, metricsURL string) (authCache, error) {
	lines, err := readMetrics(ctx, metricsURL)
	if err != nil {
		return authCache{}, err
	}
	var out authCache
	for _, line := range lines {
		if !strings.HasPrefix(line, "justclick_device_auth_cache_total{") {
			continue
		}
		switch {
		case strings.Contains(line, `result="hit"`):
			out.Hit += valueOf(line)
		case strings.Contains(line, `result="miss"`):
			out.Miss += valueOf(line)
		case strings.Contains(line, `result="stale"`):
			out.Stale += valueOf(line)
		case strings.Contains(line, `result="error"`):
			out.Error += valueOf(line)
		}
	}
	return out, nil
}

// readRouteLatency takes a snapshot of one route's histogram sum and count.
// Both are counters, so a run's own cost is the difference between two reads.
func readRouteLatency(ctx context.Context, metricsURL, route string) (sum, count float64, err error) {
	lines, err := readMetrics(ctx, metricsURL)
	if err != nil {
		return 0, 0, err
	}

	needle := `route="` + route + `"`
	for _, line := range lines {
		if !strings.Contains(line, needle) {
			continue
		}
		switch {
		case strings.HasPrefix(line, "justclick_http_request_duration_seconds_sum"):
			sum += valueOf(line)
		case strings.HasPrefix(line, "justclick_http_request_duration_seconds_count"):
			count += valueOf(line)
		}
	}
	return sum, count, nil
}

// readMetrics fetches the exposition text and hands back its lines. Parsing is
// deliberately this crude: the harness reads a handful of counters it wrote
// itself, and a Prometheus parser here would be a dependency for nothing.
func readMetrics(ctx context.Context, metricsURL string) ([]string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, metricsURL, nil)
	if err != nil {
		return nil, err
	}
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("metrics: HTTP %d", resp.StatusCode)
	}

	var lines []string
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "#") {
			continue
		}
		lines = append(lines, line)
	}
	return lines, scanner.Err()
}

func valueOf(line string) float64 {
	idx := strings.LastIndexByte(line, ' ')
	if idx < 0 {
		return 0
	}
	value, err := strconv.ParseFloat(strings.TrimSpace(line[idx+1:]), 64)
	if err != nil {
		return 0
	}
	return value
}

// measureServerSide brackets a run with two reads of the server's own
// histogram. An unreachable /metrics is not an error: the harness can drive a
// server that publishes none, it just cannot then say where the time went.
func measureServerSide(ctx context.Context, metricsURL, route string, run func()) (*serverSide, error) {
	beforeSum, beforeCount, err := readRouteLatency(ctx, metricsURL, route)
	if err != nil {
		run()
		return nil, err
	}

	run()

	afterSum, afterCount, err := readRouteLatency(ctx, metricsURL, route)
	if err != nil {
		return nil, err
	}

	count := afterCount - beforeCount
	if count <= 0 {
		return nil, fmt.Errorf("the server recorded no requests on %s", route)
	}
	return &serverSide{
		Route: route, Count: count,
		MeanMS: round((afterSum-beforeSum)/count*1000, 3),
	}, nil
}

// recordServerSide folds a server-side measurement into the result, saying so
// plainly when the server published none.
func (r *Result) recordServerSide(prefix string, measurement *serverSide, err error) {
	if err != nil || measurement == nil {
		r.note("server-side latency was not read (%v); every latency below is measured from the generator", err)
		return
	}
	r.Measured[prefix+"_server_mean_ms"] = measurement.MeanMS
	r.Measured[prefix+"_server_requests"] = measurement.Count
}

// bracketAuthCache reports where the bindings came from during one phase.
// Failure to read is recorded, never fatal: a server without /metrics can
// still be load tested, it just cannot explain itself.
func (r *Result) bracketAuthCache(ctx context.Context, metricsURL, prefix string, phase func()) {
	before, err := readAuthCache(ctx, metricsURL)
	if err != nil {
		phase()
		r.note("device auth cache counters were not read (%v)", err)
		return
	}
	phase()
	after, err := readAuthCache(ctx, metricsURL)
	if err != nil {
		r.note("device auth cache counters were not read after the run (%v)", err)
		return
	}
	delta := after.minus(before)
	if delta.total() == 0 {
		return
	}
	r.Measured[prefix+"_auth_cache_hits"] = delta.Hit
	r.Measured[prefix+"_auth_cache_misses"] = delta.Miss + delta.Stale + delta.Error
	r.Measured[prefix+"_auth_cache_hit_ratio"] = round(delta.hitRatio(), 4)
}
