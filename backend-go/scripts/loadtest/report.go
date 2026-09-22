package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"time"
)

// Gate is one published target from the plan, checked rather than described.
// A scenario that cannot check a target does not silently pass it: it records
// the gate as unmet with the reason.
type Gate struct {
	Name   string `json:"name"`
	Passed bool   `json:"passed"`
	Detail string `json:"detail"`
}

type Result struct {
	Scenario    string            `json:"scenario"`
	StartedAt   time.Time         `json:"started_at"`
	Duration    string            `json:"duration"`
	Parameters  map[string]any    `json:"parameters"`
	Measured    map[string]any    `json:"measured"`
	Gates       []Gate            `json:"gates"`
	TopBefore   []Statement       `json:"pg_stat_statements_before,omitempty"`
	TopAfter    []Statement       `json:"pg_stat_statements_after,omitempty"`
	TableStats  []TableStat       `json:"table_stats,omitempty"`
	Notes       []string          `json:"notes,omitempty"`
	Environment map[string]string `json:"environment"`
}

func newResult(scenario string, parameters map[string]any) *Result {
	return &Result{
		Scenario: scenario, StartedAt: time.Now(),
		Parameters: parameters, Measured: map[string]any{},
		Environment: map[string]string{},
	}
}

func (r *Result) gate(name string, passed bool, format string, args ...any) {
	r.Gates = append(r.Gates, Gate{Name: name, Passed: passed, Detail: fmt.Sprintf(format, args...)})
}

func (r *Result) note(format string, args ...any) {
	r.Notes = append(r.Notes, fmt.Sprintf(format, args...))
}

func (r *Result) failed() bool {
	for _, g := range r.Gates {
		if !g.Passed {
			return true
		}
	}
	return false
}

// record folds a driver run into the result under one prefix, so a scenario
// that runs two phases keeps them apart.
func (r *Result) record(prefix string, run Run) {
	set := func(key string, value any) { r.Measured[prefix+"_"+key] = value }
	set("requests", run.Completed)
	set("dropped", run.Dropped)
	set("failed", run.Failed)
	set("non_200", run.NonOK())
	set("throughput_rps", round(run.Throughput(), 1))
	set("peak_rps", run.PeakPerSecond())
	set("mean_ms", round(msOf(run.Mean()), 3))
	set("p50_ms", round(msOf(run.Percentile(50)), 3))
	set("p95_ms", round(msOf(run.Percentile(95)), 3))
	set("p99_ms", round(msOf(run.Percentile(99)), 3))
	set("max_ms", round(msOf(run.Percentile(100)), 3))
	set("elapsed_s", round(run.Elapsed.Seconds(), 2))
	if run.Accepted > 0 || run.Rejected > 0 {
		set("rows_accepted", run.Accepted)
		set("rows_rejected", run.Rejected)
	}
	if len(run.Statuses) > 0 {
		statuses := map[string]int64{}
		for status, count := range run.Statuses {
			statuses[fmt.Sprint(status)] = count
		}
		set("statuses", statuses)
	}
	if len(run.Codes) > 0 {
		set("rejection_codes", run.Codes)
	}
	if len(run.Errors) > 0 {
		set("errors", run.Errors)
	}
}

func (r *Result) print() {
	fmt.Printf("\n=== %s ===\n", r.Scenario)
	printMap("parameters", toAnyMap(r.Parameters))
	printMap("measured", r.Measured)

	if len(r.TopAfter) > 0 {
		fmt.Println("\ntop statements by total execution time (after the run):")
		printStatements(r.TopAfter)
	}
	if len(r.TopBefore) > 0 {
		fmt.Println("\ntop statements before the run (same window, for comparison):")
		printStatements(r.TopBefore)
	}
	if len(r.TableStats) > 0 {
		fmt.Println("\nautovacuum and size, per relation:")
		for _, t := range r.TableStats {
			vacuumed := "never"
			if t.LastAutovacuum != nil {
				vacuumed = t.LastAutovacuum.Format(time.RFC3339)
			}
			fmt.Printf("  %-34s live=%-12d dead=%-10d dead/live=%.3f autovacuum=%s (%d runs) size=%s\n",
				t.Relation, t.LiveTuples, t.DeadTuples, t.DeadRatio(), vacuumed, t.AutovacuumRuns, humanBytes(t.TotalBytes))
		}
	}
	for _, note := range r.Notes {
		fmt.Println("\nNOTE:", note)
	}

	fmt.Println()
	for _, g := range r.Gates {
		mark := "PASS"
		if !g.Passed {
			mark = "FAIL"
		}
		fmt.Printf("%s %-46s %s\n", mark, g.Name, g.Detail)
	}
}

func printStatements(statements []Statement) {
	for _, s := range statements {
		query := s.Query
		if len(query) > 110 {
			query = query[:110] + "…"
		}
		fmt.Printf("  calls=%-9d total=%-11.1fms mean=%-8.3fms rows/call=%-8.2f read_blks=%-9d %s\n",
			s.Calls, s.TotalMS, s.MeanMS, s.RowsPerCall(), s.SharedRead, query)
	}
}

func printMap(title string, values map[string]any) {
	if len(values) == 0 {
		return
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	fmt.Printf("%s:\n", title)
	for _, key := range keys {
		fmt.Printf("  %-28s %v\n", key, values[key])
	}
}

func toAnyMap(in map[string]any) map[string]any { return in }

func (r *Result) writeJSON(path string) error {
	if path == "" {
		return nil
	}
	r.Duration = time.Since(r.StartedAt).Round(time.Millisecond).String()
	raw, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, raw, 0o600)
}

func msOf(d time.Duration) float64 { return float64(d) / float64(time.Millisecond) }

func round(value float64, places int) float64 {
	scale := 1.0
	for range places {
		scale *= 10
	}
	return float64(int64(value*scale+0.5)) / scale
}

func humanBytes(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(bytes)/float64(div), "KMGTPE"[exp])
}
