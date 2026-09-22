package ingest

import (
	"context"
	"encoding/json"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/bcrypt"
	"sync"
	"testing"
	"time"
)

func (f *fixture) cashier(t *testing.T) string {
	t.Helper()
	hash, err := bcrypt.GenerateFromPassword([]byte("1234"), bcrypt.MinCost)
	require.NoError(t, err)
	var id string
	require.NoError(t, f.db.Owner.QueryRow(context.Background(), `INSERT INTO employees(tenant_id,name,role,pin_hash) VALUES($1,'Sari','cashier',$2) RETURNING id::text`, f.binding.Tenant.ID, string(hash)).Scan(&id))
	return id
}
func (f *fixture) access(t *testing.T, b devices.Binding, employee string) string {
	t.Helper()
	out, err := f.svc.TillLogin(context.Background(), b, employee, "1234")
	require.NoError(t, err)
	return out.Token
}
func (f *fixture) device(t *testing.T, otherRegister bool) devices.Binding {
	t.Helper()
	b := f.binding
	if otherRegister {
		require.NoError(t, f.db.Owner.QueryRow(context.Background(), `INSERT INTO pos_registers(tenant_id,outlet_id,name) VALUES($1,$2,gen_random_uuid()::text) RETURNING id::text`, b.Tenant.ID, b.Outlet.ID).Scan(&b.Register.ID))
	}
	require.NoError(t, f.db.Owner.QueryRow(context.Background(), `INSERT INTO devices(tenant_id,outlet_id,pos_register_id,device_uuid) VALUES($1,$2,$3,gen_random_uuid()::text) RETURNING id::text`, b.Tenant.ID, b.Outlet.ID, b.Register.ID).Scan(&b.Device.ID))
	return b
}
func TestCoordinatedTillExactlyOneDeviceWinsAndLostReplyReplays(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	employee := f.cashier(t)
	b := f.device(t, false)
	aToken, bToken := f.access(t, f.binding, employee), f.access(t, b, employee)
	sa, sb := f.session(t, false), f.session(t, false)
	sa.EmployeeId = &employee
	sb.EmployeeId = &employee
	var wg sync.WaitGroup
	errs := make([]error, 2)
	out := make([]TillSession, 2)
	start := make(chan struct{})
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			if i == 0 {
				out[i], errs[i] = f.svc.OpenTill(ctx, f.binding, aToken, sa)
			} else {
				out[i], errs[i] = f.svc.OpenTill(ctx, b, bToken, sb)
			}
		}(i)
	}
	close(start)
	wg.Wait()
	winner := 0
	if errs[0] != nil {
		winner = 1
	}
	require.NoError(t, errs[winner])
	require.Error(t, errs[1-winner])
	require.EqualValues(t, 1, f.count(t, "pos_sessions"))
	binding, token, session := f.binding, aToken, sa
	if winner == 1 {
		binding, token, session = b, bToken, sb
	}
	replay, err := f.svc.OpenTill(ctx, binding, token, session)
	require.NoError(t, err)
	require.Equal(t, out[winner], replay)
	require.EqualValues(t, 100000, replay.ReceiptEnd-replay.ReceiptStart+1)
	foreign := f.binding
	if winner == 0 {
		foreign = b
	}
	_, err = f.svc.OpenTill(ctx, foreign, token, session)
	require.Error(t, err, "cashier grant cannot be used on another device")
	// A legacy client cannot bypass the coordinated open path after rollout.
	rejected := f.svc.Push(ctx, binding, request("pos_sessions", f.session(t, true))).Results[0]
	require.Equal(t, "register_busy", string(*rejected.Code))
}

func TestCashierAssignmentMovesOnHandoverAndCloseWaitsForReceipts(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	a, c := f.cashier(t), f.cashier(t)
	b := f.device(t, true)
	sa := f.session(t, false)
	sa.EmployeeId = &a
	opened, err := f.svc.OpenTill(ctx, f.binding, f.access(t, f.binding, a), sa)
	require.NoError(t, err)
	sb := f.session(t, false)
	sb.EmployeeId = &a
	_, err = f.svc.OpenTill(ctx, b, f.access(t, b, a), sb)
	require.EqualError(t, err, "cashier_busy")
	_, err = f.svc.HandoverTill(ctx, f.binding, f.access(t, f.binding, c), sa.Id)
	require.NoError(t, err)
	_, err = f.svc.OpenTill(ctx, b, f.access(t, b, a), sb)
	require.NoError(t, err)
	closing := opened.Session
	closing.Revision = 2
	now := time.Now().UnixMilli()
	count := int64(1)
	cash := int64(0)
	closing.ClosedAtMs = &now
	closing.CountedCash = &cash
	closing.ExpectedCash = &cash
	closing.OrderCount = &count
	rows := f.push("pos_sessions", closing)
	require.Equal(t, "dependency_pending", string(*rows[0].Code))
	order := f.order(t, sa.Id)
	order.CashierId = &c
	effects := []wire.StockMovement{}
	order.StockMovements = &effects
	accepted(t, f.push("orders", order))
	accepted(t, f.push("pos_sessions", closing))
	accepted(t, f.push("pos_sessions", closing))
	unexpected := f.order(t, sa.Id)
	unexpected.CashierId = &c
	unexpected.StockMovements = &effects
	require.Equal(t, "session_closed", string(*f.push("orders", unexpected)[0].Code))
	accepted(t, f.push("orders", order)) // ACK-lost receipt retry after close
}

