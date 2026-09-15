// Command verify-sync drives the v2 pull contract against a REAL running
// server.
//
// It is not a duplicate of the test suite. What only exists once a request has
// been through the middleware stack: the bearer-token path, the rate limiter,
// the JSON envelope, and — the assertion worth the most here — that every 2xx
// body is a JSON OBJECT. The Flutter till parses any 2xx body that is not an
// object as SyncFailure.malformed, and on the push path malformed means it
// deletes the queued sale permanently. A top-level array is a money bug, and no
// unit test on either side would notice.
//
// It creates a disposable merchant and deletes it in a defer.
//
//	justclick serve &
//	go run ./scripts/verify-sync
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/syncfixture"
)

// Enough products that paging is real rather than theoretical, and small
// enough that the script stays a thing people actually run.
const seededProducts = 5000

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

	owner, err := pgxpool.New(ctx, os.Getenv("MIGRATE_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer owner.Close()

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

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	feed := syncfeed.NewService(pools, rdb, logger)

	tenantID, registerID, err := seedMerchant(ctx, owner)
	if err != nil {
		return err
	}
	defer func() {
		if _, err := owner.Exec(context.Background(), `DELETE FROM tenants WHERE id = $1`, tenantID); err != nil {
			fmt.Fprintln(os.Stderr, "cleanup failed:", err)
		}
	}()

	if err := syncfixture.Seed(ctx, feed, tenantID, seededProducts); err != nil {
		return err
	}

	client := &http.Client{Timeout: 30 * time.Second}
	// Caddy issues from its own local CA in development, which no system trust
	// store knows about. Only ever set this against localhost.
	if os.Getenv("VERIFY_INSECURE_TLS") == "1" {
		client.Transport = &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // dev-only, localhost
		}
	}

	clearLimiter(ctx, rdb)

	svc := devices.NewService(pools, appKey)
	issued, err := svc.Issue(ctx, tenantID, registerID, nil)
	if err != nil {
		return err
	}

	var activated struct {
		Data struct {
			Token  string              `json:"token"`
			Device struct{ ID string } `json:"device"`
		} `json:"data"`
	}
	status, body := post(client, baseURL+"/api/v2/devices/activate", map[string]any{
		"code": issued.Code, "device_uuid": "verify-sync-tablet",
	})
	if status != http.StatusOK {
		return fmt.Errorf("activation failed with %d: %s", status, body)
	}
	if err := json.Unmarshal(body, &activated); err != nil {
		return err
	}
	token := activated.Data.Token
	deviceKey := "rl:dev:" + activated.Data.Device.ID

	// ---- manifest -----------------------------------------------------------

	var manifest struct {
		SchemaVersion int `json:"schema_version"`
		Entities      []struct {
			Name      string   `json:"name"`
			Scope     string   `json:"scope"`
			Key       []string `json:"key"`
			DependsOn []string `json:"depends_on"`
			Pull      bool     `json:"pull"`
			Apply     string   `json:"apply"`
		} `json:"entities"`
	}

	status, body = get(client, baseURL+"/api/v2/sync/manifest", token)
	check("manifest returns 200", status == http.StatusOK, "got %d: %s", status, body)
	check("manifest is a JSON object", isJSONObject(body), "got %s", firstBytes(body))
	if err := json.Unmarshal(body, &manifest); err != nil {
		return fmt.Errorf("decode manifest: %w", err)
	}
	check("manifest names a schema version", manifest.SchemaVersion >= 1, "got %d", manifest.SchemaVersion)
	check("manifest publishes entities", len(manifest.Entities) > 0, "none")
	check("depends_on is a list, never null",
		!strings.Contains(string(body), `"depends_on":null`), "got null somewhere")

	seen := map[string]bool{}
	orderOK := true
	for _, e := range manifest.Entities {
		for _, dep := range e.DependsOn {
			if !seen[dep] {
				orderOK = false
			}
		}
		seen[e.Name] = true
	}
	check("entities are published dependency-first", orderOK,
		"a dependant is listed before what it depends on; the till applies with foreign keys ON")

	upsert := false
	for _, e := range manifest.Entities {
		if e.Name == "product_modifier_options" {
			upsert = e.Apply == "upsert"
		}
	}
	check("product_modifier_options is apply:upsert", upsert,
		"replace deletes-then-inserts on the device and cascades away every product's option scoping")

	// ---- changes ------------------------------------------------------------

	var changes struct {
		Cursors        map[string]int64 `json:"cursors"`
		DeviceRevision int64            `json:"device_revision"`
		ServerTimeMs   int64            `json:"server_time_ms"`
		NextPollMs     int64            `json:"next_poll_ms"`
	}

	status, body = get(client, baseURL+"/api/v2/sync/changes", token)
	check("changes returns 200", status == http.StatusOK, "got %d: %s", status, body)
	check("changes is a JSON object", isJSONObject(body), "got %s", firstBytes(body))
	if err := json.Unmarshal(body, &changes); err != nil {
		return fmt.Errorf("decode changes: %w", err)
	}
	pullable := 0
	for _, entity := range manifest.Entities {
		if entity.Pull {
			pullable++
		}
	}
	check("changes covers every pullable manifest entity",
		len(changes.Cursors) == pullable, "got %d of %d", len(changes.Cursors), pullable)
	check("the product cursor reflects the seed",
		changes.Cursors["products"] >= seededProducts, "got %d", changes.Cursors["products"])
	check("changes carries a device revision", changes.DeviceRevision > 0, "got %d", changes.DeviceRevision)
	check("server time is epoch millis, not seconds",
		changes.ServerTimeMs > 1_600_000_000_000, "got %d", changes.ServerTimeMs)
	check("the poll interval is server-controlled", changes.NextPollMs > 0, "got %d", changes.NextPollMs)

	// Redis holds nothing authoritative. Losing it must cost latency and
	// nothing else — sync_counters is the source of truth for these numbers.
	if err := rdb.FlushAll(ctx).Err(); err != nil {
		return err
	}
	status, body = get(client, baseURL+"/api/v2/sync/changes", token)
	check("changes survives an empty cache", status == http.StatusOK, "got %d: %s", status, body)
	var cold struct {
		Cursors map[string]int64 `json:"cursors"`
	}
	_ = json.Unmarshal(body, &cold)
	check("a cold cache reports the same cursors",
		cold.Cursors["products"] == changes.Cursors["products"],
		"warm %d, cold %d", changes.Cursors["products"], cold.Cursors["products"])

	// ---- pull ---------------------------------------------------------------

	rdb.Del(ctx, deviceKey)
	total := 0
	for _, e := range manifest.Entities {
		if !e.Pull {
			continue
		}
		rows, err := pullAll(client, baseURL, token, e.Name)
		if err != nil {
			return err
		}
		total += len(rows)
		check(e.Name+" delivers its complete fixture", len(rows) == seededProducts,
			"expected %d, got %d", seededProducts, len(rows))
		// Paging every feed intentionally exceeds a single device's minute
		// budget. Reset only this disposable device between feeds.
		rdb.Del(ctx, deviceKey)

		if e.Name == "products" {
			check("the whole catalogue arrives", len(rows) == seededProducts,
				"expected %d, got %d", seededProducts, len(rows))
		}
		if e.Name == "employees" && len(rows) > 0 {
			_, hasPassword := rows[0]["password"]
			_, hasEmail := rows[0]["email"]
			check("the staff feed carries no browser credential", !hasPassword && !hasEmail,
				"got keys %v", keysOf(rows[0]))
			check("the staff feed does carry the PIN hash offline sign-in needs",
				rows[0]["pin_hash"] != nil, "pin_hash was absent")
		}
	}
	check("pulling every entity delivered rows", total > seededProducts, "got %d", total)

	// ---- refusals -----------------------------------------------------------

	rdb.Del(ctx, deviceKey)

	status, body = get(client, baseURL+"/api/v2/sync/pull?entity=pg_authid", token)
	check("an unknown entity is refused", status == http.StatusNotFound, "got %d: %s", status, body)
	check("the refusal names a closed-set code",
		strings.Contains(string(body), "unknown_entity"), "got %s", body)

	status, _ = get(client, baseURL+"/api/v2/sync/pull?entity=products", "")
	check("an unauthenticated pull is refused", status == http.StatusUnauthorized, "got %d", status)

	status, body = getWithSchema(client, baseURL+"/api/v2/sync/manifest", token, "0")
	check("a client too old is told to update", status == http.StatusConflict, "got %d: %s", status, body)
	check("the 409 names device_schema_outdated",
		strings.Contains(string(body), "device_schema_outdated"), "got %s", body)
	status, body = getWithSchema(client, baseURL+"/api/v2/sync/manifest", token, "")
	check("a missing schema cannot bypass the minimum", status == http.StatusConflict &&
		strings.Contains(string(body), "device_schema_outdated"), "got %d: %s", status, body)

	status, body = get(client, baseURL+"/api/v2/sync/pull?entity=products&after_seq=abc", token)
	check("an unreadable cursor is refused", status == http.StatusBadRequest, "got %d: %s", status, body)

	status, body = get(client, baseURL+"/api/v2/time", "")
	check("the clock endpoint is reachable without a token", status == http.StatusOK, "got %d", status)
	check("the clock endpoint answers with an object", isJSONObject(body), "got %s", firstBytes(body))

	// ---- plans and latency --------------------------------------------------

	var feedOutlet string
	if err := owner.QueryRow(ctx, syncfixture.FeedOutletSQL, tenantID).Scan(&feedOutlet); err != nil {
		return err
	}
	for _, e := range syncfeed.Entities() {
		if _, err := owner.Exec(ctx, "VACUUM (ANALYZE) "+e.Table); err != nil {
			return err
		}
		plan, err := feed.ExplainPull(ctx, tenantID, feedOutlet, e.Name, seededProducts-500, 500)
		if err != nil {
			return err
		}
		check(e.Name+" pull is an Index Only Scan", strings.Contains(plan, "Index Only Scan") &&
			strings.Contains(plan, e.Table+"_sync_feed_idx"), "plan:\n%s", plan)
	}

	rdb.Del(ctx, deviceKey)
	p50, p99 := measure(client, baseURL+"/api/v2/sync/changes", token, 100)
	fmt.Printf("  INFO  /sync/changes latency p50=%.2fms p99=%.2fms (warm cache, includes HTTP overhead)\n",
		float64(p50.Microseconds())/1000, float64(p99.Microseconds())/1000)

	return nil
}

