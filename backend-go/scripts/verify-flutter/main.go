// Command verify-flutter runs the real Flutter repositories and sync client
// against the live API with a populated, disposable tenant. Secrets travel in
// child-process environment variables only, never in output or fixture files.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"runtime"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/syncfixture"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
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
	var tenant, outlet string
	if err := owner.QueryRow(ctx, `INSERT INTO tenants(name,slug) VALUES ('Flutter live verification',gen_random_uuid()::text) RETURNING id::text`).Scan(&tenant); err != nil {
		return err
	}
	defer func() {
		cleanup, done := context.WithTimeout(context.Background(), 30*time.Second)
		defer done()
		_, jobsErr := owner.Exec(cleanup, `DELETE FROM jobs.river_job WHERE args->>'tenant_id'=$1`, tenant)
		_, tenantErr := owner.Exec(cleanup, `DELETE FROM tenants WHERE id=$1`, tenant)
		if jobsErr != nil || tenantErr != nil {
			fmt.Fprintln(os.Stderr, "verification fixture cleanup failed", jobsErr, tenantErr)
		}
	}()
	if err := owner.QueryRow(ctx, `INSERT INTO outlets(tenant_id,name) VALUES ($1,'Live branch') RETURNING id::text`, tenant).Scan(&outlet); err != nil {
		return err
	}
	feed := syncfeed.NewService(pools, nil, slog.Default())
	if err := syncfixture.Seed(ctx, feed, tenant, 1); err != nil {
		return err
	}
	// Fixture is deliberately outlet-scoped, unlike a company-wide promotion.
	if err := feed.Write(ctx, tenant, func(ctx context.Context, w *syncfeed.Writer) error {
		seq, err := w.SeqBlock(ctx, "promos", 1)
		if err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx, `UPDATE promos SET all_outlets=false, sync_seq=$2 WHERE tenant_id=$1`, tenant, seq)
		return err
	}); err != nil {
		return err
	}
	if _, err := owner.Exec(ctx, `UPDATE promo_outlets SET outlet_id=$2 WHERE tenant_id=$1`, tenant, outlet); err != nil {
		return err
	}
	tokens := make([]string, 2)
	for i := range tokens {
		secret := make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			return err
		}
		tokens[i] = hex.EncodeToString(secret)
		var register string
		if err := owner.QueryRow(ctx, `INSERT INTO pos_registers(tenant_id,outlet_id,name) VALUES ($1,$2,$3) RETURNING id::text`, tenant, outlet, fmt.Sprintf("Live till %d", i+1)).Scan(&register); err != nil {
			return err
		}
		if _, err := owner.Exec(ctx, `INSERT INTO devices(tenant_id,outlet_id,pos_register_id,device_uuid,token_sha256,token_expires_at) VALUES ($1,$2,$3,gen_random_uuid()::text,$4,now()+interval '1 hour')`, tenant, outlet, register, devices.HashToken(tokens[i])); err != nil {
			return err
		}
	}
	base := os.Getenv("VERIFY_BASE_URL")
	if base == "" {
		base = "http://127.0.0.1:9000"
	}
	args := []string{"flutter", "test", "test/contract/live_sync_contract_test.dart", "test/contract/live_floor_contract_test.dart", "--concurrency=1", "--reporter", "expanded"}
	cmd := exec.CommandContext(ctx, "fvm", args...)
	if runtime.GOOS == "windows" {
		cmd = exec.CommandContext(ctx, "cmd", append([]string{"/c", "fvm"}, args...)...)
	}
	cmd.Dir = "../mobile"
	cmd.Env = append(os.Environ(), "JUSTCLICK_LIVE_BASE_URL="+base+"/api/v2", "JUSTCLICK_LIVE_TOKEN="+tokens[0], "JUSTCLICK_LIVE_TOKEN_B="+tokens[1])
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("flutter live contract: %w", err)
	}
	var orders, events int
	if err := owner.QueryRow(ctx, `SELECT count(*) FROM orders WHERE tenant_id=$1`, tenant).Scan(&orders); err != nil {
		return err
	}
	if err := owner.QueryRow(ctx, `SELECT count(*) FROM table_status_events WHERE tenant_id=$1`, tenant).Scan(&events); err != nil {
		return err
	}
	if orders != 5 || events != 3 {
		return fmt.Errorf("expected 5 receipts / 3 table events, got %d / %d", orders, events)
	}
	fmt.Println("PASS populated Flutter contract: 5 receipts, 3 immutable table events; fixture removed on exit")
	return nil
}
