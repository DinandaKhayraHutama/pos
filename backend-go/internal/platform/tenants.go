package platform

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	bo "github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/entitlements"
	domain "github.com/daniryckidinata/nti_pos/backend-go/internal/domain/platform"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/tenancy"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/platform/views"
)

const tenantsPerPage = 25

func (h *Handler) parseForm(w http.ResponseWriter, r *http.Request) (bo.Form, bool) {
	if err := r.ParseForm(); err != nil {
		h.renderStatus(w, r, http.StatusBadRequest,
			views.MessagePage(h.sessionView(r), "Ditolak", "Formulir tidak terbaca."))
		return bo.Form{}, false
	}
	f := bo.NewForm()
	for key, values := range r.PostForm {
		if len(values) > 0 {
			f.Values[key] = values[0]
		}
	}
	return f, true
}

// optionalLimit reads a limit; blank is unlimited.
func optionalLimit(f bo.Form, name string, errs validation.Errors) *int {
	raw := strings.TrimSpace(f.V(name))
	if raw == "" {
		return nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		errs.Add(name, "Harus angka bulat, atau kosong untuk tanpa batas.")
		return nil
	}
	return &n
}

func absorb(f *bo.Form, err error) bool {
	fields, ok := validation.As(err)
	if !ok {
		return false
	}
	for k, v := range fields {
		f.Errors[k] = v
	}
	return true
}

func limitValue(p *int) string {
	if p == nil {
		return ""
	}
	return strconv.Itoa(*p)
}

func limitsForm(l entitlements.Limits) bo.Form {
	f := bo.NewForm()
	f.Values["max_outlets"] = limitValue(l.MaxOutlets)
	f.Values["max_registers"] = limitValue(l.MaxRegisters)
	f.Values["max_active_devices"] = limitValue(l.MaxActiveDevices)
	return f
}

func (h *Handler) tenantsPage(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	page, _ := strconv.Atoi(q.Get("page"))
	page = max(page, 1)

	filter := domain.TenantFilter{
		Search: q.Get("q"), Status: q.Get("status"),
		Offset: (page - 1) * tenantsPerPage, Limit: tenantsPerPage,
	}
	list, more, err := h.svc.Tenants(r.Context(), filter)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.TenantsPage(h.sessionView(r), views.TenantsView{
		Tenants: list, Search: filter.Search, Status: filter.Status, Page: page, More: more,
	}))
}

func (h *Handler) newTenantPage(w http.ResponseWriter, r *http.Request) {
	f := bo.NewForm()
	f.Values["timezone"] = tenancy.DefaultTimezone
	h.render(w, r, views.NewTenantPage(h.sessionView(r), f))
}

func (h *Handler) createTenant(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}

	errs := validation.Errors{}
	in := domain.OnboardInput{
		BusinessName:     f.V("business_name"),
		Slug:             f.V("slug"),
		OwnerName:        f.V("owner_name"),
		OwnerEmail:       f.V("owner_email"),
		Timezone:         f.V("timezone"),
		MaxOutlets:       optionalLimit(f, "max_outlets", errs),
		MaxRegisters:     optionalLimit(f, "max_registers", errs),
		MaxActiveDevices: optionalLimit(f, "max_active_devices", errs),
	}
	err := errs.Err()
	var out domain.Onboarded
	if err == nil {
		out, err = h.svc.Onboard(r.Context(), h.actor(r), in)
	}
	if absorb(&f, err) {
		h.render(w, r, views.NewTenantPage(h.sessionView(r), f))
		return
	}
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	// Not a redirect: when the link could not be mailed, this response is the
	// only place it is ever shown.
	h.render(w, r, views.OnboardedPage(h.sessionView(r), strings.TrimSpace(in.BusinessName), out))
}

func (h *Handler) tenantPage(w http.ResponseWriter, r *http.Request) {
	h.renderTenant(w, r, http.StatusOK, views.TenantForms{})
}

// renderTenant draws a merchant's page, with whichever of its forms was just
// refused kept as typed.
func (h *Handler) renderTenant(w http.ResponseWriter, r *http.Request, status int, forms views.TenantForms) {
	d, err := h.svc.Tenant(r.Context(), chi.URLParam(r, "id"))
	if h.failed(w, r, err) {
		return
	}
	if forms.Limits.Values == nil {
		forms.Limits = limitsForm(d.Limits)
	}
	forms.Flash = h.sessions.PopString(r.Context(), sessionFlashKey)
	h.renderStatus(w, r, status, views.TenantPage(h.sessionView(r), d, forms))
}

