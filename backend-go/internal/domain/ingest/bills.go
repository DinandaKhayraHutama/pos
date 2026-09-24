package ingest

// Saved bills (Fase 4 paritas) — the push half.
//
// A bill is the mutable thing a table runs up; a receipt (`orders`) is what it
// becomes when it is paid. Three rows carry the cycle, and each is idempotent
// on its own id:
//
//   - `bills`: the bill as its owning till last saved it, at a revision.
//     Saving moves no money and no stock.
//   - `kitchen_dispatches`: lines confirmed for the kitchen, with the stock
//     they consumed. Immutable; only the kitchen status moves forward.
//   - `orders` with a bill_id: the receipt. It consumes nothing — every line
//     was dispatched first — and it closes the bill.
//
// One till owns a bill at a time. Ownership moves only online (park, claim, a
// manager's forced release) and every move raises owner_generation, so a
// snapshot or dispatch from a till that has lost the bill is refused no matter
// how new its revision looks.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/stock"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/jackc/pgx/v5"
)

const (
	// BillEntity and DispatchEntity are the push names of the two Fase 4 rows.
	BillEntity     = "bills"
	DispatchEntity = "kitchen_dispatches"
)

const (
	msgOtherOutlet  = "The bill belongs to another outlet."
	msgLinesPending = "Push the bill revision holding these lines first."
)

func billNotOwned() error {
	return reject("bill_not_owned", "This till no longer owns the bill. Its changes are kept on the till as evidence.")
}

// billState is the locked server row of one bill.
type billState struct {
	id           string
	outletID     string
	ownerDevice  *string
	ownerSession *string
	generation   int64
	revision     int64
	status       string
	closedOrder  *string
	payload      []byte
}

// lockBill reads a bill FOR UPDATE: every write to a bill — a snapshot, a
// dispatch, a settlement, a park or a claim — serialises on this one row.
func lockBill(ctx context.Context, tx pgx.Tx, id string) (billState, bool, error) {
	var st billState
	err := tx.QueryRow(ctx, `SELECT id::text, outlet_id::text, owner_device_id::text, owner_session_id::text,
		owner_generation, revision, status, closed_order_id::text, payload
		FROM bills WHERE id = $1 FOR UPDATE`, id).Scan(&st.id, &st.outletID, &st.ownerDevice, &st.ownerSession,
		&st.generation, &st.revision, &st.status, &st.closedOrder, &st.payload)
	if errors.Is(err, pgx.ErrNoRows) {
		return st, false, nil
	}
	return st, err == nil, err
}

func (st billState) ownedBy(b devices.Binding, generation int64) bool {
	return st.ownerDevice != nil && *st.ownerDevice == b.Device.ID && st.generation == generation
}

// canonicalLine is the form two copies of one bill line are compared in.
func canonicalLine(line wire.BillLine) []byte {
	line.Id = strings.ToLower(line.Id)
	return encode(line)
}

func lowerPtr(p *string) *string {
	if p == nil {
		return nil
	}
	v := strings.ToLower(*p)
	return &v
}

func validateBillLines(lines []wire.BillLine) error {
	ids := map[string]bool{}
	for i := range lines {
		line := &lines[i]
		line.Id = strings.ToLower(line.Id)
		line.ProductId = lowerPtr(line.ProductId)
		if !validUUID(line.Id) || ids[line.Id] {
			return reject("schema_rejected", "Every bill line needs its own UUID.")
		}
		ids[line.Id] = true
		if strings.TrimSpace(line.ProductName) == "" || line.Quantity < 1 {
			return reject("schema_rejected", "Invalid bill line.")
		}
		if line.Custom && line.ProductId != nil {
			return reject("schema_rejected", "A custom amount names no product.")
		}
		if !optionalUUIDs(line.ProductId, line.CategoryId, line.BrandId, line.LineDiscountId, line.LineDiscountAuthorizedById) {
			return reject("schema_rejected", "Invalid bill line reference.")
		}
		if line.Discount != nil && line.Discount.Kind == "percent" && line.Discount.Value > 10000 {
			return reject("schema_rejected", "A percentage discount cannot exceed 100%.")
		}
	}
	return nil
}

