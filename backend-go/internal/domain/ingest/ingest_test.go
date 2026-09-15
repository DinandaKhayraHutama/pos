package ingest

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
	"github.com/jackc/pgx/v5"
	"github.com/stretchr/testify/require"
)

type fixture struct {
	db      pgtest.DB
	svc     *Service
	binding devices.Binding
}

func setup(t *testing.T) *fixture {
	t.Helper()
	db := pgtest.New(t)
	f := &fixture{db: db}
	ctx := context.Background()
	require.NoError(t, db.Owner.QueryRow(ctx, "INSERT INTO tenants(name,slug) VALUES ('ingest', gen_random_uuid()::text) RETURNING id").Scan(&f.binding.Tenant.ID))
	require.NoError(t, db.Owner.QueryRow(ctx, "INSERT INTO outlets(tenant_id,name) VALUES ($1,'outlet') RETURNING id", f.binding.Tenant.ID).Scan(&f.binding.Outlet.ID))
	require.NoError(t, db.Owner.QueryRow(ctx, "INSERT INTO pos_registers(tenant_id,outlet_id,name) VALUES ($1,$2,'register') RETURNING id", f.binding.Tenant.ID, f.binding.Outlet.ID).Scan(&f.binding.Register.ID))
	require.NoError(t, db.Owner.QueryRow(ctx, "INSERT INTO devices(tenant_id,outlet_id,pos_register_id,device_uuid) VALUES ($1,$2,$3,'tablet') RETURNING id", f.binding.Tenant.ID, f.binding.Outlet.ID, f.binding.Register.ID).Scan(&f.binding.Device.ID))
	var err error
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	f.svc, err = NewService(db.Pools, syncfeed.NewService(db.Pools, nil, logger), logger)
	require.NoError(t, err)
	return f
}
func (f *fixture) id(t *testing.T) string {
	t.Helper()
	var id string
	require.NoError(t, f.db.Owner.QueryRow(context.Background(), "SELECT gen_random_uuid()::text").Scan(&id))
	return id
}
func (f *fixture) session(t *testing.T, closed bool) wire.Session {
	t.Helper()
	s := wire.Session{Id: f.id(t), Revision: 1, EmployeeName: "Sari", OpenedAtMs: time.Now().Add(-time.Hour).UnixMilli(), OpeningCash: 100000}
	if closed {
		now := time.Now().UnixMilli()
		counted, expected := int64(120000), int64(120000)
		s.ClosedAtMs = &now
		s.CountedCash = &counted
		s.ExpectedCash = &expected
	}
	return s
}
func (f *fixture) order(t *testing.T, session string) wire.Order {
	t.Helper()
	return wire.Order{Id: f.id(t), Revision: 1, BusinessDate: time.Now().UTC().Format(time.DateOnly), Number: "TEST-1", PlacedAtMs: time.Now().UnixMilli(), Type: "dine_in", Status: "paid", PosSessionId: session, Subtotal: 20000, Total: 20000, AmountPaid: 20000, PaymentMethod: "cash", CashierName: "Sari", Items: []wire.OrderItem{{Id: f.id(t), ProductName: "Kopi", Quantity: 2, UnitPrice: 10000, Modifiers: []wire.OrderItemModifier{{Id: f.id(t), GroupName: "Milk", OptionName: "Oat", PriceDelta: 1000}}}}}
}
func request(entity string, values ...any) wire.PushRequest {
	rows := make([]json.RawMessage, len(values))
	for i, value := range values {
		rows[i] = encode(value)
	}
	return wire.PushRequest{Batches: []wire.PushBatch{{Entity: entity, Rows: rows}}}
}
func (f *fixture) push(entity string, values ...any) []wire.PushResult {
	return f.svc.Push(context.Background(), f.binding, request(entity, values...)).Results
}
func accepted(t *testing.T, rows []wire.PushResult) {
	t.Helper()
	for _, row := range rows {
		require.Equal(t, wire.PushResultStatus("accepted"), row.Status, "%+v", row)
	}
}
func (f *fixture) count(t *testing.T, table string) int64 {
	t.Helper()
	var n int64
	require.NoError(t, f.db.Owner.QueryRow(context.Background(), "SELECT count(*) FROM "+pgx.Identifier{table}.Sanitize()).Scan(&n))
	return n
}

