package syncfeed

import (
	"context"
	"log/slog"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/redis/go-redis/v9"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// watermarkTTL bounds how long a lost write can lie.
//
// The value in Redis is a cache of sync_counters, which is authoritative. A
// publish that never lands leaves the key reading LOW, and a low watermark is
// the one direction that actually hurts: a till compares it against its own
// cursor, sees no change, and does not pull. Expiry is what turns that from
// permanent into bounded — after this the key is gone and PostgreSQL answers.
const watermarkTTL = 5 * time.Minute

func watermarkKey(scopeKey string) string { return "hwm:" + scopeKey }

// watermarkSet never lowers a value.
//
// Two API instances can publish out of order — the one that committed second
// is not guaranteed to reach Redis second — and a plain SET would let the older
// number win. Redis evaluates this atomically, so the comparison cannot be
// raced either.
var watermarkSet = redis.NewScript(`
local key = KEYS[1]
local val = ARGV[1]
local ttl = tonumber(ARGV[2])

local cur = redis.call('GET', key)
if cur == false or #val > #cur or (#val == #cur and val > cur) then
  redis.call('SET', key, val, 'EX', ttl)
end

return 1
`)

// Publish records a scope's new high-water mark, AFTER the transaction that
// allocated it has committed.
//
// Called before the commit it would advertise rows nobody can read yet, and a
// device that pulled in that window would move its cursor past them.
//
// A failure here deletes the key rather than leaving it behind: degrading to
// "ask PostgreSQL" costs one query, where degrading to "a number that is quietly
// too low" costs a till the rows it never learns about.
//
// A service built without Redis (the worker, some tests) publishes nothing;
// keys it would have raised expire within watermarkTTL.
func (s *Service) Publish(ctx context.Context, scopeKey string, seq int64) {
	if s.rdb == nil {
		return
	}

	err := watermarkSet.Run(ctx, s.rdb,
		[]string{watermarkKey(scopeKey)}, seq, int(watermarkTTL.Seconds())).Err()
	if err == nil {
		return
	}

	s.logger.Warn("publish sync watermark",
		slog.String("scope", scopeKey), slog.Int64("seq", seq), slog.Any("error", err))

	if delErr := s.rdb.Del(ctx, watermarkKey(scopeKey)).Err(); delErr != nil {
		// Redis is unreachable, which means the read path is falling back to
		// PostgreSQL anyway. Nothing further to do.
		s.logger.Debug("drop stale sync watermark", slog.Any("error", delErr))
	}
}

type feedScope struct{ name, key string }

// scopesFor lists every feed a reader sees, with the counter each is read from.
// Outlet feeds are included only when an outlet is named.
func scopesFor(tenantID, outletID string) []feedScope {
	all := Entities()
	out := make([]feedScope, 0, len(all))
	for _, e := range all {
		if e.Scope == ScopeOutlet && outletID == "" {
			continue
		}
		out = append(out, feedScope{name: e.Name, key: scopeKeyFor(e, tenantID, outletID)})
	}
	return out
}

// Cursors is every COMPANY feed's current mark for a merchant.
func (s *Service) Cursors(ctx context.Context, tenantID string) (map[string]int64, error) {
	return s.cursors(ctx, tenantID, scopesFor(tenantID, ""))
}

// DeviceCursors is the fast path behind /sync/changes: every feed a till in
// outletID reads — the company feeds and that branch's outlet feeds — in one
// Redis round trip when the cache is warm.
func (s *Service) DeviceCursors(ctx context.Context, tenantID, outletID string) (map[string]int64, error) {
	return s.cursors(ctx, tenantID, scopesFor(tenantID, outletID))
}

// cursors serves a set of marks from Redis, or all of them from PostgreSQL.
//
// A single miss sends the whole set to PostgreSQL rather than mixing sources.
// A missing key is indistinguishable from "never written", and treating it as
// zero next to warm neighbours would tell a till that a feed it has rows from
// is empty.
func (s *Service) cursors(ctx context.Context, tenantID string, scopes []feedScope) (map[string]int64, error) {
	if cached, ok := s.cachedCursors(ctx, scopes); ok {
		return cached, nil
	}

	fresh, err := s.cursorsFromPostgres(ctx, tenantID, scopes)
	if err != nil {
		return nil, err
	}

	// Caches what PostgreSQL just answered, including the zeroes: a merchant
	// with no promos should not send a query to PostgreSQL on every poll for
	// the rest of its life.
	for _, sc := range scopes {
		s.Publish(ctx, sc.key, fresh[sc.name])
	}

	return fresh, nil
}

func (s *Service) cachedCursors(ctx context.Context, scopes []feedScope) (map[string]int64, bool) {
	if s.rdb == nil {
		return nil, false
	}

	keys := make([]string, 0, len(scopes))
	for _, sc := range scopes {
		keys = append(keys, watermarkKey(sc.key))
	}

	vals, err := s.rdb.MGet(ctx, keys...).Result()
	if err != nil || len(vals) != len(scopes) {
		return nil, false
	}

	out := make(map[string]int64, len(scopes))
	for i, v := range vals {
		raw, ok := v.(string)
		if !ok {
			return nil, false
		}
		seq, err := strconv.ParseInt(raw, 10, 64)
		if err != nil {
			return nil, false
		}
		out[scopes[i].name] = seq
	}

	return out, true
}

func (s *Service) cursorsFromPostgres(ctx context.Context, tenantID string, scopes []feedScope) (map[string]int64, error) {
	keys := make([]string, 0, len(scopes))
	for _, sc := range scopes {
		keys = append(keys, sc.key)
	}

	var marks map[string]int64
	err := pg.InTenantTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		marks, err = counters(ctx, tx, keys)
		return err
	})
	if err != nil {
		return nil, err
	}

	out := make(map[string]int64, len(scopes))
	for _, sc := range scopes {
		// Absent means nothing of this kind has ever been written, which is a
		// cursor of zero, not a missing key the client has to interpret.
		out[sc.name] = marks[sc.key]
	}

	return out, nil
}
