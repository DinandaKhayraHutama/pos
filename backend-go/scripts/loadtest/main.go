// Command loadtest is the Fase 9 harness: it simulates the full device
// lifecycle against a running server and checks the published targets.
//
// Targets come from the plan, derived from 5,000 outlets x 3 tills:
//
//	changes    2,000 rps on one instance at p99 < 20 ms
//	orders     200 orders/s at p99 < 300 ms, no tenant row lock, nothing lost
//	rush       15,000 tills starting inside ten minutes, spread off then on
//	fanout     one product changed, N tills pull: N index-only scans, no more
//	datascale  a large order history: reports read rollups, autovacuum keeps up
//
// What it deliberately does NOT do is bypass production behaviour: every
// measured request carries a real device token and passes the same
// middleware, auth cache and per-device rate limiter a tablet does. Only fleet
// PROVISIONING takes a shortcut, writing device rows directly rather than
// activating fifteen thousand tablets through the activation limiter.
//
// Usage, from backend-go with the environment loaded and a server running:
//
//	go run ./scripts/loadtest changes   --rate 2000 --duration 60s
//	go run ./scripts/loadtest orders    --orders-per-second 200 --duration 60s
//	go run ./scripts/loadtest rush      --devices 15000 --spread on
//	go run ./scripts/loadtest fanout    --devices 2000
//	go run ./scripts/loadtest datascale --orders 2000000
//	go run ./scripts/loadtest smoke
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

const usage = `usage: loadtest <scenario> [flags]

scenarios:
  changes     poll /sync/changes at a fixed rate (gate: 2,000 rps, p99 < 20 ms)
  orders      push receipts at a fixed rate (gate: 200 orders/s, p99 < 300 ms)
  rush        a morning of tills starting, with the startup spread off and on
  fanout      change one product and have the fleet pull it
  datascale   seed a large order history and report off the rollups
  smoke       one till, full lifecycle, seconds — for CI

common flags:
  --base-url     server to drive (default $VERIFY_BASE_URL or http://127.0.0.1:9000)
  --workers      concurrent in-flight requests (default 4x CPU)
  --json PATH    write the full result, including pg_stat_statements, as JSON
  --keep         leave the disposable merchant behind for inspection
  --pgstat       reset pg_stat_statements before the run and report the top 20`

type common struct {
	baseURL     string
	metricsURL  string
	workers     int
	jsonPath    string
	keep        bool
	pgstat      bool
	insecureTLS bool
}

func (c *common) bind(fs *flag.FlagSet) {
	fs.StringVar(&c.baseURL, "base-url", envOr("VERIFY_BASE_URL", "http://127.0.0.1:9000"), "server to drive")
	fs.IntVar(&c.workers, "workers", runtime.NumCPU()*4, "concurrent in-flight requests")
	fs.StringVar(&c.jsonPath, "json", "", "write the result as JSON to this path")
	fs.BoolVar(&c.keep, "keep", false, "leave the disposable merchant behind")
	fs.BoolVar(&c.pgstat, "pgstat", false, "reset pg_stat_statements and report the top 20 afterwards")
	fs.BoolVar(&c.insecureTLS, "insecure-tls", os.Getenv("VERIFY_INSECURE_TLS") == "1", "accept the local development certificate")
	fs.StringVar(&c.metricsURL, "metrics-url", envOr("LOAD_METRICS_URL", "http://127.0.0.1:9090/metrics"),
		"the server's own /metrics, read before and after a run to separate server-side latency from the generator's")
}

// env carries what every scenario needs: the three credentials, Redis, and the
// feed service that seeds a catalogue through the real write path.
type env struct {
	common
	owner *pgxpool.Pool
	pools pg.Pools
	feed  *syncfeed.Service
	rdb   *redis.Client
	// appKey must be the server's: it keys the activation code fingerprint, so
	// a code minted with a different one is simply never found.
	appKey string
	logger *slog.Logger
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}

	if err := run(os.Args[1], os.Args[2:]); err != nil {
		fmt.Fprintln(os.Stderr, "\nloadtest:", err)
		os.Exit(1)
	}
}

