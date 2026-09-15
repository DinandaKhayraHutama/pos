package jobs

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/riverqueue/river"
	"github.com/riverqueue/river/riverdriver/riverpgxv5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
)

// Reports is the reporting domain as the worker runs it. An interface so this
// package does not import the domain it schedules.
type Reports interface {
	RecomputeSlice(ctx context.Context, tenantID, outletID string, day time.Time) (bool, error)
	RunExport(ctx context.Context, tenantID, exportID string, lastAttempt bool) error
	MarkRecent(ctx context.Context, tenantID string, days int, now time.Time) (int, error)
	VerifySlice(ctx context.Context, tenantID, outletID string, day time.Time) ([]string, bool, error)
	RunDueSchedules(ctx context.Context, now time.Time) (int, error)
	PurgeExports(ctx context.Context, olderThan time.Time) (int, error)
}

// WorkerDeps are the domain services the worker runs jobs for. A nil one is
// simply not scheduled.
type WorkerDeps struct {
	Stock   StockReconciler
	Reports Reports
}

const (
	// sliceSnooze is how long a slice whose marker moved while it computed
	// waits before computing again — about the ingest debounce.
	sliceSnooze = 30 * time.Second
	// recentDays is how far back the nightly recompute reaches: late offline
	// pushes land within it.
	recentDays = 3
	// exportRetention is how long an export file is kept.
	exportRetention = 30 * 24 * time.Hour
	// consistencySample is how many slices the weekly check recomputes.
	consistencySample = 20
)

// NewWorker is the one River client of the worker process.
//
// Queues: "maintenance" (one at a time) for partitions, retention, the stock
// reconcile and the reporting safety nets; "reporting" for slice recomputes
// and exports. Periodic jobs run on an interval from process start.
func NewWorker(pool *pgxpool.Pool, logger *slog.Logger, deps WorkerDeps) (*river.Client[pgx.Tx], error) {
	workers := river.NewWorkers()
	river.AddWorker(workers, &maintenanceWorker{pool: pool, logger: logger})
	periodic := []*river.PeriodicJob{periodicJob(time.Hour, Maintenance{}, "ingest-partitions", true)}
	queues := map[string]river.QueueConfig{"maintenance": {MaxWorkers: 1}}

	if deps.Stock != nil {
		river.AddWorker(workers, &stockReconcileWorker{pool: pool, stock: deps.Stock, logger: logger})
		periodic = append(periodic, periodicJob(24*time.Hour, StockReconcile{}, "stock-reconcile", true))
	}

	if deps.Reports != nil {
		river.AddWorker(workers, &reportSliceWorker{reports: deps.Reports})
		river.AddWorker(workers, &reportExportWorker{reports: deps.Reports})
		river.AddWorker(workers, &reportNightlyWorker{pool: pool, reports: deps.Reports, logger: logger})
		river.AddWorker(workers, &reportConsistencyWorker{pool: pool, reports: deps.Reports, logger: logger})
		river.AddWorker(workers, &reportSchedulesWorker{reports: deps.Reports, logger: logger})
		periodic = append(periodic,
			periodicJob(24*time.Hour, ReportNightly{}, "report-nightly", true),
			periodicJob(7*24*time.Hour, ReportConsistency{}, "report-consistency", false),
			periodicJob(15*time.Minute, ReportSchedules{}, "report-schedules", true),
		)
		queues["reporting"] = river.QueueConfig{MaxWorkers: 4}
	}

	return river.NewClient(riverpgxv5.New(pool), &river.Config{
		Schema: "jobs", Logger: logger, Workers: workers, Queues: queues, PeriodicJobs: periodic,
	})
}

func periodicJob(every time.Duration, args river.JobArgs, id string, runOnStart bool) *river.PeriodicJob {
	return river.NewPeriodicJob(river.PeriodicInterval(every), func() (river.JobArgs, *river.InsertOpts) {
		return args, &river.InsertOpts{Queue: "maintenance", UniqueOpts: river.UniqueOpts{ByPeriod: every}}
	}, &river.PeriodicJobOpts{ID: id, RunOnStart: runOnStart})
}

type reportSliceWorker struct {
	river.WorkerDefaults[ReportSlice]
	reports Reports
}

// Work recomputes one slice. A slice that changed while it computed is snoozed
// rather than retried: nothing failed, and a snooze does not use up attempts.
func (w *reportSliceWorker) Work(ctx context.Context, job *river.Job[ReportSlice]) error {
	day, err := time.Parse(time.DateOnly, job.Args.BusinessDate)
	if err != nil {
		return river.JobCancel(fmt.Errorf("report slice date %q: %w", job.Args.BusinessDate, err))
	}
	clean, err := w.reports.RecomputeSlice(ctx, job.Args.TenantID, job.Args.OutletID, day)
	if err != nil {
		return err
	}
	if !clean {
		return river.JobSnooze(sliceSnooze)
	}
	return nil
}

type reportExportWorker struct {
	river.WorkerDefaults[ReportExport]
	reports Reports
}

