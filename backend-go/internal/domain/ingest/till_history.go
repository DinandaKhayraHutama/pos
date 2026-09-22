package ingest

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

const (
	// HistoryScopeRegister is the till in front of the person, and the
	// default. Widening to the whole branch needs viewAllOrders.
	HistoryScopeRegister = "register"
	HistoryScopeOutlet   = "outlet"
	// HistoryMaxDays bounds one query, matching a report's own limit.
	HistoryMaxDays = 366
	// HistoryPageSize is one page, unchanged from the original contract.
	HistoryPageSize = 100
	// HistoryStatusSales is every receipt that was not undone — the group
	// people mean by "penjualan", as opposed to one kitchen status.
	HistoryStatusSales = "sales"
)

// HistoryPage is one page of receipts.
//
// Scope, From and To echo what the server ACTUALLY applied. A till that asked
// for something it may not have needs to say so on the screen: a cashier who
// asked for the whole branch and is shown their own register, with no label,
// reads it as the branch having sold very little.
type HistoryPage struct {
	Rows         []json.RawMessage `json:"rows"`
	Next         string            `json:"next"`
	ServerTimeMs int64             `json:"server_time_ms"`
	Scope        string            `json:"scope"`
	From         string            `json:"from"`
	To           string            `json:"to"`
}

// HistoryQuery is one page request from a till.
//
// Day and Before are the original contract and still work exactly as they did.
// Everything else is additive, so a till that knows none of it behaves as
// before.
type HistoryQuery struct {
	// Day is the single business date of the original contract.
	Day string
	// From and To are the additive range. Combining either with Day is
	// refused rather than resolved: the two say different things about which
	// days are wanted, and picking one silently hands somebody a period they
	// did not ask for.
	From, To string
	// Scope is HistoryScopeRegister (the default) or HistoryScopeOutlet.
	Scope string
	// Status is one order status, or HistoryStatusSales.
	Status string
	// Receipt is a prefix of the printed number.
	Receipt string
	// CashierID narrows to one person. A cashier may only name themselves.
	CashierID string
	Before    string
}

// resolveHistory decides the range, scope and cashier this actor may actually
// have, and REFUSES rather than narrowing where the difference would mislead.
//
// The rule it enforces is the one the endpoint rests on: a cashier sees their
// own receipts, on the current business day, on the register in front of them.
// Anything wider is resolved from the employee the cashier token names, never
// from a query parameter — the query string is written by the client, and the
// client is the thing being scoped.
func resolveHistory(q HistoryQuery, actor tillActor, today string) (HistoryQuery, error) {
	out := q
	hasRange := q.From != "" || q.To != ""
	if q.Day != "" && hasRange {
		return out, tillError("ambiguous_range")
	}

	switch {
	case q.Day != "":
		if _, err := time.Parse(time.DateOnly, q.Day); err != nil {
			return out, tillError("invalid_date")
		}
		out.From, out.To = q.Day, q.Day
	case hasRange:
		from, errFrom := time.Parse(time.DateOnly, q.From)
		to, errTo := time.Parse(time.DateOnly, q.To)
		if errFrom != nil || errTo != nil || to.Before(from) {
			return out, tillError("invalid_date")
		}
		if int(to.Sub(from).Hours()/24) >= HistoryMaxDays {
			return out, tillError("range_too_wide")
		}
	default:
		// No period at all is the current business day, which is what a till
		// asks for on every ordinary refresh.
		out.From, out.To = today, today
	}

	switch out.Scope {
	case "", HistoryScopeRegister:
		out.Scope = HistoryScopeRegister
	case HistoryScopeOutlet:
	default:
		return out, tillError("invalid_scope")
	}

	if q.Status != "" && !knownHistoryStatus(q.Status) {
		return out, tillError("invalid_status")
	}
	if len(q.Receipt) > 64 {
		return out, tillError("invalid_receipt")
	}
	if q.CashierID != "" && !validUUID(q.CashierID) {
		return out, tillError("invalid_cashier")
	}

	if actor.Role != "cashier" {
		return out, nil
	}
	// A cashier's three limits. Refused, not quietly narrowed: asking for a
	// colleague's sales and being handed your own looks like the colleague
	// sold nothing, which is a worse answer than "you may not".
	if out.Scope != HistoryScopeRegister {
		return out, tillError("forbidden_scope")
	}
	if out.CashierID != "" && out.CashierID != actor.ID {
		return out, tillError("forbidden_cashier")
	}
	if out.From != today || out.To != today {
		return out, tillError("forbidden_range")
	}
	out.CashierID = actor.ID
	return out, nil
}

func knownHistoryStatus(status string) bool {
	switch status {
	case HistoryStatusSales, "pending", "preparing", "ready", "served", "paid", "cancelled", "refunded":
		return true
	}
	return false
}

