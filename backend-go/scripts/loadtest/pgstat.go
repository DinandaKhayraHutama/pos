package main

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Statement is one row of pg_stat_statements, which is the evidence the plan
// asks for: what the database actually did, rather than what the application
// believes it asked for.
type Statement struct {
	Query      string  `json:"query"`
	Calls      int64   `json:"calls"`
	TotalMS    float64 `json:"total_ms"`
	MeanMS     float64 `json:"mean_ms"`
	Rows       int64   `json:"rows"`
	SharedHit  int64   `json:"shared_blks_hit"`
	SharedRead int64   `json:"shared_blks_read"`
}

// RowsPerCall is how a fan-out is checked: fifteen thousand tills pulling one
// changed product should be fifteen thousand calls returning one row each.
func (s Statement) RowsPerCall() float64 {
	if s.Calls == 0 {
		return 0
	}
	return float64(s.Rows) / float64(s.Calls)
}

func resetStatements(ctx context.Context, owner *pgxpool.Pool) error {
	_, err := owner.Exec(ctx, `SELECT pg_stat_statements_reset()`)
	if err != nil {
		return fmt.Errorf("reset pg_stat_statements (is the extension installed and the credential a superuser?): %w", err)
	}
	return nil
}

func topStatements(ctx context.Context, owner *pgxpool.Pool, limit int) ([]Statement, error) {
	rows, err := owner.Query(ctx, `
		SELECT query, calls, total_exec_time, mean_exec_time, rows, shared_blks_hit, shared_blks_read
		FROM pg_stat_statements
		WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
		ORDER BY total_exec_time DESC
		LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	return collectStatements(rows)
}

// statementsLike finds the statements a scenario is making a claim about. The
// pattern is a SQL LIKE over the normalised query text.
func statementsLike(ctx context.Context, owner *pgxpool.Pool, patterns ...string) ([]Statement, error) {
	rows, err := owner.Query(ctx, `
		SELECT query, calls, total_exec_time, mean_exec_time, rows, shared_blks_hit, shared_blks_read
		FROM pg_stat_statements
		WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
		  AND query LIKE ALL ($1::text[])
		ORDER BY calls DESC`, patterns)
	if err != nil {
		return nil, err
	}
	return collectStatements(rows)
}

func collectStatements(rows pgx.Rows) ([]Statement, error) {
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (Statement, error) {
		var s Statement
		err := row.Scan(&s.Query, &s.Calls, &s.TotalMS, &s.MeanMS, &s.Rows, &s.SharedHit, &s.SharedRead)
		s.Query = strings.Join(strings.Fields(s.Query), " ")
		return s, err
	})
}

// LockWatch samples pg_locks on the tenants table for the length of a run.
//
// This is the whole reason the rewrite exists. In the Laravel original every
// pushed order took SELECT … FOR UPDATE on the tenant row, so a company's
// 5,000 outlets serialised behind one lock. The check has to be a SAMPLE
// during load rather than a grep, because the statement that takes such a lock
// can be built anywhere — a query in a template, a helper three layers down.
//
// Three kinds of lock appear here and only two of them are findings:
//
//   - AccessShareLock is a plain SELECT. Ignored; it blocks nothing.
//   - RowShareLock is what an INSERT into orders takes while PostgreSQL checks
//     its foreign key to tenants (an implicit SELECT … FOR KEY SHARE). Every
//     receipt takes one, they are all compatible with each other, and no
//     writer waits. Counted and reported, never failed — a run that demanded
//     zero of these would be demanding that orders stop referencing tenants.
//   - Anything stronger — RowExclusiveLock and up — means something is WRITING
//     the tenants table on the money path, and an UNGRANTED lock of any mode
//     means a transaction is waiting for another. Those are the signatures of
//     the defect, and both must stay at zero.
//
// A mode alone cannot separate a deliberate SELECT … FOR UPDATE from an FK
// check: both are RowShareLock. What separates them is the consequence, and
// that is what "ungranted" measures. The static half of the proof is the CI
// job (internal/architecture) that fails the build on `FROM tenants … FOR
// UPDATE` in the source.
type LockWatch struct {
	stop     chan struct{}
	done     chan struct{}
	mu       sync.Mutex
	samples  int
	worst    int
	blocking int
	waiting  int
	modes    map[string]int
}

func watchTenantLocks(ctx context.Context, owner *pgxpool.Pool, every time.Duration) *LockWatch {
	w := &LockWatch{stop: make(chan struct{}), done: make(chan struct{}), modes: map[string]int{}}

	go func() {
		defer close(w.done)
		ticker := time.NewTicker(every)
		defer ticker.Stop()
		for {
			select {
			case <-w.stop:
				return
			case <-ctx.Done():
				return
			case <-ticker.C:
			}

			rows, err := owner.Query(ctx, `
				SELECT l.mode, l.granted, count(*)
				FROM pg_locks l
				JOIN pg_class c ON c.oid = l.relation
				WHERE c.relname = 'tenants'
				  AND l.mode <> 'AccessShareLock'
				GROUP BY 1, 2`)
			if err != nil {
				continue
			}
			found, blocking, waiting := 0, 0, 0
			for rows.Next() {
				var (
					mode    string
					granted bool
					count   int
				)
				if err := rows.Scan(&mode, &granted, &count); err != nil {
					break
				}
				found += count
				label := mode
				if !granted {
					label += " (waiting)"
					waiting += count
				}
				if blocksAWriter(mode) {
					blocking += count
				}
				w.mu.Lock()
				w.modes[label] += count
				w.mu.Unlock()
			}
			rows.Close()

			w.mu.Lock()
			w.samples++
			if found > w.worst {
				w.worst = found
			}
			if blocking > w.blocking {
				w.blocking = blocking
			}
			if waiting > w.waiting {
				w.waiting = waiting
			}
			w.mu.Unlock()
		}
	}()

	return w
}

// blocksAWriter is true for the modes that mean the tenants TABLE is being
// written, rather than merely referenced by a foreign key check.
func blocksAWriter(mode string) bool {
	switch mode {
	case "RowExclusiveLock", "ShareLock", "ShareRowExclusiveLock", "ExclusiveLock", "AccessExclusiveLock":
		return true
	default:
		return false
	}
}

// LockReport is what the run says about the tenant row.
type LockReport struct {
	Samples int `json:"samples"`
	// Worst is the largest number of non-AccessShare locks seen in one sample,
	// foreign key checks included. Informational.
	Worst int `json:"worst_sample"`
	// Blocking is the largest number of locks seen that mean something is
	// writing the tenants table. Must be zero.
	Blocking int `json:"blocking"`
	// Waiting is the largest number of UNGRANTED locks seen: one transaction
	// queued behind another on the tenant row. This is the defect's signature,
	// and it must be zero.
	Waiting int            `json:"waiting"`
	Modes   map[string]int `json:"modes"`
}

// Close stops sampling and reports what was seen.
func (w *LockWatch) Close() LockReport {
	close(w.stop)
	<-w.done
	w.mu.Lock()
	defer w.mu.Unlock()
	copied := map[string]int{}
	for mode, count := range w.modes {
		copied[mode] = count
	}
	return LockReport{
		Samples: w.samples, Worst: w.worst,
		Blocking: w.blocking, Waiting: w.waiting, Modes: copied,
	}
}

// TableStat answers "is autovacuum keeping up" — the question the data-scale
// scenario exists to ask. A partition whose dead tuples grow without a
// last_autovacuum behind them is a table whose plans are about to change.
type TableStat struct {
	Relation        string     `json:"relation"`
	LiveTuples      int64      `json:"live_tuples"`
	DeadTuples      int64      `json:"dead_tuples"`
	LastAutovacuum  *time.Time `json:"last_autovacuum,omitempty"`
	LastAutoanalyze *time.Time `json:"last_autoanalyze,omitempty"`
	AutovacuumRuns  int64      `json:"autovacuum_count"`
	TotalBytes      int64      `json:"total_bytes"`
}

// DeadRatio is dead tuples as a share of live ones. Above roughly 0.2 with no
// recent autovacuum, the table is falling behind.
func (t TableStat) DeadRatio() float64 {
	if t.LiveTuples == 0 {
		return 0
	}
	return float64(t.DeadTuples) / float64(t.LiveTuples)
}

func tableStats(ctx context.Context, owner *pgxpool.Pool, like string) ([]TableStat, error) {
	rows, err := owner.Query(ctx, `
		SELECT relname, n_live_tup, n_dead_tup, last_autovacuum, last_autoanalyze, autovacuum_count,
		       pg_total_relation_size(relid)
		FROM pg_stat_user_tables
		WHERE relname LIKE $1
		ORDER BY n_live_tup DESC
		LIMIT 40`, like)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (TableStat, error) {
		var t TableStat
		err := row.Scan(&t.Relation, &t.LiveTuples, &t.DeadTuples, &t.LastAutovacuum, &t.LastAutoanalyze,
			&t.AutovacuumRuns, &t.TotalBytes)
		return t, err
	})
}

// snapshotStatements records what the database had been doing BEFORE a run and
// then clears the counters, so the "after" picture is the run's own work.
//
// The plan asks for the top twenty before and after, and the "before" half is
// not ceremony: it is what tells you the box was quiet, which is the one thing
// that makes the "after" numbers mean anything.
func (r *Result) snapshotStatements(ctx context.Context, owner *pgxpool.Pool) error {
	r.TopBefore, _ = topStatements(ctx, owner, 20)
	return resetStatements(ctx, owner)
}
