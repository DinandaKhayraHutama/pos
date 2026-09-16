package reporting

import (
	"context"
	"errors"
	"net/mail"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/jobs"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
)

const (
	FrequencyDaily   = "daily"
	FrequencyWeekly  = "weekly"
	FrequencyMonthly = "monthly"

	// deliveryHour is when a scheduled report is mailed, on the merchant's
	// clock: after the night's recompute, before the shop opens.
	deliveryHour = 6

	maxRecipients = 10
)

// Frequencies is every schedule frequency, in the order the page offers them.
var Frequencies = []string{FrequencyDaily, FrequencyWeekly, FrequencyMonthly}

type Schedule struct {
	ID         string
	Frequency  string
	Format     string
	OutletID   string
	OutletName string
	Recipients []string
	Active     bool
	NextRunAt  time.Time
	LastRunAt  *time.Time
}

type ScheduleInput struct {
	Frequency  string
	Format     string
	OutletID   string
	Recipients string
}

// NextRun is the first delivery strictly after `after`: 06:00 on the
// merchant's clock every day, every Monday, or on the 1st of each month.
func NextRun(frequency string, loc *time.Location, after time.Time) time.Time {
	local := after.In(loc)
	y, m, d := local.Date()
	switch frequency {
	case FrequencyWeekly:
		next := time.Date(y, m, d, deliveryHour, 0, 0, 0, loc)
		next = next.AddDate(0, 0, (int(time.Monday)-int(next.Weekday())+7)%7)
		if !next.After(after) {
			next = next.AddDate(0, 0, 7)
		}
		return next
	case FrequencyMonthly:
		next := time.Date(y, m, 1, deliveryHour, 0, 0, 0, loc)
		if !next.After(after) {
			next = next.AddDate(0, 1, 0)
		}
		return next
	}
	next := time.Date(y, m, d, deliveryHour, 0, 0, 0, loc)
	if !next.After(after) {
		next = next.AddDate(0, 0, 1)
	}
	return next
}

// Period is the range a delivery at runAt reports on: yesterday, last Monday to
// Sunday, or last calendar month, on the merchant's clock.
func Period(frequency string, loc *time.Location, runAt time.Time) (from, to time.Time) {
	day := Date(runAt, loc)
	switch frequency {
	case FrequencyWeekly:
		monday := day.AddDate(0, 0, -((int(day.Weekday()) + 6) % 7))
		return monday.AddDate(0, 0, -7), monday.AddDate(0, 0, -1)
	case FrequencyMonthly:
		first := time.Date(day.Year(), day.Month(), 1, 0, 0, 0, 0, time.UTC)
		return first.AddDate(0, -1, 0), first.AddDate(0, 0, -1)
	}
	yesterday := day.AddDate(0, 0, -1)
	return yesterday, yesterday
}

func validFrequency(f string) bool {
	for _, v := range Frequencies {
		if v == f {
			return true
		}
	}
	return false
}

// parseRecipients reads addresses separated by commas, semicolons or lines.
func parseRecipients(raw string) ([]string, string) {
	fields := strings.FieldsFunc(raw, func(r rune) bool { return r == ',' || r == ';' || r == '\n' || r == '\r' })
	seen := map[string]bool{}
	var out []string
	for _, f := range fields {
		f = strings.TrimSpace(f)
		if f == "" {
			continue
		}
		addr, err := mail.ParseAddress(f)
		if err != nil {
			return nil, "\"" + f + "\" bukan alamat email."
		}
		key := strings.ToLower(addr.Address)
		if !seen[key] {
			seen[key] = true
			out = append(out, addr.Address)
		}
	}
	if len(out) == 0 {
		return nil, "Isi minimal satu alamat email."
	}
	if len(out) > maxRecipients {
		return nil, "Maksimal 10 penerima."
	}
	return out, ""
}

func (s *Service) Schedules(ctx context.Context, tenantID string) ([]Schedule, error) {
	var out []Schedule
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		out, err = collect(ctx, tx, `
			SELECT rs.id::text, rs.frequency, rs.format, COALESCE(rs.outlet_id::text, ''), COALESCE(o.name, ''),
			       rs.recipients, rs.active, rs.next_run_at, rs.last_run_at
			FROM report_schedules rs
			LEFT JOIN outlets o ON o.tenant_id = rs.tenant_id AND o.id = rs.outlet_id
			WHERE rs.tenant_id = $1
			ORDER BY rs.created_at, rs.id`, []any{tenantID}, func(row pgx.CollectableRow) (Schedule, error) {
			var sc Schedule
			return sc, row.Scan(&sc.ID, &sc.Frequency, &sc.Format, &sc.OutletID, &sc.OutletName,
				&sc.Recipients, &sc.Active, &sc.NextRunAt, &sc.LastRunAt)
		})
		return err
	})
	return out, err
}

