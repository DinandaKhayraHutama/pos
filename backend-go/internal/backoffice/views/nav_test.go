package views_test

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
)

func hrefs(nav views.NavView) []string {
	var out []string
	for _, group := range nav.Groups {
		for _, item := range group.Items {
			out = append(out, item.Href)
		}
	}
	return out
}

// The rule the whole sidebar rests on: a link never leads to a 403. Every
// entry is gated by the same permission and module switch its route is, so a
// menu that offers a section is a menu you can follow.
func TestTheMenuOffersOnlyWhatThisPersonMayOpen(t *testing.T) {
	bare := views.Session{}.NavView()
	require.Equal(t, []string{"/backoffice/devices"}, hrefs(bare),
		"devices are ungated on purpose; nothing else is")

	owner := views.Session{
		CanDashboard: true, CanReports: true, CanExports: true,
		CanCatalogue: true, CanPromos: true, CanStock: true,
		CanStaff: true, CanOutlets: true,
	}.NavView()
	require.Equal(t, []string{
		"/backoffice/dashboard",
		"/backoffice/reports", "/backoffice/reports/exports", "/backoffice/reports/schedules",
		"/backoffice/catalogue/products", "/backoffice/catalogue/categories",
		"/backoffice/catalogue/brands",
		"/backoffice/catalogue/modifiers", "/backoffice/promos",
		"/backoffice/stock",
		"/backoffice/staff", "/backoffice/staff/roles",
		"/backoffice/outlets", "/backoffice/devices",
	}, hrefs(owner))
}

// Exports and schedules are a module the platform can switch off. Leaving them
// in the menu would toast a 404 at whoever clicked, which is how a person
// learns to stop trusting the menu.
func TestASwitchedOffModuleLeavesTheMenu(t *testing.T) {
	on := views.Session{CanReports: true, CanExports: true}.NavView()
	require.Contains(t, hrefs(on), "/backoffice/reports/exports")

	off := views.Session{CanReports: true, CanExports: false}.NavView()
	require.Equal(t, []string{"/backoffice/reports", "/backoffice/devices"}, hrefs(off),
		"the report itself is not a module; its exports are")
}

// An empty group would render as a heading with nothing under it.
func TestAGroupWithNothingInItIsNotRendered(t *testing.T) {
	nav := views.Session{CanOutlets: true}.NavView()
	for _, group := range nav.Groups {
		require.NotEmpty(t, group.Items, "group %q rendered empty", group.Label)
	}
	for _, group := range nav.Groups {
		require.NotEqual(t, "Library", group.Label, "no catalogue permission, no Library")
	}
}

// A child page keeps its parent entry lit, and the LONGEST match wins:
// /backoffice/reports is a prefix of /backoffice/reports/exports, so a
// shortest-match rule would highlight "Laporan" while the person is reading
// "Ekspor".
func TestTheDeepestMatchingEntryIsTheActiveOne(t *testing.T) {
	full := views.Session{CanReports: true, CanExports: true, CanCatalogue: true}

	for path, want := range map[string]string{
		"/backoffice/reports":                         "/backoffice/reports",
		"/backoffice/reports/exports":                 "/backoffice/reports/exports",
		"/backoffice/reports/schedules":               "/backoffice/reports/schedules",
		"/backoffice/catalogue/products":              "/backoffice/catalogue/products",
		"/backoffice/catalogue/products/abc/variants": "/backoffice/catalogue/products",
		"/backoffice/nowhere":                         "",
	} {
		s := full
		s.Path = path
		require.Equal(t, want, s.NavView().Active, "path %s", path)
	}

	// A prefix that is not a path boundary must not match: /backoffice/stockroom
	// is not inside /backoffice/stock.
	s := views.Session{CanStock: true, Path: "/backoffice/stockroom"}
	require.Equal(t, "", s.NavView().Active)
}

// The group holding the current page arrives already open, so the person does
// not have to find and expand the section they are looking at.
func TestTheGroupHoldingTheCurrentPageStartsOpen(t *testing.T) {
	s := views.Session{CanCatalogue: true, CanStaff: true, Path: "/backoffice/catalogue/modifiers"}
	nav := s.NavView()

	var library, staff views.NavGroup
	for _, group := range nav.Groups {
		switch group.Label {
		case "Library":
			library = group
		case "Karyawan":
			staff = group
		}
	}
	require.True(t, nav.Open(library))
	require.False(t, nav.Open(staff))
}
