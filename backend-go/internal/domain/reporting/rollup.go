package reporting

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// rollupTables are every table a slice owns, in the order they are rebuilt.
var rollupTables = []string{
	"daily_sales_rollup", "daily_category_rollup", "daily_product_rollup", "daily_employee_rollup",
	"daily_payment_rollup", "hourly_sales_rollup", "daily_adjustment_rollup", "daily_product_category_rollup",
}

// revenue is the till's rule: every order that is not undone.
const revenue = `status NOT IN ('cancelled', 'refunded')`

// sliceOrders is the WHERE of every statement: one outlet's business day.
const sliceOrders = `tenant_id = $1 AND outlet_id = $2 AND business_date = $3::date`

// The totals never join order_items: a join fans every order into one row per
// line and multiplies each SUM over orders. Items are summed in their own
// subquery and added as scalars.
const salesSQL = `
WITH o AS (
	SELECT id, ` + revenue + ` AS rev, status, subtotal, discount, tax, service_charge_amount,
	       total, refunded_amount
	FROM orders
	WHERE ` + sliceOrders + `
), i AS (
	SELECT COALESCE(sum(it.quantity), 0) AS items,
	       COALESCE(sum(COALESCE(it.unit_cost, 0) * it.quantity), 0) AS cogs,
	       COALESCE(sum(it.quantity) FILTER (WHERE it.unit_cost IS NOT NULL), 0) AS costed
	FROM order_items it
	JOIN o ON o.id = it.order_id AND o.rev
	WHERE it.tenant_id = $1 AND it.business_date = $3::date
)
INSERT INTO daily_sales_rollup (
	tenant_id, outlet_id, business_date, order_count, subtotal, discount, tax, service_charge,
	revenue, items_sold, cost_of_goods, costed_items, discounted_orders,
	cancelled_count, cancelled_amount, refunded_count, refunded_amount,
	gross_sales, all_discount, sales_returns, anomaly_count, calculation_version)
SELECT $1, $2, $3::date,
	count(*) FILTER (WHERE rev),
	COALESCE(sum(subtotal) FILTER (WHERE rev), 0),
	COALESCE(sum(discount) FILTER (WHERE rev), 0),
	COALESCE(sum(tax) FILTER (WHERE rev), 0),
	COALESCE(sum(service_charge_amount) FILTER (WHERE rev), 0),
	COALESCE(sum(total) FILTER (WHERE rev), 0),
	(SELECT items FROM i), (SELECT cogs FROM i), (SELECT costed FROM i),
	count(*) FILTER (WHERE rev AND discount > 0),
	count(*) FILTER (WHERE status = 'cancelled'),
	COALESCE(sum(COALESCE(refunded_amount, total)) FILTER (WHERE status = 'cancelled'), 0),
	count(*) FILTER (WHERE status = 'refunded'),
	COALESCE(sum(COALESCE(refunded_amount, total)) FILTER (WHERE status = 'refunded'), 0),
	-- The waterfall. Gross keeps a refunded order IN, because the sale did
	-- happen; the return then takes it out again, which is what makes a refund
	-- visible instead of the day quietly shrinking. Identically:
	-- gross - all_discount - sales_returns == subtotal - discount over "rev".
	COALESCE(sum(subtotal) FILTER (WHERE status <> 'cancelled'), 0),
	COALESCE(sum(discount) FILTER (WHERE status <> 'cancelled'), 0),
	COALESCE(sum(subtotal - discount) FILTER (WHERE status = 'refunded'), 0),
	-- An anomaly is an order whose own arithmetic does not close, or one that
	-- handed back more than it ever took. A refund of LESS than the total is
	-- NOT an anomaly — it is a partial refund the till recorded honestly, and
	-- F1 shows it beside the return rather than inventing lines for it. A NULL
	-- refunded_amount means the whole total, so it is not compared at all:
	-- an IS DISTINCT FROM test would flag every ordinary full refund.
	count(*) FILTER (WHERE total <> subtotal - discount + tax + service_charge_amount
		OR (status = 'refunded' AND refunded_amount > total)), 2
FROM o
HAVING count(*) > 0`

