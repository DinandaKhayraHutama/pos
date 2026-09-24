package ingest

import (
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/pricing"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
)

func deref[T int64 | int](p *T) T {
	if p == nil {
		return 0
	}
	return *p
}

// validatePricing is the half of the Fase 3 contract that REJECTS: arithmetic
// that does not close on its own terms. A version 2 receipt carries a
// breakdown per line, and those lines must add up to the header it prints —
// otherwise every report built from the lines disagrees with the one built
// from the header, and F5's split and refund have no honest base.
//
// It deliberately does not recompute the bill. That is pricingMismatch below,
// and its answer is a flag, not a refusal.
func validatePricing(in wire.Order) error {
	version := deref(in.PricingVersion)
	if version != pricing.VersionV2 {
		// A legacy receipt has no snapshot to be checked against, and must not
		// smuggle the new terms in without one.
		if in.Pricing != nil || deref(in.TaxIncluded) != 0 || deref(in.RoundingAmount) != 0 {
			return reject("schema_rejected", "Included tax and rounding need a version 2 pricing snapshot.")
		}
		return nil
	}
	if in.Pricing == nil {
		return reject("schema_rejected", "A version 2 receipt needs its pricing snapshot.")
	}
	var discount, service, tax, included int64
	for _, item := range in.Items {
		if item.TaxRateBp == nil || item.LineDiscount == nil || item.BillDiscountShare == nil ||
			item.ServiceShare == nil || item.TaxAmount == nil || item.TaxIncluded == nil || item.NetAmount == nil {
			return reject("schema_rejected", "A version 2 line needs its full breakdown.")
		}
		gross := item.UnitPrice * int64(item.Quantity)
		ld, bs, ti := *item.LineDiscount, *item.BillDiscountShare, *item.TaxIncluded
		if ld+bs > gross || *item.NetAmount != gross-ld-bs-ti || ti > *item.TaxAmount {
			return reject("schema_rejected", "A line's breakdown does not close.")
		}
		discount += ld + bs
		service += *item.ServiceShare
		tax += *item.TaxAmount
		included += ti
	}
	if discount != in.Discount || service != in.ServiceChargeAmount || tax != in.Tax || included != deref(in.TaxIncluded) {
		return reject("schema_rejected", "The lines do not add up to the header.")
	}
	return nil
}

// pricingMismatch reports whether the server, pricing the receipt's own
// snapshot with the shared engine, arrives at different figures than the till
// printed.
//
// The answer is recorded on the order and surfaced as an anomaly. It is never
// a reason to refuse: the sale happened, the customer paid what the receipt
// says, and a till that priced it offline cannot be asked to do it again.
// Version 1 receipts are never recomputed — they predate the snapshot.
func pricingMismatch(in wire.Order) bool {
	if deref(in.PricingVersion) != pricing.VersionV2 || in.Pricing == nil {
		return false
	}
	p := in.Pricing
	input := pricing.Input{
		Version:        pricing.VersionV2,
		TaxMode:        string(p.TaxMode),
		ServiceRateBP:  int64(p.ServiceRateBp),
		ServiceTaxable: p.ServiceTaxable,
		RoundingUnit:   int64(p.RoundingUnit),
		RoundingMode:   string(p.RoundingMode),
		BillDiscount:   discountSpec(p.BillDiscount),
		Lines:          make([]pricing.Line, len(in.Items)),
	}
	for i, item := range in.Items {
		input.Lines[i] = pricing.Line{
			UnitPrice: item.UnitPrice,
			Quantity:  int64(item.Quantity),
			TaxRateBP: int64(deref(item.TaxRateBp)),
			Discount:  discountSpec(item.Discount),
		}
	}
	got, err := pricing.Compute(input)
	if err != nil {
		return true
	}
	if got.Subtotal != in.Subtotal || got.Discount != in.Discount || got.ServiceCharge != in.ServiceChargeAmount ||
		got.Tax != in.Tax || got.TaxIncluded != deref(in.TaxIncluded) || got.Rounding != deref(in.RoundingAmount) ||
		got.Total != in.Total {
		return true
	}
	for i, item := range in.Items {
		l := got.Lines[i]
		if l.LineDiscount != deref(item.LineDiscount) || l.BillDiscountShare != deref(item.BillDiscountShare) ||
			l.ServiceShare != deref(item.ServiceShare) || l.TaxAmount != deref(item.TaxAmount) ||
			l.TaxIncluded != deref(item.TaxIncluded) || l.NetAmount != deref(item.NetAmount) {
			return true
		}
	}
	return false
}

func discountSpec(d *wire.DiscountSpec) *pricing.Discount {
	if d == nil {
		return nil
	}
	return &pricing.Discount{Kind: string(d.Kind), Value: d.Value}
}