func TestHistoryCrossDeviceScopedAndCannotAcquireDrawer(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	employee := f.cashier(t)
	other := f.cashier(t)
	session := f.session(t, false)
	session.EmployeeId = &employee
	_, err := f.svc.OpenTill(ctx, f.binding, f.access(t, f.binding, employee), session)
	require.NoError(t, err)
	order := f.order(t, session.Id)
	order.CashierId = &employee
	effects := []wire.StockMovement{}
	order.StockMovements = &effects
	accepted(t, f.push("orders", order))
	b := f.device(t, false)
	token := f.access(t, b, employee)
	history, err := f.svc.TillHistory(ctx, b, token, HistoryQuery{Day: order.BusinessDate})
	require.NoError(t, err)
	require.Len(t, history.Rows, 1)
	var row map[string]any
	require.NoError(t, json.Unmarshal(history.Rows[0], &row))
	require.Equal(t, order.Id, row["id"])
	current, err := f.svc.CurrentTill(ctx, b, token)
	require.NoError(t, err)
	require.Nil(t, current)
	hidden, err := f.svc.TillHistory(ctx, b, f.access(t, b, other), HistoryQuery{Day: order.BusinessDate})
	require.NoError(t, err)
	require.Empty(t, hidden.Rows)
	another := f.device(t, true)
	hidden, err = f.svc.TillHistory(ctx, another, f.access(t, another, employee), HistoryQuery{Day: order.BusinessDate})
	require.NoError(t, err)
	require.Empty(t, hidden.Rows)
	_, err = f.db.Owner.Exec(ctx, "UPDATE employees SET active=false WHERE id=$1", employee)
	require.NoError(t, err)
	_, err = f.svc.TillHistory(ctx, b, token, HistoryQuery{Day: order.BusinessDate})
	require.EqualError(t, err, "cashier_auth_required")
}

func TestReceiptAndStockCommitTogetherRetryAndRefund(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	employee := f.cashier(t)
	session := f.session(t, false)
	session.EmployeeId = &employee
	_, err := f.svc.OpenTill(ctx, f.binding, f.access(t, f.binding, employee), session)
	require.NoError(t, err)
	var category, product string
	require.NoError(t, f.db.Owner.QueryRow(ctx, "INSERT INTO categories(tenant_id,name) VALUES($1,'Food') RETURNING id", f.binding.Tenant.ID).Scan(&category))
	require.NoError(t, f.db.Owner.QueryRow(ctx, "INSERT INTO products(tenant_id,category_id,name,price) VALUES($1,$2,'Kopi',10000) RETURNING id", f.binding.Tenant.ID, category).Scan(&product))
	order := f.order(t, session.Id)
	order.CashierId = &employee
	order.Items[0].ProductId = &product
	effect := wire.StockMovement{Id: f.id(t), Revision: 1, ProductId: product, ProductName: "Kopi", Reason: "sale", DeltaQty: -2, OccurredAtMs: time.Now().UnixMilli(), EmployeeName: "Sari"}
	effects := []wire.StockMovement{effect}
	order.StockMovements = &effects
	for i := 0; i < 3; i++ {
		accepted(t, f.push("orders", order))
	}
	require.EqualValues(t, 1, f.count(t, "orders"))
	require.EqualValues(t, 1, f.count(t, "stock_movements"))
	bad := f.order(t, session.Id)
	bad.CashierId = &employee
	bad.Items[0].ProductId = &product
	invalid := effect
	invalid.Id = f.id(t)
	invalid.ProductId = f.id(t)
	badEffects := []wire.StockMovement{invalid}
	bad.StockMovements = &badEffects
	require.Equal(t, "rejected", string(f.push("orders", bad)[0].Status))
	require.EqualValues(t, 1, f.count(t, "orders"))
	require.EqualValues(t, 1, f.count(t, "order_dedupe"))
	order.Revision++
	order.Status = "refunded"
	who, why := "Manager", "Returned"
	amount := order.Total
	order.AuthorizedBy = &who
	order.VoidReason = &why
	order.RefundedAmount = &amount
	returned := effect
	returned.Id = f.id(t)
	returned.Reason = "voidReturn"
	returned.DeltaQty = 2
	effects = append(effects, returned)
	accepted(t, f.push("orders", order))
	accepted(t, f.push("orders", order))
	require.EqualValues(t, 2, f.count(t, "stock_movements"))
	var qty int64
	require.NoError(t, f.db.Owner.QueryRow(ctx, "SELECT qty_on_hand FROM outlet_stock WHERE outlet_id=$1 AND product_id=$2", f.binding.Outlet.ID, product).Scan(&qty))
	require.Zero(t, qty)
	// Old standalone sales cannot bypass the atomic protocol on this register.
	effect.Id = f.id(t)
	require.Equal(t, "rejected", string(f.push("stock_movements", effect)[0].Status))
}

