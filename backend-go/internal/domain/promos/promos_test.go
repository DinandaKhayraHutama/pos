package promos_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/promos"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

type fixture struct {
	db       pgtest.DB
	feed     *syncfeed.Service
	svc      *promos.Service
	tenantID string
	outlets  []string
}

func newFixture(t *testing.T) fixture {
	t.Helper()

	db := pgtest.New(t)
	ctx := context.Background()

	rdb, err := redisx.Open(ctx, os.Getenv("REDIS_URL"))
	require.NoError(t, err, "REDIS_URL must point at a real Redis")
	t.Cleanup(func() { rdb.Close() })

	feed := syncfeed.NewService(db.Pools, rdb, slog.New(slog.NewTextHandler(io.Discard, nil)))
	f := fixture{db: db, feed: feed, svc: promos.NewService(db.Pools, feed)}

	require.NoError(t, db.Owner.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Warung Alpha', 'alpha') RETURNING id`).Scan(&f.tenantID))

	for _, name := range []string{"Bintaro", "Kemang", "Depok"} {
		var id string
		require.NoError(t, db.Owner.QueryRow(ctx,
			`INSERT INTO outlets (tenant_id, name) VALUES ($1, $2) RETURNING id`, f.tenantID, name).Scan(&id))
		f.outlets = append(f.outlets, id)
	}

	return f
}

func (f fixture) save(t *testing.T, p promos.Promo) string {
	t.Helper()

	id, err := f.svc.Save(context.Background(), f.tenantID, p)
	require.NoError(t, err)
	return id
}

// scope is what a till would hold for one promo after pulling everything:
// outlet id to whether that row is live.
func (f fixture) scope(t *testing.T, promoID string) map[string]bool {
	t.Helper()

	page, err := f.feed.Pull(context.Background(), f.tenantID, "promo_outlets", 0, 1000)
	require.NoError(t, err)

	out := map[string]bool{}
	for _, raw := range page.Rows {
		var row map[string]any
		require.NoError(t, json.Unmarshal(raw, &row))
		if row["promo_id"] == promoID {
			out[row["outlet_id"].(string)] = row["deleted_at_ms"] == nil
		}
	}
	return out
}

func (f fixture) promoRow(t *testing.T, promoID string) map[string]any {
	t.Helper()

	page, err := f.feed.Pull(context.Background(), f.tenantID, "promos", 0, 1000)
	require.NoError(t, err)

	for _, raw := range page.Rows {
		var row map[string]any
		require.NoError(t, json.Unmarshal(raw, &row))
		if row["id"] == promoID {
			return row
		}
	}

	t.Fatalf("promo %s never reached the feed", promoID)
	return nil
}

func (f fixture) counter(t *testing.T, entity string) int64 {
	t.Helper()

	var seq int64
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		`SELECT COALESCE(max(last_seq), 0) FROM sync_counters WHERE scope_key = $1`,
		syncfeed.CompanyScope(f.tenantID, entity)).Scan(&seq))
	return seq
}

func requireField(t *testing.T, err error, field string) {
	t.Helper()

	fields, ok := validation.As(err)
	require.True(t, ok, "expected a validation error on %q, got %v", field, err)
	require.Contains(t, fields, field)
}

func TestACompanyWidePromoPublishesItsFlagAndNoScoping(t *testing.T) {
	f := newFixture(t)

	id := f.save(t, promos.Promo{Name: "Diskon Pagi", Kind: promos.KindPercent, Value: 10,
		Active: true, AllOutlets: true, OutletIDs: []string{f.outlets[0]}})

	row := f.promoRow(t, id)
	require.Equal(t, true, row["all_outlets"])
	require.EqualValues(t, 10, row["value"])
	require.Empty(t, f.scope(t, id), "scoping rows beside all_outlets would be a second, contradictory answer")
}

func TestAScopedPromoPublishesExactlyItsOutlets(t *testing.T) {
	f := newFixture(t)

	id := f.save(t, promos.Promo{Name: "Promo Cabang", Kind: promos.KindAmount, Value: 5000,
		Active: true, OutletIDs: []string{f.outlets[0], f.outlets[1]}})

	require.Equal(t, false, f.promoRow(t, id)["all_outlets"])
	require.Equal(t, map[string]bool{f.outlets[0]: true, f.outlets[1]: true}, f.scope(t, id))
}

// Narrowing and widening must say exactly which branch stopped and which
// started — a tombstone for the one that left, a row for the one that joined,
// and silence about the one that stayed.
func TestChangingScopeTouchesOnlyWhatChanged(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	promo := promos.Promo{Name: "Promo Cabang", Kind: promos.KindAmount, Value: 5000,
		Active: true, OutletIDs: []string{f.outlets[0], f.outlets[1]}}
	promo.ID = f.save(t, promo)

	var stayedBefore float64
	page, err := f.feed.Pull(ctx, f.tenantID, "promo_outlets", 0, 1000)
	require.NoError(t, err)
	for _, raw := range page.Rows {
		var row map[string]any
		require.NoError(t, json.Unmarshal(raw, &row))
		if row["outlet_id"] == f.outlets[1] {
			stayedBefore = row["sync_seq"].(float64)
		}
	}

	promo.OutletIDs = []string{f.outlets[1], f.outlets[2]}
	f.save(t, promo)

	require.Equal(t, map[string]bool{
		f.outlets[0]: false, // left
		f.outlets[1]: true,  // stayed
		f.outlets[2]: true,  // joined
	}, f.scope(t, promo.ID))

	page, err = f.feed.Pull(ctx, f.tenantID, "promo_outlets", 0, 1000)
	require.NoError(t, err)
	for _, raw := range page.Rows {
		var row map[string]any
		require.NoError(t, json.Unmarshal(raw, &row))
		if row["outlet_id"] == f.outlets[1] {
			require.Equal(t, stayedBefore, row["sync_seq"], "an unchanged row must not be re-stamped")
		}
	}
}

