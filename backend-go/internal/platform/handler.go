// Package platform serves the super-admin panel at /platform.
//
// It is kept apart from the merchant Backoffice on purpose: its own router, its
// own session table and cookie (on a path the Backoffice never sees), its own
// CSRF key, and a second factor on every sign-in. A session here is a key to
// every merchant at once, so nothing about it may be shared with a panel that
// merchants sign in to.
package platform

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/a-h/templ"
	"github.com/alexedwards/scs/postgresstore"
	"github.com/alexedwards/scs/v2"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/gorilla/csrf"
	"github.com/redis/go-redis/v9"

	domain "github.com/daniryckidinata/nti_pos/backend-go/internal/domain/platform"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/web"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/platform/views"
)

const (
	sessionAdminKey    = "admin_id"
	sessionStageKey    = "stage"
	sessionAttemptsKey = "verify_attempts"
	sessionFlashKey    = "flash"

	// A password alone never reaches the panel. It moves the session to
	// verify (a code is due) or enroll (two-factor sign-in is not set up yet),
	// and only a code moves it to in.
	stageVerify = "verify"
	stageEnroll = "enroll"
	stageIn     = "in"

	maxVerifyAttempts = 5
)

type ctxKey int

const adminKey ctxKey = iota

type Deps struct {
	Service *domain.Service
	// SessionDB must be on the unscoped credential: platform_sessions is not
	// granted to the merchant credential at all.
	SessionDB *sql.DB
	// Redis rate-limits sign-in; nil leaves it unlimited (development only).
	Redis  *redis.Client
	Logger *slog.Logger
	// AppKey keys this panel's CSRF secret, derived separately from the
	// Backoffice's so a token minted by one is never valid in the other.
	AppKey        string
	SecureCookies bool
}

type Handler struct {
	svc      *domain.Service
	sessions *scs.SessionManager
	rdb      *redis.Client
	logger   *slog.Logger
	csrfKey  []byte
	secure   bool
}

func New(d Deps) *Handler {
	sessions := scs.New()
	sessions.Store = postgresstore.NewWithConfig(d.SessionDB, postgresstore.Config{
		TableName: "platform_sessions", CleanUpInterval: 5 * time.Minute,
	})
	// Shorter than the Backoffice's twelve hours, with an idle timeout: an
	// unattended platform tab is an open door to every merchant.
	sessions.Lifetime = 8 * time.Hour
	sessions.IdleTimeout = 30 * time.Minute
	sessions.Cookie.Name = "justclick_platform"
	sessions.Cookie.Path = "/platform"
	sessions.Cookie.HttpOnly = true
	sessions.Cookie.SameSite = http.SameSiteStrictMode
	sessions.Cookie.Secure = d.SecureCookies

	key := sha256.Sum256([]byte(d.AppKey + "|platform-csrf"))
	logger := d.Logger
	if logger == nil {
		logger = slog.Default()
	}
	return &Handler{
		svc: d.Service, sessions: sessions, rdb: d.Redis, logger: logger,
		csrfKey: key[:], secure: d.SecureCookies,
	}
}

func (h *Handler) Routes() chi.Router {
	r := chi.NewRouter()
	r.Use(securityHeaders)
	r.Use(h.sessions.LoadAndSave)
	r.Use(web.DeclareRequestScheme)
	r.Use(csrf.Protect(h.csrfKey,
		csrf.Path("/platform"),
		csrf.CookieName("justclick_platform_csrf"),
		csrf.Secure(h.secure),
		csrf.SameSite(csrf.SameSiteStrictMode),
		csrf.ErrorHandler(web.CSRFFailure(h.logger)),
	))

	r.Get("/login", h.showLogin)
	r.Post("/login", h.submitLogin)
	r.Get("/login/verify", h.showVerify)
	r.Post("/login/verify", h.submitVerify)
	r.Get("/enroll", h.showEnroll)
	r.Post("/enroll", h.submitEnroll)
	r.Post("/logout", h.logout)

	r.Group(func(r chi.Router) {
		r.Use(h.requireAdmin)

		r.Get("/", func(w http.ResponseWriter, req *http.Request) {
			http.Redirect(w, req, "/platform/tenants", http.StatusSeeOther)
		})
		r.Get("/tenants", h.tenantsPage)
		r.Get("/tenants/new", h.newTenantPage)
		r.Post("/tenants", h.createTenant)
		r.Get("/tenants/{id}", h.tenantPage)
		r.Post("/tenants/{id}/suspend", h.suspendTenant)
		r.Post("/tenants/{id}/reactivate", h.reactivateTenant)
		r.Post("/tenants/{id}/limits", h.saveLimits)
		r.Post("/tenants/{id}/flags", h.saveFlags)
		r.Post("/tenants/{id}/owners/{employeeID}/setup-link", h.reissueSetupLink)
		r.Post("/tenants/{id}/impersonate", h.startImpersonation)
		r.Get("/audit", h.auditPage)
		r.Get("/ops", h.opsPage)
	})

	return r
}

// securityHeaders: never framed, never cached, never leaking a URL onward —
// several pages here show a credential exactly once.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Frame-Options", "DENY")
		// same-origin, NOT no-referrer. gorilla/csrf falls back to the Referer
		// header when a browser sends no Origin on a form POST, and
		// no-referrer told the browser to withhold exactly that — a panel that
		// refused its own login with "referer not supplied". Same-origin still
		// sends nothing to any other site.
		w.Header().Set("Referrer-Policy", "same-origin")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(w, r)
	})
}

func adminFrom(ctx context.Context) domain.Admin {
	a, _ := ctx.Value(adminKey).(domain.Admin)
	return a
}

func (h *Handler) actor(r *http.Request) domain.Actor {
	return domain.Actor{AdminID: adminFrom(r.Context()).ID, IP: clientIP(r)}
}

func (h *Handler) sessionView(r *http.Request) views.Session {
	a := adminFrom(r.Context())
	return views.Session{AdminName: a.Name, AdminEmail: a.Email, CSRFToken: csrf.Token(r), Path: r.URL.Path}
}

func (h *Handler) render(w http.ResponseWriter, r *http.Request, c templ.Component) {
	h.renderStatus(w, r, http.StatusOK, c)
}

func (h *Handler) renderStatus(w http.ResponseWriter, r *http.Request, status int, c templ.Component) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	if err := c.Render(r.Context(), w); err != nil {
		h.logger.Error("render platform view", slog.Any("error", err))
	}
}

func (h *Handler) serverError(w http.ResponseWriter, r *http.Request, err error) {
	h.logger.Error("platform request failed", slog.Any("error", err))
	h.renderStatus(w, r, http.StatusInternalServerError,
		views.MessagePage(h.sessionView(r), "Terjadi kesalahan", "Permintaan ini gagal di server. Coba lagi."))
}

func (h *Handler) notFound(w http.ResponseWriter, r *http.Request) {
	h.renderStatus(w, r, http.StatusNotFound,
		views.MessagePage(h.sessionView(r), "Tidak ditemukan", "Data ini tidak ada."))
}

// failed answers a domain error that is not a form problem, and reports
// whether it did.
func (h *Handler) failed(w http.ResponseWriter, r *http.Request, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, domain.ErrNotFound):
		h.notFound(w, r)
	default:
		h.serverError(w, r, err)
	}
	return true
}

func clientIP(r *http.Request) string {
	if ip := middleware.GetClientIP(r.Context()); ip != "" {
		return ip
	}
	return r.RemoteAddr
}
