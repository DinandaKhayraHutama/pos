package history

// Saved bills (Fase 4 paritas), read back for the Backoffice. Read-only like
// the rest of this package: a bill is edited on the till that owns it, and the
// only way it changes hands is park/claim on the tills or a manager's takeover
// in Perangkat — never a button here.
//
// An open bill is not revenue. The list says how much is open (the lines'
// subtotal before any tax or discount) as operational backlog, beside the
// sales reports, never inside them.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// Bill statuses a list can ask for. Empty means open, which is what somebody
// opening this screen in the middle of service needs to see.
const (
	BillsOpen      = "open"
	BillsClosed    = "closed"
	BillsCancelled = "cancelled"
	BillsAll       = "all"
)

type BillFilter struct {
	// From/To bound the day a bill was opened, and apply only when looking
	// past the open ones: an open bill from last night is exactly what a
	// manager must not miss.
	From, To time.Time
	OutletID string
	Status   string
	Cursor   string
}

func (f BillFilter) Validate() error {
	errs := validation.Errors{}
	if f.Status != "" && f.Status != BillsOpen && f.Status != BillsClosed && f.Status != BillsCancelled && f.Status != BillsAll {
		errs.Add("status", "Status tidak dikenal.")
	}
	if f.Status != "" && f.Status != BillsOpen {
		validateRange(errs, f.From, f.To)
	}
	validateUUID(errs, "outlet", f.OutletID)
	return errs.Err()
}

type BillRow struct {
	ID           string
	Number       string
	Status       string
	OutletName   string
	RegisterName string
	// OwnerRegister is the till that owns it now, empty while parked.
	OwnerRegister string
	Parked        bool
	TableName     string
	CustomerName  string
	Subtotal      int64
	LineCount     int
	OpenedAtMs    int64
	UpdatedAtMs   int64
	// Dispatches counts the bill's kitchen batches by status.
	Queued, Preparing, Ready, Served, CancelledDispatches int
	ClosedOrderID string
}

type BillPage struct {
	Rows []BillRow
	Next string
	// OpenCount and OpenSubtotal describe every open bill the filter's outlet
	// holds, whatever page this is: the backlog, not revenue.
	OpenCount    int
	OpenSubtotal int64
}

const billColumns = `
	b.id::text, b.number, b.status, ol.name, rg.name, COALESCE(orr.name, ''), b.owner_device_id IS NULL,
	COALESCE(b.table_name, ''), COALESCE(b.customer_name, ''), b.subtotal, b.line_count, b.opened_at_ms,
	(EXTRACT(EPOCH FROM b.updated_at) * 1000)::bigint,
	count(k.id) FILTER (WHERE k.status = 'queued'), count(k.id) FILTER (WHERE k.status = 'preparing'),
	count(k.id) FILTER (WHERE k.status = 'ready'), count(k.id) FILTER (WHERE k.status = 'served'),
	count(k.id) FILTER (WHERE k.status = 'cancelled'), COALESCE(b.closed_order_id::text, '')`

const billJoins = `
	FROM bills b
	JOIN outlets ol ON ol.tenant_id = b.tenant_id AND ol.id = b.outlet_id
	JOIN pos_registers rg ON rg.tenant_id = b.tenant_id AND rg.id = b.pos_register_id
	LEFT JOIN devices od ON od.tenant_id = b.tenant_id AND od.id = b.owner_device_id
	LEFT JOIN pos_registers orr ON orr.tenant_id = od.tenant_id AND orr.id = od.pos_register_id
	LEFT JOIN kitchen_dispatches k ON k.tenant_id = b.tenant_id AND k.bill_id = b.id`

func scanBillRow(row pgx.CollectableRow) (BillRow, error) {
	var r BillRow
	err := row.Scan(&r.ID, &r.Number, &r.Status, &r.OutletName, &r.RegisterName, &r.OwnerRegister, &r.Parked,
		&r.TableName, &r.CustomerName, &r.Subtotal, &r.LineCount, &r.OpenedAtMs, &r.UpdatedAtMs,
		&r.Queued, &r.Preparing, &r.Ready, &r.Served, &r.CancelledDispatches, &r.ClosedOrderID)
	return r, err
}

func billCursor(r BillRow) string { return fmt.Sprintf("%d:%s", r.OpenedAtMs, r.ID) }

