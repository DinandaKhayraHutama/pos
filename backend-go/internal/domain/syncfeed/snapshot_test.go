package syncfeed_test

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
)

// Commit on a separate connection precisely between Pull's row scan and its
// counter query. A transaction alone is insufficient: READ COMMITTED gives the
// second SELECT a newer snapshot and silently advances past the missing row.
func TestPullDoesNotSkipACommitBetweenRowsAndCounter(t *testing.T) {
	for _, existing := range []bool{false, true} {
		name := "empty_page"
		if existing {
			name = "partial_page"
		}
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			var before int64
			if existing {
				f.writeCategory(t, f.tenantID, "Already committed")
				before = 1
			}

			writer, end := f.openTenantTx(t, f.tenantID)
			defer end()
			seq, err := syncfeed.AllocSeq(ctx, writer, f.tenantID,
				syncfeed.CompanyScope(f.tenantID, "categories"))
			require.NoError(t, err)
			var id string
			require.NoError(t, writer.QueryRow(ctx,
				`INSERT INTO categories (tenant_id, name, sync_seq)
				 VALUES ($1, 'Committed between reads', $2) RETURNING id`,
				f.tenantID, seq).Scan(&id))

			var committed bool
			var commitErr error
			cfg := f.db.Pools.Tenant.Config()
			cfg.ConnConfig.Tracer = &beforeCounterTracer{commit: func() {
				commitErr = writer.Commit(ctx)
				committed = true
			}}
			reader, err := pgxpool.NewWithConfig(ctx, cfg)
			require.NoError(t, err)
			defer reader.Close()
			pools := f.db.Pools
			pools.Tenant = reader
			feed := syncfeed.NewService(pools, newRedis(t), discardLogger())

			page, err := feed.Pull(ctx, f.tenantID, "categories", 0, 100)
			require.NoError(t, err)
			require.True(t, committed, "the test must hit the gap between SELECTs")
			require.NoError(t, commitErr)
			require.Len(t, page.Rows, int(before))
			require.Equal(t, before, page.NextSeq, "never acknowledge a row absent from this snapshot")
			require.False(t, page.HasMore)

			next, err := feed.Pull(ctx, f.tenantID, "categories", page.NextSeq, 100)
			require.NoError(t, err)
			require.Len(t, next.Rows, 1)
			require.Equal(t, id, decode(t, next.Rows[0])["id"])
			require.Equal(t, seq, next.NextSeq)
		})
	}
}

type beforeCounterTracer struct {
	once   sync.Once
	commit func()
}

func (t *beforeCounterTracer) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	if strings.Contains(data.SQL, "SELECT last_seq FROM sync_counters") {
		t.once.Do(t.commit)
	}
	return ctx
}

func (*beforeCounterTracer) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}
