package devices_test

import (
	"context"
	"io"
	"log/slog"
	"os"
	"testing"

	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

func newRedis(t *testing.T) *redis.Client {
	t.Helper()

	url := os.Getenv("REDIS_URL")
	if url == "" {
		t.Fatal("REDIS_URL is not set; the auth cache tests need a real Redis")
	}

	rdb, err := redisx.Open(context.Background(), url)
	require.NoError(t, err)
	t.Cleanup(func() { rdb.Close() })

	return rdb
}

func (f fixture) cached(t *testing.T) *devices.CachedAuthenticator {
	t.Helper()
	return devices.NewCachedAuthenticator(f.svc, newRedis(t),
		slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func (f fixture) activateVia(c *devices.CachedAuthenticator, code, tablet string) (devices.Activation, error) {
	return c.Activate(context.Background(), devices.ActivateInput{Code: code, DeviceUUID: tablet})
}

// This is the test that makes the two below meaningful: it proves the cache
// really does serve a binding the database has already invalidated, so a
// wrapper that forgets to invalidate is not a theoretical problem.
func TestTheCacheGenuinelyServesStaleBindings(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	cached := f.cached(t)

	issued, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	act, err := f.activateVia(cached, issued.Code, "tablet-1")
	require.NoError(t, err)

	_, err = cached.Authenticate(ctx, act.Token)
	require.NoError(t, err, "warm the entry")

	// Revoke straight on the service, deliberately going around the wrapper.
	_, err = f.svc.Revoke(ctx, f.tenantID, act.Device.ID)
	require.NoError(t, err)

	_, err = f.svc.Authenticate(ctx, act.Token)
	require.ErrorIs(t, err, devices.ErrUnauthenticated, "the database has already refused it")

	_, err = cached.Authenticate(ctx, act.Token)
	require.NoError(t, err,
		"the cache still serves it — which is exactly why every write path must go through the wrapper")
}

// Re-activation rotates the token. Anything cached against the old one has to
// stop working at once, not when a five-minute entry happens to expire.
func TestReactivationInvalidatesTheCachedPreviousToken(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	cached := f.cached(t)

	first, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	old, err := f.activateVia(cached, first.Code, "tablet-1")
	require.NoError(t, err)

	_, err = cached.Authenticate(ctx, old.Token)
	require.NoError(t, err, "warm the entry for the token that is about to be replaced")

	second, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	fresh, err := f.activateVia(cached, second.Code, "tablet-1")
	require.NoError(t, err)

	_, err = cached.Authenticate(ctx, old.Token)
	require.ErrorIs(t, err, devices.ErrUnauthenticated,
		"a reinstall must not leave the previous credential alive in the cache")

	_, err = cached.Authenticate(ctx, fresh.Token)
	require.NoError(t, err)
}

func TestCachedRevokeInvalidatesImmediately(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	cached := f.cached(t)

	issued, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	act, err := f.activateVia(cached, issued.Code, "tablet-1")
	require.NoError(t, err)

	_, err = cached.Authenticate(ctx, act.Token)
	require.NoError(t, err)

	require.NoError(t, cached.Revoke(ctx, f.tenantID, act.Device.ID))

	_, err = cached.Authenticate(ctx, act.Token)
	require.ErrorIs(t, err, devices.ErrUnauthenticated)
}

// Losing Redis must cost latency, never authentication.
func TestAuthenticationSurvivesRedisBeingUnreachable(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	issued, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	act, err := f.activate(issued.Code, "tablet-1")
	require.NoError(t, err)

	dead := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})
	t.Cleanup(func() { dead.Close() })

	cached := devices.NewCachedAuthenticator(f.svc, dead,
		slog.New(slog.NewTextHandler(io.Discard, nil)))

	binding, err := cached.Authenticate(ctx, act.Token)
	require.NoError(t, err, "a cache outage must fall through to PostgreSQL, never fail open or closed")
	require.Equal(t, f.tenantID, binding.Tenant.ID)
}
