package reporting

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// MaxAnomalyRows bounds one inventory. The count is exact; the listing is a
// sample, because the point of this tool is to see the SHAPE of what is wrong
// before deciding anything, not to page through a year of receipts.
const MaxAnomalyRows = 200

// Anomaly is one order whose stored figures do not close.
//
// F1 does not repair any of these. A receipt is what the till printed and the
// customer holds; rewriting one to make a report tidy would make the report
// agree with nothing. So they are counted into the rollups, listed here, and
// left alone.
type Anomaly struct {
	OrderID       string
	OutletID      string
	OutletName    string
	BusinessDate  time.Time
	Number        string
	Status        string
	Kind          string
	Subtotal      int64
	Discount      int64
	Tax           int64
	ServiceCharge int64
	Total         int64
	// Expected is subtotal - discount + tax + service charge: what Total would
	// be if the order's own arithmetic closed.
	Expected       int64
	RefundedAmount *int64
}

// AnomalyReport is the read-only inventory of a merchant's inconsistent money.
type AnomalyReport struct {
	From  time.Time
	To    time.Time
	Total int64
	// ByKind counts every anomaly in the range, not only the listed sample.
	ByKind map[string]int64
	Rows   []Anomaly
}

// The two kinds are deliberately separate. A total that does not equal its own
// parts is arithmetic that never closed — a client bug, or a receipt written
// by a version that computed differently. A refund larger than the sale is
// money that cannot have been handed back. They need different answers, so
// they are never merged into one "bad row" count.
const (
	AnomalyTotalMismatch   = "total_mismatch"
	AnomalyOverRefund      = "over_refund"
	AnomalyPricingMismatch = "pricing_mismatch"
)

const anomalyWhere = `
	o.tenant_id = $1 AND o.business_date BETWEEN $2::date AND $3::date
	AND ($4::uuid IS NULL OR o.outlet_id = $4::uuid)
	AND (o.total <> o.subtotal - o.discount + o.tax - o.tax_included + o.service_charge_amount + o.rounding_amount
	     OR o.pricing_mismatch
	     OR (o.status = 'refunded' AND o.refunded_amount > o.total))`

// Anomalies lists orders whose figures do not close, without changing
// anything. It is the one read in this package that goes to the order tables
// rather than the rollups, and it is allowed to because it is not a report:
// it is an inventory run by hand, bounded by a date range and a row limit.
func (s *Service) Anomalies(ctx context.Context, tenantID string, f Filter) (AnomalyReport, error) {
	if err := f.Validate(MaxReportDays); err != nil {
		return AnomalyReport{}, err
	}
	out := AnomalyReport{From: f.From, To: f.To, ByKind: map[string]int64{}, Rows: []Anomaly{}}
	args := []any{tenantID, f.From.Format(time.DateOnly), f.To.Format(time.DateOnly), outletArg(f.OutletID)}

	// One snapshot, so the counts and the sample describe the same instant.
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT CASE WHEN o.total <> o.subtotal - o.discount + o.tax - o.tax_included + o.service_charge_amount + o.rounding_amount
			            THEN '`+AnomalyTotalMismatch+`' WHEN o.pricing_mismatch THEN '`+AnomalyPricingMismatch+`'
			            ELSE '`+AnomalyOverRefund+`' END,
			       count(*)::bigint
			FROM orders o WHERE `+anomalyWhere+` GROUP BY 1`, args...)
		if err != nil {
			return err
		}
		kinds, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Line, error) {
			var l Line
			return l, row.Scan(&l.Key, &l.Count)
		})
		if err != nil {
			return err
		}
		for _, k := range kinds {
			out.ByKind[k.Key] = k.Count
			out.Total += k.Count
		}
		if out.Total == 0 {
			return nil
		}

		rows, err = tx.Query(ctx, `
			SELECT o.id::text, o.outlet_id::text, ol.name, o.business_date,
			       COALESCE(o.payload->>'number', ''), o.status,
			       CASE WHEN o.total <> o.subtotal - o.discount + o.tax - o.tax_included + o.service_charge_amount + o.rounding_amount
			            THEN '`+AnomalyTotalMismatch+`' WHEN o.pricing_mismatch THEN '`+AnomalyPricingMismatch+`'
			            ELSE '`+AnomalyOverRefund+`' END,
			       o.subtotal, o.discount, o.tax, o.service_charge_amount, o.total,
			       o.subtotal - o.discount + o.tax - o.tax_included + o.service_charge_amount + o.rounding_amount, o.refunded_amount
			FROM orders o
			JOIN outlets ol ON ol.tenant_id = o.tenant_id AND ol.id = o.outlet_id
			WHERE `+anomalyWhere+`
			ORDER BY o.business_date DESC, o.placed_at_ms DESC, o.id
			LIMIT $5`, append(args, MaxAnomalyRows)...)
		if err != nil {
			return err
		}
		out.Rows, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Anomaly, error) {
			var a Anomaly
			err := row.Scan(&a.OrderID, &a.OutletID, &a.OutletName, &a.BusinessDate, &a.Number, &a.Status,
				&a.Kind, &a.Subtotal, &a.Discount, &a.Tax, &a.ServiceCharge, &a.Total, &a.Expected, &a.RefundedAmount)
			return a, err
		})
		return err
	})
	if out.Rows == nil {
		out.Rows = []Anomaly{}
	}
	return out, err
}
