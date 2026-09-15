package syncfeed

import (
	"context"
	"errors"
	"fmt"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/store"

	"github.com/jackc/pgx/v5"
)

// ErrNoTransaction is returned rather than a number, because a number handed
// out here without a surrounding transaction is worse than an error: it orders
// nothing, and the row it stamps can be skipped by a device forever.
var ErrNoTransaction = errors.New(
	"syncfeed: AllocSeq must run inside the writer's own transaction, or the counter " +
		"lock is released before the row it numbers is committed — which lets a device " +
		"page straight past a row it never received")

// AllocSeq takes the next sequence number for one scope.
//
// # Why this must run inside the writer's transaction
//
// The obvious implementation — take a number, then write the row — loses data
// under concurrency, silently:
//
//  1. Writer A takes seq 10 and is slow to commit.
//  2. Writer B takes seq 11 and commits immediately.
//  3. A device pulls, sees only row B, and moves its cursor to 11.
//  4. Writer A finally commits. Row 10 is now visible, but the device is past
//     it and will never ask for it again.
//
// The product vanishes from one till and nobody finds out until a cashier tries
// to sell it.
//
// INSERT … ON CONFLICT DO UPDATE … RETURNING closes that precisely because
// PostgreSQL holds the counter row's exclusive lock until the surrounding
// transaction ENDS. B cannot take 11 until A has committed 10, so a device can
// never observe a gap that later fills in.
//
// That guarantee exists only while allocation and the row write share one
// transaction, which is why a nil tx is refused instead of being tolerated.
//
// A plain SEQUENCE is NOT a substitute: nextval releases immediately and
// survives rollback, which is the failure above with extra steps.
func AllocSeq(ctx context.Context, tx pgx.Tx, tenantID, scopeKey string) (int64, error) {
	return AllocSeqBlock(ctx, tx, tenantID, scopeKey, 1)
}

// AllocSeqBlock reserves n consecutive numbers and returns the first.
//
// The same lock, held for the same length of time — the counter row is updated
// once by however much was asked for, so reserving a block for a bulk write is
// one round trip and one lock acquisition rather than n of each.
//
// It exists because a cascading tombstone has to number every row it retires,
// and rows may not share a number: a page boundary landing inside a tie would
// strand every row still sitting at that sequence, since the next request asks
// for strictly greater.
func AllocSeqBlock(ctx context.Context, tx pgx.Tx, tenantID, scopeKey string, n int64) (int64, error) {
	if tx == nil {
		return 0, ErrNoTransaction
	}
	if n < 1 {
		return 0, fmt.Errorf("syncfeed: a sequence block must reserve at least one number, got %d", n)
	}

	last, err := store.New(tx).AllocateSyncBlock(ctx, store.AllocateSyncBlockParams{
		ScopeKey: scopeKey, TenantID: tenantID, LastSeq: n,
	})
	if err != nil {
		return 0, fmt.Errorf("allocate sync_seq for %s: %w", scopeKey, err)
	}

	return last - n + 1, nil
}

// counterSeq reads one scope's high-water mark inside a caller's transaction.
//
// It must share the reader's snapshot with the rows it accompanies. Read
// separately, it could report a number belonging to a transaction the row query
// could not see, and a device would move its cursor past a row still in flight.
func counterSeq(ctx context.Context, tx pgx.Tx, scopeKey string) (int64, error) {
	seq, err := store.New(tx).ReadSyncCounter(ctx, scopeKey)
	if errors.Is(err, pgx.ErrNoRows) {
		// Nothing of this kind has ever been written for this merchant.
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("read sync counter %s: %w", scopeKey, err)
	}

	return seq, nil
}

// counters reads the named scopes, for the cold-cache path of /sync/changes.
//
// By key rather than every counter the merchant owns: with outlet-scoped feeds
// a 5,000-outlet company owns tens of thousands of counters, and one till needs
// its branch's handful.
func counters(ctx context.Context, tx pgx.Tx, scopeKeys []string) (map[string]int64, error) {
	rows, err := store.New(tx).ReadSyncCountersByKeys(ctx, scopeKeys)
	if err != nil {
		return nil, fmt.Errorf("read sync counters: %w", err)
	}
	out := make(map[string]int64)
	for _, row := range rows {
		out[row.ScopeKey] = row.LastSeq
	}

	return out, nil
}
