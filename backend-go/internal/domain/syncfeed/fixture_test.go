package syncfeed_test

import (
	"context"
	"io"
	"log/slog"
	"os"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

type fixture struct {
	db pgtest.DB
	// feed is given exactly the credentials the running server uses: a tenant
	// pool that cannot bypass row-level security. Handing it the owner pool
	// would make every isolation assertion below vacuous.
	feed     *syncfeed.Service
	tenantID string
	// other is a second merchant, present in every fixture so that "this
	// tenant sees only its own rows" is something the data can actually
	// disprove.
	otherTenantID string
	outletID      string
}

func newFixture(t *testing.T) fixture {
	t.Helper()

	db := pgtest.New(t)
	ctx := context.Background()

	f := fixture{db: db, feed: syncfeed.NewService(db.Pools, newRedis(t), discardLogger())}

	require.NoError(t, db.Owner.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Warung Alpha', 'alpha') RETURNING id`).Scan(&f.tenantID))
	require.NoError(t, db.Owner.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Warung Beta', 'beta') RETURNING id`).Scan(&f.otherTenantID))
	require.NoError(t, db.Owner.QueryRow(ctx,
		`INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Bintaro') RETURNING id`,
		f.tenantID).Scan(&f.outletID))

	return f
}

func newRedis(t *testing.T) *redis.Client {
	t.Helper()

	url := os.Getenv("REDIS_URL")
	if url == "" {
		t.Fatal("REDIS_URL is not set; the watermark tests need a real Redis")
	}

	rdb, err := redisx.Open(context.Background(), url)
	require.NoError(t, err)
	t.Cleanup(func() { rdb.Close() })

	return rdb
}

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// openTenantTx starts a transaction the test drives by hand, and returns the
// call that ends it.
//
// pg.InTenantTx cannot be used where a test needs to hold a transaction open
// across a second connection's work, which is the whole shape of the
// lost-update reproduction. Releasing early matters: the pool holds four
// connections on a two-core CI runner, and a test that parks three of them has
// nothing left to pull with.
func (f fixture) openTenantTx(t *testing.T, tenantID string) (pgx.Tx, func()) {
	t.Helper()
	ctx := context.Background()

	conn, err := f.db.Pools.Tenant.Acquire(ctx)
	require.NoError(t, err)

	tx, err := conn.Begin(ctx)
	require.NoError(t, err)

	_, err = tx.Exec(ctx, "SELECT set_config('app.tenant_id', $1, true)", tenantID)
	require.NoError(t, err)

	var once sync.Once
	done := func() {
		once.Do(func() {
			// Rollback after a commit, or after a cancelled query left the
			// connection unusable, is expected and says nothing.
			_ = tx.Rollback(context.Background())
			conn.Release()
		})
	}
	t.Cleanup(done)

	return tx, done
}

// writeCategory inserts one row through the same path the Backoffice uses:
// number allocated inside the transaction, watermark published after commit.
func (f fixture) writeCategory(t *testing.T, tenantID, name string) string {
	t.Helper()

	var id string
	require.NoError(t, f.feed.Write(context.Background(), tenantID,
		func(ctx context.Context, w *syncfeed.Writer) error {
			seq, err := w.Seq(ctx, "categories")
			if err != nil {
				return err
			}

			return w.Tx.QueryRow(ctx, `
				INSERT INTO categories (tenant_id, name, sync_seq)
				VALUES ($1, $2, $3) RETURNING id`, tenantID, name, seq).Scan(&id)
		}))

	return id
}

func (f fixture) writeEmployee(t *testing.T, tenantID, name, pinHash string) string {
	t.Helper()

	var id string
	require.NoError(t, f.feed.Write(context.Background(), tenantID,
		func(ctx context.Context, w *syncfeed.Writer) error {
			seq, err := w.Seq(ctx, "employees")
			if err != nil {
				return err
			}

			return w.Tx.QueryRow(ctx, `
				INSERT INTO employees (tenant_id, name, email, password, pin_hash, role, sync_seq)
				VALUES ($1, $2, $3, 'a-browser-password-hash', $4, 'cashier', $5)
				RETURNING id`,
				tenantID, name, name+"@example.test", pinHash, seq).Scan(&id)
		}))

	return id
}
