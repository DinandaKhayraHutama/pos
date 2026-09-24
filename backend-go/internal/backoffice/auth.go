package backoffice

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5/middleware"
	"github.com/gorilla/csrf"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/entitlements"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/platform"
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

	if err := h.signIn(r, employee); err != nil {
		h.serverError(w, r, err)
		return
	}

	http.Redirect(w, r, "/backoffice/devices", http.StatusSeeOther)
}

// signIn starts a normal session for an employee. A new session id on
// privilege change, so a token an attacker planted in the browser beforehand
// is not the one that ends up authenticated — and so a session that was an
// impersonation does not carry that over.
func (h *Handler) signIn(r *http.Request, employee staff.Employee) error {
	if err := h.sessions.RenewToken(r.Context()); err != nil {
		return err
	}
	h.sessions.Remove(r.Context(), sessionImpersonationKey)
	h.sessions.Put(r.Context(), sessionEmployeeKey, employee.ID)
	h.sessions.Put(r.Context(), sessionTenantKey, employee.TenantID)
	return nil
}

func (h *Handler) logout(w http.ResponseWriter, r *http.Request) {
	if id := h.sessions.GetString(r.Context(), sessionImpersonationKey); id != "" && h.impersonations != nil {
		if err := h.impersonations.EndImpersonation(r.Context(), id, "logout", clientIP(r)); err != nil {
			h.logger.Error("end impersonation on logout", slog.Any("error", err))
		}
	}
	if err := h.sessions.Destroy(r.Context()); err != nil {
		h.serverError(w, r, err)
		return
	}

	http.Redirect(w, r, "/backoffice/login", http.StatusSeeOther)
}

// requireEmployee reloads the account on every request rather than trusting
// what was true at sign-in: deactivating someone must take effect on their
// next click, not when their session happens to expire.
//
// An impersonated session is re-checked the same way: it ends when it expires,
// when the admin who holds it is deactivated, and when the merchant is
// suspended — each on the next click.
func (h *Handler) requireEmployee(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		employeeID := h.sessions.GetString(r.Context(), sessionEmployeeKey)
		tenantID := h.sessions.GetString(r.Context(), sessionTenantKey)

		if employeeID == "" || tenantID == "" {
			http.Redirect(w, r, "/backoffice/login", http.StatusSeeOther)
			return
		}

		employee, err := h.staff.ByID(r.Context(), tenantID, employeeID)
		if err != nil || !employee.Active || !employee.Access.Backoffice {
			h.sessions.Destroy(r.Context())
			http.Redirect(w, r, "/backoffice/login", http.StatusSeeOther)
			return
		}
		ctx := context.WithValue(r.Context(), employeeKey, employee)

		if id := h.sessions.GetString(r.Context(), sessionImpersonationKey); id != "" {
			imp, err := h.activeImpersonation(r.Context(), id, tenantID, employeeID)
			if err != nil {
				// Fail closed: a session that says it is an impersonation and
				// cannot prove it is still valid is not let in as the owner.
				if !errors.Is(err, platform.ErrImpersonationInvalid) {
					h.logger.Error("check impersonation", slog.Any("error", err))
				}
				h.sessions.Destroy(r.Context())
				h.renderStatus(w, r, http.StatusUnauthorized, views.PublicMessage("Impersonasi berakhir",
					"Sesi support ini sudah berakhir. Mulai lagi dari panel platform bila masih diperlukan."))
				return
			}
			ctx = context.WithValue(ctx, impersonationKey, imp)
		}

		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func (h *Handler) activeImpersonation(ctx context.Context, id, tenantID, employeeID string) (platform.Impersonation, error) {
	if h.impersonations == nil {
		return platform.Impersonation{}, platform.ErrImpersonationInvalid
	}
	return h.impersonations.ActiveImpersonation(ctx, id, tenantID, employeeID)
}

func impersonationFrom(ctx context.Context) (platform.Impersonation, bool) {
	imp, ok := ctx.Value(impersonationKey).(platform.Impersonation)
	return imp, ok
}

// auditImpersonatedWrites writes the audit row for a change made under
// impersonation BEFORE the change runs, and refuses the change when the row
// cannot be written. Reads are not recorded: the impersonation itself already
// is, with its reason.
func (h *Handler) auditImpersonatedWrites(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		imp, ok := impersonationFrom(r.Context())
		if !ok || r.Method == http.MethodGet || r.Method == http.MethodHead || r.Method == http.MethodOptions {
			next.ServeHTTP(w, r)
			return
		}

		if err := h.impersonations.RecordImpersonatedRequest(r.Context(), imp, r.Method, r.URL.Path, clientIP(r)); err != nil {
			h.logger.Error("audit impersonated request; refusing it", slog.Any("error", err))
			toastError(w, "Perubahan tidak dijalankan: jejak audit impersonasi gagal ditulis.")
			h.renderStatus(w, r, http.StatusServiceUnavailable,
				views.ErrorCard("Perubahan tidak dijalankan: jejak audit impersonasi gagal ditulis."))
			return
		}
		next.ServeHTTP(w, r)
	})
}

