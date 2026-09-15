package backoffice_test

import (
	"net/http"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice"
)

func routesOf(t *testing.T, d backoffice.Deps) map[string]bool {
	t.Helper()
	d.CSRFKey = make([]byte, 32)
	found := map[string]bool{}
	err := chi.Walk(backoffice.New(d).Routes(), func(method, route string, _ http.Handler, _ ...func(http.Handler) http.Handler) error {
		found[method+" "+route] = true
		return nil
	})
	require.NoError(t, err)
	return found
}

// The report sections are mounted only when a report service is wired in. A
// Deps field that New forgot to copy left every one of them a 404 while the
// rest of the panel worked — nothing short of a live request noticed.
func TestTheReportSectionsAreMountedWhenReportsAreWired(t *testing.T) {
	with := routesOf(t, backoffice.Deps{Reports: struct{ backoffice.ReportService }{}})
	for _, route := range []string{
		"GET /dashboard", "GET /dashboard/tiles",
		"GET /reports/", "POST /reports/recompute",
		"GET /reports/exports", "POST /reports/exports", "GET /reports/exports/{id}/download",
		"GET /reports/schedules", "POST /reports/schedules",
		"GET /report-links/{id}",
	} {
		require.True(t, with[route], "%s is not mounted", route)
	}

	without := routesOf(t, backoffice.Deps{})
	require.True(t, without["GET /devices"])
	require.False(t, without["GET /reports/"])
	require.False(t, without["GET /report-links/{id}"])
}
