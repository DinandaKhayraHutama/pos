package ingest

// Saved bills (Fase 4 paritas) — the online half: the outlet's board of open
// bills and seatings, moving a bill between tills, and seating or clearing a
// table.
//
// Everything here needs the network on purpose. Two tills can each save,
// dispatch and settle their OWN bills offline; deciding which till owns a bill
// and which party sits at a table cannot be decided by either of them alone.
// There is no heartbeat and no timeout: a bill changes hands only because a
// person parked it, claimed it, or a manager released it from a lost till.

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/tables"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/httpapi/wire"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// billActor resolves the cashier token and requires sell — or, when
// tablesToo, sell or manageTables.
func billActor(ctx context.Context, tx pgx.Tx, b devices.Binding, token string, tablesToo bool) (tillActor, error) {
	a, err := tillEmployee(ctx, tx, b, token)
	if err != nil {
		return a, err
	}
	if a.Access.Grants(auth.Sell) || (tablesToo && a.Access.Grants(auth.ManageTables)) {
		return a, nil
	}
	return a, tillError("forbidden_operation")
}

const billSummarySelect = `
	SELECT b.id::text, b.number, b.status, b.owner_generation, b.revision,
	       b.owner_device_id IS NOT NULL AND b.owner_device_id = $2, b.owner_device_id IS NULL,
	       r.name, d.label, b.table_session_id::text, b.table_name, b.customer_name,
	       b.subtotal, b.line_count, b.opened_at_ms, (EXTRACT(EPOCH FROM b.updated_at) * 1000)::bigint,
	       COALESCE((SELECT jsonb_object_agg(k.status, k.n) FROM (
	           SELECT status, count(*) AS n FROM kitchen_dispatches WHERE bill_id = b.id GROUP BY status) k),
	           '{}'::jsonb)
	FROM bills b
	LEFT JOIN devices d ON d.tenant_id = b.tenant_id AND d.id = b.owner_device_id
	LEFT JOIN pos_registers r ON r.tenant_id = d.tenant_id AND r.id = d.pos_register_id`

func scanBillSummary(row pgx.Row) (wire.TillBillSummary, error) {
	var s wire.TillBillSummary
	var status string
	var dispatches []byte
	err := row.Scan(&s.Id, &s.Number, &status, &s.OwnerGeneration, &s.Revision, &s.OwnedByThisDevice, &s.Parked,
		&s.OwnerRegisterName, &s.OwnerDeviceLabel, &s.TableSessionId, &s.TableName, &s.CustomerName,
		&s.Subtotal, &s.LineCount, &s.OpenedAtMs, &s.UpdatedAtMs, &dispatches)
	if err != nil {
		return s, err
	}
	s.Status = wire.TillBillSummaryStatus(status)
	s.Dispatches = map[string]int{}
	err = json.Unmarshal(dispatches, &s.Dispatches)
	return s, err
}

const tableSessionSelect = `
	SELECT s.id::text, s.table_id::text, s.table_name, s.guest_count, s.opened_at_ms, s.opened_by_name,
	       s.closed_at_ms, s.closed_by_name,
	       (SELECT count(*) FROM bills b WHERE b.table_session_id = s.id AND b.status = 'open')::int
	FROM table_sessions s`

func scanTableSession(row pgx.Row) (wire.TableSession, error) {
	var t wire.TableSession
	err := row.Scan(&t.Id, &t.TableId, &t.TableName, &t.GuestCount, &t.OpenedAtMs, &t.OpenedByName,
		&t.ClosedAtMs, &t.ClosedByName, &t.OpenBillCount)
	return t, err
}

