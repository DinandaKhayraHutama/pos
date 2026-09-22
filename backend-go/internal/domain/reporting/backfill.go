package reporting

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/jobs"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// BackfillBatch is how many slices one sweep enqueues per merchant. A
// migration that marks three years of history dirty must not become one job
// insert per slice in a single transaction: the batch is the rate limit, the
// durable markers are the progress, and the sweep runs again a minute later.
const BackfillBatch = 100

// QueuePending enqueues the oldest-marked slices that are still dirty.
//
// It is the recompute side of a definition change — the migration marks every
// affected slice, this drains them — and it is restartable BY CONSTRUCTION:
// nothing is remembered outside report_dirty_slices, a job only clears a
// marker after its rollups commit, and the job key is unique per slice, so a
// sweep that overlaps a previous one enqueues nothing new. Killing the worker
// mid-backfill costs the slices in flight, which the next sweep picks up.
//
// There is deliberately NO active-outlet predicate. A branch that has been
// switched off still has years of sales behind it, and leaving its slices at
// the old calculation version would make every whole-chain report permanently
// incomplete.
func (s *Service) QueuePending(ctx context.Context, tenantID string) error {
	return pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		// Newest business date first within a marking: an owner looks at this
		// week long before they look at a Tuesday two years ago, and a backfill
		// that starts at the beginning of time leaves the report they actually
		// opened incomplete the longest.
		rows, err := tx.Query(ctx, `
			SELECT outlet_id::text, business_date
			FROM report_dirty_slices
			WHERE tenant_id = $1
			ORDER BY changed_at, business_date DESC, outlet_id
			LIMIT $2`, tenantID, BackfillBatch)
		if err != nil {
			return err
		}
		pending, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (jobs.ReportSlice, error) {
			slice := jobs.ReportSlice{TenantID: tenantID}
			var day time.Time
			err := row.Scan(&slice.OutletID, &day)
			slice.BusinessDate = day.Format(time.DateOnly)
			return slice, err
		})
		if err != nil {
			return err
		}
		now := time.Now()
		for _, slice := range pending {
			if err := jobs.EnqueueReportAt(ctx, tx, s.queue, slice, now); err != nil {
				return err
			}
		}
		return nil
	})
}

// PendingSlices counts what the backfill still owes a merchant. The ops page
// and the verification script read it to say whether a definition change has
// finished landing.
func (s *Service) PendingSlices(ctx context.Context, tenantID string) (int64, error) {
	var n int64
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx,
			`SELECT count(*) FROM report_dirty_slices WHERE tenant_id = $1`, tenantID).Scan(&n)
	})
	return n, err
}