// orderLines joins a slice's revenue orders to their lines on the partition key.
const orderLines = `
FROM orders o
JOIN order_items it ON it.tenant_id = o.tenant_id AND it.business_date = o.business_date AND it.order_id = o.id
WHERE o.tenant_id = $1 AND o.outlet_id = $2 AND o.business_date = $3::date AND o.` + revenue

const productSQL = `
INSERT INTO daily_product_rollup (tenant_id, outlet_id, business_date, product_key, product_name,
	name_at_ms, quantity, gross_sales, cost_of_goods, costed_quantity)
SELECT $1, $2, $3::date,
	COALESCE(NULLIF(it.payload->>'product_id', ''), 'name:' || it.product_name),
	(array_agg(it.product_name ORDER BY o.placed_at_ms DESC, it.id DESC))[1],
	max(o.placed_at_ms),
	sum(it.quantity), sum(it.unit_price * it.quantity),
	sum(COALESCE(it.unit_cost, 0) * it.quantity),
	COALESCE(sum(it.quantity) FILTER (WHERE it.unit_cost IS NOT NULL), 0)
` + orderLines + `
GROUP BY 4`

const employeeSQL = `
INSERT INTO daily_employee_rollup (tenant_id, outlet_id, business_date, cashier_key, cashier_name,
	name_at_ms, order_count, revenue, discount, net_sales)
SELECT $1, $2, $3::date,
	COALESCE(NULLIF(payload->>'cashier_id', ''), 'name:' || cashier_name),
	(array_agg(cashier_name ORDER BY placed_at_ms DESC, id DESC))[1],
	max(placed_at_ms), count(*), sum(total), sum(discount), sum(subtotal - discount)
FROM orders
WHERE ` + sliceOrders + ` AND ` + revenue + `
GROUP BY 4`

const paymentSQL = `
INSERT INTO daily_payment_rollup (tenant_id, outlet_id, business_date, payment_method, order_count, revenue)
SELECT $1, $2, $3::date, payment_method, count(*), sum(total)
FROM orders
WHERE ` + sliceOrders + ` AND ` + revenue + `
GROUP BY payment_method`

// Every per-dimension rollup — hour, product, category, cashier — is over the
// revenue orders only, so its gross is the day's gross MINUS what was refunded
// and its net adds up to exactly daily_sales_rollup's subtotal - discount. The
// waterfall's wider gross lives on daily_sales_rollup alone.
const hourlySQL = `
INSERT INTO hourly_sales_rollup (tenant_id, outlet_id, business_date, hour, order_count, revenue, net_sales, gross_sales)
SELECT $1, $2, $3::date,
	extract(hour FROM (to_timestamp(o.placed_at_ms / 1000.0) AT TIME ZONE t.timezone))::smallint,
	count(*), sum(o.total), sum(o.subtotal - o.discount), sum(o.subtotal)
FROM orders o
CROSS JOIN (SELECT timezone FROM tenants WHERE id = $1) t
WHERE o.tenant_id = $1 AND o.outlet_id = $2 AND o.business_date = $3::date AND o.` + revenue + `
GROUP BY 4`

// Discounts are labelled by what the till recorded beside them — the promo, or
// the manager who authorised a manual discount — and undone orders by who
// authorised the void or refund.
const adjustmentSQL = `
INSERT INTO daily_adjustment_rollup (tenant_id, outlet_id, business_date, kind, label, order_count, amount)
SELECT $1, $2, $3::date, 'discount', COALESCE(payload->>'promo_name', ''), count(*), sum(discount)
FROM orders
WHERE ` + sliceOrders + ` AND ` + revenue + ` AND discount > 0
GROUP BY 5
UNION ALL
SELECT $1, $2, $3::date, status, COALESCE(authorized_by, ''), count(*), sum(COALESCE(refunded_amount, total))
FROM orders
WHERE ` + sliceOrders + ` AND status IN ('cancelled', 'refunded')
GROUP BY 4, 5`