func validateBill(in *wire.Bill) error {
	in.Id, in.PosSessionId = strings.ToLower(in.Id), strings.ToLower(in.PosSessionId)
	if in.TableSessionId != nil {
		v := strings.ToLower(*in.TableSessionId)
		in.TableSessionId = &v
	}
	in.TableId, in.CustomerId = lowerPtr(in.TableId), lowerPtr(in.CustomerId)
	if !validUUID(in.Id) || !validUUID(in.PosSessionId) || strings.TrimSpace(in.Number) == "" ||
		strings.TrimSpace(in.CreatedByName) == "" || in.OpenedAtMs > maxMillis {
		return reject("schema_rejected", "Invalid bill identity.")
	}
	if in.TableSessionId != nil && !validUUID(*in.TableSessionId) {
		return reject("schema_rejected", "Invalid table seating.")
	}
	if !optionalUUIDs(in.TableId, in.CustomerId, in.ServedById, in.CreatedById, in.SalesTypeId,
		in.Pricing.DiscountId, in.Pricing.DiscountAuthorizedById) {
		return reject("schema_rejected", "Invalid bill reference.")
	}
	if d := in.Pricing.BillDiscount; d != nil && d.Kind == "percent" && d.Value > 10000 {
		return reject("schema_rejected", "A percentage discount cannot exceed 100%.")
	}
	switch in.Status {
	case wire.BillStatusOpen:
		if in.Cancel != nil {
			return reject("schema_rejected", "Only a cancelled bill carries a cancellation.")
		}
	case wire.BillStatusCancelled:
		c := in.Cancel
		if c == nil || strings.TrimSpace(c.Reason) == "" || strings.TrimSpace(c.AuthorizedBy) == "" ||
			c.CancelledAtMs > maxMillis || !optionalUUIDs(c.AuthorizedById) {
			return reject("schema_rejected", "Cancelling a bill needs a reason and who allowed it.")
		}
	default:
		return reject("schema_rejected", "A bill is pushed open or cancelled; the receipt closes it.")
	}
	return validateBillLines(in.Lines)
}

// sessionOfThisDevice checks that a session named by a bill or dispatch is one
// this till opened. A session the server has not seen yet is pushed in the
// same request ahead of it; until it arrives the row waits.
func sessionOfThisDevice(ctx context.Context, tx pgx.Tx, b devices.Binding, id string) error {
	var device string
	err := tx.QueryRow(ctx, `SELECT device_id::text FROM pos_sessions WHERE id = $1`, id).Scan(&device)
	if errors.Is(err, pgx.ErrNoRows) {
		return retry("dependency_pending", "Push the session before its bills.")
	}
	if err != nil {
		return err
	}
	if device != b.Device.ID {
		return reject("schema_rejected", "The session belongs to another till.")
	}
	return nil
}

func billSubtotal(lines []wire.BillLine) int64 {
	var sum int64
	for _, l := range lines {
		sum += l.UnitPrice * int64(l.Quantity)
	}
	return sum
}

