package syncfeed_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
)

// The device writes pulled rows into SQLite with PRAGMA foreign_keys ON, so a
// product landing before its category fails outright. The server publishes the
// order rather than the client hardcoding it, which keeps adding an entity a
// server-side change.
func TestTheManifestListsDependenciesBeforeDependents(t *testing.T) {
	seen := map[string]bool{}

	for _, e := range syncfeed.BuildManifest().Entities {
		for _, dep := range e.DependsOn {
			require.True(t, seen[dep],
				"%s is published before %s, which it depends on", e.Name, dep)
		}
		seen[e.Name] = true
	}
}

func TestEveryManifestEntityNamesItsKey(t *testing.T) {
	for _, e := range syncfeed.BuildManifest().Entities {
		require.NotEmpty(t, e.Key, "%s publishes no key, so a client cannot upsert it", e.Name)
		require.NotEmpty(t, e.Apply, "%s does not say how to apply a row", e.Name)
	}
}

// Load-bearing, and the reason apply travels in the manifest at all. The till's
// ConflictAlgorithm.replace deletes before inserting, and on the device this
// table cascades from modifier_options — so replacing one row would take every
// product's option scoping with it, and menus would start offering choices
// nobody priced.
func TestProductModifierOptionsMustBeUpserted(t *testing.T) {
	for _, e := range syncfeed.BuildManifest().Entities {
		if e.Name == "product_modifier_options" {
			require.Equal(t, syncfeed.ApplyUpsert, e.Apply)
			return
		}
	}

	t.Fatal("product_modifier_options is not published at all")
}

// null and [] are different things to a client that has to branch on them.
func TestManifestDependenciesSerialiseAsAListEvenWhenEmpty(t *testing.T) {
	body, err := json.Marshal(syncfeed.BuildManifest())
	require.NoError(t, err)

	require.NotContains(t, string(body), `"depends_on":null`)
	require.Contains(t, string(body), `"depends_on":[]`)
}

func TestEveryAdvertisedPullEntityIsPullable(t *testing.T) {
	for _, e := range syncfeed.BuildManifest().Entities {
		if !e.Pull {
			require.True(t, e.Push)
			require.Contains(t, []string{"pos_sessions", "orders", "table_status_events"}, e.Name)
			continue
		}
		_, ok := syncfeed.Lookup(e.Name)
		require.True(t, ok, "%s is advertised but cannot be pulled", e.Name)
		require.True(t, e.Pull)
	}
}

func TestChangesReportsEveryFeedIncludingTheUntouchedOnes(t *testing.T) {
	f := newFixture(t)

	f.writeCategory(t, f.tenantID, "Makanan")

	cursors, err := f.feed.Cursors(context.Background(), f.tenantID)
	require.NoError(t, err)

	require.EqualValues(t, 1, cursors["categories"])
	require.Contains(t, cursors, "promos")
	require.EqualValues(t, 0, cursors["promos"],
		"a feed nothing has been written to is a cursor of zero, not a missing key")

	for _, e := range syncfeed.Entities() {
		if e.Scope == syncfeed.ScopeOutlet {
			require.NotContains(t, cursors, e.Name, "a company cursor set names no branch")
			continue
		}
		require.Contains(t, cursors, e.Name, "%s is advertised but has no cursor", e.Name)
	}

	// A till's set is the company feeds plus its own branch's outlet feeds.
	device, err := f.feed.DeviceCursors(context.Background(), f.tenantID, f.outletID)
	require.NoError(t, err)
	for _, e := range syncfeed.Entities() {
		require.Contains(t, device, e.Name, "%s is advertised but has no device cursor", e.Name)
	}
}

func TestChangesTracksEachFeedSeparately(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	f.writeCategory(t, f.tenantID, "Makanan")
	f.writeCategory(t, f.tenantID, "Minuman")
	f.writeEmployee(t, f.tenantID, "Sari", "hash")

	cursors, err := f.feed.Cursors(ctx, f.tenantID)
	require.NoError(t, err)

	require.EqualValues(t, 2, cursors["categories"])
	require.EqualValues(t, 1, cursors["employees"],
		"the staff feed is numbered on its own counter, not the merchant's")
}

// The rule Redis is allowed to exist under: flushing it costs a slowdown, never
// correctness. sync_counters is the authority, and the cache is a copy of it.
func TestChangesFallsBackToPostgresWhenRedisIsUnreachable(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	f.writeCategory(t, f.tenantID, "Makanan")

	offline := syncfeed.NewService(f.db.Pools, redis.NewClient(&redis.Options{
		Addr:        "127.0.0.1:1",
		DialTimeout: 200 * time.Millisecond,
		MaxRetries:  -1,
	}), discardLogger())

	cursors, err := offline.Cursors(ctx, f.tenantID)
	require.NoError(t, err, "a cache outage must cost latency, never a sync")
	require.EqualValues(t, 1, cursors["categories"])
}

// Two API instances can reach Redis in the opposite order to the one they
// committed in. A plain SET would let the older number win, and a watermark
// that reads LOW is the one direction that hurts: a till compares it against
// its own cursor, sees no change, and does not pull.
func TestAWatermarkNeverGoesBackwards(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	f.writeCategory(t, f.tenantID, "Makanan")

	// Warm every key, so what follows is read from Redis rather than from
	// PostgreSQL on a cold-cache fallback.
	_, err := f.feed.Cursors(ctx, f.tenantID)
	require.NoError(t, err)

	scope := syncfeed.CompanyScope(f.tenantID, "categories")
	f.feed.Publish(ctx, scope, 99)
	f.feed.Publish(ctx, scope, 5)

	cursors, err := f.feed.Cursors(ctx, f.tenantID)
	require.NoError(t, err)
	require.EqualValues(t, 99, cursors["categories"], "the later, lower write must not win")

	// And a mark that is too high is harmless by construction: the device asks
	// for rows past it and receives none.
	page, err := f.feed.Pull(ctx, f.tenantID, "categories", 99, 100)
	require.NoError(t, err)
	require.Empty(t, page.Rows)
}

func TestCursorsAreTenantScoped(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	f.writeCategory(t, f.tenantID, "Makanan")
	f.writeCategory(t, f.otherTenantID, "Rahasia")
	f.writeCategory(t, f.otherTenantID, "Lebih Rahasia")

	mine, err := f.feed.Cursors(ctx, f.tenantID)
	require.NoError(t, err)
	require.EqualValues(t, 1, mine["categories"])

	theirs, err := f.feed.Cursors(ctx, f.otherTenantID)
	require.NoError(t, err)
	require.EqualValues(t, 2, theirs["categories"])
}
