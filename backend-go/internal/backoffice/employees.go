package backoffice

import (
	"errors"
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
	f.Values["role"] = p.RoleID
	f.Values["email"] = optionalString(p.Email)
	f.Values["phone"] = optionalString(p.Phone)
	f.Values["sort_order"] = itoa(p.SortOrder)
	return f
}

func profileFromForm(f views.Form, id string) (staff.ProfileInput, *parser) {
	p := newParser(f)
	in := staff.ProfileInput{
		ID:        id,
		Name:      p.text("name"),
		RoleID:    p.text("role"),
		Email:     p.optionalText("email"),
		Phone:     p.optionalText("phone"),
		SortOrder: p.integer("sort_order"),
	}
	// The select posts a role row's id. A system role may still be named by
	// its key — what this form posted before Fase 3, and what scripts that
	// drive the panel still send — and the domain looks its row up.
	switch auth.Role(in.RoleID) {
	case auth.Cashier, auth.Manager, auth.Owner:
		in.Role, in.RoleID = auth.Role(in.RoleID), ""
	}
	return in, p
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
	for _, o := range h.roleOptions(r) {
		if o.System == string(auth.Cashier) {
			f.Values["role"] = o.Value
		}
	}
	h.render(w, r, views.StaffNewPage(h.sessionView(r), f, h.roleOptions(r)))
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
		id, err = h.staff.Create(r.Context(), tenantOf(r), employeeFrom(r.Context()).ID, in, f.V("pin"))
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
	h.render(w, r, views.StaffNewPage(h.sessionView(r), f, h.roleOptions(r)))
}

func (h *Handler) staffMemberPage(w http.ResponseWriter, r *http.Request) {
	p, err := h.staff.Profile(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, staff.ErrNotFound) {
		return
	}

	h.render(w, r, views.StaffMemberPage(h.sessionView(r), p, p.ID == employeeFrom(r.Context()).ID, profileForm(p), h.roleOptions(r)))
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

	h.render(w, r, views.ProfileForm(id, f, h.roleOptions(r)))
}

func (h *Handler) setStaffPIN(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")

	err := h.staff.SetPIN(r.Context(), tenantOf(r), employeeFrom(r.Context()).ID, id, f.V("pin"))
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

	err := h.staff.SetPassword(r.Context(), tenantOf(r), employeeFrom(r.Context()).ID, id, f.V("password"))
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

// roleOptions is the role select: every live role, built-in first. A failure
// to list them renders an empty select rather than a 500 — the form's own
// validation then says "pilih peran".
func (h *Handler) roleOptions(r *http.Request) []views.Option {
	roles, err := h.staff.ListRoles(r.Context(), tenantOf(r))
	if err != nil {
		h.logger.Warn("list roles for the staff form", "error", err)
		return nil
	}
	out := make([]views.Option, 0, len(roles))
	for _, role := range roles {
		o := views.Option{Value: role.ID, Label: role.Name}
		if role.SystemKey != nil {
			o.System = *role.SystemKey
		}
		out = append(out, o)
	}
	return out
}

func roleForm(role staff.RoleInfo) views.Form {
	f := views.NewForm()
	f.Values["name"] = role.Name
	f.Values["sort_order"] = itoa(role.SortOrder)
	if role.Access.POS {
		f.Values["pos_access"] = "on"
	}
	if role.Access.Backoffice {
		f.Values["backoffice_access"] = "on"
	}
	for _, p := range role.Permission {
		f.Multi["permissions"] = append(f.Multi["permissions"], string(p))
	}
	return f
}

func roleFromForm(f views.Form, id string) (staff.RoleInput, *parser) {
	p := newParser(f)
	return staff.RoleInput{
		ID:          id,
		Name:        p.text("name"),
		Permissions: f.Multi["permissions"],
		POS:         p.check("pos_access"),
		Backoffice:  p.check("backoffice_access"),
		SortOrder:   p.integer("sort_order"),
	}, p
}

func (h *Handler) rolesPage(w http.ResponseWriter, r *http.Request) {
	roles, err := h.staff.ListRoles(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.RolesPage(h.sessionView(r), roles))
}

func (h *Handler) newRolePage(w http.ResponseWriter, r *http.Request) {
	f := views.NewForm()
	f.Values["pos_access"] = "on"
	h.render(w, r, views.RoleNewPage(h.sessionView(r), f))
}

func (h *Handler) createRole(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r, "permissions")
	if !ok {
		return
	}
	in, p := roleFromForm(f, "")
	err := p.errs.Err()
	var id string
	if err == nil {
		id, err = h.staff.SaveRole(r.Context(), tenantOf(r), employeeFrom(r.Context()).ID, in)
	}
	if err == nil {
		redirect(w, r, "/backoffice/staff/roles/"+id)
		return
	}
	if !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.RoleForm("", f))
}

func (h *Handler) rolePage(w http.ResponseWriter, r *http.Request) {
	role, err := h.staff.Role(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, staff.ErrNotFound) {
		return
	}
	h.render(w, r, views.RolePage(h.sessionView(r), role, roleForm(role)))
}

func (h *Handler) updateRole(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r, "permissions")
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")
	in, p := roleFromForm(f, id)
	err := p.errs.Err()
	if err == nil {
		_, err = h.staff.SaveRole(r.Context(), tenantOf(r), employeeFrom(r.Context()).ID, in)
	}
	if errors.Is(err, staff.ErrSystemRole) {
		f.Errors["permissions"] = "Peran bawaan tidak bisa diubah."
		err = nil
	} else if !absorb(&f, err) && h.failed(w, r, err, staff.ErrNotFound) {
		return
	} else if err == nil {
		toast(w, "Peran disimpan.")
	}
	h.render(w, r, views.RoleForm(id, f))
}

func (h *Handler) deleteRole(w http.ResponseWriter, r *http.Request) {
	err := h.staff.DeleteRole(r.Context(), tenantOf(r), employeeFrom(r.Context()).ID, chi.URLParam(r, "id"))
	switch {
	case errors.Is(err, staff.ErrRoleInUse):
		toast(w, "Peran masih dipakai karyawan.")
		w.WriteHeader(http.StatusConflict)
		return
	case errors.Is(err, staff.ErrSystemRole):
		toast(w, "Peran bawaan tidak bisa dihapus.")
		w.WriteHeader(http.StatusConflict)
		return
	}
	if h.failed(w, r, err, staff.ErrNotFound) {
		return
	}
	redirect(w, r, "/backoffice/staff/roles")
}