func run(scenario string, args []string) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	fs := flag.NewFlagSet(scenario, flag.ContinueOnError)
	var shared common
	shared.bind(fs)

	var (
		rate            float64
		duration        time.Duration
		deviceCount     int
		ordersPerSecond float64
		batch           int
		spread          string
		launch          string
		window          time.Duration
		burst           time.Duration
		catalogue       int
		seedOrders      int
		days            int
	)

	switch scenario {
	case "changes":
		fs.Float64Var(&rate, "rate", 2000, "requests per second")
		fs.DurationVar(&duration, "duration", time.Minute, "how long to hold the rate")
		fs.IntVar(&deviceCount, "devices", 2000, "tills in the fleet")
		fs.IntVar(&catalogue, "catalogue", 200, "rows seeded per feed")
	case "orders":
		fs.Float64Var(&ordersPerSecond, "orders-per-second", 200, "receipts per second")
		fs.DurationVar(&duration, "duration", time.Minute, "how long to hold the rate")
		fs.IntVar(&batch, "batch", 1, "receipts per push request; 1 is a till pushing as it sells, more is a till draining an offline queue")
		fs.IntVar(&deviceCount, "devices", 60, "tills in the fleet")
		fs.IntVar(&catalogue, "catalogue", 200, "rows seeded per feed")
	case "rush":
		fs.IntVar(&deviceCount, "devices", 15000, "tills starting up")
		fs.DurationVar(&window, "window", 10*time.Minute, "how long the tills take to open")
		fs.StringVar(&spread, "spread", "both", "startup spread: on, off or both")
		fs.StringVar(&launch, "launch", "burst", "when tills open: burst (clustered at the top of the hour) or uniform")
		fs.DurationVar(&burst, "launch-burst", time.Minute, "how tightly openings cluster in launch=burst")
		fs.IntVar(&catalogue, "catalogue", 200, "rows seeded per feed")
	case "fanout":
		fs.IntVar(&deviceCount, "devices", 2000, "tills pulling the change")
		fs.IntVar(&catalogue, "catalogue", 5000, "rows seeded per feed")
	case "datascale":
		fs.IntVar(&seedOrders, "orders", 2_000_000, "receipts to seed")
		fs.IntVar(&days, "days", 30, "business days to spread them over")
		fs.IntVar(&deviceCount, "devices", 6, "tills, one per branch")
		fs.IntVar(&catalogue, "catalogue", 200, "rows seeded per feed")
	case "smoke":
		fs.IntVar(&deviceCount, "devices", 3, "tills in the fleet")
		fs.IntVar(&catalogue, "catalogue", 20, "rows seeded per feed")
	default:
		fmt.Fprintln(os.Stderr, usage)
		return fmt.Errorf("unknown scenario %q", scenario)
	}

	if err := fs.Parse(args); err != nil {
		return err
	}

	e, closeEnv, err := openEnv(ctx, shared)
	if err != nil {
		return err
	}
	defer closeEnv()

	var result *Result
	switch scenario {
	case "changes":
		result, err = runChanges(ctx, e, changesOptions{rate: rate, duration: duration, devices: deviceCount, catalogue: catalogue})
	case "orders":
		result, err = runOrders(ctx, e, ordersOptions{perSecond: ordersPerSecond, duration: duration, batch: batch, devices: deviceCount, catalogue: catalogue})
	case "rush":
		result, err = runRush(ctx, e, rushOptions{devices: deviceCount, window: window, burst: burst, spread: spread, launch: launch, catalogue: catalogue})
	case "fanout":
		result, err = runFanout(ctx, e, fanoutOptions{devices: deviceCount, catalogue: catalogue})
	case "datascale":
		result, err = runDataScale(ctx, e, dataScaleOptions{orders: seedOrders, days: days, devices: deviceCount, catalogue: catalogue})
	case "smoke":
		result, err = runSmoke(ctx, e, smokeOptions{devices: deviceCount, catalogue: catalogue})
	}
	if result == nil {
		return err
	}

	result.Environment["base_url"] = shared.baseURL
	result.Environment["go"] = runtime.Version()
	result.Environment["cpus"] = fmt.Sprint(runtime.NumCPU())
	result.Environment["generator"] = "same host as the server unless stated otherwise"
	result.Environment["redis"] = redisState(ctx, e)
	result.print()
	if writeErr := result.writeJSON(shared.jsonPath); writeErr != nil {
		fmt.Fprintln(os.Stderr, "write JSON:", writeErr)
	}

	if err != nil {
		return err
	}
	if result.failed() {
		return errors.New("one or more gates were not met")
	}
	if ctx.Err() != nil {
		return errors.New("interrupted before the run finished")
	}
	fmt.Println("\nall gates met")
	return nil
}

func openEnv(ctx context.Context, shared common) (*env, func(), error) {
	ownerURL := os.Getenv("MIGRATE_DATABASE_URL")
	if ownerURL == "" {
		return nil, nil, errors.New("MIGRATE_DATABASE_URL is required: the harness creates and removes a disposable merchant")
	}

	// The harness seeds and inspects with connections of its own, so give it
	// headroom without letting it crowd the server out of the database.
	owner, err := pg.Open(ctx, ownerURL, pg.Limits{MaxConns: 16, MinConns: 2})
	if err != nil {
		return nil, nil, err
	}
	pools, err := pg.OpenPools(ctx, os.Getenv("DATABASE_URL"), os.Getenv("UNSCOPED_DATABASE_URL"),
		pg.Limits{MaxConns: 8, MinConns: 1})
	if err != nil {
		owner.Close()
		return nil, nil, err
	}
	rdb, err := redisx.Open(ctx, os.Getenv("REDIS_URL"))
	if err != nil {
		owner.Close()
		pools.Close()
		return nil, nil, err
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	e := &env{
		common: shared, owner: owner, pools: pools,
		feed: syncfeed.NewService(pools, rdb, logger), rdb: rdb, appKey: os.Getenv("APP_KEY"), logger: logger,
	}

	return e, func() {
		rdb.Close()
		pools.Close()
		owner.Close()
	}, nil
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

// redisState is recorded with every result because it changes what the numbers
// mean. The plan asks for one scenario with Redis stopped, to know the
// degraded ceiling as a number rather than a hope — and a run whose cache was
// quietly down would otherwise look like a regression.
func redisState(ctx context.Context, e *env) string {
	if e.rdb == nil {
		return "not configured"
	}
	if err := e.rdb.Ping(ctx).Err(); err != nil {
		return "DOWN — auth, rate limiting and the watermark cache all fell through to PostgreSQL"
	}
	return "up"
}
