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

// The platform's two ways in exist only when the platform is wired in. The
// module-gated sections stay mounted either way: a module is switched per
// merchant, so it is checked per request rather than when the router is built.
func TestThePlatformEntrancesAreMountedWhenThePlatformIsWired(t *testing.T) {
	platformRoutes := []string{
		"POST /impersonate", "POST /impersonation/end",
		"GET /welcome/{id}", "POST /welcome/{id}",
	}

	with := routesOf(t, backoffice.Deps{
		Impersonations: struct{ backoffice.Impersonations }{},
		Setup:          struct{ backoffice.AccountSetup }{},
	})
	for _, route := range platformRoutes {
		require.True(t, with[route], "%s is not mounted", route)
	}

	without := routesOf(t, backoffice.Deps{})
	for _, route := range platformRoutes {
		require.False(t, without[route], "%s is mounted with no platform behind it", route)
	}
	for _, route := range []string{"GET /stock/", "GET /promos/", "GET /outlets/{id}/tables"} {
		require.True(t, without[route], "%s must stay mounted; its module is checked per request", route)
	}
}
