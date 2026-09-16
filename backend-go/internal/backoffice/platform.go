package backoffice

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/url"

	"github.com/go-chi/chi/v5"
	"github.com/gorilla/csrf"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/platform"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/web"
)

// Impersonations is the platform domain as the Backoffice uses it: a platform
// admin enters as an owner through a one-time handoff, and every request after
// that is checked and every change audited.
type Impersonations interface {
	ConsumeHandoff(ctx context.Context, token, ip string) (platform.Impersonation, error)
	ActiveImpersonation(ctx context.Context, id, tenantID, employeeID string) (platform.Impersonation, error)
	EndImpersonation(ctx context.Context, id, by, ip string) error
	RecordImpersonatedRequest(ctx context.Context, imp platform.Impersonation, method, path, ip string) error
}

// AccountSetup is an owner's first sign-in link.
type AccountSetup interface {
	SetupAccount(ctx context.Context, tokenID, token string) (platform.SetupAccount, error)
	CompleteSetup(ctx context.Context, tokenID, token, password string) (platform.SetupAccount, error)
}

// beginImpersonation consumes the handoff the platform panel posts here and
// signs this browser in as the owner, marked as an impersonation for its life.
func (h *Handler) beginImpersonation(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !web.SameOrigin(r) {
		h.renderStatus(w, r, http.StatusForbidden, views.PublicMessage("Ditolak",
			"Impersonasi hanya bisa dimulai dari panel platform di alamat yang sama."))
		return
	}
	if err := r.ParseForm(); err != nil {
		h.renderStatus(w, r, http.StatusBadRequest, views.PublicMessage("Ditolak", "Formulir tidak terbaca."))
		return
	}

	imp, err := h.impersonations.ConsumeHandoff(r.Context(), r.PostFormValue("token"), clientIP(r))
	if errors.Is(err, platform.ErrImpersonationInvalid) {
		h.renderStatus(w, r, http.StatusForbidden, views.PublicMessage("Tautan impersonasi tidak berlaku",
			"Tautan ini sudah dipakai atau kedaluwarsa (berlaku satu menit). Mulai lagi dari panel platform."))
		return
	}
	if err != nil {
		h.logger.Error("consume impersonation handoff", slog.Any("error", err))
		h.renderStatus(w, r, http.StatusInternalServerError, views.PublicMessage("Gagal", "Impersonasi tidak bisa dimulai."))
		return
	}

	if err := h.sessions.RenewToken(r.Context()); err != nil {
		h.serverError(w, r, err)
		return
	}
	h.sessions.Put(r.Context(), sessionEmployeeKey, imp.EmployeeID)
	h.sessions.Put(r.Context(), sessionTenantKey, imp.TenantID)
	h.sessions.Put(r.Context(), sessionImpersonationKey, imp.ID)

	http.Redirect(w, r, "/backoffice/", http.StatusSeeOther)
}

// endImpersonation closes it from the banner and returns the admin to the
// merchant's page on the platform panel.
func (h *Handler) endImpersonation(w http.ResponseWriter, r *http.Request) {
	imp, ok := impersonationFrom(r.Context())
	if !ok {
		http.Redirect(w, r, "/backoffice/", http.StatusSeeOther)
		return
	}
	if err := h.impersonations.EndImpersonation(r.Context(), imp.ID, "admin", clientIP(r)); err != nil {
		h.serverError(w, r, err)
		return
	}
	if err := h.sessions.Destroy(r.Context()); err != nil {
		h.serverError(w, r, err)
		return
	}
	redirect(w, r, "/platform/tenants/"+imp.TenantID)
}

func welcomeAction(id, token string) string {
	return platform.SetupPath(id) + "?token=" + url.QueryEscape(token)
}

// welcomePage is where a first sign-in link lands. The token is in the URL, so
// the page must not leak it onward in a Referer or leave it in a cache.
func (h *Handler) welcomePage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Cache-Control", "no-store")

	id, token := chi.URLParam(r, "id"), r.URL.Query().Get("token")
	account, err := h.setup.SetupAccount(r.Context(), id, token)
	if h.setupFailed(w, r, err) {
		return
	}
	h.render(w, r, views.WelcomePage(csrf.Token(r), welcomeAction(id, token), views.SetupAccount(account), views.NewForm()))
}

// completeWelcome sets the password and signs the owner straight in, through
// the same checks as the login form.
func (h *Handler) completeWelcome(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Cache-Control", "no-store")

	id, token := chi.URLParam(r, "id"), r.URL.Query().Get("token")
	if err := r.ParseForm(); err != nil {
		h.renderStatus(w, r, http.StatusBadRequest, views.PublicMessage("Ditolak", "Formulir tidak terbaca."))
		return
	}
	password := r.PostFormValue("password")

	account, err := h.setup.CompleteSetup(r.Context(), id, token, password)
	if fields, ok := validation.As(err); ok {
		shown, err := h.setup.SetupAccount(r.Context(), id, token)
		if h.setupFailed(w, r, err) {
			return
		}
		f := views.NewForm()
		for k, v := range fields {
			f.Errors[k] = v
		}
		h.render(w, r, views.WelcomePage(csrf.Token(r), welcomeAction(id, token), views.SetupAccount(shown), f))
		return
	}
	if h.setupFailed(w, r, err) {
		return
	}

	employee, err := h.staff.Authenticate(r.Context(), account.Email, password)
	if err != nil {
		// The password is set; only the automatic sign-in did not happen.
		http.Redirect(w, r, "/backoffice/login", http.StatusSeeOther)
		return
	}
	if err := h.signIn(r, employee); err != nil {
		h.serverError(w, r, err)
		return
	}
	http.Redirect(w, r, "/backoffice/", http.StatusSeeOther)
}

func (h *Handler) setupFailed(w http.ResponseWriter, r *http.Request, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, platform.ErrSetupLinkInvalid):
		h.renderStatus(w, r, http.StatusGone, views.PublicMessage("Tautan tidak berlaku",
			"Tautan ini sudah dipakai, sudah diganti dengan yang baru, atau kedaluwarsa. Minta tautan baru ke tim JustClick."))
	default:
		h.logger.Error("owner setup link", slog.Any("error", err))
		h.renderStatus(w, r, http.StatusInternalServerError, views.PublicMessage("Gagal", "Tautan tidak bisa diproses saat ini."))
	}
	return true
}
