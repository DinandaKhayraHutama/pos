package reporting_test

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/ingest"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/reporting"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
)

func uuid() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func ptr[T any](v T) *T { return &v }

// fixture is a merchant whose orders arrive the way a till's do: through the
// ingest service, so every payload is shaped exactly as production stores it.
type fixture struct {
	t         *testing.T
	db        pgtest.DB
	ingest    *ingest.Service
	svc       *reporting.Service
	logger    *slog.Logger
	exportDir string

	tenantID, otherTenantID string
	outletA, outletB        string
	till                    devices.Binding
	sessionID               string
	drinks, food            string
	coffee, rice            string
	cashierSiti             string
	// day is today on the merchant's clock, so it always has a partition.
	day time.Time

	// The second branch, its own till and its own cashier. Reconciliation is
	// only worth asserting across more than one of each: a single outlet
	// cannot show a per-outlet total disagreeing with the chain's.
	tillB        devices.Binding
	sessionB     string
	cashierRina  string
	secondRegist string
}

func setup(t *testing.T, edit ...func(*reporting.Options)) *fixture {
	t.Helper()
	db := pgtest.New(t)
	ctx := context.Background()
	f := &fixture{t: t, db: db, exportDir: t.TempDir(), logger: slog.New(slog.NewTextHandler(io.Discard, nil))}

	var err error
	f.ingest, err = ingest.NewService(db.Pools, syncfeed.NewService(db.Pools, nil, f.logger), f.logger)
	require.NoError(t, err)
	opts := reporting.Options{ExportDir: f.exportDir, LinkBaseURL: "https://pos.test", LinkTTL: time.Hour}
	for _, e := range edit {
		e(&opts)
	}
	f.svc, err = reporting.NewService(db.Pools, f.logger, opts)
	require.NoError(t, err)

	scan := func(dst *string, sql string, args ...any) {
		t.Helper()
		require.NoError(t, db.Owner.QueryRow(ctx, sql, args...).Scan(dst))
	}
	scan(&f.tenantID, `INSERT INTO tenants (name, slug) VALUES ('Warung Laporan', gen_random_uuid()::text) RETURNING id::text`)
	scan(&f.otherTenantID, `INSERT INTO tenants (name, slug) VALUES ('Warung Lain', gen_random_uuid()::text) RETURNING id::text`)
	scan(&f.outletA, `INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Kemang') RETURNING id::text`, f.tenantID)
	scan(&f.outletB, `INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Bintaro') RETURNING id::text`, f.tenantID)
	// Current names differ from what receipts snapshotted: a report shows the
	// current one, and a deleted product its newest snapshot.
	scan(&f.drinks, `INSERT INTO categories (tenant_id, name) VALUES ($1, 'Minuman Dingin') RETURNING id::text`, f.tenantID)
	scan(&f.food, `INSERT INTO categories (tenant_id, name) VALUES ($1, 'Makanan') RETURNING id::text`, f.tenantID)
	scan(&f.coffee, `INSERT INTO products (tenant_id, category_id, name, price) VALUES ($1, $2, 'Kopi Susu Gula Aren', 15000) RETURNING id::text`, f.tenantID, f.drinks)
	scan(&f.rice, `INSERT INTO products (tenant_id, category_id, name, price, deleted_at) VALUES ($1, $2, 'Nasi Goreng Spesial', 25000, now()) RETURNING id::text`, f.tenantID, f.food)
	f.cashierSiti = uuid()

	f.till.Tenant.ID, f.till.Outlet.ID = f.tenantID, f.outletA
	scan(&f.till.Register.ID, `INSERT INTO pos_registers (tenant_id, outlet_id, name) VALUES ($1, $2, 'Kasir 1') RETURNING id::text`, f.tenantID, f.outletA)
	scan(&f.till.Device.ID, `INSERT INTO devices (tenant_id, outlet_id, pos_register_id, device_uuid) VALUES ($1, $2, $3, 'tablet') RETURNING id::text`,
		f.tenantID, f.outletA, f.till.Register.ID)

	// A second till in the SAME branch, so "one outlet" is never accidentally
	// "one register" in a scoping assertion.
	scan(&f.secondRegist, `INSERT INTO pos_registers (tenant_id, outlet_id, name) VALUES ($1, $2, 'Kasir 2') RETURNING id::text`,
		f.tenantID, f.outletA)

	f.tillB.Tenant.ID, f.tillB.Outlet.ID = f.tenantID, f.outletB
	scan(&f.tillB.Register.ID, `INSERT INTO pos_registers (tenant_id, outlet_id, name) VALUES ($1, $2, 'Bintaro 1') RETURNING id::text`,
		f.tenantID, f.outletB)
	scan(&f.tillB.Device.ID, `INSERT INTO devices (tenant_id, outlet_id, pos_register_id, device_uuid) VALUES ($1, $2, $3, 'tablet-b') RETURNING id::text`,
		f.tenantID, f.outletB, f.tillB.Register.ID)
	f.cashierRina = uuid()

	f.day = reporting.Date(time.Now(), jakarta)
	f.sessionID, f.sessionB = uuid(), uuid()
	f.accepted(f.push("pos_sessions", wire.Session{
		Id: f.sessionID, Revision: 1, EmployeeName: "Siti",
		OpenedAtMs: time.Now().Add(-8 * time.Hour).UnixMilli(), OpeningCash: 100000,
	}))
	f.accepted(f.pushAs(f.tillB, "pos_sessions", wire.Session{
		Id: f.sessionB, Revision: 1, EmployeeName: "Rina",
		OpenedAtMs: time.Now().Add(-8 * time.Hour).UnixMilli(), OpeningCash: 50000,
	}))
	return f
}

