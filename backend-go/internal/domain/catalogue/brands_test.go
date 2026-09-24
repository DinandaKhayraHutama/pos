package catalogue_test

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
)

// Mirrors catalogue_test.go's category coverage: a brand is the same shape of
// flat master, just optional on a product instead of required.

func TestASavedBrandReachesTheFeed(t *testing.T) {
	f := newFixture(t)

	id, err := f.svc.SaveBrand(context.Background(), f.tenantID, catalogue.Brand{
		Name: "Indomilk", SortOrder: 3,
	})
	require.NoError(t, err)
	require.NotEmpty(t, id)

	rows := f.rows(t, "brands", 0)
	require.Len(t, rows, 1)
	require.Equal(t, id, rows[0]["id"])
	require.Equal(t, "Indomilk", rows[0]["name"])
	require.EqualValues(t, 1, rows[0]["sync_seq"])
	require.Nil(t, rows[0]["deleted_at_ms"])
}

func TestAnEditToABrandRestampsTheRowSoTillsPastItPullAgain(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	id, err := f.svc.SaveBrand(ctx, f.tenantID, catalogue.Brand{Name: "Indomilk"})
	require.NoError(t, err)

	same, err := f.svc.SaveBrand(ctx, f.tenantID, catalogue.Brand{ID: id, Name: "Indomilk Group"})
	require.NoError(t, err)
	require.Equal(t, id, same, "saving with an id must update, never duplicate")

	rows := f.rows(t, "brands", 1)
	require.Len(t, rows, 1)
	require.Equal(t, "Indomilk Group", rows[0]["name"])
	require.EqualValues(t, 2, rows[0]["sync_seq"])
}

func TestDeletingABrandLeavesATombstoneRatherThanAnAbsence(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	id, err := f.svc.SaveBrand(ctx, f.tenantID, catalogue.Brand{Name: "Indomilk"})
	require.NoError(t, err)
	require.NoError(t, f.svc.DeleteBrand(ctx, f.tenantID, id))

	rows := f.rows(t, "brands", 1)
	require.Len(t, rows, 1)
	require.Equal(t, id, rows[0]["id"])
	require.NotNil(t, rows[0]["deleted_at_ms"], "a till can never infer a deletion from an absence")
}

// Unlike a category, retiring a brand does not remove the products under it —
// a brand is optional, so the fix is "clear the brand", not "move the
// products" — but the same "the person clicking says so" rule applies.
func TestABrandWithProductsRefusesToBeDeleted(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Minuman"})
	require.NoError(t, err)
	brandID, err := f.svc.SaveBrand(ctx, f.tenantID, catalogue.Brand{Name: "Indomilk"})
	require.NoError(t, err)

	productID, err := f.svc.SaveProduct(ctx, f.tenantID, catalogue.Product{
		CategoryID: categoryID, Name: "Susu Kotak", Price: 8_000, Available: true, BrandID: &brandID,
	})
	require.NoError(t, err)

	require.ErrorIs(t, f.svc.DeleteBrand(ctx, f.tenantID, brandID), catalogue.ErrBrandInUse)

	require.NoError(t, f.svc.DeleteProduct(ctx, f.tenantID, productID))
	require.NoError(t, f.svc.DeleteBrand(ctx, f.tenantID, brandID),
		"once no live product carries it the brand may go")
}

// A product's brand is optional: SaveProduct with no BrandID at all must not
// be treated as an error, and the feed must carry it as JSON null, not an
// absent key — the till's apply step reads it by name.
func TestAProductWithNoBrandPublishesANullBrandID(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Makanan"})
	require.NoError(t, err)

	productID := f.saveProduct(t, categoryID, "Nasi Goreng")

	rows := f.rows(t, "products", 0)
	require.Len(t, rows, 1)
	require.Equal(t, productID, rows[0]["id"])
	require.Contains(t, rows[0], "brand_id")
	require.Nil(t, rows[0]["brand_id"])
}

// SaveProduct must refuse a brand id that does not name a live brand of this
// tenant — the same defence category_id already has, just for an optional
// field, so a typo or a cross-tenant id cannot silently attach.
func TestSavingAProductWithAnUnknownBrandIsRefused(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Makanan"})
	require.NoError(t, err)

	bogus := "00000000-0000-0000-0000-000000000000"
	_, err = f.svc.SaveProduct(ctx, f.tenantID, catalogue.Product{
		CategoryID: categoryID, Name: "Nasi Goreng", Price: 20_000, Available: true, BrandID: &bogus,
	})
	require.Error(t, err)
	var verr validation.Errors
	require.ErrorAs(t, err, &verr)
	require.Contains(t, verr, "brand_id")
}

// A brand also reaches the feed carried on the product it labels, not only on
// its own row — the till's product grid reads brand_id off ProductRow.
func TestASavedProductCarriesItsBrandIDOnTheFeed(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Minuman"})
	require.NoError(t, err)
	brandID, err := f.svc.SaveBrand(ctx, f.tenantID, catalogue.Brand{Name: "Indomilk"})
	require.NoError(t, err)

	productID, err := f.svc.SaveProduct(ctx, f.tenantID, catalogue.Product{
		CategoryID: categoryID, Name: "Susu Kotak", Price: 8_000, Available: true, BrandID: &brandID,
	})
	require.NoError(t, err)

	rows := f.rows(t, "products", 0)
	require.Len(t, rows, 1)
	require.Equal(t, productID, rows[0]["id"])
	require.Equal(t, brandID, rows[0]["brand_id"])
}
