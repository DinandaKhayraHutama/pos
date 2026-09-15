package syncfeed

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// Writer hands out sequence numbers inside one transaction.
//
// Two rules, and both have teeth:
//
//   - **One number per row.** Sharing a number between rows lets a page
//     boundary fall in the middle of a tie: the client asks for
//     `sync_seq > 42`, and every row still sitting at 42 is never delivered.
//     Distinct numbers are what make the cursor a cursor.
//   - **Touch entities in registry order.** Two transactions taking the same
//     counters in opposite orders can deadlock. Writing dependencies before
//     dependents — categories before products — already produces that order, so
//     ordinary code gets it for free. PostgreSQL's deadlock detector is the
//     backstop, and it aborts a transaction rather than losing a row.
type Writer struct {
	// Tx is the caller's transaction. The row write must go through it, or the
	// counter's lock is released before the row it numbers commits.
	Tx pgx.Tx

	tenantID string
	marks    map[string]int64
}

// Seq takes the next sequence number for one row of a company feed.
func (w *Writer) Seq(ctx context.Context, entity string) (int64, error) {
	return w.SeqBlock(ctx, entity, 1)
}

// SeqBlock reserves n consecutive numbers of a company feed for a bulk write
// and returns the first, so a cascading tombstone can number every row it
// retires without one round trip per row.
//
// An outlet feed is refused: its counter is per branch, and numbering it on
// the merchant's counter would publish rows no till ever pages to.
func (w *Writer) SeqBlock(ctx context.Context, entity string, n int64) (int64, error) {
	e, ok := Lookup(entity)
	if !ok {
		return 0, fmt.Errorf("%w: %s", ErrUnknownEntity, entity)
	}
	if e.Scope == ScopeOutlet {
		return 0, fmt.Errorf("%w: %s", ErrOutletRequired, entity)
	}

	return w.block(ctx, scopeKeyFor(e, w.tenantID, ""), n)
}

// OutletSeqBlock reserves n consecutive numbers of an outlet feed at one branch.
func (w *Writer) OutletSeqBlock(ctx context.Context, entity, outletID string, n int64) (int64, error) {
	e, ok := Lookup(entity)
	if !ok {
		return 0, fmt.Errorf("%w: %s", ErrUnknownEntity, entity)
	}
	if e.Scope != ScopeOutlet || outletID == "" {
		return 0, fmt.Errorf("%w: %s at outlet %q", ErrOutletRequired, entity, outletID)
	}

	return w.block(ctx, scopeKeyFor(e, w.tenantID, outletID), n)
}

func (w *Writer) block(ctx context.Context, scope string, n int64) (int64, error) {
	first, err := AllocSeqBlock(ctx, w.Tx, w.tenantID, scope, n)
	if err != nil {
		return 0, err
	}

	if last := first + n - 1; last > w.marks[scope] {
		w.marks[scope] = last
	}

	return first, nil
}

// Write is the one correct way to publish server-owned rows.
//
// It exists so the ordering below lives in a single place rather than being
// re-derived by every screen that edits the menu. Both halves are load-bearing:
//
//   - Sequence numbers are allocated INSIDE the caller's transaction, so each
//     counter's lock is still held when the row it numbers commits. See
//     AllocSeq for what happens when it is not.
//   - Watermarks are published AFTER that transaction commits. Advertising a
//     mark first would point tills at rows nobody can read yet, and a device
//     that polled in the gap would move its cursor straight past them.
//
// A failed watermark publish is not an error the caller sees: the rows are
// committed and sync_counters — which is authoritative — already holds the
// numbers. The cache catches up when its key expires.
func (s *Service) Write(ctx context.Context, tenantID string, fn func(context.Context, *Writer) error) error {
	w := &Writer{tenantID: tenantID, marks: make(map[string]int64)}

	err := pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		w.Tx = tx
		return fn(ctx, w)
	})
	if err != nil {
		return err
	}

	for scope, seq := range w.marks {
		s.Publish(ctx, scope, seq)
	}

	return nil
}
