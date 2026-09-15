package outlets_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/outlets"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

const appKey = "test-app-key"

type fixture struct {
	db       pgtest.DB
	feed     *syncfeed.Service
	devices  *devices.Service
	cache    *devices.CachedAuthenticator
	svc      *outlets.Service
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
	deviceSvc := devices.NewService(db.Pools, appKey)
	// The real cache, so "closing a branch signs its tills out now" is proved
	// against the thing that would otherwise keep them signed in.
	cache := devices.NewCachedAuthenticator(deviceSvc, rdb, logger)

	f := fixture{
		db: db, feed: feed, devices: deviceSvc, cache: cache,
		svc: outlets.NewService(db.Pools, feed, cache),
	}
	require.NoError(t, db.Owner.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Warung Alpha', 'alpha') RETURNING id`).Scan(&f.tenantID))

	return f
}

func (f fixture) outlet(t *testing.T, name string) string {
	t.Helper()

	id, err := f.svc.SaveOutlet(context.Background(), f.tenantID, outlets.Outlet{Name: name, Active: true})
	require.NoError(t, err)
	return id
}

func (f fixture) register(t *testing.T, outletID, name string) string {
	t.Helper()

	id, err := f.svc.SaveRegister(context.Background(), f.tenantID,
		outlets.Register{OutletID: outletID, Name: name, Active: true, TableService: true})
	require.NoError(t, err)
	return id
}

// activate binds a tablet to a register and warms its cached binding, which is
// the state every assertion about invalidation has to start from.
func (f fixture) activate(t *testing.T, registerID string) string {
	t.Helper()
	ctx := context.Background()

	issued, err := f.devices.Issue(ctx, f.tenantID, registerID, nil)
	require.NoError(t, err)

	act, err := f.cache.Activate(ctx, devices.ActivateInput{Code: issued.Code, DeviceUUID: "tablet-" + registerID})
	require.NoError(t, err)

	_, err = f.cache.Authenticate(ctx, act.Token)
	require.NoError(t, err, "warm the cached binding")

	return act.Token
}

func (f fixture) rows(t *testing.T, entity string) map[string]map[string]any {
	t.Helper()

	page, err := f.feed.Pull(context.Background(), f.tenantID, entity, 0, 1000)
	require.NoError(t, err)

	out := map[string]map[string]any{}
	for _, raw := range page.Rows {
		var row map[string]any
		require.NoError(t, json.Unmarshal(raw, &row))
		out[row["id"].(string)] = row
	}
	return out
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

// Until the pull feed carried these, a branch renamed in the Backoffice never
// reached a till that was already running.
func TestANewOutletAndItsTillReachTheFeed(t *testing.T) {
	f := newFixture(t)

	outletID := f.outlet(t, "Bintaro")
	registerID := f.register(t, outletID, "Kasir 1")

	outlet := f.rows(t, "outlets")[outletID]
	require.NotNil(t, outlet)
	require.Equal(t, "Bintaro", outlet["name"])
	require.Positive(t, outlet["sync_seq"])

	register := f.rows(t, "pos_registers")[registerID]
	require.NotNil(t, register)
	require.Equal(t, outletID, register["outlet_id"])
	require.Equal(t, true, register["table_service"])
	require.Positive(t, register["sync_seq"])
}

func TestOutletNamesAreUniqueWithinAMerchant(t *testing.T) {
	f := newFixture(t)

	f.outlet(t, "Bintaro")
	_, err := f.svc.SaveOutlet(context.Background(), f.tenantID, outlets.Outlet{Name: "Bintaro", Active: true})

	requireField(t, err, "name")
}

// Every branch is allowed its own "Kasir 1".
func TestTillNamesAreUniqueWithinAnOutletOnly(t *testing.T) {
	f := newFixture(t)

	bintaro := f.outlet(t, "Bintaro")
	kemang := f.outlet(t, "Kemang")
	f.register(t, bintaro, "Kasir 1")

	_, err := f.svc.SaveRegister(context.Background(), f.tenantID,
		outlets.Register{OutletID: bintaro, Name: "Kasir 1", Active: true})
	requireField(t, err, "name")

	f.register(t, kemang, "Kasir 1")
}

// Devices carry a composite key naming the outlet; moving the till would
// orphan them and re-file its drawer history under a branch it never traded in.
func TestATillNeverMovesBetweenOutlets(t *testing.T) {
	f := newFixture(t)

	bintaro := f.outlet(t, "Bintaro")
	kemang := f.outlet(t, "Kemang")
	registerID := f.register(t, bintaro, "Kasir 1")

	_, err := f.svc.SaveRegister(context.Background(), f.tenantID,
		outlets.Register{ID: registerID, OutletID: kemang, Name: "Kasir 1", Active: true})
	require.ErrorIs(t, err, outlets.ErrNotFound)

	r, err := f.svc.Register(context.Background(), f.tenantID, registerID)
	require.NoError(t, err)
	require.Equal(t, bintaro, r.OutletID)
}

// The whole reason the writer takes an invalidator. Without the bump, the
// cached binding would keep a closed branch's tablets selling for up to five
// minutes after the owner closed it.
func TestClosingAnOutletSignsItsTillsOutNow(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	outletID := f.outlet(t, "Bintaro")
	token := f.activate(t, f.register(t, outletID, "Kasir 1"))

	require.NoError(t, f.svc.SetOutletActive(ctx, f.tenantID, outletID, false))

	_, err := f.cache.Authenticate(ctx, token)
	require.ErrorIs(t, err, devices.ErrUnauthenticated)

	require.Equal(t, false, f.rows(t, "outlets")[outletID]["active"])
}

func TestRetiringATillSignsItsTabletOutNow(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	registerID := f.register(t, f.outlet(t, "Bintaro"), "Kasir 1")
	token := f.activate(t, registerID)

	require.NoError(t, f.svc.SetRegisterActive(ctx, f.tenantID, registerID, false))

	_, err := f.cache.Authenticate(ctx, token)
	require.ErrorIs(t, err, devices.ErrUnauthenticated)
}

// A rename changes what the till shows and what /sync/changes reports as its
// revision; a cached binding must not carry the old name for five minutes.
func TestARenameReachesCachedBindingsNow(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	outletID := f.outlet(t, "Bintaro")
	registerID := f.register(t, outletID, "Kasir 1")
	token := f.activate(t, registerID)

	before, err := f.cache.Authenticate(ctx, token)
	require.NoError(t, err)

	_, err = f.svc.SaveRegister(ctx, f.tenantID, outlets.Register{
		ID: registerID, OutletID: outletID, Name: "Kasir Depan", Active: true, TableService: true,
	})
	require.NoError(t, err)

	after, err := f.cache.Authenticate(ctx, token)
	require.NoError(t, err)
	require.Equal(t, "Kasir Depan", after.Register.Name)
	require.GreaterOrEqual(t, after.RevisionMs, before.RevisionMs, "the device revision must move with it")
}

func TestASwitchLeftWhereItWasWakesNobody(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	outletID := f.outlet(t, "Bintaro")
	registerID := f.register(t, outletID, "Kasir 1")
	outletsBefore, registersBefore := f.counter(t, "outlets"), f.counter(t, "pos_registers")

	require.NoError(t, f.svc.SetOutletActive(ctx, f.tenantID, outletID, true))
	require.NoError(t, f.svc.SetRegisterActive(ctx, f.tenantID, registerID, true))

	require.Equal(t, outletsBefore, f.counter(t, "outlets"))
	require.Equal(t, registersBefore, f.counter(t, "pos_registers"))
}

func TestOutletsAreTenantIsolated(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	mine := f.outlet(t, "Bintaro")

	var otherTenant string
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Warung Beta', 'beta') RETURNING id`).Scan(&otherTenant))

	_, err := f.svc.Get(ctx, otherTenant, mine)
	require.ErrorIs(t, err, outlets.ErrNotFound)
	require.ErrorIs(t, f.svc.SetOutletActive(ctx, otherTenant, mine, false), outlets.ErrNotFound)

	_, err = f.svc.SaveRegister(ctx, otherTenant, outlets.Register{OutletID: mine, Name: "Selundupan"})
	require.ErrorIs(t, err, outlets.ErrNotFound, "a till must not be filed under another merchant's branch")
}

// An id from another merchant must read as "not found" on the write path too,
// not as the policy violation an upsert into a hidden row produces.
func TestSavingUnderAnotherMerchantsIDIsNotFound(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	outletID := f.outlet(t, "Bintaro")
	registerID := f.register(t, outletID, "Kasir 1")

	var otherTenant, theirOutlet string
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Warung Beta', 'beta') RETURNING id`).Scan(&otherTenant))
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Milik Beta') RETURNING id`, otherTenant).Scan(&theirOutlet))

	_, err := f.svc.SaveOutlet(ctx, otherTenant, outlets.Outlet{ID: outletID, Name: "Curian", Active: true})
	require.ErrorIs(t, err, outlets.ErrNotFound)

	_, err = f.svc.SaveRegister(ctx, otherTenant, outlets.Register{ID: registerID, OutletID: theirOutlet, Name: "Curian"})
	require.ErrorIs(t, err, outlets.ErrNotFound)

	o, err := f.svc.Get(ctx, f.tenantID, outletID)
	require.NoError(t, err)
	require.Equal(t, "Bintaro", o.Name, "nothing of ours moved")
	require.Equal(t, "Kasir 1", o.Registers[0].Name)
}
