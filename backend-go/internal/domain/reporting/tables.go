package reporting

import (
	"fmt"
	"time"
)

type cellKind int

const (
	cellText cellKind = iota
	cellInt
	cellDecimal
)

// Cell is a text, an integer or a two-decimal number. Numbers stay numbers in a
// spreadsheet, so a merchant can sum a column without cleaning it first.
type Cell struct {
	Kind  cellKind
	Text  string
	Int   int64
	Float float64
}

func (c Cell) IsText() bool    { return c.Kind == cellText }
func (c Cell) IsInt() bool     { return c.Kind == cellInt }
func (c Cell) IsDecimal() bool { return c.Kind == cellDecimal }

func textCell(s string) Cell         { return Cell{Kind: cellText, Text: s} }
func intCell(v int64) Cell           { return Cell{Kind: cellInt, Int: v} }
func decimalCell(v float64) Cell     { return Cell{Kind: cellDecimal, Float: v} }
func row(cells ...Cell) []Cell       { return cells }
func kv(label string, v Cell) []Cell { return row(textCell(label), v) }

// Table is one section of an export: a title, a header and its rows.
type Table struct {
	Title  string
	Header []string
	Rows   [][]Cell
}

// Weekdays names the days of the week for the report and its exports, indexed
// by time.Weekday so Sunday is 0 — the same order Go uses, not the Indonesian
// week that starts on Monday. The SORT is by weekday; the label is just a word.
var Weekdays = [7]string{"Minggu", "Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu"}