// BillBoard is every open bill and every open seating of the device's outlet,
// read in one snapshot. Not paged: an outlet's open bills are few, and one
// consistent read cannot miss a change the way a cursor over a moving set can.
func (s *Service) BillBoard(ctx context.Context, b devices.Binding, token string) (wire.TillBillBoard, error) {
	out := wire.TillBillBoard{Bills: []wire.TillBillSummary{}, TableSessions: []wire.TableSession{}}
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		if _, err := billActor(ctx, tx, b, token, true); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, billSummarySelect+`
			WHERE b.outlet_id = $1 AND b.status = 'open'
			ORDER BY b.opened_at_ms, b.id`, b.Outlet.ID, b.Device.ID)
		if err != nil {
			return err
		}
		for rows.Next() {
			summary, err := scanBillSummary(rows)
			if err != nil {
				rows.Close()
				return err
			}
			out.Bills = append(out.Bills, summary)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		rows, err = tx.Query(ctx, tableSessionSelect+`
			WHERE s.outlet_id = $1 AND s.closed_at_ms IS NULL
			ORDER BY s.opened_at_ms, s.id`, b.Outlet.ID)
		if err != nil {
			return err
		}
		for rows.Next() {
			seating, err := scanTableSession(rows)
			if err != nil {
				rows.Close()
				return err
			}
			out.TableSessions = append(out.TableSessions, seating)
		}
		rows.Close()
		return rows.Err()
	})
	out.ServerTimeMs = time.Now().UnixMilli()
	return out, err
}

// billDetail reads one bill of the device's outlet, inside tx.
func billDetail(ctx context.Context, tx pgx.Tx, b devices.Binding, id string) (wire.TillBillDetail, error) {
	var out wire.TillBillDetail
	summary, err := scanBillSummary(tx.QueryRow(ctx, billSummarySelect+`
		WHERE b.outlet_id = $1 AND b.id = $3`, b.Outlet.ID, b.Device.ID, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return out, tillError("bill_not_found")
	}
	if err != nil {
		return out, err
	}
	out.Summary = summary
	var payload []byte
	if err := tx.QueryRow(ctx, `SELECT payload FROM bills WHERE id = $1`, id).Scan(&payload); err != nil {
		return out, err
	}
	if err := json.Unmarshal(payload, &out.Bill); err != nil {
		return out, err
	}
	out.Dispatches = []wire.TillDispatchSummary{}
	rows, err := tx.Query(ctx, `SELECT k.id::text, k.revision, k.status, k.occurred_at_ms, k.employee_name,
		k.status_changed_at_ms, COALESCE(array_agg(l.id::text ORDER BY l.seq, l.id) FILTER (WHERE l.id IS NOT NULL), '{}'),
		k.payload
		FROM kitchen_dispatches k LEFT JOIN bill_lines l ON l.dispatch_id = k.id
		WHERE k.bill_id = $1
		GROUP BY k.id ORDER BY k.occurred_at_ms, k.id`, id)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		var d wire.TillDispatchSummary
		var status string
		var lines []string
		var payload []byte
		if err := rows.Scan(&d.Id, &d.Revision, &status, &d.OccurredAtMs, &d.EmployeeName, &d.StatusChangedAtMs, &lines, &payload); err != nil {
			return out, err
		}
		d.Status = wire.TillDispatchSummaryStatus(status)
		d.LineIds = lines
		// The batch as accepted, at its current status: whoever holds the
		// bill next repeats it unchanged when it reports kitchen progress.
		var full wire.KitchenDispatch
		if err := json.Unmarshal(payload, &full); err != nil {
			return out, err
		}
		full.Revision, full.Status, full.StatusChangedAtMs = d.Revision, wire.KitchenDispatchStatus(status), d.StatusChangedAtMs
		full.OwnerGeneration = out.Summary.OwnerGeneration
		d.Dispatch = &full
		out.Dispatches = append(out.Dispatches, d)
	}
	return out, rows.Err()
}

// BillDetail is one bill with its lines and dispatches, read-only.
func (s *Service) BillDetail(ctx context.Context, b devices.Binding, token, id string) (wire.TillBillDetail, error) {
	var out wire.TillBillDetail
	id = strings.ToLower(id)
	if !validUUID(id) {
		return out, tillError("bill_not_found")
	}
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		if _, err := billActor(ctx, tx, b, token, true); err != nil {
			return err
		}
		var err error
		out, err = billDetail(ctx, tx, b, id)
		return err
	})
	return out, err
}