func (f *fixture) push(entity string, values ...any) []wire.PushResult {
	f.t.Helper()
	return f.pushAs(f.till, entity, values...)
}

// pushAs is the same upload from a named till, so a fixture can ring up two
// branches without the second one borrowing the first one's identity.
func (f *fixture) pushAs(from devices.Binding, entity string, values ...any) []wire.PushResult {
	f.t.Helper()
	rows := make([]json.RawMessage, len(values))
	for i, v := range values {
		b, err := json.Marshal(v)
		require.NoError(f.t, err)
		rows[i] = b
	}
	return f.ingest.Push(context.Background(), from, wire.PushRequest{Batches: []wire.PushBatch{{Entity: entity, Rows: rows}}}).Results
}

func (f *fixture) accepted(results []wire.PushResult) {
	f.t.Helper()
	for _, r := range results {
		require.Equal(f.t, wire.PushResultStatus("accepted"), r.Status, "%+v", r)
	}
}

// at is a time on the fixture's business day, on the merchant's clock.
func (f *fixture) at(hour, minute int) time.Time {
	return time.Date(f.day.Year(), f.day.Month(), f.day.Day(), hour, minute, 0, 0, jakarta)
}

type saleLine struct {
	productID, categoryID *string
	name, categoryName    string
	price                 int64
	cost                  *int64
	qty                   int
}

func (f *fixture) order(status string, placed time.Time, cashierID *string, cashier, payment string,
	discount, tax, service int64, lines []saleLine, edit ...func(*wire.Order)) wire.Order {
	var subtotal int64
	items := make([]wire.OrderItem, len(lines))
	for i, l := range lines {
		subtotal += l.price * int64(l.qty)
		items[i] = wire.OrderItem{
			Id: uuid(), ProductId: l.productID, ProductName: l.name, CategoryId: l.categoryID,
			UnitPrice: l.price, UnitCost: l.cost, Quantity: l.qty, Modifiers: []wire.OrderItemModifier{},
		}
		if l.categoryName != "" {
			items[i].CategoryName = ptr(l.categoryName)
		}
	}
	total := subtotal - discount + tax + service
	o := wire.Order{
		Id: uuid(), Revision: 1, BusinessDate: f.day.Format(time.DateOnly), Number: "R-" + uuid()[:8],
		PlacedAtMs: placed.UnixMilli(), Type: "dine_in", Status: wire.OrderStatus(status), PosSessionId: f.sessionID,
		Subtotal: subtotal, Discount: discount, Tax: tax, ServiceChargeAmount: service, Total: total, AmountPaid: total,
		PaymentMethod: payment, CashierId: cashierID, CashierName: cashier, Items: items,
	}
	for _, e := range edit {
		e(&o)
	}
	return o
}

