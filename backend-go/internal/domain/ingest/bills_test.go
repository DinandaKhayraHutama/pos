package ingest

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/history"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/stretchr/testify/require"
)

// billTill is one till holding a coordinated drawer, the only kind of till
// that runs saved bills.
type billTill struct {
	binding devices.Binding
	cashier string
	token   string
	session string
}

func (f *fixture) billTill(t *testing.T, b devices.Binding) billTill {
	t.Helper()
	cashier := f.cashier(t)
	token := f.access(t, b, cashier)
	s := f.session(t, false)
	s.EmployeeId = &cashier
	_, err := f.svc.OpenTill(context.Background(), b, token, s)
	require.NoError(t, err)
	return billTill{binding: b, cashier: cashier, token: token, session: s.Id}
}

func (f *fixture) pushAs(b devices.Binding, entity string, values ...any) []wire.PushResult {
	return f.svc.Push(context.Background(), b, request(entity, values...)).Results
}

func (f *fixture) namedProduct(t *testing.T, name string, price int64) string {
	t.Helper()
	var category, product string
	ctx := context.Background()
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		"INSERT INTO categories (tenant_id, name) VALUES ($1, 'Menu') RETURNING id::text", f.binding.Tenant.ID).Scan(&category))
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		"INSERT INTO products (tenant_id, category_id, name, price) VALUES ($1, $2, $3, $4) RETURNING id::text",
		f.binding.Tenant.ID, category, name, price).Scan(&product))
	return product
}

func (f *fixture) shelf(t *testing.T, product string) int64 {
	t.Helper()
	var qty int64
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		"SELECT qty_on_hand FROM outlet_stock WHERE outlet_id = $1 AND product_id = $2", f.binding.Outlet.ID, product).Scan(&qty))
	return qty
}

func billLine(t *testing.T, f *fixture, product, name string, qty int, price int64) wire.BillLine {
	return wire.BillLine{Id: f.id(t), Seq: 0, ProductId: &product, ProductName: name, Quantity: qty, UnitPrice: price,
		Modifiers: []wire.BillLineModifier{}}
}

func newBill(f *fixture, t *testing.T, till billTill, lines ...wire.BillLine) wire.Bill {
	for i := range lines {
		lines[i].Seq = i
	}
	return wire.Bill{Id: f.id(t), Revision: 1, OwnerGeneration: 1, Number: "B-1", Status: wire.BillStatusOpen,
		PosSessionId: till.session, OpenedAtMs: time.Now().UnixMilli(), Type: "dineIn", CreatedByName: "Sari",
		Pricing: wire.BillPricing{Version: 1, TaxMode: "exclusive", ServiceRateBp: 500, ServiceTaxable: true,
			RoundingMode: "nearest", DefaultTaxRateBp: 1000, DiscountSource: "none"},
		Lines: lines}
}

func saleOf(f *fixture, t *testing.T, product, name string, qty int64) wire.StockMovement {
	return wire.StockMovement{Id: f.id(t), Revision: 1, ProductId: product, ProductName: name, Reason: "sale",
		DeltaQty: -qty, OccurredAtMs: time.Now().UnixMilli(), EmployeeName: "Sari"}
}

func newDispatch(f *fixture, t *testing.T, till billTill, bill wire.Bill, lines []wire.BillLine, moves ...wire.StockMovement) wire.KitchenDispatch {
	if moves == nil {
		moves = []wire.StockMovement{}
	}
	now := time.Now().UnixMilli()
	return wire.KitchenDispatch{Id: f.id(t), Revision: 1, BillId: bill.Id, OwnerGeneration: bill.OwnerGeneration,
		PosSessionId: till.session, OccurredAtMs: now, EmployeeName: "Sari", Status: "queued", StatusChangedAtMs: now,
		Lines: lines, StockMovements: moves}
}

