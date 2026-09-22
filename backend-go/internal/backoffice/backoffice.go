// Package backoffice serves the merchant-facing web panel.
//
// Screens ask for a permission, never for a role. A role comparison in a
// handler is a bug waiting for the fourth role, and it is also how a screen
// quietly keeps working for someone who should have lost it.
package backoffice

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/alexedwards/scs/postgresstore"
	"github.com/alexedwards/scs/v2"
	"github.com/go-chi/chi/v5"
	"github.com/gorilla/csrf"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/entitlements"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/ingest"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/outlets"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/promos"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/staff"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/stock"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/web"
)

//go:embed static
var staticFS embed.FS

const (
	sessionEmployeeKey      = "employee_id"
	sessionTenantKey        = "tenant_id"
	sessionImpersonationKey = "impersonation_id"
)

type ctxKey int

const (
	employeeKey ctxKey = iota
	impersonationKey
)

type Handler struct {
	pools     pg.Pools
	staff     *staff.Service
	catalogue *catalogue.Service
	promos    *promos.Service
	outlets   *outlets.Service
	stock     *stock.Service
	tables    TableService
	reports   ReportService
	history   HistoryService
	devices   *devices.Service
	auth      *devices.CachedAuthenticator
	recovery  *ingest.Service
	// impersonations and setup are the platform's two ways into this panel.
	impersonations Impersonations
	setup          AccountSetup
	sessions       *scs.SessionManager
	logger         *slog.Logger
	csrfKey        []byte
	secure         bool
}

type Deps struct {
	Pools     pg.Pools
	SessionDB *sql.DB
	Staff     *staff.Service
	Catalogue *catalogue.Service
	Promos    *promos.Service
	Outlets   *outlets.Service
	Stock     *stock.Service
	Tables    TableService
	// Reports serves the sales report, dashboard and exports. Nil leaves those
	// sections out of the panel.
	Reports ReportService
	// History serves the read-only transaction and shift screens. Nil leaves
	// them unmounted; they also need Reports, for the merchant's clock.
	History HistoryService
	Devices    *devices.Service
	CachedAuth *devices.CachedAuthenticator
	Recovery   *ingest.Service
	// Impersonations lets a platform admin in as an owner; nil leaves the
	// handoff route unmounted.
	Impersonations Impersonations
	// Setup serves an owner's first sign-in link; nil leaves it unmounted.
	Setup   AccountSetup
	Logger  *slog.Logger
	CSRFKey []byte
	// SecureCookies must be true anywhere the panel is reachable over TLS,
	// which is everywhere except a developer's own machine.
	SecureCookies bool
}

// New must copy every Deps field. It once dropped Reports, and every report
// route was a 404 while the rest of the panel worked; routes_test.go walks the
// router for each optional section.
func New(d Deps) *Handler {
	sessions := scs.New()
	sessions.Store = postgresstore.New(d.SessionDB)
	sessions.Lifetime = 12 * time.Hour
	sessions.Cookie.Name = "justclick_backoffice"
	sessions.Cookie.Path = "/backoffice"
	sessions.Cookie.HttpOnly = true
	sessions.Cookie.SameSite = http.SameSiteLaxMode
	sessions.Cookie.Secure = d.SecureCookies

	return &Handler{
		pools:          d.Pools,
		staff:          d.Staff,
		catalogue:      d.Catalogue,
		promos:         d.Promos,
		outlets:        d.Outlets,
		stock:          d.Stock,
		tables:         d.Tables,
		reports:        d.Reports,
		history:        d.History,
		devices:        d.Devices,
		auth:           d.CachedAuth,
		recovery:       d.Recovery,
		impersonations: d.Impersonations,
		setup:          d.Setup,
		sessions:       sessions,
		logger:         d.Logger,
		csrfKey:        d.CSRFKey,
		secure:         d.SecureCookies,
	}
}

