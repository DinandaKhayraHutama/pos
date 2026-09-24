// Package syncfixture seeds disposable verification tenants. It is used only
// by tests and scripts; Backoffice writers belong in domain packages (Fase 2B).
package syncfixture

import (
	"context"
	"fmt"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
)

// FeedOutletSQL selects the branch Seed numbers its outlet-scoped rows under:
// the tenant's oldest outlet — the one a verification till is bound to when it
// exists before seeding. Tests and scripts that page or explain an
// outlet feed ask for the same one.
const FeedOutletSQL = `SELECT id::text FROM outlets WHERE tenant_id = $1 ORDER BY created_at, id LIMIT 1`

// Seed publishes n rows of every current feed (one of a singleton feed) in
// manifest order, through the
// real counter/write path. Use a fresh tenant with no previously published
// rows: join fixtures pair rows by sequence. The caller owns tenant cleanup.
func Seed(ctx context.Context, feed *syncfeed.Service, tenantID string, n int) error {
	return feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var outletID string
		for _, e := range syncfeed.Entities() {
			columns, values := "", ""
			switch e.Name {
			case "employees":
				columns, values = "name, role, pin_hash", "'Feed Staff ' || g, 'cashier', '$2a$10$verificationonly'"
			case "outlets":
				columns, values = "name", "'Feed Outlet ' || g"
			case "pos_registers":
				columns, values = "name, outlet_id", "'Feed Register ' || g, (SELECT id FROM outlets WHERE tenant_id=$1 ORDER BY id LIMIT 1)"
			case "categories":
				columns, values = "name", "'Feed Category ' || g"
			case "brands":
				columns, values = "name", "'Feed Brand ' || g"
			case "customers":
				columns, values = "id, name", "gen_random_uuid(), 'Feed Customer ' || g"
			case "products":
				// Every fixture product carries a brand, not just a category —
				// otherwise this fixture would never exercise the join a brand
				// filter or report needs, only the case where brand_id is NULL.
				columns, values = "name, price, category_id, brand_id",
					"'Feed Product ' || g, 10000 + g, "+
						"(SELECT id FROM categories WHERE tenant_id=$1 ORDER BY id LIMIT 1), "+
						"(SELECT id FROM brands WHERE tenant_id=$1 ORDER BY id LIMIT 1)"
			case "product_variants":
				columns, values = "name, product_id", "'Feed Variant ' || g, (SELECT id FROM products WHERE tenant_id=$1 ORDER BY id LIMIT 1)"
			case "modifier_groups":
				columns, values = "name", "'Feed Group ' || g"
			case "modifier_options":
				columns, values = "name, group_id", "'Feed Option ' || g, (SELECT id FROM modifier_groups WHERE tenant_id=$1 ORDER BY id LIMIT 1)"
			case "product_modifier_groups":
				columns, values = "product_id, group_id", "(SELECT id FROM products WHERE tenant_id=$1 AND sync_seq=$2+g-1), (SELECT id FROM modifier_groups WHERE tenant_id=$1 ORDER BY id LIMIT 1)"
			case "product_modifier_options":
				columns, values = "product_id, option_id", "(SELECT id FROM products WHERE tenant_id=$1 ORDER BY id LIMIT 1), (SELECT id FROM modifier_options WHERE tenant_id=$1 AND sync_seq=$2+g-1)"
			case "promos":
				columns, values = "name, kind, value", "'Feed Promo ' || g, 'amount', 1000"
			case "promo_outlets":
				columns, values = "promo_id, outlet_id", "(SELECT id FROM promos WHERE tenant_id=$1 AND sync_seq=$2+g-1), (SELECT id FROM outlets WHERE tenant_id=$1 ORDER BY id LIMIT 1)"
			case "outlet_stock":
				// One row per product at the feed outlet; a fresh counter starts
				// at the products' own sequence, so seq pairs them.
				columns, values = "outlet_id, product_id, qty_on_hand", "$4, (SELECT id FROM products WHERE tenant_id=$1 AND sync_seq=$2+g-1), g"
			case "stock_movements":
				columns, values = "id, outlet_id, product_id, reason, delta_qty, balance_after, occurred_at_ms, source, employee_name, product_name, applied_stock_seq",
					"gen_random_uuid(), $4, (SELECT id FROM products WHERE tenant_id=$1 AND sync_seq=$2+g-1), 'received', 1, 1, 0, 'backoffice', 'Feed Staff', 'Feed Product ' || g, $2+g-1"
			case "tables":
				columns, values = "outlet_id, name, area, capacity, sort_order", "$4, 'Feed Table ' || g, 'Feed Area', 4, g"
			case "roles":
				// Custom roles only: the three system roles already exist, seeded
				// with the tenant, and a system_key may appear once per merchant.
				columns, values = "name, permissions", "'Feed Role ' || g, ARRAY['sell', 'viewOwnOrders']"
			case "business_settings":
				columns, values = "tax_rate_bp", "1000"
			case "outlet_settings":
				columns, values = "outlet_id, pricing_model", "$4, 'legacy'"
			case "sales_types":
				columns, values = "name", "'Feed Sales Type ' || g"
			case "payment_methods":
				columns, values = "name, kind", "'Feed Payment ' || g, 'other'"
			case "payment_groups":
				columns, values = "name, method_ids", "'Feed Payment Group ' || g, ARRAY(SELECT id FROM payment_methods WHERE tenant_id=$1 ORDER BY id LIMIT 2)"
			case "discounts":
				columns, values = "name, scope, kind, value", "'Feed Discount ' || g, 'bill', 'amount', 1000"
			case "product_sales_type_prices":
				columns, values = "product_id, sales_type_id, price", "(SELECT id FROM products WHERE tenant_id=$1 AND sync_seq=$2+g-1), (SELECT id FROM sales_types WHERE tenant_id=$1 ORDER BY id LIMIT 1), 12000 + g"
			case "outlet_product_sales_type_prices":
				columns, values = "outlet_id, product_id, sales_type_id, price", "$4, (SELECT id FROM products WHERE tenant_id=$1 AND sync_seq=$2+g-1), (SELECT id FROM sales_types WHERE tenant_id=$1 ORDER BY id LIMIT 1), 13000 + g"
			case "table_status":
				// A fresh branch counter starts the status feed where the tables
				// feed started, so seq pairs each status with its table.
				columns, values = "outlet_id, table_id", "$4, (SELECT id FROM tables WHERE tenant_id=$1 AND outlet_id=$4 AND sync_seq=$2+g-1)"
			default:
				return fmt.Errorf("add a verification fixture for feed %s", e.Name)
			}

			args := []any{tenantID}
			var first int64
			var err error
			rows := n
			if e.Singleton {
				rows = 1
			}
			if e.Scope == syncfeed.ScopeOutlet {
				if outletID == "" {
					if err := w.Tx.QueryRow(ctx, FeedOutletSQL, tenantID).Scan(&outletID); err != nil {
						return fmt.Errorf("seed %s: find feed outlet: %w", e.Name, err)
					}
				}
				first, err = w.OutletSeqBlock(ctx, e.Name, outletID, int64(rows))
			} else {
				first, err = w.SeqBlock(ctx, e.Name, int64(rows))
			}
			if err != nil {
				return err
			}
			args = append(args, first, rows)
			if e.Scope == syncfeed.ScopeOutlet {
				args = append(args, outletID)
			}

			// Table and expressions are code-owned, never user input.
			_, err = w.Tx.Exec(ctx, fmt.Sprintf(
				`INSERT INTO %s (tenant_id, sync_seq, %s)
				 SELECT $1, $2+g-1, %s FROM generate_series(1, $3::int) AS g`,
				e.Table, columns, values), args...)
			if err != nil {
				return fmt.Errorf("seed %s: %w", e.Name, err)
			}
		}
		return nil
	})
}

// ExpectedRows is how many rows a till pulls from a feed Seed wrote n of: one
// for a singleton feed, otherwise n plus the rows every merchant is born with.
func ExpectedRows(e syncfeed.Entity, n int) int {
	if e.Singleton {
		return 1
	}
	return n + e.SystemRows
}