// receiptFor is the receipt that settles bill: every line, by its bill line
// id, and no sale movement of its own.
func receiptFor(f *fixture, t *testing.T, till billTill, bill wire.Bill, discount, tax, service int64) wire.Order {
	o := f.order(t, till.session)
	o.CashierId = &till.cashier
	billID := bill.Id
	o.BillId = &billID
	o.Items = nil
	var subtotal int64
	for _, line := range bill.Lines {
		lineID := line.Id
		o.Items = append(o.Items, wire.OrderItem{Id: f.id(t), BillLineId: &lineID, ProductId: line.ProductId,
			ProductName: line.ProductName, Quantity: line.Quantity, UnitPrice: line.UnitPrice, Modifiers: []wire.OrderItemModifier{}})
		subtotal += line.UnitPrice * int64(line.Quantity)
	}
	o.Subtotal, o.Discount, o.Tax, o.ServiceChargeAmount = subtotal, discount, tax, service
	o.Total = subtotal - discount + tax + service
	o.AmountPaid = o.Total
	o.StockMovements = &[]wire.StockMovement{}
	return o
}

func rowStatus(t *testing.T, row wire.PushResult, status, code string) {
	t.Helper()
	require.Equal(t, wire.PushResultStatus(status), row.Status, "%+v", row)
	if code != "" {
		require.NotNil(t, row.Code, "%+v", row)
		require.Equal(t, code, string(*row.Code), "%+v", row)
	}
}

// The §10.1 lifecycle: saving takes nothing, each dispatch consumes exactly its
// own lines once, and paying consumes nothing again.
func TestSavedBillLifecycleConsumesStockOncePerDispatch(t *testing.T) {
	f := setup(t)
	till := f.billTill(t, f.binding)
	nasi, teh := f.namedProduct(t, "Nasi", 25000), f.namedProduct(t, "Teh", 10000)
	accepted(t, f.push("stock_movements", f.movement(t, nasi, "received", 10), f.movement(t, teh, "received", 10)))

	nasiLine := billLine(t, f, nasi, "Nasi", 2, 25000)
	bill := newBill(f, t, till, nasiLine)
	accepted(t, f.push(BillEntity, bill))
	require.EqualValues(t, 10, f.shelf(t, nasi))
	require.EqualValues(t, 0, f.count(t, "orders"), "saving a bill is not a sale")

	first := newDispatch(f, t, till, bill, []wire.BillLine{nasiLine}, saleOf(f, t, nasi, "Nasi", 2))
	for attempt := 0; attempt < 3; attempt++ {
		rows := f.push(DispatchEntity, first)
		accepted(t, rows)
		require.Equal(t, attempt == 0, *rows[0].Inserted)
		require.NotNil(t, rows[0].Effects)
		require.Len(t, *rows[0].Effects, 1)
		require.EqualValues(t, 8, (*rows[0].Effects)[0].BalanceAfter)
	}
	require.EqualValues(t, 8, f.shelf(t, nasi), "a retried dispatch consumes once")

	tehLine := billLine(t, f, teh, "Teh", 1, 10000)
	bill.Revision = 2
	bill.Lines = []wire.BillLine{nasiLine, tehLine}
	bill.Lines[1].Seq = 1
	tehLine = bill.Lines[1]
	accepted(t, f.push(BillEntity, bill))
	require.EqualValues(t, 8, f.shelf(t, nasi))
	require.EqualValues(t, 10, f.shelf(t, teh), "adding a line to a saved bill moves nothing")

	second := newDispatch(f, t, till, bill, []wire.BillLine{tehLine}, saleOf(f, t, teh, "Teh", 1))
	accepted(t, f.push(DispatchEntity, second))
	require.EqualValues(t, 9, f.shelf(t, teh))

	receipt := receiptFor(f, t, till, bill, 6000, 5670, 2700)
	for attempt := 0; attempt < 2; attempt++ {
		accepted(t, f.push("orders", receipt))
	}
	require.EqualValues(t, 1, f.count(t, "orders"))
	require.EqualValues(t, 8, f.shelf(t, nasi), "settling consumes nothing again")
	require.EqualValues(t, 9, f.shelf(t, teh))
	var status, closedBy string
	require.NoError(t, f.db.Owner.QueryRow(context.Background(), "SELECT status, closed_order_id::text FROM bills WHERE id = $1", bill.Id).Scan(&status, &closedBy))
	require.Equal(t, "closed", status)
	require.Equal(t, receipt.Id, closedBy)
	require.EqualValues(t, 2, f.count(t, "kitchen_dispatches"))
	require.EqualValues(t, 4, f.count(t, "stock_movements"), "two deliveries, two dispatch consumptions")

	// A closed bill is final; a second receipt for it is refused.
	bill.Revision = 3
	rowStatus(t, f.push(BillEntity, bill)[0], "rejected", "settled")
	again := receiptFor(f, t, till, bill, 6000, 5670, 2700)
	rowStatus(t, f.push("orders", again)[0], "rejected", "settled")

	// The kitchen keeps working after payment: status moves forward only.
	first.Revision, first.Status = 2, "served"
	accepted(t, f.push(DispatchEntity, first))
	first.Revision, first.Status = 3, "preparing"
	rowStatus(t, f.push(DispatchEntity, first)[0], "rejected", "schema_rejected")

	// The Backoffice reads the same facts back: a settled bill is no longer
	// open backlog, it names its receipt, and every line reached the kitchen.
	reader := history.New(f.db.Pools)
	open, err := reader.Bills(context.Background(), f.binding.Tenant.ID, history.BillFilter{})
	require.NoError(t, err)
	require.Zero(t, open.OpenCount)
	require.Empty(t, open.Rows)
	detail, err := reader.Bill(context.Background(), f.binding.Tenant.ID, bill.Id)
	require.NoError(t, err)
	require.Equal(t, receipt.Id, detail.ClosedOrderID)
	require.Equal(t, "TEST-1", detail.ClosedNumber)
	require.Len(t, detail.Lines, 2)
	require.Len(t, detail.Dispatches, 2)
	for _, line := range detail.Lines {
		require.NotEmpty(t, line.DispatchID)
	}
	order, err := reader.Order(context.Background(), f.binding.Tenant.ID, receipt.Id)
	require.NoError(t, err)
	require.Equal(t, bill.Id, order.BillID, "a receipt links back to the bill it settled")
}

