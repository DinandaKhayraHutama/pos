package reporting_test

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
)

// The expected figures are WRITTEN OUT, not derived from the fixture.
//
// A test that recomputes the answer with the same arithmetic the code uses
// proves only that the code is consistent with itself: change the definition
// of net sales in both places and it stays green. These numbers were worked
// out by hand from the four receipts at Kemang and the two at Bintaro, and
// they are the specification — if the code disagrees with them, the code is
// what moved.
//
// Kemang (fixture.seedDay):
//
//	paid      55000 − 5500 + 4950 PB1          = 54450
//	paid      20000 − 0    + 2000 PB1 + 1000 SC = 23000
//	cancelled 30000                             (never a sale)
//	refunded  15000 + 0                         , 12000 handed back
//
// Bintaro (fixture.seedBintaro):
//
//	paid      35000 − 0 + 3500 PB1 = 38500
//	refunded  15000 + 1500 PB1     = 16500, all 16500 handed back
type expected struct {
	orders, revenue, subtotal, discount, tax, service      int64
	gross, allDiscount, returns, net, average              int64
	items, cogs, costedItems, profit                       int64
	cancelledCount, cancelledAmount, refundCount, refunded int64
}

var kemangDay = expected{
	orders: 2, revenue: 77450, subtotal: 75000, discount: 5500, tax: 6950, service: 1000,
	gross: 90000, allDiscount: 5500, returns: 15000, net: 69500, average: 34750,
	items: 5, cogs: 15000, costedItems: 3, profit: 54500,
	cancelledCount: 1, cancelledAmount: 30000, refundCount: 1, refunded: 12000,
}

var bintaroDay = expected{
	orders: 1, revenue: 38500, subtotal: 35000, discount: 0, tax: 3500, service: 0,
	gross: 50000, allDiscount: 0, returns: 15000, net: 35000, average: 35000,
	items: 3, cogs: 10000, costedItems: 2, profit: 25000,
	cancelledCount: 0, cancelledAmount: 0, refundCount: 1, refunded: 16500,
}

// The chain is the two branches added up, except the average — 104500 over
// three receipts, not the mean of two averages.
var wholeChainDay = expected{
	orders: 3, revenue: 115950, subtotal: 110000, discount: 5500, tax: 10450, service: 1000,
	gross: 140000, allDiscount: 5500, returns: 30000, net: 104500, average: 34833,
	items: 8, cogs: 25000, costedItems: 5, profit: 79500,
	cancelledCount: 1, cancelledAmount: 30000, refundCount: 2, refunded: 28500,
}

func assertTotals(t *testing.T, want expected, got reporting.Report) {
	t.Helper()
	require.EqualValues(t, want.orders, got.OrderCount, "order count")
	require.EqualValues(t, want.revenue, got.Revenue, "revenue")
	require.EqualValues(t, want.subtotal, got.Subtotal, "subtotal")
	require.EqualValues(t, want.discount, got.Discount, "discount")
	require.EqualValues(t, want.tax, got.Tax, "tax")
	require.EqualValues(t, want.service, got.ServiceCharge, "service charge")
	require.EqualValues(t, want.gross, got.GrossSales, "gross sales")
	require.EqualValues(t, want.allDiscount, got.AllDiscount, "discounts in the waterfall")
	require.EqualValues(t, want.returns, got.SalesReturns, "sales returns")
	require.EqualValues(t, want.net, got.NetSales, "net sales")
	require.EqualValues(t, want.average, got.AverageOrder, "average sale")
	require.EqualValues(t, want.items, got.ItemsSold, "items sold")
	require.EqualValues(t, want.cogs, got.CostOfGoods, "cost of goods")
	require.EqualValues(t, want.costedItems, got.CostedItems, "costed items")
	require.EqualValues(t, want.profit, got.GrossProfit, "gross profit")
	require.EqualValues(t, want.cancelledCount, got.CancelledCount, "cancelled count")
	require.EqualValues(t, want.cancelledAmount, got.CancelledAmount, "cancelled amount")
	require.EqualValues(t, want.refundCount, got.RefundedCount, "refunded count")
	require.EqualValues(t, want.refunded, got.RefundedAmount, "money handed back")

	require.EqualValues(t, got.GrossSales-got.AllDiscount-got.SalesReturns, got.NetSales, "the waterfall closes")
	require.EqualValues(t, got.Subtotal-got.Discount, got.NetSales, "and matches the revenue orders")
	require.EqualValues(t, 0, got.AnomalyCount, "the fixture's money all closes")
	require.EqualValues(t, 0, got.LegacySlices, "every slice was computed under the F1 rules")
}