// ingestBill applies one bill snapshot.
func (s *Service) ingestBill(ctx context.Context, w *syncfeed.Writer, b devices.Binding, raw json.RawMessage, result *wire.PushResult) error {
	if err := s.conform(BillEntity, raw); err != nil {
		return err
	}
	var in wire.Bill
	if json.Unmarshal(raw, &in) != nil {
		return reject("schema_rejected", "Invalid bill values.")
	}
	if err := validateBill(&in); err != nil {
		return err
	}
	tx := w.Tx
	st, found, err := lockBill(ctx, tx, in.Id)
	if err != nil {
		return err
	}
	inserted := !found
	result.Inserted = &inserted

	if !found {
		// A new bill starts at generation 1 under the till that pushed it.
		if in.OwnerGeneration != 1 {
			return billNotOwned()
		}
		if err := sessionOfThisDevice(ctx, tx, b, in.PosSessionId); err != nil {
			return err
		}
		if in.Status != wire.BillStatusOpen {
			// Cancelled before it ever reached the server: still recorded, so
			// the cancellation and its reason are not lost.
			if len(in.Cancel.StockMovements) > 0 || len(in.Cancel.Decisions) > 0 {
				return reject("schema_rejected", "A bill never dispatched has nothing to return.")
			}
		}
		payload := encode(in)
		if _, err := tx.Exec(ctx, `INSERT INTO bills (id, tenant_id, outlet_id, pos_register_id, created_device_id,
			owner_device_id, owner_session_id, owner_generation, revision, number, status, table_session_id,
			table_name, customer_name, subtotal, line_count, opened_at_ms, cancelled_at, payload)
			VALUES ($1,$2,$3,$4,$5,$5,$6,1,$7,$8,$9,$10,$11,$12,$13,$14,$15,
			        CASE WHEN $9 = 'cancelled' THEN now() END, $16)`,
			in.Id, b.Tenant.ID, b.Outlet.ID, b.Register.ID, b.Device.ID, in.PosSessionId, in.Revision,
			strings.TrimSpace(in.Number), string(in.Status), in.TableSessionId, in.TableName, in.CustomerName,
			billSubtotal(in.Lines), len(in.Lines), in.OpenedAtMs, payload); err != nil {
			return err
		}
		return insertBillLines(ctx, tx, b, in.Id, in.Lines, nil)
	}

	if st.outletID != b.Outlet.ID {
		return reject("schema_rejected", msgOtherOutlet)
	}
	// An exact retry is answered before ownership is judged: a till whose
	// accepted revision never heard back must be able to settle it even after
	// it parked the bill.
	if in.Revision == st.revision {
		var stored wire.Bill
		if json.Unmarshal(st.payload, &stored) == nil && bytes.Equal(encode(stored), encode(in)) {
			result.Effects = s.effectsBoundTo(ctx, tx, "bill_cancel", in.Id)
			return nil
		}
	}
	if !st.ownedBy(b, in.OwnerGeneration) {
		return billNotOwned()
	}
	if st.status != "open" {
		return reject("settled", "The bill is already closed or cancelled.")
	}
	if in.Revision <= st.revision {
		if in.Revision == st.revision {
			return reject("duplicate", "This revision already names a different bill.")
		}
		return reject("stale_revision", "A newer revision of this bill is already stored.")
	}
	if err := sessionOfThisDevice(ctx, tx, b, in.PosSessionId); err != nil {
		return err
	}

	// A line the kitchen already received is a fact: every later revision
	// must carry it exactly as it was dispatched.
	dispatched := map[string][]byte{}
	rows, err := tx.Query(ctx, `SELECT id::text, payload FROM bill_lines WHERE bill_id = $1 AND dispatch_id IS NOT NULL`, in.Id)
	if err != nil {
		return err
	}
	for rows.Next() {
		var id string
		var payload []byte
		if err := rows.Scan(&id, &payload); err != nil {
			rows.Close()
			return err
		}
		var line wire.BillLine
		if err := json.Unmarshal(payload, &line); err != nil {
			rows.Close()
			return err
		}
		dispatched[id] = canonicalLine(line)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	present := map[string]bool{}
	for _, line := range in.Lines {
		if stored, ok := dispatched[line.Id]; ok {
			if !bytes.Equal(stored, canonicalLine(line)) {
				return reject("schema_rejected", "A line sent to the kitchen cannot change.")
			}
			present[line.Id] = true
		}
	}
	if len(present) != len(dispatched) {
		return reject("schema_rejected", "A line sent to the kitchen cannot be removed.")
	}

	var effects []stock.Applied
	if in.Status == wire.BillStatusCancelled {
		if effects, err = s.cancelBill(ctx, w, b, in, dispatched); err != nil {
			return err
		}
	}

	if _, err := tx.Exec(ctx, `DELETE FROM bill_lines WHERE bill_id = $1 AND dispatch_id IS NULL`, in.Id); err != nil {
		return err
	}
	if err := insertBillLines(ctx, tx, b, in.Id, in.Lines, dispatched); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE bills SET revision = $2, number = $3, status = $4, table_session_id = $5,
		table_name = $6, customer_name = $7, subtotal = $8, line_count = $9, owner_session_id = $10,
		cancelled_at = CASE WHEN $4 = 'cancelled' THEN now() END, payload = $11, updated_at = now()
		WHERE id = $1`,
		in.Id, in.Revision, strings.TrimSpace(in.Number), string(in.Status), in.TableSessionId, in.TableName,
		in.CustomerName, billSubtotal(in.Lines), len(in.Lines), in.PosSessionId, encode(in)); err != nil {
		return err
	}
	result.Effects = effectsOf(effects)
	return nil
}

// insertBillLines writes the lines of a snapshot that are not already stored
// as dispatched.
func insertBillLines(ctx context.Context, tx pgx.Tx, b devices.Binding, billID string, lines []wire.BillLine, skip map[string][]byte) error {
	for _, line := range lines {
		if _, ok := skip[line.Id]; ok {
			continue
		}
		if _, err := tx.Exec(ctx, `INSERT INTO bill_lines (id, tenant_id, bill_id, seq, product_id, product_name,
			quantity, unit_price, custom, payload) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
			line.Id, b.Tenant.ID, billID, line.Seq, line.ProductId, line.ProductName, line.Quantity,
			line.UnitPrice, line.Custom, canonicalLine(line)); err != nil {
			return err
		}
	}
	return nil
}