// Tables lays a report out as the sections every export format writes, in the
// order the page shows them. loc formats the computed-at time on the merchant's
// clock.
//
// The export carries the same metrics, the same waterfall order and the same
// labels as the screen, plus the provenance a file needs that a page does not:
// which outlets, which period, whose clock, when it was computed, under which
// rules, and whether every day in it had been recomputed yet. A spreadsheet
// outlives the screen it came from, and a figure with no scope on it is a
// figure somebody will misread next quarter.
func Tables(r Report, loc *time.Location) []Table {
	period := r.From.Format(time.DateOnly) + " s.d. " + r.To.Format(time.DateOnly)
	outlet := r.OutletName
	if outlet == "" {
		outlet = "Semua outlet"
	}
	computed := "belum dihitung"
	if r.ComputedAt != nil {
		computed = r.ComputedAt.In(loc).Format("2006-01-02 15:04")
	}
	completeness := "lengkap"
	if r.Incomplete() {
		completeness = fmt.Sprintf("belum lengkap — %d hari-outlet masih memakai rumus lama", r.LegacySlices)
	}
	if r.PendingSlices > 0 {
		completeness = fmt.Sprintf("%s; %d hari-outlet menunggu perhitungan ulang", completeness, r.PendingSlices)
	}

	scope := Table{Title: "Cakupan", Header: []string{"Keterangan", "Nilai"}, Rows: [][]Cell{
		kv("Periode", textCell(period)),
		kv("Outlet", textCell(outlet)),
		kv("Zona waktu", textCell(r.Timezone)),
		kv("Data per", textCell(computed)),
		kv("Versi perhitungan", intCell(int64(r.CalculationVersion))),
		kv("Kelengkapan data", textCell(completeness)),
		kv("Order dengan nominal tidak konsisten", intCell(r.AnomalyCount)),
	}}

	// The waterfall reads top to bottom, and the two totals below it are what
	// it produces: money collected, and profit. Tax and service charge sit
	// between the two on purpose — they raise the first and never the second.
	summary := Table{Title: "Ringkasan penjualan", Header: []string{"Metrik", "Nilai"}, Rows: [][]Cell{
		kv("Penjualan kotor", intCell(r.GrossSales)),
		kv("Diskon", intCell(r.AllDiscount)),
		kv("Retur penjualan", intCell(r.SalesReturns)),
		kv("Penjualan bersih", intCell(r.NetSales)),
		kv("Pajak (PB1)", intCell(r.Tax)),
		kv("Service charge", intCell(r.ServiceCharge)),
		kv("Total penerimaan penjualan", intCell(r.Revenue)),
		kv("Jumlah order", intCell(r.OrderCount)),
		kv("Rata-rata penjualan per order", intCell(r.AverageOrder)),
		kv("Item terjual", intCell(r.ItemsSold)),
		kv("HPP", intCell(r.CostOfGoods)),
		kv("Laba kotor", intCell(r.GrossProfit)),
		kv("Margin kotor (%)", marginCell(r)),
		kv("Cakupan HPP (%)", decimalCell(r.CostCoverage*100)),
		kv("Order berdiskon", intCell(r.DiscountedOrders)),
		kv("Order dibatalkan", intCell(r.CancelledCount)),
		kv("Nilai dibatalkan", intCell(r.CancelledAmount)),
		kv("Order refund", intCell(r.RefundedCount)),
		kv("Nilai refund uang", intCell(r.RefundedAmount)),
	}}

	daily := Table{Title: "Harian", Header: []string{"Tanggal", "Penjualan bersih", "Penerimaan", "Order"}}
	for _, d := range r.Daily {
		daily.Rows = append(daily.Rows, row(textCell(d.Date.Format(time.DateOnly)),
			intCell(d.NetSales), intCell(d.Revenue), intCell(d.Orders)))
	}

	weekdays := Table{Title: "Hari dalam minggu", Header: []string{"Hari", "Penjualan bersih", "Penerimaan", "Order", "Jumlah hari"}}
	for _, w := range r.ByWeekday {
		weekdays.Rows = append(weekdays.Rows, row(textCell(Weekdays[w.Weekday]),
			intCell(w.NetSales), intCell(w.Revenue), intCell(w.Orders), intCell(w.Days)))
	}

	outlets := Table{Title: "Outlet", Header: []string{"Outlet", "Penjualan bersih", "Penerimaan", "Order"}}
	for _, l := range r.ByOutlet {
		outlets.Rows = append(outlets.Rows, row(textCell(l.Label), intCell(l.Net), intCell(l.Value), intCell(l.Count)))
	}

	categories := Table{Title: "Kategori", Header: []string{"Kategori", "Penjualan kotor", "Penjualan bersih", "Item", "Kontribusi (%)"}}
	for _, c := range r.ByCategory {
		categories.Rows = append(categories.Rows, row(textCell(CategoryLabel(c)), intCell(c.Gross), intCell(c.Net),
			intCell(c.Items), decimalCell(c.ContributionPercent)))
	}

	products := Table{Title: "Produk", Header: []string{"Produk", "Qty", "Penjualan kotor", "Penjualan bersih", "HPP", "Cakupan HPP (%)"}}
	for _, p := range r.ByProduct {
		products.Rows = append(products.Rows, row(textCell(p.Name), intCell(p.Quantity), intCell(p.Revenue),
			intCell(p.NetSales), intCell(p.CostOfGoods), decimalCell(p.Coverage()*100)))
	}

	// One table rather than one per category: a spreadsheet with a sheet per
	// category cannot be sorted or pivoted, and a menu can have forty.
	inCategory := Table{Title: "Item teratas per kategori", Header: []string{"Kategori", "Produk", "Qty", "Penjualan bersih"}}
	for _, g := range r.ByProductInCategory {
		for _, p := range g.Products {
			inCategory.Rows = append(inCategory.Rows, row(textCell(categoryName(g.CategoryKey, g.CategoryName)),
				textCell(p.Name), intCell(p.Quantity), intCell(p.NetSales)))
		}
	}

	cashiers := Table{Title: "Kasir", Header: []string{"Kasir", "Penjualan bersih", "Penerimaan", "Order"}}
	for _, l := range r.ByCashier {
		cashiers.Rows = append(cashiers.Rows, row(textCell(l.Label), intCell(l.Net), intCell(l.Value), intCell(l.Count)))
	}

	hours := Table{Title: "Per jam", Header: []string{"Jam", "Penjualan bersih", "Penerimaan", "Order"}}
	for _, h := range r.ByHour {
		hours.Rows = append(hours.Rows, row(textCell(fmt.Sprintf("%02d:00", h.Hour)),
			intCell(h.NetSales), intCell(h.Revenue), intCell(h.Orders)))
	}

	// Payments show what was collected and nothing else: a tender has no net.
	payments := Table{Title: "Pembayaran", Header: []string{"Metode", "Penerimaan", "Order"}}
	for _, l := range r.ByPayment {
		payments.Rows = append(payments.Rows, row(textCell(l.Label), intCell(l.Value), intCell(l.Count)))
	}

	audit := Table{Title: "Audit diskon & void", Header: []string{"Jenis", "Keterangan", "Order", "Nilai"}}
	for _, a := range r.Adjustments {
		audit.Rows = append(audit.Rows, row(textCell(AdjustmentKindLabel(a.Kind)), textCell(AdjustmentLabel(a)),
			intCell(a.Count), intCell(a.Amount)))
	}

	return []Table{scope, summary, daily, weekdays, outlets, categories, products, inCategory,
		cashiers, hours, payments, audit}
}

// marginCell writes an em dash rather than a zero when there is nothing to
// divide by. A margin over no sales is undefined, and printing "0,00" invites
// a reader to treat a period with no trade as a period that lost money.
func marginCell(r Report) Cell {
	margin, ok := r.GrossMargin()
	if !ok {
		return textCell("—")
	}
	return decimalCell(margin)
}

func categoryName(key, name string) string {
	if key == Uncategorised || name == "" {
		return "Tanpa kategori"
	}
	return name
}

// Coverage is the share of this product's quantity that carried a cost.
func (p ProductLine) Coverage() float64 {
	if p.Quantity == 0 {
		return 0
	}
	return float64(p.CostedQuantity) / float64(p.Quantity)
}

// CategoryLabel names a category row, including the bucket with no category.
func CategoryLabel(c CategorySales) string { return categoryName(c.Key, c.Name) }

func AdjustmentKindLabel(kind string) string {
	switch kind {
	case "discount":
		return "Diskon"
	case "cancelled":
		return "Dibatalkan"
	case "refunded":
		return "Refund"
	}
	return kind
}

// AdjustmentLabel is what the till recorded beside an adjustment, or a
// placeholder when it recorded nothing.
func AdjustmentLabel(a Adjustment) string {
	if a.Label != "" {
		return a.Label
	}
	if a.Kind == "discount" {
		return "Diskon tanpa label"
	}
	return "Tanpa otorisasi tercatat"
}
