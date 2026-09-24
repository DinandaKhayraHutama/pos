// Package pricing is the one definition of how a bill's money is computed.
//
// The Flutter till carries a line-for-line port of this package
// (mobile/lib/core/pricing/), and both are held to the shared vectors under
// testdata/pricing at the repository root. The server never prices a sale on
// the till's behalf: ingest recomputes a received order from the snapshot the
// order itself carries and FLAGS a disagreement, because a sale that already
// happened offline is a fact and must never be refused over arithmetic.
//
// Every amount is integer rupiah and every rate is basis points (1000 = 10%).
// There is no floating point anywhere in this package — the till's first
// implementation rounded `double` products, which is exactly the class of
// result two languages cannot promise to agree on.
//
// Two algorithms live here:
//
//   - Version 1 (legacy.go) is a faithful port of the till's original cart
//     math, kept so a merchant who has not switched an outlet to the new
//     pricing model keeps the numbers printed on every receipt so far.
//   - Version 2 (this file) is the F3 engine: price → item discount → bill
//     discount allocation → included-tax extraction → service → tax → final
//     rounding, with a per-line breakdown that always adds up to the header.
package pricing

import (
	"errors"
	"math/big"
)

// Versions an order may declare.
const (
	VersionLegacy = 1
	VersionV2     = 2
)

// Tax modes.
const (
	TaxExclusive = "exclusive"
	TaxInclusive = "inclusive"
)

// Rounding modes.
const (
	RoundNearest = "nearest"
	RoundUp      = "up"
	RoundDown    = "down"
)

// Discount kinds.
const (
	DiscountPercent = "percent" // value in basis points, 0..10000
	DiscountAmount  = "amount"  // value in rupiah
)

// MaxRateBP bounds every rate: 100%.
const MaxRateBP = 10000

// Discount is a discount specification, not its result.
type Discount struct {
	Kind  string `json:"kind"`
	Value int64  `json:"value"`
}

// Line is one priced line of a bill. UnitPrice already includes the variant
// and modifier deltas, exactly as the till's CartLine.unitPrice always has.
type Line struct {
	UnitPrice int64     `json:"unit_price"`
	Quantity  int64     `json:"quantity"`
	TaxRateBP int64     `json:"tax_rate_bp"`
	Discount  *Discount `json:"discount,omitempty"`
}

// Input is everything needed to price one bill.
type Input struct {
	Version        int       `json:"version"`
	TaxMode        string    `json:"tax_mode"`
	ServiceRateBP  int64     `json:"service_rate_bp"`
	ServiceTaxable bool      `json:"service_taxable"`
	RoundingUnit   int64     `json:"rounding_unit"`
	RoundingMode   string    `json:"rounding_mode"`
	BillDiscount   *Discount `json:"bill_discount,omitempty"`
	Lines          []Line    `json:"lines"`
}

// LineResult is one line's share of every header amount.
type LineResult struct {
	Gross             int64 `json:"gross"`
	LineDiscount      int64 `json:"line_discount"`
	BillDiscountShare int64 `json:"bill_discount_share"`
	ServiceShare      int64 `json:"service_share"`
	TaxAmount         int64 `json:"tax_amount"`
	TaxIncluded       int64 `json:"tax_included"`
	NetAmount         int64 `json:"net_amount"`
}

// Result is the priced bill. For version 2 the lines always reconcile:
// Σ(line_discount + bill_discount_share) = discount, Σ service_share =
// service_charge, Σ tax_amount = tax, Σ tax_included = tax_included, and
// total = subtotal − discount + service_charge + tax − tax_included + rounding.
type Result struct {
	Subtotal      int64        `json:"subtotal"`
	Discount      int64        `json:"discount"`
	ServiceCharge int64        `json:"service_charge"`
	Tax           int64        `json:"tax"`
	TaxIncluded   int64        `json:"tax_included"`
	Rounding      int64        `json:"rounding"`
	Total         int64        `json:"total"`
	Lines         []LineResult `json:"lines"`
}

// ErrInvalid is returned for an input no till could have produced.
var ErrInvalid = errors.New("pricing: invalid input")