func TestADispatchedLineIsImmutableAndDispatchWaitsForItsBill(t *testing.T) {
	f := setup(t)
	till := f.billTill(t, f.binding)
	nasi := f.namedProduct(t, "Nasi", 25000)
	line := billLine(t, f, nasi, "Nasi", 2, 25000)
	bill := newBill(f, t, till, line)

	// The dispatch arrives before any bill: it waits, it is not refused.
	early := newDispatch(f, t, till, bill, []wire.BillLine{line})
	rowStatus(t, f.push(DispatchEntity, early)[0], "retry", "dependency_pending")
	accepted(t, f.push(BillEntity, bill))

	// Same line id, but the server holds an older quantity: still waiting.
	changed := line
	changed.Quantity = 3
	pending := newDispatch(f, t, till, bill, []wire.BillLine{changed})
	rowStatus(t, f.push(DispatchEntity, pending)[0], "retry", "dependency_pending")

	accepted(t, f.push(DispatchEntity, early))
	bill.Revision = 2
	bill.Lines[0].Quantity = 3
	rowStatus(t, f.push(BillEntity, bill)[0], "rejected", "schema_rejected")
	bill.Lines = []wire.BillLine{}
	rowStatus(t, f.push(BillEntity, bill)[0], "rejected", "schema_rejected")

	// The same line sent a second time by another dispatch is a duplicate.
	bill.Lines = []wire.BillLine{line}
	accepted(t, f.push(BillEntity, bill))
	twice := newDispatch(f, t, till, bill, []wire.BillLine{line})
	rowStatus(t, f.push(DispatchEntity, twice)[0], "rejected", "duplicate")
}

