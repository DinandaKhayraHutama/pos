package devices

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/store/unscoped"
	"github.com/jackc/pgx/v5"
	"github.com/redis/go-redis/v9"
)

const cacheTTL = 5 * time.Minute

type cacheEntry struct {
	Binding     Binding `json:"b"`
	TenantGen   int64   `json:"gt"`
	OutletGen   int64   `json:"go"`
	RegisterGen int64   `json:"gr"`
}

// CachedAuthenticator front-ends Authenticate with Redis.
//
// Without it every authenticated request re-reads the whole chain
// (device → tenant → outlet → register) from PostgreSQL, which with 15,000
// tills polling is the heaviest query in the system.
//
// Invalidation is by generation counter, never by enumerating keys: an entry
// records the database generations it was built from. Mutations publish a newer
// version monotonically; a stale cache fill cannot adopt that newer version.
//
// Every Redis failure falls through to PostgreSQL. It never fails open: a cache
// outage must cost latency, not authentication.
type CachedAuthenticator struct {
	svc      *Service
	rdb      *redis.Client
	logger   *slog.Logger
	observer CacheObserver
}

// CacheObserver counts where each binding came from: "hit", "miss" (nothing
// cached), "stale" (cached, but a generation had moved) or "error" (Redis
// answered neither). The interface is declared here rather than taking the
// metrics package, so the domain keeps no opinion about Prometheus.
type CacheObserver interface {
	AuthCache(result string)
}

type CacheOption func(*CachedAuthenticator)

// WithCacheObserver is how the serving process attaches metrics. It is an
// option rather than a parameter because every test and script constructs this
// wrapper and none of them measure anything.
func WithCacheObserver(o CacheObserver) CacheOption {
	return func(c *CachedAuthenticator) { c.observer = o }
}

func NewCachedAuthenticator(svc *Service, rdb *redis.Client, logger *slog.Logger, opts ...CacheOption) *CachedAuthenticator {
	c := &CachedAuthenticator{svc: svc, rdb: rdb, logger: logger}
	for _, opt := range opts {
		opt(c)
	}
	return c
}

func (c *CachedAuthenticator) observe(result string) {
	if c.observer != nil {
		c.observer.AuthCache(result)
	}
}

func (c *CachedAuthenticator) Authenticate(ctx context.Context, plainToken string) (Binding, error) {
	key := tokenKey(plainToken)

	if b, ok := c.cached(ctx, key); ok {
		return b, nil
	}

	b, err := c.svc.Authenticate(ctx, plainToken)
	if err != nil {
		return Binding{}, err
	}

	c.store(ctx, key, b)
	return b, nil
}

// Activate rotates the device's token, which means every binding cached
// against the PREVIOUS token must stop being servable at once.
//
// The register's generation is bumped rather than the old entry deleted:
// finding that entry would mean reading the old hash before overwriting it, and
// one version publication invalidates everything derived from this register. Sibling
// tills on the same register pay one extra database read — cheaper than a
// credential that outlives its own replacement.
func (c *CachedAuthenticator) Activate(ctx context.Context, in ActivateInput) (Activation, error) {
	activation, err := c.svc.Activate(ctx, in)
	if err != nil {
		return Activation{}, err
	}

	c.Bump(ctx, "register", activation.Register.ID)

	return activation, nil
}

// Revoke clears the device's own entry as well as bumping the register, so a
// stolen tablet stops working now rather than when the entry expires.
func (c *CachedAuthenticator) Revoke(ctx context.Context, tenantID, deviceID string) error {
	revoked, err := c.svc.Revoke(ctx, tenantID, deviceID)
	if err != nil {
		return err
	}

	if len(revoked.TokenHash) > 0 {
		c.forget(ctx, "dev:"+hex.EncodeToString(revoked.TokenHash))
	}
	c.Bump(ctx, "register", revoked.RegisterID)

	return nil
}

// InvalidateRevoked publishes a revocation already committed by another
// domain transaction, such as controlled till takeover.
func (c *CachedAuthenticator) InvalidateRevoked(ctx context.Context, tokenHash []byte, registerID string) {
	if len(tokenHash) > 0 {
		c.forget(ctx, "dev:"+hex.EncodeToString(tokenHash))
	}
	c.Bump(ctx, "register", registerID)
}

// seenInterval bounds how often one tablet's last_seen_at is written: at most
// once per interval, so 15,000 tills polling cost about fifty small writes a
// second rather than one write per request.
const seenInterval = 5 * time.Minute

// Touch records that an authenticated tablet was seen, for the platform's
// "seen in the last five minutes". Advisory, so it never fails the request.
//
// Redis decides whether this request is the one that writes: SET NX with the
// interval as its TTL. When Redis is unreachable nothing is written, rather
// than writing on every request — a cache outage must not turn into a write
// storm. Only last_seen_at is touched, never updated_at: updated_at feeds the
// device revision, and moving it would send every till to /devices/me every
// five minutes. The device_auth_version trigger ignores this column too, so the
// auth cache is not invalidated either.
func (c *CachedAuthenticator) Touch(ctx context.Context, b Binding) {
	key := "seen:" + b.Device.ID
	first, err := c.rdb.SetNX(ctx, key, 1, seenInterval).Result()
	if err != nil || !first {
		return
	}

	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 500*time.Millisecond)
	defer cancel()
	err = pg.InTenantTx(ctx, c.svc.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		_, err := tx.Exec(ctx,
			`UPDATE devices SET last_seen_at = now() WHERE tenant_id = $1 AND id = $2`, b.Tenant.ID, b.Device.ID)
		return err
	})
	if err != nil {
		// The next interval tries again; clearing the key here would retry on
		// every request while the database is struggling.
		c.logger.Warn("record device last seen", slog.String("device_id", b.Device.ID), slog.Any("error", err))
	}
}

