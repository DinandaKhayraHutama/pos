package backoffice

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/history"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/outlets"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
)

// HistoryService is the read-only history domain as the panel uses it. There
// is no write method on purpose: these screens look, and the till acts.
type HistoryService interface {
	Orders(ctx context.Context, tenantID string, f history.OrderFilter) (history.OrderPage, error)
	Order(ctx context.Context, tenantID, orderID string) (history.OrderDetail, error)
	Sessions(ctx context.Context, tenantID string, f history.SessionFilter) (history.SessionPage, error)
	Session(ctx context.Context, tenantID, sessionID string) (history.SessionDetail, error)
	Bills(ctx context.Context, tenantID string, f history.BillFilter) (history.BillPage, error)
	Bill(ctx context.Context, tenantID, billID string) (history.BillDetail, error)
}

// historyDefaultDays is how far back a list reaches when nobody picked a
// period. A week: long enough that yesterday's argument about a receipt is on
// the first screen, short enough that the first query is cheap.
const historyDefaultDays = 7

// historyRange reads the period every history screen shares, defaulting to the
// last week on the merchant's clock. A typed date that does not parse stays
// zero so validation says so, rather than the page quietly showing another
// range than the one in the box.
func (h *Handler) historyRange(r *http.Request) (from, to time.Time, err error) {
	today, err := h.reports.Today(r.Context(), tenantOf(r))
	if err != nil {
		return time.Time{}, time.Time{}, err
	}
	q := r.URL.Query()
	from, to = reporting.ParseDate(q.Get("from")), reporting.ParseDate(q.Get("to"))
	if q.Get("to") == "" {
		to = today
	}
	if q.Get("from") == "" {
		from = to.AddDate(0, 0, -(historyDefaultDays - 1))
	}
	return from, to, nil
}

