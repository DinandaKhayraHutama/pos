package ingest

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/stretchr/testify/require"
)

func TestTakeoverLateSaleApprovalAndExactRetryAreAtomic(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	cashier := f.cashier(t)
	var manager string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO employees(tenant_id,name,role) VALUES($1,'Mira','manager') RETURNING id::text`, f.binding.Tenant.ID).Scan(&manager))
	session := f.session(t, false)
	session.EmployeeId = &cashier
	_, err := f.svc.OpenTill(ctx, f.binding, f.access(t, f.binding, cashier), session)
	require.NoError(t, err)

	var category, product string
	require.NoError(t, f.db.Owner.QueryRow(ctx, "INSERT INTO categories(tenant_id,name) VALUES($1,'Food') RETURNING id", f.binding.Tenant.ID).Scan(&category))
	require.NoError(t, f.db.Owner.QueryRow(ctx, "INSERT INTO products(tenant_id,category_id,name,price) VALUES($1,$2,'Kopi',10000) RETURNING id", f.binding.Tenant.ID, category).Scan(&product))
	late := f.order(t, session.Id)
	late.CashierId = &cashier
	late.Items[0].ProductId = &product
	effect := wire.StockMovement{Id: f.id(t), Revision: 1, ProductId: product, ProductName: "Kopi", Reason: "sale", DeltaQty: -2, OccurredAtMs: time.Now().UnixMilli(), EmployeeName: "Sari"}
	effects := []wire.StockMovement{effect}
	late.StockMovements = &effects

	input := ForceTakeoverInput{OperationID: f.id(t), SessionID: session.Id, DeviceID: f.binding.Device.ID, ConfirmedRegister: "register", Reason: "tablet hilang", Actor: RecoveryActor{ID: manager, Name: "Mira"}}
	first, err := f.svc.ForceTakeover(ctx, f.binding.Tenant.ID, input)
	require.NoError(t, err)
	pointer, err := f.svc.RecoveryForSession(ctx, f.binding, session.Id)
	require.NoError(t, err)
	require.Equal(t, first.RecoveryID, pointer.ID)
	otherDevice := f.device(t, false)
	pointer, err = f.svc.RecoveryForSession(ctx, otherDevice, session.Id)
	require.NoError(t, err)
	require.Nil(t, pointer)
	replay, err := f.svc.ForceTakeover(ctx, f.binding.Tenant.ID, input)
	require.NoError(t, err)
	require.True(t, replay.Idempotent)
	require.Equal(t, first.RecoveryID, replay.RecoveryID)

	for i := 0; i < 2; i++ {
		result := f.push("orders", late)[0]
		require.Equal(t, wire.PushResultStatus("rejected"), result.Status)
		require.Equal(t, wire.PushResultCode("recovery_required"), *result.Code)
		require.Equal(t, first.RecoveryID, string(*result.RecoveryId))
	}
	require.EqualValues(t, 1, f.count(t, "till_recovery_items"))
	require.Zero(t, f.count(t, "orders"))
	require.Zero(t, f.count(t, "stock_movements"))

	cases, err := f.svc.ListRecoveries(ctx, f.binding.Tenant.ID)
	require.NoError(t, err)
	require.Len(t, cases, 1)
	require.Len(t, cases[0].Items, 1)
	require.NoError(t, f.svc.AcceptRecoveryItem(ctx, f.binding.Tenant.ID, RecoveryActor{ID: manager, Name: "Mira"}, first.RecoveryID, cases[0].Items[0].ID))
	require.EqualValues(t, 1, f.count(t, "orders"))
	require.EqualValues(t, 1, f.count(t, "stock_movements"))

	accepted(t, f.push("orders", late))
	require.EqualValues(t, 1, f.count(t, "orders"))
	require.EqualValues(t, 1, f.count(t, "stock_movements"))

	discarded := f.order(t, session.Id)
	discarded.CashierId = &cashier
	discarded.Items[0].ProductId = &product
	discardEffect := effect
	discardEffect.Id = f.id(t)
	discardEffects := []wire.StockMovement{discardEffect}
	discarded.StockMovements = &discardEffects
	require.Equal(t, wire.PushResultCode("recovery_required"), *f.push("orders", discarded)[0].Code)
	cases, err = f.svc.ListRecoveries(ctx, f.binding.Tenant.ID)
	require.NoError(t, err)
	var discardItem string
	for _, item := range cases[0].Items {
		if item.EntityID == discarded.Id {
			discardItem = item.ID
		}
	}
	require.NotEmpty(t, discardItem)
	var generationBefore int64
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT generation FROM report_dirty_slices WHERE tenant_id=$1`, f.binding.Tenant.ID).Scan(&generationBefore))
	require.NoError(t, f.svc.DiscardRecoveryItem(ctx, f.binding.Tenant.ID, RecoveryActor{ID: manager, Name: "Mira"}, first.RecoveryID, discardItem, "duplicate paper receipt"))
	require.EqualValues(t, 1, f.count(t, "orders"))
	require.EqualValues(t, 1, f.count(t, "stock_movements"))
	var generationAfter int64
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT generation FROM report_dirty_slices WHERE tenant_id=$1`, f.binding.Tenant.ID).Scan(&generationAfter))
	require.Equal(t, generationBefore, generationAfter)
	require.NoError(t, f.svc.ReconcileRecovery(ctx, f.binding.Tenant.ID, RecoveryActor{ID: manager, Name: "Mira"}, first.RecoveryID, "device_checked", "antrean perangkat telah diperiksa"))
}

func TestConcurrentTakeoverHasOneWinnerAndTenantIsolation(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	cashier := f.cashier(t)
	var manager string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO employees(tenant_id,name,role) VALUES($1,'Mira','manager') RETURNING id::text`, f.binding.Tenant.ID).Scan(&manager))
	session := f.session(t, false)
	session.EmployeeId = &cashier
	_, err := f.svc.OpenTill(ctx, f.binding, f.access(t, f.binding, cashier), session)
	require.NoError(t, err)

	start := make(chan struct{})
	errs := make([]error, 2)
	var wg sync.WaitGroup
	for i := range errs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			_, errs[i] = f.svc.ForceTakeover(ctx, f.binding.Tenant.ID, ForceTakeoverInput{OperationID: f.id(t), SessionID: session.Id, DeviceID: f.binding.Device.ID, ConfirmedRegister: "register", Reason: "lost", Actor: RecoveryActor{ID: manager, Name: "Mira"}})
		}(i)
	}
	close(start)
	wg.Wait()
	winners := 0
	for _, err := range errs {
		if err == nil {
			winners++
		}
	}
	require.Equal(t, 1, winners)
	require.EqualValues(t, 1, f.count(t, "till_recoveries"))

	var otherTenant string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO tenants(name,slug) VALUES('other',gen_random_uuid()::text) RETURNING id::text`).Scan(&otherTenant))
	hidden, err := f.svc.ListRecoveries(ctx, otherTenant)
	require.NoError(t, err)
	require.Empty(t, hidden)
}

// Closing a case is the manager saying "I have accounted for everything this
// drawer produced". A pending item means they have not, so the close is
// refused rather than quietly deciding the item by omission.
func TestReconcileIsRefusedWhileAnItemIsStillPending(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	cashier := f.cashier(t)
	var manager string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO employees(tenant_id,name,role) VALUES($1,'Mira','manager') RETURNING id::text`, f.binding.Tenant.ID).Scan(&manager))
	session := f.session(t, false)
	session.EmployeeId = &cashier
	_, err := f.svc.OpenTill(ctx, f.binding, f.access(t, f.binding, cashier), session)
	require.NoError(t, err)

	actor := RecoveryActor{ID: manager, Name: "Mira"}
	takeover, err := f.svc.ForceTakeover(ctx, f.binding.Tenant.ID, ForceTakeoverInput{
		OperationID: f.id(t), SessionID: session.Id, DeviceID: f.binding.Device.ID,
		ConfirmedRegister: "register", Reason: "tablet tertinggal", Actor: actor,
	})
	require.NoError(t, err)

	product := f.product(t, f.binding.Tenant.ID)
	late := f.order(t, session.Id)
	late.CashierId = &cashier
	late.Items[0].ProductId = &product
	lateEffects := []wire.StockMovement{{Id: f.id(t), Revision: 1, ProductId: product, ProductName: "Es Teh", Reason: "sale", DeltaQty: -2, OccurredAtMs: time.Now().UnixMilli(), EmployeeName: "Sari"}}
	late.StockMovements = &lateEffects
	require.Equal(t, wire.PushResultCode("recovery_required"), *f.push("orders", late)[0].Code)

	err = f.svc.ReconcileRecovery(ctx, f.binding.Tenant.ID, actor, takeover.RecoveryID, "device_checked", "sudah diperiksa")
	require.ErrorContains(t, err, "recovery_items_pending")
	require.Equal(t, "open", f.recoveryStatus(t, takeover.RecoveryID))

	cases, err := f.svc.ListRecoveries(ctx, f.binding.Tenant.ID)
	require.NoError(t, err)
	require.Len(t, cases[0].Items, 1)
	require.NoError(t, f.svc.DiscardRecoveryItem(ctx, f.binding.Tenant.ID, actor, takeover.RecoveryID, cases[0].Items[0].ID, "struk kertas ganda"))

	require.NoError(t, f.svc.ReconcileRecovery(ctx, f.binding.Tenant.ID, actor, takeover.RecoveryID, "device_checked", "sudah diperiksa"))
	require.Equal(t, "reconciled", f.recoveryStatus(t, takeover.RecoveryID))
	// Closing twice is the same close, not a second audit entry.
	require.NoError(t, f.svc.ReconcileRecovery(ctx, f.binding.Tenant.ID, actor, takeover.RecoveryID, "device_unavailable", "diulang"))
	require.EqualValues(t, 1, f.eventCount(t, takeover.RecoveryID, "reconciled"))
	var basis string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT reconciliation_basis FROM till_recoveries WHERE id=$1`, takeover.RecoveryID).Scan(&basis))
	require.Equal(t, "device_checked", basis, "the second close must not restate the first one's basis")
}

// The diagnostic is what an operator reads before touching anything, so it has
// to name the orphan and stay read-only. Each state below is one the till and
// the server can actually reach; the report must classify it, not repair it.
func TestDiagnoseTillNamesItsOrphansAndChangesNothing(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	tenant := f.binding.Tenant.ID

	report, err := f.svc.DiagnoseTill(ctx, tenant)
	require.NoError(t, err)
	require.Equal(t, "healthy", report.Status)
	require.Empty(t, report.Findings)

	// A legacy push opens a session no coordinated claim owns.
	legacy := f.session(t, false)
	accepted(t, f.push("pos_sessions", legacy))
	report, err = f.svc.DiagnoseTill(ctx, tenant)
	require.NoError(t, err)
	require.Equal(t, "conflict", report.Status)
	require.Equal(t, []DiagnosticFinding{{
		Classification: "conflict", Code: "open_session_without_claim", Entity: "pos_session",
		EntityID: legacy.Id, Action: "Inspect the register and create a controlled recovery before assigning another device.",
	}}, report.Findings)

	// An order whose receipt claims stock effects the ledger does not hold is
	// the money/stock divergence this check exists for.
	product := f.product(t, tenant)
	order := f.order(t, legacy.Id)
	order.Items[0].ProductId = &product
	effect := wire.StockMovement{Id: f.id(t), Revision: 1, ProductId: product, ProductName: "Kopi", Reason: "sale", DeltaQty: -2, OccurredAtMs: time.Now().UnixMilli(), EmployeeName: "Sari"}
	effects := []wire.StockMovement{effect}
	order.StockMovements = &effects
	accepted(t, f.push("orders", order))
	_, err = f.db.Owner.Exec(ctx, `DELETE FROM stock_movements WHERE id=$1`, effect.Id)
	require.NoError(t, err)

	report, err = f.svc.DiagnoseTill(ctx, tenant)
	require.NoError(t, err)
	require.Equal(t, "recovery_required", report.Status)
	require.Contains(t, codesOf(report), "order_stock_effect_missing")

	// A revoked installation still holding an open drawer, and the case a
	// controlled takeover leaves behind, are both named.
	cashier := f.cashier(t)
	var manager string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO employees(tenant_id,name,role) VALUES($1,'Mira','manager') RETURNING id::text`, tenant).Scan(&manager))
	coordinated := f.device(t, true)
	session := f.session(t, false)
	session.EmployeeId = &cashier
	_, err = f.svc.OpenTill(ctx, coordinated, f.access(t, coordinated, cashier), session)
	require.NoError(t, err)
	_, err = f.db.Owner.Exec(ctx, `UPDATE devices SET revoked_at=now() WHERE id=$1`, coordinated.Device.ID)
	require.NoError(t, err)

	report, err = f.svc.DiagnoseTill(ctx, tenant)
	require.NoError(t, err)
	require.Contains(t, codesOf(report), "revoked_device_holds_session")

	ordersBefore, movementsBefore, sessionsBefore := f.count(t, "orders"), f.count(t, "stock_movements"), f.count(t, "pos_sessions")
	var registerName string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT name FROM pos_registers WHERE id=$1`, coordinated.Register.ID).Scan(&registerName))
	_, err = f.svc.ForceTakeover(ctx, tenant, ForceTakeoverInput{
		OperationID: f.id(t), SessionID: session.Id, DeviceID: coordinated.Device.ID,
		ConfirmedRegister: registerName, Reason: "perangkat dicabut", Actor: RecoveryActor{ID: manager, Name: "Mira"},
	})
	require.NoError(t, err)

	report, err = f.svc.DiagnoseTill(ctx, tenant)
	require.NoError(t, err)
	require.Contains(t, codesOf(report), "open_recovery")
	require.NotContains(t, codesOf(report), "revoked_device_holds_session", "the drawer is closed, so this orphan is gone")
	// Read-only: running the diagnostic twice repairs nothing and loses nothing.
	require.NoError(t, err)
	require.Equal(t, ordersBefore, f.count(t, "orders"))
	require.Equal(t, movementsBefore, f.count(t, "stock_movements"))
	require.Equal(t, sessionsBefore, f.count(t, "pos_sessions"))
}

func codesOf(r DiagnosticReport) []string {
	out := make([]string, 0, len(r.Findings))
	for _, f := range r.Findings {
		out = append(out, f.Code)
	}
	return out
}

func (f *fixture) recoveryStatus(t *testing.T, id string) string {
	t.Helper()
	var status string
	require.NoError(t, f.db.Owner.QueryRow(context.Background(), `SELECT status FROM till_recoveries WHERE id=$1`, id).Scan(&status))
	return status
}

func (f *fixture) eventCount(t *testing.T, recovery, event string) int64 {
	t.Helper()
	var n int64
	require.NoError(t, f.db.Owner.QueryRow(context.Background(), `SELECT count(*) FROM till_recovery_events WHERE recovery_id=$1 AND event_type=$2`, recovery, event).Scan(&n))
	return n
}

// A session that reached the server through the legacy push path has no
// `till_claims` row, which is the state `DiagnoseTill` reports as
// `open_session_without_claim`. The till can neither resume nor close such a
// drawer, so a controlled takeover is the ONLY way out — and it has to work.
// Requiring a claim here would lock a merchant out of their own register.
func TestTakeoverClosesADrawerThatHasNoClaim(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	var manager string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO employees(tenant_id,name,role) VALUES($1,'Mira','manager') RETURNING id::text`, f.binding.Tenant.ID).Scan(&manager))

	// The legacy path: the session arrives as a pushed row, so no claim and no
	// coordinated register.
	legacy := f.session(t, false)
	accepted(t, f.push("pos_sessions", legacy))
	require.Zero(t, f.count(t, "till_claims"))

	report, err := f.svc.DiagnoseTill(ctx, f.binding.Tenant.ID)
	require.NoError(t, err)
	require.Contains(t, codesOf(report), "open_session_without_claim")

	out, err := f.svc.ForceTakeover(ctx, f.binding.Tenant.ID, ForceTakeoverInput{
		OperationID: f.id(t), SessionID: legacy.Id, DeviceID: f.binding.Device.ID,
		ConfirmedRegister: "register", Reason: "laci tanpa klaim, kasir tidak dapat menutupnya",
		Actor: RecoveryActor{ID: manager, Name: "Mira"},
	})
	require.NoError(t, err)

	var closeKind string
	var closedAt *int64
	var recoveryID *string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT close_kind,closed_at_ms,forced_recovery_id::text
		FROM pos_sessions WHERE id=$1`, legacy.Id).Scan(&closeKind, &closedAt, &recoveryID))
	require.Equal(t, "forced", closeKind)
	require.NotNil(t, closedAt)
	require.NotNil(t, recoveryID)
	require.Equal(t, out.RecoveryID, *recoveryID)

	// The register is free again, which is the whole point of the escape hatch.
	var open int64
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT count(*) FROM pos_sessions
		WHERE pos_register_id=$1 AND closed_at_ms IS NULL`, f.binding.Register.ID).Scan(&open))
	require.Zero(t, open)

	report, err = f.svc.DiagnoseTill(ctx, f.binding.Tenant.ID)
	require.NoError(t, err)
	require.NotContains(t, codesOf(report), "open_session_without_claim")
	require.Contains(t, codesOf(report), "open_recovery")

	// What the till needs to close its own stale row. The installation that
	// owned the drawer asks about it by id and must be told the closure
	// happened, even though this session never had a claim for `CurrentTill`
	// to find — that is how a drawer opened by a pre-coordination build stops
	// being "cannot be resumed" on the device.
	pointer, err := f.svc.RecoveryForSession(ctx, f.binding, legacy.Id)
	require.NoError(t, err)
	require.NotNil(t, pointer)
	require.Equal(t, out.RecoveryID, pointer.ID)
	require.NotZero(t, pointer.ForcedAtMs)

	// And the claim lookup stays empty WITHOUT erroring, so the till reads
	// `data: null` beside that pointer rather than a failed request.
	cashier := f.cashier(t)
	current, err := f.svc.CurrentTill(ctx, f.binding, f.access(t, f.binding, cashier))
	require.NoError(t, err)
	require.Nil(t, current)
}

