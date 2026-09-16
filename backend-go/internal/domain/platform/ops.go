package platform

import (
	"context"
	"io/fs"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/jobs"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
	"github.com/daniryckidinata/nti_pos/backend-go/migrations"
)

// OpsReport is what an operator checks first when something feels wrong: is
// the database reachable, did the last deploy's migrations run, is the job
// queue draining, are reports keeping up, has anything landed where it should
// not. Read-only, and every figure comes from a table that already holds it.
type OpsReport struct {
	CheckedAt  time.Time
	Database   string
	Redis      string
	Migrations MigrationStatus
	Jobs       []JobCount
	Discarded  []DiscardedJob
	// Report slices waiting to be recomputed, and how long the oldest has
	// waited. A growing age means the reporting queue is not keeping up.
	DirtySlices      int64
	OldestDirtySlice *time.Time
	// Default partitions with rows in them: orders whose business date has no
	// monthly partition. Always empty in a healthy system.
	OccupiedDefaultPartitions []string
}

type MigrationStatus struct {
	Latest  int64
	Applied int
	// Pending migrations are embedded in this binary but not applied: the
	// deploy skipped `justclick migrate up`.
	Pending []int64
	// Unknown migrations are applied but not in this binary: an older binary
	// is serving a newer schema, which expand/contract allows but is worth
	// seeing during a rollback.
	Unknown []int64
}

type JobCount struct {
	State string
	Queue string
	Count int64
}

type DiscardedJob struct {
	ID          int64
	Kind        string
	Queue       string
	Attempt     int
	FinalizedAt *time.Time
	Error       string
}

// Ops gathers the report. A failure in one section is reported in that section
// rather than failing the page: the ops page is most needed when things are
// partly broken.
func (s *Service) Ops(ctx context.Context) OpsReport {
	r := OpsReport{CheckedAt: s.now(), Database: "ok", Redis: "tidak dikonfigurasi"}

	pingCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if err := s.pools.Unscoped.Ping(pingCtx); err != nil {
		r.Database = "tidak terjangkau: " + err.Error()
		return r
	}
	if s.rdb != nil {
		r.Redis = "ok"
		if err := s.rdb.Ping(pingCtx).Err(); err != nil {
			r.Redis = "tidak terjangkau"
		}
	}

	embedded := embeddedMigrations()
	err := unscoped.Tx(ctx, s.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx,
			`SELECT DISTINCT version_id FROM goose_db_version WHERE is_applied AND version_id > 0 ORDER BY 1`)
		if err != nil {
			return err
		}
		applied, err := pgx.CollectRows(rows, pgx.RowTo[int64])
		if err != nil {
			return err
		}
		r.Migrations = compareMigrations(embedded, applied)

		rows, err = tx.Query(ctx, `
			SELECT state::text, queue, count(*) FROM jobs.river_job GROUP BY 1, 2 ORDER BY 1, 2`)
		if err != nil {
			return err
		}
		if r.Jobs, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (JobCount, error) {
			var j JobCount
			return j, row.Scan(&j.State, &j.Queue, &j.Count)
		}); err != nil {
			return err
		}

		rows, err = tx.Query(ctx, `
			SELECT id, kind, queue, attempt, finalized_at,
			       COALESCE(errors[array_length(errors, 1)]->>'error', '')
			FROM jobs.river_job WHERE state = 'discarded'
			ORDER BY finalized_at DESC NULLS LAST LIMIT 20`)
		if err != nil {
			return err
		}
		if r.Discarded, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (DiscardedJob, error) {
			var (
				j       DiscardedJob
				attempt int16
			)
			err := row.Scan(&j.ID, &j.Kind, &j.Queue, &attempt, &j.FinalizedAt, &j.Error)
			j.Attempt = int(attempt)
			if len(j.Error) > 300 {
				j.Error = j.Error[:300] + "…"
			}
			return j, err
		}); err != nil {
			return err
		}

		if err := tx.QueryRow(ctx,
			`SELECT count(*), min(changed_at) FROM report_dirty_slices`).Scan(&r.DirtySlices, &r.OldestDirtySlice); err != nil {
			return err
		}

		for _, table := range jobs.DefaultPartitions {
			var occupied bool
			if err := tx.QueryRow(ctx,
				"SELECT EXISTS (SELECT 1 FROM "+pgx.Identifier{table}.Sanitize()+" LIMIT 1)").Scan(&occupied); err != nil {
				return err
			}
			if occupied {
				r.OccupiedDefaultPartitions = append(r.OccupiedDefaultPartitions, table)
			}
		}
		return nil
	})
	if err != nil {
		s.logger.Error("platform ops report", "error", err)
		r.Database = "sebagian gagal dibaca: " + err.Error()
	}
	return r
}

// embeddedMigrations are the versions this binary would apply: every SQL file's
// numeric prefix, plus the Go steps (River's schema).
func embeddedMigrations() []int64 {
	var out []int64
	names, _ := fs.Glob(migrations.FS, "*.sql")
	for _, name := range names {
		prefix, _, ok := strings.Cut(name, "_")
		if !ok {
			continue
		}
		if v, err := strconv.ParseInt(prefix, 10, 64); err == nil {
			out = append(out, v)
		}
	}
	for _, m := range migrations.GoMigrations() {
		out = append(out, m.Version)
	}
	slices.Sort(out)
	return out
}

func compareMigrations(embedded, applied []int64) MigrationStatus {
	st := MigrationStatus{Applied: len(applied)}
	for _, v := range embedded {
		if !slices.Contains(applied, v) {
			st.Pending = append(st.Pending, v)
		}
	}
	for _, v := range applied {
		if !slices.Contains(embedded, v) {
			st.Unknown = append(st.Unknown, v)
		}
		st.Latest = max(st.Latest, v)
	}
	return st
}