// done records what happened and returns to the merchant's page, so a reload
// does not post the form again.
func (h *Handler) done(w http.ResponseWriter, r *http.Request, message string) {
	h.sessions.Put(r.Context(), sessionFlashKey, message)
	http.Redirect(w, r, "/platform/tenants/"+chi.URLParam(r, "id"), http.StatusSeeOther)
}

func (h *Handler) suspendTenant(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	err := h.svc.Suspend(r.Context(), h.actor(r), chi.URLParam(r, "id"), f.V("reason"), f.V("confirm_slug"))
	if absorb(&f, err) {
		h.renderTenant(w, r, http.StatusOK, views.TenantForms{Suspend: f})
		return
	}
	if h.failed(w, r, err) {
		return
	}
	h.done(w, r, "Perusahaan disuspend. Backoffice dan semua till-nya berhenti sekarang.")
}

func (h *Handler) reactivateTenant(w http.ResponseWriter, r *http.Request) {
	if h.failed(w, r, h.svc.Reactivate(r.Context(), h.actor(r), chi.URLParam(r, "id"))) {
		return
	}
	h.done(w, r, "Perusahaan diaktifkan kembali. Till kembali bekerja dengan token yang sama.")
}

func (h *Handler) saveLimits(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	errs := validation.Errors{}
	limits := entitlements.Limits{
		MaxOutlets:       optionalLimit(f, "max_outlets", errs),
		MaxRegisters:     optionalLimit(f, "max_registers", errs),
		MaxActiveDevices: optionalLimit(f, "max_active_devices", errs),
	}
	err := errs.Err()
	if err == nil {
		err = h.svc.SetLimits(r.Context(), h.actor(r), chi.URLParam(r, "id"), limits)
	}
	if absorb(&f, err) {
		h.renderTenant(w, r, http.StatusOK, views.TenantForms{Limits: f})
		return
	}
	if h.failed(w, r, err) {
		return
	}
	h.done(w, r, "Batas paket disimpan.")
}

func (h *Handler) saveFlags(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	enabled := map[entitlements.Flag]bool{}
	for _, flag := range entitlements.AllFlags {
		enabled[flag] = f.Checked("flag_" + string(flag))
	}
	if h.failed(w, r, h.svc.SetFlags(r.Context(), h.actor(r), chi.URLParam(r, "id"), enabled)) {
		return
	}
	h.done(w, r, "Modul disimpan.")
}

func (h *Handler) reissueSetupLink(w http.ResponseWriter, r *http.Request) {
	tenantID := chi.URLParam(r, "id")
	link, err := h.svc.ReissueSetupLink(r.Context(), h.actor(r), tenantID, chi.URLParam(r, "employeeID"))
	if h.failed(w, r, err) {
		return
	}
	h.render(w, r, views.SetupLinkPage(h.sessionView(r), tenantID, link))
}

func (h *Handler) startImpersonation(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	handoff, err := h.svc.StartImpersonation(r.Context(), h.actor(r), chi.URLParam(r, "id"), f.V("employee_id"), f.V("reason"))
	if absorb(&f, err) {
		h.renderTenant(w, r, http.StatusOK, views.TenantForms{Impersonate: f})
		return
	}
	if h.failed(w, r, err) {
		return
	}
	// The page posts the one-time token to the Backoffice by itself; the token
	// travels in a form body, never in a URL that history or a log keeps.
	h.render(w, r, views.HandoffPage(handoff.Token))
}

func (h *Handler) auditPage(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	filter := domain.AuditFilter{TenantID: q.Get("tenant"), Action: q.Get("action"), Limit: 50}
	if before, err := time.Parse(time.RFC3339Nano, q.Get("before")); err == nil {
		filter.Before = before
	}

	rows, err := h.svc.Audit(r.Context(), filter)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	v := views.AuditView{Rows: rows, Tenant: filter.TenantID, Action: filter.Action}
	if len(rows) == filter.Limit {
		v.Next = rows[len(rows)-1].At.Format(time.RFC3339Nano)
	}
	h.render(w, r, views.AuditPage(h.sessionView(r), v))
}

func (h *Handler) opsPage(w http.ResponseWriter, r *http.Request) {
	h.render(w, r, views.OpsPage(h.sessionView(r), h.svc.Ops(r.Context())))
}
