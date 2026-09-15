// Command verify-activation exercises device activation against a REAL running
// server, which the Go test suite deliberately does not: rate limiting, the
// Retry-After header and the JSON envelope only exist once a request has been
// through the middleware stack.
//
// It creates a disposable merchant and deletes it in a defer. It prints no
// credentials.
//
//	justclick serve &
//	go run ./scripts/verify-activation
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"slices"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

var failures int

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "fatal:", err)
		os.Exit(1)
	}
	if failures > 0 {
		fmt.Printf("\n%d check(s) FAILED\n", failures)
		os.Exit(1)
	}
	fmt.Println("\nall checks passed")
}

func run() error {
	ctx := context.Background()

	baseURL := envOr("VERIFY_BASE_URL", "http://127.0.0.1:9000")
	appKey := os.Getenv("APP_KEY")
	if appKey == "" {
		return fmt.Errorf("APP_KEY must match the running server's")
	}

	// Seeding and cleanup run on the owner credential, the way a platform tool
	// would; the service under test gets the same two pools the server uses.
	pool, err := pgxpool.New(ctx, os.Getenv("MIGRATE_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer pool.Close()

	pools, err := pg.OpenPools(ctx, os.Getenv("DATABASE_URL"), os.Getenv("UNSCOPED_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer pools.Close()

	rdb, err := redisx.Open(ctx, os.Getenv("REDIS_URL"))
	if err != nil {
		return err
	}
	defer rdb.Close()

	tenantID, outletID, registerID, err := seed(ctx, pool)
	if err != nil {
		return err
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM tenants WHERE id = $1`, tenantID); err != nil {
			fmt.Fprintln(os.Stderr, "cleanup failed:", err)
		}
	}()

	svc := devices.NewService(pools, appKey)
	client := &http.Client{Timeout: 10 * time.Second}

	// Caddy issues from its own local CA in development, which no system trust
	// store knows about. Only ever set this against localhost.
	if os.Getenv("VERIFY_INSECURE_TLS") == "1" {
		client.Transport = &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // dev-only, localhost
		}
	}

	// Each phase starts from a clean limiter so an assertion never fails just
	// because an earlier phase spent the allowance. The 429 phase below is the
	// deliberate exception.
	clearLimiter(ctx, rdb)

	issued, err := svc.Issue(ctx, tenantID, registerID, nil)
	if err != nil {
		return err
	}

	var activated struct {
		Data struct {
			Token            string              `json:"token"`
			TokenExpiresAtMs int64               `json:"token_expires_at_ms"`
			Device           struct{ ID string } `json:"device"`
			Tenant           struct{ ID string } `json:"tenant"`
			Outlet           struct{ ID string } `json:"outlet"`
			Register         struct {
				ID       string `json:"id"`
				OutletID string `json:"outlet_id"`
			} `json:"pos_register"`
		} `json:"data"`
	}

	status, body := post(client, baseURL+"/api/v2/devices/activate", "", map[string]any{
		"code": issued.Code, "device_uuid": "verify-tablet-1", "platform": "android",
	})
	check("activate returns 200", status == http.StatusOK, "got %d: %s", status, body)
	if err := json.Unmarshal(body, &activated); err != nil {
		return fmt.Errorf("decode activation: %w", err)
	}
	check("activate returns a token", activated.Data.Token != "", "token was empty")
	check("token expiry is epoch millis in the future",
		activated.Data.TokenExpiresAtMs > time.Now().UnixMilli(), "got %d", activated.Data.TokenExpiresAtMs)
	check("binding names the seeded merchant", activated.Data.Tenant.ID == tenantID, "tenant mismatch")
	check("register belongs to the returned outlet",
		activated.Data.Register.OutletID == activated.Data.Outlet.ID, "outlet mismatch")
	check("outlet is the seeded one", activated.Data.Outlet.ID == outletID, "outlet mismatch")

	token := activated.Data.Token

	status, body = get(client, baseURL+"/api/v2/devices/me", token)
	check("devices/me accepts the token", status == http.StatusOK, "got %d: %s", status, body)

	// Warm the cache, then take it away. Redis holds nothing authoritative, so
	// losing it must cost latency and nothing else.
	get(client, baseURL+"/api/v2/devices/me", token)
	if err := rdb.FlushAll(ctx).Err(); err != nil {
		return fmt.Errorf("flush redis: %w", err)
	}
	status, body = get(client, baseURL+"/api/v2/devices/me", token)
	check("auth survives an empty cache", status == http.StatusOK, "got %d: %s", status, body)

	// Stay below the device limiter: measuring 429 responses is not an auth SLO.
	p50, p99 := measure(client, baseURL+"/api/v2/devices/me", token, 80)
	fmt.Printf("  INFO  authenticated request latency p50=%.2fms p99=%.2fms (includes HTTP overhead)\n",
		float64(p50.Microseconds())/1000, float64(p99.Microseconds())/1000)
	cached := devices.NewCachedAuthenticator(svc, rdb, slog.Default())
	if _, err := cached.Authenticate(ctx, token); err != nil {
		return err
	}
	samples := make([]time.Duration, 1000)
	for i := range samples {
		start := time.Now()
		if _, err := cached.Authenticate(ctx, token); err != nil {
			return err
		}
		samples[i] = time.Since(start)
	}
	slices.Sort(samples)
	fmt.Printf("  INFO  warm auth only p50=%.2fms p99=%.2fms (1000 successful lookups)\n", float64(samples[500].Microseconds())/1000, float64(samples[990].Microseconds())/1000)
	check("warm auth p99 is below 3ms", samples[990] < 3*time.Millisecond, "got %s", samples[990])

	status, _ = get(client, baseURL+"/api/v2/devices/me", "not-a-real-token")
	check("an unknown token is refused", status == http.StatusUnauthorized, "got %d", status)

	status, _ = get(client, baseURL+"/api/v2/devices/me", "")
	check("a missing token is refused", status == http.StatusUnauthorized, "got %d", status)

	clearLimiter(ctx, rdb)
	status, body = post(client, baseURL+"/api/v2/devices/activate", "", map[string]any{
		"code": issued.Code, "device_uuid": "verify-tablet-2",
	})
	check("a used code is refused", status == http.StatusUnprocessableEntity, "got %d: %s", status, body)
	check("refusal names the reason", bytes.Contains(body, []byte("invalid_code")), "got %s", body)

	clearLimiter(ctx, rdb)
	status, body = post(client, baseURL+"/api/v2/devices/activate", "", map[string]any{
		"code": issued.Code, "device_uuid": "verify-tablet-3", "tenant_id": tenantID,
	})
	check("a payload naming a tenant is rejected outright",
		status == http.StatusBadRequest, "got %d: %s", status, body)

	// Deliberately no clear: spend the per-minute allowance and read the
	// throttle response, which is the part the Pest suite never exercised.
	clearLimiter(ctx, rdb)
	var throttled bool
	var retryAfter string
	for i := 0; i < 12; i++ {
		st, hdr := postWithHeader(client, baseURL+"/api/v2/devices/activate", map[string]any{
			"code": "AAAAAAAAAAAA", "device_uuid": fmt.Sprintf("verify-flood-%d", i),
		})
		if st == http.StatusTooManyRequests {
			throttled = true
			retryAfter = hdr.Get("Retry-After")
			break
		}
	}
	check("activation is rate limited", throttled, "never saw a 429")
	seconds, convErr := strconv.Atoi(retryAfter)
	check("429 carries a usable Retry-After", convErr == nil && seconds >= 1, "got %q", retryAfter)

	// Through the cache, so this also proves the invalidation path: without it
	// the revoked binding would stay servable until its entry expired.
	auth := devices.NewCachedAuthenticator(svc, rdb, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := auth.Revoke(ctx, tenantID, activated.Data.Device.ID); err != nil {
		return err
	}
	status, _ = get(client, baseURL+"/api/v2/devices/me", token)
	check("a revoked device is refused immediately", status == http.StatusUnauthorized, "got %d", status)

	return nil
}

func seed(ctx context.Context, pool *pgxpool.Pool) (tenantID, outletID, registerID string, err error) {
	slug := fmt.Sprintf("verify-%d", time.Now().UnixNano())

	if err = pool.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Verify Merchant', $1) RETURNING id`, slug).Scan(&tenantID); err != nil {
		return
	}
	if err = pool.QueryRow(ctx,
		`INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Verify Outlet') RETURNING id`, tenantID).Scan(&outletID); err != nil {
		return
	}
	err = pool.QueryRow(ctx,
		`INSERT INTO pos_registers (tenant_id, outlet_id, name) VALUES ($1, $2, 'Kasir Verify') RETURNING id`,
		tenantID, outletID).Scan(&registerID)
	return
}

func clearLimiter(ctx context.Context, rdb *redis.Client) {
	iter := rdb.Scan(ctx, 0, "rl:act:*", 100).Iterator()
	for iter.Next(ctx) {
		rdb.Del(ctx, iter.Val())
	}
}

func post(c *http.Client, url, token string, body map[string]any) (int, []byte) {
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	resp, err := c.Do(req)
	if err != nil {
		return 0, []byte(err.Error())
	}
	defer resp.Body.Close()

	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

func postWithHeader(c *http.Client, url string, body map[string]any) (int, http.Header) {
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.Do(req)
	if err != nil {
		return 0, http.Header{}
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	return resp.StatusCode, resp.Header
}

func get(c *http.Client, url, token string) (int, []byte) {
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	resp, err := c.Do(req)
	if err != nil {
		return 0, []byte(err.Error())
	}
	defer resp.Body.Close()

	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

// measure reports the latency of an authenticated request once the cache is
// warm. It covers the whole round trip, not just the auth lookup, so treat it
// as an upper bound on the middleware's cost rather than a measurement of it.
func measure(c *http.Client, url, token string, n int) (p50, p99 time.Duration) {
	samples := make([]time.Duration, 0, n)

	for range n {
		start := time.Now()
		status, _ := get(c, url, token)
		if status != http.StatusOK {
			check("latency samples are successful responses", false, "got HTTP %d", status)
		}
		samples = append(samples, time.Since(start))
	}

	slices.Sort(samples)
	return samples[len(samples)*50/100], samples[len(samples)*99/100]
}

func check(name string, ok bool, format string, args ...any) {
	if ok {
		fmt.Printf("  PASS  %s\n", name)
		return
	}

	failures++
	fmt.Printf("  FAIL  %s: %s\n", name, fmt.Sprintf(format, args...))
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