func TestBatch200RetriedThreeTimesPreservesBusinessState(t *testing.T) {
	f := setup(t)
	session := f.session(t, true)
	accepted(t, f.push("pos_sessions", session))
	values := make([]any, 200)
	for i := range values {
		values[i] = f.order(t, session.Id)
	}
	for attempt := 0; attempt < 3; attempt++ {
		rows := f.push("orders", values...)
		require.Len(t, rows, 200)
		accepted(t, rows)
	}
	require.EqualValues(t, 200, f.count(t, "orders"))
	require.EqualValues(t, 200, f.count(t, "order_dedupe"))
	require.EqualValues(t, 200, f.count(t, "order_items"))
	require.EqualValues(t, 200, f.count(t, "order_item_modifiers"))
	require.EqualValues(t, 601, f.count(t, "ingest_log"))
	var generation, jobs int64
	require.NoError(t, f.db.Owner.QueryRow(context.Background(), "SELECT generation FROM report_dirty_slices").Scan(&generation))
	require.EqualValues(t, 200, generation)
	require.NoError(t, f.db.Owner.QueryRow(context.Background(), "SELECT count(*) FROM jobs.river_job WHERE kind='report_slice'").Scan(&jobs))
	require.EqualValues(t, 1, jobs)
}

func TestSessionClosedOnceAndBusyHolder(t *testing.T) {
	f := setup(t)
	session := f.session(t, false)
	accepted(t, f.push("pos_sessions", session))
	rows := f.push("pos_sessions", f.session(t, false))
	require.Equal(t, wire.PushResultCode("register_busy"), *rows[0].Code)
	require.Equal(t, session.Id, *rows[0].HolderSessionId)
	closed := session
	closed.Revision = 2
	now := time.Now().UnixMilli()
	counted, expected := int64(120000), int64(120000)
	closed.ClosedAtMs = &now
	closed.CountedCash = &counted
	closed.ExpectedCash = &expected
	accepted(t, f.push("pos_sessions", closed))
	accepted(t, f.push("pos_sessions", closed))
	session.Revision = 3
	require.Equal(t, wire.PushResultCode("session_closed"), *f.push("pos_sessions", session)[0].Code)
	closed.Revision = 3
	counted = 90000
	require.Equal(t, wire.PushResultCode("session_closed"), *f.push("pos_sessions", closed)[0].Code)
	accepted(t, f.push("pos_sessions", f.session(t, false)))
}

func TestSettlementRetryAndShiftedDate(t *testing.T) {
	f := setup(t)
	session := f.session(t, true)
	accepted(t, f.push("pos_sessions", session))
	order := f.order(t, session.Id)
	accepted(t, f.push("orders", order))
	shifted := order
	shifted.BusinessDate = time.Now().UTC().AddDate(0, 1, 0).Format(time.DateOnly)
	accepted(t, f.push("orders", shifted))
	require.EqualValues(t, 1, f.count(t, "orders"))
	order.Revision = 2
	order.Status = "refunded"
	who, why := "Manager", "Mistake"
	refund := int64(20000)
	order.AuthorizedBy = &who
	order.VoidReason = &why
	order.RefundedAmount = &refund
	accepted(t, f.push("orders", order))
	accepted(t, f.push("orders", order))
	shifted.Revision = 3
	rows := f.push("orders", shifted)
	require.Equal(t, wire.PushResultCode("settled"), *rows[0].Code)
	var status string
	require.NoError(t, f.db.Owner.QueryRow(context.Background(), "SELECT status FROM orders").Scan(&status))
	require.Equal(t, "refunded", status)
}

func TestInvalidRowsAndMissingDependenciesNeverBlockNeighbours(t *testing.T) {
	f := setup(t)
	session := f.session(t, true)
	order := f.order(t, session.Id)
	require.Equal(t, wire.PushResultStatus("retry"), f.push("orders", order)[0].Status)
	require.Zero(t, f.count(t, "order_dedupe"))
	accepted(t, f.push("pos_sessions", session))
	rows := f.push("orders", []any{}, "ok", nil, map[string]any{"id": "bad"}, order)
	require.Len(t, rows, 5)
	for _, row := range rows[:4] {
		require.Equal(t, wire.PushResultStatus("rejected"), row.Status)
	}
	accepted(t, rows[4:])
	require.EqualValues(t, 1, f.count(t, "orders"))
	require.EqualValues(t, 7, f.count(t, "ingest_log"))
	require.Equal(t, wire.PushResultCode("unknown_entity"), *f.push("employees", map[string]any{"name": "forged"})[0].Code)
}

