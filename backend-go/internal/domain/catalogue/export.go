package catalogue

// Catalogue export: the read side of Fase 2's import/export loop. See
// import.go for the write side — the two share the exact column list
// (exportColumns) so a file this produces is always a file ImportCatalogue
// accepts unmodified, which is what "ekspor–impor tanpa menggandakan
// entitas" (the phase's own pass criterion) requires in practice: the round
// trip has to be lossless on the columns that matter.

import (
	"context"
	"strconv"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// ExportRow is one product line of a catalogue export.
//
// CategoryName and BrandName are read-only: they exist only so a human
// editing the file in a spreadsheet can see what category_id/brand_id mean
// without a second lookup. ImportCatalogue ignores both — ImportColumns
// below does not list them, and the importer refuses any header cell it does
// not recognise as either an identity column or an importable one.
type ExportRow struct {
	ID           string
	Name         string
	CategoryID   string
	CategoryName string
	BrandID      *string
	BrandName    *string
	SKU          *string
	Price        int64
	Cost         *int64
	TaxRate      *float64
	Description  *string
	IconKey      string
	SortOrder    int
	Available    bool
	IsPopular    bool
}

// exportColumns is the full header ExportProductsCSV writes, in order.
var exportColumns = []string{
	"id", "name", "category_id", "category_name", "brand_id", "brand_name",
	"sku", "price", "cost", "tax_rate", "description", "icon_key",
	"sort_order", "available", "is_popular",
}

// ImportColumns is the subset of exportColumns ImportCatalogue will write —
// category_name and brand_name are excluded, on purpose: see the type doc on
// ExportRow. import.go reads this rather than spelling its own list, so the
// two can never quietly drift out of step.
var ImportColumns = []string{
	"id", "name", "category_id", "brand_id",
	"sku", "price", "cost", "tax_rate", "description", "icon_key",
	"sort_order", "available", "is_popular",
}

// ImportColumnSet is ImportColumns as a set, for the HTTP layer's header
// allow-list check — built once rather than re-scanning the slice per column
// of every uploaded header.
var ImportColumnSet = func() map[string]bool {
	out := make(map[string]bool, len(ImportColumns))
	for _, c := range ImportColumns {
		out[c] = true
	}
	return out
}()

// AllProductsForExport returns every live product, unpaginated. An export is
// a download a merchant runs occasionally on a whole menu, not a page a
// browser renders, so it does not share ProductPageSize with the Backoffice
// list.
func (s *Service) AllProductsForExport(ctx context.Context, tenantID string) ([]ExportRow, error) {
	var out []ExportRow

	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT p.id, p.name, p.category_id, c.name, p.brand_id, b.name,
			       p.sku, p.price, p.cost, p.tax_rate, p.description, p.icon_key,
			       p.sort_order, p.available, p.is_popular
			FROM products p
			JOIN categories c ON c.tenant_id = p.tenant_id AND c.id = p.category_id
			LEFT JOIN brands b ON b.tenant_id = p.tenant_id AND b.id = p.brand_id AND b.deleted_at IS NULL
			WHERE p.tenant_id = $1 AND p.deleted_at IS NULL
			ORDER BY c.sort_order, c.name, p.sort_order, p.name`, tenantID)
		if err != nil {
			return err
		}

		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (ExportRow, error) {
			var e ExportRow
			err := row.Scan(&e.ID, &e.Name, &e.CategoryID, &e.CategoryName, &e.BrandID, &e.BrandName,
				&e.SKU, &e.Price, &e.Cost, &e.TaxRate, &e.Description, &e.IconKey,
				&e.SortOrder, &e.Available, &e.IsPopular)
			return e, err
		})
		return err
	})

	return out, err
}

// ExportProductsCSV renders the live catalogue as CSV, header on line one
// and nothing above it (reporting.RenderFlatCSV) so the file this produces
// is, completely unmodified, a valid upload to ImportCatalogue — that round
// trip is what "ekspor–impor tanpa menggandakan entitas" (the phase's own
// pass criterion) means in practice. Still under the same UTF-8 BOM and
// safeText formula-injection guard report exports use, and numbers stay
// numbers (reporting.IntCell), so a merchant opening this in a spreadsheet
// can sum or sort the price column without cleaning it first.
func (s *Service) ExportProductsCSV(ctx context.Context, tenantID string) ([]byte, error) {
	rows, err := s.AllProductsForExport(ctx, tenantID)
	if err != nil {
		return nil, err
	}

	table := reporting.Table{Header: exportColumns}
	for _, r := range rows {
		table.Rows = append(table.Rows, []reporting.Cell{
			reporting.TextCell(r.ID),
			reporting.TextCell(r.Name),
			reporting.TextCell(r.CategoryID),
			reporting.TextCell(r.CategoryName),
			reporting.TextCell(deref(r.BrandID)),
			reporting.TextCell(deref(r.BrandName)),
			reporting.TextCell(deref(r.SKU)),
			reporting.IntCell(r.Price),
			reporting.TextCell(optionalInt64String(r.Cost)),
			reporting.TextCell(optionalFloatString(r.TaxRate)),
			reporting.TextCell(deref(r.Description)),
			reporting.TextCell(r.IconKey),
			reporting.IntCell(int64(r.SortOrder)),
			reporting.TextCell(yesNo(r.Available)),
			reporting.TextCell(yesNo(r.IsPopular)),
		})
	}

	return reporting.RenderFlatCSV(table)
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func optionalInt64String(v *int64) string {
	if v == nil {
		return ""
	}
	return strconv.FormatInt(*v, 10)
}

func optionalFloatString(v *float64) string {
	if v == nil {
		return ""
	}
	return strconv.FormatFloat(*v, 'f', -1, 64)
}

func yesNo(b bool) string {
	if b {
		return "ya"
	}
	return "tidak"
}
