package v2

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/render"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

// ReportService is the reporting domain as the device API uses it. The SAME
// service the Backoffice uses, deliberately: two implementations of "what did
// we sell" is two answers to one question, and the whole point of F1 is that a
// till and a panel agree.
type ReportService interface {
	Report(ctx context.Context, tenantID string, f reporting.Filter) (reporting.Report, error)
	Today(ctx context.Context, tenantID string) (time.Time, error)
}

// reportLimit is per device. A dashboard that refreshes on a timer is the
// normal caller, and a rollup read is cheap but not free.
var reportLimit = redisx.Limit{Burst: 30, Window: time.Minute}

// tillReports serves both report endpoints. The permission decides what is in
// the body, and it is applied to the RESULT rather than to the rendering: a
// figure withheld by a template is still in the JSON.
func (h *Handler) tillReports(permission auth.Permission) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		b := bindingFrom(r.Context())
		if ok, retry := redisx.Allow(r.Context(), h.rdb, "reports:device:"+b.Device.ID, reportLimit); !ok {
			h.tooManyRequests(w, retry)
			return
		}
		actor, err := h.ingest.WhoIsAtTheTill(r.Context(), b, r.Header.Get("X-Cashier-Token"))
		if err != nil {
			h.tillReply(w, nil, err)
			return
		}
		access := actor.Access
		if !access.Grants(permission) {
			w.Header().Set("Cache-Control", "no-store")
			render.Error(w, h.logger, http.StatusForbidden, "forbidden",
				"Akun ini tidak punya izin melihat laporan tersebut.")
			return
		}

		filter, err := h.reportFilter(r, b, access)
		if err != nil {
			w.Header().Set("Cache-Control", "no-store")
			render.Error(w, h.logger, http.StatusBadRequest, "invalid_filter", err.Error())
			return
		}

		report, err := h.reports.Report(r.Context(), b.Tenant.ID, filter)
		if errors.Is(err, reporting.ErrNotFound) {
			w.Header().Set("Cache-Control", "no-store")
			render.Error(w, h.logger, http.StatusBadRequest, "invalid_filter", "Outlet tidak dikenal.")
			return
		}
		if problems, invalid := validation.As(err); invalid {
			w.Header().Set("Cache-Control", "no-store")
			render.Error(w, h.logger, http.StatusBadRequest, "invalid_filter", firstMessage(problems))
			return
		}
		if err != nil {
			h.logger.Error("till report failed", "error", err)
			w.Header().Set("Cache-Control", "no-store")
			render.Error(w, h.logger, http.StatusServiceUnavailable, "server_unavailable", "Coba lagi sebentar.")
			return
		}

		// Cost and profit leave the server only for whoever may see them.
		// Stripping here rather than in the client is the difference between a
		// figure being hidden and a figure never being sent.
		full := access.Grants(auth.ViewFinancialReports)
		if !full {
			report = report.WithoutCostData()
		}

		// no-store, not no-cache: a shared tablet must not keep yesterday's
		// takings in a cache for the next person who opens the screen.
		w.Header().Set("Cache-Control", "no-store")
		render.JSON(w, h.logger, http.StatusOK, map[string]any{"data": reportBody(report, filter, full)})
	}
}

// reportFilter reads the range and outlet a till asked for.
//
// The device's own branch is the default and the only one most people can
// have: widening to the whole company needs BOTH the summary permission and
// the permission to manage outlets, which together are the shape of "this
// person is responsible for more than one branch".
func (h *Handler) reportFilter(r *http.Request, b devices.Binding, role auth.Access) (reporting.Filter, error) {
	today, err := h.reports.Today(r.Context(), b.Tenant.ID)
	if err != nil {
		return reporting.Filter{}, err
	}
	q := r.URL.Query()
	filter, _ := reporting.ResolvePeriod(period(q.Get("period")), today,
		reporting.ParseDate(q.Get("from")), reporting.ParseDate(q.Get("to")))

	switch outlet := q.Get("outlet_id"); outlet {
	case "":
		filter.OutletID = b.Outlet.ID
	case "all":
		if !role.Grants(auth.ManageOutlets) {
			return filter, errors.New("Akun ini hanya bisa melihat outlet perangkat ini.")
		}
		filter.OutletID = ""
	default:
		if outlet != b.Outlet.ID && !role.Grants(auth.ManageOutlets) {
			return filter, errors.New("Akun ini hanya bisa melihat outlet perangkat ini.")
		}
		filter.OutletID = outlet
	}
	if err := filter.Validate(reporting.MaxReportDays); err != nil {
		problems, _ := validation.As(err)
		return filter, errors.New(firstMessage(problems))
	}
	return filter, nil
}

