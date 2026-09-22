package main

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// The morning-rush scenario's whole claim is a claim about the distribution
// the TILL produces. These vectors are shared with
// mobile/test/sync/sync_scheduler_test.dart: if either implementation drifts,
// one of the two suites fails and the load test stops describing the fleet.
func TestTheStartupSpreadMatchesTheFlutterTill(t *testing.T) {
	for _, tc := range []struct {
		deviceID string
		seconds  int
	}{
		{"device-7", 261},
		{"0f2b6c1e-0000-4000-8000-000000000001", 289},
		{"till-jakarta-01", 44},
		{"", 162},
	} {
		require.Equal(t, time.Duration(tc.seconds)*time.Second,
			startupSpread(tc.deviceID, 300*time.Second), "spread for %q", tc.deviceID)
	}
}

func TestTheSpreadIsStableAndInsideItsWindow(t *testing.T) {
	seen := map[time.Duration]int{}
	for i := range 3000 {
		id := newUUID()
		spread := startupSpread(id, 300*time.Second)
		require.GreaterOrEqual(t, spread, time.Duration(0))
		require.Less(t, spread, 300*time.Second)
		require.Equal(t, spread, startupSpread(id, 300*time.Second), "the same device must wait the same time")
		seen[spread]++
		_ = i
	}
	// Flat enough that no single second carries a fifth of the fleet: the
	// spread exists to remove a spike, not to move it.
	for spread, count := range seen {
		require.Less(t, count, 3000/5, "%s carries too much of the fleet", spread)
	}
}

// An overloaded server must show up as latency and drops, never as a load
// generator that quietly waits its turn. This is the property that separates
// an open model from a closed one, and it is the difference between a
// measurement and a comforting story.
func TestAnArrivalThatFindsEveryWorkerBusyIsDroppedNotDelayed(t *testing.T) {
	run := Driver{
		Count: 20, Schedule: ConstantRate(1000), Workers: 1,
		Call: func(ctx context.Context, _ int64) Outcome {
			time.Sleep(20 * time.Millisecond)
			return Outcome{Status: 200}
		},
	}.Run(context.Background())

	require.Positive(t, run.Dropped, "arrivals should have been dropped, not queued")
	require.Equal(t, int64(20), run.Started+run.Dropped)
	require.Equal(t, run.Started, run.Completed)
	require.Less(t, run.Percentile(99), 100*time.Millisecond,
		"a dropped arrival must not inflate the latency of the ones that ran")
}

func TestTheDriverHoldsItsRateAndReportsIt(t *testing.T) {
	run := Driver{
		Count: 100, Schedule: ConstantRate(200), Workers: 8,
		Call: func(ctx context.Context, _ int64) Outcome { return Outcome{Status: 200} },
	}.Run(context.Background())

	require.Equal(t, int64(100), run.Completed)
	require.Zero(t, run.Dropped)
	require.Zero(t, run.NonOK())
	require.InDelta(t, 0.5, run.Elapsed.Seconds(), 0.35, "100 arrivals at 200/s is about half a second")
}

func TestPercentilesReadTheSortedLatencies(t *testing.T) {
	run := Run{}
	for i := 1; i <= 100; i++ {
		run.Latencies = append(run.Latencies, time.Duration(i)*time.Millisecond)
	}
	require.Equal(t, 50*time.Millisecond, run.Percentile(50))
	require.Equal(t, 99*time.Millisecond, run.Percentile(99))
	require.Equal(t, 100*time.Millisecond, run.Percentile(100))
	require.Equal(t, time.Duration(0), Run{}.Percentile(99))
}

func TestTheBusiestSecondIsWhatTheSpreadGateReads(t *testing.T) {
	run := Run{PerSecond: []int64{10, 49, 3, 7}}
	require.Equal(t, int64(49), run.PeakPerSecond())
	require.Equal(t, int64(0), Run{}.PeakPerSecond())
}

// The data-scale gate accuses a report of reading raw tables. It must not
// accuse the rollups, whose names contain "orders" nowhere but whose queries
// mention report_dirty_slices and daily_sales_rollup.
func TestOnlyTheRawOrderTablesCountAsReadingRawOrders(t *testing.T) {
	require.True(t, mentionsRawOrders("SELECT count(*) FROM orders WHERE tenant_id = $1"))
	require.True(t, mentionsRawOrders("SELECT * FROM daily_sales_rollup r JOIN orders o ON o.id = r.id"))
	require.True(t, mentionsRawOrders("SELECT sum(quantity) FROM order_items WHERE business_date = $1"))

	require.False(t, mentionsRawOrders("SELECT sum(revenue) FROM daily_sales_rollup WHERE tenant_id = $1"))
	require.False(t, mentionsRawOrders("SELECT count(*), min(changed_at) FROM report_dirty_slices"))
	require.False(t, mentionsRawOrders("SELECT * FROM daily_product_rollup ORDER BY net DESC"))
}

// unit_price already includes the modifier delta. Adding it again is the one
// arithmetic mistake this system's rules exist to prevent, and a harness that
// made it would push receipts whose totals disagree with their own lines.
func TestASimulatedReceiptNeverCountsAModifierTwice(t *testing.T) {
	till := newTill("http://example.invalid", nil, "0f2b6c1e-0000-4000-8000-000000000001", "outlet", "token")
	order := till.receipt([]product{{id: newUUID(), name: "Kopi", price: 18000}, {id: newUUID(), name: "Teh", price: 12000}})

	var lines int64
	for _, item := range order.Items {
		lines += item.UnitPrice * int64(item.Quantity)
	}
	require.Equal(t, lines, order.Subtotal, "subtotal is the sum of unit_price x quantity and nothing else")
	require.Equal(t, order.Subtotal, order.Total)
	require.Equal(t, order.Total, order.AmountPaid)
	require.NotEmpty(t, order.Number, "a receipt carries its own number")
}

func TestGatesDecideTheExitCode(t *testing.T) {
	result := newResult("unit", map[string]any{})
	require.False(t, result.failed(), "a result with no gates has nothing to fail")

	result.gate("first", true, "fine")
	require.False(t, result.failed())

	result.gate("second", false, "not fine")
	require.True(t, result.failed())
}

func TestWithinPercentIsInclusiveOfItsSlack(t *testing.T) {
	require.True(t, withinPercent(2000, 2000, 2))
	require.True(t, withinPercent(2040, 2000, 2))
	require.False(t, withinPercent(2041, 2000, 2))
	require.True(t, withinPercent(0, 0, 2))
	require.False(t, withinPercent(1, 0, 2))
	// Small fleets still get a whole request of slack rather than none.
	require.True(t, withinPercent(3, 4, 2))
}