const categoryInsertSQL = `
INSERT INTO daily_category_rollup (tenant_id, outlet_id, business_date, category_key, category_name,
	name_at_ms, gross_sales, net_sales, items_sold)
SELECT $1, $2, $3::date, u.k, u.n, u.a, u.g, u.ne, u.i
FROM unnest($4::text[], $5::text[], $6::bigint[], $7::bigint[], $8::bigint[], $9::bigint[])
	AS u(k, n, a, g, ne, i)`

// RecomputeSlice rebuilds every rollup of one slice and reports whether the
// slice is now clean.
//
// False means a change landed while it ran: the marker is left for the next
// run, and the caller (the River job) snoozes and runs again. The rollups
// written are still correct for the snapshot they were computed on.
func (s *Service) RecomputeSlice(ctx context.Context, tenantID, outletID string, day time.Time) (bool, error) {
	if !validation.UUID(outletID) || day.IsZero() {
		return false, ErrNotFound
	}
	date := day.Format(time.DateOnly)

	var generation int64
	err := pg.InTenantSnapshotTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SET LOCAL statement_timeout = '120s'"); err != nil {
			return err
		}
		err := tx.QueryRow(ctx, `
			SELECT generation FROM report_dirty_slices
			WHERE tenant_id = $1 AND outlet_id = $2 AND business_date = $3::date`,
			tenantID, outletID, date).Scan(&generation)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		return writeSlice(ctx, tx, tenantID, outletID, date)
	})
	if err != nil {
		return false, err
	}

	if s.afterRollup != nil {
		s.afterRollup()
	}

	clean := false
	err = pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		if generation == 0 {
			// There was no marker on the snapshot. One that exists now was made
			// by a sale the snapshot did not see.
			return tx.QueryRow(ctx, `
				SELECT NOT EXISTS (SELECT 1 FROM report_dirty_slices
				                   WHERE tenant_id = $1 AND outlet_id = $2 AND business_date = $3::date)`,
				tenantID, outletID, date).Scan(&clean)
		}
		tag, err := tx.Exec(ctx, `
			DELETE FROM report_dirty_slices
			WHERE tenant_id = $1 AND outlet_id = $2 AND business_date = $3::date AND generation = $4`,
			tenantID, outletID, date, generation)
		clean = err == nil && tag.RowsAffected() == 1
		return err
	})
	return clean, err
}

// writeSlice deletes and rebuilds every rollup of one slice on the caller's
// transaction. A slice with no orders leaves no rows at all.
func writeSlice(ctx context.Context, tx pgx.Tx, tenantID, outletID, date string) error {
	for _, table := range rollupTables {
		// table is one of this file's constants, never request input.
		if _, err := tx.Exec(ctx, `DELETE FROM `+table+` WHERE `+sliceOrders, tenantID, outletID, date); err != nil {
			return fmt.Errorf("clear %s: %w", table, err)
		}
	}

	for _, stmt := range []struct{ table, sql string }{
		{"daily_sales_rollup", salesSQL},
		{"daily_product_rollup", productSQL},
		{"daily_employee_rollup", employeeSQL},
		{"daily_payment_rollup", paymentSQL},
		{"hourly_sales_rollup", hourlySQL},
		{"daily_adjustment_rollup", adjustmentSQL},
	} {
		if _, err := tx.Exec(ctx, stmt.sql, tenantID, outletID, date); err != nil {
			return fmt.Errorf("write %s: %w", stmt.table, err)
		}
	}

	// The category split and the product-inside-category split share one read
	// and one allocation, so they cannot disagree by a rounding rupiah.
	return writeCategoryAndProduct(ctx, tx, tenantID, outletID, date)
}