func (w *reportExportWorker) Work(ctx context.Context, job *river.Job[ReportExport]) error {
	return w.reports.RunExport(ctx, job.Args.TenantID, job.Args.ExportID, job.Attempt >= job.MaxAttempts)
}

// ReportNightly re-queues every merchant's recent slices and purges old export
// files.
type ReportNightly struct{}

func (ReportNightly) Kind() string { return "report_nightly" }

type reportNightlyWorker struct {
	river.WorkerDefaults[ReportNightly]
	pool    *pgxpool.Pool
	reports Reports
	logger  *slog.Logger
}

func (w *reportNightlyWorker) Work(ctx context.Context, _ *river.Job[ReportNightly]) error {
	return RecomputeRecent(ctx, w.pool, w.reports, w.logger, time.Now())
}

// RecomputeRecent marks each active merchant's last recentDays slices dirty and
// queues them, then removes expired exports. One merchant failing does not
// stop the others.
func RecomputeRecent(ctx context.Context, pool *pgxpool.Pool, reports Reports, logger *slog.Logger, now time.Time) error {
	tenants, err := activeTenants(ctx, pool)
	if err != nil {
		return err
	}
	var errs []error
	for _, tenantID := range tenants {
		n, err := reports.MarkRecent(ctx, tenantID, recentDays, now)
		if err != nil {
			logger.Error("recent report slices could not be queued", "tenant_id", tenantID, "error", err)
			errs = append(errs, err)
			continue
		}
		logger.Info("recent report slices queued", "tenant_id", tenantID, "slices", n)
	}
	removed, err := reports.PurgeExports(ctx, now.Add(-exportRetention))
	if err != nil {
		errs = append(errs, err)
	} else if removed > 0 {
		logger.Info("expired report exports removed", "exports", removed)
	}
	return errors.Join(errs...)
}

// ReportConsistency recomputes a random sample of recent slices and compares.
type ReportConsistency struct{}

func (ReportConsistency) Kind() string { return "report_consistency" }

type reportConsistencyWorker struct {
	river.WorkerDefaults[ReportConsistency]
	pool    *pgxpool.Pool
	reports Reports
	logger  *slog.Logger
}

func (w *reportConsistencyWorker) Work(ctx context.Context, _ *river.Job[ReportConsistency]) error {
	_, _, err := CheckReportConsistency(ctx, w.pool, w.reports, w.logger, consistencySample)
	return err
}

// CheckReportConsistency samples slices with rollups from the last four weeks
// and recomputes each without keeping the result. A disagreement is logged as
// an error: a rollup can only drift when a change was never marked or a job was
// lost, and either is a bug someone has to explain. The nightly recompute is
// what repairs the recent past; this is what notices the rest.
func CheckReportConsistency(ctx context.Context, pool *pgxpool.Pool, reports Reports, logger *slog.Logger, sample int) (checked, mismatched int, err error) {
	type slice struct {
		tenantID, outletID string
		day                time.Time
	}
	var slices []slice
	err = unscoped.Tx(ctx, pool, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT r.tenant_id::text, r.outlet_id::text, r.business_date
			FROM daily_sales_rollup r
			JOIN tenants t ON t.id = r.tenant_id AND t.status = 'active'
			WHERE r.business_date >= current_date - 28
			ORDER BY random()
			LIMIT $1`, sample)
		if err != nil {
			return err
		}
		slices, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (slice, error) {
			var s slice
			return s, row.Scan(&s.tenantID, &s.outletID, &s.day)
		})
		return err
	})
	if err != nil {
		return 0, 0, err
	}

	var errs []error
	for _, s := range slices {
		tables, pending, err := reports.VerifySlice(ctx, s.tenantID, s.outletID, s.day)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if pending {
			continue
		}
		checked++
		if len(tables) > 0 {
			mismatched++
			logger.Error("report rollup disagrees with its orders",
				"tenant_id", s.tenantID, "outlet_id", s.outletID,
				"business_date", s.day.Format(time.DateOnly), "tables", tables)
		}
	}
	logger.Info("report consistency checked", "slices", checked, "mismatched", mismatched)
	return checked, mismatched, errors.Join(errs...)
}

// ReportSchedules creates the exports of every schedule that is due.
type ReportSchedules struct{}

func (ReportSchedules) Kind() string { return "report_schedules" }

type reportSchedulesWorker struct {
	river.WorkerDefaults[ReportSchedules]
	reports Reports
	logger  *slog.Logger
}

func (w *reportSchedulesWorker) Work(ctx context.Context, _ *river.Job[ReportSchedules]) error {
	n, err := w.reports.RunDueSchedules(ctx, time.Now())
	if n > 0 {
		w.logger.Info("scheduled report exports queued", "exports", n)
	}
	return err
}

func activeTenants(ctx context.Context, pool *pgxpool.Pool) ([]string, error) {
	var tenants []string
	err := unscoped.Tx(ctx, pool, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, "SELECT id::text FROM tenants WHERE status = 'active' ORDER BY id")
		if err != nil {
			return err
		}
		tenants, err = pgx.CollectRows(rows, pgx.RowTo[string])
		return err
	})
	return tenants, err
}
