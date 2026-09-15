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

// Tables lays a report out as the sections every export format writes, in the
// order the page shows them. loc formats the computed-at time on the merchant's
// clock.
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

	summary := Table{Title: "Ringkasan", Header: []string{"Metrik", "Nilai"}, Rows: [][]Cell{
		kv("Periode", textCell(period)),
		kv("Outlet", textCell(outlet)),
		kv("Pendapatan", intCell(r.Revenue)),
		kv("Subtotal", intCell(r.Subtotal)),
		kv("Diskon", intCell(r.Discount)),
		kv("Pajak (PB1)", intCell(r.Tax)),
		kv("Service charge", intCell(r.ServiceCharge)),
		kv("Jumlah order", intCell(r.OrderCount)),
		kv("Rata-rata per order", intCell(r.AverageOrder)),
		kv("Item terjual", intCell(r.ItemsSold)),
		kv("HPP", intCell(r.CostOfGoods)),
		kv("Laba kotor", intCell(r.GrossProfit)),
		kv("Cakupan HPP (%)", decimalCell(r.CostCoverage*100)),
		kv("Order berdiskon", intCell(r.DiscountedOrders)),
		kv("Order dibatalkan", intCell(r.CancelledCount)),
		kv("Nilai dibatalkan", intCell(r.CancelledAmount)),
		kv("Order refund", intCell(r.RefundedCount)),
		kv("Nilai refund", intCell(r.RefundedAmount)),
		kv("Data per", textCell(computed)),
		kv("Hari-outlet belum diperbarui", intCell(r.PendingSlices)),
	}}

	daily := Table{Title: "Harian", Header: []string{"Tanggal", "Pendapatan", "Order"}}
	for _, d := range r.Daily {
		daily.Rows = append(daily.Rows, row(textCell(d.Date.Format(time.DateOnly)), intCell(d.Revenue), intCell(d.Orders)))
	}

	outlets := Table{Title: "Outlet", Header: []string{"Outlet", "Pendapatan", "Order"}}
	for _, l := range r.ByOutlet {
		outlets.Rows = append(outlets.Rows, row(textCell(l.Label), intCell(l.Value), intCell(l.Count)))
	}

	categories := Table{Title: "Kategori", Header: []string{"Kategori", "Penjualan kotor", "Penjualan bersih", "Item", "Kontribusi (%)"}}
	for _, c := range r.ByCategory {
		categories.Rows = append(categories.Rows, row(textCell(CategoryLabel(c)), intCell(c.Gross), intCell(c.Net),
			intCell(c.Items), decimalCell(c.ContributionPercent)))
	}

	products := Table{Title: "Produk", Header: []string{"Produk", "Qty", "Penjualan", "HPP", "Cakupan HPP (%)"}}
	for _, p := range r.ByProduct {
		products.Rows = append(products.Rows, row(textCell(p.Name), intCell(p.Quantity), intCell(p.Revenue),
			intCell(p.CostOfGoods), decimalCell(p.Coverage()*100)))
	}

	cashiers := Table{Title: "Kasir", Header: []string{"Kasir", "Pendapatan", "Order"}}
	for _, l := range r.ByCashier {
		cashiers.Rows = append(cashiers.Rows, row(textCell(l.Label), intCell(l.Value), intCell(l.Count)))
	}

	hours := Table{Title: "Per jam", Header: []string{"Jam", "Pendapatan", "Order"}}
	for _, h := range r.ByHour {
		hours.Rows = append(hours.Rows, row(textCell(fmt.Sprintf("%02d:00", h.Hour)), intCell(h.Revenue), intCell(h.Orders)))
	}

	payments := Table{Title: "Pembayaran", Header: []string{"Metode", "Pendapatan", "Order"}}
	for _, l := range r.ByPayment {
		payments.Rows = append(payments.Rows, row(textCell(l.Label), intCell(l.Value), intCell(l.Count)))
	}

	audit := Table{Title: "Audit diskon & void", Header: []string{"Jenis", "Keterangan", "Order", "Nilai"}}
	for _, a := range r.Adjustments {
		audit.Rows = append(audit.Rows, row(textCell(AdjustmentKindLabel(a.Kind)), textCell(AdjustmentLabel(a)),
			intCell(a.Count), intCell(a.Amount)))
	}

	return []Table{summary, daily, outlets, categories, products, cashiers, hours, payments, audit}
}

// Coverage is the share of this product's quantity that carried a cost.
func (p ProductLine) Coverage() float64 {
	if p.Quantity == 0 {
		return 0
	}
	return float64(p.CostedQuantity) / float64(p.Quantity)
}

// CategoryLabel names a category row, including the bucket with no category.
func CategoryLabel(c CategorySales) string {
	if c.Key == Uncategorised || c.Name == "" {
		return "Tanpa kategori"
	}
	return c.Name
}

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
