// Package metrics publishes the numbers an incident is diagnosed from.
//
// The list is deliberately short. Two of these are the ones that would catch a
// money bug while it is happening rather than in tomorrow's reconciliation:
//
//   - push_rows_total{status,code} — a rejection rate that climbs is a client
//     bug throwing away sales, and per-code is what names which one;
//   - http_request_duration_seconds{route} — /sync/changes is polled by the
//     whole fleet, so its p99 is the fleet's experience of the server.
//
// Everything is registered on a private registry, never the default one: a
// dependency that quietly registers a collector cannot then appear on our
// /metrics, and a test can assert the exact output of a fresh instance.
//
// A nil *Metrics is usable and does nothing, so a test or a command that has no
// interest in instrumentation passes nil rather than wiring a registry.
package metrics

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const namespace = "justclick"

type Metrics struct {
	reg          *prometheus.Registry
	httpDuration *prometheus.HistogramVec
	httpRequests *prometheus.CounterVec
	pushRows     *prometheus.CounterVec
	pullRows     *prometheus.CounterVec
	authCache    *prometheus.CounterVec
}

// New builds the registry this process publishes.
func New() *Metrics {
	m := &Metrics{
		reg: prometheus.NewRegistry(),
		httpDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Namespace: namespace, Name: "http_request_duration_seconds",
			Help: "Request latency by routing pattern.",
			// Bucketed for this system's two very different shapes: a warm
			// /sync/changes answered from Redis in about a millisecond, and a
			// push that writes a receipt in tens to hundreds of them. The
			// 0.02 and 0.3 edges are the two published gates, so the p99
			// panels read against a real bucket boundary rather than an
			// interpolation between neighbours.
			Buckets: []float64{0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2, 5},
		}, []string{"surface", "route", "method"}),
		httpRequests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: namespace, Name: "http_requests_total",
			Help: "Requests by routing pattern and response status.",
		}, []string{"surface", "route", "method", "status"}),
		pushRows: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: namespace, Name: "push_rows_total",
			Help: "Pushed rows by entity, per-row outcome and rejection code.",
		}, []string{"entity", "status", "code"}),
		pullRows: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: namespace, Name: "sync_pull_rows_total",
			Help: "Rows served on the pull path, by entity.",
		}, []string{"entity"}),
		authCache: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: namespace, Name: "device_auth_cache_total",
			Help: "Device authentications by where the binding came from.",
		}, []string{"result"}),
	}

	m.reg.MustRegister(
		m.httpDuration, m.httpRequests, m.pushRows, m.pullRows, m.authCache,
		collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	return m
}

// Registry exposes the private registry for collectors owned by other packages.
func (m *Metrics) Registry() *prometheus.Registry {
	if m == nil {
		return nil
	}
	return m.reg
}

// Register adds a collector, and is a no-op on a nil *Metrics so a caller need
// not branch on whether this process publishes metrics at all.
func (m *Metrics) Register(collectors ...prometheus.Collector) {
	if m == nil {
		return
	}
	m.reg.MustRegister(collectors...)
}

func (m *Metrics) Handler() http.Handler {
	if m == nil {
		return http.NotFoundHandler()
	}
	return promhttp.HandlerFor(m.reg, promhttp.HandlerOpts{})
}

// Middleware records every request by its chi routing PATTERN, never its URL.
//
// The pattern is what bounds cardinality: `/backoffice/products/{id}` is one
// series, where the raw path would be one series per product and would grow
// without limit. It is only known after routing, so it is read on the way out.
func (m *Metrics) Middleware(next http.Handler) http.Handler {
	if m == nil {
		return next
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		recorder := middleware.NewWrapResponseWriter(w, r.ProtoMajor)

		next.ServeHTTP(recorder, r)

		route := "other"
		if rctx := chi.RouteContext(r.Context()); rctx != nil && rctx.RoutePattern() != "" {
			route = rctx.RoutePattern()
		}
		surface := surfaceOf(r.URL.Path)
		m.httpDuration.WithLabelValues(surface, route, r.Method).Observe(time.Since(started).Seconds())
		m.httpRequests.WithLabelValues(surface, route, r.Method, strconv.Itoa(recorder.Status())).Inc()
	})
}

// PushRow records one per-row push outcome. code is empty for an accepted row.
func (m *Metrics) PushRow(entity, status, code string) {
	if m == nil {
		return
	}
	if code == "" {
		code = "none"
	}
	m.pushRows.WithLabelValues(entity, status, code).Add(1)
}

// PullRows records rows served on one pull page.
func (m *Metrics) PullRows(entity string, rows int) {
	if m == nil || rows < 0 {
		return
	}
	m.pullRows.WithLabelValues(entity).Add(float64(rows))
}

// AuthCache records where a device binding came from: "hit", "miss", or
// "error" when Redis answered neither.
func (m *Metrics) AuthCache(result string) {
	if m == nil {
		return
	}
	m.authCache.WithLabelValues(result).Inc()
}

// surfaceOf keeps the three audiences apart on the dashboard: a slow Backoffice
// page and a slow device poll are different incidents.
func surfaceOf(path string) string {
	switch {
	case strings.HasPrefix(path, "/api/"):
		return "api"
	case strings.HasPrefix(path, "/backoffice"):
		return "backoffice"
	case strings.HasPrefix(path, "/platform"):
		return "platform"
	case strings.HasPrefix(path, "/media"):
		return "media"
	default:
		return "other"
	}
}
