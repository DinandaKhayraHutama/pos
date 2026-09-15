package backoffice

import (
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/promos"
)

func promoForm(p promos.Promo) views.Form {
	f := views.NewForm()
	f.Values["name"] = p.Name
	f.Values["kind"] = p.Kind
	f.Values["value"] = i64toa(p.Value)
	f.Values["min_spend"] = i64toa(p.MinSpend)
	f.Values["sort_order"] = itoa(p.SortOrder)
	f.Values["active"] = checkbox(p.Active)
	f.Values["all_outlets"] = checkbox(p.AllOutlets)
	f.Multi["outlets"] = p.OutletIDs
	return f
}

func promoFromForm(f views.Form, id string) (promos.Promo, *parser) {
	p := newParser(f)

	in := promos.Promo{
		ID:         id,
		Name:       p.text("name"),
		Kind:       p.text("kind"),
		MinSpend:   p.money("min_spend"),
		SortOrder:  p.integer("sort_order"),
		Active:     p.check("active"),
		AllOutlets: p.check("all_outlets"),
		OutletIDs:  f.Multi["outlets"],
	}

	// A percentage and an amount are both whole numbers, but only an amount is
	// written with thousands separators; either way the domain checks range.
	if in.Kind == promos.KindPercent {
		in.Value = int64(p.integer("value"))
	} else {
		in.Value = p.money("value")
	}

	return in, p
}

func (h *Handler) outletOptions(r *http.Request) ([]views.Option, error) {
	list, err := h.outlets.List(r.Context(), tenantOf(r))
	if err != nil {
		return nil, err
	}

	out := make([]views.Option, 0, len(list))
	for _, o := range list {
		label := o.Name
		if !o.Active {
			label += " (nonaktif)"
		}
		out = append(out, views.Option{Value: o.ID, Label: label})
	}
	return out, nil
}

func (h *Handler) promosPage(w http.ResponseWriter, r *http.Request) {
	list, err := h.promos.List(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	h.render(w, r, views.PromosPage(h.sessionView(r), list))
}

func (h *Handler) newPromoPage(w http.ResponseWriter, r *http.Request) {
	outlets, err := h.outletOptions(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	f := views.NewForm()
	f.Values["kind"] = promos.KindPercent
	f.Values["active"] = "on"
	f.Values["all_outlets"] = "on"
	h.render(w, r, views.PromoNewPage(h.sessionView(r), outlets, f))
}

func (h *Handler) createPromo(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r, "outlets")
	if !ok {
		return
	}

	in, p := promoFromForm(f, "")
	err := p.errs.Err()
	var id string
	if err == nil {
		id, err = h.promos.Save(r.Context(), tenantOf(r), in)
	}
	if err == nil {
		redirect(w, r, "/backoffice/promos/"+id)
		return
	}
	if !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}

	h.renderPromoForm(w, r, "/backoffice/promos", f)
}

func (h *Handler) promoPage(w http.ResponseWriter, r *http.Request) {
	p, err := h.promos.Get(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, promos.ErrNotFound) {
		return
	}

	outlets, err := h.outletOptions(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	h.render(w, r, views.PromoPage(h.sessionView(r), p.ID, outlets, promoForm(p)))
}

func (h *Handler) updatePromo(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r, "outlets")
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")

	in, p := promoFromForm(f, id)
	err := p.errs.Err()
	if err == nil {
		_, err = h.promos.Save(r.Context(), tenantOf(r), in)
	}
	if !absorb(&f, err) && h.failed(w, r, err, promos.ErrNotFound) {
		return
	}
	if err == nil {
		toast(w, "Promo disimpan.")
	}

	h.renderPromoForm(w, r, "/backoffice/promos/"+id, f)
}

func (h *Handler) renderPromoForm(w http.ResponseWriter, r *http.Request, action string, f views.Form) {
	outlets, err := h.outletOptions(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	h.render(w, r, views.PromoForm(action, outlets, f))
}

func (h *Handler) deletePromo(w http.ResponseWriter, r *http.Request) {
	err := h.promos.Delete(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, promos.ErrNotFound) {
		return
	}

	redirect(w, r, "/backoffice/promos")
}
