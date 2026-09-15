package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"github.com/pressly/goose/v3/lock"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/stock"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/tenancy"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/config"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/jobs"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/logging"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/media"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
	"github.com/daniryckidinata/nti_pos/backend-go/migrations"
)

const usage = `usage:
  justclick serve                 run the API and Backoffice
  justclick worker                run River maintenance, report rollups and exports
  justclick migrate up            apply pending migrations
  justclick migrate down          roll back the last migration
  justclick migrate status        show migration state
  justclick tenant create [flags] onboard a merchant and its first Owner
  justclick roles set-password    set credentials for the two login roles,
                                  from APP_DB_PASSWORD and UNSCOPED_DB_PASSWORD`

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "fatal:", err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) < 2 {
		return errors.New(usage)
	}

	cfg, err := config.Load()
	if err != nil {
		return err
	}
	logger := logging.New(cfg.LogLevel)

	switch os.Args[1] {
	case "serve":
		return serve(cfg, logger)
	case "worker":
		return worker(cfg, logger)
	case "migrate":
		if len(os.Args) < 3 {
			return errors.New(usage)
		}
		return migrate(cfg, os.Args[2])
	case "tenant":
		if len(os.Args) < 3 || os.Args[2] != "create" {
			return errors.New(usage)
		}
		return createTenant(cfg, os.Args[3:])
	case "roles":
		if len(os.Args) < 3 || os.Args[2] != "set-password" {
			return errors.New(usage)
		}
		return setRolePasswords(cfg)
	default:
		return errors.New(usage)
	}
}

func worker(cfg config.Config, logger *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	pools, err := openPools(ctx, cfg)
	if err != nil {
		return err
	}
	defer pools.Close()
	// The worker holds no Redis: a reconcile repair publishes no watermark, and
	// the key it would have raised expires within minutes.
	reconciler := stock.NewService(pools, syncfeed.NewService(pools, nil, logger))
	reports, err := newReports(cfg, pools, logger)
	if err != nil {
		return err
	}
	client, err := jobs.NewWorker(pools.Unscoped, logger, jobs.WorkerDeps{Stock: reconciler, Reports: reports})
	if err != nil {
		return err
	}
	if err := client.Start(ctx); err != nil {
		return err
	}
	<-ctx.Done()
	drain, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return client.Stop(drain)
}

func openPools(ctx context.Context, cfg config.Config) (pg.Pools, error) {
	return pg.OpenPools(ctx, cfg.DatabaseURL, cfg.UnscopedDatabaseURL)
}

// setRolePasswords gives the two login roles their credentials. Passwords live
// in the environment rather than in a migration, because a migration is
// version control.
func setRolePasswords(cfg config.Config) error {
	migrateURL, err := cfg.RequireMigrateURL()
	if err != nil {
		return err
	}

	appPassword, crossPassword := os.Getenv("APP_DB_PASSWORD"), os.Getenv("UNSCOPED_DB_PASSWORD")
	if appPassword == "" || crossPassword == "" {
		return errors.New("set APP_DB_PASSWORD and UNSCOPED_DB_PASSWORD before running this")
	}

	ctx := context.Background()
	pool, err := pg.Open(ctx, migrateURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	for _, role := range []struct{ name, password string }{
		{pg.AppRole, appPassword},
		{pg.UnscopedRole, crossPassword},
	} {
		// ALTER ROLE ... PASSWORD accepts no bind parameters, so PostgreSQL is
		// asked to build the statement with format(%I, %L) and it is executed
		// as returned. That keeps the quoting rules in the one place that
		// actually knows them.
		var stmt string
		if err := pool.QueryRow(ctx,
			`SELECT format('ALTER ROLE %I PASSWORD %L', $1::text, $2::text)`,
			role.name, role.password,
		).Scan(&stmt); err != nil {
			return fmt.Errorf("build password statement for %s: %w", role.name, err)
		}

		if _, err := pool.Exec(ctx, stmt); err != nil {
			return fmt.Errorf("set password for %s: %w", role.name, err)
		}

		fmt.Printf("password set for %s\n", role.name)
	}

	return nil
}

func createTenant(cfg config.Config, args []string) error {
	fs := flag.NewFlagSet("tenant create", flag.ContinueOnError)
	name := fs.String("name", "", "business name")
	slug := fs.String("slug", "", "url-safe identifier, unique across the platform")
	ownerName := fs.String("owner-name", "", "the first Owner's name")
	ownerEmail := fs.String("owner-email", "", "the first Owner's email, unique across the platform")
	password := fs.String("password", "", "omit to generate one and print it exactly once")

	if err := fs.Parse(args); err != nil {
		return err
	}

	plain := *password
	generated := plain == ""
	if generated {
		var err error
		// Generated rather than typed on the command line by default: an
		// argument lands in shell history, which is a durable place for a live
		// credential to sit.
		if plain, err = randomPassword(); err != nil {
			return err
		}
	}

	in := tenancy.Input{
		BusinessName:  *name,
		Slug:          *slug,
		OwnerName:     *ownerName,
		OwnerEmail:    *ownerEmail,
		OwnerPassword: plain,
	}
	if err := tenancy.ValidateInput(in); err != nil {
		return err
	}

	ctx := context.Background()
	pools, err := openPools(ctx, cfg)
	if err != nil {
		return err
	}
	defer pools.Close()

	result, err := tenancy.Provision(ctx, pools, in)
	if err != nil {
		return err
	}

	fmt.Printf("merchant created\n  tenant id : %s\n  owner id  : %s\n  sign in as: %s\n",
		result.TenantID, result.OwnerID, in.OwnerEmail)

	if generated {
		fmt.Printf("  password  : %s\n\nThis password is shown once and is not stored anywhere in plaintext.\n", plain)
	}

	return nil
}

func randomPassword() (string, error) {
	const alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"

	buf := make([]byte, 20)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}

	out := make([]byte, len(buf))
	for i, b := range buf {
		out[i] = alphabet[int(b)%len(alphabet)]
	}

	return string(out), nil
}

