package devices_test

import (
	"context"
	"io"
	"log/slog"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

func TestCapabilitiesAreParsedAsAKnownSortedSet(t *testing.T) {
	require.Equal(t, []string{"pricing-v2", "roles-v1"}, devices.ParseCapabilities(" roles-v1 ,pricing-v2,Pricing-V2,teleport"))
	require.Equal(t, []string{"bills-v1", "pricing-v2"}, devices.ParseCapabilities("pricing-v2,bills-v1"))
	require.Equal(t, []string{}, devices.ParseCapabilities(""))
	require.True(t, devices.SameCapabilities(nil, []string{}))
}

// A capability report is advisory bookkeeping. It must not move the device
// revision (every till would call /devices/me) nor the auth generations (the
// cache would empty), and an unchanged report writes nothing at all.
func TestRecordingCapabilitiesMovesNeitherTheRevisionNorTheAuthGeneration(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	rdb := newRedis(t)
	cached := devices.NewCachedAuthenticator(f.svc, rdb, slog.New(slog.NewTextHandler(io.Discard, nil)))

	issued, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	act, err := cached.Activate(ctx, devices.ActivateInput{Code: issued.Code, DeviceUUID: "tablet-caps"})
	require.NoError(t, err)
	require.Empty(t, act.Capabilities, "an activation without the header reports nothing")

	before, err := cached.Authenticate(ctx, act.Token)
	require.NoError(t, err)
	require.Empty(t, before.Capabilities)

	caps := []string{devices.CapabilityPricingV2, devices.CapabilityRolesV1}
	require.NoError(t, cached.RecordCapabilities(ctx, act.Token, before, caps))

	after, err := cached.Authenticate(ctx, act.Token)
	require.NoError(t, err)
	require.Equal(t, caps, after.Capabilities, "the cached binding was dropped and re-read")
	require.Equal(t, before.RevisionMs, after.RevisionMs)
	require.Equal(t, before.AuthGenerations, after.AuthGenerations)

	var reported1, reported2 int64
	read := func(dst *int64) {
		require.NoError(t, f.pool.QueryRow(ctx,
			`SELECT (EXTRACT(EPOCH FROM capabilities_reported_at) * 1000000)::bigint FROM devices WHERE id = $1`,
			act.Device.ID).Scan(dst))
	}
	read(&reported1)
	require.NoError(t, f.svc.RecordCapabilities(ctx, after, caps))
	read(&reported2)
	require.Equal(t, reported1, reported2, "re-reporting the same set writes nothing")
}

func TestAnActivationTheBusinessCannotHonourIsRefusedAndKeepsTheCode(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	_, err := f.pool.Exec(ctx,
		`INSERT INTO outlet_settings (tenant_id, outlet_id, pricing_model) VALUES ($1, $2, 'v2')`,
		f.tenantID, f.outletID)
	require.NoError(t, err)

	issued, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)

	_, err = f.activate(issued.Code, "old-build")
	require.ErrorIs(t, err, devices.ErrIncompatibleApp)

	// The refusal rolled back: the same code activates the updated build.
	act, err := f.svc.Activate(ctx, devices.ActivateInput{
		Code: issued.Code, DeviceUUID: "old-build", Capabilities: []string{devices.CapabilityPricingV2},
	})
	require.NoError(t, err)
	require.Equal(t, []string{devices.CapabilityPricingV2}, act.Capabilities)
}

func TestIncompatibleDevicesNamesTheTabletsThatLackACapability(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	for _, tablet := range []struct {
		uuid string
		caps []string
	}{{"new", []string{devices.CapabilityPricingV2}}, {"old", nil}} {
		issued, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
		require.NoError(t, err)
		_, err = f.svc.Activate(ctx, devices.ActivateInput{Code: issued.Code, DeviceUUID: tablet.uuid, Capabilities: tablet.caps})
		require.NoError(t, err)
	}

	var found []devices.IncompatibleDevice
	require.NoError(t, pg.InTenantTx(ctx, f.tenantPool, f.tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		found, err = devices.IncompatibleDevices(ctx, tx, f.outletID, devices.CapabilityPricingV2)
		return err
	}))
	require.Len(t, found, 1)
	require.Equal(t, "Kasir 1", found[0].RegisterName)
}

// Once a branch runs saved bills, a till that cannot is refused at activation
// — it would read a seated table as free and take dispatched stock again.
func TestAnActivationWithoutSavedBillsIsRefusedWhereTheyAreOn(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	_, err := f.pool.Exec(ctx,
		`INSERT INTO outlet_settings (tenant_id, outlet_id, bill_model) VALUES ($1, $2, 'v1')`,
		f.tenantID, f.outletID)
	require.NoError(t, err)

	issued, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	_, err = f.svc.Activate(ctx, devices.ActivateInput{Code: issued.Code, DeviceUUID: "f3-build",
		Capabilities: []string{devices.CapabilityPricingV2, devices.CapabilityRolesV1}})
	require.ErrorIs(t, err, devices.ErrIncompatibleApp)

	_, err = f.svc.Activate(ctx, devices.ActivateInput{Code: issued.Code, DeviceUUID: "f4-build",
		Capabilities: []string{devices.CapabilityBillsV1}})
	require.NoError(t, err)
}
