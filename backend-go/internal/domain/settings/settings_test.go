package settings_test

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/settings"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

type fixture struct {
	db       pgtest.DB
	svc      *settings.Service
	tenantID string
	outletID string
}

func newFixture(t *testing.T) fixture {
	t.Helper()
	db := pgtest.New(t)
	ctx := context.Background()
	rdb, err := redisx.Open(ctx, os.Getenv("REDIS_URL"))
	require.NoError(t, err, "REDIS_URL must point at a real Redis")
	t.Cleanup(func() { rdb.Close() })
	feed := syncfeed.NewService(db.Pools, rdb, slog.New(slog.NewTextHandler(io.Discard, nil)))
	f := fixture{db: db, svc: settings.NewService(db.Pools, feed, nil, nil)}
	require.NoError(t, db.Owner.QueryRow(ctx, `INSERT INTO tenants (name, slug) VALUES ('Warung', 'warung') RETURNING id::text`).Scan(&f.tenantID))
	require.NoError(t, db.Owner.QueryRow(ctx, `INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Pusat') RETURNING id::text`, f.tenantID).Scan(&f.outletID))
	return f
}

func (f fixture) counter(t *testing.T, key string) int64 {
	t.Helper()
	var seq int64
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		`SELECT COALESCE(max(last_seq), 0) FROM sync_counters WHERE scope_key = $1`, key).Scan(&seq))
	return seq
}

func ptr[T any](v T) *T { return &v }

// Nothing is published until the owner saves, and that absence is what a till
// reads as "keep what you were doing".
func TestABusinessIsUnconfiguredUntilItsOwnerSaves(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	b, err := f.svc.Business(ctx, f.tenantID)
	require.NoError(t, err)
	require.False(t, b.Configured)
	require.Equal(t, 1000, b.TaxRateBP)

	b.TaxRateBP, b.ServiceEnabled, b.RoundingUnit = 1100, true, 100
	require.NoError(t, f.svc.SaveBusiness(ctx, f.tenantID, b))
	key := syncfeed.CompanyScope(f.tenantID, "business_settings")
	require.EqualValues(t, 1, f.counter(t, key))

	require.NoError(t, f.svc.SaveBusiness(ctx, f.tenantID, b))
	require.EqualValues(t, 1, f.counter(t, key), "re-saving the same values wakes no till")

	b.ReceiptFooter = ptr("WiFi: kopi123 🙂")
	_, invalid := validation.As(f.svc.SaveBusiness(ctx, f.tenantID, b))
	require.True(t, invalid, "an emoji cannot be printed in the receipt's font")
}

func TestPricingV2WaitsForEveryTillOfTheBranch(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	var register, device string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO pos_registers (tenant_id, outlet_id, name) VALUES ($1, $2, 'Kasir 1') RETURNING id::text`, f.tenantID, f.outletID).Scan(&register))
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO devices (tenant_id, outlet_id, pos_register_id, device_uuid) VALUES ($1, $2, $3, 'old') RETURNING id::text`, f.tenantID, f.outletID, register).Scan(&device))

	err := f.svc.SetPricingModel(ctx, f.tenantID, f.outletID, "v2")
	var notReady *settings.ErrDevicesNotReady
	require.True(t, errors.As(err, &notReady), "got %v", err)
	require.Len(t, notReady.Devices, 1)

	_, err = f.db.Owner.Exec(ctx, `UPDATE devices SET capabilities = ARRAY['pricing-v2'] WHERE id = $1`, device)
	require.NoError(t, err)
	require.NoError(t, f.svc.SetPricingModel(ctx, f.tenantID, f.outletID, "v2"))
	o, err := f.svc.OutletSettings(ctx, f.tenantID, f.outletID)
	require.NoError(t, err)
	require.Equal(t, "v2", o.PricingModel)

	// Saving the other outlet fields keeps the model it was switched to.
	o.TrackServer = true
	require.NoError(t, f.svc.SaveOutlet(ctx, f.tenantID, o))
	o, err = f.svc.OutletSettings(ctx, f.tenantID, f.outletID)
	require.NoError(t, err)
	require.Equal(t, "v2", o.PricingModel)
	require.True(t, o.TrackServer)
	require.Positive(t, f.counter(t, syncfeed.OutletScope(f.tenantID, f.outletID, "outlet_settings")),
		"outlet settings are numbered on the branch's own counter")
}