func parseBillCursor(s string) (int64, string, error) {
	ms, id, ok := strings.Cut(s, ":")
	n, err := strconv.ParseInt(ms, 10, 64)
	if !ok || err != nil || !validation.UUID(id) {
		return 0, "", validation.Errors{"cursor": "Halaman tidak dikenal. Muat ulang daftar."}
	}
	return n, id, nil
}

// Bills lists bills newest-opened first, keyset-paged.
func (s *Service) Bills(ctx context.Context, tenantID string, f BillFilter) (BillPage, error) {
	if f.Status == "" {
		f.Status = BillsOpen
	}
	if err := f.Validate(); err != nil {
		return BillPage{}, err
	}
	var out BillPage
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		where := []string{"b.tenant_id = $1"}
		args := []any{tenantID}
		add := func(clause string, v any) {
			args = append(args, v)
			where = append(where, strings.ReplaceAll(clause, "?", "$"+strconv.Itoa(len(args))))
		}
		if f.OutletID != "" {
			add("b.outlet_id = ?::uuid", f.OutletID)
		}
		if f.Status != BillsAll {
			add("b.status = ?", f.Status)
		}
		if f.Status != BillsOpen {
			add("b.created_at >= ?", f.From)
			add("b.created_at < ?", f.To.AddDate(0, 0, 1))
		}
		if f.Cursor != "" {
			ms, id, err := parseBillCursor(f.Cursor)
			if err != nil {
				return err
			}
			args = append(args, ms, id)
			n := len(args)
			where = append(where, fmt.Sprintf("(b.opened_at_ms, b.id) < ($%d, $%d::uuid)", n-1, n))
		}
		args = append(args, PageSize+1)
		rows, err := tx.Query(ctx, `SELECT`+billColumns+billJoins+`
			WHERE `+strings.Join(where, " AND ")+`
			GROUP BY b.id, ol.name, rg.name, orr.name
			ORDER BY b.opened_at_ms DESC, b.id DESC
			LIMIT $`+strconv.Itoa(len(args)), args...)
		if err != nil {
			return err
		}
		out.Rows, err = pgx.CollectRows(rows, scanBillRow)
		if err != nil {
			return err
		}
		if len(out.Rows) > PageSize {
			out.Rows = out.Rows[:PageSize]
			out.Next = billCursor(out.Rows[PageSize-1])
		}
		backlog := `SELECT count(*), COALESCE(sum(subtotal), 0) FROM bills WHERE tenant_id = $1 AND status = 'open'`
		backlogArgs := []any{tenantID}
		if f.OutletID != "" {
			backlog += ` AND outlet_id = $2::uuid`
			backlogArgs = append(backlogArgs, f.OutletID)
		}
		return tx.QueryRow(ctx, backlog, backlogArgs...).Scan(&out.OpenCount, &out.OpenSubtotal)
	})
	return out, err
}

type BillLineRow struct {
	ID        string
	Name      string
	Variant   string
	Modifiers string
	Note      string
	Quantity  int64
	UnitPrice int64
	Custom    bool
	// DispatchID is empty while the line has not reached the kitchen.
	DispatchID string
}

type DispatchRow struct {
	ID           string
	Status       string
	EmployeeName string
	OccurredAtMs int64
	ChangedAtMs  int64
	LineCount    int
}

type BillEventRow struct {
	Type      string
	ActorName string
	Device    string
	AtMs      int64
	FromGen   *int64
	ToGen     *int64
}

type BillDetail struct {
	BillRow
	OwnerGeneration int64
	Revision        int64
	ServedBy        string
	CreatedBy       string
	Note            string
	CancelReason    string
	CancelledBy     string
	ClosedNumber    string
	ClosedDate      string
	Lines           []BillLineRow
	Dispatches      []DispatchRow
	Events          []BillEventRow
}

