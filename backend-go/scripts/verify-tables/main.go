// Command verify-tables drives the Fase 6 floor plan through the deployed HTTP
// API with a fresh tenant. The Backoffice domain publishes a branch's tables;
// two tills in that branch pull the plan and its status, race on one table and
// pull back the same contested answer; a till in another branch sees none of
// it and cannot write it; retries and fifty concurrent changes leave one
// consistent projection. Credentials and payloads are never printed.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/tables"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
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
	fmt.Println("all table checks passed")
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

type api struct {
	client *http.Client
	base   string
}

func (a api) do(ctx context.Context, method, path, token string, body any) (int, []byte, error) {
	reader := bytes.NewReader(nil)
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return 0, nil, err
		}
		reader = bytes.NewReader(raw)
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

func (a api) push(ctx context.Context, token string, rows ...map[string]any) ([]wire.PushResult, error) {
	raws := make([]json.RawMessage, len(rows))
	for i, r := range rows {
		b, err := json.Marshal(r)
		if err != nil {
			return nil, err
		}
		raws[i] = b
	}
	status, body, err := a.do(ctx, http.MethodPost, "/api/v2/sync/push", token,
		wire.PushRequest{Batches: []wire.PushBatch{{Entity: tables.EventEntity, Rows: raws}}})
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

// pull reads one page of a feed after a cursor.
func (a api) pull(ctx context.Context, token, entity string, after int64) ([]map[string]any, int64, error) {
	status, body, err := a.do(ctx, http.MethodGet,
		fmt.Sprintf("/api/v2/sync/pull?entity=%s&after_seq=%d&limit=1000", entity, after), token, nil)
	if err != nil {
		return nil, 0, err
	}
	if status != http.StatusOK {
		return nil, 0, fmt.Errorf("pull %s HTTP %d", entity, status)
	}
	var page struct {
		Rows    []map[string]any `json:"rows"`
		NextSeq int64            `json:"next_seq"`
	}
	if err := json.Unmarshal(body, &page); err != nil {
		return nil, 0, err
	}
	return page.Rows, page.NextSeq, nil
}

func statusOf(rows []map[string]any, tableID string) (map[string]any, bool) {
	for _, r := range rows {
		if r["table_id"] == tableID {
			return r, true
		}
	}
	return nil, false
}

func number(v any) int64 {
	f, _ := v.(float64)
	return int64(f)
}

var clientSequence atomic.Int64

func event(tableID, status string, basis, atMs int64) map[string]any {
	return map[string]any{
		"id": uuid(), "revision": 1, "table_id": tableID, "status": status,
		"client_seq": clientSequence.Add(1),
		"basis_seq":  basis, "occurred_at_ms": atMs, "employee_name": "Kasir Verifikasi",
	}
}

func outcome(r wire.PushResult) string {
	if r.Outcome == nil {
		return ""
	}
	return string(*r.Outcome)
}

func seqOf(r wire.PushResult) int64 {
	if r.StatusSeq == nil {
		return -1
	}
	return *r.StatusSeq
}

func code(r wire.PushResult) string {
	if r.Code == nil {
		return ""
	}
	return string(*r.Code)
}

func run() error {
	ctx := context.Background()

	base := os.Getenv("VERIFY_BASE_URL")
	if base == "" {
		base = "http://127.0.0.1:9000"
	}
	client := &http.Client{Timeout: 30 * time.Second}
	// Caddy issues from its own local CA in development. Only ever set this
	// against localhost.
	if os.Getenv("VERIFY_INSECURE_TLS") == "1" {
		client.Transport = &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // dev-only, localhost
		}
	}
	a := api{client: client, base: base}

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

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := tables.NewService(pools, syncfeed.NewService(pools, rdb, logger))

	tenant := uuid()
	if _, err := owner.Exec(ctx, "INSERT INTO tenants(id,name,slug) VALUES ($1::uuid,'Table verification',$1::uuid::text)", tenant); err != nil {
		return err
	}
	defer func() {
		if _, err := owner.Exec(context.Background(), "DELETE FROM jobs.river_job WHERE args->>'tenant_id'=$1", tenant); err != nil {
			fmt.Fprintln(os.Stderr, "job fixture cleanup failed:", err)
		}
		if _, err := owner.Exec(context.Background(), "DELETE FROM tenants WHERE id=$1", tenant); err != nil {
			fmt.Fprintln(os.Stderr, "fixture cleanup failed:", err)
		}
	}()

	outletA, outletB := uuid(), uuid()
	for _, o := range []struct{ id, name string }{{outletA, "Outlet A"}, {outletB, "Outlet B"}} {
		if _, err := owner.Exec(ctx, "INSERT INTO outlets(id,tenant_id,name) VALUES ($1,$2,$3)", o.id, tenant, o.name); err != nil {
			return err
		}
	}

	registers := 0
	newTill := func(outlet string) (string, error) {
		register, device := uuid(), uuid()
		registers++ // register names are unique per outlet
		if _, err := owner.Exec(ctx, "INSERT INTO pos_registers(id,tenant_id,outlet_id,name) VALUES ($1,$2,$3,$4)",
			register, tenant, outlet, fmt.Sprintf("Kasir %d", registers)); err != nil {
			return "", err
		}
		secret := make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			return "", err
		}
		token := hex.EncodeToString(secret)
		if _, err := owner.Exec(ctx, "INSERT INTO devices(id,tenant_id,outlet_id,pos_register_id,device_uuid,token_sha256,token_expires_at) VALUES ($1::uuid,$2,$3,$4,$1::uuid::text,$5,now()+interval '1 hour')",
			device, tenant, outlet, register, devices.HashToken(token)); err != nil {
			return "", err
		}
		return token, nil
	}
	a1, err := newTill(outletA)
	if err != nil {
		return err
	}
	a2, err := newTill(outletA)
	if err != nil {
		return err
	}
	b1, err := newTill(outletB)
	if err != nil {
		return err
	}

	// The Backoffice publishes the floor plans through the domain service.
	t1, err := svc.Save(ctx, tenant, tables.Table{OutletID: outletA, Name: "Meja 1", Area: "Lantai 1", Capacity: 4, Active: true})
	if err != nil {
		return err
	}
	t2, err := svc.Save(ctx, tenant, tables.Table{OutletID: outletA, Name: "Meja 2", Area: "Teras", Capacity: 2, Active: true})
	if err != nil {
		return err
	}
	tb, err := svc.Save(ctx, tenant, tables.Table{OutletID: outletB, Name: "Meja 1", Area: "Lantai 1", Capacity: 4, Active: true})
	if err != nil {
		return err
	}

	// ---- manifest -------------------------------------------------------------

	status, body, err := a.do(ctx, http.MethodGet, "/api/v2/sync/manifest", a1, nil)
	if err != nil {
		return err
	}
	if status != http.StatusOK {
		return fmt.Errorf("manifest HTTP %d", status)
	}
	var manifest wire.Manifest
	if err := json.Unmarshal(body, &manifest); err != nil {
		return err
	}
	index := map[string]int{}
	byName := map[string]wire.ManifestEntity{}
	for i, e := range manifest.Entities {
		index[e.Name], byName[e.Name] = i, e
	}
	feedOK := func(name string, pull, push bool) bool {
		e, ok := byName[name]
		return ok && string(e.Scope) == "outlet" && e.Pull == pull && e.Push == push
	}
	check("manifest publishes tables as an outlet feed tills pull", feedOK("tables", true, false), "got %+v", byName["tables"])
	check("manifest publishes table_status as an outlet feed tills pull", feedOK("table_status", true, false), "got %+v", byName["table_status"])
	check("manifest accepts table_status_events as push-only", feedOK("table_status_events", false, true), "got %+v", byName["table_status_events"])
	check("a table is listed before its status", index["tables"] < index["table_status"],
		"tables at %d, table_status at %d", index["tables"], index["table_status"])

	// ---- pulls ----------------------------------------------------------------

	plan, _, err := a.pull(ctx, a1, "tables", 0)
	if err != nil {
		return err
	}
	areaOK := false
	for _, r := range plan {
		if r["id"] == t2 && r["area"] == "Teras" && number(r["capacity"]) == 2 {
			areaOK = true
		}
	}
	check("a till pulls its branch's floor plan with areas and seats", len(plan) == 2 && areaOK, "got %d rows", len(plan))

	other, _, err := a.pull(ctx, b1, "tables", 0)
	if err != nil {
		return err
	}
	check("a till in another branch pulls only its own tables", len(other) == 1 && other[0]["id"] == tb, "got %d rows", len(other))

	statuses, _, err := a.pull(ctx, a1, "table_status", 0)
	if err != nil {
		return err
	}
	s1, ok := statusOf(statuses, t1)
	check("each table arrives with its status", ok && len(statuses) == 2 && s1["status"] == "available", "got %v", statuses)
	basis := number(s1["sync_seq"])

	status, body, err = a.do(ctx, http.MethodGet, "/api/v2/sync/changes", a1, nil)
	if err != nil {
		return err
	}
	var changes struct {
		Cursors map[string]int64 `json:"cursors"`
	}
	if status != http.StatusOK || json.Unmarshal(body, &changes) != nil {
		return fmt.Errorf("changes HTTP %d", status)
	}
	check("/sync/changes names both floor-plan feeds",
		changes.Cursors["tables"] > 0 && changes.Cursors["table_status"] >= basis, "got %v", changes.Cursors)

	// ---- retries --------------------------------------------------------------

	seat := event(t1, tables.StatusOccupied, basis, time.Now().UnixMilli())
	seated := int64(-1)
	retriesOK := true
	for i := 0; i < 3; i++ {
		res, err := a.push(ctx, a1, seat)
		if err != nil {
			return err
		}
		if res[0].Status != "accepted" || outcome(res[0]) != tables.OutcomeApplied || (seated >= 0 && seqOf(res[0]) != seated) {
			retriesOK = false
		}
		if seated < 0 {
			seated = seqOf(res[0])
		}
	}
	var events int
	if err := owner.QueryRow(ctx, "SELECT count(*) FROM table_status_events WHERE tenant_id = $1", tenant).Scan(&events); err != nil {
		return err
	}
	check("a status change and two retries are accepted as one event", retriesOK && events == 1,
		"retries consistent %v, events %d", retriesOK, events)

	// ---- a race between two tills ---------------------------------------------

	agree := func(tableID string) (map[string]any, bool) {
		ra, _, errA := a.pull(ctx, a1, "table_status", 0)
		rb, _, errB := a.pull(ctx, a2, "table_status", 0)
		if errA != nil || errB != nil {
			return nil, false
		}
		sa, okA := statusOf(ra, tableID)
		sb, okB := statusOf(rb, tableID)
		return sa, okA && okB && sa["status"] == sb["status"] && sa["contested"] == sb["contested"] &&
			number(sa["sync_seq"]) == number(sb["sync_seq"])
	}

	// Till A2 never pulled A1's change, and its own change was made earlier.
	stale := event(t1, tables.StatusReserved, basis, time.Now().Add(-time.Minute).UnixMilli())
	res, err := a.push(ctx, a2, stale)
	if err != nil {
		return err
	}
	check("a change that raced a later one is accepted but superseded",
		res[0].Status == "accepted" && outcome(res[0]) == tables.OutcomeSuperseded, "got %s/%s", res[0].Status, outcome(res[0]))

	raced, same := agree(t1)
	check("both tills pull the same contested status, with the later change kept",
		same && raced["status"] == tables.StatusOccupied && raced["contested"] == true, "got %v", raced)

	res, err = a.push(ctx, a2, event(t1, tables.StatusAvailable, number(raced["sync_seq"]), time.Now().UnixMilli()))
	if err != nil {
		return err
	}
	settled, same := agree(t1)
	check("a change made against the contested status settles it for both tills",
		res[0].Status == "accepted" && outcome(res[0]) == tables.OutcomeApplied && same &&
			settled["status"] == tables.StatusAvailable && settled["contested"] == false, "got %v", settled)

	// ---- another branch ------------------------------------------------------

	res, err = a.push(ctx, b1, event(t1, tables.StatusOccupied, number(settled["sync_seq"]), time.Now().UnixMilli()))
	if err != nil {
		return err
	}
	check("a till in another branch cannot change the table",
		res[0].Status == "rejected" && code(res[0]) == "schema_rejected", "got %s/%s", res[0].Status, code(res[0]))
	foreign, _, err := a.pull(ctx, b1, "table_status", 0)
	if err != nil {
		return err
	}
	_, leaked := statusOf(foreign, t1)
	check("nor pull its status", !leaked && len(foreign) == 1, "got %d rows", len(foreign))

	// ---- concurrency ---------------------------------------------------------

	const perTill = 25
	var (
		mu      sync.Mutex
		results []wire.PushResult
		pushErr error
		wg      sync.WaitGroup
	)
	for w, token := range []string{a1, a2} {
		wg.Add(1)
		go func(w int, token string) {
			defer wg.Done()
			cycle := []string{tables.StatusOccupied, tables.StatusReserved, tables.StatusAvailable}
			for i := 0; i < perTill; i++ {
				res, err := a.push(ctx, token, event(t2, cycle[(i+w)%len(cycle)], 0, time.Now().UnixMilli()))
				mu.Lock()
				if err != nil {
					pushErr = err
				} else {
					results = append(results, res...)
				}
				mu.Unlock()
			}
		}(w, token)
	}
	wg.Wait()
	if pushErr != nil {
		return pushErr
	}
	allAccepted := len(results) == 2*perTill
	newest := int64(0)
	for _, r := range results {
		if r.Status != "accepted" {
			allAccepted = false
		}
		if seqOf(r) > newest {
			newest = seqOf(r)
		}
	}
	check("fifty concurrent changes on one table from two tills are all accepted", allAccepted, "got %d results", len(results))
	final, same := agree(t2)
	check("both tills converge on one status for the raced table", same, "tills disagree: %v", final)
	check("the projection carries the newest event's sequence", number(final["sync_seq"]) == newest,
		"projection %d, newest event %d", number(final["sync_seq"]), newest)

	// ---- Backoffice edits reach the till ----------------------------------------

	_, planCursor, err := a.pull(ctx, a1, "tables", 0)
	if err != nil {
		return err
	}
	_, statusCursor, err := a.pull(ctx, a1, "table_status", 0)
	if err != nil {
		return err
	}
	if _, err := svc.Save(ctx, tenant, tables.Table{ID: t1, OutletID: outletA, Name: "Meja Jendela", Area: "Lantai 1", Capacity: 6, Active: true}); err != nil {
		return err
	}
	if err := svc.Delete(ctx, tenant, t2); err != nil {
		return err
	}

	planDelta, _, err := a.pull(ctx, a1, "tables", planCursor)
	if err != nil {
		return err
	}
	renamed, tombstoned := false, false
	for _, r := range planDelta {
		if r["id"] == t1 && r["name"] == "Meja Jendela" && number(r["capacity"]) == 6 {
			renamed = true
		}
		if r["id"] == t2 && r["deleted_at_ms"] != nil {
			tombstoned = true
		}
	}
	check("a rename in the Backoffice reaches the till as a delta", renamed, "got %d rows", len(planDelta))

	statusDelta, _, err := a.pull(ctx, a1, "table_status", statusCursor)
	if err != nil {
		return err
	}
	gone, ok := statusOf(statusDelta, t2)
	check("a deleted table reaches the till as tombstones for the table and its status",
		tombstoned && ok && gone["deleted_at_ms"] != nil, "table tombstone %v, status row %v", tombstoned, gone)

	res, err = a.push(ctx, a1, event(t2, tables.StatusOccupied, number(gone["sync_seq"]), time.Now().UnixMilli()))
	if err != nil {
		return err
	}
	check("a deleted table takes no more changes", res[0].Status == "rejected", "got %s", res[0].Status)

	var tenantLocks int
	if err := owner.QueryRow(ctx, `
		SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
		WHERE c.relname = 'tenants' AND l.locktype = 'tuple'`).Scan(&tenantLocks); err != nil {
		return err
	}
	fmt.Printf("  INFO  row locks held on tenants after the run: %d\n", tenantLocks)

	return nil
}