// period defaults a missing preset to a custom range, so from/to alone work
// without the caller also naming a preset.
func period(preset string) string {
	if preset == "" {
		return reporting.PeriodCustom
	}
	return preset
}

func firstMessage(problems validation.Errors) string {
	for _, field := range []string{"from", "to", "outlet"} {
		if msg, ok := problems[field]; ok {
			return msg
		}
	}
	for _, msg := range problems {
		return msg
	}
	return "Filter tidak valid."
}

// reportBody is the wire shape both endpoints return.
//
// Every response carries its own provenance — period, scope, timezone,
// calculation version, when it was computed and how many days are still being
// recomputed — because a till caches this for offline use, and a cached figure
// with no scope on it is a figure somebody will read as today's.
func reportBody(r reporting.Report, f reporting.Filter, full bool) map[string]any {
	body := map[string]any{
		"period": map[string]any{
			"from": f.From.Format(time.DateOnly),
			"to":   f.To.Format(time.DateOnly),
			"days": reporting.DaysBetween(f.From, f.To) + 1,
		},
		"scope": map[string]any{
			"outlet_id":   f.OutletID,
			"outlet_name": r.OutletName,
			"all_outlets": f.OutletID == "",
		},
		"timezone":            r.Timezone,
		"calculation_version": r.CalculationVersion,
		"computed_at_ms":      millisOrNil(r.ComputedAt),
		"pending_slices":      r.PendingSlices,
		"incomplete":          r.Incomplete(),
		"anomaly_count":       r.AnomalyCount,
		"server_time_ms":      time.Now().UnixMilli(),
		"sales": map[string]any{
			"gross_sales":      r.GrossSales,
			"discounts":        r.AllDiscount,
			"sales_returns":    r.SalesReturns,
			"net_sales":        r.NetSales,
			"tax":              r.Tax,
			"tax_included":     r.TaxIncluded,
			"service_charge":   r.ServiceCharge,
			"rounding":         r.Rounding,
			"revenue":          r.Revenue,
			"order_count":      r.OrderCount,
			"average_sale":     r.AverageOrder,
			"items_sold":       r.ItemsSold,
			"discounted":       r.DiscountedOrders,
			"cancelled_count":  r.CancelledCount,
			"cancelled_amount": r.CancelledAmount,
			"refunded_count":   r.RefundedCount,
			"refunded_amount":  r.RefundedAmount,
		},
		"by_hour":       hourLines(r),
		"by_weekday":    weekdayLines(r),
		"by_day":        dayLines(r),
		"by_outlet":     namedLines(r.ByOutlet),
		"by_payment":    namedLines(r.ByPayment),
		"by_sales_type": namedLines(r.BySalesType),
		// Managers need the sales picture promised by the summary endpoint:
		// top products, categories, cashiers and adjustments. Product rows only
		// gain their cost field on the financial endpoint.
		"by_cashier":             namedLines(r.ByCashier),
		"by_category":            categoryLines(r),
		"by_brand":               categoryLinesFor(r.ByBrand),
		"by_product":             productLines(r.ByProduct, full),
		"by_product_in_category": productsInCategories(r, full),
		"adjustments":            adjustmentLines(r),
	}
	if !full {
		return body
	}
	// The cost half of the report, and the breakdowns that carry cost with
	// them, only for whoever may see what the merchant pays for stock.
	body["profit"] = map[string]any{
		"cost_of_goods": r.CostOfGoods,
		"gross_profit":  r.GrossProfit,
		"cost_coverage": r.CostCoverage,
		"margin":        marginOrNil(r),
	}
	return body
}

