package syncfeed_test

import (
	"context"
	"testing"

	"github.com/daniryckidinata/nti_pos/backend-go/api"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/syncfixture"
	"github.com/getkin/kin-openapi/openapi3"
	"github.com/stretchr/testify/require"
)

func TestRealPostgresRowsConformToOpenAPI(t *testing.T) {
	f := newFixture(t)
	doc, err := openapi3.NewLoader().LoadFromData(api.Specification)
	require.NoError(t, err)
	require.NoError(t, syncfixture.Seed(context.Background(), f.feed, f.tenantID, 2))
	schemas := map[string]string{
		"employees": "EmployeeRow", "outlets": "OutletRow", "pos_registers": "RegisterRow",
		"categories": "CategoryRow", "brands": "BrandRow", "customers": "CustomerRow",
		"products": "ProductRow", "product_variants": "VariantRow",
		"modifier_groups": "ModifierGroupRow", "modifier_options": "ModifierOptionRow",
		"product_modifier_groups": "ProductModifierGroupRow", "product_modifier_options": "ProductModifierOptionRow",
		"promos": "PromoRow", "promo_outlets": "PromoOutletRow",
		"outlet_stock": "OutletStockRow", "stock_movements": "StockMovementRow",
		"tables": "TableRow", "table_status": "TableStatusRow",
		"roles": "RoleRow", "business_settings": "BusinessSettingsRow", "outlet_settings": "OutletSettingsRow",
		"sales_types": "SalesTypeRow", "payment_methods": "PaymentMethodRow", "payment_groups": "PaymentGroupRow",
		"discounts": "DiscountRow", "product_sales_type_prices": "ProductSalesTypePriceRow",
		"outlet_product_sales_type_prices": "OutletProductSalesTypePriceRow",
	}
	var outletID string
	require.NoError(t, f.db.Owner.QueryRow(context.Background(), syncfixture.FeedOutletSQL, f.tenantID).Scan(&outletID))
	for entity, name := range schemas {
		t.Run(entity, func(t *testing.T) {
			page, err := f.feed.PullOutlet(context.Background(), f.tenantID, outletID, entity, 0, 100)
			require.NoError(t, err)
			require.NotEmpty(t, page.Rows)
			for _, raw := range page.Rows {
				require.NoError(t, doc.Components.Schemas[name].Value.VisitJSON(decode(t, raw)))
			}
		})
	}
}
