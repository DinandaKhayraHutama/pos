package pricing

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

// The vectors live at the repository root, shared with the Flutter till's
// test/pricing/vectors_test.dart. Both ports must reproduce every header and
// every line figure; neither side may skip a file silently.
const expectedVectorFiles = 5 // legacy_v1, v2_exclusive, v2_inclusive, rounding, overflow

func vectorDir(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	require.NoError(t, err)
	for {
		candidate := filepath.Join(dir, "testdata", "pricing")
		if st, err := os.Stat(candidate); err == nil && st.IsDir() {
			return candidate
		}
		parent := filepath.Dir(dir)
		require.NotEqual(t, parent, dir, "testdata/pricing not found above the package")
		dir = parent
	}
}

type vector struct {
	Name     string `json:"name"`
	Input    Input  `json:"input"`
	Expected Result `json:"expected"`
}

func TestPricingVectors(t *testing.T) {
	dir := vectorDir(t)
	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	require.NoError(t, err)
	seen := 0
	for _, f := range files {
		if filepath.Base(f) == "allocate.json" {
			continue
		}
		seen++
		raw, err := os.ReadFile(f)
		require.NoError(t, err)
		var doc struct {
			Vectors []vector `json:"vectors"`
		}
		require.NoError(t, json.Unmarshal(raw, &doc))
		require.NotEmpty(t, doc.Vectors, f)
		for _, v := range doc.Vectors {
			t.Run(filepath.Base(f)+"/"+v.Name, func(t *testing.T) {
				got, err := Compute(v.Input)
				require.NoError(t, err)
				require.Equal(t, v.Expected, got)
				if v.Input.Version == VersionV2 {
					requireReconciles(t, got)
				}
			})
		}
	}
	require.Equal(t, expectedVectorFiles, seen, "a vector file was added or removed; update both ports' counts")
}

func TestAllocateVectors(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(vectorDir(t), "allocate.json"))
	require.NoError(t, err)
	var doc struct {
		Cases []struct {
			Name     string  `json:"name"`
			Total    int64   `json:"total"`
			Weights  []int64 `json:"weights"`
			Expected []int64 `json:"expected"`
		} `json:"cases"`
	}
	require.NoError(t, json.Unmarshal(raw, &doc))
	require.NotEmpty(t, doc.Cases)
	for _, c := range doc.Cases {
		t.Run(c.Name, func(t *testing.T) {
			require.Equal(t, c.Expected, Allocate(c.Total, c.Weights))
		})
	}
}

// requireReconciles is the version 2 promise the ingest check relies on.
func requireReconciles(t *testing.T, r Result) {
	t.Helper()
	var disc, svc, tax, incl int64
	for _, l := range r.Lines {
		disc += l.LineDiscount + l.BillDiscountShare
		svc += l.ServiceShare
		tax += l.TaxAmount
		incl += l.TaxIncluded
		require.Equal(t, l.Gross-l.LineDiscount-l.BillDiscountShare-l.TaxIncluded, l.NetAmount)
		require.GreaterOrEqual(t, l.NetAmount, int64(0))
	}
	require.Equal(t, r.Discount, disc)
	require.Equal(t, r.ServiceCharge, svc)
	require.Equal(t, r.Tax, tax)
	require.Equal(t, r.TaxIncluded, incl)
	require.Equal(t, r.Subtotal-r.Discount+r.ServiceCharge+r.Tax-r.TaxIncluded+r.Rounding, r.Total)
}

func TestAllocateNeverExceedsAWeight(t *testing.T) {
	// The property that made Hamilton the choice over "whole remainder to the
	// largest row": for every total up to the sum, no share passes its weight.
	weights := []int64{1, 1, 1, 7, 2, 0, 3}
	var sum int64
	for _, w := range weights {
		sum += w
	}
	for total := int64(0); total <= sum; total++ {
		got := Allocate(total, weights)
		var s int64
		for i, g := range got {
			require.LessOrEqual(t, g, weights[i], "total %d", total)
			s += g
		}
		require.Equal(t, total, s)
	}
}

func TestInvalidInputIsRefused(t *testing.T) {
	for _, in := range []Input{
		{Version: 3},
		{Version: 2, ServiceRateBP: 10001},
		{Version: 2, TaxMode: "gross"},
		{Version: 2, RoundingMode: "bankers"},
		{Version: 2, BillDiscount: &Discount{Kind: "percent", Value: 10001}},
		{Version: 2, Lines: []Line{{UnitPrice: -1, Quantity: 1}}},
		{Version: 2, Lines: []Line{{UnitPrice: 1, Quantity: 1, Discount: &Discount{Kind: "free"}}}},
	} {
		_, err := Compute(in)
		require.ErrorIs(t, err, ErrInvalid)
	}
}
