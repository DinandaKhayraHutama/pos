package reporting_test

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
)

// The discount split, as pure logic over raw rows.
//
// Ported from backend/tests/Unit/CategorySalesAggregatorTest.php before the
// code, as the plan asks. Kept without a database on purpose: the Dart original
// shipped two bugs only tests at this level caught — net computed as the
// discount SHARE rather than gross minus it, and a name guard that let an older
// snapshot name replace a newer one.

func line(edit ...func(*reporting.CategoryLine)) reporting.CategoryLine {
	l := reporting.CategoryLine{
		OrderID:       "o1",
		OrderDiscount: 0,
		OrderSubtotal: 10000,
		PlacedAtMs:    1000,
		CategoryID:    "cat_food",
		SnapshotName:  "Makanan",
		LiveName:      "Makanan",
		LineTotal:     10000,
		Quantity:      1,
	}
	for _, e := range edit {
		e(&l)
	}
	return l
}

func byKey(out []reporting.CategorySales) map[string]reporting.CategorySales {
	m := make(map[string]reporting.CategorySales, len(out))
	for _, c := range out {
		m[c.Key] = c
	}
	return m
}

func sums(out []reporting.CategorySales) (gross, net int64) {
	for _, c := range out {
		gross += c.Gross
		net += c.Net
	}
	return gross, net
}

// ------------------------------------------------------------------- money

func TestASingleOrderCarriesStraightThrough(t *testing.T) {
	out := reporting.AggregateCategories([]reporting.CategoryLine{line()})

	require.Len(t, out, 1)
	require.EqualValues(t, 10000, out[0].Gross)
	require.EqualValues(t, 10000, out[0].Net)
	require.EqualValues(t, 1, out[0].Items)
	require.Equal(t, 100.0, out[0].ContributionPercent)
}

func TestGrossEqualsNetWhenNothingWasDiscounted(t *testing.T) {
	out := reporting.AggregateCategories([]reporting.CategoryLine{line(func(l *reporting.CategoryLine) {
		l.LineTotal, l.OrderSubtotal = 25000, 25000
	})})

	require.Equal(t, out[0].Gross, out[0].Net)
}

func TestADiscountSplitsInProportionToEachCategory(t *testing.T) {
	// Net is gross MINUS the share. The Dart original stored the share itself.
	out := byKey(reporting.AggregateCategories([]reporting.CategoryLine{
		line(func(l *reporting.CategoryLine) {
			l.CategoryID, l.LineTotal, l.OrderSubtotal, l.OrderDiscount = "food", 10000, 30000, 3000
		}),
		line(func(l *reporting.CategoryLine) {
			l.CategoryID, l.LineTotal, l.OrderSubtotal, l.OrderDiscount = "drinks", 20000, 30000, 3000
		}),
	}))

	require.EqualValues(t, 9000, out["food"].Net)
	require.EqualValues(t, 18000, out["drinks"].Net)
}

func TestEveryRupiahOfAnUnevenDiscountIsAccountedFor(t *testing.T) {
	// Three categories at 10000 on a 30000 subtotal, discount 100. Each floors
	// to 33, summing to 99: the missing rupiah is why largest-remainder exists.
	lines := make([]reporting.CategoryLine, 0, 3)
	for _, id := range []string{"b", "a", "c"} {
		lines = append(lines, line(func(l *reporting.CategoryLine) {
			l.CategoryID, l.LineTotal, l.OrderSubtotal, l.OrderDiscount = id, 10000, 30000, 100
		}))
	}
	out := reporting.AggregateCategories(lines)

	gross, net := sums(out)
	require.EqualValues(t, 30000, gross)
	require.EqualValues(t, 30000-100, net)
	// A tie on the line total breaks on the category id, so two runs over the
	// same data agree: "a" takes the rupiah whatever order the rows came in.
	m := byKey(out)
	require.EqualValues(t, 10000-34, m["a"].Net)
	require.EqualValues(t, 10000-33, m["b"].Net)
	require.EqualValues(t, 10000-33, m["c"].Net)
}

func TestTheRemainderGoesToTheLargestLine(t *testing.T) {
	out := byKey(reporting.AggregateCategories([]reporting.CategoryLine{
		line(func(l *reporting.CategoryLine) {
			l.CategoryID, l.LineTotal, l.OrderSubtotal, l.OrderDiscount = "a", 10000, 30001, 100
		}),
		line(func(l *reporting.CategoryLine) {
			l.CategoryID, l.LineTotal, l.OrderSubtotal, l.OrderDiscount = "z", 20001, 30001, 100
		}),
	}))

	// floor(100×10000/30001) = 33, floor(100×20001/30001) = 66; the leftover
	// rupiah goes to the larger line even though its id sorts last.
	require.EqualValues(t, 10000-33, out["a"].Net)
	require.EqualValues(t, 20001-67, out["z"].Net)
}

func TestEachOrderReconcilesIndependently(t *testing.T) {
	out := reporting.AggregateCategories([]reporting.CategoryLine{
		line(func(l *reporting.CategoryLine) {
			l.OrderID, l.CategoryID, l.LineTotal, l.OrderSubtotal, l.OrderDiscount = "o1", "food", 10000, 10000, 1000
		}),
		line(func(l *reporting.CategoryLine) {
			l.OrderID, l.CategoryID, l.LineTotal, l.OrderSubtotal, l.OrderDiscount = "o2", "food", 20000, 20000, 2000
		}),
	})

	require.EqualValues(t, 30000, out[0].Gross)
	require.EqualValues(t, 27000, out[0].Net)
}