func TestGoingCompanyWideRetiresTheScoping(t *testing.T) {
	f := newFixture(t)

	promo := promos.Promo{Name: "Promo", Kind: promos.KindPercent, Value: 5,
		Active: true, OutletIDs: []string{f.outlets[0], f.outlets[1]}}
	promo.ID = f.save(t, promo)

	promo.AllOutlets = true
	f.save(t, promo)

	for outlet, live := range f.scope(t, promo.ID) {
		require.False(t, live, "outlet %s is still scoped on a company-wide promo", outlet)
	}
}

// On the device promo_outlets hangs off promos; scoping left alive here would
// never be mentioned to a till again after it deleted the promo locally.
func TestDeletingAPromoRetiresItsScoping(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	id := f.save(t, promos.Promo{Name: "Promo", Kind: promos.KindPercent, Value: 5,
		Active: true, OutletIDs: []string{f.outlets[0], f.outlets[1]}})

	require.NoError(t, f.svc.Delete(ctx, f.tenantID, id))

	require.NotNil(t, f.promoRow(t, id)["deleted_at_ms"])
	scope := f.scope(t, id)
	require.Len(t, scope, 2)
	for outlet, live := range scope {
		require.False(t, live, "outlet %s kept a live scoping row after its promo was deleted", outlet)
	}

	require.ErrorIs(t, f.svc.Delete(ctx, f.tenantID, id), promos.ErrNotFound)
}

func TestPromoRulesMatchTheTill(t *testing.T) {
	f := newFixture(t)

	for name, tc := range map[string]struct {
		promo promos.Promo
		field string
	}{
		"over 100 percent":  {promos.Promo{Name: "X", Kind: promos.KindPercent, Value: 101, AllOutlets: true}, "value"},
		"zero amount":       {promos.Promo{Name: "X", Kind: promos.KindAmount, Value: 0, AllOutlets: true}, "value"},
		"unknown kind":      {promos.Promo{Name: "X", Kind: "bogo", Value: 1, AllOutlets: true}, "kind"},
		"negative minimum":  {promos.Promo{Name: "X", Kind: promos.KindAmount, Value: 1, MinSpend: -1, AllOutlets: true}, "min_spend"},
		"scoped to nowhere": {promos.Promo{Name: "X", Kind: promos.KindAmount, Value: 1}, "outlets"},
		"nameless":          {promos.Promo{Kind: promos.KindAmount, Value: 1, AllOutlets: true}, "name"},
		"foreign outlet": {promos.Promo{Name: "X", Kind: promos.KindAmount, Value: 1,
			OutletIDs: []string{"00000000-0000-0000-0000-000000000001"}}, "outlets"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := f.svc.Save(context.Background(), f.tenantID, tc.promo)
			requireField(t, err, tc.field)
		})
	}
}

func TestResavingTheSameScopeWakesNobody(t *testing.T) {
	f := newFixture(t)

	promo := promos.Promo{Name: "Promo", Kind: promos.KindAmount, Value: 5000,
		Active: true, OutletIDs: []string{f.outlets[0], f.outlets[1]}}
	promo.ID = f.save(t, promo)
	before := f.counter(t, "promo_outlets")

	// Same set, different order and a duplicate — the form can send either.
	promo.OutletIDs = []string{f.outlets[1], f.outlets[0], f.outlets[1]}
	f.save(t, promo)

	require.Equal(t, before, f.counter(t, "promo_outlets"))
}

func TestPromosAreTenantIsolated(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	id := f.save(t, promos.Promo{Name: "Promo", Kind: promos.KindAmount, Value: 5000, Active: true, AllOutlets: true})

	var otherTenant string
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Warung Beta', 'beta') RETURNING id`).Scan(&otherTenant))

	_, err := f.svc.Get(ctx, otherTenant, id)
	require.ErrorIs(t, err, promos.ErrNotFound)
	require.ErrorIs(t, f.svc.Delete(ctx, otherTenant, id), promos.ErrNotFound)

	// And a promo cannot be scoped to another merchant's branch.
	_, err = f.svc.Save(ctx, otherTenant, promos.Promo{Name: "Selundupan", Kind: promos.KindAmount,
		Value: 1, OutletIDs: []string{f.outlets[0]}})
	requireField(t, err, "outlets")
}

// An id from another merchant must read as "not found" on the write path too,
// not as the policy violation an upsert into a hidden row produces.
func TestSavingUnderAnotherMerchantsIDIsNotFound(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	id := f.save(t, promos.Promo{Name: "Promo", Kind: promos.KindAmount, Value: 5000, Active: true, AllOutlets: true})

	var otherTenant string
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Warung Beta', 'beta') RETURNING id`).Scan(&otherTenant))

	_, err := f.svc.Save(ctx, otherTenant, promos.Promo{
		ID: id, Name: "Curian", Kind: promos.KindAmount, Value: 1, AllOutlets: true})
	require.ErrorIs(t, err, promos.ErrNotFound)

	require.Equal(t, "Promo", f.promoRow(t, id)["name"], "nothing of ours moved")
}
