package devices_test

import (
	"bytes"
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
)

const appKey = "test-app-key"

type fixture struct {
	pool       *pgxpool.Pool
	svc        *devices.Service
	tenantID   string
	outletID   string
	registerID string
}

func newFixture(t *testing.T) fixture {
	t.Helper()

	db := pgtest.New(t)
	ctx := context.Background()

	// Seeding goes through the owner, but the service under test gets exactly
	// the credentials the running server uses — otherwise these tests would
	// pass on a configuration that disables RLS entirely.
	f := fixture{pool: db.Owner, svc: devices.NewService(db.Pools, appKey)}

	require.NoError(t, db.Owner.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Warung Alpha', 'alpha') RETURNING id`).Scan(&f.tenantID))
	require.NoError(t, db.Owner.QueryRow(ctx,
		`INSERT INTO outlets (tenant_id, name, address) VALUES ($1, 'Bintaro', 'Jl. Test 1') RETURNING id`,
		f.tenantID).Scan(&f.outletID))
	require.NoError(t, db.Owner.QueryRow(ctx,
		`INSERT INTO pos_registers (tenant_id, outlet_id, name) VALUES ($1, $2, 'Kasir 1') RETURNING id`,
		f.tenantID, f.outletID).Scan(&f.registerID))

	return f
}

func (f fixture) activate(code, tablet string) (devices.Activation, error) {
	return f.svc.Activate(context.Background(), devices.ActivateInput{Code: code, DeviceUUID: tablet})
}

func TestIssueStoresAFingerprintNotThePlaintext(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	issued, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	require.Len(t, issued.Code, 12)
	require.NotContains(t, issued.Code, "0")
	require.NotContains(t, issued.Code, "I")

	var stored []byte
	require.NoError(t, f.pool.QueryRow(ctx,
		`SELECT fingerprint FROM activation_codes WHERE pos_register_id = $1`, f.registerID).Scan(&stored))

	require.False(t, bytes.Contains(stored, []byte(issued.Code)),
		"the plaintext code must never be recoverable from the row")
	require.Equal(t, devices.Fingerprint(issued.Code, appKey), stored)
}

func TestActivateReturnsTheBindingTheTillStores(t *testing.T) {
	f := newFixture(t)

	issued, err := f.svc.Issue(context.Background(), f.tenantID, f.registerID, nil)
	require.NoError(t, err)

	act, err := f.activate(issued.Code, "tablet-1")
	require.NoError(t, err)

	require.NotEmpty(t, act.Token)
	require.Equal(t, f.tenantID, act.Tenant.ID)
	require.Equal(t, f.outletID, act.Outlet.ID)
	require.Equal(t, f.registerID, act.Register.ID)
	// The Flutter client refuses a binding whose register names a different
	// outlet, so this relationship is part of the contract.
	require.Equal(t, act.Outlet.ID, act.Register.OutletID)
	require.True(t, act.TokenExpiresAt.After(time.Now()))
}

func TestCodeIsSingleUse(t *testing.T) {
	f := newFixture(t)

	issued, err := f.svc.Issue(context.Background(), f.tenantID, f.registerID, nil)
	require.NoError(t, err)

	_, err = f.activate(issued.Code, "tablet-1")
	require.NoError(t, err)

	_, err = f.activate(issued.Code, "tablet-2")
	require.ErrorIs(t, err, devices.ErrInvalidCode)
}

func TestExpiredCodeIsRefused(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	issued, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)

	_, err = f.pool.Exec(ctx,
		`UPDATE activation_codes SET expires_at = now() - interval '1 second' WHERE pos_register_id = $1`,
		f.registerID)
	require.NoError(t, err)

	_, err = f.activate(issued.Code, "tablet-1")
	require.ErrorIs(t, err, devices.ErrInvalidCode)
}

func TestIssuingAgainCancelsTheOutstandingCode(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	first, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	second, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)

	_, err = f.activate(first.Code, "tablet-1")
	require.ErrorIs(t, err, devices.ErrInvalidCode, "a replaced code must stop working immediately")

	_, err = f.activate(second.Code, "tablet-1")
	require.NoError(t, err)
}

func TestInactiveRegisterCannotBeActivated(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	issued, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)

	_, err = f.pool.Exec(ctx, `UPDATE pos_registers SET active = false WHERE id = $1`, f.registerID)
	require.NoError(t, err)

	_, err = f.activate(issued.Code, "tablet-1")
	require.ErrorIs(t, err, devices.ErrInvalidCode)
}