func (h *Handler) Routes() chi.Router {
	r := chi.NewRouter()

	r.Handle("/static/*", http.StripPrefix("/backoffice/", http.FileServer(http.FS(staticFS))))

	r.Group(func(r chi.Router) {
		r.Use(h.sessions.LoadAndSave)
		r.Use(web.DeclareRequestScheme)

		// The platform panel's handoff arrives from a page of another panel,
		// which cannot hold this panel's CSRF token. The one-time token in the
		// body is the credential, and the handler still refuses a cross-site
		// Origin.
		if h.impersonations != nil {
			r.Post("/impersonate", h.beginImpersonation)
		}

		r.Group(func(r chi.Router) {
			r.Use(csrf.Protect(h.csrfKey,
				csrf.Path("/backoffice"),
				csrf.Secure(h.secure),
				csrf.SameSite(csrf.SameSiteLaxMode),
				csrf.ErrorHandler(web.CSRFFailure(h.logger)),
			))

			r.Get("/login", h.showLogin)
			r.Post("/login", h.submitLogin)
			r.Post("/logout", h.logout)

			// An e-mailed report link: no session, the token is the credential.
			if h.reports != nil {
				r.Get("/report-links/{id}", h.downloadByToken)
			}
			// An owner's first sign-in link: likewise.
			if h.setup != nil {
				r.Get("/welcome/{id}", h.welcomePage)
				r.Post("/welcome/{id}", h.completeWelcome)
			}

			r.Group(func(r chi.Router) {
				r.Use(h.requireEmployee)

				// Outside the audit middleware: ending an impersonation writes
				// its own audit row, and must work even when a request row
				// could not be written.
				if h.impersonations != nil {
					r.Post("/impersonation/end", h.endImpersonation)
				}

				r.Group(h.panelRoutes)
			})
		})
	})

	return r
}

