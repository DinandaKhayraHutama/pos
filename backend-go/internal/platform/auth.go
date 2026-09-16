package platform

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/csrf"

	domain "github.com/daniryckidinata/nti_pos/backend-go/internal/domain/platform"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/platform/views"
)

// Sign-in is limited per address and per account. The limiter allows when
// Redis is down, as everywhere else in the system; the second factor is what
// still stands then.
var (
	loginPerIP     = redisx.Limit{Burst: 10, Window: time.Minute}
	loginPerEmail  = redisx.Limit{Burst: 5, Window: 15 * time.Minute}
	verifyPerAdmin = redisx.Limit{Burst: 10, Window: 15 * time.Minute}
)

func (h *Handler) allow(r *http.Request, key string, limit redisx.Limit) bool {
	if h.rdb == nil {
		return true
	}
	ok, _ := redisx.Allow(r.Context(), h.rdb, key, limit)
	return ok
}

func (h *Handler) stage(r *http.Request) string {
	return h.sessions.GetString(r.Context(), sessionStageKey)
}

func (h *Handler) showLogin(w http.ResponseWriter, r *http.Request) {
	if h.stage(r) == stageIn {
		http.Redirect(w, r, "/platform/tenants", http.StatusSeeOther)
		return
	}
	h.render(w, r, views.LoginPage(csrf.Token(r), "", ""))
}

func (h *Handler) submitLogin(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		h.renderStatus(w, r, http.StatusBadRequest, views.LoginPage(csrf.Token(r), "", "Formulir tidak terbaca."))
		return
	}
	email := strings.TrimSpace(r.PostFormValue("email"))

	if !h.allow(r, "pl:login:ip:"+clientIP(r), loginPerIP) ||
		!h.allow(r, "pl:login:email:"+strings.ToLower(email), loginPerEmail) {
		w.Header().Set("Retry-After", "60")
		h.renderStatus(w, r, http.StatusTooManyRequests,
			views.LoginPage(csrf.Token(r), email, "Terlalu banyak percobaan. Coba lagi beberapa menit lagi."))
		return
	}

	admin, err := h.svc.Authenticate(r.Context(), email, r.PostFormValue("password"))
	if err != nil {
		if !errors.Is(err, domain.ErrInvalidCredentials) {
			h.logger.Error("platform login", slog.Any("error", err))
		}
		h.renderStatus(w, r, http.StatusUnauthorized,
			views.LoginPage(csrf.Token(r), email, "Email atau kata sandi salah."))
		return
	}

	// A new session id at every change of stage, so a token planted in the
	// browser beforehand is never the one that ends up signed in.
	if err := h.sessions.RenewToken(r.Context()); err != nil {
		h.serverError(w, r, err)
		return
	}
	h.sessions.Put(r.Context(), sessionAdminKey, admin.ID)
	h.sessions.Remove(r.Context(), sessionAttemptsKey)

	if admin.TOTPEnabled {
		h.sessions.Put(r.Context(), sessionStageKey, stageVerify)
		http.Redirect(w, r, "/platform/login/verify", http.StatusSeeOther)
		return
	}
	h.sessions.Put(r.Context(), sessionStageKey, stageEnroll)
	http.Redirect(w, r, "/platform/enroll", http.StatusSeeOther)
}

func (h *Handler) showVerify(w http.ResponseWriter, r *http.Request) {
	if h.stage(r) != stageVerify {
		http.Redirect(w, r, "/platform/login", http.StatusSeeOther)
		return
	}
	h.render(w, r, views.VerifyPage(csrf.Token(r), ""))
}

func (h *Handler) submitVerify(w http.ResponseWriter, r *http.Request) {
	adminID := h.sessions.GetString(r.Context(), sessionAdminKey)
	if h.stage(r) != stageVerify || adminID == "" {
		http.Redirect(w, r, "/platform/login", http.StatusSeeOther)
		return
	}
	if err := r.ParseForm(); err != nil {
		h.renderStatus(w, r, http.StatusBadRequest, views.VerifyPage(csrf.Token(r), "Formulir tidak terbaca."))
		return
	}
	if !h.allow(r, "pl:verify:"+adminID, verifyPerAdmin) {
		w.Header().Set("Retry-After", "60")
		h.renderStatus(w, r, http.StatusTooManyRequests,
			views.VerifyPage(csrf.Token(r), "Terlalu banyak percobaan. Coba lagi beberapa menit lagi."))
		return
	}

	var err error
	if recovery := strings.TrimSpace(r.PostFormValue("recovery_code")); recovery != "" {
		err = h.svc.SignInWithRecoveryCode(r.Context(), adminID, recovery, clientIP(r))
	} else {
		err = h.svc.SignInWithTOTP(r.Context(), adminID, r.PostFormValue("code"), clientIP(r))
	}
	if err != nil {
		if !errors.Is(err, domain.ErrInvalidCode) {
			h.serverError(w, r, err)
			return
		}
		attempts := h.sessions.GetInt(r.Context(), sessionAttemptsKey) + 1
		if attempts >= maxVerifyAttempts {
			// Back to the password: five wrong codes is not someone who has the phone.
			_ = h.sessions.Destroy(r.Context())
			h.renderStatus(w, r, http.StatusUnauthorized,
				views.LoginPage(csrf.Token(r), "", "Terlalu banyak kode salah. Masuk lagi dari awal."))
			return
		}
		h.sessions.Put(r.Context(), sessionAttemptsKey, attempts)
		h.renderStatus(w, r, http.StatusUnauthorized, views.VerifyPage(csrf.Token(r), "Kode salah atau sudah dipakai."))
		return
	}

	if err := h.sessions.RenewToken(r.Context()); err != nil {
		h.serverError(w, r, err)
		return
	}
	h.sessions.Remove(r.Context(), sessionAttemptsKey)
	h.sessions.Put(r.Context(), sessionStageKey, stageIn)
	http.Redirect(w, r, "/platform/tenants", http.StatusSeeOther)
}

