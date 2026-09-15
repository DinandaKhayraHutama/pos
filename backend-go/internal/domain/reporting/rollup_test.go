package reporting_test

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
)

func TestAReportFromRollupsMatchesTheOrdersItWasBuiltFrom(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	f.seedDay()
	f.recompute(f.outletA)

	r, err := f.svc.Report(ctx, f.tenantID, reporting.Filter{From: f.day, To: f.day})
	require.NoError(t, err)

	require.Equal(t, "Warung Laporan", r.BusinessName)
	require.Equal(t, "Asia/Jakarta", r.Timezone)
	require.EqualValues(t, 2, r.OrderCount, "cancelled and refunded orders are not revenue")
	require.EqualValues(t, 77450, r.Revenue)
	require.EqualValues(t, 75000, r.Subtotal)
	require.EqualValues(t, 5500, r.Discount)
	require.EqualValues(t, 6950, r.Tax)
	require.EqualValues(t, 1000, r.ServiceCharge)
	require.EqualValues(t, 38725, r.AverageOrder)
	require.EqualValues(t, 5, r.ItemsSold, "items are summed without fanning out the order totals")
	require.EqualValues(t, 15000, r.CostOfGoods)
	require.EqualValues(t, 3, r.CostedItems)
	require.InDelta(t, 0.6, r.CostCoverage, 1e-9)
	require.True(t, r.CostCoverageLow())
	require.EqualValues(t, 62450, r.GrossProfit)
	require.EqualValues(t, 1, r.DiscountedOrders)
	require.EqualValues(t, 1, r.CancelledCount)
	require.EqualValues(t, 30000, r.CancelledAmount)
	require.EqualValues(t, 1, r.RefundedCount)
	require.EqualValues(t, 12000, r.RefundedAmount, "the refunded amount, not the order total")
	require.NotNil(t, r.ComputedAt)
	require.EqualValues(t, 0, r.PendingSlices)

	require.Equal(t, []reporting.Line{{Key: f.outletA, Label: "Kemang", Value: 77450, Count: 2}}, r.ByOutlet)
	require.Len(t, r.Daily, 1)
	require.True(t, f.day.Equal(r.Daily[0].Date))
	require.EqualValues(t, 77450, r.Daily[0].Revenue)

	// Largest remainder: 5500 of the 55000 order split 3000/2500, and the
	// category net column adds up to subtotal minus discount.
	require.Len(t, r.ByCategory, 3)
	require.Equal(t, reporting.CategorySales{Key: f.drinks, Name: "Minuman Dingin", Gross: 45000, Net: 42000, Items: 3,
		ContributionPercent: r.ByCategory[0].ContributionPercent}, r.ByCategory[0], "the current name, not the snapshot")
	require.InDelta(t, 42000*100.0/69500, r.ByCategory[0].ContributionPercent, 1e-9)
	require.Equal(t, f.food, r.ByCategory[1].Key)
	require.EqualValues(t, 22500, r.ByCategory[1].Net)
	require.Equal(t, reporting.Uncategorised, r.ByCategory[2].Key)
	require.EqualValues(t, 5000, r.ByCategory[2].Net)
	var net int64
	for _, c := range r.ByCategory {
		net += c.Net
	}
	require.EqualValues(t, r.Subtotal-r.Discount, net)

	require.Equal(t, []reporting.ProductLine{
		{Key: f.coffee, Name: "Kopi Susu Gula Aren", Quantity: 3, Revenue: 45000, CostOfGoods: 15000, CostedQuantity: 3},
		{Key: f.rice, Name: "Nasi Goreng", Quantity: 1, Revenue: 25000},
		{Key: "name:Air Mineral", Name: "Air Mineral", Quantity: 1, Revenue: 5000},
	}, r.ByProduct, "a deleted product shows its newest snapshot name")

	require.Equal(t, []reporting.Line{
		{Key: f.cashierSiti, Label: "Siti", Value: 54450, Count: 1},
		{Key: "name:Budi", Label: "Budi", Value: 23000, Count: 1},
	}, r.ByCashier)
	require.Equal(t, []reporting.Line{
		{Key: "cash", Label: "Tunai", Value: 54450, Count: 1},
		{Key: "qris", Label: "QRIS", Value: 23000, Count: 1},
	}, r.ByPayment)
	require.Equal(t, []reporting.HourLine{{Hour: 9, Revenue: 54450, Orders: 1}, {Hour: 13, Revenue: 23000, Orders: 1}}, r.ByHour,
		"hours on the merchant's clock")
	require.Equal(t, []reporting.Adjustment{
		{Kind: "discount", Label: "Happy Hour", Count: 1, Amount: 5500},
		{Kind: "cancelled", Label: "Manajer A", Count: 1, Amount: 30000},
		{Kind: "refunded", Label: "Owner", Count: 1, Amount: 12000},
	}, r.Adjustments)

	// The report never reads orders: with every order gone, it says the same.
	_, err = f.db.Owner.Exec(ctx, `DELETE FROM orders WHERE tenant_id = $1`, f.tenantID)
	require.NoError(t, err)
	again, err := f.svc.Report(ctx, f.tenantID, reporting.Filter{From: f.day, To: f.day})
	require.NoError(t, err)
	require.Equal(t, r, again)
}

