package entitlements_test

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/entitlements"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/outlets"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

type fixture struct {
	db       pgtest.DB
	devices  *devices.Service
	cache    *devices.CachedAuthenticator
	outlets  *outlets.Service
	tenantID string
}

func newFixture(t *testing.T) fixture {
	t.Helper()

	db := pgtest.New(t)
	ctx := context.Background()

	rdb, err := redisx.Open(ctx, os.Getenv("REDIS_URL"))
	require.NoError(t, err, "REDIS_URL must point at a real Redis")
	t.Cleanup(func() { rdb.Close() })

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	feed := syncfeed.NewService(db.Pools, rdb, logger)
	deviceSvc := devices.NewService(db.Pools, "test-app-key")
	cache := devices.NewCachedAuthenticator(deviceSvc, rdb, logger)

	f := fixture{db: db, devices: deviceSvc, cache: cache, outlets: outlets.NewService(db.Pools, feed, cache)}
	require.NoError(t, db.Owner.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Warung Alpha', 'alpha') RETURNING id`).Scan(&f.tenantID))
	return f
}

// setLimit writes through the platform credential, the only one allowed to.
func (f fixture) setLimit(t *testing.T, column string, max any) {
	t.Helper()
	_, err := f.db.Pools.Unscoped.Exec(context.Background(), fmt.Sprintf(`
		INSERT INTO tenant_limits (tenant_id, %[1]s) VALUES ($1, $2)
		ON CONFLICT (tenant_id) DO UPDATE SET %[1]s = EXCLUDED.%[1]s`, column), f.tenantID, max)
	require.NoError(t, err)
}

func (f fixture) outlet(t *testing.T, name string) string {
	t.Helper()
	id, err := f.outlets.SaveOutlet(context.Background(), f.tenantID, outlets.Outlet{Name: name, Active: true})
	require.NoError(t, err)
	return id
}

func (f fixture) register(t *testing.T, outletID, name string) string {
	t.Helper()
	id, err := f.outlets.SaveRegister(context.Background(), f.tenantID,
		outlets.Register{OutletID: outletID, Name: name, Active: true})
	require.NoError(t, err)
	return id
}

func requireLimitField(t *testing.T, err error) {
	t.Helper()
	fields, ok := validation.As(err)
	require.True(t, ok, "expected the limit beside the name input, got %v", err)
	require.Contains(t, fields["name"], "Batas paket")
}

// Count-then-insert without the lock lets every concurrent writer count the
// same number and all of them in. This is the race the advisory lock is for.
func TestConcurrentOutletCreatesStopExactlyAtTheLimit(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	f.setLimit(t, "max_outlets", 3)

	var (
		wg             sync.WaitGroup
		mu             sync.Mutex
		saved, refused int
		unexpected     []error
	)
	for i := range 10 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := f.outlets.SaveOutlet(ctx, f.tenantID, outlets.Outlet{Name: fmt.Sprintf("Cabang %d", i), Active: true})
			mu.Lock()
			defer mu.Unlock()
			if err == nil {
				saved++
				return
			}
			if fields, ok := validation.As(err); ok && fields["name"] != "" {
				refused++
				return
			}
			unexpected = append(unexpected, err)
		}()
	}
	wg.Wait()

	require.Empty(t, unexpected)
	require.Equal(t, 3, saved)
	require.Equal(t, 7, refused)

	var active int
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`SELECT count(*) FROM outlets WHERE tenant_id = $1 AND active`, f.tenantID).Scan(&active))
	require.Equal(t, 3, active)
}

// Closing a branch frees its place; switching it back on takes one again.
func TestSwitchingAnOutletBackOnCountsAgainstTheLimit(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	f.setLimit(t, "max_outlets", 1)

	first := f.outlet(t, "Bintaro")
	require.NoError(t, f.outlets.SetOutletActive(ctx, f.tenantID, first, false))
	kemang := f.outlet(t, "Kemang")

	err := f.outlets.SetOutletActive(ctx, f.tenantID, first, true)
	require.ErrorIs(t, err, entitlements.ErrLimitReached)

	o, err := f.outlets.Get(ctx, f.tenantID, first)
	require.NoError(t, err)
	require.False(t, o.Active, "a refused switch must stay where it was")

	// Editing a branch that is already on, at the limit, is not a new branch.
	_, err = f.outlets.SaveOutlet(ctx, f.tenantID, outlets.Outlet{ID: kemang, Name: "Kemang Raya", Active: true})
	require.NoError(t, err)

	// Nor is switching on one that is already on.
	require.NoError(t, f.outlets.SetOutletActive(ctx, f.tenantID, kemang, true))
}

func TestTillsAreLimitedAcrossBranches(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	f.setLimit(t, "max_registers", 2)

	bintaro := f.outlet(t, "Bintaro")
	kemang := f.outlet(t, "Kemang")
	f.register(t, bintaro, "Kasir 1")
	kasir := f.register(t, kemang, "Kasir 1")

	_, err := f.outlets.SaveRegister(ctx, f.tenantID, outlets.Register{OutletID: kemang, Name: "Kasir 2", Active: true})
	requireLimitField(t, err)

	// Renaming a till that is already on is not a new till.
	_, err = f.outlets.SaveRegister(ctx, f.tenantID, outlets.Register{ID: kasir, OutletID: kemang, Name: "Kasir Depan", Active: true})
	require.NoError(t, err)
}