func TestATimezoneChangeReachesTheBindingAndRecomputesOnlyToday(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	changed, err := f.svc.SetProfile(ctx, f.tenantID, "Warung Timur", "Asia/Jayapura")
	require.NoError(t, err)
	require.True(t, changed)
	var zone, legacy string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT timezone, COALESCE(legacy_timezone, '') FROM tenants WHERE id = $1`, f.tenantID).Scan(&zone, &legacy))
	require.Equal(t, "Asia/Jayapura", zone)
	var dirty int
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT count(*) FROM report_dirty_slices WHERE tenant_id = $1 AND business_date >= current_date - 2`, f.tenantID).Scan(&dirty))
	require.Positive(t, dirty)
	var old int
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT count(*) FROM report_dirty_slices WHERE tenant_id = $1 AND business_date < current_date - 2`, f.tenantID).Scan(&old))
	require.Zero(t, old, "history is never rewritten")

	_, invalid := validation.As(func() error { _, err := f.svc.SetProfile(ctx, f.tenantID, "Warung", "Europe/London"); return err }())
	require.True(t, invalid)
}

func TestAnOutletCannotNameAnotherMerchantsSalesType(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	var other, theirs string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO tenants (name, slug) VALUES ('Beta', 'beta') RETURNING id::text`).Scan(&other))
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT id::text FROM sales_types WHERE tenant_id = $1 LIMIT 1`, other).Scan(&theirs))

	o, err := f.svc.OutletSettings(ctx, f.tenantID, f.outletID)
	require.NoError(t, err)
	o.SalesTypeIDs = []string{theirs}
	_, invalid := validation.As(f.svc.SaveOutlet(ctx, f.tenantID, o))
	require.True(t, invalid)

	require.ErrorIs(t, f.svc.SaveOutlet(ctx, other, settings.Outlet{OutletID: f.outletID}), settings.ErrNotFound,
		"another merchant's outlet id is not found, not an RLS error")
}

// Saved bills (Fase 4) are switched on per branch the same way pricing v2 is:
// only once every active till there reports bills-v1. Switching back off is
// always allowed — it stops new bills and keeps the ones already open.
func TestSavedBillsWaitForEveryTillOfTheBranch(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	var register, device string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO pos_registers (tenant_id, outlet_id, name) VALUES ($1, $2, 'Kasir 1') RETURNING id::text`, f.tenantID, f.outletID).Scan(&register))
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO devices (tenant_id, outlet_id, pos_register_id, device_uuid, capabilities) VALUES ($1, $2, $3, 'f3', ARRAY['pricing-v2','roles-v1']) RETURNING id::text`, f.tenantID, f.outletID, register).Scan(&device))

	err := f.svc.SetBillModel(ctx, f.tenantID, f.outletID, "v1")
	var notReady *settings.ErrDevicesNotReady
	require.True(t, errors.As(err, &notReady), "got %v", err)
	require.Len(t, notReady.Devices, 1)

	_, err = f.db.Owner.Exec(ctx, `UPDATE devices SET capabilities = ARRAY['bills-v1','pricing-v2','roles-v1'] WHERE id = $1`, device)
	require.NoError(t, err)
	require.NoError(t, f.svc.SetBillModel(ctx, f.tenantID, f.outletID, "v1"))
	before := f.counter(t, syncfeed.OutletScope(f.tenantID, f.outletID, "outlet_settings"))
	require.NoError(t, f.svc.SetBillModel(ctx, f.tenantID, f.outletID, "v1"))
	require.Equal(t, before, f.counter(t, syncfeed.OutletScope(f.tenantID, f.outletID, "outlet_settings")),
		"re-saving the same model wakes no till")

	o, err := f.svc.OutletSettings(ctx, f.tenantID, f.outletID)
	require.NoError(t, err)
	require.Equal(t, "v1", o.BillModel)
	o.TrackServer = true
	require.NoError(t, f.svc.SaveOutlet(ctx, f.tenantID, o))
	o, err = f.svc.OutletSettings(ctx, f.tenantID, f.outletID)
	require.NoError(t, err)
	require.Equal(t, "v1", o.BillModel, "saving the other fields keeps the bill model")
	require.Equal(t, "legacy", o.PricingModel, "and the two models are independent")

	require.NoError(t, f.svc.SetBillModel(ctx, f.tenantID, f.outletID, "legacy"))
	o, err = f.svc.OutletSettings(ctx, f.tenantID, f.outletID)
	require.NoError(t, err)
	require.Equal(t, "legacy", o.BillModel)
}
