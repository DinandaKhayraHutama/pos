package redisx

import (
	"context"
	"time"

	"github.com/redis/go-redis/v9"
)

// tokenBucket refills continuously rather than resetting on a window boundary,
// so a caller cannot spend a full allowance at 11:59:59 and another at
// 12:00:00. Redis evaluates it atomically, so concurrent requests on different
// API instances cannot both read the same remaining count.
var tokenBucket = redis.NewScript(`
local key      = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill   = tonumber(ARGV[2])
local now      = tonumber(ARGV[3])

local state   = redis.call('HMGET', key, 'tokens', 'at')
local tokens  = tonumber(state[1])
local last    = tonumber(state[2])

if tokens == nil then
  tokens = capacity
  last   = now
end

tokens = math.min(capacity, tokens + (now - last) * refill)

local allowed = 0
if tokens >= 1 then
  tokens  = tokens - 1
  allowed = 1
end

-- Keep the bucket only as long as it takes to refill completely; a full bucket
-- is indistinguishable from an absent one.
local ttl = math.ceil(capacity / refill) + 1
redis.call('HSET', key, 'tokens', tokens, 'at', now)
redis.call('EXPIRE', key, ttl)

local retry = 0
if allowed == 0 then
  retry = math.ceil((1 - tokens) / refill)
end

return {allowed, retry}
`)

type Limit struct {
	Burst  int
	Window time.Duration
}

// Allow reports whether this call may proceed, and how long to wait if not.
//
// A Redis failure allows the call: losing the limiter costs one unthrottled
// window, while failing closed would take the whole till fleet offline over a
// cache outage.
func Allow(ctx context.Context, rdb *redis.Client, key string, limit Limit) (ok bool, retryAfter time.Duration) {
	refill := float64(limit.Burst) / limit.Window.Seconds()

	res, err := tokenBucket.Run(ctx, rdb, []string{"rl:" + key},
		limit.Burst, refill, float64(time.Now().UnixMilli())/1000).Slice()
	if err != nil {
		return true, 0
	}

	allowed, _ := res[0].(int64)
	retry, _ := res[1].(int64)

	if allowed == 1 {
		return true, 0
	}
	return false, time.Duration(retry) * time.Second
}
