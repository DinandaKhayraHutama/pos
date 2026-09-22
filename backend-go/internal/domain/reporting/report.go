package reporting

import (
	"context"
	"errors"
	"slices"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// Line is one grouped figure: an outlet, a cashier, a payment method.
//
// Value is money received — the old meaning of "revenue", kept because every
// caller already reads it that way. Net is the sales figure the waterfall
// works in: it excludes tax and service charge, and Σ Net over outlets or
// cashiers is the report's NetSales. A payment method has no Net, because
// money is taken in receipts, not in net sales.
type Line struct {
	Key   string
	Label string
	Value int64
	Net   int64
	Count int64
}

type DayLine struct {
	Date     time.Time
	Revenue  int64
	NetSales int64
	Orders   int64
}

type HourLine struct {
	Hour     int
	Revenue  int64
	NetSales int64
	Orders   int64
}

// WeekdayLine is one day of the week across the range. The weekday comes from
// the BUSINESS date, not from a timestamp: a sale rung up after midnight
// belongs to the trading day it was part of, which is the whole reason a
// business date exists.
type WeekdayLine struct {
	Weekday  time.Weekday
	Revenue  int64
	NetSales int64
	Orders   int64
	// Days is how many calendar days of this weekday the range actually
	// traded, so "Saturday" over five weeks is comparable to "Monday" over
	// four. Without it a range that is not a whole number of weeks ranks the
	// weekday it happens to contain twice.
	Days int64
}

type ProductLine struct {
	Key            string
	Name           string
	Quantity       int64
	Revenue        int64
	NetSales       int64
	CostOfGoods    int64
	CostedQuantity int64
}

// CategoryProducts is one category and the items sold inside it, largest net
// first. Its products sum to the category's own net, because both come from
// the same allocation.
type CategoryProducts struct {
	CategoryKey  string
	CategoryName string
	Products     []ProductLine
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

	// The waterfall, in the order it is read: gross sales, less the discounts
	// given on those same orders, less what was returned, is net sales. Tax
	// and service charge are added AFTER it to reach Revenue — they are money
	// collected on someone else's behalf, so they never raise a sales figure
	// and never raise profit.
	GrossSales   int64
	AllDiscount  int64
	SalesReturns int64
	NetSales     int64
	// AnomalyCount is orders whose own arithmetic does not close. Reported,
	// never repaired.
	AnomalyCount int64
	// LegacySlices counts days in the range still computed under the old
	// rules, whose waterfall columns are therefore zero rather than final.
	LegacySlices       int64
	CalculationVersion int
	Revenue            int64
	Subtotal           int64
	Discount           int64
	Tax                int64
	ServiceCharge      int64
	OrderCount         int64
	AverageOrder       int64
	ItemsSold          int64
	CostOfGoods        int64
	CostedItems        int64
	GrossProfit        int64
	DiscountedOrders   int64
	// CostCoverage is the share of items sold that carried a cost, 0 to 1.
	CostCoverage float64

	CancelledCount  int64
	CancelledAmount int64
	RefundedCount   int64
	RefundedAmount  int64

	ByOutlet            []Line
	Daily               []DayLine
	ByCategory          []CategorySales
	ByProduct           []ProductLine
	ByProductInCategory []CategoryProducts
	ByCashier           []Line
	ByPayment           []Line
	ByHour              []HourLine
	ByWeekday           []WeekdayLine
	Adjustments         []Adjustment

	// ComputedAt is the newest rollup computation in the range; nil when the
	// range has no rollups at all.
	ComputedAt *time.Time
	// PendingSlices counts slices in the range with changes not yet rolled up.
	PendingSlices int64
}

// CostCoverageLow says the margin should not be trusted: fewer than nine in ten
// items sold carried a cost.
func (r Report) CostCoverageLow() bool { return r.ItemsSold > 0 && r.CostCoverage < 0.9 }

// Incomplete says the waterfall is still being rebuilt: some day in the range
// was computed under the old rules, so its gross, discount and return columns
// are zero rather than final. A screen must say so rather than presenting
// those zeroes as the answer.
func (r Report) Incomplete() bool { return r.LegacySlices > 0 }

// GrossMargin is profit as a share of net sales, and the second return says
// whether it means anything. A zero divisor is shown as "—": a margin over no
// sales is not zero percent, it is undefined, and rendering it as 0% invites
// someone to read a flat line as a bad day.
func (r Report) GrossMargin() (float64, bool) {
	if r.NetSales == 0 {
		return 0, false
	}
	return float64(r.GrossProfit) * 100 / float64(r.NetSales), true
}

// WithoutCostData strips everything a manager may not see: cost of goods,
// profit, margin and the coverage that qualifies them. It is applied to the
// RESPONSE, not to the screen — a figure withheld by a template is still in
// the HTML, in the JSON and in anything cached from either.
//
// Sales, receipts, tax, service charge and the whole waterfall stay: a manager
// runs the floor and needs them. What goes is the merchant's buying price.
// The slices are cloned before they are edited: a Report value copies its
// slice HEADERS, so zeroing in place would also blank the report the caller
// still holds — and the caller is often the page that may see the costs.
func (r Report) WithoutCostData() Report {
	r.CostOfGoods, r.CostedItems, r.GrossProfit, r.CostCoverage = 0, 0, 0, 0

	r.ByProduct = slices.Clone(r.ByProduct)
	for i := range r.ByProduct {
		r.ByProduct[i].CostOfGoods, r.ByProduct[i].CostedQuantity = 0, 0
	}

	r.ByProductInCategory = slices.Clone(r.ByProductInCategory)
	for i := range r.ByProductInCategory {
		r.ByProductInCategory[i].Products = slices.Clone(r.ByProductInCategory[i].Products)
		for j := range r.ByProductInCategory[i].Products {
			r.ByProductInCategory[i].Products[j].CostOfGoods = 0
			r.ByProductInCategory[i].Products[j].CostedQuantity = 0
		}
	}
	return r
}

// Report builds a sales report from rollups. It never reads orders.
func (s *Service) Report(ctx context.Context, tenantID string, f Filter) (Report, error) {
	if err := f.Validate(MaxReportDays); err != nil {
		return Report{}, err
	}
	r := Report{CalculationVersion: 2, From: f.From, To: f.To, OutletID: f.OutletID}
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
		       max(computed_at), COALESCE(sum(gross_sales),0)::bigint, COALESCE(sum(all_discount),0)::bigint,
               COALESCE(sum(sales_returns),0)::bigint, COALESCE(sum(anomaly_count),0)::bigint,
               count(*) FILTER (WHERE calculation_version < 2)
		FROM daily_sales_rollup r
		WHERE `+rangeOf("r"), args...).Scan(
		&r.OrderCount, &r.Subtotal, &r.Discount, &r.Tax, &r.ServiceCharge, &r.Revenue,
		&r.ItemsSold, &r.CostOfGoods, &r.CostedItems, &r.DiscountedOrders,
		&r.CancelledCount, &r.CancelledAmount, &r.RefundedCount, &r.RefundedAmount, &r.ComputedAt,
		&r.GrossSales, &r.AllDiscount, &r.SalesReturns, &r.AnomalyCount, &r.LegacySlices,
	); err != nil {
		return err
	}
	r.NetSales = r.Subtotal - r.Discount
	if r.OrderCount > 0 {
		r.AverageOrder = r.NetSales / r.OrderCount
	}
	if r.ItemsSold > 0 {
		r.CostCoverage = float64(r.CostedItems) / float64(r.ItemsSold)
	}
	r.GrossProfit = r.NetSales - r.CostOfGoods

	var err error
	// Comparing outlets is a comparison of SALES, so the net column is what
	// ranks them: one branch charging service and another not would otherwise
	// come out ahead on takings alone.
	if r.ByOutlet, err = lines(ctx, tx, `
		SELECT r.outlet_id::text, o.name, sum(r.revenue)::bigint,
		       sum(r.subtotal - r.discount)::bigint, sum(r.order_count)::bigint
		FROM daily_sales_rollup r
		JOIN outlets o ON o.tenant_id = r.tenant_id AND o.id = r.outlet_id
		WHERE `+rangeOf("r")+`
		GROUP BY 1, 2 HAVING sum(r.order_count) > 0
		ORDER BY 4 DESC, 2, 1`, args); err != nil {
		return err
	}

	if r.Daily, err = collect(ctx, tx, `
		SELECT business_date, sum(revenue)::bigint, sum(subtotal - discount)::bigint, sum(order_count)::bigint
		FROM daily_sales_rollup r
		WHERE `+rangeOf("r")+`
		GROUP BY 1 HAVING sum(order_count) > 0
		ORDER BY 1`, args, func(row pgx.CollectableRow) (DayLine, error) {
		var d DayLine
		return d, row.Scan(&d.Date, &d.Revenue, &d.NetSales, &d.Orders)
	}); err != nil {
		return err
	}

	// The weekday comes from the business date in SQL, with no timezone in
	// sight: the business date is already the merchant's trading day, and
	// converting it again would move a Sunday's late sales into Monday.
	if r.ByWeekday, err = collect(ctx, tx, `
		SELECT extract(isodow FROM r.business_date)::int,
		       sum(r.revenue)::bigint, sum(r.subtotal - r.discount)::bigint,
		       sum(r.order_count)::bigint, count(DISTINCT r.business_date)::bigint
		FROM daily_sales_rollup r
		WHERE `+rangeOf("r")+`
		GROUP BY 1 HAVING sum(r.order_count) > 0
		ORDER BY 1`, args, func(row pgx.CollectableRow) (WeekdayLine, error) {
		var w WeekdayLine
		var isoDow int
		err := row.Scan(&isoDow, &w.Revenue, &w.NetSales, &w.Orders, &w.Days)
		// ISO counts Monday as 1 and Sunday as 7; time.Weekday counts Sunday
		// as 0. Sunday is the one that moves.
		w.Weekday = time.Weekday(isoDow % 7)
		return w, err
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
		       sum(r.quantity)::bigint, sum(r.gross_sales)::bigint, sum(r.net_sales)::bigint,
		       sum(r.cost_of_goods)::bigint, sum(r.costed_quantity)::bigint
		FROM daily_product_rollup r
		LEFT JOIN products p ON p.tenant_id = r.tenant_id AND p.id::text = r.product_key AND p.deleted_at IS NULL
		WHERE `+rangeOf("r")+`
		GROUP BY r.product_key, p.name
		ORDER BY 5 DESC, 3 DESC, 1`, args, func(row pgx.CollectableRow) (ProductLine, error) {
		var p ProductLine
		return p, row.Scan(&p.Key, &p.Name, &p.Quantity, &p.Revenue, &p.NetSales, &p.CostOfGoods, &p.CostedQuantity)
	}); err != nil {
		return err
	}

	if r.ByProductInCategory, err = productsInCategories(ctx, tx, args, r.ByCategory); err != nil {
		return err
	}

	if r.ByCashier, err = lines(ctx, tx, `
		SELECT r.cashier_key,
		       (array_agg(r.cashier_name ORDER BY r.name_at_ms DESC, r.business_date DESC, r.outlet_id DESC))[1],
		       sum(r.revenue)::bigint, sum(r.net_sales)::bigint, sum(r.order_count)::bigint
		FROM daily_employee_rollup r
		WHERE `+rangeOf("r")+`
		GROUP BY 1
		ORDER BY 4 DESC, 1`, args); err != nil {
		return err
	}

	// A payment method's Net is left at zero deliberately: money arrives as a
	// receipt total, tax and service charge included, and splitting a tender
	// into "net" would invent a number nobody took.
	if r.ByPayment, err = lines(ctx, tx, `
		SELECT r.payment_method, r.payment_method, sum(r.revenue)::bigint, 0::bigint, sum(r.order_count)::bigint
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
		SELECT r.hour, sum(r.revenue)::bigint, sum(r.net_sales)::bigint, sum(r.order_count)::bigint
		FROM hourly_sales_rollup r
		WHERE `+rangeOf("r")+`
		GROUP BY 1
		ORDER BY 1`, args, func(row pgx.CollectableRow) (HourLine, error) {
		var h HourLine
		return h, row.Scan(&h.Hour, &h.Revenue, &h.NetSales, &h.Orders)
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

// MaxProductsPerCategory bounds one category's item list. A category with two
// hundred items is a menu, not an insight, and the whole point of this section
// is "what sells inside this group".
const MaxProductsPerCategory = 10

// productsInCategories reads the item breakdown inside every category, in the
// category order the report already resolved — so the names on this section
// are the ones shown above it, deleted categories included, rather than a
// second resolution that could disagree.
func productsInCategories(ctx context.Context, tx pgx.Tx, args []any, categories []CategorySales) ([]CategoryProducts, error) {
	if len(categories) == 0 {
		return []CategoryProducts{}, nil
	}
	rows, err := collect(ctx, tx, `
		SELECT r.category_key, r.product_key,
		       COALESCE(p.name, (array_agg(r.product_name ORDER BY r.name_at_ms DESC, r.business_date DESC, r.outlet_id DESC))[1]),
		       sum(r.quantity)::bigint, sum(r.gross_sales)::bigint, sum(r.net_sales)::bigint
		FROM daily_product_category_rollup r
		LEFT JOIN products p ON p.tenant_id = r.tenant_id AND p.id::text = r.product_key AND p.deleted_at IS NULL
		WHERE `+rangeOf("r")+`
		GROUP BY r.category_key, r.product_key, p.name
		ORDER BY 6 DESC, 4 DESC, 2`, args, func(row pgx.CollectableRow) (struct {
		Category string
		Product  ProductLine
	}, error) {
		var v struct {
			Category string
			Product  ProductLine
		}
		err := row.Scan(&v.Category, &v.Product.Key, &v.Product.Name,
			&v.Product.Quantity, &v.Product.Revenue, &v.Product.NetSales)
		return v, err
	})
	if err != nil {
		return nil, err
	}

	byCategory := map[string][]ProductLine{}
	for _, v := range rows {
		if len(byCategory[v.Category]) < MaxProductsPerCategory {
			byCategory[v.Category] = append(byCategory[v.Category], v.Product)
		}
	}

	out := make([]CategoryProducts, 0, len(categories))
	for _, c := range categories {
		if items := byCategory[c.Key]; len(items) > 0 {
			out = append(out, CategoryProducts{CategoryKey: c.Key, CategoryName: c.Name, Products: items})
		}
	}
	return out, nil
}

func lines(ctx context.Context, tx pgx.Tx, sql string, args []any) ([]Line, error) {
	return collect(ctx, tx, sql, args, func(row pgx.CollectableRow) (Line, error) {
		var l Line
		return l, row.Scan(&l.Key, &l.Label, &l.Value, &l.Net, &l.Count)
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
