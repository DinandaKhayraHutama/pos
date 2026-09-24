package catalogue_test

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
)

func (f fixture) outletCounter(t *testing.T, outletID, entity string) int64 {
	t.Helper()
	var seq int64
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		`SELECT COALESCE(max(last_seq), 0) FROM sync_counters WHERE scope_key = $1`,
		syncfeed.OutletScope(f.tenantID, outletID, entity)).Scan(&seq))
	return seq
}

func TestEveryMerchantHasTheThreeBuiltInSalesTypes(t *testing.T) {
	f := newFixture(t)
	types, err := f.svc.ListSalesTypes(context.Background(), f.tenantID)
	require.NoError(t, err)
	require.Len(t, types, 3)
	keys := []string{}
	for _, st := range types {
		keys = append(keys, *st.SystemKey)
	}
	require.Equal(t, []string{"dineIn", "takeaway", "delivery"}, keys,
		"the keys are the wire values every till has always sent as `type`")
	require.Len(t, f.rows(t, "sales_types", 0), 3, "and they are numbered for the feed")

	require.ErrorIs(t, f.svc.DeleteSalesType(context.Background(), f.tenantID, types[0].ID), catalogue.ErrSystemSalesType)
}

func TestProductPricesWriteOnlyTheirDifferencesAndCountPerBranch(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	product := f.saveProduct(t, f.category(t, "Minuman"), "Es teh")
	gofood, err := f.svc.SaveSalesType(ctx, f.tenantID, catalogue.SalesType{Name: "GoFood", Active: true})
	require.NoError(t, err)
	var outlet string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Kemang') RETURNING id::text`, f.tenantID).Scan(&outlet))

	want := []catalogue.Price{
		{SalesTypeID: gofood, Price: 9000},
		{SalesTypeID: gofood, OutletID: &outlet, Price: 9500},
	}
	require.NoError(t, f.svc.SetProductPrices(ctx, f.tenantID, product, want))
	company, branch := f.counter(t, "product_sales_type_prices"), f.outletCounter(t, outlet, "outlet_product_sales_type_prices")
	require.EqualValues(t, 1, company)
	require.EqualValues(t, 1, branch, "a branch override is numbered on the branch's counter, where its tills page")

	require.NoError(t, f.svc.SetProductPrices(ctx, f.tenantID, product, want))
	require.Equal(t, company, f.counter(t, "product_sales_type_prices"), "an unchanged price wakes nobody")
	require.Equal(t, branch, f.outletCounter(t, outlet, "outlet_product_sales_type_prices"))

	// Dropping the override retires it; the business price stays.
	require.NoError(t, f.svc.SetProductPrices(ctx, f.tenantID, product, want[:1]))
	prices, err := f.svc.ProductPrices(ctx, f.tenantID, product)
	require.NoError(t, err)
	require.Len(t, prices, 1)
	require.Nil(t, prices[0].OutletID)

	// Deleting the sales type retires every price that named it.
	require.NoError(t, f.svc.DeleteSalesType(ctx, f.tenantID, gofood))
	prices, err = f.svc.ProductPrices(ctx, f.tenantID, product)
	require.NoError(t, err)
	require.Empty(t, prices)
	var tombstones int
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT count(*) FROM product_sales_type_prices WHERE deleted_at IS NOT NULL`).Scan(&tombstones))
	require.Equal(t, 1, tombstones, "a till learns of the retirement from a tombstone, never from absence")
}

func TestAPriceForAnotherMerchantsSalesTypeIsRefused(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	product := f.saveProduct(t, f.category(t, "Makanan"), "Nasi goreng")
	var other, theirs string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO tenants (name, slug) VALUES ('Beta', 'beta') RETURNING id::text`).Scan(&other))
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT id::text FROM sales_types WHERE tenant_id = $1 LIMIT 1`, other).Scan(&theirs))

	err := f.svc.SetProductPrices(ctx, f.tenantID, product, []catalogue.Price{{SalesTypeID: theirs, Price: 1}})
	_, invalid := validation.As(err)
	require.True(t, invalid, "got %v", err)
}