func TestAnOrderWithNoSubtotalNeverDividesByZero(t *testing.T) {
	out := reporting.AggregateCategories([]reporting.CategoryLine{line(func(l *reporting.CategoryLine) {
		l.LineTotal, l.OrderSubtotal, l.OrderDiscount = 0, 0, 0
	})})

	require.Len(t, out, 1)
	require.EqualValues(t, 0, out[0].Net)
}

func TestZeroNetReportsZeroContribution(t *testing.T) {
	out := reporting.AggregateCategories([]reporting.CategoryLine{line(func(l *reporting.CategoryLine) {
		l.LineTotal, l.OrderSubtotal = 0, 0
	})})

	require.Equal(t, 0.0, out[0].ContributionPercent)
}

func TestCategoriesSortByNetSalesLargestFirst(t *testing.T) {
	out := reporting.AggregateCategories([]reporting.CategoryLine{
		line(func(l *reporting.CategoryLine) { l.CategoryID, l.LineTotal, l.OrderSubtotal = "small", 5000, 25000 }),
		line(func(l *reporting.CategoryLine) { l.CategoryID, l.LineTotal, l.OrderSubtotal = "big", 20000, 25000 }),
	})

	require.Equal(t, "big", out[0].Key)
	require.Equal(t, "small", out[1].Key)
}

func TestLargeAmountsDoNotOverflow(t *testing.T) {
	out := byKey(reporting.AggregateCategories([]reporting.CategoryLine{
		line(func(l *reporting.CategoryLine) {
			l.CategoryID, l.LineTotal, l.OrderSubtotal, l.OrderDiscount = "a", 1_000_000_000_000, 2_000_000_000_000, 900_000_000_000
		}),
		line(func(l *reporting.CategoryLine) {
			l.CategoryID, l.LineTotal, l.OrderSubtotal, l.OrderDiscount = "b", 1_000_000_000_000, 2_000_000_000_000, 900_000_000_000
		}),
	}))

	require.EqualValues(t, 550_000_000_000, out["a"].Net)
	require.EqualValues(t, 550_000_000_000, out["b"].Net)
}

// --------------------------------------------------- grouping and naming

func TestARenameMidRangeStaysOneRow(t *testing.T) {
	out := reporting.AggregateCategories([]reporting.CategoryLine{
		line(func(l *reporting.CategoryLine) {
			l.OrderID, l.SnapshotName, l.LiveName = "o1", "Makanan", "Makanan Utama"
		}),
		line(func(l *reporting.CategoryLine) {
			l.OrderID, l.SnapshotName, l.LiveName = "o2", "Makanan Utama", "Makanan Utama"
		}),
	})

	require.Len(t, out, 1)
	require.Equal(t, "Makanan Utama", out[0].Name)
}

func TestTwoCategoriesSharingANameStayApart(t *testing.T) {
	out := reporting.AggregateCategories([]reporting.CategoryLine{
		line(func(l *reporting.CategoryLine) { l.CategoryID, l.SnapshotName, l.LiveName = "a", "Es Teh", "Es Teh" }),
		line(func(l *reporting.CategoryLine) { l.CategoryID, l.SnapshotName, l.LiveName = "b", "Es Teh", "Es Teh" }),
	})

	require.Len(t, out, 2)
}

func TestADeletedCategoryShowsItsNewestSnapshotName(t *testing.T) {
	// Rows arrive oldest first, so keeping the first name seen shows the stale
	// one. That was the second bug in the Dart version.
	out := reporting.AggregateCategories([]reporting.CategoryLine{
		line(func(l *reporting.CategoryLine) {
			l.OrderID, l.PlacedAtMs, l.SnapshotName, l.LiveName = "o1", 1000, "Lama", ""
		}),
		line(func(l *reporting.CategoryLine) {
			l.OrderID, l.PlacedAtMs, l.SnapshotName, l.LiveName = "o2", 2000, "Baru", ""
		}),
	})

	require.Equal(t, "Baru", out[0].Name)
	require.EqualValues(t, 2000, out[0].NameAtMs)
}

func TestALiveNameWinsOverAnySnapshot(t *testing.T) {
	out := reporting.AggregateCategories([]reporting.CategoryLine{
		line(func(l *reporting.CategoryLine) {
			l.OrderID, l.PlacedAtMs, l.SnapshotName, l.LiveName = "o1", 2000, "Snapshot", ""
		}),
		line(func(l *reporting.CategoryLine) {
			l.OrderID, l.PlacedAtMs, l.SnapshotName, l.LiveName = "o2", 1000, "Older", "Live"
		}),
	})

	require.Equal(t, "Live", out[0].Name)
}

func TestALineWithNoCategoryIsBucketed(t *testing.T) {
	out := reporting.AggregateCategories([]reporting.CategoryLine{line(func(l *reporting.CategoryLine) {
		l.CategoryID, l.SnapshotName, l.LiveName = "", "", ""
	})})

	// Left with an empty name for the page to label, as the till does.
	require.Equal(t, reporting.Uncategorised, out[0].Key)
	require.Equal(t, "", out[0].Name)
}

func TestTheUncategorisedBucketStaysSeparate(t *testing.T) {
	out := reporting.AggregateCategories([]reporting.CategoryLine{
		line(func(l *reporting.CategoryLine) { l.CategoryID, l.LineTotal, l.OrderSubtotal = "food", 10000, 20000 }),
		line(func(l *reporting.CategoryLine) {
			l.CategoryID, l.SnapshotName, l.LiveName, l.LineTotal, l.OrderSubtotal = "", "", "", 10000, 20000
		}),
	})

	require.Len(t, out, 2)
}

func TestNoRowsReturnNothing(t *testing.T) {
	require.Empty(t, reporting.AggregateCategories(nil))
}