func TestTheWaterfallAndEveryBreakdownReconcileAcrossBranches(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	f.seedDay()
	f.seedBintaro()
	f.recompute(f.outletA)
	f.recompute(f.outletB)

	kemang, err := f.svc.Report(ctx, f.tenantID, reporting.Filter{From: f.day, To: f.day, OutletID: f.outletA})
	require.NoError(t, err)
	assertTotals(t, kemangDay, kemang)

	bintaro, err := f.svc.Report(ctx, f.tenantID, reporting.Filter{From: f.day, To: f.day, OutletID: f.outletB})
	require.NoError(t, err)
	assertTotals(t, bintaroDay, bintaro)

	// A full refund hands back the tax too, so the money returned is larger
	// than the sale that was returned. Both numbers are shown; neither stands
	// in for the other.
	require.EqualValues(t, 16500, bintaro.RefundedAmount)
	require.EqualValues(t, 15000, bintaro.SalesReturns)

	chain, err := f.svc.Report(ctx, f.tenantID, reporting.Filter{From: f.day, To: f.day})
	require.NoError(t, err)
	assertTotals(t, wholeChainDay, chain)

	require.Equal(t, []reporting.Line{
		{Key: f.outletA, Label: "Kemang", Value: 77450, Net: 69500, Count: 2},
		{Key: f.outletB, Label: "Bintaro", Value: 38500, Net: 35000, Count: 1},
	}, chain.ByOutlet, "branches rank on sales, not on takings")

	// Tax and service charge raise what was collected and nothing else. The
	// pair below is the whole point of F1's correction: the old definition put
	// 11450 of somebody else's money into profit.
	require.EqualValues(t, chain.NetSales+chain.Tax+chain.ServiceCharge, chain.Revenue)
	require.EqualValues(t, chain.NetSales-chain.CostOfGoods, chain.GrossProfit)

	var categoryNet, productNet, cashierNet, hourNet, dayNet int64
	for _, c := range chain.ByCategory {
		categoryNet += c.Net
	}
	for _, p := range chain.ByProduct {
		productNet += p.NetSales
	}
	for _, c := range chain.ByCashier {
		cashierNet += c.Net
	}
	for _, h := range chain.ByHour {
		hourNet += h.NetSales
	}
	for _, d := range chain.Daily {
		dayNet += d.NetSales
	}
	require.EqualValues(t, chain.NetSales, categoryNet, "categories")
	require.EqualValues(t, chain.NetSales, productNet, "products")
	require.EqualValues(t, chain.NetSales, cashierNet, "cashiers")
	require.EqualValues(t, chain.NetSales, hourNet, "hours")
	require.EqualValues(t, chain.NetSales, dayNet, "days")

	// And the items inside a category add up to that category's own net: the
	// two splits come out of one allocation, so a remainder cannot land in one
	// and not the other.
	byKey := map[string]int64{}
	for _, c := range chain.ByCategory {
		byKey[c.Key] = c.Net
	}
	require.NotEmpty(t, chain.ByProductInCategory)
	for _, group := range chain.ByProductInCategory {
		var inside int64
		for _, p := range group.Products {
			inside += p.NetSales
		}
		require.EqualValues(t, byKey[group.CategoryKey], inside, "items inside %q", group.CategoryName)
	}

	require.Equal(t, []reporting.Line{
		{Key: f.cashierSiti, Label: "Siti", Value: 54450, Net: 49500, Count: 1},
		{Key: f.cashierRina, Label: "Rina", Value: 38500, Net: 35000, Count: 1},
		{Key: "name:Budi", Label: "Budi", Value: 23000, Net: 20000, Count: 1},
	}, chain.ByCashier)

	require.Equal(t, []reporting.Adjustment{
		{Kind: "discount", Label: "Happy Hour", Count: 1, Amount: 5500},
		{Kind: "cancelled", Label: "Manajer A", Count: 1, Amount: 30000},
		{Kind: "refunded", Label: "Owner", Count: 2, Amount: 28500},
	}, chain.Adjustments)
}

// Recomputing is destroy-and-rebuild, so running it again must land on exactly
// the same figures. Incremental arithmetic is what this design avoids, and
// this is the assertion that would catch someone reintroducing it.
func TestRecomputingTwiceDoesNotDoubleAnything(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	f.seedDay()
	f.seedBintaro()
	for range 3 {
		f.recompute(f.outletA)
		f.recompute(f.outletB)
	}

	chain, err := f.svc.Report(ctx, f.tenantID, reporting.Filter{From: f.day, To: f.day})
	require.NoError(t, err)
	assertTotals(t, wholeChainDay, chain)
	require.Equal(t, 2, f.count(`SELECT count(*) FROM daily_sales_rollup WHERE tenant_id = $1`, f.tenantID),
		"one row per outlet per day, however many times it ran")
	require.Equal(t, 5, f.count(`SELECT count(*) FROM daily_product_category_rollup WHERE tenant_id = $1`, f.tenantID),
		"coffee and rice and water at Kemang, coffee and water at Bintaro")
}

// A manager may run the floor and may not see what the merchant pays for
// stock. The figures are removed from the RESULT, so nothing downstream — a
// template, a JSON body, an export — can leak what it was never handed.
func TestCostDataIsRemovedFromTheReportNotHiddenByTheScreen(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	f.seedDay()
	f.seedBintaro()
	f.recompute(f.outletA)
	f.recompute(f.outletB)

	full, err := f.svc.Report(ctx, f.tenantID, reporting.Filter{From: f.day, To: f.day})
	require.NoError(t, err)
	require.EqualValues(t, 25000, full.CostOfGoods)

	limited := full.WithoutCostData()
	require.EqualValues(t, 0, limited.CostOfGoods)
	require.EqualValues(t, 0, limited.CostedItems)
	require.EqualValues(t, 0, limited.GrossProfit)
	require.Zero(t, limited.CostCoverage)
	for _, p := range limited.ByProduct {
		require.Zero(t, p.CostOfGoods, p.Name)
		require.Zero(t, p.CostedQuantity, p.Name)
	}
	for _, g := range limited.ByProductInCategory {
		for _, p := range g.Products {
			require.Zero(t, p.CostOfGoods, p.Name)
		}
	}

	// Sales survive: a manager still needs the day.
	require.EqualValues(t, wholeChainDay.net, limited.NetSales)
	require.EqualValues(t, wholeChainDay.revenue, limited.Revenue)

	// And the report the caller still holds is untouched — the slices are
	// cloned, not blanked in place.
	require.EqualValues(t, 25000, full.CostOfGoods)
	require.EqualValues(t, 25000, full.ByProduct[0].CostOfGoods)
}