// refuseWhileImpersonating guards the two ways to take an account over. An
// owner locked out gets a fresh sign-in link from the platform panel instead;
// support never learns or sets anyone's credentials.
func (h *Handler) refuseWhileImpersonating(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, ok := impersonationFrom(r.Context()); ok {
			h.renderStatus(w, r, http.StatusForbidden, views.ErrorCard(
				"Kata sandi dan PIN tidak bisa diubah saat impersonasi. Terbitkan tautan setel kata sandi dari panel platform."))
			return
		}
		next.ServeHTTP(w, r)
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

// requireFeature closes a module the merchant has not been sold. It answers
// "not found" rather than "forbidden": the module does not exist for this
// merchant, and the nav — built from the same switch — never links to it.
func (h *Handler) requireFeature(f entitlements.Flag) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !employeeFrom(r.Context()).Has(f) {
				h.notFound(w, r)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// sessionView is what every page shell needs. The nav is built from the same
// permissions and module switches the routes check, so a link never leads to a
// 403 or a 404, and a section someone may open is never missing from the menu.
func (h *Handler) sessionView(r *http.Request) views.Session {
	employee := employeeFrom(r.Context())

	s := views.Session{
		EmployeeName:    employee.Name,
		Role:            roleDisplay(employee),
		BusinessName:    employee.BusinessName,
		CSRFToken:       csrf.Token(r),
		Path:            r.URL.Path,
		CanCatalogue:    employee.Can(auth.ManageCatalogue),
		CanCustomers:    h.customers != nil && employee.Can(auth.ManageCustomers),
		CanPromos:       employee.Can(auth.ManagePromos) && employee.Has(entitlements.Promos),
		CanDiscounts:    employee.Can(auth.ManagePromos),
		CanSettings:     h.settings != nil && h.payments != nil && employee.Can(auth.ManageSettings),
		CanStaff:        employee.Can(auth.ManageEmployees),
		CanOutlets:      employee.Can(auth.ManageOutlets),
		CanStock:        employee.Can(auth.AdjustStock) && employee.Has(entitlements.Stock),
		CanDashboard:    h.reports != nil && employee.Can(auth.ViewDailySummary),
		CanReports:      h.reports != nil && employee.Can(auth.ViewFinancialReports),
		CanTransactions: h.history != nil && h.reports != nil && employee.Can(auth.ViewAllOrders),
		CanShifts:       h.history != nil && h.reports != nil && employee.Can(auth.ViewCashDrawer),
		CanTables:       employee.Can(auth.ManageOutlets) && employee.Has(entitlements.Tables),
		CanExports: h.reports != nil && employee.Can(auth.ViewFinancialReports) &&
			employee.Has(entitlements.ReportExports),
	}

	if imp, ok := impersonationFrom(r.Context()); ok {
		minutes := max(int(time.Until(imp.ExpiresAt).Round(time.Minute).Minutes()), 0)
		s.Impersonation = &views.ImpersonationBanner{
			AdminName:    imp.AdminName,
			EmployeeName: imp.EmployeeName,
			Reason:       imp.Reason,
			EndsAt:       fmt.Sprintf("dalam %d menit", minutes),
		}
	}
	return s
}

func clientIP(r *http.Request) string {
	if ip := middleware.GetClientIP(r.Context()); ip != "" {
		return ip
	}
	return r.RemoteAddr
}

// roleDisplay is what the header says someone is: the built-in role's key,
// which RoleLabel translates, or a custom role's own name.
func roleDisplay(e staff.Employee) string {
	if e.Access.System != "" {
		return string(e.Access.System)
	}
	return e.RoleName
}
