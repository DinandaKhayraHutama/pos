package backoffice

import (
	"context"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/outlets"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/tables"
)

// TableService is the floor-plan domain as the panel uses it.
type TableService interface {
	List(ctx context.Context, tenantID, outletID string) ([]tables.Table, error)
	Get(ctx context.Context, tenantID, id string) (tables.Table, error)
	Save(ctx context.Context, tenantID string, in tables.Table) (string, error)
	SetActive(ctx context.Context, tenantID, id string, active bool) error
	Delete(ctx context.Context, tenantID, id string) error
}

// tablesPage is one branch's floor plan: the live status board, which the page
// refreshes on its own, and the definitions below it. Status is the tills' to
// change; the panel only shows it.
func (h *Handler) tablesPage(w http.ResponseWriter, r *http.Request) {
	tenantID, outletID := tenantOf(r), chi.URLParam(r, "id")

	o, err := h.outlets.Get(r.Context(), tenantID, outletID)
	if h.failed(w, r, err, outlets.ErrNotFound) {
		return
	}
	list, err := h.tables.List(r.Context(), tenantID, outletID)
	if h.failed(w, r, err, tables.ErrNotFound) {
		return
	}

	h.render(w, r, views.TablesPage(h.sessionView(r), o, list))
}

func (h *Handler) tablesBoard(w http.ResponseWriter, r *http.Request) {
	outletID := chi.URLParam(r, "id")
	list, err := h.tables.List(r.Context(), tenantOf(r), outletID)
	if h.failed(w, r, err, tables.ErrNotFound) {
		return
	}

	h.render(w, r, views.TableBoard(outletID, list))
}

func (h *Handler) saveTable(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	tenantID, outletID, tableID := tenantOf(r), chi.URLParam(r, "id"), chi.URLParam(r, "tableID")

	// The switch has its own control, so an edit carries the current state.
	active := true
	if tableID != "" {
		current, ok := h.tableInOutlet(w, r, outletID, tableID)
		if !ok {
			return
		}
		active = current.Active
	}

	p := newParser(f)
	in := tables.Table{
		ID: tableID, OutletID: outletID, Name: p.text("name"), Area: p.text("area"),
		Capacity: p.integer("capacity"), PosX: p.optionalInteger("pos_x"), PosY: p.optionalInteger("pos_y"),
		SortOrder: p.integer("sort_order"), Active: active,
	}
	err := p.errs.Err()
	if err == nil {
		_, err = h.tables.Save(r.Context(), tenantID, in)
	}
	if !absorb(&f, err) && h.failed(w, r, err, tables.ErrNotFound) {
		return
	}

	failed := ""
	if err != nil {
		failed = tableID
		if failed == "" {
			failed = "new"
		}
	} else {
		f = views.NewForm()
		toast(w, "Meja disimpan.")
	}

	h.renderTables(w, r, outletID, failed, f)
}

func (h *Handler) setTableActive(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	tenantID, outletID, tableID := tenantOf(r), chi.URLParam(r, "id"), chi.URLParam(r, "tableID")
	if _, ok := h.tableInOutlet(w, r, outletID, tableID); !ok {
		return
	}

	err := h.tables.SetActive(r.Context(), tenantID, tableID, f.Checked("active"))
	if h.failed(w, r, err, tables.ErrNotFound) {
		return
	}

	if f.Checked("active") {
		toast(w, "Meja diaktifkan.")
	} else {
		toast(w, "Meja dinonaktifkan. Selama masih terisi, meja tetap tampil di till sampai dikosongkan.")
	}
	h.renderTables(w, r, outletID, "", views.NewForm())
}

func (h *Handler) deleteTable(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.parseForm(w, r); !ok {
		return
	}
	tenantID, outletID, tableID := tenantOf(r), chi.URLParam(r, "id"), chi.URLParam(r, "tableID")
	if _, ok := h.tableInOutlet(w, r, outletID, tableID); !ok {
		return
	}

	err := h.tables.Delete(r.Context(), tenantID, tableID)
	if h.failed(w, r, err, tables.ErrNotFound) {
		return
	}

	toast(w, "Meja dihapus.")
	h.renderTables(w, r, outletID, "", views.NewForm())
}

// tableInOutlet answers 404 for a table that is not in the branch the URL
// names, so a stale or edited URL cannot reach another branch's table.
func (h *Handler) tableInOutlet(w http.ResponseWriter, r *http.Request, outletID, tableID string) (tables.Table, bool) {
	t, err := h.tables.Get(r.Context(), tenantOf(r), tableID)
	if h.failed(w, r, err, tables.ErrNotFound) {
		return tables.Table{}, false
	}
	if t.OutletID != outletID {
		h.notFound(w, r)
		return tables.Table{}, false
	}
	return t, true
}

func (h *Handler) renderTables(w http.ResponseWriter, r *http.Request, outletID, failed string, f views.Form) {
	list, err := h.tables.List(r.Context(), tenantOf(r), outletID)
	if h.failed(w, r, err, tables.ErrNotFound) {
		return
	}

	h.render(w, r, views.TablesCard(outletID, list, failed, f))
}