func TestSettlementWaitsForEveryLineAndCarriesNoSaleOfItsOwn(t *testing.T) {
	f := setup(t)
	till := f.billTill(t, f.binding)
	nasi := f.namedProduct(t, "Nasi", 25000)
	line := billLine(t, f, nasi, "Nasi", 1, 25000)
	bill := newBill(f, t, till, line)
	accepted(t, f.push(BillEntity, bill))

	receipt := receiptFor(f, t, till, bill, 0, 0, 0)
	rowStatus(t, f.push("orders", receipt)[0], "retry", "dependency_pending")
	require.EqualValues(t, 0, f.count(t, "orders"))

	accepted(t, f.push(DispatchEntity, newDispatch(f, t, till, bill, []wire.BillLine{line}, saleOf(f, t, nasi, "Nasi", 1))))
	withSale := receipt
	withSale.StockMovements = &[]wire.StockMovement{saleOf(f, t, nasi, "Nasi", 1)}
	rowStatus(t, f.push("orders", withSale)[0], "rejected", "schema_rejected")

	short := receipt
	short.Items = nil
	short.Items = append(short.Items, receipt.Items[0])
	short.Items[0].Quantity = 2
	short.Subtotal, short.Total, short.AmountPaid = 50000, 50000, 50000
	rowStatus(t, f.push("orders", short)[0], "rejected", "schema_rejected")

	accepted(t, f.push("orders", receipt))
}

func TestAnotherTillCannotEditDispatchOrSettleABillItDoesNotOwn(t *testing.T) {
	f := setup(t)
	a := f.billTill(t, f.binding)
	b := f.billTill(t, f.device(t, true))
	nasi := f.namedProduct(t, "Nasi", 25000)
	line := billLine(t, f, nasi, "Nasi", 1, 25000)
	bill := newBill(f, t, a, line)
	accepted(t, f.push(BillEntity, bill))

	stolen := bill
	stolen.Revision, stolen.PosSessionId = 2, b.session
	rowStatus(t, f.pushAs(b.binding, BillEntity, stolen)[0], "rejected", "bill_not_owned")
	rowStatus(t, f.pushAs(b.binding, DispatchEntity, newDispatch(f, t, b, bill, []wire.BillLine{line}))[0], "rejected", "bill_not_owned")
	accepted(t, f.push(DispatchEntity, newDispatch(f, t, a, bill, []wire.BillLine{line})))
	rowStatus(t, f.pushAs(b.binding, "orders", receiptFor(f, t, b, bill, 0, 0, 0))[0], "rejected", "bill_not_owned")
	require.EqualValues(t, 0, f.count(t, "orders"))
}

func TestParkThenClaimMovesTheBillAndFencesTheFormerOwner(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	a := f.billTill(t, f.binding)
	b := f.billTill(t, f.device(t, true))
	c := f.billTill(t, f.device(t, true))
	nasi := f.namedProduct(t, "Nasi", 25000)
	line := billLine(t, f, nasi, "Nasi", 1, 25000)
	bill := newBill(f, t, a, line)
	accepted(t, f.push(BillEntity, bill))

	// The server must already hold what the till knows before it lets go.
	_, err := f.svc.ParkBill(ctx, a.binding, a.token, bill.Id, wire.TillBillParkRequest{OperationId: f.id(t), ExpectedRevision: 2})
	require.EqualError(t, err, "sync_before_handoff")
	_, err = f.svc.ParkBill(ctx, b.binding, b.token, bill.Id, wire.TillBillParkRequest{OperationId: f.id(t), ExpectedRevision: 1})
	require.EqualError(t, err, "bill_not_owned")

	park := wire.TillBillParkRequest{OperationId: f.id(t), ExpectedRevision: 1}
	parked, err := f.svc.ParkBill(ctx, a.binding, a.token, bill.Id, park)
	require.NoError(t, err)
	require.EqualValues(t, 2, parked.OwnerGeneration)
	replay, err := f.svc.ParkBill(ctx, a.binding, a.token, bill.Id, park)
	require.NoError(t, err)
	require.Equal(t, parked, replay, "a retried park answers what the first did")

	// Two tills claim at once: exactly one wins.
	ops := []string{f.id(t), f.id(t)}
	errs := make([]error, 2)
	details := make([]wire.TillBillDetail, 2)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i, till := range []billTill{b, c} {
		wg.Add(1)
		go func(i int, till billTill) {
			defer wg.Done()
			<-start
			details[i], errs[i] = f.svc.ClaimBill(ctx, till.binding, till.token, bill.Id, ops[i])
		}(i, till)
	}
	close(start)
	wg.Wait()
	winner := 0
	if errs[0] != nil {
		winner = 1
	}
	require.NoError(t, errs[winner])
	require.EqualError(t, errs[1-winner], "bill_not_parked")
	owner := []billTill{b, c}[winner]
	claimed := details[winner]
	require.EqualValues(t, 3, claimed.Summary.OwnerGeneration)
	require.True(t, claimed.Summary.OwnedByThisDevice)
	require.Len(t, claimed.Bill.Lines, 1)
	again, err := f.svc.ClaimBill(ctx, owner.binding, owner.token, bill.Id, ops[winner])
	require.NoError(t, err)
	require.EqualValues(t, 3, again.Summary.OwnerGeneration, "a retried claim is the same claim")

	// The former owner is fenced even with a newer revision.
	late := bill
	late.Revision = 5
	rowStatus(t, f.push(BillEntity, late)[0], "rejected", "bill_not_owned")

	// The new owner continues from the server's revision and generation.
	next := claimed.Bill
	next.Revision, next.OwnerGeneration, next.PosSessionId = 2, 3, owner.session
	accepted(t, f.pushAs(owner.binding, BillEntity, next))
	var events int64
	require.NoError(t, f.db.Owner.QueryRow(ctx, "SELECT count(*) FROM bill_events WHERE bill_id = $1", bill.Id).Scan(&events))
	require.EqualValues(t, 2, events, "one park and one claim are audited")
}