// historySQL is one statement for both scopes. The register filter is a NULL
// check rather than a branch in Go: one plan, and no chance of the
// outlet-scope path forgetting a predicate the register path applies.
const historySQL = `
	SELECT business_date, placed_at_ms, id::text,
	       payload || jsonb_build_object('outlet_id', outlet_id, 'pos_id', pos_register_id, 'source_device_id', device_id)
	FROM orders
	WHERE tenant_id = $1 AND outlet_id = $2
	  AND business_date BETWEEN $3::date AND $4::date
	  AND ($5::uuid IS NULL OR pos_register_id = $5::uuid)
	  AND ($6::text IS NULL OR payload->>'cashier_id' = $6::text)
	  AND ($7::text IS NULL OR CASE WHEN $7::text = 'sales'
	                                THEN status NOT IN ('cancelled', 'refunded')
	                                ELSE status = $7::text END)
	  AND ($8::text IS NULL OR upper(payload->>'number') LIKE upper($8::text) || '%')
	  AND ($9::date IS NULL OR (business_date, placed_at_ms, id) < ($9::date, $10::bigint, $11::uuid))
	ORDER BY business_date DESC, placed_at_ms DESC, id DESC
	LIMIT $12`

// TillHistory returns one page of receipts for this till's scope.
func (s *Service) TillHistory(ctx context.Context, b devices.Binding, token string, q HistoryQuery) (HistoryPage, error) {
	out := HistoryPage{Rows: []json.RawMessage{}, ServerTimeMs: time.Now().UnixMilli()}
	// The cursor carries the sort key, not just the id: receipts are ordered by
	// when they were rung up, and a v4 UUID orders at random. Paging by id
	// alone was stable but meaningless — page two held whatever the shuffle put
	// there, not the next oldest sale. The client treats this as opaque.
	cursorDate, cursorMs, cursorID, err := parseHistoryCursor(q.Before)
	if err != nil {
		return out, err
	}

	err = pg.InTenantReadTx(ctx, s.pools.Tenant, b.Tenant.ID, func(ctx context.Context, tx pgx.Tx) error {
		actor, err := tillEmployee(ctx, tx, b, token)
		if err != nil {
			return err
		}
		today, err := tenantToday(ctx, tx, b.Tenant.ID)
		if err != nil {
			return err
		}
		resolved, err := resolveHistory(q, actor, today)
		if err != nil {
			return err
		}
		out.Scope, out.From, out.To = resolved.Scope, resolved.From, resolved.To

		register := &b.Register.ID
		if resolved.Scope == HistoryScopeOutlet {
			register = nil
		}
		rows, err := tx.Query(ctx, historySQL,
			b.Tenant.ID, b.Outlet.ID, resolved.From, resolved.To, register,
			nilIfBlank(resolved.CashierID), nilIfBlank(resolved.Status), nilIfBlank(resolved.Receipt),
			cursorDate, cursorMs, cursorID, HistoryPageSize+1)
		if err != nil {
			return err
		}
		defer rows.Close()

		type marker struct {
			date time.Time
			ms   int64
			id   string
		}
		var markers []marker
		for rows.Next() {
			var (
				date time.Time
				ms   int64
				id   string
				raw  []byte
			)
			if err = rows.Scan(&date, &ms, &id, &raw); err != nil {
				return err
			}
			markers = append(markers, marker{date: date, ms: ms, id: id})
			out.Rows = append(out.Rows, json.RawMessage(raw))
		}
		if err = rows.Err(); err != nil {
			return err
		}
		// One row past the page is how the server knows there is a next one,
		// without counting the range on every scroll.
		if len(out.Rows) > HistoryPageSize {
			out.Rows = out.Rows[:HistoryPageSize]
			last := markers[HistoryPageSize-1]
			out.Next = fmt.Sprintf("%s:%d:%s", last.date.Format(time.DateOnly), last.ms, last.id)
		}
		return nil
	})
	return out, err
}

func nilIfBlank(v string) *string {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	return &v
}

// tenantToday is the merchant's current calendar date. A cashier's "today" has
// to be the merchant's rather than the server's: a till in Jakarta at 00:30 is
// still working the day a UTC server already calls yesterday.
func tenantToday(ctx context.Context, tx pgx.Tx, tenantID string) (string, error) {
	var day time.Time
	err := tx.QueryRow(ctx,
		`SELECT (now() AT TIME ZONE t.timezone)::date FROM tenants t WHERE t.id = $1`, tenantID).Scan(&day)
	return day.Format(time.DateOnly), err
}

// parseHistoryCursor reads what a previous page handed back. Empty means the
// first page; anything else must be exactly what this server produced, so a
// hand-edited cursor cannot widen the scan or smuggle SQL through a type.
//
// The business date now leads the key, because a page can span days. A cursor
// minted by the old single-day contract has no date in it and is refused
// rather than guessed at — the client starts again at the first page, which
// costs one request and cannot silently skip a day.
func parseHistoryCursor(before string) (date *string, placedAtMs *int64, id *string, err error) {
	if before == "" {
		return nil, nil, nil, nil
	}
	parts := strings.SplitN(before, ":", 3)
	if len(parts) != 3 || !validUUID(parts[2]) {
		return nil, nil, nil, tillError("invalid_cursor")
	}
	if _, err := time.Parse(time.DateOnly, parts[0]); err != nil {
		return nil, nil, nil, tillError("invalid_cursor")
	}
	placed, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || placed < 0 {
		return nil, nil, nil, tillError("invalid_cursor")
	}
	return &parts[0], &placed, &parts[2], nil
}
