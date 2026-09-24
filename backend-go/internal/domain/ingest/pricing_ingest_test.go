package ingest

import (
	"context"
	"testing"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/pricing"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/stretchr/testify/require"
)

// v2Order prices two lines with the shared engine — inclusive tax, a service
// charge, an item discount, a bill discount and rounding to 100 — and writes
// the figures the till would send.
func (f *fixture) v2Order(t *testing.T, session string) wire.Order {
	t.Helper()
	in := pricing.Input{
		Version: pricing.VersionV2, TaxMode: pricing.TaxInclusive, ServiceRateBP: 500, ServiceTaxable: true,
		RoundingUnit: 100, RoundingMode: pricing.RoundNearest,
		BillDiscount: &pricing.Discount{Kind: pricing.DiscountAmount, Value: 1000},
		Lines: []pricing.Line{
			{UnitPrice: 27500, Quantity: 2, TaxRateBP: 1000, Discount: &pricing.Discount{Kind: pricing.DiscountPercent, Value: 1000}},
			{UnitPrice: 12345, Quantity: 1, TaxRateBP: 0},
		},
	}
	res, err := pricing.Compute(in)
	require.NoError(t, err)
	o := f.order(t, session)
	o.PricingVersion = ptr(2)
	o.Pricing = &wire.PricingSnapshot{
		TaxMode: "inclusive", ServiceRateBp: 500, ServiceTaxable: true, RoundingUnit: 100, RoundingMode: "nearest",
		BillDiscount: &wire.DiscountSpec{Kind: "amount", Value: 1000},
	}
	o.Subtotal, o.Discount, o.ServiceChargeAmount, o.Tax = res.Subtotal, res.Discount, res.ServiceCharge, res.Tax
	o.TaxIncluded, o.RoundingAmount, o.Total, o.AmountPaid = ptr(res.TaxIncluded), ptr(res.Rounding), res.Total, res.Total
	o.Items = nil
	for i, l := range res.Lines {
		item := wire.OrderItem{
			Id: f.id(t), ProductName: "Line", Quantity: int(in.Lines[i].Quantity), UnitPrice: in.Lines[i].UnitPrice,
			TaxRateBp: ptr(int(in.Lines[i].TaxRateBP)), LineDiscount: ptr(l.LineDiscount), BillDiscountShare: ptr(l.BillDiscountShare),
			ServiceShare: ptr(l.ServiceShare), TaxAmount: ptr(l.TaxAmount), TaxIncluded: ptr(l.TaxIncluded), NetAmount: ptr(l.NetAmount),
			Modifiers: []wire.OrderItemModifier{},
		}
		if d := in.Lines[i].Discount; d != nil {
			item.Discount = &wire.DiscountSpec{Kind: wire.DiscountSpecKind(d.Kind), Value: d.Value}
		}
		o.Items = append(o.Items, item)
	}
	return o
}

func (f *fixture) storedPricing(t *testing.T, id string) (taxIncluded, rounding int64, mismatch bool) {
	t.Helper()
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		`SELECT tax_included, rounding_amount, pricing_mismatch FROM orders WHERE id=$1`, id).
		Scan(&taxIncluded, &rounding, &mismatch))
	return
}

func TestAVersion2ReceiptIsStoredWithItsIncludedTaxAndRounding(t *testing.T) {
	f := setup(t)
	session := f.session(t, false)
	accepted(t, f.push("pos_sessions", session))
	o := f.v2Order(t, session.Id)
	require.NotZero(t, *o.TaxIncluded, "the fixture must exercise inclusive tax")
	require.NotZero(t, *o.RoundingAmount, "the fixture must exercise rounding")

	accepted(t, f.push("orders", o))
	included, rounding, mismatch := f.storedPricing(t, o.Id)
	require.Equal(t, *o.TaxIncluded, included)
	require.Equal(t, *o.RoundingAmount, rounding)
	require.False(t, mismatch, "the server's recomputation agrees with the till")

	// An exact retry is still one receipt.
	accepted(t, f.push("orders", o))
	require.EqualValues(t, 1, f.count(t, "orders"))
}

func TestARecomputationDisagreementIsFlaggedNeverRefused(t *testing.T) {
	f := setup(t)
	session := f.session(t, false)
	accepted(t, f.push("pos_sessions", session))
	o := f.v2Order(t, session.Id)
	// The till moved one rupiah of bill discount between lines. Its own
	// arithmetic still closes, so the sale is accepted — but it is not what
	// the engine would have produced, and that is recorded.
	*o.Items[0].BillDiscountShare++
	*o.Items[0].NetAmount--
	*o.Items[1].BillDiscountShare--
	*o.Items[1].NetAmount++
	accepted(t, f.push("orders", o))
	_, _, mismatch := f.storedPricing(t, o.Id)
	require.True(t, mismatch)
}

func TestVersion2ArithmeticThatDoesNotCloseIsRejected(t *testing.T) {
	f := setup(t)
	session := f.session(t, false)
	accepted(t, f.push("pos_sessions", session))

	cases := map[string]func(*wire.Order){
		"lines do not add up to the header tax": func(o *wire.Order) { *o.Items[0].TaxAmount++ },
		"a line's net does not close":           func(o *wire.Order) { *o.Items[1].NetAmount++ },
		"a line is missing its breakdown":       func(o *wire.Order) { o.Items[0].ServiceShare = nil },
		"no snapshot":                           func(o *wire.Order) { o.Pricing = nil },
		"included tax above tax": func(o *wire.Order) {
			o.TaxIncluded = ptr(o.Tax + 1)
			o.Total -= 1
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			o := f.v2Order(t, session.Id)
			mutate(&o)
			rows := f.push("orders", o)
			require.Equal(t, wire.PushResultStatus("rejected"), rows[0].Status, "%+v", rows[0])
			require.Equal(t, "schema_rejected", string(*rows[0].Code))
		})
	}
}

func TestALegacyReceiptCannotCarryTheNewTerms(t *testing.T) {
	f := setup(t)
	session := f.session(t, false)
	accepted(t, f.push("pos_sessions", session))
	o := f.order(t, session.Id)
	o.RoundingAmount = ptr(int64(-50))
	o.Total -= 50
	rows := f.push("orders", o)
	require.Equal(t, wire.PushResultStatus("rejected"), rows[0].Status)

	// And the old shape, with none of them, is untouched.
	accepted(t, f.push("orders", f.order(t, session.Id)))
}

func TestTheNewPricingTermsAreImmutableAcrossRevisions(t *testing.T) {
	f := setup(t)
	session := f.session(t, false)
	accepted(t, f.push("pos_sessions", session))
	o := f.v2Order(t, session.Id)
	accepted(t, f.push("orders", o))

	o.Revision = 2
	o.Status = "served"
	*o.Items[0].ServiceShare++
	*o.Items[1].ServiceShare--
	rows := f.push("orders", o)
	require.Equal(t, wire.PushResultStatus("rejected"), rows[0].Status, "a later revision may change status, never the money")
}
