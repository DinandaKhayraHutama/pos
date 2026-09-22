package jobs_test

import (
	"context"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/riverqueue/river"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/jobs"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
)

type reportsSpy struct {
	mu       sync.Mutex
	slices   int
	clean    bool
	marked   []string
	due      int
	purged   int
	verified int
	queued   []string
	mismatch []string
}

func (s *reportsSpy) RecomputeSlice(context.Context, string, string, time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.slices++
	return s.clean, nil
}

func (s *reportsSpy) RunExport(context.Context, string, string, bool) error { return nil }

func (s *reportsSpy) MarkRecent(_ context.Context, tenantID string, days int, _ time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.marked = append(s.marked, tenantID)
	return days, nil
}

func (s *reportsSpy) VerifySlice(context.Context, string, string, time.Time) ([]string, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.verified++
	return s.mismatch, false, nil
}

func (s *reportsSpy) RunDueSchedules(context.Context, time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.due++
	return 0, nil
}

func (s *reportsSpy) PurgeExports(context.Context, time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.purged++
	return 0, nil
}

func (s *reportsSpy) QueuePending(_ context.Context, tenantID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.queued = append(s.queued, tenantID)
	return nil
}

func (s *reportsSpy) snapshot() reportsSpy {
	s.mu.Lock()
	defer s.mu.Unlock()
	return reportsSpy{slices: s.slices, marked: append([]string(nil), s.marked...), due: s.due,
		purged: s.purged, verified: s.verified, queued: append([]string(nil), s.queued...)}
}

func TestTheWorkerRunsTheReportingJobs(t *testing.T) {
	db := pgtest.New(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	var tenantID, outletID string
	require.NoError(t, db.Owner.QueryRow(ctx, `INSERT INTO tenants (name, slug) VALUES ('Warung', gen_random_uuid()::text) RETURNING id::text`).Scan(&tenantID))
	require.NoError(t, db.Owner.QueryRow(ctx, `INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Kemang') RETURNING id::text`, tenantID).Scan(&outletID))

	spy := &reportsSpy{clean: false}
	client, err := jobs.NewWorker(db.Pools.Unscoped, logger, jobs.WorkerDeps{Reports: spy})
	require.NoError(t, err)
	require.NoError(t, client.Start(ctx))
	defer client.Stop(context.Background())

	// The nightly recompute, the schedule scan and the backfill sweep all run
	// at start. The sweep matters on a fresh process: a definition change lands
	// as durable dirty markers, and nothing else turns them into work.
	require.Eventually(t, func() bool {
		s := spy.snapshot()
		return len(s.marked) == 1 && s.marked[0] == tenantID && s.due >= 1 && s.purged >= 1 &&
			len(s.queued) >= 1 && s.queued[0] == tenantID
	}, 15*time.Second, 100*time.Millisecond)

	// A slice that changed while it computed is snoozed, not failed: its
	// attempt is not used up, and it comes back.
	inserted, err := client.Insert(ctx, jobs.ReportSlice{TenantID: tenantID, OutletID: outletID, BusinessDate: "2026-09-15"},
		&river.InsertOpts{Queue: "reporting"})
	require.NoError(t, err)
	require.Eventually(t, func() bool {
		var state string
		var attempt int
		err := db.Owner.QueryRow(ctx, `SELECT state, attempt FROM jobs.river_job WHERE id = $1`, inserted.Job.ID).Scan(&state, &attempt)
		return err == nil && spy.snapshot().slices == 1 && state == "scheduled" && attempt == 0
	}, 10*time.Second, 100*time.Millisecond)
}

func TestTheConsistencyCheckLogsADisagreement(t *testing.T) {
	db := pgtest.New(t)
	ctx := context.Background()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	var tenantID, outletID string
	require.NoError(t, db.Owner.QueryRow(ctx, `INSERT INTO tenants (name, slug) VALUES ('Warung', gen_random_uuid()::text) RETURNING id::text`).Scan(&tenantID))
	require.NoError(t, db.Owner.QueryRow(ctx, `INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Kemang') RETURNING id::text`, tenantID).Scan(&outletID))
	_, err := db.Owner.Exec(ctx, `
		INSERT INTO daily_sales_rollup (tenant_id, outlet_id, business_date, order_count, subtotal, discount, tax,
			service_charge, revenue, items_sold, cost_of_goods, costed_items, discounted_orders,
			cancelled_count, cancelled_amount, refunded_count, refunded_amount)
		VALUES ($1, $2, current_date, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0)`, tenantID, outletID)
	require.NoError(t, err)

	spy := &reportsSpy{mismatch: []string{"daily_sales_rollup"}}
	checked, mismatched, err := jobs.CheckReportConsistency(ctx, db.Pools.Unscoped, spy, logger, 20)
	require.NoError(t, err)
	require.Equal(t, 1, checked)
	require.Equal(t, 1, mismatched)

	require.NoError(t, jobs.RecomputeRecent(ctx, db.Pools.Unscoped, spy, logger, time.Now()))
	require.Contains(t, spy.snapshot().marked, tenantID)
}
