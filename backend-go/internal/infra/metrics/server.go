package metrics

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
)

// Serve publishes /metrics on its own listener, separate from the application's.
//
// Its own port, never a route on the public server: this is an operator
// surface, and a route on :9000 would be one Caddy rule away from being
// readable by anyone. The port is not published by Compose; Prometheus reaches
// it on the internal network by service name.
//
// The returned function shuts the listener down; an empty addr disables
// publishing entirely and returns a no-op.
func Serve(addr string, m *Metrics, logger *slog.Logger) (func(context.Context) error, error) {
	if addr == "" || m == nil {
		return func(context.Context) error { return nil }, nil
	}

	mux := http.NewServeMux()
	mux.Handle("/metrics", m.Handler())
	// A liveness probe that needs no database, so a metrics scrape failing and
	// the process being dead stay distinguishable.
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})

	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		logger.Info("metrics listening", slog.String("addr", addr))
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			// Never fatal: losing the dashboard must not take the service with it.
			logger.Error("metrics listener stopped", slog.Any("error", err))
		}
	}()

	return srv.Shutdown, nil
}

// PoolCollector reports one pgxpool's saturation.
//
// The number that matters here is acquire wait: a pool whose connections are
// all busy does not fail, it queues, and the queue is invisible in every other
// metric — the request latency rises with no query being slow.
type PoolCollector struct {
	pools map[string]*pgxpool.Pool

	conns       *prometheus.Desc
	maxConns    *prometheus.Desc
	acquires    *prometheus.Desc
	emptyWaits  *prometheus.Desc
	cancelled   *prometheus.Desc
	waitSeconds *prometheus.Desc
}

func NewPoolCollector(pools map[string]*pgxpool.Pool) *PoolCollector {
	label := []string{"pool"}
	return &PoolCollector{
		pools:       pools,
		conns:       prometheus.NewDesc(namespace+"_pgxpool_connections", "Connections held by this pool, by state.", []string{"pool", "state"}, nil),
		maxConns:    prometheus.NewDesc(namespace+"_pgxpool_max_connections", "Configured ceiling for this pool.", label, nil),
		acquires:    prometheus.NewDesc(namespace+"_pgxpool_acquires_total", "Connection acquisitions.", label, nil),
		emptyWaits:  prometheus.NewDesc(namespace+"_pgxpool_empty_acquires_total", "Acquisitions that had to wait for a free connection.", label, nil),
		cancelled:   prometheus.NewDesc(namespace+"_pgxpool_canceled_acquires_total", "Acquisitions abandoned before a connection was free.", label, nil),
		waitSeconds: prometheus.NewDesc(namespace+"_pgxpool_acquire_wait_seconds_total", "Total time spent waiting for a connection.", label, nil),
	}
}

func (c *PoolCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.conns
	ch <- c.maxConns
	ch <- c.acquires
	ch <- c.emptyWaits
	ch <- c.cancelled
	ch <- c.waitSeconds
}

func (c *PoolCollector) Collect(ch chan<- prometheus.Metric) {
	for name, pool := range c.pools {
		if pool == nil {
			continue
		}
		stat := pool.Stat()
		ch <- prometheus.MustNewConstMetric(c.conns, prometheus.GaugeValue, float64(stat.AcquiredConns()), name, "acquired")
		ch <- prometheus.MustNewConstMetric(c.conns, prometheus.GaugeValue, float64(stat.IdleConns()), name, "idle")
		ch <- prometheus.MustNewConstMetric(c.conns, prometheus.GaugeValue, float64(stat.ConstructingConns()), name, "constructing")
		ch <- prometheus.MustNewConstMetric(c.maxConns, prometheus.GaugeValue, float64(stat.MaxConns()), name)
		ch <- prometheus.MustNewConstMetric(c.acquires, prometheus.CounterValue, float64(stat.AcquireCount()), name)
		ch <- prometheus.MustNewConstMetric(c.emptyWaits, prometheus.CounterValue, float64(stat.EmptyAcquireCount()), name)
		ch <- prometheus.MustNewConstMetric(c.cancelled, prometheus.CounterValue, float64(stat.CanceledAcquireCount()), name)
		ch <- prometheus.MustNewConstMetric(c.waitSeconds, prometheus.CounterValue, stat.AcquireDuration().Seconds(), name)
	}
}
