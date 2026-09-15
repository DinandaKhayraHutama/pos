package reporting_test

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
)

var jakarta = func() *time.Location {
	loc, err := time.LoadLocation("Asia/Jakarta")
	if err != nil {
		panic(err)
	}
	return loc
}()

func wibTime(y int, m time.Month, d, h, min int) time.Time {
	return time.Date(y, m, d, h, min, 0, 0, jakarta)
}

func date(y int, m time.Month, d int) time.Time {
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

// 15 September 2026 is a Tuesday.
func TestADeliveryIsAtSixOnTheMerchantsClock(t *testing.T) {
	for _, tc := range []struct {
		name      string
		frequency string
		after     time.Time
		want      time.Time
	}{
		{"daily before six", reporting.FrequencyDaily, wibTime(2026, 9, 15, 5, 0), wibTime(2026, 9, 15, 6, 0)},
		{"daily at six exactly moves on", reporting.FrequencyDaily, wibTime(2026, 9, 15, 6, 0), wibTime(2026, 9, 16, 6, 0)},
		{"daily across a month end", reporting.FrequencyDaily, wibTime(2026, 9, 30, 7, 0), wibTime(2026, 10, 1, 6, 0)},
		{"weekly waits for Monday", reporting.FrequencyWeekly, wibTime(2026, 9, 15, 9, 0), wibTime(2026, 9, 21, 6, 0)},
		{"weekly on Monday before six", reporting.FrequencyWeekly, wibTime(2026, 9, 21, 5, 59), wibTime(2026, 9, 21, 6, 0)},
		{"weekly on Monday after six", reporting.FrequencyWeekly, wibTime(2026, 9, 21, 6, 1), wibTime(2026, 9, 28, 6, 0)},
		{"monthly waits for the first", reporting.FrequencyMonthly, wibTime(2026, 9, 15, 9, 0), wibTime(2026, 10, 1, 6, 0)},
		{"monthly on the first before six", reporting.FrequencyMonthly, wibTime(2026, 10, 1, 5, 0), wibTime(2026, 10, 1, 6, 0)},
		{"monthly across a year end", reporting.FrequencyMonthly, wibTime(2026, 12, 2, 0, 0), wibTime(2027, 1, 1, 6, 0)},
		// 23:30 UTC on the 14th is already 06:30 on the 15th in Jakarta.
		{"the merchant's day, not UTC's", reporting.FrequencyDaily, time.Date(2026, 9, 14, 23, 30, 0, 0, time.UTC), wibTime(2026, 9, 16, 6, 0)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			require.True(t, tc.want.Equal(reporting.NextRun(tc.frequency, jakarta, tc.after)),
				"got %s", reporting.NextRun(tc.frequency, jakarta, tc.after))
		})
	}
}

func TestADeliveryReportsTheLastCompletePeriod(t *testing.T) {
	for _, tc := range []struct {
		name      string
		frequency string
		runAt     time.Time
		from, to  time.Time
	}{
		{"daily is yesterday", reporting.FrequencyDaily, wibTime(2026, 9, 15, 6, 0), date(2026, 9, 14), date(2026, 9, 14)},
		{"weekly is last Monday to Sunday", reporting.FrequencyWeekly, wibTime(2026, 9, 21, 6, 0), date(2026, 9, 14), date(2026, 9, 20)},
		{"weekly run late in the week still means last week", reporting.FrequencyWeekly, wibTime(2026, 9, 24, 6, 0), date(2026, 9, 14), date(2026, 9, 20)},
		{"monthly is last calendar month", reporting.FrequencyMonthly, wibTime(2026, 10, 1, 6, 0), date(2026, 9, 1), date(2026, 9, 30)},
		{"monthly in January is December", reporting.FrequencyMonthly, wibTime(2027, 1, 1, 6, 0), date(2026, 12, 1), date(2026, 12, 31)},
		{"a UTC instant resolves on the merchant's clock", reporting.FrequencyDaily, time.Date(2026, 9, 14, 23, 0, 0, 0, time.UTC), date(2026, 9, 14), date(2026, 9, 14)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			from, to := reporting.Period(tc.frequency, jakarta, tc.runAt)
			require.Equal(t, tc.from, from)
			require.Equal(t, tc.to, to)
		})
	}
}

func TestAReportRangeIsBoundedAndOrdered(t *testing.T) {
	ok := reporting.Filter{From: date(2026, 9, 1), To: date(2026, 9, 30)}
	require.NoError(t, ok.Validate(reporting.MaxReportDays))

	fields := func(f reporting.Filter, max int) validation.Errors {
		t.Helper()
		errs, invalid := validation.As(f.Validate(max))
		require.True(t, invalid, "expected field errors for %+v", f)
		return errs
	}
	require.Contains(t, fields(reporting.Filter{From: date(2026, 9, 30), To: date(2026, 9, 1)}, reporting.MaxReportDays), "to")
	require.Contains(t, fields(reporting.Filter{From: date(2025, 1, 1), To: date(2026, 9, 1)}, reporting.MaxReportDays), "to")
	require.Contains(t, fields(reporting.Filter{}, reporting.MaxReportDays), "from")
	require.Contains(t, fields(reporting.Filter{From: date(2026, 9, 1), To: date(2026, 9, 1), OutletID: "kemang"}, reporting.MaxReportDays), "outlet")
	// A year is allowed; a recompute is held to a quarter.
	require.NoError(t, reporting.Filter{From: date(2025, 9, 16), To: date(2026, 9, 15)}.Validate(reporting.MaxReportDays))
	require.Contains(t, fields(reporting.Filter{From: date(2026, 1, 1), To: date(2026, 9, 1)}, reporting.MaxRecomputeDays), "to")
}
