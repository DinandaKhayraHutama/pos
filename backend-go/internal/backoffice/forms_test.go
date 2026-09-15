package backoffice

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
)

// Every price typed into the panel and every price in an uploaded spreadsheet
// goes through here. The failure it guards against is silent: stripping every
// dot would read "25000.50" as 2.500.050, a hundredfold price rise with no
// message at all.
func TestRupiahIsReadOnlyWhenItIsUnambiguous(t *testing.T) {
	for input, want := range map[string]int64{
		"25000":       25_000,
		"25.000":      25_000,
		"1.250.000":   1_250_000,
		"Rp 25.000":   25_000,
		" 7500 ":      7_500,
		"-5.000":      -5_000,
		"0":           0,
		"":            0,
		"999.999.999": 999_999_999,
	} {
		got, message := parseRupiah(input)
		require.Empty(t, message, "%q should be accepted", input)
		require.Equal(t, want, got, "%q", input)
	}

	for _, input := range []string{
		"25000.50",  // a decimal, not a separator
		"25,000",    // a comma is a decimal mark here
		"25.00",     // not a group of three
		"2.5000",    // a group of four
		"25.000,50", // cents do not exist
		"dua puluh",
		"1e6",
		"99999999999999999999", // past int64
	} {
		_, message := parseRupiah(input)
		require.NotEmpty(t, message, "%q must be refused, not guessed at", input)
	}
}

func TestAPriceListIsReadFromEitherSpreadsheetDialect(t *testing.T) {
	for name, file := range map[string]string{
		"commas":           "sku,harga\nNG-01,25000\nMG-01,\"22.000\"\n",
		"semicolons":       "sku;harga\nNG-01;25000\nMG-01;22.000\n",
		"english header":   "SKU,Price\nNG-01,25000\nMG-01,22000\n",
		"byte-order mark":  string(rune(0xFEFF)) + "sku,harga\nNG-01,25000\nMG-01,22000\n",
		"extra columns":    "nama,sku,harga\nNasi,NG-01,25000\nMie,MG-01,22000\n",
		"windows newlines": "sku,harga\r\nNG-01,25000\r\nMG-01,22000\r\n",
	} {
		t.Run(name, func(t *testing.T) {
			rows, problems := readPriceList(strings.NewReader(file))
			require.Empty(t, problems)
			require.Equal(t, []catalogue.PriceChange{
				{Line: 2, SKU: "NG-01", Price: 25_000},
				{Line: 3, SKU: "MG-01", Price: 22_000},
			}, rows)
		})
	}
}

// One upload should show every problem in the file, each on its own line
// number, rather than stopping at the first.
func TestEveryUnreadableLineIsReported(t *testing.T) {
	rows, problems := readPriceList(strings.NewReader(
		"sku,harga\nNG-01,25000.50\nMG-01,\nET-01,5000\nXX\n"))

	require.Len(t, rows, 1)
	require.Equal(t, "ET-01", rows[0].SKU)

	lines := make([]int, 0, len(problems))
	for _, p := range problems {
		lines = append(lines, p.Line)
	}
	require.Equal(t, []int{2, 3, 5}, lines)
}

func TestAPriceListNeedsItsTwoColumns(t *testing.T) {
	_, problems := readPriceList(strings.NewReader("kode,nominal\nNG-01,25000\n"))

	require.Len(t, problems, 1)
	require.Equal(t, 1, problems[0].Line)
}