func TestCancellingAfterDispatchRestocksOnlyWhatCameBack(t *testing.T) {
	f := setup(t)
	till := f.billTill(t, f.binding)
	nasi, teh := f.namedProduct(t, "Nasi", 25000), f.namedProduct(t, "Teh", 10000)
	accepted(t, f.push("stock_movements", f.movement(t, nasi, "received", 10), f.movement(t, teh, "received", 10)))
	nasiLine, tehLine := billLine(t, f, nasi, "Nasi", 2, 25000), billLine(t, f, teh, "Teh", 1, 10000)
	tehLine.Seq = 1
	bill := newBill(f, t, till, nasiLine, tehLine)
	accepted(t, f.push(BillEntity, bill))
	accepted(t, f.push(DispatchEntity, newDispatch(f, t, till, bill, []wire.BillLine{bill.Lines[0], bill.Lines[1]},
		saleOf(f, t, nasi, "Nasi", 2), saleOf(f, t, teh, "Teh", 1))))
	require.EqualValues(t, 8, f.shelf(t, nasi))
	require.EqualValues(t, 9, f.shelf(t, teh))

	returned := wire.StockMovement{Id: f.id(t), Revision: 1, ProductId: nasi, ProductName: "Nasi", Reason: "voidReturn",
		DeltaQty: 2, OccurredAtMs: time.Now().UnixMilli(), EmployeeName: "Sari"}
	cancel := bill
	cancel.Revision, cancel.Status = 2, wire.BillStatusCancelled
	cancel.Cancel = &wire.BillCancel{Reason: "Tamu batal", AuthorizedBy: "Manajer", CancelledAtMs: time.Now().UnixMilli(),
		StockMovements: []wire.StockMovement{returned}}
	// Every line the kitchen received needs a decision.
	rowStatus(t, f.push(BillEntity, cancel)[0], "rejected", "schema_rejected")
	cancel.Cancel.Decisions = append(cancel.Cancel.Decisions,
		struct {
			BillLineId  wire.UUID                           `json:"bill_line_id"`
			Disposition wire.BillCancelDecisionsDisposition `json:"disposition"`
		}{BillLineId: bill.Lines[0].Id, Disposition: "restock"},
		struct {
			BillLineId  wire.UUID                           `json:"bill_line_id"`
			Disposition wire.BillCancelDecisionsDisposition `json:"disposition"`
		}{BillLineId: bill.Lines[1].Id, Disposition: "waste"})
	for attempt := 0; attempt < 2; attempt++ {
		rows := f.push(BillEntity, cancel)
		accepted(t, rows)
		require.NotNil(t, rows[0].Effects)
	}
	require.EqualValues(t, 10, f.shelf(t, nasi), "the restocked plate is back once")
	require.EqualValues(t, 9, f.shelf(t, teh), "waste is not a second debit")
	var active int64
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		"SELECT count(*) FROM kitchen_dispatches WHERE bill_id = $1 AND status <> 'cancelled'", bill.Id).Scan(&active))
	require.Zero(t, active)
	rowStatus(t, f.push("orders", receiptFor(f, t, till, bill, 0, 0, 0))[0], "rejected", "settled")
}

