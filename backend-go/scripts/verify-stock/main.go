// Command verify-stock drives the Fase 5 stock ledger through the deployed
// HTTP API with a fresh tenant: two tills in one outlet push concurrent offline
// sales with retries, both pull the same count, a third till in another outlet
// sees none of it, and a count is converted server-side. Credentials and
// payloads are never printed.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
)

var failed bool

func check(name string, ok bool, format string, args ...any) {
	if ok {
		fmt.Printf("  PASS  %s\n", name)
		return
	}
	failed = true
	fmt.Printf("  FAIL  %s: %s\n", name, fmt.Sprintf(format, args...))
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if failed {
		os.Exit(1)
	}
	fmt.Println("all stock checks passed")
}

func uuid() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

type till struct {
	token string
}

type api struct {
	client *http.Client
	base   string
}

func (a api) do(ctx context.Context, method, path, token string, body any) (int, []byte, error) {
	var reader *bytes.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return 0, nil, err
		}
		reader = bytes.NewReader(raw)
	} else {
		reader = bytes.NewReader(nil)
	}
	req, err := http.NewRequestWithContext(ctx, method, a.base+path, reader)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Schema-Version", "1")
	resp, err := a.client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	var buf bytes.Buffer
	if _, err := buf.ReadFrom(resp.Body); err != nil {
		return 0, nil, err
	}
	return resp.StatusCode, buf.Bytes(), nil
}

func (a api) push(ctx context.Context, t till, rows ...map[string]any) ([]wire.PushResult, error) {
	raws := make([]json.RawMessage, len(rows))
	for i, r := range rows {
		b, err := json.Marshal(r)
		if err != nil {
			return nil, err
		}
		raws[i] = b
	}
	status, body, err := a.do(ctx, http.MethodPost, "/api/v2/sync/push", t.token,
		wire.PushRequest{Batches: []wire.PushBatch{{Entity: "stock_movements", Rows: raws}}})
	if err != nil {
		return nil, err
	}
	if status != http.StatusOK {
		return nil, fmt.Errorf("push HTTP %d", status)
	}
	var out wire.PushResponse
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, err
	}
	if len(out.Results) != len(rows) {
		return nil, fmt.Errorf("expected %d results, got %d", len(rows), len(out.Results))
	}
	return out.Results, nil
}

func (a api) pull(ctx context.Context, t till, entity string) (wire.PullPage, error) {
	status, body, err := a.do(ctx, http.MethodGet, "/api/v2/sync/pull?entity="+entity+"&after_seq=0&limit=1000", t.token, nil)
	if err != nil {
		return wire.PullPage{}, err
	}
	if status != http.StatusOK {
		return wire.PullPage{}, fmt.Errorf("pull %s HTTP %d", entity, status)
	}
	var page wire.PullPage
	return page, json.Unmarshal(body, &page)
}

func movement(product, reason string, delta int64) map[string]any {
	return map[string]any{
		"id": uuid(), "revision": 1, "product_id": product, "product_name": "Es Teh Verifikasi",
		"reason": reason, "delta_qty": delta, "occurred_at_ms": time.Now().UnixMilli(),
		"employee_name": "Kasir Verifikasi",
	}
}