// panelRoutes is every signed-in screen.
func (h *Handler) panelRoutes(r chi.Router) {
	// Under impersonation every change is audited before it runs, and refused
	// if the audit row cannot be written.
	r.Use(h.auditImpersonatedWrites)

	r.Get("/", func(w http.ResponseWriter, req *http.Request) {
		target := "/backoffice/devices"
		if h.reports != nil && employeeFrom(req.Context()).Can(auth.ViewDailySummary) {
			target = "/backoffice/dashboard"
		}
		http.Redirect(w, req, target, http.StatusSeeOther)
	})
	r.Get("/devices", h.devicesPage)

	if h.reports != nil {
		// The dashboard is the daily summary a manager already sees on the
		// till; the full report is financial and stays with whoever holds
		// viewFinancialReports.
		r.With(h.require(auth.ViewDailySummary)).Get("/dashboard", h.dashboardPage)
		r.With(h.require(auth.ViewDailySummary)).Get("/dashboard/tiles", h.dashboardTiles)
		r.Route("/reports", func(r chi.Router) {
			r.Use(h.require(auth.ViewFinancialReports))

			r.Get("/", h.reportsPage)
			r.Post("/recompute", h.recomputeReport)

			// Exports and schedules are a module the platform can switch off;
			// the report itself is not.
			r.Group(func(r chi.Router) {
				r.Use(h.requireFeature(entitlements.ReportExports))

				r.Get("/exports", h.exportsList)
				r.Post("/exports", h.requestExport)
				r.Get("/exports/{id}/download", h.downloadExport)
				r.Get("/schedules", h.schedulesPage)
				r.Post("/schedules", h.createSchedule)
				r.Post("/schedules/{id}/active", h.setScheduleActive)
				r.Post("/schedules/{id}/delete", h.deleteSchedule)
			})
		})
	}

	// Reading somebody else's sales is the permission a manager already holds
	// to void and refund on the till; reading a drawer is the one they hold to
	// look inside it. Both sections are read-only, and both need the merchant's
	// clock, which Reports owns — hence the pair in the guard.
	if h.history != nil && h.reports != nil {
		r.With(h.require(auth.ViewAllOrders)).Get("/transactions", h.transactionsPage)
		r.With(h.require(auth.ViewAllOrders)).Get("/transactions/{id}", h.transactionPage)
		r.With(h.require(auth.ViewCashDrawer)).Get("/shifts", h.shiftsPage)
		r.With(h.require(auth.ViewCashDrawer)).Get("/shifts/{id}", h.shiftPage)
	}

	// Issuing and revoking are infrastructure work, so they carry the
	// same permission as configuring branches and tills.
	r.With(h.require(auth.ManageOutlets)).
		Post("/registers/{registerID}/activation-code", h.issueActivationCode)
	r.With(h.require(auth.ManageOutlets)).
		Post("/devices/{deviceID}/revoke", h.revokeDevice)
	if h.recovery != nil {
		r.With(h.require(auth.ManageOutlets)).Post("/till-sessions/{sessionID}/takeover", h.takeoverTill)
		r.With(h.require(auth.ManageOutlets)).Post("/till-recoveries/{recoveryID}/items/{itemID}/accept", h.acceptRecoveryItem)
		r.With(h.require(auth.ManageOutlets)).Post("/till-recoveries/{recoveryID}/items/{itemID}/discard", h.discardRecoveryItem)
		r.With(h.require(auth.ManageOutlets)).Post("/till-recoveries/{recoveryID}/reconcile", h.reconcileRecovery)
	}

	// Each section is gated by the permission it exercises, reading
	// included: a page someone may not act on is still a page of
	// another role's data.
	r.Route("/catalogue", func(r chi.Router) {
		r.Use(h.require(auth.ManageCatalogue))

		r.Get("/categories", h.categoriesPage)
		r.Post("/categories", h.createCategory)
		r.Get("/categories/{id}", h.categoryPage)
		r.Post("/categories/{id}", h.updateCategory)
		r.Post("/categories/{id}/delete", h.deleteCategory)

		r.Get("/products", h.productsPage)
		r.Get("/products/new", h.newProductPage)
		r.Post("/products", h.createProduct)
		r.Get("/products/import", h.importPage)
		r.Post("/products/import", h.importPrices)
		r.Get("/products/{id}", h.productPage)
		r.Post("/products/{id}", h.updateProduct)
		r.Post("/products/{id}/availability", h.setProductAvailability)
		r.Post("/products/{id}/delete", h.deleteProduct)
		r.Post("/products/{id}/image", h.uploadProductImage)
		r.Post("/products/{id}/image/delete", h.removeProductImage)
		r.Post("/products/{id}/variants", h.saveVariant)
		r.Post("/products/{id}/variants/{variantID}", h.saveVariant)
		r.Post("/products/{id}/variants/{variantID}/delete", h.deleteVariant)
		r.Post("/products/{id}/modifiers", h.saveProductModifiers)

		r.Get("/modifiers", h.modifiersPage)
		r.Post("/modifiers", h.createModifierGroup)
		r.Get("/modifiers/{id}", h.modifierGroupPage)
		r.Post("/modifiers/{id}", h.updateModifierGroup)
		r.Post("/modifiers/{id}/delete", h.deleteModifierGroup)
		r.Post("/modifiers/{id}/options", h.saveModifierOption)
		r.Post("/modifiers/{id}/options/{optionID}", h.saveModifierOption)
		r.Post("/modifiers/{id}/options/{optionID}/delete", h.deleteModifierOption)
	})

	r.Route("/promos", func(r chi.Router) {
		r.Use(h.require(auth.ManagePromos))
		r.Use(h.requireFeature(entitlements.Promos))

		r.Get("/", h.promosPage)
		r.Get("/new", h.newPromoPage)
		r.Post("/", h.createPromo)
		r.Get("/{id}", h.promoPage)
		r.Post("/{id}", h.updatePromo)
		r.Post("/{id}/delete", h.deletePromo)
	})

	r.Route("/staff", func(r chi.Router) {
		r.Use(h.require(auth.ManageEmployees))

		r.Get("/", h.staffPage)
		r.Get("/new", h.newStaffPage)
		r.Post("/", h.createStaff)
		r.Get("/{id}", h.staffMemberPage)
		r.Post("/{id}", h.updateStaff)
		// Support inside a merchant must not be able to take an account over.
		r.With(h.refuseWhileImpersonating).Post("/{id}/pin", h.setStaffPIN)
		r.With(h.refuseWhileImpersonating).Post("/{id}/password", h.setStaffPassword)
		r.Post("/{id}/active", h.setStaffActive)
	})

	r.Route("/outlets", func(r chi.Router) {
		r.Use(h.require(auth.ManageOutlets))

		r.Get("/", h.outletsPage)
		r.Post("/", h.createOutlet)
		r.Get("/{id}", h.outletPage)
		r.Post("/{id}", h.updateOutlet)
		r.Post("/{id}/active", h.setOutletActive)
		r.Post("/{id}/registers", h.saveRegister)
		r.Post("/{id}/registers/{registerID}", h.saveRegister)
		r.Post("/{id}/registers/{registerID}/active", h.setRegisterActive)

		// The floor plan belongs to the branch it is in, and configuring it is the
		// same infrastructure work as configuring its tills.
		r.Group(func(r chi.Router) {
			r.Use(h.requireFeature(entitlements.Tables))

			r.Get("/{id}/tables", h.tablesPage)
			r.Get("/{id}/tables/board", h.tablesBoard)
			r.Post("/{id}/tables", h.saveTable)
			r.Post("/{id}/tables/{tableID}", h.saveTable)
			r.Post("/{id}/tables/{tableID}/active", h.setTableActive)
			r.Post("/{id}/tables/{tableID}/delete", h.deleteTable)
		})
	})

	// The same permission the till uses for stock in and out, so a
	// manager who may adjust a shelf at the counter may do it here.
	r.Route("/stock", func(r chi.Router) {
		r.Use(h.require(auth.AdjustStock))
		r.Use(h.requireFeature(entitlements.Stock))

		r.Get("/", h.stockPage)
		r.Get("/{outletID}/{productID}", h.stockProductPage)
		r.Post("/{outletID}/{productID}/adjust", h.adjustStock)
		r.Post("/{outletID}/{productID}/count", h.countStock)
		r.Post("/{outletID}/{productID}/transfer", h.transferStock)
	})
}