// Compute prices a bill with the algorithm its Version names.
func Compute(in Input) (Result, error) {
	if err := validate(in); err != nil {
		return Result{}, err
	}
	switch in.Version {
	case VersionLegacy:
		return computeLegacy(in), nil
	case VersionV2:
		return computeV2(in), nil
	}
	return Result{}, ErrInvalid
}

func validate(in Input) error {
	if in.ServiceRateBP < 0 || in.ServiceRateBP > MaxRateBP || in.RoundingUnit < 0 {
		return ErrInvalid
	}
	switch in.TaxMode {
	case "", TaxExclusive, TaxInclusive:
	default:
		return ErrInvalid
	}
	switch in.RoundingMode {
	case "", RoundNearest, RoundUp, RoundDown:
	default:
		return ErrInvalid
	}
	if !validDiscount(in.BillDiscount) {
		return ErrInvalid
	}
	for _, l := range in.Lines {
		if l.UnitPrice < 0 || l.Quantity < 0 || l.TaxRateBP < 0 || l.TaxRateBP > MaxRateBP || !validDiscount(l.Discount) {
			return ErrInvalid
		}
	}
	return nil
}

func validDiscount(d *Discount) bool {
	if d == nil {
		return true
	}
	switch d.Kind {
	case DiscountPercent:
		return d.Value >= 0 && d.Value <= MaxRateBP
	case DiscountAmount:
		return d.Value >= 0
	}
	return false
}

func computeV2(in Input) Result {
	n := len(in.Lines)
	res := Result{Lines: make([]LineResult, n)}

	// 1–2. Gross, then each line's own discount.
	after := make([]int64, n)
	var sumAfter, lineDiscounts int64
	for i, l := range in.Lines {
		g := mul(l.UnitPrice, l.Quantity)
		d := discountOn(l.Discount, g)
		res.Lines[i].Gross = g
		res.Lines[i].LineDiscount = d
		after[i] = g - d
		res.Subtotal += g
		sumAfter += after[i]
		lineDiscounts += d
	}

	// 3. The bill discount is taken off what the lines still owe, and shared
	// back over them in proportion to it.
	billDiscount := discountOn(in.BillDiscount, sumAfter)
	shares := Allocate(billDiscount, after)
	res.Discount = lineDiscounts + billDiscount

	// 4. Included tax is extracted from each line's discounted amount.
	exTax := make([]int64, n)
	var sumExTax int64
	for i, l := range in.Lines {
		net := after[i] - shares[i]
		res.Lines[i].BillDiscountShare = shares[i]
		e := net
		if in.TaxMode == TaxInclusive && l.TaxRateBP > 0 {
			e = divHalfUp(mul(net, MaxRateBP), MaxRateBP+l.TaxRateBP)
		}
		exTax[i] = e
		res.Lines[i].TaxIncluded = net - e
		res.Lines[i].NetAmount = e
		sumExTax += e
	}

	// 5. Service charge on the pre-tax amount, shared over the lines.
	res.ServiceCharge = mulDivHalfUp(sumExTax, in.ServiceRateBP, MaxRateBP)
	serviceShares := Allocate(res.ServiceCharge, exTax)

	// 6. Tax. Exclusive: on the line plus (when taxable) its service share.
	// Inclusive: what was extracted, plus tax on the service share, which the
	// menu price never contained.
	for i, l := range in.Lines {
		res.Lines[i].ServiceShare = serviceShares[i]
		taxedService := int64(0)
		if in.ServiceTaxable {
			taxedService = serviceShares[i]
		}
		var tx int64
		if in.TaxMode == TaxInclusive {
			tx = res.Lines[i].TaxIncluded + mulDivHalfUp(taxedService, l.TaxRateBP, MaxRateBP)
		} else {
			tx = mulDivHalfUp(exTax[i]+taxedService, l.TaxRateBP, MaxRateBP)
		}
		res.Lines[i].TaxAmount = tx
		res.Tax += tx
		res.TaxIncluded += res.Lines[i].TaxIncluded
	}

	// 7. Final rounding of what the customer pays.
	pre := res.Subtotal - res.Discount + res.ServiceCharge + res.Tax - res.TaxIncluded
	res.Total = roundTo(pre, in.RoundingUnit, in.RoundingMode)
	res.Rounding = res.Total - pre
	return res
}

