package catalogue_test

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
)

func row(line int, fields map[string]string) catalogue.CatalogueRow {
	return catalogue.CatalogueRow{Line: line, Fields: fields}
}

func TestImportCatalogueCreatesNewProducts(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Minuman"})
	require.NoError(t, err)
	brandID, err := f.svc.SaveBrand(ctx, f.tenantID, catalogue.Brand{Name: "Indomilk"})
	require.NoError(t, err)

	header := []string{"name", "category_id", "brand_id", "sku", "price"}
	rows := []catalogue.CatalogueRow{
		row(2, map[string]string{"name": "Susu Kotak", "category_id": categoryID, "brand_id": brandID, "sku": "SK-01", "price": "8000"}),
		row(3, map[string]string{"name": "Teh Botol", "category_id": categoryID, "sku": "SK-02", "price": "6000"}),
	}

	result, err := f.svc.ImportCatalogue(ctx, f.tenantID, header, rows, true)
	require.NoError(t, err)
	require.Equal(t, catalogue.CatalogueImportResult{Created: 2, Updated: 0, Unchanged: 0}, result)

	products := f.rows(t, "products", 0)
	require.Len(t, products, 2)
	names := map[string]bool{}
	for _, p := range products {
		names[p["name"].(string)] = true
	}
	require.True(t, names["Susu Kotak"] && names["Teh Botol"])
}

func TestImportCatalogueUpdatesByID(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Minuman"})
	require.NoError(t, err)
	productID := f.saveProduct(t, categoryID, "Kopi")

	header := []string{"id", "price"}
	rows := []catalogue.CatalogueRow{row(2, map[string]string{"id": productID, "price": "30000"})}

	result, err := f.svc.ImportCatalogue(ctx, f.tenantID, header, rows, true)
	require.NoError(t, err)
	require.Equal(t, catalogue.CatalogueImportResult{Created: 0, Updated: 1, Unchanged: 0}, result)

	rows2 := f.rows(t, "products", 1)
	require.Len(t, rows2, 1)
	require.EqualValues(t, 30_000, rows2[0]["price"])
	// name must survive untouched: the header did not carry it, so the
	// current value is kept, never blanked.
	require.Equal(t, "Kopi", rows2[0]["name"])
}

func TestImportCatalogueUpdatesBySKUWhenIDColumnIsAbsent(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Minuman"})
	require.NoError(t, err)
	sku := "SK-09"
	_, err = f.svc.SaveProduct(ctx, f.tenantID, catalogue.Product{
		CategoryID: categoryID, Name: "Kopi", Price: 20_000, SKU: &sku, Available: true,
	})
	require.NoError(t, err)

	header := []string{"sku", "price"}
	rows := []catalogue.CatalogueRow{row(2, map[string]string{"sku": "SK-09", "price": "22000"})}

	result, err := f.svc.ImportCatalogue(ctx, f.tenantID, header, rows, true)
	require.NoError(t, err)
	require.Equal(t, 1, result.Updated)
}

func TestImportCatalogueRefusesAnAmbiguousSKU(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Minuman"})
	require.NoError(t, err)
	sku := "DUP"
	_, err = f.svc.SaveProduct(ctx, f.tenantID, catalogue.Product{CategoryID: categoryID, Name: "A", Price: 1000, SKU: &sku, Available: true})
	require.NoError(t, err)
	_, err = f.svc.SaveProduct(ctx, f.tenantID, catalogue.Product{CategoryID: categoryID, Name: "B", Price: 1000, SKU: &sku, Available: true})
	require.NoError(t, err)

	header := []string{"sku", "price"}
	rows := []catalogue.CatalogueRow{row(2, map[string]string{"sku": "DUP", "price": "2000"})}

	_, err = f.svc.ImportCatalogue(ctx, f.tenantID, header, rows, true)
	require.Error(t, err)
	var problems catalogue.ImportErrors
	require.ErrorAs(t, err, &problems)
	require.Contains(t, problems.Error(), "dipakai 2 produk")
}

func TestImportCatalogueRefusesAnUnknownID(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	header := []string{"id", "price"}
	rows := []catalogue.CatalogueRow{row(2, map[string]string{"id": "00000000-0000-0000-0000-000000000000", "price": "1000"})}

	_, err := f.svc.ImportCatalogue(ctx, f.tenantID, header, rows, true)
	require.Error(t, err)
	var problems catalogue.ImportErrors
	require.ErrorAs(t, err, &problems)
	require.Contains(t, problems.Error(), "tidak dikenal")
}