// A recovery decision is made today about a sale that happened on another
// trading day, and the money belongs to the day it was taken. So approval must
// mark THAT slice dirty — not the manager's. Marking the decision date would
// move a Saturday's takings into Monday's report and leave Saturday short with
// nothing to show why.
func TestAnApprovedLateSaleMarksItsOwnBusinessDate(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	cashier := f.cashier(t)
	var manager string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `INSERT INTO employees(tenant_id,name,role) VALUES($1,'Mira','manager') RETURNING id::text`, f.binding.Tenant.ID).Scan(&manager))
	session := f.session(t, false)
	session.EmployeeId = &cashier
	_, err := f.svc.OpenTill(ctx, f.binding, f.access(t, f.binding, cashier), session)
	require.NoError(t, err)

	// Two days ago, so the date cannot be confused with today's by accident.
	sold := time.Now().AddDate(0, 0, -2)
	late := f.order(t, session.Id)
	late.CashierId = &cashier
	late.BusinessDate = sold.UTC().Format(time.DateOnly)
	late.PlacedAtMs = sold.UnixMilli()
	// A coordinated session's receipt must declare its stock effects, even
	// when it has none: absence is "the till did not say", not "nothing moved".
	late.StockMovements = &[]wire.StockMovement{}

	takeover, err := f.svc.ForceTakeover(ctx, f.binding.Tenant.ID, ForceTakeoverInput{
		OperationID: f.id(t), SessionID: session.Id, DeviceID: f.binding.Device.ID,
		ConfirmedRegister: "register", Reason: "tablet tertinggal", Actor: RecoveryActor{ID: manager, Name: "Mira"},
	})
	require.NoError(t, err)
	require.Equal(t, wire.PushResultCode("recovery_required"), *f.push("orders", late)[0].Code)

	cases, err := f.svc.ListRecoveries(ctx, f.binding.Tenant.ID)
	require.NoError(t, err)
	require.Len(t, cases[0].Items, 1)

	_, err = f.db.Owner.Exec(ctx, `DELETE FROM report_dirty_slices WHERE tenant_id = $1`, f.binding.Tenant.ID)
	require.NoError(t, err)
	require.NoError(t, f.svc.AcceptRecoveryItem(ctx, f.binding.Tenant.ID,
		RecoveryActor{ID: manager, Name: "Mira"}, takeover.RecoveryID, cases[0].Items[0].ID))

	var marked []time.Time
	rows, err := f.db.Owner.Query(ctx, `SELECT business_date FROM report_dirty_slices WHERE tenant_id = $1`, f.binding.Tenant.ID)
	require.NoError(t, err)
	for rows.Next() {
		var day time.Time
		require.NoError(t, rows.Scan(&day))
		marked = append(marked, day)
	}
	require.NoError(t, rows.Err())
	require.Len(t, marked, 1)
	require.Equal(t, late.BusinessDate, marked[0].Format(time.DateOnly), "the sale's day, not the decision's")
}