func categoryLinesFor(lines []reporting.CategorySales) []map[string]any {
	out := make([]map[string]any, 0, len(lines))
	for _, b := range lines {
		label := b.Name
		if b.Key == reporting.Uncategorised || label == "" {
			label = "Tanpa brand"
		}
		out = append(out, map[string]any{"key": b.Key, "label": label, "gross_sales": b.Gross,
			"net_sales": b.Net, "items": b.Items, "contribution": b.ContributionPercent})
	}
	return out
}

func millisOrNil(t *time.Time) any {
	if t == nil {
		return nil
	}
	return t.UnixMilli()
}

// marginOrNil is null rather than zero when there are no sales to divide by.
// A client that reads a zero as a margin draws a flat line for a period with
// no trade, which is a different claim from "there is nothing to show".
func marginOrNil(r reporting.Report) any {
	margin, ok := r.GrossMargin()
	if !ok {
		return nil
	}
	return margin
}

func namedLines(lines []reporting.Line) []map[string]any {
	out := make([]map[string]any, 0, len(lines))
	for _, l := range lines {
		out = append(out, map[string]any{
			"key": l.Key, "label": l.Label, "revenue": l.Value, "net_sales": l.Net, "count": l.Count,
		})
	}
	return out
}

func hourLines(r reporting.Report) []map[string]any {
	out := make([]map[string]any, 0, len(r.ByHour))
	for _, h := range r.ByHour {
		out = append(out, map[string]any{
			"hour": h.Hour, "net_sales": h.NetSales, "revenue": h.Revenue, "count": h.Orders,
		})
	}
	return out
}

// weekdayLines uses Go's numbering, Sunday = 0, and says how many days of that
// weekday actually traded so a client can average rather than rank a range
// that is not a whole number of weeks.
func weekdayLines(r reporting.Report) []map[string]any {
	out := make([]map[string]any, 0, len(r.ByWeekday))
	for _, w := range r.ByWeekday {
		out = append(out, map[string]any{
			"weekday": int(w.Weekday), "label": reporting.Weekdays[w.Weekday],
			"net_sales": w.NetSales, "revenue": w.Revenue, "count": w.Orders, "days": w.Days,
		})
	}
	return out
}

func dayLines(r reporting.Report) []map[string]any {
	out := make([]map[string]any, 0, len(r.Daily))
	for _, d := range r.Daily {
		out = append(out, map[string]any{
			"date": d.Date.Format(time.DateOnly), "net_sales": d.NetSales, "revenue": d.Revenue, "count": d.Orders,
		})
	}
	return out
}

func categoryLines(r reporting.Report) []map[string]any {
	out := make([]map[string]any, 0, len(r.ByCategory))
	for _, c := range r.ByCategory {
		out = append(out, map[string]any{
			"key": c.Key, "label": reporting.CategoryLabel(c), "gross_sales": c.Gross,
			"net_sales": c.Net, "items": c.Items, "contribution": c.ContributionPercent,
		})
	}
	return out
}

func productLines(lines []reporting.ProductLine, includeCost bool) []map[string]any {
	out := make([]map[string]any, 0, len(lines))
	for _, p := range lines {
		row := map[string]any{
			"key": p.Key, "label": p.Name, "quantity": p.Quantity,
			"gross_sales": p.Revenue, "net_sales": p.NetSales,
		}
		if includeCost {
			row["cost_of_goods"] = p.CostOfGoods
		}
		out = append(out, row)
	}
	return out
}

func productsInCategories(r reporting.Report, includeCost bool) []map[string]any {
	out := make([]map[string]any, 0, len(r.ByProductInCategory))
	for _, g := range r.ByProductInCategory {
		out = append(out, map[string]any{
			"key":   g.CategoryKey,
			"label": reporting.CategoryLabel(reporting.CategorySales{Key: g.CategoryKey, Name: g.CategoryName}),
			"items": productLines(g.Products, includeCost),
		})
	}
	return out
}

func adjustmentLines(r reporting.Report) []map[string]any {
	out := make([]map[string]any, 0, len(r.Adjustments))
	for _, a := range r.Adjustments {
		out = append(out, map[string]any{
			"kind": a.Kind, "label": reporting.AdjustmentLabel(a), "count": a.Count, "amount": a.Amount,
		})
	}
	return out
}
