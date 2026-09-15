// Package redisx holds the Redis client and the things that legitimately live
// in it.
//
// The rule: if flushing Redis on a live system would cause anything worse than
// a slowdown or a re-login, it does not belong here. Orders, sessions, the
// stock ledger, sync_seq allocation and idempotency records are all excluded by
// that test — they live in PostgreSQL.
package redisx

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

func Open(ctx context.Context, url string) (*redis.Client, error) {
	opts, err := redis.ParseURL(url)
	if err != nil {
		return nil, fmt.Errorf("parse redis url: %w", err)
	}

	// Redis is optional at boot as well as during a request. Bound each failed
	// attempt so fallback does not inherit multiple seconds of retry latency.
	opts.DialTimeout = 200 * time.Millisecond
	opts.ReadTimeout = 200 * time.Millisecond
	opts.WriteTimeout = 200 * time.Millisecond
	opts.MaxRetries = -1
	return redis.NewClient(opts), nil
}
