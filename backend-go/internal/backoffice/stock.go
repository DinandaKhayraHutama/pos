package backoffice

import (
	"net/http"
	"strings"

	"github.com/a-h/templ"
	"github.com/go-chi/chi/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/stock"
)

func actorOf(r *http.Request) stock.Actor {
	employee := employeeFrom(r.Context())
	return stock.Actor{EmployeeID: employee.ID, Name: employee.Name}
}

func stockPath(outletID, productID string) string {
	return "/backoffice/stock/" + outletID + "/" + productID
}

func (h *Handler) stockPage(w http.ResponseWriter, r *http.Request) {
	outlets, err := h.outletOptions(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	v := views.StockView{
		Outlets:  outlets,
		OutletID: r.URL.Query().Get("outlet"),
		Query:    strings.TrimSpace(r.URL.Query().Get("q")),
	}
	if v.OutletID == "" && len(outlets) > 0 {
		v.OutletID = outlets[0].Value
	}

	if v.OutletID != "" {
		v.Levels, err = h.stock.Levels(r.Context(), tenantOf(r), v.OutletID, v.Query)
		if h.failed(w, r, err, stock.ErrNotFound) {
			return
		}
	}

	v.Alerts, err = h.stock.Alerts(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	h.render(w, r, views.StockPage(h.sessionView(r), v))
}

// transferTargets is every other live branch.
func (h *Handler) transferTargets(r *http.Request, outletID string) ([]views.Option, error) {
	all, err := h.outletOptions(r)
	if err != nil {
		return nil, err
	}
	out := make([]views.Option, 0, len(all))
	for _, o := range all {
		if o.Value != outletID {
			out = append(out, o)
		}
	}
	return out, nil
}

func (h *Handler) stockProductPage(w http.ResponseWriter, r *http.Request) {
	outletID, productID := chi.URLParam(r, "outletID"), chi.URLParam(r, "productID")

	detail, err := h.stock.Detail(r.Context(), tenantOf(r), outletID, productID)
	if h.failed(w, r, err, stock.ErrNotFound) {
		return
	}
	targets, err := h.transferTargets(r, outletID)
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	adjust := views.NewForm()
	adjust.Values["kind"] = stock.KindReceived
	h.render(w, r, views.StockProductPage(h.sessionView(r), views.StockDetailView{
		Detail: detail, Targets: targets,
		Adjust: adjust, Count: views.NewForm(), Transfer: views.NewForm(),
	}))
}

// afterStockWrite ends every stock form the same way: a saved write reloads the
// page, so the count and the ledger beside the form are the ones just written;
// a refused one re-renders only its own form, with the message beside its input.
func (h *Handler) afterStockWrite(w http.ResponseWriter, r *http.Request, err error, f views.Form, outletID, productID string, form func(views.Form) templ.Component) {
	if err == nil {
		redirect(w, r, stockPath(outletID, productID))
		return
	}
	if absorb(&f, err) {
		h.render(w, r, form(f))
		return
	}
	h.failed(w, r, err, stock.ErrNotFound)
}

func (h *Handler) adjustStock(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	outletID, productID := chi.URLParam(r, "outletID"), chi.URLParam(r, "productID")

	p := newParser(f)
	in := stock.Adjustment{
		OutletID: outletID, ProductID: productID,
		Kind: p.text("kind"), Quantity: int64(p.integer("quantity")), Note: p.optionalText("note"),
	}
	err := p.errs.Err()
	if err == nil {
		err = h.stock.Adjust(r.Context(), tenantOf(r), actorOf(r), in)
	}

	d := stock.Detail{OutletID: outletID, ProductID: productID}
	h.afterStockWrite(w, r, err, f, outletID, productID, func(f views.Form) templ.Component {
		return views.StockAdjustForm(d, f)
	})
}

func (h *Handler) countStock(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	outletID, productID := chi.URLParam(r, "outletID"), chi.URLParam(r, "productID")

	p := newParser(f)
	counted := int64(p.integer("counted"))
	if p.text("counted") == "" {
		p.errs.Add("counted", "Isi jumlah yang dihitung.")
	}
	err := p.errs.Err()
	if err == nil {
		err = h.stock.Count(r.Context(), tenantOf(r), actorOf(r), outletID, productID, counted, p.optionalText("note"))
	}

	d := stock.Detail{OutletID: outletID, ProductID: productID}
	h.afterStockWrite(w, r, err, f, outletID, productID, func(f views.Form) templ.Component {
		return views.StockCountForm(d, f)
	})
}

func (h *Handler) transferStock(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	outletID, productID := chi.URLParam(r, "outletID"), chi.URLParam(r, "productID")

	p := newParser(f)
	in := stock.Transfer{
		FromOutletID: outletID, ToOutletID: p.text("to_outlet"), ProductID: productID,
		Quantity: int64(p.integer("quantity")), Note: p.optionalText("note"),
	}
	err := p.errs.Err()
	if err == nil {
		err = h.stock.Transfer(r.Context(), tenantOf(r), actorOf(r), in)
	}

	targets, targetErr := h.transferTargets(r, outletID)
	if targetErr != nil {
		h.serverError(w, r, targetErr)
		return
	}
	d := stock.Detail{OutletID: outletID, ProductID: productID}
	h.afterStockWrite(w, r, err, f, outletID, productID, func(f views.Form) templ.Component {
		return views.StockTransferForm(d, targets, f)
	})
}
