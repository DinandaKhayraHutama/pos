package reporting

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// The category split and the product-inside-category split are computed from
// ONE read, in two passes, and that is what makes them reconcile:
//
//  1. the order's discount is allocated across the categories it touched —
//     byte for byte the allocation AggregateCategories has always done, on
//     rows grouped exactly as categoryLinesSQL grouped them;
//  2. each category's share is then allocated across the products inside it.
//
// Σ product net within a category is therefore its category's net by
// construction, and Σ category net is the day's subtotal − discount. Computing
// the two from separate queries — or grouping them differently — leaves them a
// rupiah apart on any order whose split has a remainder, and a month of those
// is a breakdown that does not add up to its own total.
const productLinesSQL = `
SELECT o.id::text, o.discount, o.subtotal, o.placed_at_ms,
	COALESCE(it.payload->>'category_id', ''), COALESCE(it.category_name, ''),
	COALESCE(NULLIF(it.payload->>'product_id', ''), 'name:' || it.product_name),
	(array_agg(it.product_name ORDER BY it.id DESC))[1],
	sum(it.unit_price * it.quantity)::bigint, sum(it.quantity)::bigint
` + orderLines + `
GROUP BY o.id, o.discount, o.subtotal, o.placed_at_ms, 5, 6, 7
ORDER BY o.placed_at_ms, o.id, 5, 6, 7`

const productCategoryInsertSQL = `
INSERT INTO daily_product_category_rollup (tenant_id, outlet_id, business_date,
	category_key, product_key, product_name, name_at_ms, quantity, gross_sales, net_sales)
SELECT $1, $2, $3::date, u.c, u.p, u.n, u.a, u.q, u.g, u.ne
FROM unnest($4::text[], $5::text[], $6::text[], $7::bigint[], $8::bigint[], $9::bigint[], $10::bigint[])
	AS u(c, p, n, a, q, g, ne)`

// A product sold under two category keys in one slice — some lines carrying a
// category id and some not — is one row here and two there, so the sum is the
// authority rather than either half.
const productNetUpdateSQL = `
UPDATE daily_product_rollup p SET net_sales = n.net
FROM (
	SELECT product_key, sum(net_sales)::bigint AS net
	FROM daily_product_category_rollup
	WHERE ` + sliceOrders + `
	GROUP BY product_key
) n
WHERE p.tenant_id = $1 AND p.outlet_id = $2 AND p.business_date = $3::date
  AND p.product_key = n.product_key`

// productLine is one (order, category, product) group of a slice. The embedded
// CategoryLine is what the category pass consumes, unchanged.
type productLine struct {
	CategoryLine
	ProductKey  string
	ProductName string
}

// productCategoryRow is one row of daily_product_category_rollup.
type productCategoryRow struct {
	CategoryKey string
	ProductKey  string
	Name        string
	NameAtMs    int64
	Quantity    int64
	Gross       int64
	Net         int64
}

// writeCategoryAndProduct rebuilds daily_category_rollup and
// daily_product_category_rollup from one read, and stamps the net it allocated
// onto daily_product_rollup.
func writeCategoryAndProduct(ctx context.Context, tx pgx.Tx, tenantID, outletID, date string) error {
	rows, err := tx.Query(ctx, productLinesSQL, tenantID, outletID, date)
	if err != nil {
		return fmt.Errorf("read product lines: %w", err)
	}
	lines, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (productLine, error) {
		var l productLine
		err := row.Scan(&l.OrderID, &l.OrderDiscount, &l.OrderSubtotal, &l.PlacedAtMs,
			&l.CategoryID, &l.SnapshotName, &l.ProductKey, &l.ProductName, &l.LineTotal, &l.Quantity)
		return l, err
	})
	if err != nil {
		return fmt.Errorf("read product lines: %w", err)
	}
	if len(lines) == 0 {
		return nil
	}

	categories, products := allocateSlice(lines)

	if err := writeCategories(ctx, tx, tenantID, outletID, date, AggregateCategories(categories)); err != nil {
		return err
	}
	return writeProductCategories(ctx, tx, tenantID, outletID, date, products)
}