// pullAll pages an entity to exhaustion, the way the till does, and refuses to
// accept the same row twice.
func pullAll(c *http.Client, baseURL, token, entity string) ([]map[string]any, error) {
	var (
		out    []map[string]any
		cursor int64
		ids    = map[string]bool{}
	)

	for page := 0; ; page++ {
		if page > 200 {
			return nil, fmt.Errorf("%s: paging is not terminating", entity)
		}

		url := fmt.Sprintf("%s/api/v2/sync/pull?entity=%s&after_seq=%d&limit=500", baseURL, entity, cursor)
		status, body := get(c, url, token)
		if status != http.StatusOK {
			return nil, fmt.Errorf("%s: pull returned %d: %s", entity, status, body)
		}
		if !isJSONObject(body) {
			return nil, fmt.Errorf("%s: pull body is not an object: %s", entity, firstBytes(body))
		}

		var decoded struct {
			Entity        string           `json:"entity"`
			Rows          []map[string]any `json:"rows"`
			NextSeq       int64            `json:"next_seq"`
			HasMore       bool             `json:"has_more"`
			SchemaVersion int              `json:"schema_version"`
		}
		if err := json.Unmarshal(body, &decoded); err != nil {
			return nil, fmt.Errorf("%s: decode page: %w", entity, err)
		}
		if decoded.Entity != entity {
			return nil, fmt.Errorf("%s: page claims to be %s", entity, decoded.Entity)
		}
		if decoded.NextSeq < cursor {
			return nil, fmt.Errorf("%s: cursor went backwards, %d then %d", entity, cursor, decoded.NextSeq)
		}

		for _, row := range decoded.Rows {
			if key := rowKey(row); key != "" {
				if ids[key] {
					return nil, fmt.Errorf("%s: row %s was delivered twice", entity, key)
				}
				ids[key] = true
			}
			out = append(out, row)
		}

		cursor = decoded.NextSeq
		if !decoded.HasMore {
			return out, nil
		}
	}
}