// priorEvent returns the event an operation id already produced, so a retried
// park or claim answers what the first attempt did.
func priorEvent(ctx context.Context, tx pgx.Tx, operationID string) (eventType string, billID, seating, device *string, toGeneration *int64, at time.Time, found bool, err error) {
	err = tx.QueryRow(ctx, `SELECT event_type, bill_id::text, table_session_id::text, device_id::text, to_generation, created_at
		FROM bill_events WHERE operation_id = $1`, operationID).Scan(&eventType, &billID, &seating, &device, &toGeneration, &at)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil, nil, nil, nil, at, false, nil
	}
	return eventType, billID, seating, device, toGeneration, at, err == nil, err
}

// ParkBill releases this till's open bill to the server. The server must
// already hold everything the till knows about it — the revision and the
// dispatches — so that whoever claims it next continues from the whole bill.
func (s *Service) ParkBill(ctx context.Context, b devices.Binding, token, id string, in wire.TillBillParkRequest) (wire.TillBillParkData, error) {
	var out wire.TillBillParkData
	id, op := strings.ToLower(id), strings.ToLower(in.OperationId)
	if !validUUID(id) || !validUUID(op) {
		return out, tillError("invalid_operation")
	}
	err := pg.InTenantTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		actor, err := billActor(ctx, tx, b, token, false)
		if err != nil {
			return err
		}
		kind, billID, _, device, generation, at, found, err := priorEvent(ctx, tx, op)
		if err != nil {
			return err
		}
		if found {
			if kind != "park" || billID == nil || *billID != id || device == nil || *device != b.Device.ID || generation == nil {
				return tillError("idempotency_conflict")
			}
			out = wire.TillBillParkData{BillId: id, OwnerGeneration: *generation, ParkedAtMs: at.UnixMilli()}
			return nil
		}
		bill, found, err := lockBill(ctx, tx, id)
		if err != nil {
			return err
		}
		if !found || bill.outletID != b.Outlet.ID {
			return tillError("bill_not_found")
		}
		if bill.ownerDevice == nil || *bill.ownerDevice != b.Device.ID {
			return tillError("bill_not_owned")
		}
		if bill.status != "open" {
			return tillError("bill_closed")
		}
		var dispatches int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM kitchen_dispatches WHERE bill_id = $1`, id).Scan(&dispatches); err != nil {
			return err
		}
		if bill.revision != in.ExpectedRevision || dispatches != in.ExpectedDispatches {
			return tillError("sync_before_handoff")
		}
		now := time.Now()
		next := bill.generation + 1
		if _, err := tx.Exec(ctx, `UPDATE bills SET owner_device_id = NULL, owner_session_id = NULL,
			owner_generation = $2, parked_at = $3, updated_at = $3 WHERE id = $1`, id, next, now); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO bill_events (tenant_id, outlet_id, bill_id, event_type, operation_id,
			device_id, actor_employee_id, actor_name, from_generation, to_generation, created_at)
			VALUES ($1,$2,$3,'park',$4,$5,$6,$7,$8,$9,$10)`,
			b.Tenant.ID, b.Outlet.ID, id, op, b.Device.ID, actor.ID, actor.Name, bill.generation, next, now); err != nil {
			return err
		}
		out = wire.TillBillParkData{BillId: id, OwnerGeneration: next, ParkedAtMs: now.UnixMilli()}
		return nil
	})
	return out, tillDBError(err)
}