// seedDay rings up one day at outlet A:
//
//   - 09:15, Siti, cash: 2 × Kopi Susu (cost 5000) + Nasi Goreng (no cost),
//     subtotal 55000, promo "Happy Hour" −5500, PB1 4950 → 54450;
//   - 13:40, Budi (no cashier id), QRIS: Kopi Susu + Air Mineral (no product,
//     no category), subtotal 20000, PB1 2000, service 1000 → 23000;
//   - 11:00, cancelled by "Manajer A": 2 × Kopi Susu → 30000;
//   - 15:00, refunded 12000 of 15000 by "Owner": Nasi Goreng.
func (f *fixture) seedDay() {
	f.t.Helper()
	cost := int64(5000)
	coffee := func(qty int) saleLine {
		return saleLine{productID: ptr(f.coffee), categoryID: ptr(f.drinks), name: "Kopi Susu", categoryName: "Minuman", price: 15000, cost: &cost, qty: qty}
	}
	rice := func(price int64) saleLine {
		return saleLine{productID: ptr(f.rice), categoryID: ptr(f.food), name: "Nasi Goreng", categoryName: "Makanan", price: price, qty: 1}
	}
	water := saleLine{name: "Air Mineral", price: 5000, qty: 1}

	f.accepted(f.push("orders",
		f.order("paid", f.at(9, 15), ptr(f.cashierSiti), "Siti", "cash", 5500, 4950, 0, []saleLine{coffee(2), rice(25000)},
			func(o *wire.Order) { o.PromoName = ptr("Happy Hour") }),
		f.order("paid", f.at(13, 40), nil, "Budi", "qris", 0, 2000, 1000, []saleLine{coffee(1), water}),
		f.order("cancelled", f.at(11, 0), ptr(f.cashierSiti), "Siti", "cash", 0, 0, 0, []saleLine{coffee(2)},
			func(o *wire.Order) { o.AuthorizedBy, o.VoidReason = ptr("Manajer A"), ptr("Salah input") }),
		f.order("refunded", f.at(15, 0), nil, "Budi", "cash", 0, 0, 0, []saleLine{rice(15000)},
			func(o *wire.Order) {
				o.AuthorizedBy, o.VoidReason, o.RefundedAmount = ptr("Owner"), ptr("Komplain"), ptr(int64(12000))
			}),
	))
}

// seedBintaro rings up the second branch on the same business day:
//
//   - 10:00, Rina, card: 2 × Kopi Susu (cost 5000) + Air Mineral, subtotal
//     35000, no discount, PB1 3500 → 38500;
//   - 12:00, refunded IN FULL by "Owner": Kopi Susu at 15000, PB1 1500 →
//     16500, refunded_amount 16500.
//
// The full refund is the case the partial one at Kemang does not cover: the
// money handed back equals the receipt, so "refunded amount" and "sales
// return" are two different numbers on the same order — 16500 against 15000,
// because tax came back with the money but was never a sale.
func (f *fixture) seedBintaro() {
	f.t.Helper()
	cost := int64(5000)
	coffee := func(qty int) saleLine {
		return saleLine{productID: ptr(f.coffee), categoryID: ptr(f.drinks), name: "Kopi Susu", categoryName: "Minuman", price: 15000, cost: &cost, qty: qty}
	}
	water := saleLine{name: "Air Mineral", price: 5000, qty: 1}

	full := f.order("refunded", f.at(12, 0), ptr(f.cashierRina), "Rina", "cash", 0, 1500, 0, []saleLine{coffee(1)},
		func(o *wire.Order) {
			o.PosSessionId = f.sessionB
			o.AuthorizedBy, o.VoidReason, o.RefundedAmount = ptr("Owner"), ptr("Gelas pecah"), ptr(int64(16500))
		})
	f.accepted(f.pushAs(f.tillB, "orders",
		f.order("paid", f.at(10, 0), ptr(f.cashierRina), "Rina", "card", 0, 3500, 0, []saleLine{coffee(2), water},
			func(o *wire.Order) { o.PosSessionId = f.sessionB }),
		full,
	))
}

func (f *fixture) recompute(outletID string) {
	f.t.Helper()
	clean, err := f.svc.RecomputeSlice(context.Background(), f.tenantID, outletID, f.day)
	require.NoError(f.t, err)
	require.True(f.t, clean)
}

func (f *fixture) count(sql string, args ...any) int {
	f.t.Helper()
	var n int
	require.NoError(f.t, f.db.Owner.QueryRow(context.Background(), sql, args...).Scan(&n))
	return n
}
