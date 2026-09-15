// Package pgtest gives each test its own database, cloned from a migrated
// template.
//
// Tests run against real PostgreSQL, never SQLite. The invariants this system
// depends on — RLS policies, partial unique indexes, composite foreign keys —
// either do not exist on SQLite or behave differently there, so a green SQLite
// suite would prove nothing about production.
package pgtest

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/migrations"
)

// Package test binaries run in parallel, so template creation is guarded by a
// PostgreSQL advisory lock rather than sync.Once, which is only per-process.
const templateLockKey = 0x6a63_7431

var (
	buildOnce    sync.Once
	buildErr     error
	templateName string
	unsafeChars  = regexp.MustCompile(`[^a-z0-9_]`)
)

// DB is a throwaway database plus the credentials a test needs.
type DB struct {
	// Owner connects as the database owner. Tests seed through it and assert
	// through it, the way a platform tool would.
	Owner *pgxpool.Pool
	// Pools is what a service under test receives, and it is the same split the
	// running server uses: a tenant credential that CANNOT bypass row-level
	// security, and an escape hatch that deliberately can. Handing a service
	// the owner pool instead would make every RLS assertion vacuous.
	Pools pg.Pools
}

// New returns a throwaway database that is dropped when the test ends.
func New(t *testing.T) DB {
	t.Helper()

	// The owner credential, because cloning a template database is DDL. The
	// application credentials below deliberately cannot do this.
	base := os.Getenv("MIGRATE_DATABASE_URL")
	if base == "" {
		t.Fatal("MIGRATE_DATABASE_URL is not set; these tests need the owner credential to clone a database")
	}

	buildOnce.Do(func() { buildErr = ensureTemplate(base) })
	if buildErr != nil {
		t.Fatalf("build template database: %v", buildErr)
	}

	prefix := unsafeChars.ReplaceAllString(strings.ToLower(t.Name()), "_")
	if len(prefix) > 40 {
		prefix = prefix[:40]
	}
	// Keep the random suffix even for long/subtest names and overlapping runs.
	name := fmt.Sprintf("jc_%s_%x", prefix, randBytes(t))

	if err := adminExec(base, fmt.Sprintf("CREATE DATABASE %q TEMPLATE %q", name, templateName)); err != nil {
		t.Fatalf("clone template: %v", err)
	}

	ctx := context.Background()

	owner := connect(t, ctx, withDatabase(base, name))
	db := DB{
		Owner: owner,
		Pools: pg.Pools{
			Tenant:   connect(t, ctx, asRole(base, name, pg.AppRole, "APP_DB_PASSWORD")),
			Unscoped: connect(t, ctx, asRole(base, name, pg.UnscopedRole, "UNSCOPED_DB_PASSWORD")),
		},
	}

	// The harness itself is worth checking: if it ever hands a service an
	// over-privileged credential, every isolation test in the suite quietly
	// stops testing anything.
	if err := pg.AssertPools(ctx, db.Pools); err != nil {
		t.Fatalf("test pools are misconfigured: %v", err)
	}

	t.Cleanup(func() {
		db.Pools.Close()
		owner.Close()
		if err := adminExec(base, fmt.Sprintf("DROP DATABASE IF EXISTS %q WITH (FORCE)", name)); err != nil {
			t.Logf("drop %s: %v", name, err)
		}
	})

	return db
}

func randBytes(t *testing.T) []byte {
	t.Helper()
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

func connect(t *testing.T, ctx context.Context, dsn string) *pgxpool.Pool {
	t.Helper()

	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("ping: %v (run 'justclick roles set-password' if the login roles have no credentials yet)", err)
	}

	return pool
}

// asRole rewrites the base DSN to connect as one of the two login roles. Tests
// need the owner to create databases, so the base URL cannot itself be the
// application credential the way it is in a running server.
func asRole(base, database, role, passwordEnv string) string {
	password := os.Getenv(passwordEnv)

	u, err := url.Parse(withDatabase(base, database))
	if err != nil {
		return base
	}
	u.User = url.UserPassword(role, password)

	return u.String()
}

// ensureTemplate creates the migrated template if it is not already there.
//
// The name carries a hash of the migrations, so editing any migration produces
// a different template rather than silently reusing a stale schema — and an
// unchanged schema is built once and reused across runs.
func ensureTemplate(base string) error {
	digest, err := migrationsDigest()
	if err != nil {
		return err
	}
	templateName = "jc_tmpl_" + digest

	admin, err := sql.Open("pgx", withDatabase(base, "postgres"))
	if err != nil {
		return err
	}
	defer admin.Close()

	ctx := context.Background()
	conn, err := admin.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()

	// Two package binaries reaching this at once must not both try to create
	// the database; the loser waits here and then sees it already exists.
	if _, err := conn.ExecContext(ctx, "SELECT pg_advisory_lock($1)", templateLockKey); err != nil {
		return err
	}
	defer conn.ExecContext(ctx, "SELECT pg_advisory_unlock($1)", templateLockKey)

	var exists bool
	if err := conn.QueryRowContext(ctx,
		"SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)", templateName).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		if _, err := conn.ExecContext(ctx, fmt.Sprintf("CREATE DATABASE %q", templateName)); err != nil {
			return err
		}
	}
	// A failed first migration leaves an existing but incomplete database.
	// Always ask goose to finish it before it becomes a clone source.

	db, err := sql.Open("pgx", withDatabase(base, templateName))
	if err != nil {
		return err
	}
	defer db.Close()

	provider, err := goose.NewProvider(goose.DialectPostgres, db, migrations.FS, goose.WithGoMigrations(migrations.GoMigrations()...))
	if err != nil {
		return err
	}
	if _, err := provider.Up(ctx); err != nil {
		return fmt.Errorf("migrate template: %w", err)
	}

	// CREATE DATABASE ... TEMPLATE refuses to run while anything is connected
	// to the source, so this close is load-bearing, not tidiness.
	return db.Close()
}

func migrationsDigest() (string, error) {
	names, err := fs.Glob(migrations.FS, "*")
	if err != nil {
		return "", err
	}
	sort.Strings(names)

	sum := sha256.New()
	for _, name := range names {
		body, err := migrations.FS.ReadFile(name)
		if err != nil {
			return "", err
		}
		sum.Write([]byte(name))
		sum.Write(body)
	}

	return hex.EncodeToString(sum.Sum(nil))[:12], nil
}

func adminExec(base, stmt string) error {
	db, err := sql.Open("pgx", withDatabase(base, "postgres"))
	if err != nil {
		return err
	}
	defer db.Close()

	_, err = db.Exec(stmt)
	return err
}

func withDatabase(base, name string) string {
	u, err := url.Parse(base)
	if err != nil {
		return base
	}
	u.Path = "/" + name
	return u.String()
}
