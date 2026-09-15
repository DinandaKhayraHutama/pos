package catalogue

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
)

// retire tombstones every live row of a table that matches where, giving each
// its own sequence number, and reports how many it retired.
//
// Two properties make it safe to use for every cascade in this package:
//
//   - **The rows are locked before they are counted.** The block of numbers is
//     reserved for exactly the rows this transaction holds, so a row committed
//     by someone else in between cannot fall outside the block and take a
//     number a later write will hand out again.
//   - **One number per row.** Two rows sharing a number can be split by a page
//     boundary, and the next request — for strictly greater — never delivers
//     the rest of the tie.
//
// Rows are addressed by ctid after the lock, which is what lets one helper
// serve both id-keyed tables and the join tables keyed by a pair. A locked
// row's ctid cannot change under this transaction.
//
// The table, entity and predicate come from this package's own constants,
// never from a request; only the arguments are values.
func retire(ctx context.Context, w *syncfeed.Writer, entity, table, where string, args ...any) (int, error) {
	rows, err := w.Tx.Query(ctx, fmt.Sprintf(`
		SELECT ctid::text FROM %s
		WHERE deleted_at IS NULL AND (%s)
		ORDER BY ctid
		FOR UPDATE`, table, where), args...)
	if err != nil {
		return 0, fmt.Errorf("lock %s to retire: %w", table, err)
	}

	ctids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return 0, err
	}
	if len(ctids) == 0 {
		return 0, nil
	}

	first, err := w.SeqBlock(ctx, entity, int64(len(ctids)))
	if err != nil {
		return 0, err
	}

	_, err = w.Tx.Exec(ctx, fmt.Sprintf(`
		UPDATE %s t
		SET deleted_at = now(), sync_seq = $1 + x.ord - 1, updated_at = now()
		FROM unnest($2::text[]) WITH ORDINALITY AS x(c, ord)
		WHERE t.ctid = x.c::tid`, table), first, ctids)
	if err != nil {
		return 0, fmt.Errorf("retire %s: %w", table, err)
	}

	return len(ctids), nil
}

// claim confirms that an id being updated belongs to this merchant — retired or
// not — and locks it for the rest of the transaction.
//
// Without it, an upsert naming another merchant's id collides with a row that
// row-level security hides, and PostgreSQL refuses with a policy violation: no
// data crosses, but the caller gets a 500 where it should get "not found", and
// the difference tells it the id exists somewhere.
func claim(ctx context.Context, tx pgx.Tx, table, tenantID, id string) error {
	var found bool
	err := tx.QueryRow(ctx, fmt.Sprintf(
		`SELECT true FROM %s WHERE tenant_id = $1 AND id = $2 FOR UPDATE`, table),
		tenantID, id).Scan(&found)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	return err
}
