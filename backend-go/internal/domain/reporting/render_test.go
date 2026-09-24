package reporting_test

import (
	"archive/zip"
	"bytes"
	"encoding/csv"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
)

func sampleReport() reporting.Report {
	computed := time.Date(2026, 9, 15, 1, 5, 0, 0, time.UTC)
	return reporting.Report{
		From: date(2026, 9, 1), To: date(2026, 9, 15), BusinessName: "Warung & Kopi", Timezone: "Asia/Jakarta",
		CalculationVersion: 2,
		GrossSales:         90000, AllDiscount: 5500, SalesReturns: 15000, NetSales: 69500,
		Revenue: 77450, Subtotal: 75000, Discount: 5500, OrderCount: 2, ItemsSold: 5, CostedItems: 3, CostCoverage: 0.6,
		CostOfGoods: 15000, GrossProfit: 54500,
		ByCategory: []reporting.CategorySales{
			{Key: "c1", Name: "=HYPERLINK(\"http://evil\")", Gross: 45000, Net: 42000, Items: 3, ContributionPercent: 60.4316},
			{Key: reporting.Uncategorised, Gross: 5000, Net: 5000, Items: 1, ContributionPercent: 7.19},
		},
		ByHour:     []reporting.HourLine{{Hour: 9, Revenue: 54450, NetSales: 49500, Orders: 1}},
		ComputedAt: &computed,
	}
}

func TestACSVExportIsExcelReadableAndCannotRunAFormula(t *testing.T) {
	data, err := reporting.RenderCSV(reporting.Tables(sampleReport(), jakarta))
	require.NoError(t, err)

	require.True(t, bytes.HasPrefix(data, []byte{0xEF, 0xBB, 0xBF}), "UTF-8 byte-order mark for Excel")
	r := csv.NewReader(bytes.NewReader(data[3:]))
	r.FieldsPerRecord = -1
	records, err := r.ReadAll()
	require.NoError(t, err)

	text := func(cells ...string) bool {
		for _, rec := range records {
			if strings.Join(rec, "|") == strings.Join(cells, "|") {
				return true
			}
		}
		return false
	}
	// The waterfall, in order, as plain integers a spreadsheet can sum.
	require.True(t, text("Penjualan kotor", "90000"))
	require.True(t, text("Retur penjualan", "15000"))
	require.True(t, text("Penjualan bersih", "69500"))
	require.True(t, text("Total penerimaan penjualan", "77450"), "money as plain integers")
	require.True(t, text("Laba kotor", "54500"))
	require.True(t, text("Cakupan HPP (%)", "60.00"))
	// Provenance: a file outlives the screen it came from.
	require.True(t, text("Zona waktu", "Asia/Jakarta"))
	require.True(t, text("Versi perhitungan", "2"))
	require.True(t, text("Kelengkapan data", "lengkap"))
	require.True(t, text("Data per", "2026-09-15 08:05"), "computed time on the merchant's clock")
	require.True(t, text(`'=HYPERLINK("http://evil")`, "45000", "42000", "3", "60.43"), "a name is data, never a formula")
	require.True(t, text("Tanpa kategori", "5000", "5000", "1", "7.19"))
	require.True(t, text("09:00", "49500", "54450", "1"))

	require.Equal(t, "'-1", reporting.SafeText("-1"))
	require.Equal(t, "'@SUM(A1)", reporting.SafeText("@SUM(A1)"))
	require.Equal(t, "Kopi", reporting.SafeText("Kopi"))
}

func TestAnXLSXExportIsAWorkbookWithNumbersAsNumbers(t *testing.T) {
	data, err := reporting.RenderXLSX(reporting.Tables(sampleReport(), jakarta))
	require.NoError(t, err)

	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	require.NoError(t, err)
	parts := map[string]string{}
	for _, f := range zr.File {
		rc, err := f.Open()
		require.NoError(t, err)
		b, err := io.ReadAll(rc)
		require.NoError(t, err)
		require.NoError(t, rc.Close())
		parts[f.Name] = string(b)
	}

	sections := reporting.Tables(sampleReport(), jakarta)
	for _, name := range []string{"[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels",
		"xl/styles.xml", "xl/worksheets/sheet1.xml", fmt.Sprintf("xl/worksheets/sheet%d.xml", len(sections))} {
		require.Contains(t, parts, name)
	}
	require.Equal(t, len(sections), strings.Count(parts["xl/workbook.xml"], "<sheet "))
	require.Contains(t, parts["xl/workbook.xml"], `name="Audit diskon &amp; void"`)

	sheet := func(title string) string {
		for i, s := range sections {
			if s.Title == title {
				return parts[fmt.Sprintf("xl/worksheets/sheet%d.xml", i+1)]
			}
		}
		require.FailNow(t, "no such section", title)
		return ""
	}

	// Row 1 is the title and row 2 the header, so the waterfall starts at 3
	// and "Total penerimaan penjualan" is its seventh line.
	summary := sheet("Ringkasan penjualan")
	require.Contains(t, summary, `<c r="B11" s="2"><v>77450</v></c>`, "revenue is a number cell (row 11 since Fase 3 added included tax and rounding to the waterfall)")
	require.Contains(t, summary, `<v>60.00</v>`)

	categories := sheet("Kategori")
	require.Contains(t, categories, `=HYPERLINK(&#34;http://evil&#34;)`, "inline strings are text, escaped")
	require.NotContains(t, categories, "<f>", "no formula element is ever written")
}

func TestSpreadsheetNamesAndColumnsFollowTheFormat(t *testing.T) {
	for i, want := range map[int]string{0: "A", 25: "Z", 26: "AA", 27: "AB", 701: "ZZ", 702: "AAA"} {
		require.Equal(t, want, reporting.ColumnName(i), "column %d", i)
	}

	names := reporting.SheetNames([]reporting.Table{
		{Title: "Penjualan per outlet / kasir [detail]: semua"},
		{Title: "Penjualan per outlet / kasir [detail]: semua"},
		{Title: "?*"},
	})
	require.Len(t, names, 3)
	seen := map[string]bool{}
	for _, n := range names {
		require.LessOrEqual(t, len([]rune(n)), 31)
		require.NotContains(t, n, "/")
		require.NotContains(t, n, "[")
		require.False(t, seen[strings.ToLower(n)], "duplicate sheet name %q", n)
		seen[strings.ToLower(n)] = true
	}
}
