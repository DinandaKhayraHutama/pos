package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/syncfixture"
)

type product struct {
	id, name string
	price    int64
}

// Fleet is a disposable merchant: its own tenant row, its own branches, tills
// and catalogue. Everything hangs off the tenant, so cleanup is one DELETE.
//
// It is never a merchant that exists for any other reason. A load test writes
// millions of rows and then removes them, and pointing it at a real tenant is
// how a verification run becomes an incident.
type Fleet struct {
	TenantID string
	Outlets  []string
	Tills    []*Till
	Products []product
}

type FleetOptions struct {
	Devices        int
	TillsPerOutlet int
	// CatalogueRows is seeded per feed. 5,000 is the size the pull path is
	// verified at; a smaller number makes a faster fleet but a less honest
	// catalogue fan-out.
	CatalogueRows int
	BaseURL       string
	Client        *http.Client
}

// ProvisionFleet writes device rows and their token hashes directly.
//
// Activation itself is exercised by the smoke scenario and by
// verify-activation; going through it fifteen thousand times here would
// measure the activation limiter rather than the thing under test. What the
// measured requests do NOT bypass is production authentication: every request
// below carries a real bearer token and passes the same middleware, cache and
// per-device rate limiter as a tablet's.
func ProvisionFleet(ctx context.Context, owner *pgxpool.Pool, feed *syncfeed.Service, opts FleetOptions) (*Fleet, error) {
	if opts.TillsPerOutlet < 1 {
		opts.TillsPerOutlet = 3
	}
	outletCount := (opts.Devices + opts.TillsPerOutlet - 1) / opts.TillsPerOutlet
	if outletCount < 1 {
		outletCount = 1
	}

	fleet := &Fleet{}
	err := owner.QueryRow(ctx, `INSERT INTO tenants (name, slug) VALUES ('Load test fleet', $1) RETURNING id::text`,
		fmt.Sprintf("loadtest-%d", time.Now().UnixNano())).Scan(&fleet.TenantID)
	if err != nil {
		return nil, fmt.Errorf("create disposable tenant: %w", err)
	}

	if err := syncfixture.Seed(ctx, feed, fleet.TenantID, opts.CatalogueRows); err != nil {
		return fleet, fmt.Errorf("seed catalogue: %w", err)
	}

	tokens := make([]string, 0, opts.Devices)
	err = pgx.BeginFunc(ctx, owner, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO outlets (tenant_id, name)
			SELECT $1, 'Load Outlet ' || g FROM generate_series(1, $2::int) AS g`,
			fleet.TenantID, outletCount); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO pos_registers (tenant_id, outlet_id, name)
			SELECT $1, o.id, 'Load Register ' || g
			FROM outlets o CROSS JOIN generate_series(1, $2::int) AS g
			WHERE o.tenant_id = $1 AND o.name LIKE 'Load Outlet %'`,
			fleet.TenantID, opts.TillsPerOutlet); err != nil {
			return err
		}

		rows, err := tx.Query(ctx, `SELECT id::text, outlet_id::text FROM pos_registers
			WHERE tenant_id = $1 AND name LIKE 'Load Register %' ORDER BY outlet_id, id LIMIT $2`,
			fleet.TenantID, opts.Devices)
		if err != nil {
			return err
		}
		registers, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) ([2]string, error) {
			var pair [2]string
			return pair, row.Scan(&pair[0], &pair[1])
		})
		if err != nil {
			return err
		}
		if len(registers) < opts.Devices {
			return fmt.Errorf("provisioned %d registers for %d devices", len(registers), opts.Devices)
		}

		copyRows := make([][]any, 0, opts.Devices)
		ids := make([]string, 0, opts.Devices)
		for i, pair := range registers {
			secret := make([]byte, 32)
			if _, err := rand.Read(secret); err != nil {
				return err
			}
			token := hex.EncodeToString(secret)
			tokens = append(tokens, token)
			deviceID := newUUID()
			ids = append(ids, deviceID)
			fleet.Outlets = append(fleet.Outlets, pair[1])
			copyRows = append(copyRows, []any{
				deviceID, fleet.TenantID, pair[1], pair[0], fmt.Sprintf("load-%d", i),
				devices.HashToken(token), time.Now().Add(24 * time.Hour),
			})
		}
		if _, err := tx.CopyFrom(ctx, pgx.Identifier{"devices"}, []string{
			"id", "tenant_id", "outlet_id", "pos_register_id", "device_uuid", "token_sha256", "token_expires_at",
		}, pgx.CopyFromRows(copyRows)); err != nil {
			return err
		}

		for i := range ids {
			fleet.Tills = append(fleet.Tills, newTill(opts.BaseURL, opts.Client, ids[i], fleet.Outlets[i], tokens[i]))
		}
		return nil
	})
	if err != nil {
		return fleet, fmt.Errorf("provision tills: %w", err)
	}

	fleet.Products, err = readProducts(ctx, owner, fleet.TenantID, 200)
	if err != nil {
		return fleet, err
	}
	if len(fleet.Products) == 0 {
		return fleet, fmt.Errorf("the seeded catalogue has no products to sell")
	}

	return fleet, nil
}

