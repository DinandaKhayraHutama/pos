package backoffice

import (
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
)

// Mirrors categories.go exactly — a brand is the same shape of flat master as
// a category, just optional on a product instead of required.

func brandForm(b catalogue.Brand) views.Form {
	f := views.NewForm()
	f.Values["name"] = b.Name
	f.Values["sort_order"] = itoa(b.SortOrder)
	return f
}

func brandFromForm(f views.Form, id string) (catalogue.Brand, *parser) {
	p := newParser(f)
	return catalogue.Brand{
		ID:        id,
		Name:      p.text("name"),
		SortOrder: p.integer("sort_order"),
	}, p
}

// brandOptions lists brands for the product form's select. withBlank's own
// label reads "— pilih kategori —", which is wrong for an optional field, so
// this prepends its own blank choice rather than reusing that helper.
func (h *Handler) brandOptions(r *http.Request) ([]views.Option, error) {
	rows, err := h.catalogue.Brands(r.Context(), tenantOf(r))
	if err != nil {
		return nil, err
	}

	out := make([]views.Option, 0, len(rows)+1)
	out = append(out, views.Option{Value: "", Label: "— tanpa brand —"})
	for _, b := range rows {
		out = append(out, views.Option{Value: b.ID, Label: b.Name})
	}
	return out, nil
}

func (h *Handler) brandsPage(w http.ResponseWriter, r *http.Request) {
	rows, err := h.catalogue.Brands(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	h.render(w, r, views.BrandsPage(h.sessionView(r), rows, views.NewForm()))
}

func (h *Handler) createBrand(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}

	in, p := brandFromForm(f, "")
	err := p.errs.Err()
	if err == nil {
		_, err = h.catalogue.SaveBrand(r.Context(), tenantOf(r), in)
	}

	if err != nil && !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}
	if err == nil {
		f = views.NewForm()
		toast(w, "Brand ditambahkan.")
	}

	rows, loadErr := h.catalogue.Brands(r.Context(), tenantOf(r))
	if loadErr != nil {
		h.serverError(w, r, loadErr)
		return
	}
	h.render(w, r, views.BrandsSection(rows, f))
}

func (h *Handler) brandPage(w http.ResponseWriter, r *http.Request) {
	b, err := h.catalogue.Brand(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	h.render(w, r, views.BrandPage(h.sessionView(r), b.ID, brandForm(b)))
}

func (h *Handler) updateBrand(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")

	in, p := brandFromForm(f, id)
	err := p.errs.Err()
	if err == nil {
		_, err = h.catalogue.SaveBrand(r.Context(), tenantOf(r), in)
	}
	if !absorb(&f, err) && h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}
	if err == nil {
		toast(w, "Brand disimpan.")
	}

	h.render(w, r, views.BrandForm(id, f))
}

func (h *Handler) deleteBrand(w http.ResponseWriter, r *http.Request) {
	err := h.catalogue.DeleteBrand(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if errors.Is(err, catalogue.ErrBrandInUse) {
		toastError(w, "Brand masih dipakai produk. Lepaskan brand dari produknya dulu.")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	redirect(w, r, "/backoffice/catalogue/brands")
}
