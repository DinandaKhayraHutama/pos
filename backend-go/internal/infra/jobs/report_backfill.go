package jobs

import (
	"context"
	"errors"
	"log/slog"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/riverqueue/river"
)

// ReportBackfill drains the durable dirty markers into slice jobs, a bounded
// batch per merchant per sweep.
//
// It is how a change to what a figure MEANS reaches history. A migration marks
// every affected slice — including dates far outside the nightly window and
// outlets that have been switched off — and this sweep turns those markers into
// work at a rate the reporting queue can absorb. Nothing tracks progress
// outside the markers themselves, so an interrupted backfill resumes rather
// than restarting, and a sweep that overlaps the previous one enqueues nothing
// new: the slice job key is unique per slice.
type ReportBackfill struct{}

func (ReportBackfill) Kind() string { return "report_backfill" }

type reportBackfillWorker struct {
	river.WorkerDefaults[ReportBackfill]
	pool    *pgxpool.Pool
	reports Reports
	logger  *slog.Logger
}

// Work sweeps every active merchant. One merchant's failure is collected
// rather than returned immediately, so a single bad tenant cannot stop the
// backfill of all the others — the job still fails, and River retries the
// whole sweep, which is idempotent.
func (w *reportBackfillWorker) Work(ctx context.Context, _ *river.Job[ReportBackfill]) error {
	tenants, err := activeTenants(ctx, w.pool)
	if err != nil {
		return err
	}
	var failures []error
	for _, tenantID := range tenants {
		if err := w.reports.QueuePending(ctx, tenantID); err != nil {
			w.logger.Error("report backfill sweep failed", "tenant", tenantID, "error", err)
			failures = append(failures, err)
		}
	}
	return errors.Join(failures...)
}