func readProducts(ctx context.Context, owner *pgxpool.Pool, tenantID string, limit int) ([]product, error) {
	rows, err := owner.Query(ctx,
		`SELECT id::text, name, price FROM products WHERE tenant_id = $1 AND deleted_at IS NULL ORDER BY sync_seq LIMIT $2`,
		tenantID, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (product, error) {
		var p product
		return p, row.Scan(&p.id, &p.name, &p.price)
	})
}

// Cleanup removes the disposable merchant and the jobs its writes enqueued.
//
// It runs on a fresh context: a run cancelled by Ctrl-C must still take its
// millions of rows with it. The tenant id was minted by this process, never
// supplied by anyone.
func (f *Fleet) Cleanup(owner *pgxpool.Pool, keep bool) {
	if f == nil || f.TenantID == "" {
		return
	}
	if keep {
		fmt.Printf("keeping tenant %s for inspection; remove it with: DELETE FROM tenants WHERE id = '%s';\n",
			f.TenantID, f.TenantID)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	if _, err := owner.Exec(ctx, `DELETE FROM jobs.river_job WHERE args->>'tenant_id' = $1`, f.TenantID); err != nil {
		fmt.Fprintln(os.Stderr, "cleanup jobs:", err)
	}
	if _, err := owner.Exec(ctx, `DELETE FROM tenants WHERE id = $1`, f.TenantID); err != nil {
		fmt.Fprintln(os.Stderr, "cleanup tenant:", err)
	}
}

// openSessions gives every till a drawer to attribute receipts to, in
// parallel but bounded — this is setup, not the measurement.
func openSessions(ctx context.Context, tills []*Till, concurrency int, logger *slog.Logger) error {
	return inParallel(ctx, len(tills), min(concurrency, 64), func(ctx context.Context, i int) error {
		if err := tills[i].OpenSession(ctx); err != nil {
			logger.Error("open session", slog.Int("till", i), slog.Any("error", err))
			return err
		}
		return nil
	})
}

func inParallel(ctx context.Context, count, concurrency int, fn func(context.Context, int) error) error {
	if concurrency < 1 {
		concurrency = 1
	}
	jobs := make(chan int)
	errs := make(chan error, concurrency)

	for range concurrency {
		go func() {
			var firstErr error
			for i := range jobs {
				if err := fn(ctx, i); err != nil && firstErr == nil {
					firstErr = err
				}
			}
			errs <- firstErr
		}()
	}
	for i := range count {
		select {
		case jobs <- i:
		case <-ctx.Done():
			close(jobs)
			return ctx.Err()
		}
	}
	close(jobs)

	var firstErr error
	for range concurrency {
		if err := <-errs; err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}