// allocateSlice folds the product lines back into the category rows
// AggregateCategories expects, and allocates each category's discount share
// across the products inside it.
func allocateSlice(lines []productLine) ([]CategoryLine, []productCategoryRow) {
	var categories []CategoryLine
	totals := map[[2]string]*productCategoryRow{}
	var keys [][2]string

	for start := 0; start < len(lines); {
		end := start + 1
		for end < len(lines) && lines[end].OrderID == lines[start].OrderID {
			end++
		}
		order := lines[start:end]

		// The category rows of this order, in the order the rows arrived —
		// which is categoryLinesSQL's own ordering, because the query shares
		// its GROUP BY prefix and its ORDER BY prefix.
		var catRows []CategoryLine
		var members [][]productLine
		for i := 0; i < len(order); {
			j := i + 1
			row := order[i].CategoryLine
			for j < len(order) && order[j].CategoryID == order[i].CategoryID &&
				order[j].SnapshotName == order[i].SnapshotName {
				row.LineTotal += order[j].LineTotal
				row.Quantity += order[j].Quantity
				j++
			}
			catRows = append(catRows, row)
			members = append(members, order[i:j])
			i = j
		}
		categories = append(categories, catRows...)

		shares := allocate(catRows, order[0].OrderDiscount, order[0].OrderSubtotal)
		for i, group := range members {
			// keyOf reads CategoryID, so the second-level tie-break is on the
			// product key: two products with equal line totals settle the
			// remainder the same way on every recompute.
			within := make([]CategoryLine, len(group))
			for j, p := range group {
				within[j] = CategoryLine{CategoryID: p.ProductKey, LineTotal: p.LineTotal}
			}
			inner := allocate(within, shares[i], catRows[i].LineTotal)

			for j, p := range group {
				key := [2]string{keyOf(catRows[i]), p.ProductKey}
				row := totals[key]
				if row == nil {
					row = &productCategoryRow{CategoryKey: key[0], ProductKey: p.ProductKey}
					totals[key] = row
					keys = append(keys, key)
				}
				row.Gross += p.LineTotal
				row.Quantity += p.Quantity
				row.Net += p.LineTotal - inner[j]
				// The newest snapshot names the product, the same rule the
				// category split uses; the id breaks a same-millisecond tie.
				if p.PlacedAtMs > row.NameAtMs || (p.PlacedAtMs == row.NameAtMs && p.ProductName > row.Name) {
					row.NameAtMs, row.Name = p.PlacedAtMs, p.ProductName
				}
			}
		}
		start = end
	}

	out := make([]productCategoryRow, 0, len(keys))
	for _, k := range keys {
		out = append(out, *totals[k])
	}
	return categories, out
}

func writeCategories(ctx context.Context, tx pgx.Tx, tenantID, outletID, date string, categories []CategorySales) error {
	if len(categories) == 0 {
		return nil
	}
	keys, names := make([]string, len(categories)), make([]string, len(categories))
	namedAt, gross, net, items := make([]int64, len(categories)), make([]int64, len(categories)),
		make([]int64, len(categories)), make([]int64, len(categories))
	for i, c := range categories {
		keys[i], names[i], namedAt[i], gross[i], net[i], items[i] = c.Key, c.Name, c.NameAtMs, c.Gross, c.Net, c.Items
	}
	if _, err := tx.Exec(ctx, categoryInsertSQL, tenantID, outletID, date,
		keys, names, namedAt, gross, net, items); err != nil {
		return fmt.Errorf("write daily_category_rollup: %w", err)
	}
	return nil
}

func writeProductCategories(ctx context.Context, tx pgx.Tx, tenantID, outletID, date string, rows []productCategoryRow) error {
	if len(rows) == 0 {
		return nil
	}
	cats, keys, names := make([]string, len(rows)), make([]string, len(rows)), make([]string, len(rows))
	namedAt, qty, gross, net := make([]int64, len(rows)), make([]int64, len(rows)),
		make([]int64, len(rows)), make([]int64, len(rows))
	for i, r := range rows {
		cats[i], keys[i], names[i] = r.CategoryKey, r.ProductKey, r.Name
		namedAt[i], qty[i], gross[i], net[i] = r.NameAtMs, r.Quantity, r.Gross, r.Net
	}
	if _, err := tx.Exec(ctx, productCategoryInsertSQL, tenantID, outletID, date,
		cats, keys, names, namedAt, qty, gross, net); err != nil {
		return fmt.Errorf("write daily_product_category_rollup: %w", err)
	}
	if _, err := tx.Exec(ctx, productNetUpdateSQL, tenantID, outletID, date); err != nil {
		return fmt.Errorf("write daily_product_rollup net: %w", err)
	}
	return nil
}
