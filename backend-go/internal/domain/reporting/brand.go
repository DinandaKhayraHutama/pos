package reporting

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

const brandLinesSQL = `
SELECT o.id::text, o.discount, o.subtotal, o.placed_at_ms,
       COALESCE(it.payload->>'brand_id', ''), '',
       sum(it.unit_price * it.quantity)::bigint, sum(it.quantity)::bigint,
       -- A version 2 line carries its own net (item discount, bill share and
       -- included tax already out). Re-allocating the header discount would
       -- ignore item discounts and count included tax as sales.
       CASE WHEN bool_and(it.payload ? 'net_amount')
            THEN sum((it.payload->>'net_amount')::bigint)::bigint END
` + orderLines + `
GROUP BY o.id, o.discount, o.subtotal, o.placed_at_ms, 5
ORDER BY o.placed_at_ms, o.id, 5`

const brandInsertSQL = `
INSERT INTO daily_brand_rollup (tenant_id, outlet_id, business_date, brand_key, brand_name,
 name_at_ms, gross_sales, net_sales, items_sold)
SELECT $1, $2, $3::date, u.k, u.n, u.a, u.g, u.ne, u.i
FROM unnest($4::text[], $5::text[], $6::bigint[], $7::bigint[], $8::bigint[], $9::bigint[])
 AS u(k,n,a,g,ne,i)`

func writeBrands(ctx context.Context, tx pgx.Tx, tenantID, outletID, date string) error {
	rows, err := tx.Query(ctx, brandLinesSQL, tenantID, outletID, date)
	if err != nil {
		return fmt.Errorf("read brand lines: %w", err)
	}
	lines, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (CategoryLine, error) {
		var (
			line CategoryLine
			net  *int64
		)
		err := row.Scan(&line.OrderID, &line.OrderDiscount, &line.OrderSubtotal, &line.PlacedAtMs,
			&line.CategoryID, &line.SnapshotName, &line.LineTotal, &line.Quantity, &net)
		if net != nil {
			line.NetTotal, line.NetKnown = *net, true
		}
		return line, err
	})
	if err != nil {
		return fmt.Errorf("read brand lines: %w", err)
	}
	brands := AggregateCategories(lines)
	if len(brands) == 0 {
		return nil
	}
	keys, names := make([]string, len(brands)), make([]string, len(brands))
	namedAt, gross, net, items := make([]int64, len(brands)), make([]int64, len(brands)), make([]int64, len(brands)), make([]int64, len(brands))
	for i, b := range brands {
		keys[i], names[i], namedAt[i], gross[i], net[i], items[i] = b.Key, b.Name, b.NameAtMs, b.Gross, b.Net, b.Items
	}
	if _, err := tx.Exec(ctx, brandInsertSQL, tenantID, outletID, date, keys, names, namedAt, gross, net, items); err != nil {
		return fmt.Errorf("write daily_brand_rollup: %w", err)
	}
	return nil
}
