package backoffice

import (
	"context"
	"errors"
	"log/slog"
	"net/http"

	"github.com/gorilla/csrf"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/staff"
)

func (h *Handler) showLogin(w http.ResponseWriter, r *http.Request) {
	if h.sessions.GetString(r.Context(), sessionEmployeeKey) != "" {
		http.Redirect(w, r, "/backoffice/devices", http.StatusSeeOther)
		return
	}

	h.render(w, r, views.LoginPage(csrf.Token(r), "", ""))
}

func (h *Handler) submitLogin(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		h.render(w, r, views.LoginPage(csrf.Token(r), "", "Formulir tidak terbaca."))
		return
	}

	email := r.PostFormValue("email")

	employee, err := h.staff.Authenticate(r.Context(), email, r.PostFormValue("password"))
	if err != nil {
		if !errors.Is(err, staff.ErrInvalidCredentials) {
			h.logger.Error("backoffice login", slog.Any("error", err))
		}

		// One message for every failure. Saying which half was wrong turns this
		// form into a way to find out who has an account.
		h.renderStatus(w, r, http.StatusUnauthorized,
			views.LoginPage(csrf.Token(r), email, "Email atau kata sandi salah."))
		return
	}

	// A new session id on privilege change, so a token an attacker planted in
	// the browser beforehand is not the one that ends up authenticated.
	if err := h.sessions.RenewToken(r.Context()); err != nil {
		h.serverError(w, r, err)
		return
	}

	h.sessions.Put(r.Context(), sessionEmployeeKey, employee.ID)
	h.sessions.Put(r.Context(), sessionTenantKey, employee.TenantID)

	http.Redirect(w, r, "/backoffice/devices", http.StatusSeeOther)
}

func (h *Handler) logout(w http.ResponseWriter, r *http.Request) {
	if err := h.sessions.Destroy(r.Context()); err != nil {
		h.serverError(w, r, err)
		return
	}

	http.Redirect(w, r, "/backoffice/login", http.StatusSeeOther)
}

// requireEmployee reloads the account on every request rather than trusting
// what was true at sign-in: deactivating someone must take effect on their
// next click, not when their session happens to expire.
func (h *Handler) requireEmployee(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		employeeID := h.sessions.GetString(r.Context(), sessionEmployeeKey)
		tenantID := h.sessions.GetString(r.Context(), sessionTenantKey)

		if employeeID == "" || tenantID == "" {
			http.Redirect(w, r, "/backoffice/login", http.StatusSeeOther)
			return
		}

		employee, err := h.staff.ByID(r.Context(), tenantID, employeeID)
		if err != nil || !employee.Active || !employee.Role.UsesBackoffice() {
			h.sessions.Destroy(r.Context())
			http.Redirect(w, r, "/backoffice/login", http.StatusSeeOther)
			return
		}

		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), employeeKey, employee)))
	})
}

func (h *Handler) require(permission auth.Permission) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !employeeFrom(r.Context()).Can(permission) {
				if isHX(r) {
					h.renderStatus(w, r, http.StatusForbidden,
						views.ErrorCard("Anda tidak punya izin untuk tindakan ini."))
					return
				}
				h.renderStatus(w, r, http.StatusForbidden, views.MessagePage(h.sessionView(r),
					"Tidak diizinkan", "Peran Anda tidak punya izin untuk membuka halaman ini."))
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

// sessionView is what every page shell needs. The nav is built from the same
// permissions the routes check, so a link never leads to a 403 and a section
// someone may open is never missing from the menu.
func (h *Handler) sessionView(r *http.Request) views.Session {
	employee := employeeFrom(r.Context())

	return views.Session{
		EmployeeName: employee.Name,
		Role:         string(employee.Role),
		BusinessName: employee.BusinessName,
		CSRFToken:    csrf.Token(r),
		CanCatalogue: employee.Can(auth.ManageCatalogue),
		CanPromos:    employee.Can(auth.ManagePromos),
		CanStaff:     employee.Can(auth.ManageEmployees),
		CanOutlets:   employee.Can(auth.ManageOutlets),
		CanStock:     employee.Can(auth.AdjustStock),
		CanDashboard: h.reports != nil && employee.Can(auth.ViewDailySummary),
		CanReports:   h.reports != nil && employee.Can(auth.ViewFinancialReports),
	}
}
