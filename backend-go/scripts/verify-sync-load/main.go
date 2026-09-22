// Command verify-sync-load seeds a disposable fleet and runs the Fase 2A k6
// gate against the existing Compose API. No production auth/limiter is bypassed
// by the measured requests. Run from backend-go with .env loaded.
//
// Kept for the Fase 2A gate it was written for. The Fase 9 harness
// (scripts/loadtest) supersedes it for everything else: it drives the whole
// device lifecycle rather than one endpoint, needs no k6 image, reads the
// server's own metrics to separate server-side latency from the generator's,
// and checks the plan's targets as gates.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/syncfixture"
)

const fleetSize = 2000

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	ctx := context.Background()
	owner, err := pgxpool.New(ctx, os.Getenv("MIGRATE_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer owner.Close()
	pools, err := pg.OpenPools(ctx, os.Getenv("DATABASE_URL"), os.Getenv("UNSCOPED_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer pools.Close()
	rdb, err := redisx.Open(ctx, os.Getenv("REDIS_URL"))
	if err != nil {
		return err
	}
	defer rdb.Close()

	var tenantID string
	err = owner.QueryRow(ctx, `INSERT INTO tenants (name, slug)
		VALUES ('Sync load verification', $1) RETURNING id`, fmt.Sprintf("sync-load-%d", time.Now().UnixNano())).Scan(&tenantID)
	if err != nil {
		return err
	}
	defer func() {
		// The tenant is created by this invocation, never supplied by a user.
		_, cleanupErr := owner.Exec(context.Background(), `DELETE FROM tenants WHERE id=$1`, tenantID)
		if cleanupErr != nil {
			fmt.Fprintln(os.Stderr, "cleanup tenant", tenantID, cleanupErr)
		}
	}()
	feed := syncfeed.NewService(pools, rdb, slog.Default())
	if err := syncfixture.Seed(ctx, feed, tenantID, 1); err != nil {
		return err
	}
	tokens := make([]string, 0, fleetSize)
	err = pgx.BeginFunc(ctx, owner, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO outlets (tenant_id, name)
			SELECT $1, 'Load Outlet ' || g FROM generate_series(1, 667) AS g`, tenantID)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO pos_registers (tenant_id, outlet_id, name)
			SELECT $1, o.id, 'Load Register ' || g FROM outlets o CROSS JOIN generate_series(1, 3) AS g
			WHERE o.tenant_id=$1 AND o.name LIKE 'Load Outlet %'`, tenantID)
		if err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT id::text, outlet_id::text FROM pos_registers
			WHERE tenant_id=$1 AND name LIKE 'Load Register %' ORDER BY id LIMIT $2`, tenantID, fleetSize)
		if err != nil {
			return err
		}
		registers, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) ([2]string, error) {
			var ids [2]string
			err := row.Scan(&ids[0], &ids[1])
			return ids, err
		})
		if err != nil {
			return err
		}
		data := make([][]any, 0, fleetSize)
		for i, ids := range registers {
			secret := make([]byte, 32)
			if _, err := rand.Read(secret); err != nil {
				return err
			}
			token := hex.EncodeToString(secret)
			tokens = append(tokens, token)
			data = append(data, []any{tenantID, ids[1], ids[0], fmt.Sprintf("load-%d", i), devices.HashToken(token), time.Now().Add(time.Hour)})
		}
		_, err = tx.CopyFrom(ctx, pgx.Identifier{"devices"}, []string{
			"tenant_id", "outlet_id", "pos_register_id", "device_uuid", "token_sha256", "token_expires_at",
		}, pgx.CopyFromRows(data))
		return err
	})
	if err != nil {
		return err
	}
	if len(tokens) != fleetSize {
		return fmt.Errorf("expected %d devices, got %d", fleetSize, len(tokens))
	}

	// Synthetic tokens only; never place them in logs or committed artifacts.
	dir, err := os.MkdirTemp("", "justclick-sync-load-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	data, err := json.Marshal(map[string]any{"tokens": tokens, "schema_version": syncfeed.SchemaVersion, "entities": len(syncfeed.Entities())})
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "fleet.json"), data, 0600); err != nil {
		return err
	}
	script, err := filepath.Abs("scripts/verify-sync-load/changes.js")
	if err != nil {
		return err
	}
	cmd := exec.Command("docker", "run", "--rm", "--user", "0", "--network", envOr("LOAD_NETWORK", "justclick_default"),
		"-v", dir+":/fixtures:ro", "-v", script+":/changes.js:ro",
		"-e", "BASE_URL="+envOr("LOAD_BASE_URL", "http://api:9000"),
		"-e", "RATE="+envOr("LOAD_RATE", "2000"),
		"-e", "DURATION="+envOr("LOAD_DURATION", "60s"),
		"-e", "K6_INSECURE_SKIP_TLS_VERIFY="+envOr("VERIFY_INSECURE_TLS", "false"),
		"grafana/k6:1.8.0", "run", "--quiet", "/changes.js")
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	fmt.Printf("Fase 2A: %d devices, 667 outlets, normal auth + limiter; target %s\n", fleetSize, envOr("LOAD_BASE_URL", "http://api:9000"))
	return cmd.Run()
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
