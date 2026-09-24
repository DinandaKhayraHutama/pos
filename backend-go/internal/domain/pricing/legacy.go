package pricing

// computeLegacy is the till's pre-F3 cart math (mobile CartState before F3),
// reproduced exactly so an outlet that has not switched to version 2 keeps
// printing the numbers its receipts always had:
//
//   - one bill-level discount (percent rounds down), clamped to the subtotal;
//   - service charge on subtotal − discount, rounded half up once;
//   - tax per line on lineTotal − ⌊discount·line/sub⌋ + ⌊service·line/sub⌋,
//     rounded half up per line — the floored shares are NOT reconciled, which
//     is why version 1 lines are not required to add up to the header;
//   - no included tax, no line discounts, no final rounding.
//
// The server never recomputes a version 1 order; this exists so one vector
// format covers both algorithms and both languages.
func computeLegacy(in Input) Result {
	n := len(in.Lines)
	res := Result{Lines: make([]LineResult, n)}
	for i, l := range in.Lines {
		g := mul(l.UnitPrice, l.Quantity)
		res.Lines[i].Gross = g
		res.Subtotal += g
	}
	sub := res.Subtotal
	res.Discount = discountOn(in.BillDiscount, sub)
	base := sub - res.Discount
	if base > 0 && in.ServiceRateBP > 0 {
		res.ServiceCharge = mulDivHalfUp(base, in.ServiceRateBP, MaxRateBP)
	}
	if sub > 0 {
		for i, l := range in.Lines {
			g := res.Lines[i].Gross
			var dShare, sShare int64
			if res.Discount != 0 {
				dShare = mulDiv(res.Discount, g, sub)
			}
			if res.ServiceCharge != 0 {
				sShare = mulDiv(res.ServiceCharge, g, sub)
			}
			res.Lines[i].BillDiscountShare = dShare
			res.Lines[i].ServiceShare = sShare
			res.Lines[i].NetAmount = g - dShare
			if l.TaxRateBP == 0 {
				continue
			}
			tx := mulDivHalfUp(g-dShare+sShare, l.TaxRateBP, MaxRateBP)
			res.Lines[i].TaxAmount = tx
			res.Tax += tx
		}
	}
	res.Total = base + res.ServiceCharge + res.Tax
	return res
}
