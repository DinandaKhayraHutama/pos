package history

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// SessionFilter is one query over drawer sessions.
//
// The period is the OPENING time, not the business date: a drawer is a shift,
// it can run past midnight, and filing it under the day it closed would hide
// the night shift from the day it started.
type SessionFilter struct {
	From, To   time.Time
	OutletID   string
	RegisterID string
	// CashierID matches either the person who opened the drawer or anyone who
	// rang up a sale in it. A handover means the opener is often not who was
	// standing there when the money in question was taken.
	CashierID string
	// Open filters on whether the drawer is still open. Nil is both.
	Open   *bool
	Cursor string
}

func (f SessionFilter) Validate() error {
	errs := validation.Errors{}
	validateRange(errs, f.From, f.To)
	validateUUID(errs, "outlet", f.OutletID)
	validateUUID(errs, "register", f.RegisterID)
	validateUUID(errs, "cashier", f.CashierID)
	return errs.Err()
}

// SessionRow is one drawer as a list shows it.
type SessionRow struct {
	ID           string
	OutletID     string
	OutletName   string
	RegisterID   string
	RegisterName string
	// EmployeeName is the snapshot the till sent when the drawer was opened.
	EmployeeName string
	OpenedAtMs   int64
	ClosedAtMs   *int64
	OpeningCash  int64
	// ExpectedCash and CountedCash are what the till computed and what the
	// person counted, both as the closing snapshot recorded them. They are
	// nil on an open drawer: there is nothing to reconcile yet.
	ExpectedCash *int64
	CountedCash  *int64
	// CloseKind is "normal" or "forced" — a drawer a manager took over.
	CloseKind  string
	RecoveryID string
	OrderCount int64
	// NetSales and Revenue cover the receipts the server holds for this
	// session, sales only. A drawer with receipts still on an offline tablet
	// shows fewer than it eventually will, which is why the screen says the
	// figures are what the server has.
	NetSales  int64
	Revenue   int64
	CashTaken int64
}

func (s SessionRow) Open() bool { return s.ClosedAtMs == nil }

// Difference is counted minus expected, and the second return says whether
// there is one to show. An open drawer has no difference — only a closed one
// has been counted — and rendering a nil as zero would read as "it balanced".
func (s SessionRow) Difference() (int64, bool) {
	if s.CountedCash == nil || s.ExpectedCash == nil {
		return 0, false
	}
	return *s.CountedCash - *s.ExpectedCash, true
}

type SessionPage struct {
	Rows []SessionRow
	Next string
}

// SessionDetail is one drawer with its receipts and what happened to it.
type SessionDetail struct {
	SessionRow
	DeviceID   string
	DeviceUUID string
	// Operators is everyone who was assigned to sell in this drawer, opener
	// and handovers alike.
	Operators []SessionOperator
	Orders    []OrderRow
	// AfterClose are receipts whose own timestamp is later than the closing
	// snapshot — a late upload, or a recovery decision. They are listed
	// SEPARATELY: a closed drawer keeps the numbers it was closed on, and
	// folding these into them would rewrite a count somebody signed.
	AfterClose []OrderRow
	Recovery   *SessionRecovery
}

type SessionOperator struct {
	EmployeeID string
	Name       string
	AssignedAt time.Time
	Active     bool
}

// SessionRecovery is the manager's forced-closure case, when there was one.
type SessionRecovery struct {
	ID                     string
	ActorName              string
	Reason                 string
	ForcedAt               time.Time
	OrderCountAtTakeover   int64
	ExpectedCashAtTakeover int64
	CountedCash            *int64
	Status                 string
	PendingItems           int64
	AcceptedItems          int64
	DiscardedItems         int64
}

const sessionColumns = `
	p.id::text, p.outlet_id::text, ol.name, p.pos_register_id::text, rg.name,
	p.employee_name, p.opened_at_ms, p.closed_at_ms, p.opening_cash,
	p.expected_cash, p.counted_cash, p.close_kind, COALESCE(p.forced_recovery_id::text, ''),
	COALESCE(t.orders, 0), COALESCE(t.net, 0), COALESCE(t.revenue, 0), COALESCE(t.cash, 0)`

// sessionTotals sums the session's receipts once, in a lateral join, rather
// than joining the rows themselves — a join would fan each session out per
// receipt and multiply every column beside it.
const sessionTotals = `
	LEFT JOIN LATERAL (
		SELECT count(*) AS orders, sum(o.subtotal - o.discount) AS net, sum(o.total) AS revenue,
		       COALESCE(sum(o.total) FILTER (WHERE o.payment_method = 'cash'), 0) AS cash
		FROM orders o
		WHERE o.tenant_id = p.tenant_id AND o.pos_session_id = p.id
		  AND o.status NOT IN ('cancelled', 'refunded')
	) t ON true`

