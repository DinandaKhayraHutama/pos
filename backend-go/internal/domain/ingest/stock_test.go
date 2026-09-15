package ingest

import (
	"context"
	"testing"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/stretchr/testify/require"
)

func (f *fixture) product(t *testing.T, tenantID string) string {
	t.Helper()
	ctx := context.Background()
	var category, product string
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		"INSERT INTO categories (tenant_id, name) VALUES ($1, 'Minuman') RETURNING id::text", tenantID).Scan(&category))
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		"INSERT INTO products (tenant_id, category_id, name, price) VALUES ($1, $2, 'Es Teh', 5000) RETURNING id::text",
		tenantID, category).Scan(&product))
	return product
}

func (f *fixture) movement(t *testing.T, product, reason string, delta int64) map[string]any {
	return map[string]any{
		"id": f.id(t), "revision": 1, "product_id": product, "product_name": "Es Teh",
		"reason": reason, "delta_qty": delta, "occurred_at_ms": time.Now().UnixMilli(),
		"employee_name": "Sari",
	}
}

// Stock movements ride the same push contract as money: logged before domain
// processing, one result per row, an exact retry accepted without a second
// movement, and a bad row refused without failing its neighbours.
func TestStockMovementsPushThroughTheSameContract(t *testing.T) {
	f := setup(t)
	product := f.product(t, f.binding.Tenant.ID)

	received := f.movement(t, product, "received", 5)
	for attempt := 0; attempt < 3; attempt++ {
		rows := f.push("stock_movements", received)
		accepted(t, rows)
		require.NotNil(t, rows[0].StockSeq)
		require.EqualValues(t, 5, *rows[0].BalanceAfter)
		require.Equal(t, attempt == 0, *rows[0].Inserted)
	}
	require.EqualValues(t, 1, f.count(t, "stock_movements"))
	require.EqualValues(t, 3, f.count(t, "ingest_log"))

	// Identity comes from the token: an outlet in the row is not in the schema.
	withOutlet := f.movement(t, product, "sale", -1)
	withOutlet["outlet_id"] = f.binding.Outlet.ID

	otherTenant := ""
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		"INSERT INTO tenants (name, slug) VALUES ('other', gen_random_uuid()::text) RETURNING id::text").Scan(&otherTenant))
	foreign := f.movement(t, f.product(t, otherTenant), "sale", -1)

	sale := f.movement(t, product, "sale", -2)
	rows := f.push("stock_movements", withOutlet, foreign, sale)
	require.Len(t, rows, 3)
	for _, row := range rows[:2] {
		require.Equal(t, wire.PushResultStatus("rejected"), row.Status)
		require.Equal(t, wire.PushResultCode("schema_rejected"), *row.Code)
		require.Nil(t, row.StockSeq)
	}
	require.Equal(t, wire.PushResultStatus("accepted"), rows[2].Status)
	require.EqualValues(t, 3, *rows[2].BalanceAfter)

	var qty int64
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		"SELECT qty_on_hand FROM outlet_stock WHERE outlet_id = $1", f.binding.Outlet.ID).Scan(&qty))
	require.EqualValues(t, 3, qty)
}