func run() error {
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, os.Getenv("MIGRATE_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer pool.Close()

	tenant := uuid()
	if _, err := pool.Exec(ctx, "INSERT INTO tenants(id,name,slug) VALUES ($1::uuid,'Stock verification',$1::uuid::text)", tenant); err != nil {
		return err
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), "DELETE FROM jobs.river_job WHERE args->>'tenant_id'=$1", tenant); err != nil {
			fmt.Fprintln(os.Stderr, "job fixture cleanup failed:", err)
		}
		if _, err := pool.Exec(context.Background(), "DELETE FROM tenants WHERE id=$1", tenant); err != nil {
			fmt.Fprintln(os.Stderr, "fixture cleanup failed:", err)
		}
	}()

	outletA, outletB, category, product := uuid(), uuid(), uuid(), uuid()
	for _, stmt := range []struct {
		sql  string
		args []any
	}{
		{"INSERT INTO outlets(id,tenant_id,name) VALUES ($1,$2,'Outlet A')", []any{outletA, tenant}},
		{"INSERT INTO outlets(id,tenant_id,name) VALUES ($1,$2,'Outlet B')", []any{outletB, tenant}},
		{"INSERT INTO categories(id,tenant_id,name) VALUES ($1,$2,'Minuman')", []any{category, tenant}},
		{"INSERT INTO products(id,tenant_id,category_id,name,price) VALUES ($1,$2,$3,'Es Teh Verifikasi',5000)", []any{product, tenant, category}},
	} {
		if _, err := pool.Exec(ctx, stmt.sql, stmt.args...); err != nil {
			return err
		}
	}

	registers := 0
	newTill := func(outlet string) (till, error) {
		register, device := uuid(), uuid()
		registers++ // register names are unique per outlet
		if _, err := pool.Exec(ctx, "INSERT INTO pos_registers(id,tenant_id,outlet_id,name) VALUES ($1,$2,$3,$4)", register, tenant, outlet, fmt.Sprintf("Kasir %d", registers)); err != nil {
			return till{}, err
		}
		secret := make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			return till{}, err
		}
		token := hex.EncodeToString(secret)
		if _, err := pool.Exec(ctx, "INSERT INTO devices(id,tenant_id,outlet_id,pos_register_id,device_uuid,token_sha256,token_expires_at) VALUES ($1::uuid,$2,$3,$4,$1::uuid::text,$5,now()+interval '1 hour')",
			device, tenant, outlet, register, devices.HashToken(token)); err != nil {
			return till{}, err
		}
		return till{token: token}, nil
	}
	tillA1, err := newTill(outletA)
	if err != nil {
		return err
	}
	tillA2, err := newTill(outletA)
	if err != nil {
		return err
	}
	tillB, err := newTill(outletB)
	if err != nil {
		return err
	}

	client := &http.Client{Timeout: 90 * time.Second}
	if os.Getenv("VERIFY_INSECURE_TLS") == "1" {
		client.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}} // local CA only
	}
	base := os.Getenv("VERIFY_BASE_URL")
	if base == "" {
		base = "http://127.0.0.1:9000"
	}
	a := api{client: client, base: base}

	// ---- manifest ---------------------------------------------------------
	status, body, err := a.do(ctx, http.MethodGet, "/api/v2/sync/manifest", tillA1.token, nil)
	if err != nil {
		return err
	}
	var manifest wire.Manifest
	if err := json.Unmarshal(body, &manifest); err != nil || status != http.StatusOK {
		return fmt.Errorf("manifest HTTP %d: %v", status, err)
	}
	found := map[string]wire.ManifestEntity{}
	for _, e := range manifest.Entities {
		found[e.Name] = e
	}
	check("manifest publishes stock_movements as outlet-scoped, pulled and pushed",
		found["stock_movements"].Scope == "outlet" && found["stock_movements"].Pull && found["stock_movements"].Push, "%+v", found["stock_movements"])
	check("manifest publishes outlet_stock as outlet-scoped and pull-only",
		found["outlet_stock"].Scope == "outlet" && found["outlet_stock"].Pull && !found["outlet_stock"].Push, "%+v", found["outlet_stock"])

	// ---- opening stock, then two offline tills --------------------------------
	opening, err := a.push(ctx, tillA1, movement(product, "received", 20))
	if err != nil {
		return err
	}
	check("a delivery pushed by a till is accepted with its projection sequence",
		opening[0].Status == "accepted" && opening[0].StockSeq != nil && opening[0].BalanceAfter != nil && *opening[0].BalanceAfter == 20,
		"%+v", opening[0])

	salesA1 := make([]map[string]any, 15)
	salesA2 := make([]map[string]any, 15)
	for i := range salesA1 {
		salesA1[i] = movement(product, "sale", -1)
		salesA2[i] = movement(product, "sale", -1)
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	var pushErrors []error
	notAccepted := 0
	for attempt := 0; attempt < 3; attempt++ {
		for _, job := range []struct {
			t    till
			rows []map[string]any
		}{{tillA1, salesA1}, {tillA2, salesA2}} {
			wg.Add(1)
			go func(t till, rows []map[string]any) {
				defer wg.Done()
				results, err := a.push(ctx, t, rows...)
				mu.Lock()
				defer mu.Unlock()
				if err != nil {
					pushErrors = append(pushErrors, err)
					return
				}
				for _, r := range results {
					if r.Status != "accepted" || r.StockSeq == nil {
						notAccepted++
					}
				}
			}(job.t, job.rows)
		}
	}
	wg.Wait()
	check("two tills pushing the same item concurrently, three times each, are all accepted",
		len(pushErrors) == 0 && notAccepted == 0, "errors=%v notAccepted=%d", pushErrors, notAccepted)

	var qty, ledger int64
	var rows int
	if err := pool.QueryRow(ctx, "SELECT qty_on_hand FROM outlet_stock WHERE tenant_id=$1 AND outlet_id=$2 AND product_id=$3", tenant, outletA, product).Scan(&qty); err != nil {
		return err
	}
	if err := pool.QueryRow(ctx, "SELECT COALESCE(sum(delta_qty),0), count(*) FROM stock_movements WHERE tenant_id=$1", tenant).Scan(&ledger, &rows); err != nil {
		return err
	}
	check("the outlet lands on 20 - 30 = -10: a shortfall is recorded, never refused", qty == -10, "qty=%d", qty)
	check("the projection equals its ledger, and retries created no movement", ledger == -10 && rows == 31, "ledger=%d rows=%d", ledger, rows)

	quantityFrom := func(t till) (int64, int, error) {
		page, err := a.pull(ctx, t, "outlet_stock")
		if err != nil {
			return 0, 0, err
		}
		if len(page.Rows) == 0 {
			return 0, 0, nil
		}
		var row struct {
			QtyOnHand int64 `json:"qty_on_hand"`
		}
		return row.QtyOnHand, len(page.Rows), json.Unmarshal(page.Rows[0], &row)
	}
	q1, n1, err := quantityFrom(tillA1)
	if err != nil {
		return err
	}
	q2, n2, err := quantityFrom(tillA2)
	if err != nil {
		return err
	}
	check("both tills in the outlet pull the same count the server holds", n1 == 1 && n2 == 1 && q1 == -10 && q2 == -10, "a1=%d(%d rows) a2=%d(%d rows)", q1, n1, q2, n2)

	_, nb, err := quantityFrom(tillB)
	if err != nil {
		return err
	}
	moves, err := a.pull(ctx, tillB, "stock_movements")
	if err != nil {
		return err
	}
	check("a till in another outlet pulls none of that outlet's stock", nb == 0 && len(moves.Rows) == 0, "outlet_stock=%d stock_movements=%d", nb, len(moves.Rows))

	status, body, err = a.do(ctx, http.MethodGet, "/api/v2/sync/changes", tillA1.token, nil)
	if err != nil {
		return err
	}
	var changes wire.Changes
	if err := json.Unmarshal(body, &changes); err != nil || status != http.StatusOK {
		return fmt.Errorf("changes HTTP %d: %v", status, err)
	}
	check("/sync/changes names the outlet feeds' own cursors", changes.Cursors["stock_movements"] == 31 && changes.Cursors["outlet_stock"] >= 1,
		"stock_movements=%d outlet_stock=%d", changes.Cursors["stock_movements"], changes.Cursors["outlet_stock"])

	// ---- a count, and a refused movement -------------------------------------
	count := movement(product, "count", 0)
	count["counted_qty"] = 5
	first, err := a.push(ctx, tillA2, count)
	if err != nil {
		return err
	}
	again, err := a.push(ctx, tillA2, count)
	if err != nil {
		return err
	}
	check("a count becomes the server's quantity, and its retry repeats the result",
		first[0].Status == "accepted" && first[0].BalanceAfter != nil && *first[0].BalanceAfter == 5 &&
			again[0].Status == "accepted" && *again[0].StockSeq == *first[0].StockSeq,
		"first=%+v again=%+v", first[0], again[0])

	bad, err := a.push(ctx, tillA1, movement(product, "sale", 3))
	if err != nil {
		return err
	}
	check("a sale that would add stock is refused per row, not per request",
		bad[0].Status == "rejected" && bad[0].Code != nil && *bad[0].Code == "schema_rejected", "%+v", bad[0])

	if err := pool.QueryRow(ctx, "SELECT qty_on_hand FROM outlet_stock WHERE tenant_id=$1 AND outlet_id=$2 AND product_id=$3", tenant, outletA, product).Scan(&qty); err != nil {
		return err
	}
	check("the final count is the counted quantity", qty == 5, "qty=%d", qty)

	var tenantLocks int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation WHERE c.relname = 'tenants' AND l.mode IN ('RowExclusiveLock','RowShareLock') AND l.granted AND l.pid <> pg_backend_pid()").Scan(&tenantLocks); err != nil {
		return err
	}
	fmt.Printf("  INFO  row-level lock modes held on tenants after the run: %d\n", tenantLocks)
	return nil
}
