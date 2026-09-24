package syncfeed_test

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/syncfixture"
)

func decode(t *testing.T, raw json.RawMessage) map[string]any {
	t.Helper()

	var row map[string]any
	require.NoError(t, json.Unmarshal(raw, &row))

	return row
}

func keysOf(row map[string]any) []string {
	out := make([]string, 0, len(row))
	for k := range row {
		out = append(out, k)
	}
	return out
}

// The reason the column list is an allow-list and not SELECT *. In the Laravel
// original, mapping an entity name to a model by convention had once served
// `employees` complete with password hashes to anything holding a device token.
func TestPullPublishesOnlyTheColumnsOnTheAllowList(t *testing.T) {
	f := newFixture(t)

	f.writeEmployee(t, f.tenantID, "Sari", "$2a$10$averyfakebcrypthash")

	page, err := f.feed.Pull(context.Background(), f.tenantID, "employees", 0, 100)
	require.NoError(t, err)
	require.Len(t, page.Rows, 1)

	row := decode(t, page.Rows[0])

	require.ElementsMatch(t,
		[]string{"id", "name", "pin_hash", "role", "role_id", "active", "sort_order", "sync_seq", "deleted_at_ms"},
		keysOf(row))

	require.NotContains(t, row, "password", "a browser credential is of no use to a till")
	require.NotContains(t, row, "email")
	require.Equal(t, "$2a$10$averyfakebcrypthash", row["pin_hash"],
		"the PIN hash does travel: offline sign-in genuinely needs it")
}

// Not a style point. The Flutter till parses any 2xx body that is not an object
// as SyncFailure.malformed, and a malformed push response makes it delete the
// queued sale permanently.
func TestEveryPulledRowIsAJSONObject(t *testing.T) {
	f := newFixture(t)

	f.writeCategory(t, f.tenantID, "Makanan")
	f.writeEmployee(t, f.tenantID, "Sari", "hash")

	for _, entity := range []string{"categories", "employees"} {
		page, err := f.feed.Pull(context.Background(), f.tenantID, entity, 0, 100)
		require.NoError(t, err)
		require.NotEmpty(t, page.Rows)

		for _, raw := range page.Rows {
			require.True(t, strings.HasPrefix(string(raw), "{"),
				"%s published something that is not an object: %s", entity, raw)
		}
	}
}

// An empty feed must serialise as [] and not null: a client should not have to
// treat "no rows" as a different case from "some rows".
func TestAnEmptyPageStillCarriesARowList(t *testing.T) {
	f := newFixture(t)

	page, err := f.feed.Pull(context.Background(), f.tenantID, "promos", 0, 100)
	require.NoError(t, err)

	body, err := json.Marshal(page)
	require.NoError(t, err)
	require.Contains(t, string(body), `"rows":[]`)
}

func TestPullPagesInSequenceOrder(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	for _, name := range []string{"Makanan", "Minuman", "Snack", "Kopi", "Teh"} {
		f.writeCategory(t, f.tenantID, name)
	}

	first, err := f.feed.Pull(ctx, f.tenantID, "categories", 0, 2)
	require.NoError(t, err)
	require.Len(t, first.Rows, 2)
	require.True(t, first.HasMore)
	require.EqualValues(t, 2, first.NextSeq)
	require.Equal(t, "Makanan", decode(t, first.Rows[0])["name"])

	second, err := f.feed.Pull(ctx, f.tenantID, "categories", first.NextSeq, 2)
	require.NoError(t, err)
	require.Len(t, second.Rows, 2)
	require.Equal(t, "Snack", decode(t, second.Rows[0])["name"])

	last, err := f.feed.Pull(ctx, f.tenantID, "categories", second.NextSeq, 2)
	require.NoError(t, err)
	require.Len(t, last.Rows, 1)
	require.False(t, last.HasMore)
	require.EqualValues(t, 5, last.NextSeq)
}

// A tombstone is the only way a till learns a row is gone. A delta page says
// what changed; absence from it says nothing at all.
func TestPullDeliversTombstones(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	id := f.writeCategory(t, f.tenantID, "Makanan")

	require.NoError(t, f.feed.Write(ctx, f.tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		seq, err := w.Seq(ctx, "categories")
		if err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx,
			`UPDATE categories SET deleted_at = now(), sync_seq = $2 WHERE id = $1`, id, seq)
		return err
	}))

	page, err := f.feed.Pull(ctx, f.tenantID, "categories", 1, 100)
	require.NoError(t, err)
	require.Len(t, page.Rows, 1)

	row := decode(t, page.Rows[0])
	require.Equal(t, id, row["id"])
	require.NotNil(t, row["deleted_at_ms"], "the retired row must arrive, marked")
	require.IsType(t, float64(0), row["deleted_at_ms"], "timestamps on the wire are epoch millis")
}

// Row-level security is what enforces this, not a WHERE clause somebody
// remembered to write. The service holds a credential that cannot bypass it.
func TestPullNeverCrossesTenants(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	f.writeCategory(t, f.tenantID, "Makanan")
	f.writeCategory(t, f.otherTenantID, "Rahasia")

	page, err := f.feed.Pull(ctx, f.tenantID, "categories", 0, 100)
	require.NoError(t, err)
	require.Len(t, page.Rows, 1)
	require.Equal(t, "Makanan", decode(t, page.Rows[0])["name"])

	other, err := f.feed.Pull(ctx, f.otherTenantID, "categories", 0, 100)
	require.NoError(t, err)
	require.Len(t, other.Rows, 1)
	require.Equal(t, "Rahasia", decode(t, other.Rows[0])["name"])
}