func TestInstallationCannotSilentlyMoveBetweenRegisters(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	var otherRegister string
	require.NoError(t, f.pool.QueryRow(ctx,
		`INSERT INTO pos_registers (tenant_id, outlet_id, name) VALUES ($1, $2, 'Kasir 2') RETURNING id`,
		f.tenantID, f.outletID).Scan(&otherRegister))

	first, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	_, err = f.activate(first.Code, "tablet-1")
	require.NoError(t, err)

	second, err := f.svc.Issue(ctx, f.tenantID, otherRegister, nil)
	require.NoError(t, err)

	_, err = f.activate(second.Code, "tablet-1")
	require.ErrorIs(t, err, devices.ErrBoundToAnother)
}

func TestReactivationRotatesThePreviousToken(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	first, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	old, err := f.activate(first.Code, "tablet-1")
	require.NoError(t, err)

	second, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	fresh, err := f.activate(second.Code, "tablet-1")
	require.NoError(t, err)

	_, err = f.svc.Authenticate(ctx, old.Token)
	require.ErrorIs(t, err, devices.ErrUnauthenticated, "a reinstall must not leave an old credential alive")

	_, err = f.svc.Authenticate(ctx, fresh.Token)
	require.NoError(t, err)
}

func TestAuthenticateRechecksTheWholeChain(t *testing.T) {
	ctx := context.Background()

	for _, tc := range []struct {
		name   string
		break_ string
	}{
		{"revoked device", `UPDATE devices SET revoked_at = now()`},
		{"suspended tenant", `UPDATE tenants SET status = 'suspended'`},
		{"closed outlet", `UPDATE outlets SET active = false`},
		{"retired register", `UPDATE pos_registers SET active = false`},
		{"expired token", `UPDATE devices SET token_expires_at = now() - interval '1 second'`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)

			issued, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
			require.NoError(t, err)
			act, err := f.activate(issued.Code, "tablet-1")
			require.NoError(t, err)

			_, err = f.svc.Authenticate(ctx, act.Token)
			require.NoError(t, err)

			_, err = f.pool.Exec(ctx, tc.break_)
			require.NoError(t, err)

			_, err = f.svc.Authenticate(ctx, act.Token)
			require.ErrorIs(t, err, devices.ErrUnauthenticated)
		})
	}
}

func TestRevokeIsImmediateAndKeepsTheDeviceRow(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	issued, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	act, err := f.activate(issued.Code, "tablet-1")
	require.NoError(t, err)

	revoked, err := f.svc.Revoke(ctx, f.tenantID, act.Device.ID)
	require.NoError(t, err)
	require.Equal(t, f.registerID, revoked.RegisterID)
	require.NotEmpty(t, revoked.TokenHash, "the caller needs the old hash to drop its cache entry")

	_, err = f.svc.Authenticate(ctx, act.Token)
	require.ErrorIs(t, err, devices.ErrUnauthenticated)

	var still int
	require.NoError(t, f.pool.QueryRow(ctx,
		`SELECT count(*) FROM devices WHERE id = $1`, act.Device.ID).Scan(&still))
	require.Equal(t, 1, still, "a stolen tablet is something an owner needs to keep seeing")
}

// The completion criterion for this phase: real concurrent connections
// contending for one code, with no lock on the tenant row.
func TestConcurrentActivationsExactlyOneWins(t *testing.T) {
	f := newFixture(t)

	issued, err := f.svc.Issue(context.Background(), f.tenantID, f.registerID, nil)
	require.NoError(t, err)

	const racers = 8
	var (
		wg      sync.WaitGroup
		start   = make(chan struct{})
		results = make([]error, racers)
	)

	for i := range racers {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			_, results[i] = f.activate(issued.Code, fmt.Sprintf("tablet-%d", i))
		}(i)
	}

	close(start)
	wg.Wait()

	won := 0
	for _, err := range results {
		if err == nil {
			won++
			continue
		}
		require.ErrorIs(t, err, devices.ErrInvalidCode)
	}
	require.Equal(t, 1, won, "one code must bind exactly one tablet")

	var bound int
	require.NoError(t, f.pool.QueryRow(context.Background(),
		`SELECT count(*) FROM devices`).Scan(&bound))
	require.Equal(t, 1, bound)
}
