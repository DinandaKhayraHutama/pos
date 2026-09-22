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

// fingerprints render every rollup row of one slice as text, without
// computed_at, so a stored slice and a freshly computed one compare exactly.
var fingerprints = map[string]string{
	"daily_product_category_rollup": `concat_ws('|', category_key, product_key, product_name, name_at_ms, quantity, gross_sales, net_sales)`,
	"daily_sales_rollup": `concat_ws('|', order_count, subtotal, discount, tax, service_charge, revenue,
		items_sold, cost_of_goods, costed_items, discounted_orders, cancelled_count, cancelled_amount,
		refunded_count, refunded_amount, gross_sales, all_discount, sales_returns, anomaly_count, calculation_version)`,
	"daily_category_rollup":   `concat_ws('|', category_key, category_name, name_at_ms, gross_sales, net_sales, items_sold)`,
	"daily_product_rollup":    `concat_ws('|', product_key, product_name, name_at_ms, quantity, gross_sales, cost_of_goods, costed_quantity, net_sales)`,
	"daily_employee_rollup":   `concat_ws('|', cashier_key, cashier_name, name_at_ms, order_count, revenue, discount, net_sales)`,
	"daily_payment_rollup":    `concat_ws('|', payment_method, order_count, revenue)`,
	"hourly_sales_rollup":     `concat_ws('|', hour, order_count, revenue, net_sales, gross_sales)`,
	"daily_adjustment_rollup": `concat_ws('|', kind, label, order_count, amount)`,
}

// errRollback ends a verification transaction without keeping its writes.
var errRollback = errors.New("reporting: verification rollback")

// VerifySlice compares a slice's stored rollups with what the orders say now,
// and returns the tables that disagree.
//
// It recomputes the slice with the same statements a job uses, on one snapshot,
// inside a transaction it always rolls back — so nothing it computes is kept,
// and "the check and the job disagree about the rules" cannot hide drift. A
// slice with changes pending is skipped (pending = true): its rollups are
// expected to be behind.
func (s *Service) VerifySlice(ctx context.Context, tenantID, outletID string, day time.Time) (mismatches []string, pending bool, err error) {
	if !validation.UUID(outletID) || day.IsZero() {
		return nil, false, ErrNotFound
	}
	date := day.Format(time.DateOnly)

	err = pg.InTenantSnapshotTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `
			SELECT EXISTS (SELECT 1 FROM report_dirty_slices
			               WHERE tenant_id = $1 AND outlet_id = $2 AND business_date = $3::date)`,
			tenantID, outletID, date).Scan(&pending); err != nil {
			return err
		}
		if pending {
			return errRollback
		}

		stored, err := sliceFingerprint(ctx, tx, tenantID, outletID, date)
		if err != nil {
			return err
		}
		if err := writeSlice(ctx, tx, tenantID, outletID, date); err != nil {
			return err
		}
		fresh, err := sliceFingerprint(ctx, tx, tenantID, outletID, date)
		if err != nil {
			return err
		}
		for _, table := range rollupTables {
			if stored[table] != fresh[table] {
				mismatches = append(mismatches, table)
			}
		}
		return errRollback
	})
	if errors.Is(err, errRollback) {
		err = nil
	}
	return mismatches, pending, err
}

func sliceFingerprint(ctx context.Context, tx pgx.Tx, tenantID, outletID, date string) (map[string]string, error) {
	out := make(map[string]string, len(rollupTables))
	for _, table := range rollupTables {
		var fp string
		// table and expression are this file's constants.
		err := tx.QueryRow(ctx, fmt.Sprintf(`
			SELECT COALESCE(string_agg(%s, E'\n' ORDER BY %s), '')
			FROM %s WHERE `+sliceOrders, fingerprints[table], fingerprints[table], table),
			tenantID, outletID, date).Scan(&fp)
		if err != nil {
			return nil, fmt.Errorf("fingerprint %s: %w", table, err)
		}
		out[table] = fp
	}
	return out, nil
}
