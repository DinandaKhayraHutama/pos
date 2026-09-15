package backoffice

import (
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/staff"
)

// Credentials never come back out of these handlers. A PIN or password form
// is always re-rendered empty — even after a rejection — because echoing a
// credential into HTML puts it in the browser's history, its form cache and
// any screenshot of the page.

func profileForm(p staff.Profile) views.Form {
	f := views.NewForm()
	f.Values["name"] = p.Name
	f.Values["role"] = string(p.Role)
	f.Values["email"] = optionalString(p.Email)
	f.Values["sort_order"] = itoa(p.SortOrder)
	return f
}

func profileFromForm(f views.Form, id string) (staff.ProfileInput, *parser) {
	p := newParser(f)
	return staff.ProfileInput{
		ID:        id,
		Name:      p.text("name"),
		Role:      auth.Role(p.text("role")),
		Email:     p.optionalText("email"),
		SortOrder: p.integer("sort_order"),
	}, p
}

func (h *Handler) staffPage(w http.ResponseWriter, r *http.Request) {
	list, err := h.staff.List(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	h.render(w, r, views.StaffPage(h.sessionView(r), list))
}

func (h *Handler) newStaffPage(w http.ResponseWriter, r *http.Request) {
	f := views.NewForm()
	f.Values["role"] = string(auth.Cashier)
	h.render(w, r, views.StaffNewPage(h.sessionView(r), f))
}

func (h *Handler) createStaff(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}

	in, p := profileFromForm(f, "")
	err := p.errs.Err()
	var id string
	if err == nil {
		id, err = h.staff.Create(r.Context(), tenantOf(r), in, f.V("pin"))
	}
	if err == nil {
		redirect(w, r, "/backoffice/staff/"+id)
		return
	}
	if !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}

	delete(f.Values, "pin")
	h.render(w, r, views.StaffNewPage(h.sessionView(r), f))
}

func (h *Handler) staffMemberPage(w http.ResponseWriter, r *http.Request) {
	p, err := h.staff.Profile(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, staff.ErrNotFound) {
		return
	}

	h.render(w, r, views.StaffMemberPage(h.sessionView(r), p, p.ID == employeeFrom(r.Context()).ID, profileForm(p)))
}

func (h *Handler) updateStaff(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")

	in, p := profileFromForm(f, id)
	err := p.errs.Err()
	if err == nil {
		err = h.staff.Update(r.Context(), tenantOf(r), employeeFrom(r.Context()).ID, in)
	}
	if !absorb(&f, err) && h.failed(w, r, err, staff.ErrNotFound) {
		return
	}
	if err == nil {
		toast(w, "Profil disimpan.")
	}

	h.render(w, r, views.ProfileForm(id, f))
}

func (h *Handler) setStaffPIN(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")

	err := h.staff.SetPIN(r.Context(), tenantOf(r), id, f.V("pin"))
	if !absorb(&f, err) && h.failed(w, r, err, staff.ErrNotFound) {
		return
	}
	if err == nil {
		toast(w, "PIN diperbarui.")
	}

	delete(f.Values, "pin")
	h.render(w, r, views.PINForm(id, f, h.credentialSet(r, id, true)))
}

func (h *Handler) setStaffPassword(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")

	err := h.staff.SetPassword(r.Context(), tenantOf(r), id, f.V("password"))
	if !absorb(&f, err) && h.failed(w, r, err, staff.ErrNotFound) {
		return
	}
	if err == nil {
		toast(w, "Kata sandi diperbarui.")
	}

	delete(f.Values, "password")
	h.render(w, r, views.PasswordForm(id, f, h.credentialSet(r, id, false)))
}

func (h *Handler) setStaffActive(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	tenantID, id := tenantOf(r), chi.URLParam(r, "id")

	err := h.staff.SetActive(r.Context(), tenantID, employeeFrom(r.Context()).ID, id, f.Checked("active"))
	if !absorb(&f, err) && h.failed(w, r, err, staff.ErrNotFound) {
		return
	}

	p, loadErr := h.staff.Profile(r.Context(), tenantID, id)
	if h.failed(w, r, loadErr, staff.ErrNotFound) {
		return
	}
	if err == nil {
		if p.Active {
			toast(w, "Karyawan diaktifkan.")
		} else {
			toast(w, "Karyawan dinonaktifkan.")
		}
	}

	h.render(w, r, views.StaffActiveCard(p, id == employeeFrom(r.Context()).ID, f))
}

// credentialSet reads back whether a PIN (or password) is now stored, so the
// button says "change" or "set" from what is true rather than from what the
// last request hoped.
func (h *Handler) credentialSet(r *http.Request, id string, pin bool) bool {
	p, err := h.staff.Profile(r.Context(), tenantOf(r), id)
	if err != nil {
		return false
	}
	if pin {
		return p.HasPIN
	}
	return p.HasPassword
}
