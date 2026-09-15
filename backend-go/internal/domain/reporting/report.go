package reporting

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// Line is one grouped figure: an outlet, a cashier, a payment method.
type Line struct {
	Key   string
	Label string
	Value int64
	Count int64
}

type DayLine struct {
	Date    time.Time
	Revenue int64
	Orders  int64
}

type HourLine struct {
	Hour    int
	Revenue int64
	Orders  int64
}

type ProductLine struct {
	Key            string
	Name           string
	Quantity       int64
	Revenue        int64
	CostOfGoods    int64
	CostedQuantity int64
}

type Adjustment struct {
	// "discount", "cancelled" or "refunded".
	Kind   string
	Label  string
	Count  int64
	Amount int64
}

// Report is everything the sales report shows, read from rollups only.
type Report struct {
	From       time.Time
	To         time.Time
	OutletID   string
	OutletName string
	// The merchant's name and clock, for a report that has to stand on its own
	// as a PDF or an e-mailed file.
	BusinessName string
	Timezone     string

	Revenue          int64
	Subtotal         int64
	Discount         int64
	Tax              int64
	ServiceCharge    int64
	OrderCount       int64
	AverageOrder     int64
	ItemsSold        int64
	CostOfGoods      int64
	CostedItems      int64
	GrossProfit      int64
	DiscountedOrders int64
	// CostCoverage is the share of items sold that carried a cost, 0 to 1.
	CostCoverage float64

	CancelledCount  int64
	CancelledAmount int64
	RefundedCount   int64
	RefundedAmount  int64

	ByOutlet    []Line
	Daily       []DayLine
	ByCategory  []CategorySales
	ByProduct   []ProductLine
	ByCashier   []Line
	ByPayment   []Line
	ByHour      []HourLine
	Adjustments []Adjustment

	// ComputedAt is the newest rollup computation in the range; nil when the
	// range has no rollups at all.
	ComputedAt *time.Time
	// PendingSlices counts slices in the range with changes not yet rolled up.
	PendingSlices int64
}

// CostCoverageLow says the margin should not be trusted: fewer than nine in ten
// items sold carried a cost.
func (r Report) CostCoverageLow() bool { return r.ItemsSold > 0 && r.CostCoverage < 0.9 }

// Report builds a sales report from rollups. It never reads orders.
func (s *Service) Report(ctx context.Context, tenantID string, f Filter) (Report, error) {
	if err := f.Validate(MaxReportDays); err != nil {
		return Report{}, err
	}
	r := Report{From: f.From, To: f.To, OutletID: f.OutletID}
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		return readReport(ctx, tx, tenantID, f, &r)
	})
	return r, err
}

// rangeOf is the WHERE every rollup read shares; alias is the table alias.
func rangeOf(alias string) string {
	return alias + `.tenant_id = $1 AND ` + alias + `.business_date BETWEEN $2::date AND $3::date
		AND ($4::uuid IS NULL OR ` + alias + `.outlet_id = $4::uuid)`
}