// A receipt list is read by a cashier looking for the sale they just rang up,
// so it has to be in the order things happened. Paging by id alone was stable
// but meaningless: a v4 UUID sorts at random, so "page two" held whatever the
// shuffle put there rather than the next oldest sale — and the newest receipt
// could land anywhere in the list.
func TestHistoryIsNewestFirstAndPagesInThatOrder(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	employee := f.cashier(t)
	session := f.session(t, false)
	session.EmployeeId = &employee
	_, err := f.svc.OpenTill(ctx, f.binding, f.access(t, f.binding, employee), session)
	require.NoError(t, err)

	// Rung up a minute apart, pushed in an order that has nothing to do with
	// time — the query must not be able to borrow the arrival order either.
	placed := time.Now().UnixMilli()
	byTime := map[int64]string{}
	for _, offset := range []int64{2, 0, 4, 1, 3} {
		order := f.order(t, session.Id)
		order.CashierId = &employee
		order.PlacedAtMs = placed + offset*60_000
		effects := []wire.StockMovement{}
		order.StockMovements = &effects
		accepted(t, f.push("orders", order))
		byTime[offset] = order.Id
	}

	token := f.access(t, f.binding, employee)
	today := time.Now().UTC().Format(time.DateOnly)
	history, err := f.svc.TillHistory(ctx, f.binding, token, HistoryQuery{Day: today})
	require.NoError(t, err)
	require.Len(t, history.Rows, 5)
	require.Equal(t, HistoryScopeRegister, history.Scope, "the server echoes the scope it applied")
	require.Equal(t, today, history.From)
	require.Equal(t, today, history.To)

	got := make([]string, 0, 5)
	for _, raw := range history.Rows {
		var row map[string]any
		require.NoError(t, json.Unmarshal(raw, &row))
		got = append(got, row["id"].(string))
	}
	require.Equal(t,
		[]string{byTime[4], byTime[3], byTime[2], byTime[1], byTime[0]}, got,
		"newest receipt first, oldest last")

	// A cursor is opaque to the client but must be exactly what this server
	// produced: a hand-edited one cannot widen the scan. A cursor minted by
	// the old single-day contract has no date in it and is refused too, so a
	// page boundary is never guessed at.
	for _, cursor := range []string{"not-a-cursor", "12:not-a-uuid", "1700000000000:" + byTime[0]} {
		_, err = f.svc.TillHistory(ctx, f.binding, token, HistoryQuery{Day: today, Before: cursor})
		require.EqualError(t, err, "invalid_cursor", "cursor %q", cursor)
	}

	// A cashier is held to their own day, their own register and their own
	// name — and told so, rather than handed a narrower list with no label.
	for _, q := range []HistoryQuery{
		{Day: today, Scope: HistoryScopeOutlet},
		{From: "2020-01-01", To: "2020-01-02"},
		{Day: today, CashierID: "11111111-1111-4111-8111-111111111111"},
	} {
		_, err = f.svc.TillHistory(ctx, f.binding, token, q)
		require.Error(t, err, "%+v", q)
	}

	// Naming a day AND a range says two different things about which days are
	// wanted. Resolving it either way hands somebody a period they did not ask
	// for, so it is refused.
	_, err = f.svc.TillHistory(ctx, f.binding, token, HistoryQuery{Day: today, From: today, To: today})
	require.EqualError(t, err, "ambiguous_range")
}