// Bump invalidates every cached binding derived from one tenant, outlet or
// register. Call it whenever one of those stops being usable.
func (c *CachedAuthenticator) Bump(ctx context.Context, kind, id string) {
	// Request cancellation after commit must not cancel cache invalidation.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), time.Second)
	defer cancel()
	table, ok := map[string]string{"tenant": "tenants", "outlet": "outlets", "register": "pos_registers"}[kind]
	if !ok {
		return
	}
	var generation int64
	err := unscoped.Tx(ctx, c.svc.pools.Unscoped, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, "SELECT auth_generation FROM "+table+" WHERE id = $1", id).Scan(&generation)
	})
	if err == nil {
		err = authGenerationSet.Run(ctx, c.rdb, []string{"gen:" + kind + ":" + id}, generation, int(cacheTTL.Seconds())).Err()
	}
	if err != nil {
		// The entry still expires on its own, so this degrades rather than
		// breaks — but it is worth knowing about.
		c.logger.Error("bump auth cache generation",
			slog.String("kind", kind), slog.String("id", id), slog.Any("error", err))
	}
}

func (c *CachedAuthenticator) cached(ctx context.Context, key string) (Binding, bool) {
	raw, err := c.rdb.Get(ctx, key).Bytes()
	if err != nil {
		// A key that is simply absent is the ordinary cold path; anything else
		// means Redis itself is answering badly, and the two want different
		// reactions from whoever is reading the dashboard.
		if errors.Is(err, redis.Nil) {
			c.observe("miss")
		} else {
			c.observe("error")
		}
		return Binding{}, false
	}

	var entry cacheEntry
	if err := json.Unmarshal(raw, &entry); err != nil || entry.Binding.ExpiresAtMs <= time.Now().UnixMilli() {
		c.observe("stale")
		return Binding{}, false
	}

	gens, err := c.generations(ctx, entry.Binding)
	if err != nil {
		c.observe("error")
		return Binding{}, false
	}

	if gens[0] != entry.TenantGen || gens[1] != entry.OutletGen || gens[2] != entry.RegisterGen {
		c.observe("stale")
		return Binding{}, false
	}

	c.observe("hit")
	return entry.Binding, true
}

func (c *CachedAuthenticator) store(ctx context.Context, key string, b Binding) {
	deadline := time.UnixMilli(b.CacheReadAtMs).Add(cacheTTL)
	ttl := min(time.Until(deadline), time.Until(time.UnixMilli(b.ExpiresAtMs)))
	if ttl <= 0 {
		return
	}
	// Use ONLY the generations returned alongside the PostgreSQL binding.
	// Publishing an older version cannot overwrite an already-published revoke.
	gens := b.AuthGenerations
	for i, k := range generationKeys(b) {
		if gens[i] < 1 {
			return
		}
		if err := authGenerationSet.Run(ctx, c.rdb, []string{k}, gens[i], int(cacheTTL.Seconds())).Err(); err != nil {
			return
		}
	}

	raw, err := json.Marshal(cacheEntry{
		Binding: b, TenantGen: gens[0], OutletGen: gens[1], RegisterGen: gens[2],
	})
	if err != nil {
		return
	}

	ttl = min(time.Until(deadline), time.Until(time.UnixMilli(b.ExpiresAtMs)))
	if ttl <= 0 {
		return
	}
	if err := c.rdb.Set(ctx, key, raw, ttl).Err(); err != nil {
		c.logger.Warn("store auth cache entry", slog.Any("error", err))
	}
}

func (c *CachedAuthenticator) forget(ctx context.Context, key string) {
	if err := c.rdb.Del(ctx, key).Err(); err != nil {
		c.logger.Warn("drop auth cache entry", slog.Any("error", err))
	}
}

// generations reads all three counters in one round trip. Missing keys are
// cache misses, not generation zero: PostgreSQL must revalidate the binding.
func (c *CachedAuthenticator) generations(ctx context.Context, b Binding) ([3]int64, error) {
	vals, err := c.rdb.MGet(ctx, generationKeys(b)...).Result()
	if err != nil {
		return [3]int64{}, err
	}

	var gens [3]int64
	for i, v := range vals {
		s, ok := v.(string)
		if !ok {
			return [3]int64{}, fmt.Errorf("auth generation cache miss")
		}
		gens[i], err = strconv.ParseInt(s, 10, 64)
		if err != nil || gens[i] < 1 {
			return [3]int64{}, fmt.Errorf("invalid auth generation")
		}
	}

	return gens, nil
}

func generationKeys(b Binding) []string {
	return []string{"gen:tenant:" + b.Tenant.ID, "gen:outlet:" + b.Outlet.ID, "gen:register:" + b.Register.ID}
}

// Decimal strings avoid Lua's floating-point rounding above 2^53. TTLs are
// refreshed only for a NEW version: stale cache fills cannot extend a lease.
var authGenerationSet = redis.NewScript(`
local old = redis.call('GET', KEYS[1])
local new = ARGV[1]
if not old or #new > #old or (#new == #old and new > old) then
  redis.call('SET', KEYS[1], new, 'EX', ARGV[2])
end
return 1
`)

func tokenKey(plainToken string) string {
	return "dev:" + hex.EncodeToString(HashToken(plainToken))
}