// showEnroll is compulsory: an admin without two-factor sign-in reaches no page
// but this one.
func (h *Handler) showEnroll(w http.ResponseWriter, r *http.Request) {
	h.renderEnroll(w, r, http.StatusOK, "")
}

func (h *Handler) renderEnroll(w http.ResponseWriter, r *http.Request, status int, message string) {
	adminID := h.sessions.GetString(r.Context(), sessionAdminKey)
	if h.stage(r) != stageEnroll || adminID == "" {
		http.Redirect(w, r, "/platform/login", http.StatusSeeOther)
		return
	}
	admin, err := h.svc.Admin(r.Context(), adminID)
	if err != nil || !admin.Active {
		_ = h.sessions.Destroy(r.Context())
		http.Redirect(w, r, "/platform/login", http.StatusSeeOther)
		return
	}

	secret, err := h.svc.BeginEnrollment(r.Context(), adminID)
	if errors.Is(err, domain.ErrTOTPAlreadyEnabled) {
		h.sessions.Put(r.Context(), sessionStageKey, stageVerify)
		http.Redirect(w, r, "/platform/login/verify", http.StatusSeeOther)
		return
	}
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	h.renderStatus(w, r, status, views.EnrollPage(csrf.Token(r), views.Enrollment{
		Email:  admin.Email,
		Secret: domain.GroupSecret(secret),
		URI:    domain.TOTPURI("JustClick", admin.Email, secret),
	}, message))
}

func (h *Handler) submitEnroll(w http.ResponseWriter, r *http.Request) {
	adminID := h.sessions.GetString(r.Context(), sessionAdminKey)
	if h.stage(r) != stageEnroll || adminID == "" {
		http.Redirect(w, r, "/platform/login", http.StatusSeeOther)
		return
	}
	if err := r.ParseForm(); err != nil {
		h.renderEnroll(w, r, http.StatusBadRequest, "Formulir tidak terbaca.")
		return
	}

	codes, err := h.svc.ConfirmEnrollment(r.Context(), adminID, r.PostFormValue("code"), clientIP(r))
	if errors.Is(err, domain.ErrInvalidCode) {
		h.renderEnroll(w, r, http.StatusUnauthorized, "Kode tidak cocok. Periksa jam ponsel dan secret yang diketik.")
		return
	}
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	if err := h.sessions.RenewToken(r.Context()); err != nil {
		h.serverError(w, r, err)
		return
	}
	h.sessions.Put(r.Context(), sessionStageKey, stageIn)

	// Rendered in this response and nowhere else: the codes are stored hashed,
	// so this is the only moment anyone can see them.
	h.render(w, r, views.RecoveryCodesPage(codes))
}

func (h *Handler) logout(w http.ResponseWriter, r *http.Request) {
	if err := h.sessions.Destroy(r.Context()); err != nil {
		h.serverError(w, r, err)
		return
	}
	http.Redirect(w, r, "/platform/login", http.StatusSeeOther)
}

// requireAdmin reloads the admin on every request: deactivating an account, or
// resetting its two-factor sign-in, takes effect on the next click.
func (h *Handler) requireAdmin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		adminID := h.sessions.GetString(r.Context(), sessionAdminKey)
		if h.stage(r) != stageIn || adminID == "" {
			http.Redirect(w, r, "/platform/login", http.StatusSeeOther)
			return
		}

		admin, err := h.svc.Admin(r.Context(), adminID)
		if err != nil || !admin.Active || !admin.TOTPEnabled {
			if err != nil && !errors.Is(err, domain.ErrNotFound) {
				h.logger.Error("reload platform admin", slog.Any("error", err))
			}
			_ = h.sessions.Destroy(r.Context())
			http.Redirect(w, r, "/platform/login", http.StatusSeeOther)
			return
		}

		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), adminKey, admin)))
	})
}