// ClaimBill makes this till the owner of a parked bill, under the drawer the
// calling cashier is active on. One of two tills claiming together wins: the
// bill row is locked, and the loser finds it no longer parked.
func (s *Service) ClaimBill(ctx context.Context, b devices.Binding, token, id, operationID string) (wire.TillBillDetail, error) {
	var out wire.TillBillDetail
	id, op := strings.ToLower(id), strings.ToLower(operationID)
	if !validUUID(id) || !validUUID(op) {
		return out, tillError("invalid_operation")
	}
	err := pg.InTenantTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		actor, err := billActor(ctx, tx, b, token, false)
		if err != nil {
			return err
		}
		kind, billID, _, device, _, _, found, err := priorEvent(ctx, tx, op)
		if err != nil {
			return err
		}
		if found {
			if kind != "claim" || billID == nil || *billID != id || device == nil || *device != b.Device.ID {
				return tillError("idempotency_conflict")
			}
			out, err = billDetail(ctx, tx, b, id)
			return err
		}
		var session string
		err = tx.QueryRow(ctx, `SELECT c.session_id::text FROM till_claims c
			JOIN pos_sessions p ON p.id = c.session_id
			WHERE c.device_id = $1 AND c.register_id = $2 AND c.active_employee_id = $3 AND p.closed_at_ms IS NULL`,
			b.Device.ID, b.Register.ID, actor.ID).Scan(&session)
		if errors.Is(err, pgx.ErrNoRows) {
			return tillError("session_required")
		}
		if err != nil {
			return err
		}
		bill, found, err := lockBill(ctx, tx, id)
		if err != nil {
			return err
		}
		if !found || bill.outletID != b.Outlet.ID {
			return tillError("bill_not_found")
		}
		if bill.status != "open" {
			return tillError("bill_closed")
		}
		if bill.ownerDevice != nil {
			return tillError("bill_not_parked")
		}
		next := bill.generation + 1
		if _, err := tx.Exec(ctx, `UPDATE bills SET owner_device_id = $2, owner_session_id = $3,
			owner_generation = $4, parked_at = NULL, updated_at = now() WHERE id = $1`, id, b.Device.ID, session, next); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO bill_events (tenant_id, outlet_id, bill_id, event_type, operation_id,
			device_id, actor_employee_id, actor_name, from_generation, to_generation)
			VALUES ($1,$2,$3,'claim',$4,$5,$6,$7,$8,$9)`,
			b.Tenant.ID, b.Outlet.ID, id, op, b.Device.ID, actor.ID, actor.Name, bill.generation, next); err != nil {
			return err
		}
		out, err = billDetail(ctx, tx, b, id)
		return err
	})
	return out, tillDBError(err)
}

func readTableSession(ctx context.Context, tx pgx.Tx, id string) (wire.TableSession, error) {
	return scanTableSession(tx.QueryRow(ctx, tableSessionSelect+` WHERE s.id = $1`, id))
}

// OpenTableSession seats a table. The seating id is the idempotency key the
// till stores before it asks; the partial unique index on open seatings is what
// decides which of two tills racing for one table wins.
func (s *Service) OpenTableSession(ctx context.Context, b devices.Binding, token string, in wire.TableSessionOpenRequest) (wire.TableSession, error) {
	var out wire.TableSession
	id, table := strings.ToLower(in.Id), strings.ToLower(in.TableId)
	if !validUUID(id) || !validUUID(table) {
		return out, tillError("invalid_operation")
	}
	err := s.feed.Write(ctx, b.Tenant.ID, func(ctx context.Context, w *syncfeed.Writer) error {
		tx := w.Tx
		actor, err := billActor(ctx, tx, b, token, true)
		if err != nil {
			return err
		}
		var existingTable string
		err = tx.QueryRow(ctx, `SELECT table_id::text FROM table_sessions WHERE id = $1`, id).Scan(&existingTable)
		if err == nil {
			if existingTable != table {
				return tillError("idempotency_conflict")
			}
			out, err = readTableSession(ctx, tx, id)
			return err
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		var name string
		var active bool
		err = tx.QueryRow(ctx, `SELECT name, active FROM tables
			WHERE id = $1 AND outlet_id = $2 AND deleted_at IS NULL`, table, b.Outlet.ID).Scan(&name, &active)
		if errors.Is(err, pgx.ErrNoRows) {
			return tillError("table_not_found")
		}
		if err != nil {
			return err
		}
		if !active {
			return tillError("table_inactive")
		}
		now := time.Now().UnixMilli()
		// The status row is locked before the seating is written, the order a
		// legacy status event takes too, so the two cannot interleave.
		if _, err := tables.SetFromSeating(ctx, w, b.Tenant.ID, b.Outlet.ID, table, tables.StatusOccupied, actor.Name, now); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO table_sessions (id, tenant_id, outlet_id, table_id, table_name,
			guest_count, opened_at_ms, opened_by_device_id, opened_by_employee_id, opened_by_name)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
			id, b.Tenant.ID, b.Outlet.ID, table, name, in.GuestCount, now, b.Device.ID, actor.ID, actor.Name); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO bill_events (tenant_id, outlet_id, table_session_id, event_type,
			device_id, actor_employee_id, actor_name) VALUES ($1,$2,$3,'table_open',$4,$5,$6)`,
			b.Tenant.ID, b.Outlet.ID, id, b.Device.ID, actor.ID, actor.Name); err != nil {
			return err
		}
		out, err = readTableSession(ctx, tx, id)
		return err
	})
	var p *pgconn.PgError
	if errors.As(err, &p) && p.Code == "23505" && p.ConstraintName == "table_sessions_one_open" {
		return out, tillError("table_busy")
	}
	return out, tillDBError(err)
}

