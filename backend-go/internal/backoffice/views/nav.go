package views

import "strings"

// NavItem is one destination in the sidebar.
type NavItem struct {
	Label string
	Href  string
}

// NavGroup is a heading and the destinations under it. A group with no Label
// renders as a bare link — the sidebar's top-level entries, like the dashboard,
// which have nothing to group.
type NavGroup struct {
	Label string
	// Icon names one of the inline glyphs in navIcon. A group without one is
	// still usable expanded, but collapses to an empty rail.
	Icon  string
	Items []NavItem
}

// NavView is the whole sidebar for one request: what this person may open, and
// which entry the page they are on belongs to.
type NavView struct {
	Groups []NavGroup
	// Active is the href of the entry the current path belongs to, chosen by
	// LONGEST match. /backoffice/reports is a prefix of
	// /backoffice/reports/exports, so a shortest-match rule would light up
	// "Laporan" while the person is looking at "Ekspor".
	Active string
}

// Open reports whether a group should start expanded: it holds the page the
// person is on. Rendered server-side, so the right section is already open when
// the page arrives rather than after JavaScript runs.
func (v NavView) Open(g NavGroup) bool {
	for _, item := range g.Items {
		if item.Href == v.Active {
			return true
		}
	}
	return false
}

// activeHref picks the entry the path belongs to. A child page keeps its parent
// entry lit: /backoffice/catalogue/products/{id} is still "Produk".
// ActiveHref is exported for the platform panel, which builds its own menu
// but reuses this sidebar.
func ActiveHref(groups []NavGroup, path string) string {
	best := ""
	for _, g := range groups {
		for _, item := range g.Items {
			if path != item.Href && !strings.HasPrefix(path, item.Href+"/") {
				continue
			}
			if len(item.Href) > len(best) {
				best = item.Href
			}
		}
	}
	return best
}

// NavView builds the sidebar from the same permissions and module switches the
// routes are gated on.
//
// Every entry here has a route that this person can actually open: the
// alternative is a menu that leads to a 403, which teaches people to distrust
// the menu. Nothing is hidden for tidiness — only for permission.
func (s Session) NavView() NavView {
	var groups []NavGroup

	if s.CanDashboard {
		groups = append(groups, NavGroup{Icon: "home", Items: []NavItem{
			{Label: "Dashboard", Href: "/backoffice/dashboard"},
		}})
	}

	// Transactions and shifts sit under Laporan because that is what people
	// come here to reconcile, but each carries its own permission: a manager
	// holds both, and a role that could read sales without reading a drawer
	// would see only the first entry.
	var reports []NavItem
	if s.CanReports {
		reports = append(reports, NavItem{Label: "Ringkasan penjualan", Href: "/backoffice/reports"})
	}
	if s.CanTransactions {
		reports = append(reports, NavItem{Label: "Transaksi", Href: "/backoffice/transactions"})
	}
	if s.CanShifts {
		reports = append(reports, NavItem{Label: "Shift", Href: "/backoffice/shifts"})
	}
	// Exports and schedules are a module the platform can switch off. The nav
	// folds in the same switch the routes use, or the section would toast a
	// 404 at whoever clicked it.
	if s.CanExports {
		reports = append(reports,
			NavItem{Label: "Ekspor", Href: "/backoffice/reports/exports"},
			NavItem{Label: "Jadwal laporan", Href: "/backoffice/reports/schedules"},
		)
	}
	if len(reports) > 0 {
		groups = append(groups, NavGroup{Label: "Laporan", Icon: "chart", Items: reports})
	}

	// "Library" is what a cashier already calls this on the till: the things
	// that end up on a receipt.
	var library []NavItem
	if s.CanCatalogue {
		library = append(library,
			NavItem{Label: "Produk", Href: "/backoffice/catalogue/products"},
			NavItem{Label: "Kategori", Href: "/backoffice/catalogue/categories"},
			NavItem{Label: "Modifier", Href: "/backoffice/catalogue/modifiers"},
		)
	}
	if s.CanPromos {
		library = append(library, NavItem{Label: "Promo", Href: "/backoffice/promos"})
	}
	if len(library) > 0 {
		groups = append(groups, NavGroup{Label: "Library", Icon: "book", Items: library})
	}

	if s.CanStock {
		groups = append(groups, NavGroup{Label: "Inventaris", Icon: "box", Items: []NavItem{
			{Label: "Stok", Href: "/backoffice/stock"},
		}})
	}

	if s.CanStaff {
		groups = append(groups, NavGroup{Label: "Karyawan", Icon: "people", Items: []NavItem{
			{Label: "Daftar karyawan", Href: "/backoffice/staff"},
		}})
	}

	// Devices are ungated on purpose: anyone who can sign in may need to see
	// whether the till in front of them is the one that stopped syncing.
	outlets := []NavItem{}
	if s.CanOutlets {
		outlets = append(outlets, NavItem{Label: "Outlet & till", Href: "/backoffice/outlets"})
	}
	outlets = append(outlets, NavItem{Label: "Perangkat", Href: "/backoffice/devices"})
	groups = append(groups, NavGroup{Label: "Outlet", Icon: "store", Items: outlets})

	return NavView{Groups: groups, Active: ActiveHref(groups, s.Path)}
}
