// Package jobs owns transactional enqueueing. Reporting execution belongs to
// Fase 7; its queue is intentionally not consumed by the maintenance worker.
package jobs

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/riverqueue/river"
	"github.com/riverqueue/river/riverdriver/riverpgxv5"
	"github.com/riverqueue/river/rivertype"
)

type ReportSlice struct {
	TenantID     string `json:"tenant_id"`
	OutletID     string `json:"outlet_id"`
	BusinessDate string `json:"business_date"`
}

func (ReportSlice) Kind() string { return "report_slice" }

func NewInserter(pool *pgxpool.Pool, logger *slog.Logger) (*river.Client[pgx.Tx], error) {
	return river.NewClient(riverpgxv5.New(pool), &river.Config{Schema: "jobs", Logger: logger})
}

func EnqueueReport(ctx context.Context, tx pgx.Tx, client *river.Client[pgx.Tx], args ReportSlice) error {
	_, err := client.InsertTx(ctx, tx, args, &river.InsertOpts{
		Queue: "reporting", ScheduledAt: time.Now().Add(time.Minute),
		UniqueOpts: river.UniqueOpts{ByArgs: true, ByState: []rivertype.JobState{
			rivertype.JobStateAvailable, rivertype.JobStatePending, rivertype.JobStateRunning,
			rivertype.JobStateScheduled, rivertype.JobStateRetryable,
		}},
	})
	return err
}
