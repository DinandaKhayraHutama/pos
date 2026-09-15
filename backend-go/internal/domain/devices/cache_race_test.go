package devices_test

import (
	"context"
	"io"
	"log/slog"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/require"
)

type beforeCacheWrite struct {
	once sync.Once
	run  func()
}

func (h *beforeCacheWrite) DialHook(next redis.DialHook) redis.DialHook {
	return func(ctx context.Context, network, addr string) (net.Conn, error) { return next(ctx, network, addr) }
}
func (h *beforeCacheWrite) ProcessPipelineHook(next redis.ProcessPipelineHook) redis.ProcessPipelineHook {
	return next
}
func (h *beforeCacheWrite) ProcessHook(next redis.ProcessHook) redis.ProcessHook {
	return func(ctx context.Context, cmd redis.Cmder) error {
		// Pause after the DB snapshot, just before Redis cache publication. The
		// independent connection commits revoke and publishes its newer generation.
		if strings.HasPrefix(cmd.Name(), "eval") || cmd.Name() == "mget" {
			h.once.Do(h.run)
		}
		return next(ctx, cmd)
	}
}

func TestRevokeBetweenDatabaseReadAndCacheFillCannotResurrectToken(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	code, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	act, err := f.activate(code.Code, "race-tablet")
	require.NoError(t, err)
	writer := f.cached(t)
	rdb := newRedis(t)
	rdb.AddHook(&beforeCacheWrite{run: func() { require.NoError(t, writer.Revoke(ctx, f.tenantID, act.Device.ID)) }})
	reader := devices.NewCachedAuthenticator(f.svc, rdb, slog.New(slog.NewTextHandler(io.Discard, nil)))
	_, _ = reader.Authenticate(ctx, act.Token) // already in flight at the revoke
	_, err = reader.Authenticate(ctx, act.Token)
	require.ErrorIs(t, err, devices.ErrUnauthenticated, "a later request cannot use the stale fill")
}

func TestWarmCacheCannotOutliveTokenExpiry(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	code, err := f.svc.Issue(ctx, f.tenantID, f.registerID, nil)
	require.NoError(t, err)
	act, err := f.activate(code.Code, "expiry-tablet")
	require.NoError(t, err)
	_, err = f.pool.Exec(ctx, "UPDATE devices SET token_expires_at = now() + interval '250 milliseconds' WHERE id=$1", act.Device.ID)
	require.NoError(t, err)
	c := f.cached(t)
	_, err = c.Authenticate(ctx, act.Token)
	require.NoError(t, err)
	time.Sleep(300 * time.Millisecond)
	_, err = c.Authenticate(ctx, act.Token)
	require.ErrorIs(t, err, devices.ErrUnauthenticated)
}

func TestConcurrentIssuanceLeavesOnlyTheLatestCodeUsable(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	var wg sync.WaitGroup
	errs := make([]error, 8)
	for i := range errs {
		wg.Add(1)
		go func() { defer wg.Done(); _, errs[i] = f.svc.Issue(ctx, f.tenantID, f.registerID, nil) }()
	}
	wg.Wait()
	for _, err := range errs {
		require.NoError(t, err)
	}
	var n int
	require.NoError(t, f.pool.QueryRow(ctx, "SELECT count(*) FROM activation_codes WHERE consumed_at IS NULL AND cancelled_at IS NULL").Scan(&n))
	require.Equal(t, 1, n)
}