// CloseTableSession clears a table once none of its seating's bills is still
// open. Paying never does this by itself: the guests may still be seated.
func (s *Service) CloseTableSession(ctx context.Context, b devices.Binding, token, id, operationID string) (wire.TableSession, error) {
	var out wire.TableSession
	id = strings.ToLower(id)
	if !validUUID(id) || !validUUID(strings.ToLower(operationID)) {
		return out, tillError("invalid_operation")
	}
	err := s.feed.Write(ctx, b.Tenant.ID, func(ctx context.Context, w *syncfeed.Writer) error {
		tx := w.Tx
		actor, err := billActor(ctx, tx, b, token, true)
		if err != nil {
			return err
		}
		var table, outlet string
		var closed *int64
		err = tx.QueryRow(ctx, `SELECT table_id::text, outlet_id::text, closed_at_ms FROM table_sessions WHERE id = $1`, id).
			Scan(&table, &outlet, &closed)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && outlet != b.Outlet.ID) {
			return tillError("table_session_not_found")
		}
		if err != nil {
			return err
		}
		if closed != nil {
			out, err = readTableSession(ctx, tx, id)
			return err
		}
		now := time.Now().UnixMilli()
		// Status row, then the seating row, then the counter inside
		// SetFromSeating's numbering — rows before counters.
		if _, err := tx.Exec(ctx, `SELECT 1 FROM table_status WHERE table_id = $1 FOR UPDATE`, table); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT closed_at_ms FROM table_sessions WHERE id = $1 FOR UPDATE`, id).Scan(&closed); err != nil {
			return err
		}
		if closed != nil {
			out, err = readTableSession(ctx, tx, id)
			return err
		}
		var open int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM bills WHERE table_session_id = $1 AND status = 'open'`, id).Scan(&open); err != nil {
			return err
		}
		if open > 0 {
			return tillError("open_bills_remaining")
		}
		if _, err := tx.Exec(ctx, `UPDATE table_sessions SET closed_at_ms = $2, closed_by_device_id = $3,
			closed_by_name = $4 WHERE id = $1`, id, now, b.Device.ID, actor.Name); err != nil {
			return err
		}
		if _, err := tables.SetFromSeating(ctx, w, b.Tenant.ID, b.Outlet.ID, table, tables.StatusAvailable, actor.Name, now); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO bill_events (tenant_id, outlet_id, table_session_id, event_type,
			device_id, actor_employee_id, actor_name) VALUES ($1,$2,$3,'table_close',$4,$5,$6)`,
			b.Tenant.ID, b.Outlet.ID, id, b.Device.ID, actor.ID, actor.Name); err != nil {
			return err
		}
		out, err = readTableSession(ctx, tx, id)
		return err
	})
	return out, tillDBError(err)
}
