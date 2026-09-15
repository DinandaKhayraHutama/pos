package backoffice

import (
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/outlets"
)

func outletForm(o outlets.Outlet) views.Form {
	f := views.NewForm()
	f.Values["name"] = o.Name
	f.Values["address"] = optionalString(o.Address)
	f.Values["phone"] = optionalString(o.Phone)
	f.Values["sort_order"] = itoa(o.SortOrder)
	return f
}

func (h *Handler) outletsPage(w http.ResponseWriter, r *http.Request) {
	list, err := h.outlets.List(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	h.render(w, r, views.OutletsPage(h.sessionView(r), list, views.NewForm()))
}

func (h *Handler) createOutlet(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}

	p := newParser(f)
	in := outlets.Outlet{
		Name: p.text("name"), Address: p.optionalText("address"), Phone: p.optionalText("phone"),
		Active: true,
	}
	err := p.errs.Err()
	if err == nil {
		_, err = h.outlets.SaveOutlet(r.Context(), tenantOf(r), in)
	}
	if err != nil && !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}
	if err == nil {
		f = views.NewForm()
		toast(w, "Outlet ditambahkan.")
	}

	list, loadErr := h.outlets.List(r.Context(), tenantOf(r))
	if loadErr != nil {
		h.serverError(w, r, loadErr)
		return
	}
	h.render(w, r, views.OutletsSection(list, f))
}

func (h *Handler) outletPage(w http.ResponseWriter, r *http.Request) {
	o, err := h.outlets.Get(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, outlets.ErrNotFound) {
		return
	}

	h.render(w, r, views.OutletPage(h.sessionView(r), o, outletForm(o)))
}

func (h *Handler) updateOutlet(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	tenantID, id := tenantOf(r), chi.URLParam(r, "id")

	// The switch has its own control, so an edit carries the current state
	// rather than whatever a stale form would imply.
	current, err := h.outlets.Get(r.Context(), tenantID, id)
	if h.failed(w, r, err, outlets.ErrNotFound) {
		return
	}

	p := newParser(f)
	in := outlets.Outlet{
		ID: id, Name: p.text("name"), Address: p.optionalText("address"), Phone: p.optionalText("phone"),
		SortOrder: p.integer("sort_order"), Active: current.Active,
	}
	err = p.errs.Err()
	if err == nil {
		_, err = h.outlets.SaveOutlet(r.Context(), tenantID, in)
	}
	if !absorb(&f, err) && h.failed(w, r, err, outlets.ErrNotFound) {
		return
	}
	if err == nil {
		toast(w, "Outlet disimpan.")
	}

	h.render(w, r, views.OutletForm(id, f))
}

func (h *Handler) setOutletActive(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	tenantID, id := tenantOf(r), chi.URLParam(r, "id")

	err := h.outlets.SetOutletActive(r.Context(), tenantID, id, f.Checked("active"))
	if h.failed(w, r, err, outlets.ErrNotFound) {
		return
	}

	o, err := h.outlets.Get(r.Context(), tenantID, id)
	if h.failed(w, r, err, outlets.ErrNotFound) {
		return
	}

	if o.Active {
		toast(w, "Outlet diaktifkan.")
	} else {
		toast(w, "Outlet dinonaktifkan. Till di dalamnya berhenti.")
	}
	h.render(w, r, views.OutletActiveCard(o))
}

func (h *Handler) saveRegister(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	tenantID, outletID, registerID := tenantOf(r), chi.URLParam(r, "id"), chi.URLParam(r, "registerID")

	active := true
	if registerID != "" {
		current, err := h.outlets.Register(r.Context(), tenantID, registerID)
		if h.failed(w, r, err, outlets.ErrNotFound) {
			return
		}
		active = current.Active
	}

	p := newParser(f)
	in := outlets.Register{
		ID: registerID, OutletID: outletID, Name: p.text("name"),
		TableService: p.check("table_service"), SortOrder: p.integer("sort_order"), Active: active,
	}
	err := p.errs.Err()
	if err == nil {
		_, err = h.outlets.SaveRegister(r.Context(), tenantID, in)
	}
	if !absorb(&f, err) && h.failed(w, r, err, outlets.ErrNotFound) {
		return
	}

	failed := ""
	if err != nil {
		failed = registerID
		if failed == "" {
			failed = "new"
		}
	} else {
		f = views.NewForm()
		toast(w, "Till disimpan.")
	}

	h.renderRegisters(w, r, outletID, failed, f)
}

func (h *Handler) setRegisterActive(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	outletID := chi.URLParam(r, "id")

	err := h.outlets.SetRegisterActive(r.Context(), tenantOf(r), chi.URLParam(r, "registerID"), f.Checked("active"))
	if h.failed(w, r, err, outlets.ErrNotFound) {
		return
	}

	if f.Checked("active") {
		toast(w, "Till diaktifkan.")
	} else {
		toast(w, "Till dinonaktifkan. Tablet yang terikat berhenti.")
	}
	h.renderRegisters(w, r, outletID, "", views.NewForm())
}

func (h *Handler) renderRegisters(w http.ResponseWriter, r *http.Request, outletID, failed string, f views.Form) {
	o, err := h.outlets.Get(r.Context(), tenantOf(r), outletID)
	if h.failed(w, r, err, outlets.ErrNotFound) {
		return
	}

	h.render(w, r, views.RegistersCard(o, failed, f))
}
