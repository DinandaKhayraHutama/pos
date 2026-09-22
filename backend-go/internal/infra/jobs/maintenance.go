package jobs

import (
	"context"
	"log/slog"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/riverqueue/river"
)

type Maintenance struct{}

func (Maintenance) Kind() string { return "ingest_maintenance" }

type maintenanceWorker struct {
	river.WorkerDefaults[Maintenance]
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func (w *maintenanceWorker) Work(ctx context.Context, _ *river.Job[Maintenance]) error {
	return Maintain(ctx, w.pool, w.logger)
}

// DefaultPartitions catch rows whose date has no partition of its own. Anything
// in one is a sale or an audit row filed where no report or retention job looks,
// so it needs an operator. The platform ops page checks the same list.
var DefaultPartitions = []string{"orders_default", "order_items_default", "order_item_modifiers_default", "ingest_log_default"}

// Maintain uses a credential without DDL ownership. Only the two constrained
// SECURITY DEFINER maintenance functions grant it partition DDL authority.
func Maintain(ctx context.Context, pool *pgxpool.Pool, logger *slog.Logger) error {
	return unscoped.Tx(ctx, pool, func(ctx context.Context, tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SET LOCAL lock_timeout = '2s'"); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, "SET LOCAL statement_timeout = '30s'"); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, "SELECT app.ensure_ingest_partitions()"); err != nil {
			return err
		}
		var removed int
		if err := tx.QueryRow(ctx, "SELECT app.prune_ingest_log()").Scan(&removed); err != nil {
			return err
		}
		if removed > 0 {
			logger.Info("expired ingest audit partitions removed", "partitions", removed, "retention_days", 90)
		}

		// Every cashier sign-in at a till writes a row here, and nothing else
		// ever deletes one: a busy outlet mints a few a day per device and
		// they would accumulate for the life of the deployment. An expired
		// token already authenticates nobody, so the row is only weight.
		tag, err := tx.Exec(ctx, "DELETE FROM till_access WHERE expires_at < now()")
		if err != nil {
			return err
		}
		if n := tag.RowsAffected(); n > 0 {
			logger.Info("expired till sign-ins removed", "rows", n)
		}
		for _, table := range DefaultPartitions {
			var occupied bool
			if err := tx.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM "+pgx.Identifier{table}.Sanitize()+" LIMIT 1)").Scan(&occupied); err != nil {
				return err
			}
			if occupied {
				logger.Error("default partition requires operator attention", "table", table)
			}
		}
		return nil
	})
}

// StockReconciler re-derives one merchant's stock projection from its ledger.
type StockReconciler interface {
	Reconcile(ctx context.Context, tenantID string) (int, error)
}

// StockReconcile is the nightly self-heal for stock projections.
type StockReconcile struct{}

func (StockReconcile) Kind() string { return "stock_reconcile" }

type stockReconcileWorker struct {
	river.WorkerDefaults[StockReconcile]
	pool   *pgxpool.Pool
	stock  StockReconciler
	logger *slog.Logger
}

func (w *stockReconcileWorker) Work(ctx context.Context, _ *river.Job[StockReconcile]) error {
	return ReconcileStock(ctx, w.pool, w.stock, w.logger)
}

// ReconcileStock runs the reconcile for every active merchant. Listing the
// merchants is the only cross-tenant read, and it uses the unscoped credential
// this package already holds; each merchant's repair runs through the
// reconciler's own tenant-scoped transactions.
//
// A repaired row is logged as an error: the projection moves in its movement's
// transaction, so drift means a bug or a manual change someone must explain.
func ReconcileStock(ctx context.Context, pool *pgxpool.Pool, reconciler StockReconciler, logger *slog.Logger) error {
	var tenants []string
	if err := unscoped.Tx(ctx, pool, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, "SELECT id::text FROM tenants WHERE status = 'active' ORDER BY id")
		if err != nil {
			return err
		}
		tenants, err = pgx.CollectRows(rows, pgx.RowTo[string])
		return err
	}); err != nil {
		return err
	}

	for _, tenantID := range tenants {
		repaired, err := reconciler.Reconcile(ctx, tenantID)
		if err != nil {
			return err
		}
		if repaired > 0 {
			logger.Error("stock projection disagreed with its ledger and was repaired",
				"tenant_id", tenantID, "rows", repaired)
		}
	}
	return nil
}

// NewMaintenanceWorker runs partition/retention maintenance hourly and, when a
// reconciler is given, the stock reconcile daily. Both run once at start.
func NewMaintenanceWorker(pool *pgxpool.Pool, logger *slog.Logger, stock StockReconciler) (*river.Client[pgx.Tx], error) {
	return NewWorker(pool, logger, WorkerDeps{Stock: stock})
}
