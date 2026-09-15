package jobs

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/riverqueue/river"
	"github.com/riverqueue/river/rivertype"
)

// ReportExport renders one requested or scheduled report export.
type ReportExport struct {
	TenantID string `json:"tenant_id"`
	ExportID string `json:"export_id"`
}

func (ReportExport) Kind() string { return "report_export" }

// reportSliceUnique keeps one pending job per slice. A running job is included
// on purpose: a sale that lands while its slice is computing does not add a
// second job, it bumps the marker's generation, and the running job sees that
// and runs again.
var reportSliceUnique = river.UniqueOpts{ByArgs: true, ByState: []rivertype.JobState{
	rivertype.JobStateAvailable, rivertype.JobStatePending, rivertype.JobStateRunning,
	rivertype.JobStateScheduled, rivertype.JobStateRetryable,
}}

// EnqueueReportAt enqueues a slice recompute to run at a chosen time: now for
// a requested recompute, where ingest uses EnqueueReport's one-minute debounce.
func EnqueueReportAt(ctx context.Context, tx pgx.Tx, client *river.Client[pgx.Tx], args ReportSlice, at time.Time) error {
	_, err := client.InsertTx(ctx, tx, args, &river.InsertOpts{
		Queue: "reporting", ScheduledAt: at, UniqueOpts: reportSliceUnique,
	})
	return err
}

// EnqueueExport enqueues an export in the transaction that created its row.
func EnqueueExport(ctx context.Context, tx pgx.Tx, client *river.Client[pgx.Tx], args ReportExport) error {
	_, err := client.InsertTx(ctx, tx, args, &river.InsertOpts{Queue: "reporting", MaxAttempts: 5})
	return err
}
