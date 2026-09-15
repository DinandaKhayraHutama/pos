package reporting

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/riverqueue/river"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/jobs"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// MaxRecomputeDays bounds one "hitung ulang" request.
const MaxRecomputeDays = 92

// RequestRecompute marks every slice in the filter dirty and enqueues its job
// to run now. It is what the report's "hitung ulang" button does: the raw order
// tables are read by the jobs, never by the page. Returns how many slices were
// marked.
func (s *Service) RequestRecompute(ctx context.Context, tenantID string, f Filter) (int, error) {
	if err := f.Validate(MaxRecomputeDays); err != nil {
		return 0, err
	}
	var n int
	err := pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		n, err = markSlices(ctx, tx, s.queue, tenantID, f.OutletID, f.From, f.To, time.Now())
		return err
	})
	return n, err
}

// MarkRecent is the nightly self-heal: every outlet's last `days` business
// dates on the merchant's clock are marked dirty and recomputed. It catches an
// offline till's late push and any enqueue that was lost.
func (s *Service) MarkRecent(ctx context.Context, tenantID string, days int, now time.Time) (int, error) {
	loc, err := s.Location(ctx, tenantID)
	if err != nil {
		return 0, err
	}
	to := Date(now, loc)
	from := to.AddDate(0, 0, -(days - 1))
	var n int
	err = pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		n, err = markSlices(ctx, tx, s.queue, tenantID, "", from, to, now)
		return err
	})
	return n, err
}

func markSlices(ctx context.Context, tx pgx.Tx, queue *river.Client[pgx.Tx], tenantID, outletID string, from, to, runAt time.Time) (int, error) {
	rows, err := tx.Query(ctx, `
		INSERT INTO report_dirty_slices (tenant_id, outlet_id, business_date)
		SELECT $1, o.id, d::date
		FROM outlets o
		CROSS JOIN generate_series($2::date, $3::date, interval '1 day') AS d
		WHERE o.tenant_id = $1 AND o.deleted_at IS NULL AND ($4::uuid IS NULL OR o.id = $4::uuid)
		ON CONFLICT (tenant_id, outlet_id, business_date) DO UPDATE
		SET generation = report_dirty_slices.generation + 1, changed_at = now()
		RETURNING outlet_id::text, business_date`,
		tenantID, from.Format(time.DateOnly), to.Format(time.DateOnly), outletArg(outletID))
	if err != nil {
		return 0, err
	}
	slices, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (jobs.ReportSlice, error) {
		var outlet string
		var day time.Time
		err := row.Scan(&outlet, &day)
		return jobs.ReportSlice{TenantID: tenantID, OutletID: outlet, BusinessDate: day.Format(time.DateOnly)}, err
	})
	if err != nil {
		return 0, err
	}
	if len(slices) == 0 && outletID != "" {
		return 0, ErrNotFound
	}
	for _, slice := range slices {
		if err := jobs.EnqueueReportAt(ctx, tx, queue, slice, runAt); err != nil {
			return 0, err
		}
	}
	return len(slices), nil
}