// Bill is one bill with what the kitchen received and every change of hands.
func (s *Service) Bill(ctx context.Context, tenantID, id string) (BillDetail, error) {
	if !validation.UUID(id) {
		return BillDetail{}, ErrNotFound
	}
	var d BillDetail
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT`+billColumns+billJoins+`
			WHERE b.tenant_id = $1 AND b.id = $2::uuid
			GROUP BY b.id, ol.name, rg.name, orr.name`, tenantID, id)
		if err != nil {
			return err
		}
		found, err := pgx.CollectRows(rows, scanBillRow)
		if err != nil {
			return err
		}
		if len(found) == 0 {
			return ErrNotFound
		}
		d.BillRow = found[0]
		var payload []byte
		var closedDate *time.Time
		if err := tx.QueryRow(ctx, `SELECT owner_generation, revision, payload, closed_business_date FROM bills WHERE id = $1`, id).
			Scan(&d.OwnerGeneration, &d.Revision, &payload, &closedDate); err != nil {
			return err
		}
		var snap struct {
			ServedByName  *string `json:"served_by_name"`
			CreatedByName string  `json:"created_by_name"`
			Note          *string `json:"note"`
			Cancel        *struct {
				Reason       string `json:"reason"`
				AuthorizedBy string `json:"authorized_by"`
			} `json:"cancel"`
		}
		if json.Unmarshal(payload, &snap) == nil {
			d.ServedBy, d.CreatedBy = deref(snap.ServedByName), snap.CreatedByName
			d.Note = deref(snap.Note)
			if snap.Cancel != nil {
				d.CancelReason, d.CancelledBy = snap.Cancel.Reason, snap.Cancel.AuthorizedBy
			}
		}
		if d.ClosedOrderID != "" && closedDate != nil {
			d.ClosedDate = closedDate.Format(time.DateOnly)
			err := tx.QueryRow(ctx, `SELECT COALESCE(payload->>'number', '') FROM orders
				WHERE business_date = $1 AND id = $2::uuid`, *closedDate, d.ClosedOrderID).Scan(&d.ClosedNumber)
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
		}

		lines, err := tx.Query(ctx, `SELECT id::text, payload, COALESCE(dispatch_id::text, '') FROM bill_lines
			WHERE bill_id = $1 ORDER BY seq, id`, id)
		if err != nil {
			return err
		}
		d.Lines, err = pgx.CollectRows(lines, func(row pgx.CollectableRow) (BillLineRow, error) {
			var l BillLineRow
			var raw []byte
			if err := row.Scan(&l.ID, &raw, &l.DispatchID); err != nil {
				return l, err
			}
			var v struct {
				ProductName string  `json:"product_name"`
				VariantName *string `json:"variant_name"`
				Note        *string `json:"note"`
				Quantity    int64   `json:"quantity"`
				UnitPrice   int64   `json:"unit_price"`
				Custom      bool    `json:"custom"`
				Modifiers   []struct {
					OptionName string `json:"option_name"`
				} `json:"modifiers"`
			}
			if json.Unmarshal(raw, &v) == nil {
				l.Name, l.Variant, l.Note = v.ProductName, deref(v.VariantName), deref(v.Note)
				l.Quantity, l.UnitPrice, l.Custom = v.Quantity, v.UnitPrice, v.Custom
				names := make([]string, 0, len(v.Modifiers))
				for _, m := range v.Modifiers {
					names = append(names, m.OptionName)
				}
				l.Modifiers = strings.Join(names, ", ")
			}
			return l, nil
		})
		if err != nil {
			return err
		}

		dispatches, err := tx.Query(ctx, `SELECT k.id::text, k.status, k.employee_name, k.occurred_at_ms, k.status_changed_at_ms,
			(SELECT count(*) FROM bill_lines l WHERE l.dispatch_id = k.id)::int
			FROM kitchen_dispatches k WHERE k.bill_id = $1 ORDER BY k.occurred_at_ms, k.id`, id)
		if err != nil {
			return err
		}
		d.Dispatches, err = pgx.CollectRows(dispatches, func(row pgx.CollectableRow) (DispatchRow, error) {
			var r DispatchRow
			err := row.Scan(&r.ID, &r.Status, &r.EmployeeName, &r.OccurredAtMs, &r.ChangedAtMs, &r.LineCount)
			return r, err
		})
		if err != nil {
			return err
		}

		events, err := tx.Query(ctx, `SELECT e.event_type, e.actor_name, COALESCE(r.name, ''),
			(EXTRACT(EPOCH FROM e.created_at) * 1000)::bigint, e.from_generation, e.to_generation
			FROM bill_events e
			LEFT JOIN devices d ON d.tenant_id = e.tenant_id AND d.id = e.device_id
			LEFT JOIN pos_registers r ON r.tenant_id = d.tenant_id AND r.id = d.pos_register_id
			WHERE e.bill_id = $1 ORDER BY e.created_at, e.id`, id)
		if err != nil {
			return err
		}
		d.Events, err = pgx.CollectRows(events, func(row pgx.CollectableRow) (BillEventRow, error) {
			var r BillEventRow
			err := row.Scan(&r.Type, &r.ActorName, &r.Device, &r.AtMs, &r.FromGen, &r.ToGen)
			return r, err
		})
		return err
	})
	return d, err
}

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