func tenantOf(r *http.Request) string { return employeeFrom(r.Context()).TenantID }

// parseForm reads the posted form, keeping the named inputs that repeat
// (checkbox groups) as lists.
func (h *Handler) parseForm(w http.ResponseWriter, r *http.Request, multi ...string) (views.Form, bool) {
	if err := r.ParseForm(); err != nil {
		h.renderStatus(w, r, http.StatusBadRequest, views.ErrorCard("Formulir tidak terbaca."))
		return views.Form{}, false
	}
	return formOf(r, multi...), true
}

// failed answers an error that is not the person's to fix by retyping, and
// reports whether it did. A missing row is a 404 — usually a stale tab, or an
// id from another merchant, which row-level security makes indistinguishable
// on purpose. Anything else is the server's fault.
func (h *Handler) failed(w http.ResponseWriter, r *http.Request, err, notFound error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, notFound):
		h.notFound(w, r)
	default:
		h.serverError(w, r, err)
	}
	return true
}

func (h *Handler) notFound(w http.ResponseWriter, r *http.Request) {
	if isHX(r) {
		h.renderStatus(w, r, http.StatusNotFound, views.ErrorCard("Data tidak ditemukan."))
		return
	}
	h.renderStatus(w, r, http.StatusNotFound,
		views.MessagePage(h.sessionView(r), "Tidak ditemukan", "Data ini tidak ada, atau sudah dihapus."))
}

func employeeFrom(ctx context.Context) staff.Employee {
	emp, _ := ctx.Value(employeeKey).(staff.Employee)
	return emp
}
