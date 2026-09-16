package devices_test

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
)

// last_seen_at feeds the platform's usage page and nothing else. The write must
// not move updated_at — that is the device revision, and moving it would send
// every till in the fleet to /devices/me on each touch — nor the auth
// generation, which would empty the auth cache every five minutes.
func TestTouchingLastSeenMovesNeitherTheRevisionNorTheAuthGeneration(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	rdb := newRedis(t)
	cached := devices.NewCachedAuthenticator(f.svc, rdb, slog.New(slog.NewTextHandler(io.Discard, nil)))

	issued, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	act, err := cached.Activate(ctx, devices.ActivateInput{Code: issued.Code, DeviceUUID: "tablet-seen"})
	require.NoError(t, err)

	key := "seen:" + act.Device.ID
	require.NoError(t, rdb.Del(ctx, key).Err())
	age := func() time.Duration {
		var seen time.Time
		require.NoError(t, f.pool.QueryRow(ctx, `SELECT last_seen_at FROM devices WHERE id = $1`, act.Device.ID).Scan(&seen))
		return time.Since(seen)
	}
	backdate := func() {
		_, err := f.pool.Exec(ctx, `UPDATE devices SET last_seen_at = now() - interval '1 hour' WHERE id = $1`, act.Device.ID)
		require.NoError(t, err)
	}

	backdate()
	before, err := f.svc.Authenticate(ctx, act.Token)
	require.NoError(t, err)

	cached.Touch(ctx, before)
	require.Less(t, age(), time.Minute, "the first request in a window writes")

	after, err := f.svc.Authenticate(ctx, act.Token)
	require.NoError(t, err)
	require.Equal(t, before.RevisionMs, after.RevisionMs)
	require.Equal(t, before.AuthGenerations, after.AuthGenerations)

	backdate()
	cached.Touch(ctx, before)
	require.Greater(t, age(), 30*time.Minute, "later requests in the same window do not write")

	require.NoError(t, rdb.Del(ctx, key).Err())
	cached.Touch(ctx, before)
	require.Less(t, age(), time.Minute, "the next window writes again")
}