func TestHoursFollowTheMerchantsTimezone(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	f.seedDay()
	_, err := f.db.Owner.Exec(ctx, `UPDATE tenants SET timezone = 'UTC' WHERE id = $1`, f.tenantID)
	require.NoError(t, err)
	f.recompute(f.outletA)

	r, err := f.svc.Report(ctx, f.tenantID, reporting.Filter{From: f.day, To: f.day})
	require.NoError(t, err)
	require.Equal(t, []reporting.HourLine{{Hour: 2, Revenue: 54450, Orders: 1}, {Hour: 6, Revenue: 23000, Orders: 1}}, r.ByHour)
}

func TestASaleLandingDuringARecomputeKeepsTheSliceDirty(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	tea := func(placed time.Time) wire.Order {
		return f.order("paid", placed, nil, "Budi", "cash", 0, 0, 0, []saleLine{{name: "Es Teh", price: 5000, qty: 1}})
	}
	f.accepted(f.push("orders", tea(f.at(10, 0))))

	landed := false
	f.svc.SetAfterRollup(func() {
		if !landed {
			landed = true
			f.accepted(f.push("orders", tea(f.at(10, 5))))
		}
	})
	clean, err := f.svc.RecomputeSlice(ctx, f.tenantID, f.outletA, f.day)
	require.NoError(t, err)
	require.False(t, clean, "the marker moved while the slice computed")

	r, err := f.svc.Report(ctx, f.tenantID, reporting.Filter{From: f.day, To: f.day})
	require.NoError(t, err)
	require.EqualValues(t, 1, r.OrderCount, "the rollup is the snapshot it was computed on")
	require.EqualValues(t, 1, r.PendingSlices, "and the page says it is behind")

	f.svc.SetAfterRollup(nil)
	f.recompute(f.outletA)
	r, err = f.svc.Report(ctx, f.tenantID, reporting.Filter{From: f.day, To: f.day})
	require.NoError(t, err)
	require.EqualValues(t, 2, r.OrderCount)
	require.EqualValues(t, 0, r.PendingSlices)
	require.Zero(t, f.count(`SELECT count(*) FROM report_dirty_slices WHERE tenant_id = $1`, f.tenantID))
}