func TestConcurrentSameUUIDCreatesExactlyOneReceipt(t *testing.T) {
	f := setup(t)
	session := f.session(t, true)
	accepted(t, f.push("pos_sessions", session))
	order := f.order(t, session.Id)
	var wg sync.WaitGroup
	results := make([][]wire.PushResult, 8)
	for i := range results {
		wg.Add(1)
		go func() { defer wg.Done(); results[i] = f.push("orders", order) }()
	}
	wg.Wait()
	for _, rows := range results {
		accepted(t, rows)
	}
	require.EqualValues(t, 1, f.count(t, "orders"))
	require.EqualValues(t, 1, f.count(t, "order_items"))
}

func TestNestedConflictAndQueueFailureRollBackWholeOrder(t *testing.T) {
	f := setup(t)
	session := f.session(t, true)
	accepted(t, f.push("pos_sessions", session))
	first := f.order(t, session.Id)
	accepted(t, f.push("orders", first))
	second := f.order(t, session.Id)
	second.Items[0].Modifiers[0].Id = first.Items[0].Modifiers[0].Id
	require.Equal(t, wire.PushResultCode("duplicate"), *f.push("orders", second)[0].Code)
	require.EqualValues(t, 1, f.count(t, "orders"))
	require.EqualValues(t, 1, f.count(t, "order_dedupe"))
	require.EqualValues(t, 1, f.count(t, "order_items"))
	_, err := f.db.Owner.Exec(context.Background(), "REVOKE INSERT ON jobs.river_job FROM justclick_app")
	require.NoError(t, err)
	third := f.order(t, session.Id)
	rows := f.push("orders", third)
	require.Equal(t, wire.PushResultStatus("retry"), rows[0].Status)
	require.EqualValues(t, 1, f.count(t, "orders"))
	require.EqualValues(t, 1, f.count(t, "order_dedupe"))
	require.EqualValues(t, 4, f.count(t, "ingest_log"))
}

func TestFinancialRowsAndJobsAreTenantIsolated(t *testing.T) {
	f := setup(t)
	session := f.session(t, true)
	accepted(t, f.push("pos_sessions", session))
	accepted(t, f.push("orders", f.order(t, session.Id)))
	foreign := f.id(t)
	for _, table := range []string{"pos_sessions", "orders", "order_items", "order_item_modifiers", "order_dedupe", "ingest_log", "report_dirty_slices", "jobs.river_job"} {
		t.Run(table, func(t *testing.T) {
			for _, tenant := range []string{"", foreign} {
				var n int
				require.NoError(t, pg.InTenantTx(context.Background(), f.db.Pools.Tenant, tenant, func(ctx context.Context, tx pgx.Tx) error {
					return tx.QueryRow(ctx, "SELECT count(*) FROM "+table).Scan(&n)
				}))
				require.Zero(t, n)
			}
		})
	}
}

func TestOrderIngestDoesNotWaitForTenantRowWriter(t *testing.T) {
	f := setup(t)
	session := f.session(t, true)
	accepted(t, f.push("pos_sessions", session))
	order := f.order(t, session.Id)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	blocker, err := f.db.Owner.Begin(ctx)
	require.NoError(t, err)
	defer blocker.Rollback(context.Background())
	// NO KEY UPDATE permits ordinary FK key-share checks, but conflicts with
	// the old tenant FOR UPDATE / FOR SHARE money-path serialization.
	_, err = blocker.Exec(ctx, "SELECT id FROM tenants WHERE id=$1 FOR NO KEY UPDATE", f.binding.Tenant.ID)
	require.NoError(t, err)
	accepted(t, f.svc.Push(ctx, f.binding, request("orders", order)).Results)
}