const sessionJoins = `
	FROM pos_sessions p
	JOIN outlets ol ON ol.tenant_id = p.tenant_id AND ol.id = p.outlet_id
	JOIN pos_registers rg ON rg.tenant_id = p.tenant_id AND rg.id = p.pos_register_id` + sessionTotals

func scanSessionRow(row pgx.CollectableRow) (SessionRow, error) {
	var s SessionRow
	err := row.Scan(&s.ID, &s.OutletID, &s.OutletName, &s.RegisterID, &s.RegisterName,
		&s.EmployeeName, &s.OpenedAtMs, &s.ClosedAtMs, &s.OpeningCash,
		&s.ExpectedCash, &s.CountedCash, &s.CloseKind, &s.RecoveryID,
		&s.OrderCount, &s.NetSales, &s.Revenue, &s.CashTaken)
	return s, err
}

// Sessions returns one page of drawers, most recently opened first.
func (s *Service) Sessions(ctx context.Context, tenantID string, f SessionFilter) (SessionPage, error) {
	if err := f.Validate(); err != nil {
		return SessionPage{}, err
	}
	opened, id, err := parseSessionCursor(f.Cursor)
	if err != nil {
		return SessionPage{}, err
	}

	// The opening time is compared in the merchant's own day boundaries by
	// taking the whole of the last day: a shift that opened at 23:30 on the
	// last day of the range is inside it.
	from := f.From.UnixMilli()
	to := f.To.AddDate(0, 0, 1).UnixMilli() - 1
	args := []any{tenantID, from, to, emptyToNil(f.OutletID), emptyToNil(f.RegisterID),
		emptyToNil(f.CashierID), f.Open, opened, id, PageSize + 1}

	where := `p.tenant_id = $1
		AND p.opened_at_ms BETWEEN $2::bigint AND $3::bigint
		AND ($4::uuid IS NULL OR p.outlet_id = $4::uuid)
		AND ($5::uuid IS NULL OR p.pos_register_id = $5::uuid)
		AND ($6::uuid IS NULL OR EXISTS (
			SELECT 1 FROM till_operators op WHERE op.session_id = p.id AND op.employee_id = $6::uuid
			UNION ALL
			SELECT 1 FROM orders o
			WHERE o.tenant_id = p.tenant_id AND o.pos_session_id = p.id AND o.payload->>'cashier_id' = $6::text
		))
		AND ($7::boolean IS NULL OR (p.closed_at_ms IS NULL) = $7::boolean)
		AND ($8::bigint IS NULL OR (p.opened_at_ms, p.id) < ($8::bigint, $9::uuid))`

	out := SessionPage{Rows: []SessionRow{}}
	err = pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT`+sessionColumns+sessionJoins+`
			WHERE `+where+`
			ORDER BY p.opened_at_ms DESC, p.id DESC
			LIMIT $10`, args...)
		if err != nil {
			return err
		}
		out.Rows, err = pgx.CollectRows(rows, scanSessionRow)
		return err
	})
	if err != nil {
		return SessionPage{}, err
	}
	if len(out.Rows) > PageSize {
		last := out.Rows[PageSize-1]
		out.Rows = out.Rows[:PageSize]
		out.Next = fmt.Sprintf("%d:%s", last.OpenedAtMs, last.ID)
	}
	return out, nil
}

// Session returns one drawer with everything rung up in it.
func (s *Service) Session(ctx context.Context, tenantID, sessionID string) (SessionDetail, error) {
	if !validation.UUID(sessionID) {
		return SessionDetail{}, ErrNotFound
	}
	var d SessionDetail
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT`+sessionColumns+`, p.device_id::text, COALESCE(dv.device_uuid, '')`+
			sessionJoins+`
			LEFT JOIN devices dv ON dv.tenant_id = p.tenant_id AND dv.id = p.device_id
			WHERE p.tenant_id = $1 AND p.id = $2::uuid`, tenantID, sessionID)
		if err != nil {
			return err
		}
		found, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (SessionDetail, error) {
			var v SessionDetail
			err := row.Scan(&v.ID, &v.OutletID, &v.OutletName, &v.RegisterID, &v.RegisterName,
				&v.EmployeeName, &v.OpenedAtMs, &v.ClosedAtMs, &v.OpeningCash,
				&v.ExpectedCash, &v.CountedCash, &v.CloseKind, &v.RecoveryID,
				&v.OrderCount, &v.NetSales, &v.Revenue, &v.CashTaken, &v.DeviceID, &v.DeviceUUID)
			return v, err
		})
		if err != nil {
			return err
		}
		if len(found) == 0 {
			return ErrNotFound
		}
		d = found[0]

		if d.Operators, err = sessionOperators(ctx, tx, sessionID); err != nil {
			return err
		}
		// Every receipt of the session, without a date range: a shift that ran
		// past midnight owns receipts on two business dates, and bounding this
		// by one of them would drop half of them off the page.
		rows, err = tx.Query(ctx, `SELECT`+orderColumns+orderJoins+`
			WHERE o.tenant_id = $1 AND o.pos_session_id = $2::uuid
			ORDER BY o.placed_at_ms DESC, o.id DESC
			LIMIT $3`, tenantID, sessionID, PageSize)
		if err != nil {
			return err
		}
		all, err := pgx.CollectRows(rows, scanOrderRow)
		if err != nil {
			return err
		}
		d.Orders, d.AfterClose = splitAtClose(all, d.ClosedAtMs)
		d.Recovery, err = sessionRecovery(ctx, tx, tenantID, sessionID)
		return err
	})
	return d, err
}