func readReport(ctx context.Context, tx pgx.Tx, tenantID string, f Filter, r *Report) error {
	outlet := outletArg(f.OutletID)
	args := []any{tenantID, f.From.Format(time.DateOnly), f.To.Format(time.DateOnly), outlet}

	if err := tx.QueryRow(ctx, `SELECT name, timezone FROM tenants WHERE id = $1`, tenantID).
		Scan(&r.BusinessName, &r.Timezone); err != nil {
		return err
	}

	if outlet != nil {
		err := tx.QueryRow(ctx, `SELECT name FROM outlets WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL`,
			tenantID, *outlet).Scan(&r.OutletName)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
	}

	if err := tx.QueryRow(ctx, `
		SELECT COALESCE(sum(order_count), 0)::bigint, COALESCE(sum(subtotal), 0)::bigint,
		       COALESCE(sum(discount), 0)::bigint, COALESCE(sum(tax), 0)::bigint,
		       COALESCE(sum(service_charge), 0)::bigint, COALESCE(sum(revenue), 0)::bigint,
		       COALESCE(sum(items_sold), 0)::bigint, COALESCE(sum(cost_of_goods), 0)::bigint,
		       COALESCE(sum(costed_items), 0)::bigint, COALESCE(sum(discounted_orders), 0)::bigint,
		       COALESCE(sum(cancelled_count), 0)::bigint, COALESCE(sum(cancelled_amount), 0)::bigint,
		       COALESCE(sum(refunded_count), 0)::bigint, COALESCE(sum(refunded_amount), 0)::bigint,
		       max(computed_at)
		FROM daily_sales_rollup r
		WHERE `+rangeOf("r"), args...).Scan(
		&r.OrderCount, &r.Subtotal, &r.Discount, &r.Tax, &r.ServiceCharge, &r.Revenue,
		&r.ItemsSold, &r.CostOfGoods, &r.CostedItems, &r.DiscountedOrders,
		&r.CancelledCount, &r.CancelledAmount, &r.RefundedCount, &r.RefundedAmount, &r.ComputedAt,
	); err != nil {
		return err
	}
	if r.OrderCount > 0 {
		r.AverageOrder = r.Revenue / r.OrderCount
	}
	if r.ItemsSold > 0 {
		r.CostCoverage = float64(r.CostedItems) / float64(r.ItemsSold)
	}
	r.GrossProfit = r.Revenue - r.CostOfGoods

	var err error
	if r.ByOutlet, err = lines(ctx, tx, `
		SELECT r.outlet_id::text, o.name, sum(r.revenue)::bigint, sum(r.order_count)::bigint
		FROM daily_sales_rollup r
		JOIN outlets o ON o.tenant_id = r.tenant_id AND o.id = r.outlet_id
		WHERE `+rangeOf("r")+`
		GROUP BY 1, 2 HAVING sum(r.order_count) > 0
		ORDER BY 3 DESC, 2, 1`, args); err != nil {
		return err
	}

	if r.Daily, err = collect(ctx, tx, `
		SELECT business_date, sum(revenue)::bigint, sum(order_count)::bigint
		FROM daily_sales_rollup r
		WHERE `+rangeOf("r")+`
		GROUP BY 1 HAVING sum(order_count) > 0
		ORDER BY 1`, args, func(row pgx.CollectableRow) (DayLine, error) {
		var d DayLine
		return d, row.Scan(&d.Date, &d.Revenue, &d.Orders)
	}); err != nil {
		return err
	}

	// The current name wins; a category deleted since shows its newest
	// snapshot name, never whichever day happened to be read first.
	if r.ByCategory, err = collect(ctx, tx, `
		SELECT r.category_key,
		       COALESCE(c.name,
		                (array_agg(r.category_name ORDER BY r.name_at_ms DESC, r.business_date DESC, r.outlet_id DESC)
		                 FILTER (WHERE r.category_name <> ''))[1], ''),
		       sum(r.gross_sales)::bigint, sum(r.net_sales)::bigint, sum(r.items_sold)::bigint
		FROM daily_category_rollup r
		LEFT JOIN categories c ON c.tenant_id = r.tenant_id AND c.id::text = r.category_key AND c.deleted_at IS NULL
		WHERE `+rangeOf("r")+`
		GROUP BY r.category_key, c.name`, args, func(row pgx.CollectableRow) (CategorySales, error) {
		var c CategorySales
		return c, row.Scan(&c.Key, &c.Name, &c.Gross, &c.Net, &c.Items)
	}); err != nil {
		return err
	}
	var totalNet int64
	for _, c := range r.ByCategory {
		totalNet += c.Net
	}
	WithContribution(r.ByCategory, totalNet)
	SortCategories(r.ByCategory)

	if r.ByProduct, err = collect(ctx, tx, `
		SELECT r.product_key,
		       COALESCE(p.name, (array_agg(r.product_name ORDER BY r.name_at_ms DESC, r.business_date DESC, r.outlet_id DESC))[1]),
		       sum(r.quantity)::bigint, sum(r.gross_sales)::bigint,
		       sum(r.cost_of_goods)::bigint, sum(r.costed_quantity)::bigint
		FROM daily_product_rollup r
		LEFT JOIN products p ON p.tenant_id = r.tenant_id AND p.id::text = r.product_key AND p.deleted_at IS NULL
		WHERE `+rangeOf("r")+`
		GROUP BY r.product_key, p.name
		ORDER BY 4 DESC, 3 DESC, 1`, args, func(row pgx.CollectableRow) (ProductLine, error) {
		var p ProductLine
		return p, row.Scan(&p.Key, &p.Name, &p.Quantity, &p.Revenue, &p.CostOfGoods, &p.CostedQuantity)
	}); err != nil {
		return err
	}

	if r.ByCashier, err = lines(ctx, tx, `
		SELECT r.cashier_key,
		       (array_agg(r.cashier_name ORDER BY r.name_at_ms DESC, r.business_date DESC, r.outlet_id DESC))[1],
		       sum(r.revenue)::bigint, sum(r.order_count)::bigint
		FROM daily_employee_rollup r
		WHERE `+rangeOf("r")+`
		GROUP BY 1
		ORDER BY 3 DESC, 1`, args); err != nil {
		return err
	}

	if r.ByPayment, err = lines(ctx, tx, `
		SELECT r.payment_method, r.payment_method, sum(r.revenue)::bigint, sum(r.order_count)::bigint
		FROM daily_payment_rollup r
		WHERE `+rangeOf("r")+`
		GROUP BY 1
		ORDER BY 3 DESC, 1`, args); err != nil {
		return err
	}
	for i := range r.ByPayment {
		r.ByPayment[i].Label = PaymentLabel(r.ByPayment[i].Key)
	}

	if r.ByHour, err = collect(ctx, tx, `
		SELECT r.hour, sum(r.revenue)::bigint, sum(r.order_count)::bigint
		FROM hourly_sales_rollup r
		WHERE `+rangeOf("r")+`
		GROUP BY 1
		ORDER BY 1`, args, func(row pgx.CollectableRow) (HourLine, error) {
		var h HourLine
		return h, row.Scan(&h.Hour, &h.Revenue, &h.Orders)
	}); err != nil {
		return err
	}

	if r.Adjustments, err = collect(ctx, tx, `
		SELECT r.kind, r.label, sum(r.order_count)::bigint, sum(r.amount)::bigint
		FROM daily_adjustment_rollup r
		WHERE `+rangeOf("r")+`
		GROUP BY 1, 2
		ORDER BY 1, 4 DESC, 2`, args, func(row pgx.CollectableRow) (Adjustment, error) {
		var a Adjustment
		return a, row.Scan(&a.Kind, &a.Label, &a.Count, &a.Amount)
	}); err != nil {
		return err
	}
	sort.SliceStable(r.Adjustments, func(i, j int) bool {
		return adjustmentOrder(r.Adjustments[i].Kind) < adjustmentOrder(r.Adjustments[j].Kind)
	})

	return tx.QueryRow(ctx, `
		SELECT count(*) FROM report_dirty_slices r
		WHERE `+rangeOf("r"), args...).Scan(&r.PendingSlices)
}

func adjustmentOrder(kind string) int {
	switch kind {
	case "discount":
		return 0
	case "cancelled":
		return 1
	}
	return 2
}

func lines(ctx context.Context, tx pgx.Tx, sql string, args []any) ([]Line, error) {
	return collect(ctx, tx, sql, args, func(row pgx.CollectableRow) (Line, error) {
		var l Line
		return l, row.Scan(&l.Key, &l.Label, &l.Value, &l.Count)
	})
}

func collect[T any](ctx context.Context, tx pgx.Tx, sql string, args []any, scan func(pgx.CollectableRow) (T, error)) ([]T, error) {
	rows, err := tx.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, scan)
	if out == nil {
		out = []T{}
	}
	return out, err
}

// PaymentLabel names a till payment method for people.
func PaymentLabel(method string) string {
	switch method {
	case "cash":
		return "Tunai"
	case "card":
		return "Kartu"
	case "qris":
		return "QRIS"
	case "transfer":
		return "Transfer"
	case "ewallet", "e_wallet":
		return "E-wallet"
	}
	return method
}
