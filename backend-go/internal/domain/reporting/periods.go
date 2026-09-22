package reporting

import "time"

// The periods every dashboard offers, named once so the till and the
// Backoffice cannot drift into meaning different things by "7 hari". They are
// resolved against the merchant's own today, never the server's.
const (
	PeriodToday     = "today"
	PeriodYesterday = "yesterday"
	PeriodLast7     = "last7"
	PeriodThisMonth = "month"
	PeriodCustom    = "custom"
)

// Periods is the offer order: the two single days people check constantly,
// then the two windows they plan with.
var Periods = []string{PeriodToday, PeriodYesterday, PeriodLast7, PeriodThisMonth}

// PeriodLabel names a period for a screen.
func PeriodLabel(preset string) string {
	switch preset {
	case PeriodToday:
		return "Hari ini"
	case PeriodYesterday:
		return "Kemarin"
	case PeriodLast7:
		return "7 hari"
	case PeriodThisMonth:
		return "Bulan berjalan"
	}
	return "Rentang khusus"
}

// ResolvePeriod turns a preset into a range on the merchant's clock, and
// returns the preset it actually used.
//
// An unknown preset falls back to today rather than erroring: a dashboard is a
// glance, and a bookmark from an older version should show something rather
// than a validation page. A custom range is only honoured when both ends parse
// — half a range is not a range, and silently completing it from today would
// show a period nobody asked for.
func ResolvePeriod(preset string, today, from, to time.Time) (Filter, string) {
	switch preset {
	case PeriodCustom:
		if !from.IsZero() && !to.IsZero() {
			return Filter{From: from, To: to}, PeriodCustom
		}
		return Filter{From: today, To: today}, PeriodToday
	case PeriodYesterday:
		yesterday := today.AddDate(0, 0, -1)
		return Filter{From: yesterday, To: yesterday}, PeriodYesterday
	case PeriodLast7:
		// Seven days ENDING today, today included: "the last week of trade",
		// not "the week before this one".
		return Filter{From: today.AddDate(0, 0, -6), To: today}, PeriodLast7
	case PeriodThisMonth:
		return Filter{From: time.Date(today.Year(), today.Month(), 1, 0, 0, 0, 0, time.UTC), To: today}, PeriodThisMonth
	}
	return Filter{From: today, To: today}, PeriodToday
}

// PreviousPeriod is the same NUMBER OF DAYS immediately before f.
//
// Same length rather than "the same period last month": comparing a 31-day
// month with a 28-day one makes February look like a collapse. The comparison
// is only ever "this many days, then the same many days before them".
func PreviousPeriod(f Filter) Filter {
	days := DaysBetween(f.From, f.To) + 1
	return Filter{
		From:     f.From.AddDate(0, 0, -days),
		To:       f.From.AddDate(0, 0, -1),
		OutletID: f.OutletID,
	}
}

// Change is the movement between two periods as a percentage, and whether
// there is one worth showing.
//
// A zero base is NOT a 100% rise or an infinite one: there is nothing to
// compare against, so the second return is false and the screen writes "—".
// Rendering ∞ or a made-up 100% is how a first day of trade reads as a
// triumph and a first quiet day reads as a catastrophe.
func Change(current, previous int64) (float64, bool) {
	if previous == 0 {
		return 0, false
	}
	return float64(current-previous) * 100 / float64(previous), true
}