func rowKey(row map[string]any) string {
	if id, ok := row["id"].(string); ok {
		return id
	}
	// The join feeds are keyed by their pair rather than an id column.
	var parts []string
	for _, k := range []string{"table_id", "product_id", "group_id", "option_id", "promo_id", "outlet_id"} {
		if v, ok := row[k].(string); ok {
			parts = append(parts, v)
		}
	}
	return strings.Join(parts, "/")
}

func seedMerchant(ctx context.Context, owner *pgxpool.Pool) (tenantID, registerID string, err error) {
	slug := fmt.Sprintf("verify-sync-%d", time.Now().UnixNano())

	if err = owner.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Verify Sync', $1) RETURNING id`, slug).Scan(&tenantID); err != nil {
		return
	}

	var outletID string
	if err = owner.QueryRow(ctx,
		`INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Verify Outlet') RETURNING id`,
		tenantID).Scan(&outletID); err != nil {
		return
	}

	err = owner.QueryRow(ctx,
		`INSERT INTO pos_registers (tenant_id, outlet_id, name) VALUES ($1, $2, 'Kasir Verify') RETURNING id`,
		tenantID, outletID).Scan(&registerID)
	return
}

func clearLimiter(ctx context.Context, rdb *redis.Client) {
	iter := rdb.Scan(ctx, 0, "rl:*", 200).Iterator()
	for iter.Next(ctx) {
		rdb.Del(ctx, iter.Val())
	}
}