func TestArchivedIDCannotReappearAndFinancialSnapshotCannotChange(t *testing.T) {
	f := setup(t)
	session := f.session(t, true)
	accepted(t, f.push("pos_sessions", session))
	order := f.order(t, session.Id)
	accepted(t, f.push("orders", order))
	changed := order
	changed.Revision = 2
	changed.CashierName = "Changed historical name"
	require.Equal(t, wire.PushResultCode("schema_rejected"), *f.push("orders", changed)[0].Code)
	// Models an archived partition no longer visible through the parent.
	_, err := f.db.Owner.Exec(context.Background(), "DELETE FROM orders WHERE tenant_id=$1", f.binding.Tenant.ID)
	require.NoError(t, err)
	require.Equal(t, wire.PushResultCode("archived"), *f.push("orders", order)[0].Code)
	require.Zero(t, f.count(t, "orders"))
	require.EqualValues(t, 1, f.count(t, "order_dedupe"))
}

func TestADeviceCannotOverwriteAnotherRegistersReceiptOrSession(t *testing.T) {
	f := setup(t)
	session := f.session(t, true)
	accepted(t, f.push("pos_sessions", session))
	order := f.order(t, session.Id)
	accepted(t, f.push("orders", order))
	other := f.binding
	other.Register.ID, other.Device.ID = f.id(t), f.id(t)
	ctx := context.Background()
	_, err := f.db.Owner.Exec(ctx, "INSERT INTO pos_registers(id,tenant_id,outlet_id,name) VALUES ($1,$2,$3,'Other register')", other.Register.ID, other.Tenant.ID, other.Outlet.ID)
	require.NoError(t, err)
	_, err = f.db.Owner.Exec(ctx, "INSERT INTO devices(id,tenant_id,outlet_id,pos_register_id,device_uuid) VALUES ($1,$2,$3,$4,'other-tablet')", other.Device.ID, other.Tenant.ID, other.Outlet.ID, other.Register.ID)
	require.NoError(t, err)
	for entity, payload := range map[string]any{"orders": order, "pos_sessions": session} {
		rows := f.svc.Push(ctx, other, request(entity, payload)).Results
		require.Equal(t, wire.PushResultCode("duplicate"), *rows[0].Code)
	}
	require.EqualValues(t, 1, f.count(t, "orders"))
}

func TestMonthlyAndDefaultPartitionRouting(t *testing.T) {
	f := setup(t)
	session := f.session(t, true)
	accepted(t, f.push("pos_sessions", session))
	for _, offset := range []int{0, 1, 2, 3, -6} {
		order := f.order(t, session.Id)
		day := time.Now().UTC().AddDate(0, offset, 0)
		order.BusinessDate = day.Format(time.DateOnly)
		accepted(t, f.push("orders", order))
		var parent, child string
		require.NoError(t, f.db.Owner.QueryRow(context.Background(), "SELECT tableoid::regclass::text FROM orders WHERE id=$1", order.Id).Scan(&parent))
		require.NoError(t, f.db.Owner.QueryRow(context.Background(), "SELECT tableoid::regclass::text FROM order_items WHERE order_id=$1", order.Id).Scan(&child))
		suffix := day.Format("2006_01")
		if offset < 0 {
			suffix = "default"
		}
		require.Equal(t, "orders_"+suffix, parent)
		require.Equal(t, "order_items_"+suffix, child)
	}
}

func TestLockTimeoutIsRetryAndNextOrderStillCommits(t *testing.T) {
	f := setup(t)
	session := f.session(t, true)
	accepted(t, f.push("pos_sessions", session))
	first := f.order(t, session.Id)
	accepted(t, f.push("orders", first))
	blocker, err := f.db.Owner.Begin(context.Background())
	require.NoError(t, err)
	defer blocker.Rollback(context.Background())
	_, err = blocker.Exec(context.Background(), "SELECT id FROM order_dedupe WHERE id=$1 FOR UPDATE", first.Id)
	require.NoError(t, err)
	second := f.order(t, session.Id)
	rows := f.push("orders", first, second)
	require.Equal(t, wire.PushResultStatus("retry"), rows[0].Status)
	require.Equal(t, wire.PushResultCode("server_unavailable"), *rows[0].Code)
	accepted(t, rows[1:])
	require.EqualValues(t, 2, f.count(t, "orders"))
	require.EqualValues(t, 4, f.count(t, "ingest_log"))
}