func TestReturningMoreThanTheBillConsumedIsRefused(t *testing.T) {
	f := setup(t)
	till := f.billTill(t, f.binding)
	nasi := f.namedProduct(t, "Nasi", 25000)
	line := billLine(t, f, nasi, "Nasi", 1, 25000)
	bill := newBill(f, t, till, line)
	accepted(t, f.push(BillEntity, bill))
	accepted(t, f.push(DispatchEntity, newDispatch(f, t, till, bill, []wire.BillLine{line}, saleOf(f, t, nasi, "Nasi", 1))))
	cancel := bill
	cancel.Revision, cancel.Status = 2, wire.BillStatusCancelled
	cancel.Cancel = &wire.BillCancel{Reason: "x", AuthorizedBy: "M", CancelledAtMs: time.Now().UnixMilli(),
		StockMovements: []wire.StockMovement{{Id: f.id(t), Revision: 1, ProductId: nasi, ProductName: "Nasi",
			Reason: "voidReturn", DeltaQty: 3, OccurredAtMs: time.Now().UnixMilli(), EmployeeName: "S"}}}
	cancel.Cancel.Decisions = append(cancel.Cancel.Decisions, struct {
		BillLineId  wire.UUID                           `json:"bill_line_id"`
		Disposition wire.BillCancelDecisionsDisposition `json:"disposition"`
	}{BillLineId: line.Id, Disposition: "restock"})
	rowStatus(t, f.push(BillEntity, cancel)[0], "rejected", "schema_rejected")
}

func TestADrawerWithAnOpenBillCannotClose(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	till := f.billTill(t, f.binding)
	nasi := f.namedProduct(t, "Nasi", 25000)
	bill := newBill(f, t, till, billLine(t, f, nasi, "Nasi", 1, 25000))
	accepted(t, f.push(BillEntity, bill))

	closing := f.session(t, false)
	closing.Id, closing.EmployeeId, closing.Revision = till.session, &till.cashier, 2
	now, cash, zero := time.Now().UnixMilli(), int64(100000), int64(0)
	closing.OpenedAtMs = time.Now().Add(-time.Hour).UnixMilli()
	closing.ClosedAtMs, closing.CountedCash, closing.ExpectedCash, closing.OrderCount = &now, &cash, &cash, &zero
	var opening struct {
		at int64
	}
	require.NoError(t, f.db.Owner.QueryRow(ctx, "SELECT opened_at_ms FROM pos_sessions WHERE id = $1", till.session).Scan(&opening.at))
	closing.OpenedAtMs = opening.at
	rowStatus(t, f.push("pos_sessions", closing)[0], "retry", "dependency_pending")

	_, err := f.svc.ParkBill(ctx, till.binding, till.token, bill.Id, wire.TillBillParkRequest{OperationId: f.id(t), ExpectedRevision: 1})
	require.NoError(t, err)
	accepted(t, f.push("pos_sessions", closing))
}