// discountOn is what a discount takes off base: percent rounds down, an amount
// is capped at the base, and nothing ever goes below zero.
func discountOn(d *Discount, base int64) int64 {
	if d == nil || base <= 0 {
		return 0
	}
	var v int64
	switch d.Kind {
	case DiscountPercent:
		v = mulDiv(base, d.Value, MaxRateBP)
	case DiscountAmount:
		v = d.Value
	}
	return min(max(v, 0), base)
}

// roundTo rounds a non-negative amount to a multiple of unit. A unit of 0 or 1
// means no rounding.
func roundTo(v, unit int64, mode string) int64 {
	if unit <= 1 || v <= 0 {
		return v
	}
	q, r := v/unit, v%unit
	switch mode {
	case RoundUp:
		if r > 0 {
			q++
		}
	case RoundDown:
	default: // nearest, half up
		if 2*r >= unit {
			q++
		}
	}
	return q * unit
}

// Allocate splits total over weights by the largest-remainder (Hamilton)
// method: every row gets ⌊total·w/W⌋, and the rupiah still unassigned go one
// each to the rows with the largest remainders, ties to the lowest index.
//
// Deliberately NOT the reporting package's "whole remainder to the largest
// row": with weights [1,1,1] and a total of 2 that method hands one row 2
// against a weight of 1, a negative net line. Hamilton never gives a row more
// than ⌈total·w/W⌉, which is ≤ w whenever total ≤ W.
func Allocate(total int64, weights []int64) []int64 {
	out := make([]int64, len(weights))
	var sum int64
	for _, w := range weights {
		sum += w
	}
	if total == 0 || sum <= 0 {
		return out
	}
	rems := make([]*big.Int, len(weights))
	var given int64
	bt, bs := big.NewInt(total), big.NewInt(sum)
	for i, w := range weights {
		p := new(big.Int).Mul(bt, big.NewInt(w))
		q, r := new(big.Int).QuoRem(p, bs, new(big.Int))
		out[i] = q.Int64()
		rems[i] = r
		given += out[i]
	}
	left := total - given
	order := make([]int, len(weights))
	for i := range order {
		order[i] = i
	}
	// Insertion sort: bills are short, and a stable, dependency-free order is
	// what the Dart port has to reproduce exactly.
	for i := 1; i < len(order); i++ {
		for j := i; j > 0 && rems[order[j]].Cmp(rems[order[j-1]]) > 0; j-- {
			order[j], order[j-1] = order[j-1], order[j]
		}
	}
	for k := 0; k < len(order) && left > 0; k++ {
		out[order[k]]++
		left--
	}
	return out
}

func mul(a, b int64) int64 {
	return new(big.Int).Mul(big.NewInt(a), big.NewInt(b)).Int64()
}

// mulDiv is ⌊a·b/c⌋ for non-negative operands, exact at any size.
func mulDiv(a, b, c int64) int64 {
	p := new(big.Int).Mul(big.NewInt(a), big.NewInt(b))
	return p.Quo(p, big.NewInt(c)).Int64()
}

// mulDivHalfUp is a·b/c rounded half up, for non-negative operands.
func mulDivHalfUp(a, b, c int64) int64 {
	p := new(big.Int).Mul(big.NewInt(a), big.NewInt(b))
	return halfUp(p, big.NewInt(c))
}

func divHalfUp(a, c int64) int64 {
	return halfUp(big.NewInt(a), big.NewInt(c))
}

// halfUp is n/d rounded half up: ⌊(2n + d) / 2d⌋.
func halfUp(n, d *big.Int) int64 {
	num := new(big.Int).Add(new(big.Int).Lsh(n, 1), d)
	return num.Quo(num, new(big.Int).Lsh(d, 1)).Int64()
}