func (s *Service) CreateSchedule(ctx context.Context, tenantID, employeeID string, in ScheduleInput) (string, error) {
	errs := validation.Errors{}
	if !validFrequency(in.Frequency) {
		errs.Add("frequency", "Pilih frekuensi.")
	}
	if !validFormat(in.Format) {
		errs.Add("format", "Pilih format.")
	}
	recipients, problem := parseRecipients(in.Recipients)
	if problem != "" {
		errs.Add("recipients", problem)
	}
	if in.OutletID != "" && !validation.UUID(in.OutletID) {
		errs.Add("outlet", "Outlet tidak dikenal.")
	}
	if err := errs.Err(); err != nil {
		return "", err
	}

	loc, err := s.Location(ctx, tenantID)
	if err != nil {
		return "", err
	}
	var createdBy *string
	if validation.UUID(employeeID) {
		createdBy = &employeeID
	}

	var id string
	err = pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		if err := liveOutlet(ctx, tx, tenantID, in.OutletID); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `
			INSERT INTO report_schedules (tenant_id, created_by, frequency, format, outlet_id, recipients, next_run_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7)
			RETURNING id::text`,
			tenantID, createdBy, in.Frequency, in.Format, outletArg(in.OutletID), recipients,
			NextRun(in.Frequency, loc, time.Now())).Scan(&id)
	})
	return id, err
}

// SetScheduleActive pauses or resumes a schedule. Resuming starts from the next
// delivery after now, so a schedule paused for a month does not fire a stale
// run the moment it comes back.
func (s *Service) SetScheduleActive(ctx context.Context, tenantID, id string, active bool) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}
	loc, err := s.Location(ctx, tenantID)
	if err != nil {
		return err
	}
	return pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var frequency string
		err := tx.QueryRow(ctx, `
			SELECT frequency FROM report_schedules WHERE tenant_id = $1 AND id = $2 FOR UPDATE`,
			tenantID, id).Scan(&frequency)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `
			UPDATE report_schedules SET active = $3, next_run_at = CASE WHEN $3 THEN $4 ELSE next_run_at END,
			       updated_at = now()
			WHERE tenant_id = $1 AND id = $2`, tenantID, id, active, NextRun(frequency, loc, time.Now()))
		return err
	})
}

func (s *Service) DeleteSchedule(ctx context.Context, tenantID, id string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}
	return pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM report_schedules WHERE tenant_id = $1 AND id = $2`, tenantID, id)
		if err == nil && tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return err
	})
}

// RunDueSchedules creates and enqueues the export of every schedule due at
// `now`, and moves each schedule to its next delivery. Finding the due
// schedules is the one cross-merchant read; each run happens in its merchant's
// transaction, and a unique index stops a retried scan from mailing a period
// twice. A schedule that missed several deliveries (the worker was down)
// sends the period it was due for, then resumes from now.
func (s *Service) RunDueSchedules(ctx context.Context, now time.Time) (int, error) {
	type due struct{ tenantID, id string }
	var dues []due
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT rs.tenant_id::text, rs.id::text
			FROM report_schedules rs
			JOIN tenants t ON t.id = rs.tenant_id AND t.status = 'active'
			WHERE rs.active AND rs.next_run_at <= $1
			  -- A merchant whose exports were switched off by the platform is
			  -- not mailed. Its schedules stay due and resume if the module
			  -- comes back, rather than being silently moved on.
			  AND NOT EXISTS (SELECT 1 FROM tenant_feature_flags f
			                  WHERE f.tenant_id = rs.tenant_id AND f.flag = 'report_exports' AND NOT f.enabled)
			ORDER BY rs.next_run_at
			LIMIT 500`, now)
		if err != nil {
			return err
		}
		dues, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (due, error) {
			var d due
			return d, row.Scan(&d.tenantID, &d.id)
		})
		return err
	})
	if err != nil {
		return 0, err
	}

	created := 0
	var errs []error
	for _, d := range dues {
		ok, err := s.runSchedule(ctx, d.tenantID, d.id, now)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if ok {
			created++
		}
	}
	return created, errors.Join(errs...)
}

func (s *Service) runSchedule(ctx context.Context, tenantID, scheduleID string, now time.Time) (bool, error) {
	loc, err := s.Location(ctx, tenantID)
	if err != nil {
		return false, err
	}
	created := false
	err = pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var frequency, format string
		var outletID *string
		var dueAt time.Time
		err := tx.QueryRow(ctx, `
			SELECT frequency, format, outlet_id::text, next_run_at
			FROM report_schedules
			WHERE tenant_id = $1 AND id = $2 AND active AND next_run_at <= $3
			FOR UPDATE SKIP LOCKED`, tenantID, scheduleID, now).Scan(&frequency, &format, &outletID, &dueAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}

		from, to := Period(frequency, loc, dueAt)
		var exportID string
		err = tx.QueryRow(ctx, `
			INSERT INTO report_exports (tenant_id, schedule_id, format, outlet_id, date_from, date_to)
			VALUES ($1, $2, $3, $4, $5::date, $6::date)
			ON CONFLICT (schedule_id, date_from, date_to) WHERE schedule_id IS NOT NULL DO NOTHING
			RETURNING id::text`,
			tenantID, scheduleID, format, outletID, from.Format(time.DateOnly), to.Format(time.DateOnly)).Scan(&exportID)
		switch {
		case err == nil:
			created = true
			if err := jobs.EnqueueExport(ctx, tx, s.queue, jobs.ReportExport{TenantID: tenantID, ExportID: exportID}); err != nil {
				return err
			}
		case !errors.Is(err, pgx.ErrNoRows):
			return err
		}

		_, err = tx.Exec(ctx, `
			UPDATE report_schedules SET next_run_at = $3, last_run_at = $4, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`, tenantID, scheduleID, NextRun(frequency, loc, now), now)
		return err
	})
	return created, err
}