// consumedByBill is what the bill's dispatches took off the shelf, net of
// what a cancellation already put back, per product.
func consumedByBill(ctx context.Context, tx pgx.Tx, billID string) (map[string]int64, error) {
	rows, err := tx.Query(ctx, `
		SELECT m.product_id::text, -sum(m.delta_qty)
		FROM stock_movements m
		WHERE m.ref_type = 'dispatch' AND m.reason = 'sale'
		  AND m.ref_id IN (SELECT id FROM kitchen_dispatches WHERE bill_id = $1)
		GROUP BY m.product_id`, billID)
	if err != nil {
		return nil, err
	}
	out := map[string]int64{}
	for rows.Next() {
		var product string
		var qty int64
		if err := rows.Scan(&product, &qty); err != nil {
			rows.Close()
			return nil, err
		}
		out[product] = qty
	}
	rows.Close()
	return out, rows.Err()
}

func (s *Service) effectsBoundTo(ctx context.Context, tx pgx.Tx, refType, refID string) *[]wire.PushEffect {
	rows, err := tx.Query(ctx, `SELECT id::text, applied_stock_seq, balance_after FROM stock_movements
		WHERE ref_type = $1 AND ref_id = $2 ORDER BY id`, refType, refID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []stock.Applied
	for rows.Next() {
		var a stock.Applied
		if rows.Scan(&a.ID, &a.StockSeq, &a.BalanceAfter) != nil {
			return nil
		}
		out = append(out, a)
	}
	return effectsOf(out)
}

// cancelBill records a cancellation's physical side. Every dispatched line
// needs a decision: restock puts it back on the shelf, waste classifies a
// consumption that already happened and moves nothing — never a second debit.
func (s *Service) cancelBill(ctx context.Context, w *syncfeed.Writer, b devices.Binding, in wire.Bill, dispatched map[string][]byte) ([]stock.Applied, error) {
	restockable := map[string]int64{}
	decided := map[string]bool{}
	lines := map[string]wire.BillLine{}
	for _, line := range in.Lines {
		lines[line.Id] = line
	}
	for _, d := range in.Cancel.Decisions {
		id := strings.ToLower(d.BillLineId)
		if _, ok := dispatched[id]; !ok || decided[id] {
			return nil, reject("schema_rejected", "A decision names a line that was not sent to the kitchen.")
		}
		decided[id] = true
		if d.Disposition == wire.BillCancelDecisionsDispositionRestock {
			if line := lines[id]; line.ProductId != nil {
				restockable[*line.ProductId] += int64(line.Quantity)
			}
		}
	}
	if len(decided) != len(dispatched) {
		return nil, reject("schema_rejected", "Every line sent to the kitchen needs a restock or waste decision.")
	}
	consumed, err := consumedByBill(ctx, w.Tx, in.Id)
	if err != nil {
		return nil, err
	}
	returns := map[string]int64{}
	movements := make([]stock.DeviceMovement, 0, len(in.Cancel.StockMovements))
	for _, effect := range in.Cancel.StockMovements {
		var m stock.DeviceMovement
		if err := json.Unmarshal(encode(effect), &m); err != nil {
			return nil, err
		}
		m.ProductID = strings.ToLower(m.ProductID)
		if m.Reason != stock.ReasonVoidReturn {
			return nil, reject("schema_rejected", "A cancellation only returns stock.")
		}
		returns[m.ProductID] += m.DeltaQty
		if returns[m.ProductID] > restockable[m.ProductID] || returns[m.ProductID] > consumed[m.ProductID] {
			return nil, reject("schema_rejected", "More stock returned than the bill's dispatches consumed.")
		}
		movements = append(movements, m)
	}
	applied, err := s.stock.RecordBatchFromDevice(ctx, w, b, movements, "bill_cancel", in.Id)
	if err != nil {
		var rejection *stock.Rejection
		if errors.As(err, &rejection) {
			return nil, reject(rejection.Code, rejection.Message)
		}
		return nil, err
	}
	if _, err := w.Tx.Exec(ctx, `UPDATE kitchen_dispatches SET status = 'cancelled', revision = revision + 1,
		status_changed_at_ms = $2, updated_at = now()
		WHERE bill_id = $1 AND status IN ('queued', 'preparing', 'ready')`, in.Id, in.Cancel.CancelledAtMs); err != nil {
		return nil, err
	}
	return applied, nil
}

var dispatchOrder = map[wire.KitchenDispatchStatus]int{
	wire.KitchenDispatchStatusQueued: 0, wire.KitchenDispatchStatusPreparing: 1,
	wire.KitchenDispatchStatusReady: 2, wire.KitchenDispatchStatusServed: 3,
	wire.KitchenDispatchStatusCancelled: 4,
}

// immutableDispatch is what a dispatch may never change after it is accepted:
// everything but its kitchen status, revision and the owner generation of the
// till reporting that status.
func immutableDispatch(in wire.KitchenDispatch) []byte {
	in.Revision, in.Status, in.StatusChangedAtMs, in.OwnerGeneration = 0, "", 0, 0
	for i := range in.Lines {
		in.Lines[i].Id = strings.ToLower(in.Lines[i].Id)
	}
	return encode(in)
}

func validateDispatch(in *wire.KitchenDispatch) error {
	in.Id, in.BillId, in.PosSessionId = strings.ToLower(in.Id), strings.ToLower(in.BillId), strings.ToLower(in.PosSessionId)
	in.EmployeeId = lowerPtr(in.EmployeeId)
	if !validUUID(in.Id) || !validUUID(in.BillId) || !validUUID(in.PosSessionId) || !optionalUUIDs(in.EmployeeId) ||
		in.OccurredAtMs > maxMillis || in.StatusChangedAtMs > maxMillis {
		return reject("schema_rejected", "Invalid dispatch identity.")
	}
	if _, ok := dispatchOrder[in.Status]; !ok {
		return reject("schema_rejected", "Unknown kitchen status.")
	}
	if err := validateBillLines(in.Lines); err != nil {
		return err
	}
	for i := range in.StockMovements {
		in.StockMovements[i].Id = strings.ToLower(in.StockMovements[i].Id)
		in.StockMovements[i].ProductId = strings.ToLower(in.StockMovements[i].ProductId)
	}
	return nil
}

// ingestDispatch applies one kitchen dispatch: new, an exact retry, or a
// forward move of its kitchen status.
func (s *Service) ingestDispatch(ctx context.Context, w *syncfeed.Writer, b devices.Binding, raw json.RawMessage, result *wire.PushResult) error {
	if err := s.conform(DispatchEntity, raw); err != nil {
		return err
	}
	var in wire.KitchenDispatch
	if json.Unmarshal(raw, &in) != nil {
		return reject("schema_rejected", "Invalid dispatch values.")
	}
	if err := validateDispatch(&in); err != nil {
		return err
	}
	tx := w.Tx
	bill, found, err := lockBill(ctx, tx, in.BillId)
	if err != nil {
		return err
	}
	if !found {
		return retry("dependency_pending", "Push the bill before its dispatch.")
	}
	if bill.outletID != b.Outlet.ID {
		return reject("schema_rejected", msgOtherOutlet)
	}

	var (
		storedRevision int64
		storedStatus   string
		storedPayload  []byte
		storedDevice   string
		storedBill     string
	)
	err = tx.QueryRow(ctx, `SELECT revision, status, payload, device_id::text, bill_id::text
		FROM kitchen_dispatches WHERE id = $1 FOR UPDATE`, in.Id).Scan(&storedRevision, &storedStatus, &storedPayload, &storedDevice, &storedBill)
	switch {
	case err == nil:
		inserted := false
		result.Inserted = &inserted
		if storedBill != in.BillId {
			return reject("duplicate", "This identifier already names another dispatch.")
		}
		var stored wire.KitchenDispatch
		if json.Unmarshal(storedPayload, &stored) != nil || !bytes.Equal(immutableDispatch(stored), immutableDispatch(in)) {
			return reject("duplicate", "A dispatch's lines and stock never change.")
		}
		result.Effects = s.effectsBoundTo(ctx, tx, "dispatch", in.Id)
		if in.Revision == storedRevision && string(in.Status) == storedStatus {
			return nil
		}
		if in.Revision < storedRevision {
			return reject("stale_revision", "A newer kitchen status is already stored.")
		}
		if !bill.ownedBy(b, in.OwnerGeneration) {
			return billNotOwned()
		}
		if storedStatus == string(wire.KitchenDispatchStatusCancelled) {
			return reject("settled", "The dispatch was cancelled with its bill.")
		}
		if in.Status == wire.KitchenDispatchStatusCancelled && bill.status != "cancelled" {
			return reject("schema_rejected", "A dispatch is cancelled by cancelling its bill.")
		}
		if dispatchOrder[in.Status] < dispatchOrder[wire.KitchenDispatchStatus(storedStatus)] {
			return reject("schema_rejected", "A kitchen status only moves forward.")
		}
		_, err := tx.Exec(ctx, `UPDATE kitchen_dispatches SET status = $2, revision = $3, status_changed_at_ms = $4,
			updated_at = now() WHERE id = $1`, in.Id, string(in.Status), in.Revision, in.StatusChangedAtMs)
		return err
	case !errors.Is(err, pgx.ErrNoRows):
		return err
	}

	inserted := true
	result.Inserted = &inserted
	if !bill.ownedBy(b, in.OwnerGeneration) {
		return billNotOwned()
	}
	if bill.status != "open" {
		return reject("settled", "The bill is already closed or cancelled.")
	}
	if in.Status == wire.KitchenDispatchStatusCancelled {
		return reject("schema_rejected", "A dispatch is cancelled by cancelling its bill.")
	}
	if err := sessionOfThisDevice(ctx, tx, b, in.PosSessionId); err != nil {
		return err
	}

	// Every line must be one the server holds for this bill, not yet sent,
	// and exactly as the bill holds it. A line the server does not hold yet
	// (or holds at an older revision) waits for the bill snapshot.
	ids := make([]string, len(in.Lines))
	for i, line := range in.Lines {
		ids[i] = line.Id
	}
	held := map[string]struct {
		payload  []byte
		dispatch *string
	}{}
	rows, err := tx.Query(ctx, `SELECT id::text, payload, dispatch_id::text FROM bill_lines
		WHERE bill_id = $1 AND id = ANY($2::text[]::uuid[])`, in.BillId, ids)
	if err != nil {
		return err
	}
	for rows.Next() {
		var id string
		var h struct {
			payload  []byte
			dispatch *string
		}
		if err := rows.Scan(&id, &h.payload, &h.dispatch); err != nil {
			rows.Close()
			return err
		}
		held[id] = h
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	bound := map[string]int64{}
	for _, line := range in.Lines {
		h, ok := held[line.Id]
		if !ok {
			return retry("dependency_pending", msgLinesPending)
		}
		if h.dispatch != nil {
			return reject("duplicate", "A line was already sent to the kitchen by another dispatch.")
		}
		var stored wire.BillLine
		if json.Unmarshal(h.payload, &stored) != nil || !bytes.Equal(canonicalLine(stored), canonicalLine(line)) {
			return retry("dependency_pending", msgLinesPending)
		}
		if line.ProductId != nil && !line.Custom {
			bound[*line.ProductId] += int64(line.Quantity)
		}
	}

	consumed := map[string]int64{}
	movements := make([]stock.DeviceMovement, 0, len(in.StockMovements))
	for _, effect := range in.StockMovements {
		var m stock.DeviceMovement
		if err := json.Unmarshal(encode(effect), &m); err != nil {
			return err
		}
		if m.Reason != stock.ReasonSale {
			return reject("schema_rejected", "A dispatch only consumes stock.")
		}
		consumed[m.ProductID] -= m.DeltaQty
		if consumed[m.ProductID] > bound[m.ProductID] {
			return reject("schema_rejected", "Stock consumed exceeds the dispatched lines.")
		}
		movements = append(movements, m)
	}
	applied, err := s.stock.RecordBatchFromDevice(ctx, w, b, movements, "dispatch", in.Id)
	if err != nil {
		var rejection *stock.Rejection
		if errors.As(err, &rejection) {
			return reject(rejection.Code, rejection.Message)
		}
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO kitchen_dispatches (id, tenant_id, outlet_id, bill_id, device_id,
		pos_session_id, status, revision, occurred_at_ms, employee_name, status_changed_at_ms, payload)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
		in.Id, b.Tenant.ID, b.Outlet.ID, in.BillId, b.Device.ID, in.PosSessionId, string(in.Status), in.Revision,
		in.OccurredAtMs, in.EmployeeName, in.StatusChangedAtMs, encode(in)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE bill_lines SET dispatch_id = $2 WHERE bill_id = $3 AND id = ANY($1::text[]::uuid[])`,
		ids, in.Id, in.BillId); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE bills SET updated_at = now() WHERE id = $1`, in.BillId); err != nil {
		return err
	}
	result.Effects = effectsOf(applied)
	return nil
}

// billSettlement is a bill locked for the receipt that settles it.
type billSettlement struct {
	billID   string
	already  bool
	consumed map[string]int64
}

// prepareSettlement checks a settling receipt against its bill before the
// receipt is written. recovery is true only on a manager's approval of a
// quarantined receipt, and admits exactly one more case: a bill released from
// the lost till and still unclaimed.
func (s *Service) prepareSettlement(ctx context.Context, w *syncfeed.Writer, b devices.Binding, in wire.Order, recovery bool) (*billSettlement, error) {
	id := strings.ToLower(*in.BillId)
	if !validUUID(id) {
		return nil, reject("schema_rejected", "Invalid bill reference.")
	}
	tx := w.Tx
	bill, found, err := lockBill(ctx, tx, id)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, retry("dependency_pending", "Push the bill before the receipt that settles it.")
	}
	if bill.outletID != b.Outlet.ID {
		return nil, reject("schema_rejected", msgOtherOutlet)
	}
	out := &billSettlement{billID: id}
	if out.consumed, err = consumedByBill(ctx, tx, id); err != nil {
		return nil, err
	}
	if bill.closedOrder != nil {
		if strings.EqualFold(*bill.closedOrder, in.Id) {
			out.already = true
			return out, nil
		}
		return nil, reject("settled", "The bill was already settled by another receipt.")
	}
	if bill.status != "open" {
		return nil, reject("settled", "A cancelled bill cannot be paid.")
	}
	switch {
	case bill.ownerDevice == nil && recovery:
		// Released from the lost till by the manager's takeover, and nobody
		// claimed it since: the late payment is the only one there is.
	case bill.ownerDevice == nil || *bill.ownerDevice != b.Device.ID:
		return nil, billNotOwned()
	}

	type heldLine struct {
		product    *string
		quantity   int64
		unitPrice  int64
		dispatched bool
	}
	held := map[string]heldLine{}
	rows, err := tx.Query(ctx, `SELECT id::text, product_id::text, quantity, unit_price, dispatch_id IS NOT NULL
		FROM bill_lines WHERE bill_id = $1`, id)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var lid string
		var h heldLine
		if err := rows.Scan(&lid, &h.product, &h.quantity, &h.unitPrice, &h.dispatched); err != nil {
			rows.Close()
			return nil, err
		}
		held[lid] = h
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, h := range held {
		if !h.dispatched {
			return nil, retry("dependency_pending", "Every line of the bill must reach the kitchen before it is settled.")
		}
	}
	named := map[string]bool{}
	for _, item := range in.Items {
		if item.BillLineId == nil {
			return nil, reject("schema_rejected", "Every line of a bill's receipt names its bill line.")
		}
		lid := strings.ToLower(*item.BillLineId)
		h, ok := held[lid]
		if !ok {
			return nil, retry("dependency_pending", msgLinesPending)
		}
		if named[lid] {
			return nil, reject("schema_rejected", "A bill line is settled twice on one receipt.")
		}
		named[lid] = true
		sameProduct := (h.product == nil && item.ProductId == nil) ||
			(h.product != nil && item.ProductId != nil && strings.EqualFold(*h.product, *item.ProductId))
		if !sameProduct || h.quantity != int64(item.Quantity) || h.unitPrice != item.UnitPrice {
			return nil, reject("schema_rejected", "The receipt does not match the bill it settles.")
		}
	}
	if len(named) != len(held) {
		return nil, reject("schema_rejected", "The receipt must settle every line of the bill.")
	}
	return out, nil
}

// close marks the bill settled by the receipt that was just written.
func (st *billSettlement) close(ctx context.Context, tx pgx.Tx, in wire.Order, result *wire.PushResult) error {
	if st.already {
		return nil
	}
	date := in.BusinessDate
	if result.BusinessDate != nil {
		date = *result.BusinessDate
	}
	_, err := tx.Exec(ctx, `UPDATE bills SET status = 'closed', closed_order_id = $2, closed_business_date = $3,
		closed_at = now(), updated_at = now() WHERE id = $1`, st.billID, in.Id, date)
	return err
}

// openBillsOfSession counts the open bills a session still owns. A drawer
// with one cannot close: the bill would be left with no one responsible.
func openBillsOfSession(ctx context.Context, tx pgx.Tx, sessionID string) (int, error) {
	var n int
	err := tx.QueryRow(ctx, `SELECT count(*) FROM bills WHERE owner_session_id = $1 AND status = 'open'`, sessionID).Scan(&n)
	return n, err
}