func TestARecomputeRequestMarksAndQueuesEverySliceInRange(t *testing.T) {
	f := setup(t)
	ctx := context.Background()

	n, err := f.svc.RequestRecompute(ctx, f.tenantID, reporting.Filter{From: f.day.AddDate(0, 0, -2), To: f.day})
	require.NoError(t, err)
	require.Equal(t, 6, n, "two outlets, three days")
	require.Equal(t, 6, f.count(`SELECT count(*) FROM report_dirty_slices WHERE tenant_id = $1`, f.tenantID))
	require.Equal(t, 6, f.count(`
		SELECT count(DISTINCT (args->>'outlet_id') || (args->>'business_date'))
		FROM jobs.river_job WHERE kind = 'report_slice' AND args->>'tenant_id' = $1`, f.tenantID))

	for _, outlet := range []string{f.outletA, f.outletB} {
		for d := 0; d < 3; d++ {
			clean, err := f.svc.RecomputeSlice(ctx, f.tenantID, outlet, f.day.AddDate(0, 0, -d))
			require.NoError(t, err)
			require.True(t, clean)
		}
	}
	require.Zero(t, f.count(`SELECT count(*) FROM report_dirty_slices WHERE tenant_id = $1`, f.tenantID))
	require.Zero(t, f.count(`SELECT count(*) FROM daily_sales_rollup WHERE tenant_id = $1`, f.tenantID),
		"a slice with no orders leaves no rows")

	n, err = f.svc.RequestRecompute(ctx, f.tenantID, reporting.Filter{From: f.day.AddDate(0, 0, -2), To: f.day, OutletID: f.outletB})
	require.NoError(t, err)
	require.Equal(t, 3, n)

	_, err = f.svc.RequestRecompute(ctx, f.otherTenantID, reporting.Filter{From: f.day, To: f.day, OutletID: f.outletA})
	require.ErrorIs(t, err, reporting.ErrNotFound)
	_, err = f.svc.RequestRecompute(ctx, f.tenantID, reporting.Filter{From: f.day.AddDate(0, 0, -100), To: f.day})
	_, invalid := validation.As(err)
	require.True(t, invalid, "a recompute is held to a quarter")

	n, err = f.svc.MarkRecent(ctx, f.tenantID, 3, time.Now())
	require.NoError(t, err)
	require.Equal(t, 6, n)
}

func TestTheConsistencyCheckFindsDriftAndRepairsNothing(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	f.seedDay()
	f.recompute(f.outletA)

	tables, pending, err := f.svc.VerifySlice(ctx, f.tenantID, f.outletA, f.day)
	require.NoError(t, err)
	require.False(t, pending)
	require.Empty(t, tables)

	_, err = f.db.Owner.Exec(ctx, `
		UPDATE daily_category_rollup SET net_sales = net_sales + 1
		WHERE tenant_id = $1 AND category_key = $2`, f.tenantID, f.drinks)
	require.NoError(t, err)

	tables, pending, err = f.svc.VerifySlice(ctx, f.tenantID, f.outletA, f.day)
	require.NoError(t, err)
	require.False(t, pending)
	require.Equal(t, []string{"daily_category_rollup"}, tables)
	require.Equal(t, 42001, f.count(`SELECT net_sales FROM daily_category_rollup WHERE tenant_id = $1 AND category_key = $2`,
		f.tenantID, f.drinks), "a check rolls back what it computed")

	f.recompute(f.outletA)
	tables, _, err = f.svc.VerifySlice(ctx, f.tenantID, f.outletA, f.day)
	require.NoError(t, err)
	require.Empty(t, tables)

	_, err = f.db.Owner.Exec(ctx, `INSERT INTO report_dirty_slices (tenant_id, outlet_id, business_date) VALUES ($1, $2, $3)`,
		f.tenantID, f.outletA, f.day)
	require.NoError(t, err)
	tables, pending, err = f.svc.VerifySlice(ctx, f.tenantID, f.outletA, f.day)
	require.NoError(t, err)
	require.True(t, pending, "a slice with changes pending is expected to be behind")
	require.Empty(t, tables)
}

func TestAnotherMerchantSeesNoneOfIt(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	f.seedDay()
	f.recompute(f.outletA)

	theirs, err := f.svc.Report(ctx, f.otherTenantID, reporting.Filter{From: f.day, To: f.day})
	require.NoError(t, err)
	require.Zero(t, theirs.OrderCount)
	require.Empty(t, theirs.ByOutlet)
	require.Empty(t, theirs.ByCategory)

	_, err = f.svc.Report(ctx, f.otherTenantID, reporting.Filter{From: f.day, To: f.day, OutletID: f.outletA})
	require.ErrorIs(t, err, reporting.ErrNotFound)

	// Recomputing someone else's slice from the wrong merchant sees no orders
	// and can delete no rollups.
	clean, err := f.svc.RecomputeSlice(ctx, f.otherTenantID, f.outletA, f.day)
	require.NoError(t, err)
	require.True(t, clean)
	mine, err := f.svc.Report(ctx, f.tenantID, reporting.Filter{From: f.day, To: f.day})
	require.NoError(t, err)
	require.EqualValues(t, 77450, mine.Revenue)
}