func TestOneSeatingPerTableAndPaymentDoesNotClearIt(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	a := f.billTill(t, f.binding)
	b := f.billTill(t, f.device(t, true))
	var table string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO tables (tenant_id, outlet_id, name) VALUES ($1, $2, 'Meja 1') RETURNING id::text`,
		f.binding.Tenant.ID, f.binding.Outlet.ID).Scan(&table))
	_, err := f.db.Owner.Exec(ctx, `INSERT INTO table_status (tenant_id, table_id, outlet_id) VALUES ($1, $2, $3)`,
		f.binding.Tenant.ID, table, f.binding.Outlet.ID)
	require.NoError(t, err)

	requests := []wire.TableSessionOpenRequest{{Id: f.id(t), TableId: table}, {Id: f.id(t), TableId: table}}
	errs := make([]error, 2)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i, till := range []billTill{a, b} {
		wg.Add(1)
		go func(i int, till billTill) {
			defer wg.Done()
			<-start
			_, errs[i] = f.svc.OpenTableSession(ctx, till.binding, till.token, requests[i])
		}(i, till)
	}
	close(start)
	wg.Wait()
	winner := 0
	if errs[0] != nil {
		winner = 1
	}
	require.NoError(t, errs[winner])
	require.EqualError(t, errs[1-winner], "table_busy")
	seating := requests[winner]
	owner := []billTill{a, b}[winner]
	replay, err := f.svc.OpenTableSession(ctx, owner.binding, owner.token, seating)
	require.NoError(t, err, "a retried seating is the same seating")
	require.Equal(t, seating.Id, replay.Id)

	var status string
	require.NoError(t, f.db.Owner.QueryRow(ctx, "SELECT status FROM table_status WHERE table_id = $1", table).Scan(&status))
	require.Equal(t, "occupied", status)

	// An old-path status event cannot clear a seated table underneath it.
	event := map[string]any{"id": f.id(t), "revision": 1, "table_id": table, "client_seq": time.Now().UnixMilli(),
		"status": "available", "basis_seq": 0, "occurred_at_ms": time.Now().UnixMilli(), "employee_name": "Sari"}
	rows := f.pushAs(owner.binding, "table_status_events", event)
	accepted(t, rows)
	require.Equal(t, wire.PushResultOutcome("superseded"), *rows[0].Outcome)

	nasi := f.namedProduct(t, "Nasi", 25000)
	line := billLine(t, f, nasi, "Nasi", 1, 25000)
	bill := newBill(f, t, owner, line)
	sid := seating.Id
	bill.TableSessionId = &sid
	accepted(t, f.pushAs(owner.binding, BillEntity, bill))
	_, err = f.svc.CloseTableSession(ctx, owner.binding, owner.token, seating.Id, f.id(t))
	require.EqualError(t, err, "open_bills_remaining")

	accepted(t, f.pushAs(owner.binding, DispatchEntity, newDispatch(f, t, owner, bill, []wire.BillLine{line})))
	accepted(t, f.pushAs(owner.binding, "orders", receiptFor(f, t, owner, bill, 0, 0, 0)))
	require.NoError(t, f.db.Owner.QueryRow(ctx, "SELECT status FROM table_status WHERE table_id = $1", table).Scan(&status))
	require.Equal(t, "occupied", status, "paying does not clear the table")

	closed, err := f.svc.CloseTableSession(ctx, owner.binding, owner.token, seating.Id, f.id(t))
	require.NoError(t, err)
	require.NotNil(t, closed.ClosedAtMs)
	require.NoError(t, f.db.Owner.QueryRow(ctx, "SELECT status FROM table_status WHERE table_id = $1", table).Scan(&status))
	require.Equal(t, "available", status)

	board, err := f.svc.BillBoard(ctx, owner.binding, owner.token)
	require.NoError(t, err)
	require.Empty(t, board.Bills)
	require.Empty(t, board.TableSessions)
}

func TestForcedTakeoverReleasesTheLostTillsBills(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	till := f.billTill(t, f.binding)
	nasi := f.namedProduct(t, "Nasi", 25000)
	bill := newBill(f, t, till, billLine(t, f, nasi, "Nasi", 1, 25000))
	accepted(t, f.push(BillEntity, bill))

	var manager, register string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO employees(tenant_id,name,role) VALUES($1,'Manajer','manager') RETURNING id::text`, f.binding.Tenant.ID).Scan(&manager))
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT name FROM pos_registers WHERE id = $1`, f.binding.Register.ID).Scan(&register))
	_, err := f.svc.ForceTakeover(ctx, f.binding.Tenant.ID, ForceTakeoverInput{OperationID: f.id(t), SessionID: till.session,
		DeviceID: f.binding.Device.ID, ConfirmedRegister: register, Reason: "Tablet hilang", Actor: RecoveryActor{ID: manager, Name: "Manajer"}})
	require.NoError(t, err)

	var owner *string
	var generation int64
	require.NoError(t, f.db.Owner.QueryRow(ctx, "SELECT owner_device_id::text, owner_generation FROM bills WHERE id = $1", bill.Id).Scan(&owner, &generation))
	require.Nil(t, owner, "the lost till's bill waits on the server for another till")
	require.EqualValues(t, 2, generation)
	var kind string
	require.NoError(t, f.db.Owner.QueryRow(ctx, "SELECT event_type FROM bill_events WHERE bill_id = $1", bill.Id).Scan(&kind))
	require.Equal(t, "force_park", kind)
}

// Two tills dispatching the same two products in opposite order. Nothing else
// serialises two dispatches of different bills, so if the movements were
// applied one at a time — row A, the counters, then row B — the two would wait
// on each other and one would be killed as a deadlock. The batch locks every
// projection row, in order, before any counter.
func TestDispatchesWithReversedProductsDoNotDeadlock(t *testing.T) {
	f := setup(t)
	a := f.billTill(t, f.binding)
	b := f.billTill(t, f.device(t, true))
	p1, p2 := f.namedProduct(t, "Satu", 1000), f.namedProduct(t, "Dua", 1000)
	accepted(t, f.push("stock_movements", f.movement(t, p1, "received", 100), f.movement(t, p2, "received", 100)))

	prepare := func(till billTill, first, second string) wire.KitchenDispatch {
		l1, l2 := billLine(t, f, first, "x", 1, 1000), billLine(t, f, second, "y", 1, 1000)
		bill := newBill(f, t, till, l1, l2)
		accepted(t, f.pushAs(till.binding, BillEntity, bill))
		return newDispatch(f, t, till, bill, bill.Lines, saleOf(f, t, first, "x", 1), saleOf(f, t, second, "y", 1))
	}
	for round := 0; round < 20; round++ {
		dispatches := []wire.KitchenDispatch{prepare(a, p1, p2), prepare(b, p2, p1)}
		var wg sync.WaitGroup
		results := make([][]wire.PushResult, 2)
		start := make(chan struct{})
		for i, till := range []billTill{a, b} {
			wg.Add(1)
			go func(i int, till billTill) {
				defer wg.Done()
				<-start
				results[i] = f.pushAs(till.binding, DispatchEntity, dispatches[i])
			}(i, till)
		}
		close(start)
		wg.Wait()
		for _, rows := range results {
			accepted(t, rows)
		}
	}
	require.EqualValues(t, 60, f.shelf(t, p1))
	require.EqualValues(t, 60, f.shelf(t, p2))
}

// A till that claims a bill reports kitchen progress for a batch another till
// sent, by repeating the batch exactly as the claim handed it over.
func TestAClaimingTillMovesTheKitchenStatusOfABatchItDidNotSend(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	a := f.billTill(t, f.binding)
	b := f.billTill(t, f.device(t, true))
	nasi := f.namedProduct(t, "Nasi", 25000)
	accepted(t, f.push("stock_movements", f.movement(t, nasi, "received", 10)))
	line := billLine(t, f, nasi, "Nasi", 1, 25000)
	bill := newBill(f, t, a, line)
	accepted(t, f.push(BillEntity, bill))
	accepted(t, f.push(DispatchEntity, newDispatch(f, t, a, bill, []wire.BillLine{line}, saleOf(f, t, nasi, "Nasi", 1))))
	_, err := f.svc.ParkBill(ctx, a.binding, a.token, bill.Id, wire.TillBillParkRequest{OperationId: f.id(t), ExpectedRevision: 1, ExpectedDispatches: 1})
	require.NoError(t, err)
	claimed, err := f.svc.ClaimBill(ctx, b.binding, b.token, bill.Id, f.id(t))
	require.NoError(t, err)
	require.Len(t, claimed.Dispatches, 1)
	handed := claimed.Dispatches[0].Dispatch
	require.NotNil(t, handed)
	require.EqualValues(t, 3, handed.OwnerGeneration)

	progress := *handed
	progress.Revision, progress.Status, progress.StatusChangedAtMs = 2, "ready", time.Now().UnixMilli()
	rows := f.pushAs(b.binding, DispatchEntity, progress)
	accepted(t, rows)
	require.False(t, *rows[0].Inserted)
	require.EqualValues(t, 9, f.shelf(t, nasi), "reporting progress consumes nothing again")

	// The till that let the bill go can no longer move its batch.
	stale := *handed
	stale.Revision, stale.Status, stale.OwnerGeneration = 3, "served", 1
	rowStatus(t, f.push(DispatchEntity, stale)[0], "rejected", "bill_not_owned")
}