// An unlimited merchant pays one primary-key read and no lock; a bounded one
// takes exactly the one lock for the limit it is checking.
func TestOnlyABoundedMerchantTakesTheLimitLock(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	advisoryLocks := func() int {
		var held int
		require.NoError(t, pg.InTenantTx(ctx, f.db.Pools.Tenant, f.tenantID, func(ctx context.Context, tx pgx.Tx) error {
			if err := entitlements.Enforce(ctx, tx, f.tenantID, entitlements.Outlets); err != nil {
				return err
			}
			return tx.QueryRow(ctx,
				`SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()`).Scan(&held)
		}))
		return held
	}

	require.Zero(t, advisoryLocks(), "no row: unlimited")
	f.setLimit(t, "max_registers", 5)
	require.Zero(t, advisoryLocks(), "a row that bounds something else: still unlimited for outlets")
	f.setLimit(t, "max_outlets", 5)
	require.Equal(t, 1, advisoryLocks())
}

// Activation is the authority. A code issued before the limit was lowered is
// refused, and because the refusal rolls the claim back, the same code works
// once the owner has freed a place.
func TestActivatingPastTheDeviceLimitLeavesTheCodeUsable(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	outletID := f.outlet(t, "Bintaro")
	first := f.register(t, outletID, "Kasir 1")
	second := f.register(t, outletID, "Kasir 2")

	issued, err := f.devices.Issue(ctx, f.tenantID, first, nil)
	require.NoError(t, err)
	existing, err := f.cache.Activate(ctx, devices.ActivateInput{Code: issued.Code, DeviceUUID: "tablet-1"})
	require.NoError(t, err)

	pending, err := f.devices.Issue(ctx, f.tenantID, second, nil)
	require.NoError(t, err)
	f.setLimit(t, "max_active_devices", 1)

	_, err = f.cache.Activate(ctx, devices.ActivateInput{Code: pending.Code, DeviceUUID: "tablet-2"})
	require.ErrorIs(t, err, entitlements.ErrLimitReached)

	var consumed bool
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`SELECT consumed_at IS NOT NULL FROM activation_codes WHERE pos_register_id = $1 AND cancelled_at IS NULL`,
		second).Scan(&consumed))
	require.False(t, consumed, "the refused activation must not use the code up")

	require.NoError(t, f.cache.Revoke(ctx, f.tenantID, existing.Device.ID))
	_, err = f.cache.Activate(ctx, devices.ActivateInput{Code: pending.Code, DeviceUUID: "tablet-2"})
	require.NoError(t, err, "the same code works once a place is free")
}

// A reinstall re-binds a tablet that is already counted. Refusing it at the
// limit would lock a merchant out of a till it is paying for.
func TestReinstallingATabletAtTheLimitStillBinds(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	registerID := f.register(t, f.outlet(t, "Bintaro"), "Kasir 1")
	issued, err := f.devices.Issue(ctx, f.tenantID, registerID, nil)
	require.NoError(t, err)
	_, err = f.cache.Activate(ctx, devices.ActivateInput{Code: issued.Code, DeviceUUID: "tablet-1"})
	require.NoError(t, err)

	again, err := f.devices.Issue(ctx, f.tenantID, registerID, nil)
	require.NoError(t, err)
	f.setLimit(t, "max_active_devices", 1)

	_, err = f.cache.Activate(ctx, devices.ActivateInput{Code: again.Code, DeviceUUID: "tablet-1"})
	require.NoError(t, err)
}

// The panel says why before a tablet ever sees a code.
func TestIssuingACodeAtTheDeviceLimitIsRefused(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	outletID := f.outlet(t, "Bintaro")
	first := f.register(t, outletID, "Kasir 1")
	issued, err := f.devices.Issue(ctx, f.tenantID, first, nil)
	require.NoError(t, err)
	_, err = f.cache.Activate(ctx, devices.ActivateInput{Code: issued.Code, DeviceUUID: "tablet-1"})
	require.NoError(t, err)

	f.setLimit(t, "max_active_devices", 1)
	_, err = f.devices.Issue(ctx, f.tenantID, f.register(t, outletID, "Kasir 2"), nil)

	var limit *entitlements.LimitError
	require.ErrorAs(t, err, &limit)
	require.Equal(t, entitlements.ActiveDevices, limit.Limit)
	require.Equal(t, 1, limit.Max)
}

func TestFlagsDefaultOnAndAnOverrideWins(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	var none entitlements.Set
	for _, flag := range entitlements.AllFlags {
		require.True(t, none.Has(flag), "%s must default to on, or every existing merchant loses it", flag)
	}

	_, err := f.db.Pools.Unscoped.Exec(ctx,
		`INSERT INTO tenant_feature_flags (tenant_id, flag, enabled) VALUES ($1, 'stock', false)`, f.tenantID)
	require.NoError(t, err)

	var set entitlements.Set
	require.NoError(t, pg.InTenantReadTx(ctx, f.db.Pools.Tenant, f.tenantID, func(ctx context.Context, tx pgx.Tx) error {
		set, err = entitlements.Load(ctx, tx, f.tenantID)
		return err
	}))
	require.False(t, set.Has(entitlements.Stock))
	require.True(t, set.Has(entitlements.Promos))
}