func TestImportCatalogueRefusesAnUnknownCategoryOrBrand(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	bogus := "00000000-0000-0000-0000-000000000000"
	header := []string{"name", "category_id", "price"}
	rows := []catalogue.CatalogueRow{row(2, map[string]string{"name": "X", "category_id": bogus, "price": "1000"})}

	_, err := f.svc.ImportCatalogue(ctx, f.tenantID, header, rows, true)
	require.Error(t, err)
	var problems catalogue.ImportErrors
	require.ErrorAs(t, err, &problems)
	require.Contains(t, problems.Error(), "Kategori tidak ditemukan")
}

// A file that only updates existing rows never needs name/category_id/price
// in its header — but the moment one row in it has no match, it is
// implicitly asking to create a product, and the file is refused for
// lacking what a new product requires, not silently half-applied.
func TestImportCatalogueRefusesACreateRowWhenTheHeaderCannotCreate(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	header := []string{"sku", "price"}
	rows := []catalogue.CatalogueRow{row(2, map[string]string{"sku": "NEW-01", "price": "1000"})}

	_, err := f.svc.ImportCatalogue(ctx, f.tenantID, header, rows, true)
	require.Error(t, err)
	var problems catalogue.ImportErrors
	require.ErrorAs(t, err, &problems)
	require.Contains(t, problems.Error(), "kolom")
}

// Re-importing an unchanged file must not wake every till in the company to
// pull rows that did not change — the same discipline ImportPrices already
// holds for a single column, generalised to every column this importer owns.
func TestImportCatalogueLeavesUnchangedRowsUnnumbered(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Minuman"})
	require.NoError(t, err)
	productID := f.saveProduct(t, categoryID, "Kopi")

	header := []string{"id", "name", "category_id", "price"}
	rows := []catalogue.CatalogueRow{row(2, map[string]string{"id": productID, "name": "Kopi", "category_id": categoryID, "price": "25000"})}

	result, err := f.svc.ImportCatalogue(ctx, f.tenantID, header, rows, true)
	require.NoError(t, err)
	require.Equal(t, catalogue.CatalogueImportResult{Unchanged: 1}, result)

	require.Empty(t, f.rows(t, "products", 1), "an unchanged row must not receive a new sync_seq")
}

// One bad row refuses the whole file — no row of it is written, matching
// ImportPrices' own all-or-nothing rule.
func TestImportCatalogueIsAllOrNothing(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Minuman"})
	require.NoError(t, err)

	header := []string{"name", "category_id", "price"}
	rows := []catalogue.CatalogueRow{
		row(2, map[string]string{"name": "Good", "category_id": categoryID, "price": "1000"}),
		row(3, map[string]string{"name": "Bad", "category_id": "not-a-uuid", "price": "1000"}),
	}

	_, err = f.svc.ImportCatalogue(ctx, f.tenantID, header, rows, true)
	require.Error(t, err)
	require.Empty(t, f.rows(t, "products", 0), "no row may be written when any row fails")
}

// A preview (commit=false) reports the same counts a commit would, but
// writes nothing — the till must not learn of a change nobody confirmed.
func TestImportCataloguePreviewWritesNothing(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Minuman"})
	require.NoError(t, err)

	header := []string{"name", "category_id", "price"}
	rows := []catalogue.CatalogueRow{row(2, map[string]string{"name": "Susu", "category_id": categoryID, "price": "5000"})}

	preview, err := f.svc.ImportCatalogue(ctx, f.tenantID, header, rows, false)
	require.NoError(t, err)
	require.Equal(t, catalogue.CatalogueImportResult{Created: 1}, preview)
	require.Empty(t, f.rows(t, "products", 0), "a preview must not write any row")

	commit, err := f.svc.ImportCatalogue(ctx, f.tenantID, header, rows, true)
	require.NoError(t, err)
	require.Equal(t, catalogue.CatalogueImportResult{Created: 1}, commit)
	require.Len(t, f.rows(t, "products", 0), 1)
}

func TestLegacyPriceListHeaderDetection(t *testing.T) {
	require.True(t, catalogue.LegacyPriceListHeader([]string{"sku", "harga"}))
	require.True(t, catalogue.LegacyPriceListHeader([]string{"sku", "price"}))
	require.True(t, catalogue.LegacyPriceListHeader([]string{"harga", "sku"}))
	require.False(t, catalogue.LegacyPriceListHeader([]string{"sku", "harga", "name"}),
		"a third column means this is a full import, not the legacy shape")
	require.False(t, catalogue.LegacyPriceListHeader([]string{"sku"}))
	require.False(t, catalogue.LegacyPriceListHeader([]string{"name", "price"}))
}
