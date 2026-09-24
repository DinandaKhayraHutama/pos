package catalogue_test

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
)

// The export is the half of the round trip import.go is checked against, so
// its column order and formula-injection guard are pinned here directly
// rather than only implicitly through an import test.
func TestExportedCSVCarriesTheStableIDAndEveryColumn(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Minuman"})
	require.NoError(t, err)
	brandID, err := f.svc.SaveBrand(ctx, f.tenantID, catalogue.Brand{Name: "Indomilk"})
	require.NoError(t, err)
	sku := "SK-01"
	cost := int64(4_000)
	productID, err := f.svc.SaveProduct(ctx, f.tenantID, catalogue.Product{
		CategoryID: categoryID, BrandID: &brandID, Name: "Susu Kotak",
		Price: 8_000, Cost: &cost, SKU: &sku, Available: true, IsPopular: true,
	})
	require.NoError(t, err)

	csv, err := f.svc.ExportProductsCSV(ctx, f.tenantID)
	require.NoError(t, err)
	out := string(csv)

	require.True(t, strings.HasPrefix(out, "\xEF\xBB\xBF"), "must carry the UTF-8 BOM report exports use")
	firstLine := strings.SplitN(strings.TrimPrefix(out, "\xEF\xBB\xBF"), "\n", 2)[0]
	require.Equal(t, "id,name,category_id,category_name,brand_id,brand_name,sku,price,cost,tax_rate,description,icon_key,sort_order,available,is_popular",
		strings.TrimRight(firstLine, "\r"),
		"the header must be the very first line — no title row, or a generic CSV reader (and ImportCatalogue) reads the title as the header")
	require.Contains(t, out, productID+",Susu Kotak,"+categoryID+",Minuman,"+brandID+",Indomilk,SK-01,8000,4000")
	require.Contains(t, out, ",ya,ya")
}

// A product carrying no brand exports an empty brand_id/brand_name cell, not
// a row that fails to render — ImportCatalogue reads that back as "no
// change to this product's brand", never as an error.
func TestExportedCSVLeavesBrandBlankWhenTheProductHasNone(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Makanan"})
	require.NoError(t, err)
	productID := f.saveProduct(t, categoryID, "Nasi Goreng")

	csv, err := f.svc.ExportProductsCSV(ctx, f.tenantID)
	require.NoError(t, err)
	out := string(csv)

	require.Contains(t, out, productID+",Nasi Goreng,"+categoryID+",Makanan,,,")
}

// A product name a cashier typed as "=cmd|..." must not become a live
// formula when the file is opened in Excel or Sheets — the same guard report
// exports already carry (reporting.safeText), reused rather than
// reimplemented.
func TestExportedCSVGuardsAgainstFormulaInjection(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Makanan"})
	require.NoError(t, err)
	_, err = f.svc.SaveProduct(ctx, f.tenantID, catalogue.Product{
		CategoryID: categoryID, Name: `=cmd|' /C calc'!A1`, Price: 10_000, Available: true,
	})
	require.NoError(t, err)

	csv, err := f.svc.ExportProductsCSV(ctx, f.tenantID)
	require.NoError(t, err)
	require.Contains(t, string(csv), `'=cmd`)
}