func (h *Handler) transactionsPage(w http.ResponseWriter, r *http.Request) {
	v, err := h.transactionsView(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	// The table is swapped on its own for paging and filtering, so the same
	// view renders whole or in part depending on who asked.
	if r.Header.Get("HX-Request") == "true" {
		h.render(w, r, views.TransactionsTable(v))
		return
	}
	h.render(w, r, views.TransactionsPage(h.sessionView(r), v))
}

func (h *Handler) transactionsView(r *http.Request) (views.TransactionsView, error) {
	ctx, tenantID := r.Context(), tenantOf(r)
	from, to, err := h.historyRange(r)
	if err != nil {
		return views.TransactionsView{}, err
	}
	q := r.URL.Query()
	f := history.OrderFilter{
		From: from, To: to,
		OutletID:   strings.TrimSpace(q.Get("outlet")),
		RegisterID: strings.TrimSpace(q.Get("register")),
		CashierID:  strings.TrimSpace(q.Get("cashier")),
		Receipt:    strings.TrimSpace(q.Get("receipt")),
		Group:      strings.TrimSpace(q.Get("status")),
		Cursor:     q.Get("cursor"),
	}

	v := views.TransactionsView{Filter: f, Form: views.NewForm()}
	v.Form.Values["from"] = views.DateValue(f.From)
	v.Form.Values["to"] = views.DateValue(f.To)
	v.Form.Values["outlet"] = f.OutletID
	v.Form.Values["register"] = f.RegisterID
	v.Form.Values["cashier"] = f.CashierID
	v.Form.Values["receipt"] = f.Receipt
	v.Form.Values["status"] = f.Group

	if v.Outlets, err = h.outletOptions(r); err != nil {
		return v, err
	}
	if v.Registers, err = h.registerOptions(ctx, tenantID, f.OutletID); err != nil {
		return v, err
	}
	if v.Cashiers, err = h.cashierOptions(ctx, tenantID); err != nil {
		return v, err
	}

	page, err := h.history.Orders(ctx, tenantID, f)
	switch {
	case err == nil:
		v.Page = page
	case absorb(&v.Form, err):
		// The message is already beside its field; the list stays empty.
	default:
		return v, err
	}
	return v, nil
}

func (h *Handler) transactionPage(w http.ResponseWriter, r *http.Request) {
	detail, err := h.history.Order(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, history.ErrNotFound) {
		return
	}
	loc, err := h.reports.Location(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.TransactionPage(h.sessionView(r), views.TransactionView{Order: detail, Location: loc}))
}

func (h *Handler) shiftsPage(w http.ResponseWriter, r *http.Request) {
	v, err := h.shiftsView(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	if r.Header.Get("HX-Request") == "true" {
		h.render(w, r, views.ShiftsTable(v))
		return
	}
	h.render(w, r, views.ShiftsPage(h.sessionView(r), v))
}

func (h *Handler) shiftsView(r *http.Request) (views.ShiftsView, error) {
	ctx, tenantID := r.Context(), tenantOf(r)
	from, to, err := h.historyRange(r)
	if err != nil {
		return views.ShiftsView{}, err
	}
	q := r.URL.Query()
	f := history.SessionFilter{
		From: from, To: to,
		OutletID:   strings.TrimSpace(q.Get("outlet")),
		RegisterID: strings.TrimSpace(q.Get("register")),
		CashierID:  strings.TrimSpace(q.Get("cashier")),
		Open:       openState(q.Get("state")),
		Cursor:     q.Get("cursor"),
	}

	v := views.ShiftsView{Filter: f, State: q.Get("state"), Form: views.NewForm()}
	v.Form.Values["from"] = views.DateValue(f.From)
	v.Form.Values["to"] = views.DateValue(f.To)
	v.Form.Values["outlet"] = f.OutletID
	v.Form.Values["register"] = f.RegisterID
	v.Form.Values["cashier"] = f.CashierID
	v.Form.Values["state"] = v.State

	if v.Outlets, err = h.outletOptions(r); err != nil {
		return v, err
	}
	if v.Registers, err = h.registerOptions(ctx, tenantID, f.OutletID); err != nil {
		return v, err
	}
	if v.Cashiers, err = h.cashierOptions(ctx, tenantID); err != nil {
		return v, err
	}
	if v.Location, err = h.reports.Location(ctx, tenantID); err != nil {
		return v, err
	}

	page, err := h.history.Sessions(ctx, tenantID, f)
	switch {
	case err == nil:
		v.Page = page
	case absorb(&v.Form, err):
	default:
		return v, err
	}
	return v, nil
}

// openState reads the open/closed filter. Anything else is "both", so a
// hand-edited query string widens the view rather than failing it.
func openState(value string) *bool {
	yes, no := true, false
	switch value {
	case "open":
		return &yes
	case "closed":
		return &no
	}
	return nil
}

func (h *Handler) shiftPage(w http.ResponseWriter, r *http.Request) {
	detail, err := h.history.Session(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, history.ErrNotFound) {
		return
	}
	loc, err := h.reports.Location(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.ShiftPage(h.sessionView(r), views.ShiftView{Session: detail, Location: loc}))
}

// registerOptions lists the tills a filter can name, narrowed to one branch
// when one is picked. An unparseable outlet yields an empty list rather than an
// error: the outlet select already says what is wrong with it, and a second
// message about the till list would not help.
func (h *Handler) registerOptions(ctx context.Context, tenantID, outletID string) ([]views.Option, error) {
	if outletID != "" && !validation.UUID(outletID) {
		return []views.Option{}, nil
	}
	list, err := h.outlets.Registers(ctx, tenantID, outletID)
	if err != nil {
		if errors.Is(err, outlets.ErrNotFound) {
			return []views.Option{}, nil
		}
		return nil, err
	}
	out := make([]views.Option, 0, len(list))
	for _, r := range list {
		// The branch is only worth repeating when the list spans branches.
		label := r.Name
		if outletID == "" && r.OutletName != "" {
			label = r.OutletName + " · " + r.Name
		}
		if !r.Active {
			label += " (nonaktif)"
		}
		out = append(out, views.Option{Value: r.ID, Label: label})
	}
	return out, nil
}

// cashierOptions lists everyone who could have rung up a sale. Deliberately
// not "only cashiers": a manager covering the counter signs in on a cashier
// account, people change role, and a filter that hid a former cashier would
// hide their sales with them.
func (h *Handler) cashierOptions(ctx context.Context, tenantID string) ([]views.Option, error) {
	list, err := h.staff.List(ctx, tenantID)
	if err != nil {
		return nil, err
	}
	out := make([]views.Option, 0, len(list))
	for _, p := range list {
		label := p.Name
		if !p.Active {
			label += " (nonaktif)"
		}
		out = append(out, views.Option{Value: p.ID, Label: label})
	}
	return out, nil
}
