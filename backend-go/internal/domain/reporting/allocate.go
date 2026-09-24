package reporting

import (
	"math"
	"math/big"
	"sort"
)

// Uncategorised is the key of lines that carried no category at all.
const Uncategorised = "__uncategorised__"

// CategoryLine is one (order, category) row: the order's discount and
// subtotal, and the lines of that category in the order summed.
type CategoryLine struct {
	OrderID       string
	OrderDiscount int64
	OrderSubtotal int64
	PlacedAtMs    int64
	// Empty when the line had no category.
	CategoryID   string
	SnapshotName string
	// The category's current name, or empty when it no longer exists.
	LiveName  string
	LineTotal int64
	NetTotal  int64
	NetKnown  bool
	Quantity  int64
}

// CategorySales is one category's contribution to a report.
//
// Gross is the sum of line totals before any order-level discount; Net is gross
// minus the discount allocated to the category. Both are pre-tax and
// pre-service-charge, deliberately, so Σ Net reconciles to Σ(subtotal −
// discount), not to revenue.
type CategorySales struct {
	Key  string
	Name string
	// When the snapshot Name was recorded; zero for a live name. A rollup keeps
	// it so a report over several days picks the newest name.
	NameAtMs            int64
	Gross               int64
	Net                 int64
	Items               int64
	ContributionPercent float64
}

// AggregateCategories splits each order's discount across the categories it
// touched, by largest remainder.
//
// A port of the Laravel CategorySalesAggregator (that tree is gone), itself a
// port of the till's aggregateCategorySales. Allocating
// discount × line / subtotal per category and flooring leaves up to
// (categories − 1) rupiah unaccounted for on every order, and over a month the
// category breakdown stops reconciling. So the floors are summed, the leftover
// is handed whole to the category with the largest line total in that order,
// and ties break on the category key so the result is deterministic.
func AggregateCategories(lines []CategoryLine) []CategorySales {
	var orderIDs []string
	byOrder := map[string][]CategoryLine{}
	for _, l := range lines {
		if _, seen := byOrder[l.OrderID]; !seen {
			orderIDs = append(orderIDs, l.OrderID)
		}
		byOrder[l.OrderID] = append(byOrder[l.OrderID], l)
	}

	var keys []string
	gross, net, items := map[string]int64{}, map[string]int64{}, map[string]int64{}
	for _, id := range orderIDs {
		rows := byOrder[id]
		shares := allocate(rows, rows[0].OrderDiscount, rows[0].OrderSubtotal)
		for i, r := range rows {
			k := keyOf(r)
			if _, seen := gross[k]; !seen {
				keys = append(keys, k)
			}
			gross[k] += r.LineTotal
			// Gross MINUS the share, not the share itself: the inversion was one
			// of the two bugs the Dart version shipped.
			if r.NetKnown {
				net[k] += r.NetTotal
			} else {
				net[k] += r.LineTotal - shares[i]
			}
			items[k] += r.Quantity
		}
	}

	names, namedAt := resolveNames(orderIDs, byOrder)
	var totalNet int64
	for _, k := range keys {
		totalNet += net[k]
	}

	out := make([]CategorySales, 0, len(keys))
	for _, k := range keys {
		c := CategorySales{Key: k, Name: names[k], NameAtMs: namedAt[k], Gross: gross[k], Net: net[k], Items: items[k]}
		out = append(out, c)
	}
	WithContribution(out, totalNet)
	SortCategories(out)
	return out
}

// WithContribution fills each category's share of totalNet.
func WithContribution(cs []CategorySales, totalNet int64) {
	for i := range cs {
		cs[i].ContributionPercent = 0
		if totalNet != 0 {
			cs[i].ContributionPercent = float64(cs[i].Net) * 100 / float64(totalNet)
		}
	}
}

// SortCategories orders by net sales, largest first. Ties break on the key so a
// page and its export list the same order.
func SortCategories(cs []CategorySales) {
	sort.SliceStable(cs, func(i, j int) bool {
		if cs[i].Net != cs[j].Net {
			return cs[i].Net > cs[j].Net
		}
		return cs[i].Key < cs[j].Key
	})
}

// allocate returns the discount each row of one order carries.
func allocate(rows []CategoryLine, discount, subtotal int64) []int64 {
	shares := make([]int64, len(rows))
	var allocated int64
	for i, r := range rows {
		// subtotal == 0 implies discount == 0, because the till clamps a
		// discount to what there is to discount. Guarded anyway: dividing by
		// zero here would take down a whole report.
		if subtotal != 0 {
			shares[i] = mulDiv(discount, r.LineTotal, subtotal)
		}
		allocated += shares[i]
	}

	remainder := discount - allocated
	if remainder == 0 || len(rows) == 0 {
		return shares
	}

	// The whole remainder goes to one row: the largest line total, ties broken
	// by category key.
	winner := 0
	for i, r := range rows {
		best := rows[winner]
		if r.LineTotal > best.LineTotal || (r.LineTotal == best.LineTotal && keyOf(r) < keyOf(best)) {
			winner = i
		}
	}
	shares[winner] += remainder
	return shares
}

// mulDiv is a × b / c truncated toward zero, exact even when a × b does not fit
// in 64 bits. Money is bounded at a trillion rupiah per field, and a discount
// times a line total can exceed int64 long before that.
func mulDiv(a, b, c int64) int64 {
	if a == 0 || b == 0 {
		return 0
	}
	if absGreater(a, math.MaxInt64/abs(b)) {
		p := new(big.Int).Mul(big.NewInt(a), big.NewInt(b))
		return p.Quo(p, big.NewInt(c)).Int64()
	}
	return a * b / c
}

func abs(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}

func absGreater(a, limit int64) bool { return abs(a) > limit }

// resolveNames picks what to call each category. A live name always wins and
// closes the key off; otherwise the NEWEST snapshot name is used, and an older
// one never overwrites a newer one — the second bug the Dart version shipped.
func resolveNames(orderIDs []string, byOrder map[string][]CategoryLine) (map[string]string, map[string]int64) {
	names := map[string]string{}
	live := map[string]bool{}
	newest := map[string]int64{}
	seen := map[string]bool{}

	for _, id := range orderIDs {
		for _, r := range byOrder[id] {
			k := keyOf(r)
			if r.LiveName != "" {
				names[k], live[k] = r.LiveName, true
				continue
			}
			if live[k] || r.SnapshotName == "" {
				continue
			}
			if !seen[k] || r.PlacedAtMs >= newest[k] {
				names[k], newest[k], seen[k] = r.SnapshotName, r.PlacedAtMs, true
			}
		}
	}
	return names, newest
}

// keyOf groups by category id, never by name: a category renamed mid-range
// stays one bucket, and two categories that share a name stay two.
func keyOf(r CategoryLine) string {
	if r.CategoryID == "" {
		return Uncategorised
	}
	return r.CategoryID
}
