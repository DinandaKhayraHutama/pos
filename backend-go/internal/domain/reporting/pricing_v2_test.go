package reporting_test

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/pricing"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
)

// v2Order rings up a Fase 3 receipt: inclusive PB1 10%, service 5%, a 10%
// item discount on the coffee, Rp 1.000 off the bill, rounding to 100, sold as
// "GoFood" and paid by "EDC BCA" (kind card), dated on WIT.
func (f *fixture) v2Order(placed time.Time) wire.Order {
	f.t.Helper()
	in := pricing.Input{
		Version: pricing.VersionV2, TaxMode: pricing.TaxInclusive, ServiceRateBP: 500, ServiceTaxable: true,
		RoundingUnit: 100, RoundingMode: pricing.RoundNearest,
		BillDiscount: &pricing.Discount{Kind: pricing.DiscountAmount, Value: 1000},
		Lines: []pricing.Line{
			{UnitPrice: 16500, Quantity: 2, TaxRateBP: 1000, Discount: &pricing.Discount{Kind: pricing.DiscountPercent, Value: 1000}},
			{UnitPrice: 27500, Quantity: 1, TaxRateBP: 1000},
		},
	}
	res, err := pricing.Compute(in)
	require.NoError(f.t, err)
	require.NotZero(f.t, res.TaxIncluded)
	require.NotZero(f.t, res.Rounding)

	cost := int64(5000)
	o := f.order("paid", placed, ptr(f.cashierSiti), "Siti", "card", 0, 0, 0, []saleLine{
		{productID: ptr(f.coffee), categoryID: ptr(f.drinks), name: "Kopi Susu", categoryName: "Minuman", price: 16500, cost: &cost, qty: 2},
		{productID: ptr(f.rice), categoryID: ptr(f.food), name: "Nasi Goreng", categoryName: "Makanan", price: 27500, qty: 1},
	})
	o.Type = "custom"
	o.SalesTypeId, o.SalesTypeName = ptr(uuid()), ptr("GoFood")
	o.PaymentMethodId, o.PaymentMethodName = ptr(uuid()), ptr("EDC BCA")
	o.TzOffsetMinutes = ptr(540)
	o.PricingVersion = ptr(2)
	o.Pricing = &wire.PricingSnapshot{TaxMode: "inclusive", ServiceRateBp: 500, ServiceTaxable: true,
		RoundingUnit: 100, RoundingMode: "nearest", BillDiscount: &wire.DiscountSpec{Kind: "amount", Value: 1000}}
	o.Subtotal, o.Discount, o.ServiceChargeAmount, o.Tax = res.Subtotal, res.Discount, res.ServiceCharge, res.Tax
	o.TaxIncluded, o.RoundingAmount, o.Total, o.AmountPaid = ptr(res.TaxIncluded), ptr(res.Rounding), res.Total, res.Total
	for i, l := range res.Lines {
		it := &o.Items[i]
		it.TaxRateBp = ptr(int(in.Lines[i].TaxRateBP))
		it.LineDiscount, it.BillDiscountShare, it.ServiceShare = ptr(l.LineDiscount), ptr(l.BillDiscountShare), ptr(l.ServiceShare)
		it.TaxAmount, it.TaxIncluded, it.NetAmount = ptr(l.TaxAmount), ptr(l.TaxIncluded), ptr(l.NetAmount)
		if d := in.Lines[i].Discount; d != nil {
			it.Discount = &wire.DiscountSpec{Kind: wire.DiscountSpecKind(d.Kind), Value: d.Value}
		}
	}
	return o
}

// The invariant every Fase 3 report rests on: a version 2 receipt's lines
// carry their own net, and every breakdown sums to the same net sales the
// waterfall produces — gross − discounts − returns − included tax.
func TestAVersion2ReceiptReconcilesAcrossEveryBreakdown(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	f.seedDay()
	v2 := f.v2Order(f.at(10, 30))
	f.accepted(f.push("orders", v2))
	f.recompute(f.outletA)

	r, err := f.svc.Report(ctx, f.tenantID, reporting.Filter{OutletID: f.outletA, From: f.day, To: f.day})
	require.NoError(t, err)

	// seedDay's revenue orders net 49500 + 20000; the v2 receipt nets the
	// sum of its lines' net_amount, never subtotal − discount.
	v2Net := *v2.Items[0].NetAmount + *v2.Items[1].NetAmount
	require.Equal(t, v2.Subtotal-v2.Discount-*v2.TaxIncluded, v2Net)
	require.Equal(t, 49500+20000+v2Net, r.NetSales)
	require.Equal(t, *v2.TaxIncluded, r.TaxIncluded)
	require.Equal(t, *v2.RoundingAmount, r.Rounding)

	require.Equal(t, r.NetSales, r.GrossSales-r.AllDiscount-r.SalesReturns-r.TaxIncluded, "the waterfall closes")
	require.Equal(t, r.Revenue, r.NetSales+r.Tax+r.ServiceCharge+r.Rounding, "revenue is net plus what was collected on top")

	var categories, products, brands int64
	for _, c := range r.ByCategory {
		categories += c.Net
	}
	for _, p := range r.ByProduct {
		products += p.NetSales
	}
	for _, b := range r.ByBrand {
		brands += b.Net
	}
	require.Equal(t, r.NetSales, categories)
	require.Equal(t, r.NetSales, products)
	require.Equal(t, r.NetSales, brands)

	var gofood *reporting.Line
	for i := range r.BySalesType {
		if r.BySalesType[i].Label == "GoFood" {
			gofood = &r.BySalesType[i]
		}
	}
	require.NotNil(t, gofood, "%+v", r.BySalesType)
	require.Equal(t, v2Net, gofood.Net)
	require.Equal(t, v2.Total, gofood.Value)

	var edc *reporting.Line
	for i := range r.ByPayment {
		if r.ByPayment[i].Label == "EDC BCA" {
			edc = &r.ByPayment[i]
		}
	}
	require.NotNil(t, edc, "the method's own name is the label: %+v", r.ByPayment)

	// Dated on WIT: 10:30 in Jakarta is 12:30 on the receipt's own clock.
	found := false
	for _, h := range r.ByHour {
		if h.Hour == 12 {
			found = true
			require.Equal(t, v2Net, h.NetSales)
		}
	}
	require.True(t, found, "%+v", r.ByHour)
}
