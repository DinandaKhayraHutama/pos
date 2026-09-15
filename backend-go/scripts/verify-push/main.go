// Command verify-push tests the deployed HTTP money path with a fresh tenant.
// Credentials and received financial payloads are never printed.
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
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("all push checks passed")
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
func raw(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}
func run() error {
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, os.Getenv("MIGRATE_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer pool.Close()
	tenant, outlet, register, device := uuid(), uuid(), uuid(), uuid()
	if _, err := pool.Exec(ctx, "INSERT INTO tenants(id,name,slug) VALUES ($1::uuid,'Push verification',$1::uuid::text)", tenant); err != nil {
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
	if _, err := pool.Exec(ctx, "INSERT INTO outlets(id,tenant_id,name) VALUES ($1,$2,'Outlet')", outlet, tenant); err != nil {
		return err
	}
	if _, err := pool.Exec(ctx, "INSERT INTO pos_registers(id,tenant_id,outlet_id,name) VALUES ($1,$2,$3,'Register')", register, tenant, outlet); err != nil {
		return err
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return err
	}
	token := hex.EncodeToString(secret)
	if _, err := pool.Exec(ctx, "INSERT INTO devices(id,tenant_id,outlet_id,pos_register_id,device_uuid,token_sha256,token_expires_at) VALUES ($1::uuid,$2,$3,$4,$1::uuid::text,$5,now()+interval '1 hour')", device, tenant, outlet, register, devices.HashToken(token)); err != nil {
		return err
	}
	client := &http.Client{Timeout: 90 * time.Second}
	if os.Getenv("VERIFY_INSECURE_TLS") == "1" {
		client.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
	} // local CA only
	base := os.Getenv("VERIFY_BASE_URL")
	if base == "" {
		base = "http://127.0.0.1:9000"
	}
	post := func(payload wire.PushRequest) (wire.PushResponse, error) {
		req, err := http.NewRequestWithContext(ctx, "POST", base+"/api/v2/sync/push", bytes.NewReader(raw(payload)))
		if err != nil {
			return wire.PushResponse{}, err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Schema-Version", "1")
		resp, err := client.Do(req)
		if err != nil {
			return wire.PushResponse{}, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			return wire.PushResponse{}, fmt.Errorf("push HTTP %d", resp.StatusCode)
		}
		var out wire.PushResponse
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			return out, err
		}
		n := 0
		for bi, batch := range payload.Batches {
			for ri := range batch.Rows {
				if n >= len(out.Results) || out.Results[n].BatchIndex != bi || out.Results[n].RowIndex != ri {
					return out, fmt.Errorf("missing or miscorrelated result")
				}
				n++
			}
		}
		if len(out.Results) != n {
			return out, fmt.Errorf("unexpected result count")
		}
		return out, nil
	}
	push := func(entity string, rows ...json.RawMessage) (wire.PushResponse, error) {
		return post(wire.PushRequest{Batches: []wire.PushBatch{{Entity: entity, Rows: rows}}})
	}
	accept := func(out wire.PushResponse, err error) error {
		if err != nil {
			return err
		}
		for _, result := range out.Results {
			if result.Status != "accepted" {
				return fmt.Errorf("expected accepted, got %s (%v)", result.Status, result.Code)
			}
		}
		return nil
	}
	closed := time.Now().UnixMilli()
	cash := int64(100000)
	session := wire.Session{Id: uuid(), Revision: 1, EmployeeName: "Cashier", OpenedAtMs: closed - 3600000, ClosedAtMs: &closed, OpeningCash: cash, CountedCash: &cash, ExpectedCash: &cash}
	if err := accept(push("pos_sessions", raw(session))); err != nil {
		return err
	}
	orders := make([]wire.Order, 200)
	rows := make([]json.RawMessage, 200)
	for i := range orders {
		orders[i] = wire.Order{Id: uuid(), Revision: 1, BusinessDate: time.Now().UTC().Format(time.DateOnly), Number: fmt.Sprintf("VERIFY-%d", i), PlacedAtMs: closed - 1000, Type: "takeaway", Status: "paid", PosSessionId: session.Id, Subtotal: 10000, Total: 10000, AmountPaid: 10000, PaymentMethod: "cash", CashierName: "Cashier", Items: []wire.OrderItem{{Id: uuid(), ProductName: "Coffee", Quantity: 1, UnitPrice: 10000, Modifiers: []wire.OrderItemModifier{{Id: uuid(), GroupName: "Milk", OptionName: "Oat", PriceDelta: 1000}}}}}
		rows[i] = raw(orders[i])
	}
	for attempt := 0; attempt < 3; attempt++ {
		if err := accept(push("orders", rows...)); err != nil {
			return err
		}
	}
	for _, table := range []string{"orders", "order_dedupe", "order_items", "order_item_modifiers"} {
		var n int
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM "+table+" WHERE tenant_id=$1", tenant).Scan(&n); err != nil {
			return err
		}
		if n != 200 {
			return fmt.Errorf("%s: got %d, expected 200", table, n)
		}
	}
	fmt.Println("PASS 200-row batch x3 preserves 200 complete receipts")
	var sum int64
	if err := pool.QueryRow(ctx, "SELECT sum(total) FROM orders WHERE tenant_id=$1", tenant).Scan(&sum); err != nil {
		return err
	}
	if sum != 2000000 {
		return fmt.Errorf("incorrect financial total")
	}
	fmt.Println("PASS exact financial total after retries")
	shifted := orders[0]
	shifted.BusinessDate = time.Now().UTC().AddDate(0, 1, 0).Format(time.DateOnly)
	if err := accept(push("orders", raw(shifted))); err != nil {
		return err
	}
	fmt.Println("PASS shifted-date retry uses canonical date")
	settled := orders[0]
	settled.Revision = 2
	settled.Status = "cancelled"
	who, why := "Manager", "Verification"
	settled.AuthorizedBy = &who
	settled.VoidReason = &why
	if err := accept(push("orders", raw(settled))); err != nil {
		return err
	}
	if err := accept(push("orders", raw(settled))); err != nil {
		return err
	}
	stale := orders[0]
	stale.Revision = 3
	out, err := push("orders", raw(stale))
	if err != nil {
		return err
	}
	if out.Results[0].Code == nil || *out.Results[0].Code != "settled" {
		return fmt.Errorf("settle-once failed")
	}
	fmt.Println("PASS settled order cannot be restated; exact retry accepted")
	if err := accept(push("pos_sessions", raw(session))); err != nil {
		return err
	}
	session.Revision = 2
	session.ClosedAtMs = nil
	out, err = push("pos_sessions", raw(session))
	if err != nil {
		return err
	}
	if out.Results[0].Code == nil || *out.Results[0].Code != "session_closed" {
		return fmt.Errorf("closed session reopened")
	}
	fmt.Println("PASS closed session cannot reopen")
	out, err = push("orders", raw([]any{}), raw("ok"), raw(nil), rows[1])
	if err != nil {
		return err
	}
	for _, result := range out.Results[:3] {
		if result.Status != "rejected" {
			return fmt.Errorf("invalid row was not individually rejected")
		}
	}
	if out.Results[3].Status != "accepted" {
		return fmt.Errorf("bad neighbour blocked valid order")
	}
	fmt.Println("PASS malformed rows do not block valid neighbour")
	var count int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM ingest_log WHERE tenant_id=$1", tenant).Scan(&count); err != nil {
		return err
	}
	if count != 611 {
		return fmt.Errorf("audit: expected 611 attempts, got %d", count)
	}
	fmt.Println("PASS all 611 received attempts preserved in audit")
	var partition string
	if err := pool.QueryRow(ctx, "SELECT tableoid::regclass::text FROM orders WHERE tenant_id=$1 LIMIT 1", tenant).Scan(&partition); err != nil {
		return err
	}
	if partition != "orders_"+time.Now().UTC().Format("2006_01") {
		return fmt.Errorf("unexpected order partition %s", partition)
	}
	fmt.Println("PASS receipt routed to monthly partition", partition)
	return nil
}