func serve(cfg config.Config, logger *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pools, err := openPools(ctx, cfg)
	if err != nil {
		return err
	}
	defer pools.Close()

	rdb, err := redisx.Open(ctx, cfg.RedisURL)
	if err != nil {
		return err
	}
	defer rdb.Close()

	mediaBase, err := cfg.MediaBaseURL()
	if err != nil {
		return err
	}
	store, err := media.Open(cfg.MediaDir, mediaBase)
	if err != nil {
		return err
	}

	reports, err := newReports(cfg, pools, logger)
	if err != nil {
		return err
	}

	sessionDB, err := sql.Open("pgx", cfg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("open session store: %w", err)
	}
	defer sessionDB.Close()

	srv := &http.Server{
		Addr: cfg.HTTPAddr,
		Handler: httpapi.NewRouter(httpapi.Deps{
			TrustProxy: cfg.TrustProxy,
			Pools:      pools,
			SessionDB:  sessionDB,
			Redis:      rdb,
			Logger:     logger,
			AppKey:     cfg.AppKey,
			// Everywhere but a developer's own machine is served over TLS, and
			// a session cookie without Secure there is one sent in the clear.
			SecureCookies:    cfg.Environment != "local",
			SyncPollInterval: cfg.SyncPollInterval,
			Media:            store,
			Reports:          reports,
		}),
		ReadHeaderTimeout: 10 * time.Second,
	}

	errc := make(chan error, 1)
	go func() {
		logger.Info("api listening", slog.String("addr", cfg.HTTPAddr), slog.String("env", cfg.Environment))
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errc <- err
		}
	}()

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}

	// Tills are offline-tolerant, so a drain this long costs nobody a sale.
	logger.Info("shutting down, draining for up to 30s")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	return srv.Shutdown(shutdownCtx)
}

func migrate(cfg config.Config, command string) error {
	migrateURL, err := cfg.RequireMigrateURL()
	if err != nil {
		return err
	}

	db, err := sql.Open("pgx", migrateURL)
	if err != nil {
		return fmt.Errorf("open database: %w", err)
	}
	defer db.Close()

	locker, err := lock.NewPostgresSessionLocker()
	if err != nil {
		return err
	}
	provider, err := goose.NewProvider(goose.DialectPostgres, db, migrations.FS, goose.WithSessionLocker(locker), goose.WithGoMigrations(migrations.GoMigrations()...))
	if err != nil {
		return err
	}
	ctx := context.Background()

	switch command {
	case "up":
		_, err := provider.Up(ctx)
		return err
	case "down":
		_, err := provider.Down(ctx)
		return err
	case "status":
		statuses, err := provider.Status(ctx)
		for _, s := range statuses {
			fmt.Printf("%v\n", s)
		}
		return err
	default:
		return fmt.Errorf("unknown migrate command %q", command)
	}
}
