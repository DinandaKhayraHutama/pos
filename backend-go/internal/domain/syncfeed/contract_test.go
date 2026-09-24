package syncfeed

import (
	"github.com/daniryckidinata/nti_pos/backend-go/api"
	"github.com/getkin/kin-openapi/openapi3"
	"github.com/stretchr/testify/require"
	"testing"
)

func TestPublishedColumnsExactlyMatchFrozenRowSchemas(t *testing.T) {
	doc, err := openapi3.NewLoader().LoadFromData(api.Specification)
	require.NoError(t, err)
	schemas := map[string]string{"roles": "RoleRow", "business_settings": "BusinessSettingsRow", "outlet_settings": "OutletSettingsRow", "sales_types": "SalesTypeRow", "payment_methods": "PaymentMethodRow", "payment_groups": "PaymentGroupRow", "discounts": "DiscountRow", "product_sales_type_prices": "ProductSalesTypePriceRow", "outlet_product_sales_type_prices": "OutletProductSalesTypePriceRow", "employees": "EmployeeRow", "outlets": "OutletRow", "pos_registers": "RegisterRow", "categories": "CategoryRow", "brands": "BrandRow", "customers": "CustomerRow", "products": "ProductRow", "product_variants": "VariantRow", "modifier_groups": "ModifierGroupRow", "modifier_options": "ModifierOptionRow", "product_modifier_groups": "ProductModifierGroupRow", "product_modifier_options": "ProductModifierOptionRow", "promos": "PromoRow", "promo_outlets": "PromoOutletRow", "outlet_stock": "OutletStockRow", "stock_movements": "StockMovementRow", "tables": "TableRow", "table_status": "TableStatusRow"}
	for _, e := range Entities() {
		s := doc.Components.Schemas[schemas[e.Name]].Value
		cols := []string{"sync_seq", "deleted_at_ms"}
		for _, c := range e.columns {
			cols = append(cols, c.wire)
		}
		require.ElementsMatch(t, cols, s.Required, e.Name)
		require.Len(t, s.Properties, len(cols), e.Name)
	}
}