// isJSONObject is the assertion this script exists for. A top-level array or
// scalar in a 2xx body is what the till reads as malformed, and on the push
// path malformed deletes a queued sale.
func isJSONObject(body []byte) bool {
	var object map[string]json.RawMessage
	return json.Unmarshal(body, &object) == nil && object != nil
}

func firstBytes(body []byte) string {
	if len(body) > 120 {
		return string(body[:120]) + "…"
	}
	return string(body)
}

func keysOf(row map[string]any) []string {
	out := make([]string, 0, len(row))
	for k := range row {
		out = append(out, k)
	}
	slices.Sort(out)
	return out
}

func post(c *http.Client, url string, body map[string]any) (int, []byte) {
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader(string(raw)))
	req.Header.Set("Content-Type", "application/json")

	return send(c, req)
}

func get(c *http.Client, url, token string) (int, []byte) {
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	req.Header.Set("X-Schema-Version", fmt.Sprint(syncfeed.SchemaVersion))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	return send(c, req)
}

func getWithSchema(c *http.Client, url, token, schemaVersion string) (int, []byte) {
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Schema-Version", schemaVersion)

	return send(c, req)
}

func send(c *http.Client, req *http.Request) (int, []byte) {
	resp, err := c.Do(req)
	if err != nil {
		return 0, []byte(err.Error())
	}
	defer resp.Body.Close()

	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

func measure(c *http.Client, url, token string, n int) (p50, p99 time.Duration) {
	samples := make([]time.Duration, 0, n)

	for range n {
		start := time.Now()
		get(c, url, token)
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