// splitAtClose separates the receipts the closing snapshot could have seen
// from the ones that arrived with a later timestamp.
func splitAtClose(all []OrderRow, closedAtMs *int64) (during, after []OrderRow) {
	during, after = []OrderRow{}, []OrderRow{}
	for _, o := range all {
		if closedAtMs != nil && o.PlacedAtMs > *closedAtMs {
			after = append(after, o)
			continue
		}
		during = append(during, o)
	}
	return during, after
}

func sessionOperators(ctx context.Context, tx pgx.Tx, sessionID string) ([]SessionOperator, error) {
	rows, err := tx.Query(ctx, `
		SELECT op.employee_id::text, e.name, op.assigned_at,
		       EXISTS (SELECT 1 FROM till_claims c WHERE c.session_id = op.session_id AND c.active_employee_id = op.employee_id)
		FROM till_operators op
		JOIN employees e ON e.tenant_id = op.tenant_id AND e.id = op.employee_id
		WHERE op.session_id = $1::uuid
		ORDER BY op.assigned_at, op.employee_id`, sessionID)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (SessionOperator, error) {
		var o SessionOperator
		err := row.Scan(&o.EmployeeID, &o.Name, &o.AssignedAt, &o.Active)
		return o, err
	})
	if out == nil {
		out = []SessionOperator{}
	}
	return out, err
}

func sessionRecovery(ctx context.Context, tx pgx.Tx, tenantID, sessionID string) (*SessionRecovery, error) {
	rows, err := tx.Query(ctx, `
		SELECT r.id::text, r.actor_name, r.reason, r.forced_at,
		       r.order_count_at_takeover, r.expected_cash_at_takeover, r.counted_cash, r.status,
		       count(i.id) FILTER (WHERE i.status = 'pending'),
		       count(i.id) FILTER (WHERE i.status = 'accepted'),
		       count(i.id) FILTER (WHERE i.status = 'discarded')
		FROM till_recoveries r
		LEFT JOIN till_recovery_items i ON i.tenant_id = r.tenant_id AND i.recovery_id = r.id
		WHERE r.tenant_id = $1 AND r.session_id = $2::uuid
		GROUP BY r.id, r.actor_name, r.reason, r.forced_at, r.order_count_at_takeover,
		         r.expected_cash_at_takeover, r.counted_cash, r.status`, tenantID, sessionID)
	if err != nil {
		return nil, err
	}
	found, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (SessionRecovery, error) {
		var r SessionRecovery
		err := row.Scan(&r.ID, &r.ActorName, &r.Reason, &r.ForcedAt, &r.OrderCountAtTakeover,
			&r.ExpectedCashAtTakeover, &r.CountedCash, &r.Status,
			&r.PendingItems, &r.AcceptedItems, &r.DiscardedItems)
		return r, err
	})
	if err != nil || len(found) == 0 {
		return nil, err
	}
	return &found[0], nil
}

func parseSessionCursor(cursor string) (*int64, *string, error) {
	if cursor == "" {
		return nil, nil, nil
	}
	ms, id, ok := strings.Cut(cursor, ":")
	if !ok || !validation.UUID(id) {
		return nil, nil, validation.Errors{"cursor": "Halaman tidak dikenal. Muat ulang daftar."}
	}
	opened, err := strconv.ParseInt(ms, 10, 64)
	if err != nil || opened < 0 {
		return nil, nil, validation.Errors{"cursor": "Halaman tidak dikenal. Muat ulang daftar."}
	}
	return &opened, &id, nil
}
