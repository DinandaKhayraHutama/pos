package metrics_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/metrics"
)

func scrape(t *testing.T, m *metrics.Metrics) string {
	t.Helper()
	recorder := httptest.NewRecorder()
	m.Handler().ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	require.Equal(t, http.StatusOK, recorder.Code)
	return recorder.Body.String()
}

// A metric labelled with something a caller chooses grows a series per
// request until the process runs out of memory. chi's routing PATTERN is
// bounded by the router; the URL is not.
func TestRequestsAreLabelledByRoutePatternNotByURL(t *testing.T) {
	m := metrics.New()
	router := chi.NewRouter()
	router.Use(m.Middleware)
	router.Get("/backoffice/products/{id}", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })

	for _, id := range []string{"a1", "b2", "c3"} {
		recorder := httptest.NewRecorder()
		router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/backoffice/products/"+id, nil))
		require.Equal(t, 200, recorder.Code)
	}

	body := scrape(t, m)
	require.Contains(t, body, `route="/backoffice/products/{id}"`)
	require.Contains(t, body, `surface="backoffice"`)
	require.NotContains(t, body, "products/a1")
	require.Equal(t, 1, strings.Count(body, `justclick_http_requests_total{method="GET",route="/backoffice/products/{id}",status="200",surface="backoffice"}`))
}

func TestAnUnroutedRequestIsCountedWithoutInventingASeries(t *testing.T) {
	m := metrics.New()
	router := chi.NewRouter()
	router.Use(m.Middleware)
	router.Get("/known", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/nothing/here", nil))
	require.Equal(t, 404, recorder.Code)

	body := scrape(t, m)
	require.Contains(t, body, `route="other"`)
	require.Contains(t, body, `status="404"`)
}

// The rejection rate is the earliest visible sign of a client build losing
// money, so it has to carry the code, and an accepted row must not be filed
// under an empty label that no query can select.
func TestPushOutcomesAreCountedPerEntityAndCode(t *testing.T) {
	m := metrics.New()
	m.PushRow("orders", "accepted", "")
	m.PushRow("orders", "accepted", "")
	m.PushRow("orders", "rejected", "settled")
	m.PushRow("pos_sessions", "rejected", "session_closed")

	body := scrape(t, m)
	require.Contains(t, body, `justclick_push_rows_total{code="none",entity="orders",status="accepted"} 2`)
	require.Contains(t, body, `justclick_push_rows_total{code="settled",entity="orders",status="rejected"} 1`)
	require.Contains(t, body, `justclick_push_rows_total{code="session_closed",entity="pos_sessions",status="rejected"} 1`)
}

func TestPullRowsAndAuthCacheAreCounted(t *testing.T) {
	m := metrics.New()
	m.PullRows("products", 500)
	m.PullRows("products", 120)
	m.PullRows("products", -1) // a negative page is nonsense; it must not subtract
	m.AuthCache("hit")
	m.AuthCache("miss")
	m.AuthCache("hit")

	body := scrape(t, m)
	require.Contains(t, body, `justclick_sync_pull_rows_total{entity="products"} 620`)
	require.Contains(t, body, `justclick_device_auth_cache_total{result="hit"} 2`)
	require.Contains(t, body, `justclick_device_auth_cache_total{result="miss"} 1`)
}

// Every test, every script and every one-shot command constructs the server's
// dependencies without a registry. A nil *Metrics has to be safe, or
// instrumentation becomes something each caller must remember.
func TestANilMetricsInstrumentsNothingAndPanicsAtNothing(t *testing.T) {
	var m *metrics.Metrics

	require.NotPanics(t, func() {
		m.PushRow("orders", "accepted", "")
		m.PullRows("products", 10)
		m.AuthCache("hit")
		m.Register()
	})

	handler := m.Middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(204) }))
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/", nil))
	require.Equal(t, 204, recorder.Code)

	recorder = httptest.NewRecorder()
	m.Handler().ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	require.Equal(t, http.StatusNotFound, recorder.Code)
}

// The registry is private on purpose: a dependency that registers a collector
// on the default one must not appear on our /metrics, and two instances in one
// test binary must not collide.
func TestTwoRegistriesDoNotShareState(t *testing.T) {
	first, second := metrics.New(), metrics.New()
	first.PushRow("orders", "accepted", "")

	require.Contains(t, scrape(t, first), `justclick_push_rows_total{code="none",entity="orders",status="accepted"} 1`)
	require.NotContains(t, scrape(t, second), "justclick_push_rows_total")
}