func TestPullOfAnUnknownEntityIsRefused(t *testing.T) {
	f := newFixture(t)

	_, err := f.feed.Pull(context.Background(), f.tenantID, "pg_authid", 0, 100)

	require.ErrorIs(t, err, syncfeed.ErrUnknownEntity,
		"the entity name arrives from a client; turning it into a table would serve whatever it names")
}

// Without the mark, a cursor stuck below a number whose row no longer exists
// would re-ask for the same empty page forever.
func TestTheCursorMovesPastNumbersWhoseRowsAreGone(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	f.writeCategory(t, f.tenantID, "Makanan")
	doomed := f.writeCategory(t, f.tenantID, "Minuman")

	// A hard delete, the way a platform-level purge would do it — not the
	// tombstone the Backoffice writes.
	_, err := f.db.Owner.Exec(ctx, `DELETE FROM categories WHERE id = $1`, doomed)
	require.NoError(t, err)

	page, err := f.feed.Pull(ctx, f.tenantID, "categories", 1, 100)
	require.NoError(t, err)
	require.Empty(t, page.Rows)
	require.EqualValues(t, 2, page.NextSeq, "the cursor must reach the mark, not crawl behind it")
	require.False(t, page.HasMore)
}

func TestPullRefusesToServeMoreThanTheMaximumPage(t *testing.T) {
	f := newFixture(t)

	f.seedProducts(t, syncfeed.MaxPullLimit+10)

	page, err := f.feed.Pull(context.Background(), f.tenantID, "products", 0, 100_000)
	require.NoError(t, err)
	require.Len(t, page.Rows, syncfeed.MaxPullLimit)
	require.True(t, page.HasMore)
}

// The Fase 2A gate: a 5,000-product catalogue pulls through in full, with no
// row delivered twice and none missing.
func TestTheWholeCatalogueOfFiveThousandProductsPullsThrough(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	const total = 5000
	f.seedProducts(t, total)

	seen := make(map[string]bool, total)
	cursor := int64(0)
	pages := 0

	for {
		page, err := f.feed.Pull(ctx, f.tenantID, "products", cursor, 500)
		require.NoError(t, err)

		for _, raw := range page.Rows {
			id, _ := decode(t, raw)["id"].(string)
			require.NotEmpty(t, id)
			require.False(t, seen[id], "a row must not be delivered twice")
			seen[id] = true
		}

		cursor = page.NextSeq
		pages++
		require.Less(t, pages, 100, "paging is not terminating")

		if !page.HasMore {
			break
		}
	}

	require.Len(t, seen, total)

	// And the cursor is now settled: polling again returns nothing.
	page, err := f.feed.Pull(ctx, f.tenantID, "products", cursor, 500)
	require.NoError(t, err)
	require.Empty(t, page.Rows)
	require.Equal(t, cursor, page.NextSeq)
}

// The covering indexes exist so that fifteen thousand tablets pulling the menu
// never touch the heap. Adding a published column without adding it to the
// index INCLUDE list silently costs a heap fetch per row, and this is the only
// thing that would notice.
func TestPullUsesAnIndexOnlyScan(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	require.NoError(t, syncfixture.Seed(ctx, f.feed, f.tenantID, 5000))

	// The visibility map has to be built, or PostgreSQL cannot prove a row is
	// visible from the index alone and falls back to reading the heap.
	var outletID string
	require.NoError(t, f.db.Owner.QueryRow(ctx, syncfixture.FeedOutletSQL, f.tenantID).Scan(&outletID))
	for _, e := range syncfeed.Entities() {
		if e.Singleton {
			// One row per scope: see Entity.Singleton for why the plan is not
			// asserted. Its covering index must still exist under the name the
			// fleet-wide table relies on.
			var exists bool
			require.NoError(t, f.db.Owner.QueryRow(ctx,
				`SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = $1)`, e.Table+"_sync_feed_idx").Scan(&exists))
			require.True(t, exists, e.Name)
			continue
		}
		t.Run(e.Name, func(t *testing.T) {
			_, err := f.db.Owner.Exec(ctx, "VACUUM (ANALYZE) "+e.Table, pgx.QueryExecModeSimpleProtocol)
			require.NoError(t, err)
			plan, err := f.feed.ExplainPull(ctx, f.tenantID, outletID, e.Name, 4500, 500)
			require.NoError(t, err)
			require.Contains(t, plan, "Index Only Scan", "cover every published column:\n%s", plan)
			require.Contains(t, plan, e.Table+"_sync_feed_idx")
		})
	}
}

// seedProducts writes n products in one transaction, numbered from a single
// reserved block — the same shape a bulk import will take.
func (f fixture) seedProducts(t *testing.T, n int) {
	t.Helper()

	categoryID := f.writeCategory(t, f.tenantID, "Makanan")

	require.NoError(t, f.feed.Write(context.Background(), f.tenantID,
		func(ctx context.Context, w *syncfeed.Writer) error {
			first, err := w.SeqBlock(ctx, "products", int64(n))
			if err != nil {
				return err
			}

			_, err = w.Tx.Exec(ctx, fmt.Sprintf(`
				INSERT INTO products (tenant_id, category_id, name, price, sync_seq)
				SELECT $1, $2, 'Produk ' || g, 10000 + g, $3 + g - 1
				FROM generate_series(1, %d) AS g`, n),
				f.tenantID, categoryID, first)
			return err
		}))
}
