package jobs_test

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/jobs"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
	"github.com/jackc/pgx/v5"
	"github.com/stretchr/testify/require"
)

func TestMaintenanceIsIdempotentAndRestricted(t *testing.T) {
	db := pgtest.New(t)
	ctx := context.Background()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	require.NoError(t, jobs.Maintain(ctx, db.Pools.Unscoped, logger))
	require.NoError(t, jobs.Maintain(ctx, db.Pools.Unscoped, logger))
	_, err := db.Pools.Tenant.Exec(ctx, "SELECT app.ensure_ingest_partitions()")
	require.Error(t, err, "device credential cannot run partition DDL")
	_, err = db.Pools.Tenant.Exec(ctx, "SELECT app.prune_ingest_log()")
	require.Error(t, err, "device credential cannot prune audit")
	var n int
	require.NoError(t, db.Owner.QueryRow(ctx, "SELECT count(*) FROM pg_inherits WHERE inhparent='orders'::regclass").Scan(&n))
	require.Equal(t, 5, n, "current month +3 future + default")
}

func TestRiverActuallyRunsTheMaintenanceJob(t *testing.T) {
	db := pgtest.New(t)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	client, err := jobs.NewMaintenanceWorker(db.Pools.Unscoped, logger, nil)
	require.NoError(t, err)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	require.NoError(t, client.Start(ctx))
	defer client.Stop(context.Background())
	require.Eventually(t, func() bool {
		var n int
		err := db.Owner.QueryRow(ctx, "SELECT count(*) FROM jobs.river_job WHERE kind='ingest_maintenance' AND state='completed'").Scan(&n)
		return err == nil && n > 0
	}, 10*time.Second, 100*time.Millisecond)
}

func TestRetentionDropsOnlyExpiredAuditChildren(t *testing.T) {
	db := pgtest.New(t)
	ctx := context.Background()
	today := time.Now().UTC()
	names := make([]string, 2)
	for i, age := range []int{91, 90} {
		day := today.AddDate(0, 0, -age)
		names[i] = "ingest_log_" + day.Format("20060102")
		_, err := db.Owner.Exec(ctx, fmt.Sprintf("CREATE TABLE %s PARTITION OF ingest_log FOR VALUES FROM ('%s') TO ('%s')", pgx.Identifier{names[i]}.Sanitize(), day.Format(time.DateOnly), day.AddDate(0, 0, 1).Format(time.DateOnly)))
		require.NoError(t, err)
	}
	// A similarly-named table outside this exact partition tree is untouched.
	_, err := db.Owner.Exec(ctx, "CREATE TABLE ingest_log_19981231 (id integer)")
	require.NoError(t, err)
	require.NoError(t, jobs.Maintain(ctx, db.Pools.Unscoped, slog.New(slog.NewTextHandler(io.Discard, nil))))
	for _, tc := range []struct {
		name   string
		exists bool
	}{{names[0], false}, {names[1], true}, {"ingest_log_19981231", true}, {"orders", true}, {"order_dedupe", true}} {
		var exists bool
		require.NoError(t, db.Owner.QueryRow(ctx, "SELECT to_regclass($1) IS NOT NULL", tc.name).Scan(&exists))
		require.Equal(t, tc.exists, exists, tc.name)
	}
}

type reconcilerSpy struct {
	mu      sync.Mutex
	tenants []string
}

func (r *reconcilerSpy) Reconcile(_ context.Context, tenantID string) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.tenants = append(r.tenants, tenantID)
	return 0, nil
}

// The nightly stock self-heal visits every active merchant and no suspended
// one, through the reconciler's own tenant-scoped work.
func TestStockReconcileVisitsEveryActiveMerchant(t *testing.T) {
	db := pgtest.New(t)
	ctx := context.Background()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	var active, suspended string
	require.NoError(t, db.Owner.QueryRow(ctx, "INSERT INTO tenants (name, slug) VALUES ('a', gen_random_uuid()::text) RETURNING id::text").Scan(&active))
	require.NoError(t, db.Owner.QueryRow(ctx, "INSERT INTO tenants (name, slug, status) VALUES ('s', gen_random_uuid()::text, 'suspended') RETURNING id::text").Scan(&suspended))

	spy := &reconcilerSpy{}
	require.NoError(t, jobs.ReconcileStock(ctx, db.Pools.Unscoped, spy, logger))
	require.Contains(t, spy.tenants, active)
	require.NotContains(t, spy.tenants, suspended)
}
