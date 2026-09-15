package syncfeed_test

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
)

func TestAllocSeqRefusesToRunOutsideATransaction(t *testing.T) {
	f := newFixture(t)

	_, err := syncfeed.AllocSeq(context.Background(), nil, f.tenantID,
		syncfeed.CompanyScope(f.tenantID, "categories"))

	require.ErrorIs(t, err, syncfeed.ErrNoTransaction,
		"a number handed out with no transaction orders nothing, and refusing is the only safe answer")
}

// The reproduction of the failure this whole design exists to prevent.
//
//  1. Writer A takes seq 1 and is slow to commit.
//  2. Writer B wants a number. If it could take 2 and commit first, a device
//     pulling in between would see only B, move its cursor to 2, and never ask
//     for row 1 again — the product vanishes from that till until someone tries
//     to sell it.
//
// PostgreSQL holds the counter row's lock until A's transaction ENDS, so step 2
// cannot happen. What follows asserts that B genuinely blocks, that a device
// polling mid-flight sees nothing rather than a gap, and that B's number only
// becomes available once A's row is readable.
func TestTheCounterLockIsHeldUntilTheWriterCommits(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	scope := syncfeed.CompanyScope(f.tenantID, "categories")

	slowWriter, endSlow := f.openTenantTx(t, f.tenantID)

	seqA, err := syncfeed.AllocSeq(ctx, slowWriter, f.tenantID, scope)
	require.NoError(t, err)
	require.EqualValues(t, 1, seqA)

	_, err = slowWriter.Exec(ctx,
		`INSERT INTO categories (tenant_id, name, sync_seq) VALUES ($1, 'Makanan', $2)`,
		f.tenantID, seqA)
	require.NoError(t, err)

	// A second writer arrives while the first is still open.
	fastWriter, endFast := f.openTenantTx(t, f.tenantID)

	blocked, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
	defer cancel()

	_, err = syncfeed.AllocSeq(blocked, fastWriter, f.tenantID, scope)
	require.Error(t, err,
		"the second writer must not be able to take a higher number while the first is uncommitted")
	endFast()

	// A device polling at exactly this moment. Neither the row nor the counter
	// is committed, so it must see nothing at all — never a mark it could move
	// its cursor to.
	page, err := f.feed.Pull(ctx, f.tenantID, "categories", 0, 100)
	require.NoError(t, err)
	require.Empty(t, page.Rows)
	require.Zero(t, page.NextSeq, "an in-flight allocation must never move a device's cursor")

	require.NoError(t, slowWriter.Commit(ctx))
	endSlow()

	// Only now can the number after it be taken.
	secondWriter, endSecond := f.openTenantTx(t, f.tenantID)
	seqB, err := syncfeed.AllocSeq(ctx, secondWriter, f.tenantID, scope)
	require.NoError(t, err)
	require.EqualValues(t, 2, seqB)
	endSecond()

	page, err = f.feed.Pull(ctx, f.tenantID, "categories", 0, 100)
	require.NoError(t, err)
	require.Len(t, page.Rows, 1, "the row the device would have skipped is there to be read")
	require.EqualValues(t, 1, page.NextSeq)
}

// The point of sharding. Under the old one-row-per-tenant counter these two
// writers queued behind each other, and with 5,000 outlets that queue was the
// system's ceiling.
func TestWritesToDifferentEntitiesDoNotQueueBehindEachOther(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	catalogueWriter, endCatalogue := f.openTenantTx(t, f.tenantID)
	_, err := syncfeed.AllocSeq(ctx, catalogueWriter, f.tenantID,
		syncfeed.CompanyScope(f.tenantID, "categories"))
	require.NoError(t, err)

	staffWriter, endStaff := f.openTenantTx(t, f.tenantID)

	// Deliberately impatient: if these two shared a counter, this could not
	// return before the first transaction ended.
	quick, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	_, err = syncfeed.AllocSeq(quick, staffWriter, f.tenantID,
		syncfeed.CompanyScope(f.tenantID, "employees"))
	require.NoError(t, err, "a staff write must not wait on an open catalogue write")

	endStaff()
	endCatalogue()
}

// The outlet axis, which is where the high-volume device feeds land in Fase 5
// and 6. Contention there should fall to the two to four tills inside one
// branch, never the whole company.
func TestOutletScopedCountersAreIndependentPerOutlet(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	var secondOutlet string
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Kemang') RETURNING id`,
		f.tenantID).Scan(&secondOutlet))

	bintaro, endBintaro := f.openTenantTx(t, f.tenantID)
	_, err := syncfeed.AllocSeq(ctx, bintaro, f.tenantID,
		syncfeed.OutletScope(f.tenantID, f.outletID, "stock_movements"))
	require.NoError(t, err)

	kemang, endKemang := f.openTenantTx(t, f.tenantID)

	quick, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	seq, err := syncfeed.AllocSeq(quick, kemang, f.tenantID,
		syncfeed.OutletScope(f.tenantID, secondOutlet, "stock_movements"))
	require.NoError(t, err, "one branch's stock ledger must not wait on another's")
	require.EqualValues(t, 1, seq, "each branch starts its own numbering")

	endKemang()
	endBintaro()
}

// A cascading tombstone numbers many rows at once, and they may not share a
// number: a page boundary landing inside a tie strands every row still sitting
// at that sequence, because the next request asks for strictly greater.
func TestASequenceBlockReservesConsecutiveNumbers(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	scope := syncfeed.CompanyScope(f.tenantID, "products")

	tx, end := f.openTenantTx(t, f.tenantID)
	defer end()

	first, err := syncfeed.AllocSeqBlock(ctx, tx, f.tenantID, scope, 5)
	require.NoError(t, err)
	require.EqualValues(t, 1, first)

	next, err := syncfeed.AllocSeq(ctx, tx, f.tenantID, scope)
	require.NoError(t, err)
	require.EqualValues(t, 6, next, "the block must not be handed out twice")
}

// Counters carry no merchant data, but a merchant able to read another's could
// measure how much business it does.
func TestCountersAreTenantIsolated(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	f.writeCategory(t, f.tenantID, "Makanan")
	f.writeCategory(t, f.otherTenantID, "Minuman")

	tx, end := f.openTenantTx(t, f.tenantID)
	defer end()

	var count int
	require.NoError(t, tx.QueryRow(ctx, `SELECT count(*) FROM sync_counters`).Scan(&count))
	require.Equal(t, 1, count, "a merchant must see only its own counters")
}
