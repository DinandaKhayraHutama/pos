// Command verify-till drives the coordinated till surface over real HTTP.
//
// till_test.go exercises the domain service directly. This script exercises
// what a tablet actually touches: the handlers, the cashier-token header, the
// PIN limiter, the JSON envelope and the status codes — the layer unit tests
// structurally cannot reach. Credentials and financial payloads are never
// printed.
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
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/ingest"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

var failures int

func check(name string, ok bool, format string, args ...any) {
	if ok {
		fmt.Println("  PASS ", name)
		return
	}
	failures++
	fmt.Printf("  FAIL  %s: %s\n", name, fmt.Sprintf(format, args...))
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if failures > 0 {
		fmt.Printf("\n%d check(s) FAILED\n", failures)
		os.Exit(1)
	}
	fmt.Println("\nall till checks passed")
}

func uuid() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6], b[8] = (b[6]&15)|64, (b[8]&63)|128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func raw(v any) json.RawMessage {
	out, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return out
}

type till struct {
	base    string
	client  *http.Client
	token   string
	cashier string
	device  string
}

// do returns the status and body. A cashier token is sent only when held, so
// the unauthenticated refusal can be exercised with the same helper.
func (t till) do(method, path string, body any) (int, map[string]any) {
	var reader *bytes.Reader
	if body != nil {
		reader = bytes.NewReader(raw(body))
	} else {
		reader = bytes.NewReader(nil)
	}
	req, err := http.NewRequest(method, t.base+path, reader)
	if err != nil {
		panic(err)
	}
	req.Header.Set("Authorization", "Bearer "+t.token)
	req.Header.Set("X-Schema-Version", "1")
	req.Header.Set("Content-Type", "application/json")
	if t.cashier != "" {
		req.Header.Set("X-Cashier-Token", t.cashier)
	}
	resp, err := t.client.Do(req)
	if err != nil {
		panic(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func errorCode(body map[string]any) string {
	e, ok := body["error"].(map[string]any)
	if !ok {
		return ""
	}
	code, _ := e["code"].(string)
	return code
}

func data(body map[string]any) map[string]any {
	d, _ := body["data"].(map[string]any)
	return d
}

func run() error {
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, os.Getenv("MIGRATE_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer pool.Close()

	tenant, outlet, register := uuid(), uuid(), uuid()
	if _, err := pool.Exec(ctx, "INSERT INTO tenants(id,name,slug) VALUES($1::uuid,'Till verification',$1::uuid::text)", tenant); err != nil {
		return err
	}
	defer func() {
		// Created by this invocation, never supplied by a user.
		if _, err := pool.Exec(context.Background(), "DELETE FROM jobs.river_job WHERE args->>'tenant_id'=$1", tenant); err != nil {
			fmt.Fprintln(os.Stderr, "job cleanup:", err)
		}
		if _, err := pool.Exec(context.Background(), "DELETE FROM tenants WHERE id=$1", tenant); err != nil {
			fmt.Fprintln(os.Stderr, "fixture cleanup:", err)
		}
	}()
	if _, err := pool.Exec(ctx, "INSERT INTO outlets(id,tenant_id,name) VALUES($1,$2,'Outlet')", outlet, tenant); err != nil {
		return err
	}
	if _, err := pool.Exec(ctx, "INSERT INTO pos_registers(id,tenant_id,outlet_id,name) VALUES($1,$2,$3,'Till 1')", register, tenant, outlet); err != nil {
		return err
	}

	pin, err := bcrypt.GenerateFromPassword([]byte("2468"), 10)
	if err != nil {
		return err
	}
	var sari, budi, manager string
	if err := pool.QueryRow(ctx, "INSERT INTO employees(tenant_id,name,role,pin_hash) VALUES($1,'Sari','cashier',$2) RETURNING id::text", tenant, string(pin)).Scan(&sari); err != nil {
		return err
	}
	if err := pool.QueryRow(ctx, "INSERT INTO employees(tenant_id,name,role,pin_hash) VALUES($1,'Budi','cashier',$2) RETURNING id::text", tenant, string(pin)).Scan(&budi); err != nil {
		return err
	}
	if err := pool.QueryRow(ctx, "INSERT INTO employees(tenant_id,name,role) VALUES($1,'Mira','manager') RETURNING id::text", tenant).Scan(&manager); err != nil {
		return err
	}

	var category, product string
	if err := pool.QueryRow(ctx, "INSERT INTO categories(tenant_id,name) VALUES($1,'Minuman') RETURNING id::text", tenant).Scan(&category); err != nil {
		return err
	}
	if err := pool.QueryRow(ctx, "INSERT INTO products(tenant_id,category_id,name,price) VALUES($1,$2,'Kopi',10000) RETURNING id::text", tenant, category).Scan(&product); err != nil {
		return err
	}

	newDevice := func() till {
		secret := make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			panic(err)
		}
		token := hex.EncodeToString(secret)
		id := uuid()
		if _, err := pool.Exec(ctx, "INSERT INTO devices(id,tenant_id,outlet_id,pos_register_id,device_uuid,token_sha256,token_expires_at) VALUES($1::uuid,$2,$3,$4,$1::uuid::text,$5,now()+interval '1 hour')",
			id, tenant, outlet, register, devices.HashToken(token)); err != nil {
			panic(err)
		}
		client := &http.Client{Timeout: 30 * time.Second}
		if os.Getenv("VERIFY_INSECURE_TLS") == "1" {
			client.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}} // local CA only
		}
		base := os.Getenv("VERIFY_BASE_URL")
		if base == "" {
			base = "http://127.0.0.1:9000"
		}
		return till{base: base, client: client, token: token, device: id}
	}

	a, b := newDevice(), newDevice()

	fmt.Println("cashier sign-in")
	status, body := a.do("POST", "/api/v2/till/login", map[string]any{"employee_id": sari, "pin": "0000"})
	check("a wrong PIN is refused", status == 409 && errorCode(body) == "invalid_pin", "got %d %s", status, errorCode(body))

	status, body = a.do("POST", "/api/v2/till/login", map[string]any{"employee_id": sari, "pin": "2468"})
	check("the right PIN returns a cashier token", status == 200 && data(body)["token"] != nil, "got %d %s", status, errorCode(body))
	a.cashier, _ = data(body)["token"].(string)

	status, body = b.do("POST", "/api/v2/till/login", map[string]any{"employee_id": sari, "pin": "2468"})
	if status != 200 {
		check("a second device can sign the same cashier in", false, "got %d %s", status, errorCode(body))
	} else {
		b.cashier, _ = data(body)["token"].(string)
		check("a second device can sign the same cashier in", true, "")
	}

	fmt.Println("\nclaiming the drawer")
	session := wire.Session{
		Id: uuid(), Revision: 1, EmployeeId: &sari, EmployeeName: "Sari",
		OpenedAtMs: time.Now().UnixMilli(), OpeningCash: 100000,
	}
	anonymous := till{base: a.base, client: a.client, token: a.token}
	status, body = anonymous.do("POST", "/api/v2/till/sessions/open", session)
	check("opening without a cashier token is refused", status == 409 && errorCode(body) == "cashier_auth_required", "got %d %s", status, errorCode(body))

	status, body = a.do("POST", "/api/v2/till/sessions/open", session)
	opened := data(body)
	check("the first device claims the drawer", status == 200 && opened["session"] != nil, "got %d %s", status, errorCode(body))
	start, _ := opened["receipt_start"].(float64)
	end, _ := opened["receipt_end"].(float64)
	check("the claim carries a receipt range", end-start == 99999, "got %.0f..%.0f", start, end)

	_, replay := a.do("POST", "/api/v2/till/sessions/open", session)
	check("a lost reply replays the same claim", fmt.Sprint(data(replay)) == fmt.Sprint(opened), "the replay differed")

	other := wire.Session{
		Id: uuid(), Revision: 1, EmployeeId: &sari, EmployeeName: "Sari",
		OpenedAtMs: time.Now().UnixMilli(), OpeningCash: 50000,
	}
	status, body = b.do("POST", "/api/v2/till/sessions/open", other)
	check("the second device cannot take an open drawer", status == 409 &&
		(errorCode(body) == "register_busy" || errorCode(body) == "cashier_busy"), "got %d %s", status, errorCode(body))

	status, body = a.do("GET", "/api/v2/till/sessions/current", nil)
	check("the holder sees its own claim", status == 200 && data(body)["session"] != nil, "got %d %s", status, errorCode(body))

	fmt.Println("\nselling")
	movement := wire.StockMovement{
		Id: uuid(), Revision: 1, ProductId: product, ProductName: "Kopi",
		Reason: "sale", DeltaQty: -2, OccurredAtMs: time.Now().UnixMilli(), EmployeeName: "Sari",
	}
	effects := []wire.StockMovement{movement}
	order := wire.Order{
		Id: uuid(), Revision: 1, BusinessDate: time.Now().UTC().Format(time.DateOnly),
		Number: fmt.Sprintf("%.0f", start), PlacedAtMs: time.Now().UnixMilli(),
		Type: "dine_in", Status: "paid", PosSessionId: session.Id, CashierId: &sari,
		Subtotal: 20000, Total: 20000, AmountPaid: 20000, PaymentMethod: "cash", CashierName: "Sari",
		Items: []wire.OrderItem{{
			Id: uuid(), ProductId: &product, ProductName: "Kopi", Quantity: 2, UnitPrice: 10000,
			Modifiers: []wire.OrderItemModifier{},
		}},
		StockMovements: &effects,
	}
	status, body = a.do("POST", "/api/v2/sync/push", wire.PushRequest{
		Batches: []wire.PushBatch{{Entity: "orders", Rows: []json.RawMessage{raw(order)}}},
	})
	results, _ := body["results"].([]any)
	accepted := status == 200 && len(results) == 1 && results[0].(map[string]any)["status"] == "accepted"
	check("a receipt and its stock effect are accepted together", accepted, "got %d %v", status, results)

	var qty int64
	if err := pool.QueryRow(ctx, "SELECT qty_on_hand FROM outlet_stock WHERE tenant_id=$1 AND product_id=$2", tenant, product).Scan(&qty); err != nil {
		return err
	}
	check("the outlet quantity moved once", qty == -2, "got %d", qty)

	var linked int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM stock_movements WHERE tenant_id=$1 AND ref_type='order' AND ref_id=$2", tenant, order.Id).Scan(&linked); err != nil {
		return err
	}
	check("the movement is bound to the receipt, not its number", linked == 1, "got %d", linked)

	fmt.Println("\nreading history from another device")
	status, body = b.do("GET", "/api/v2/till/orders?day="+order.BusinessDate, nil)
	rows, _ := data(body)["rows"].([]any)
	check("the other device reads the receipt", status == 200 && len(rows) == 1, "got %d rows=%d %s", status, len(rows), errorCode(body))
	if len(rows) == 1 {
		row := rows[0].(map[string]any)
		check("the receipt carries its origin", row["id"] == order.Id && row["source_device_id"] != nil, "got %v", row["id"])
	}
	status, body = b.do("GET", "/api/v2/till/sessions/current", nil)
	check("reading history never grants the drawer", status == 200 && data(body) == nil, "got %d %v", status, body["data"])

	status, body = b.do("GET", "/api/v2/till/orders?day=not-a-date", nil)
	check("a malformed day is refused", status == 409 && errorCode(body) == "invalid_date", "got %d %s", status, errorCode(body))
	status, body = b.do("GET", "/api/v2/till/orders?day="+order.BusinessDate+"&before=tampered", nil)
	check("a tampered cursor is refused", status == 409 && errorCode(body) == "invalid_cursor", "got %d %s", status, errorCode(body))

	fmt.Println("\nhandover and close")
	status, body = a.do("POST", "/api/v2/till/login", map[string]any{"employee_id": budi, "pin": "2468"})
	if status != 200 {
		return fmt.Errorf("second cashier sign-in failed: %d %s", status, errorCode(body))
	}
	a.cashier, _ = data(body)["token"].(string)
	status, body = a.do("POST", "/api/v2/till/sessions/handover", map[string]any{"id": session.Id})
	check("the drawer hands over to the next cashier", status == 200 && data(body)["current_employee_id"] == budi, "got %d %v", status, data(body)["current_employee_id"])

	closing := session
	closing.Revision = 2
	closed := time.Now().UnixMilli()
	cash, count := int64(120000), int64(1)
	closing.ClosedAtMs, closing.CountedCash, closing.ExpectedCash = &closed, &cash, &cash

	wrong := int64(9)
	closing.OrderCount = &wrong
	_, body = a.do("POST", "/api/v2/sync/push", wire.PushRequest{
		Batches: []wire.PushBatch{{Entity: "pos_sessions", Rows: []json.RawMessage{raw(closing)}}},
	})
	results, _ = body["results"].([]any)
	code := ""
	if len(results) == 1 {
		code, _ = results[0].(map[string]any)["code"].(string)
	}
	check("closing waits for every receipt to arrive", code == "dependency_pending", "got %q", code)

	closing.OrderCount = &count
	_, body = a.do("POST", "/api/v2/sync/push", wire.PushRequest{
		Batches: []wire.PushBatch{{Entity: "pos_sessions", Rows: []json.RawMessage{raw(closing)}}},
	})
	results, _ = body["results"].([]any)
	check("the drawer closes once its receipts are in", len(results) == 1 && results[0].(map[string]any)["status"] == "accepted", "got %v", results)

	status, body = a.do("GET", "/api/v2/till/sessions/current", nil)
	check("a closed drawer is no longer current", status == 200 && data(body) == nil, "got %d %v", status, body["data"])

	fmt.Println("\nthe legacy path stays shut")
	legacy := wire.Session{
		Id: uuid(), Revision: 1, EmployeeName: "Sari",
		OpenedAtMs: time.Now().UnixMilli(), OpeningCash: 1000,
	}
	_, body = a.do("POST", "/api/v2/sync/push", wire.PushRequest{
		Batches: []wire.PushBatch{{Entity: "pos_sessions", Rows: []json.RawMessage{raw(legacy)}}},
	})
	results, _ = body["results"].([]any)
	code = ""
	if len(results) == 1 {
		code, _ = results[0].(map[string]any)["code"].(string)
	}
	check("a coordinated register refuses a pushed session", code == "register_busy", "got %q", code)

	fmt.Println("\ncontrolled takeover and late-sale recovery")
	status, body = b.do("POST", "/api/v2/till/sessions/open", other)
	check("the replacement scenario opens a fresh drawer", status == 200, "got %d %s", status, errorCode(body))
	lateMovement := wire.StockMovement{Id: uuid(), Revision: 1, ProductId: product, ProductName: "Kopi", Reason: "sale", DeltaQty: -1, OccurredAtMs: time.Now().UnixMilli(), EmployeeName: "Sari"}
	lateEffects := []wire.StockMovement{lateMovement}
	late := wire.Order{Id: uuid(), Revision: 1, BusinessDate: time.Now().UTC().Format(time.DateOnly), Number: "LATE-1", PlacedAtMs: time.Now().UnixMilli(), Type: "takeaway", Status: "paid", PosSessionId: other.Id, CashierId: &sari, Subtotal: 10000, Total: 10000, AmountPaid: 10000, PaymentMethod: "cash", CashierName: "Sari", Items: []wire.OrderItem{{Id: uuid(), ProductId: &product, ProductName: "Kopi", Quantity: 1, UnitPrice: 10000, Modifiers: []wire.OrderItemModifier{}}}, StockMovements: &lateEffects}

	pools, err := pg.OpenPools(ctx, os.Getenv("DATABASE_URL"), os.Getenv("UNSCOPED_DATABASE_URL"), pg.Limits{MaxConns: 4, MinConns: 1}, pg.Limits{MaxConns: 2, MinConns: 1})
	if err != nil {
		return err
	}
	defer pools.Close()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	recoveryService, err := ingest.NewService(pools, syncfeed.NewService(pools, nil, logger), logger)
	if err != nil {
		return err
	}
	takeover, err := recoveryService.ForceTakeover(ctx, tenant, ingest.ForceTakeoverInput{OperationID: uuid(), SessionID: other.Id, DeviceID: b.device, ConfirmedRegister: "Till 1", Reason: "verification lost device", Actor: ingest.RecoveryActor{ID: manager, Name: "Mira"}})
	if err != nil {
		return err
	}
	rdb, err := redisx.Open(ctx, os.Getenv("REDIS_URL"))
	if err != nil {
		return err
	}
	defer rdb.Close()
	devices.NewCachedAuthenticator(devices.NewService(pools, os.Getenv("APP_KEY")), rdb, logger).InvalidateRevoked(ctx, takeover.TokenHash, takeover.RegisterID)
	status, body = a.do("POST", "/api/v2/till/login", map[string]any{"employee_id": sari, "pin": "2468"})
	if status != 200 {
		return fmt.Errorf("replacement cashier sign-in failed: %d %s", status, errorCode(body))
	}
	a.cashier, _ = data(body)["token"].(string)
	replacement := wire.Session{
		Id: uuid(), Revision: 1, EmployeeId: &sari, EmployeeName: "Sari",
		OpenedAtMs: time.Now().UnixMilli(), OpeningCash: 70000,
	}
	status, body = a.do("POST", "/api/v2/till/sessions/open", replacement)
	check("a replacement device opens a new drawer", status == 200, "got %d %s", status, errorCode(body))

	status, _ = b.do("POST", "/api/v2/sync/push", wire.PushRequest{Batches: []wire.PushBatch{{Entity: "orders", Rows: []json.RawMessage{raw(late)}}}})
	check("the revoked device can no longer mutate the server", status == 401, "got %d", status)

	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return err
	}
	b.token = hex.EncodeToString(secret)
	if _, err := pool.Exec(ctx, `UPDATE devices SET token_sha256=$2,token_expires_at=now()+interval '1 hour',revoked_at=NULL,updated_at=now() WHERE id=$1`, b.device, devices.HashToken(b.token)); err != nil {
		return err
	}
	devices.NewCachedAuthenticator(devices.NewService(pools, os.Getenv("APP_KEY")), rdb, logger).Bump(ctx, "register", register)
	status, body = b.do("POST", "/api/v2/till/login", map[string]any{"employee_id": sari, "pin": "2468"})
	if status != 200 {
		return fmt.Errorf("reactivated cashier sign-in failed: %d %s", status, errorCode(body))
	}
	b.cashier, _ = data(body)["token"].(string)
	status, body = b.do("GET", "/api/v2/till/sessions/current?local_session_id="+other.Id, nil)
	recoveryPointer, _ := body["recovery"].(map[string]any)
	check("the recovered installation sees the forced-close case", status == 200 && data(body) == nil && recoveryPointer["id"] == takeover.RecoveryID, "got %d %v", status, body)
	status, body = b.do("POST", "/api/v2/sync/push", wire.PushRequest{Batches: []wire.PushBatch{{Entity: "orders", Rows: []json.RawMessage{raw(late)}}}})
	results, _ = body["results"].([]any)
	lateResult := results[0].(map[string]any)
	check("a late sale is quarantined once", status == 200 && lateResult["code"] == "recovery_required" && lateResult["recovery_id"] == takeover.RecoveryID, "got %d %v", status, lateResult)
	b.do("POST", "/api/v2/sync/push", wire.PushRequest{Batches: []wire.PushBatch{{Entity: "orders", Rows: []json.RawMessage{raw(late)}}}})
	var quarantined int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM till_recovery_items WHERE recovery_id=$1", takeover.RecoveryID).Scan(&quarantined); err != nil {
		return err
	}
	check("an exact late retry creates one recovery item", quarantined == 1, "got %d", quarantined)
	cases, err := recoveryService.ListRecoveries(ctx, tenant)
	if err != nil {
		return err
	}
	var itemID string
	for _, c := range cases {
		if c.ID == takeover.RecoveryID && len(c.Items) == 1 {
			itemID = c.Items[0].ID
		}
	}
	if itemID == "" {
		return fmt.Errorf("recovery item not found")
	}
	if err := recoveryService.AcceptRecoveryItem(ctx, tenant, ingest.RecoveryActor{ID: manager, Name: "Mira"}, takeover.RecoveryID, itemID); err != nil {
		return err
	}
	_, body = b.do("POST", "/api/v2/sync/push", wire.PushRequest{Batches: []wire.PushBatch{{Entity: "orders", Rows: []json.RawMessage{raw(late)}}}})
	results, _ = body["results"].([]any)
	check("an exact retry after approval is accepted", len(results) == 1 && results[0].(map[string]any)["status"] == "accepted", "got %v", results)
	var orderCount, movementCount, dirtyCount int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM orders WHERE id=$1", late.Id).Scan(&orderCount); err != nil {
		return err
	}
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM stock_movements WHERE ref_id=$1", late.Id).Scan(&movementCount); err != nil {
		return err
	}
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM report_dirty_slices WHERE tenant_id=$1 AND outlet_id=$2 AND business_date=$3", tenant, outlet, late.BusinessDate).Scan(&dirtyCount); err != nil {
		return err
	}
	check("approval writes one order, one stock effect, and a dirty report slice", orderCount == 1 && movementCount == 1 && dirtyCount == 1, "orders=%d movements=%d dirty=%d", orderCount, movementCount, dirtyCount)
	var replacementOpening int64
	var replacementCounted *int64
	if err := pool.QueryRow(ctx, "SELECT opening_cash,counted_cash FROM pos_sessions WHERE id=$1", replacement.Id).Scan(&replacementOpening, &replacementCounted); err != nil {
		return err
	}
	check("recovery leaves the replacement drawer cash unchanged", replacementOpening == 70000 && replacementCounted == nil, "opening=%d counted=%v", replacementOpening, replacementCounted)
	fmt.Printf("F0_EVIDENCE device_uuid=%s session_uuid=%s replacement_session_uuid=%s order_uuid=%s recovery_id=%s orders=%d movements=%d dirty_slices=%d\n", b.device, other.Id, replacement.Id, late.Id, takeover.RecoveryID, orderCount, movementCount, dirtyCount)

	return nil
}
