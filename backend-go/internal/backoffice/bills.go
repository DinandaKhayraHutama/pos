package backoffice

import (
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/history"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
)

// Saved bills (Fase 4 paritas), read-only. The list defaults to what is open
// right now across every outlet — the backlog a manager checks mid-service —
// and a date range applies only when looking back at settled or cancelled
// bills.

func (h *Handler) billsPage(w http.ResponseWriter, r *http.Request) {
	v, err := h.billsView(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	if r.Header.Get("HX-Request") == "true" {
		h.render(w, r, views.BillsTable(v))
		return
	}
	h.render(w, r, views.BillsPage(h.sessionView(r), v))
}

func (h *Handler) billsView(r *http.Request) (views.BillsView, error) {
	ctx, tenantID := r.Context(), tenantOf(r)
	q := r.URL.Query()
	f := history.BillFilter{
		OutletID: strings.TrimSpace(q.Get("outlet")),
		Status:   strings.TrimSpace(q.Get("status")),
		Cursor:   q.Get("cursor"),
	}
	if f.Status == "" {
		f.Status = history.BillsOpen
	}
	v := views.BillsView{Filter: f, Form: views.NewForm()}
	if f.Status != history.BillsOpen {
		from, to, err := h.historyRange(r)
		if err != nil {
			return v, err
		}
		f.From, f.To = from, to
		v.Filter = f
		v.Form.Values["from"] = views.DateValue(from)
		v.Form.Values["to"] = views.DateValue(to)
	} else {
		v.Form.Values["from"] = q.Get("from")
		v.Form.Values["to"] = q.Get("to")
		if q.Get("from") != "" {
			v.Form.Values["from"] = views.DateValue(reporting.ParseDate(q.Get("from")))
		}
	}
	v.Form.Values["status"] = f.Status
	v.Form.Values["outlet"] = f.OutletID

	var err error
	if v.Outlets, err = h.outletOptions(r); err != nil {
		return v, err
	}
	if v.Location, err = h.reports.Location(ctx, tenantID); err != nil {
		return v, err
	}
	page, err := h.history.Bills(ctx, tenantID, f)
	switch {
	case err == nil:
		v.Page = page
	case absorb(&v.Form, err):
	default:
		return v, err
	}
	return v, nil
}

func (h *Handler) billPage(w http.ResponseWriter, r *http.Request) {
	detail, err := h.history.Bill(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, history.ErrNotFound) {
		return
	}
	loc, err := h.reports.Location(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.BillPage(h.sessionView(r), views.BillView{Bill: detail, Location: loc}))
}
