// Package reporting owns the report rollups and everything read from them: the
// Backoffice sales report and dashboard, their exports, and scheduled
// deliveries.
//
// Three rules carry the design, and each is a failure it prevents:
//
//   - **A report never reads the order tables.** Thirty million orders a month
//     cannot be summed on every page view. Reports read the rollups, show when
//     they were computed, and the raw path exists only behind "hitung ulang",
//     which recomputes rollups rather than bypassing them.
//   - **A slice is recomputed whole, on one snapshot.** Every rollup of one
//     (tenant, outlet, business_date) is deleted and rebuilt inside a single
//     REPEATABLE READ transaction, so the totals, the category split and the
//     hourly curve always describe the same set of orders.
//   - **A dirty marker is cleared only for the generation that was computed.**
//     Ingest bumps report_dirty_slices.generation in the same transaction as
//     the order. The job reads the generation on its snapshot and deletes the
//     marker only while it is unchanged; a sale that landed meanwhile keeps the
//     marker and the job runs again. A clean slice therefore always includes
//     everything committed before its computed_at.
//
// Money semantics are the till's: revenue is every order that is not cancelled
// or refunded, unit_price already includes variant and modifier deltas, and the
// category split is the largest-remainder allocation of AggregateCategories.
package reporting

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"
	// Report hours and schedule times are on the merchant's clock, and a slim
	// container image has no zoneinfo of its own.
	_ "time/tzdata"

	"github.com/jackc/pgx/v5"
	"github.com/riverqueue/river"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/jobs"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/mailer"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

var (
	ErrNotFound         = errors.New("reporting: no such outlet, export or schedule")
	ErrPDFNotConfigured = errors.New("reporting: GOTENBERG_URL is not configured, so PDF exports are unavailable")
	ErrExportNotReady   = errors.New("reporting: the export is not ready")
	ErrLinkExpired      = errors.New("reporting: the download link has expired")
)

// MaxReportDays bounds one report or export.
const MaxReportDays = 366

// PDFRenderer turns the report page's HTML into a PDF.
type PDFRenderer interface {
	RenderPDF(ctx context.Context, html []byte) ([]byte, error)
}

// HTMLRenderer renders a report as a standalone printable page. It lives with
// the Backoffice templates, so the PDF is the page, not a second layout.
type HTMLRenderer func(ctx context.Context, r Report) ([]byte, error)

// Mailer sends one plain-text message.
type Mailer interface {
	Send(ctx context.Context, msg mailer.Message) error
}

type Options struct {
	// ExportDir is where export files are written. Private: nothing serves the
	// directory itself.
	ExportDir string
	// LinkBaseURL is the origin e-mailed download links start with.
	LinkBaseURL string
	// LinkTTL is how long an e-mailed link works. Defaults to a day.
	LinkTTL time.Duration
	PDF     PDFRenderer
	HTML    HTMLRenderer
	Mail    Mailer
}

type Service struct {
	pools  pg.Pools
	queue  *river.Client[pgx.Tx]
	logger *slog.Logger
	opts   Options

	// afterRollup runs between a slice's rollup commit and its marker check.
	// Tests land a sale there, exactly where a real one would race the job.
	afterRollup func()
}

func NewService(pools pg.Pools, logger *slog.Logger, opts Options) (*Service, error) {
	queue, err := jobs.NewInserter(pools.Tenant, logger)
	if err != nil {
		return nil, err
	}
	if opts.LinkTTL <= 0 {
		opts.LinkTTL = 24 * time.Hour
	}
	return &Service{pools: pools, queue: queue, logger: logger, opts: opts}, nil
}

// Filter is a report range and, optionally, one outlet. Dates are calendar
// dates carried as UTC midnight.
type Filter struct {
	From     time.Time
	To       time.Time
	OutletID string
}

func (f Filter) Validate(maxDays int) error {
	errs := validation.Errors{}
	if f.From.IsZero() {
		errs.Add("from", "Pilih tanggal awal.")
	}
	if f.To.IsZero() {
		errs.Add("to", "Pilih tanggal akhir.")
	}
	if !f.From.IsZero() && !f.To.IsZero() {
		switch {
		case f.To.Before(f.From):
			errs.Add("to", "Tanggal akhir tidak boleh sebelum tanggal awal.")
		case DaysBetween(f.From, f.To) >= maxDays:
			errs.Add("to", fmt.Sprintf("Rentang maksimal %d hari.", maxDays))
		}
	}
	if f.OutletID != "" && !validation.UUID(f.OutletID) {
		errs.Add("outlet", "Outlet tidak dikenal.")
	}
	return errs.Err()
}

// DaysBetween counts whole days from one calendar date to another.
func DaysBetween(from, to time.Time) int {
	return int(to.Sub(from).Hours() / 24)
}

// Date is the calendar date t falls on in loc, as UTC midnight.
func Date(t time.Time, loc *time.Location) time.Time {
	y, m, d := t.In(loc).Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

// ParseDate reads YYYY-MM-DD, or returns the zero time.
func ParseDate(s string) time.Time {
	t, err := time.Parse(time.DateOnly, s)
	if err != nil {
		return time.Time{}
	}
	return t
}

func outletArg(outletID string) *string {
	if outletID == "" {
		return nil
	}
	return &outletID
}

// Location is the merchant's clock.
func (s *Service) Location(ctx context.Context, tenantID string) (*time.Location, error) {
	var tz string
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT timezone FROM tenants WHERE id = $1`, tenantID).Scan(&tz)
	})
	if err != nil {
		return nil, err
	}
	return loadLocation(tz)
}

func loadLocation(tz string) (*time.Location, error) {
	loc, err := time.LoadLocation(tz)
	if err != nil {
		return nil, fmt.Errorf("reporting: merchant timezone %q: %w", tz, err)
	}
	return loc, nil
}

// Today is the merchant's current calendar date.
func (s *Service) Today(ctx context.Context, tenantID string) (time.Time, error) {
	loc, err := s.Location(ctx, tenantID)
	if err != nil {
		return time.Time{}, err
	}
	return Date(time.Now(), loc), nil
}
