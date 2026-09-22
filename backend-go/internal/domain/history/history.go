// Package history reads receipts and drawer sessions back out.
//
// It is READ ONLY, and that is a design decision rather than a stage of work.
// A receipt is immutable once the till has printed it; a closed session keeps
// the snapshot it was closed on. Correcting either happens on the till, where
// the person and the cash drawer are, and leaves its own audit. So nothing in
// this package writes, and the Backoffice screens over it offer no void and no
// refund — a panel that could quietly undo a sale four branches away is a
// different product with different controls.
//
// Three rules shape the queries:
//
//   - **Paging is keyset, never OFFSET.** A list people scroll while tills are
//     still selling would otherwise repeat and skip rows: every insert ahead of
//     the offset shifts the window. The cursor carries the full sort key —
//     business date, the millisecond it was rung up, and the UUID — because a
//     v4 UUID orders at random and a timestamp alone is not unique.
//   - **A cursor is bound to the filter it was issued for.** It is a position
//     in one ordering, and handing it to a different one silently pages through
//     a list nobody asked for. Changing a filter resets to the first page.
//   - **Snapshots win in a detail, ids win in a filter.** The receipt shows
//     what it was printed with, so renaming a product does not reword a sale
//     from last year; the filters match on the ids, so a rename does not split
//     one cashier's history in two.
package history

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

var ErrNotFound = errors.New("history: no such transaction or session")

const (
	// PageSize is how many rows one page holds. One hundred is what the till
	// history already uses, and a Backoffice table longer than that is a
	// spreadsheet someone should have exported.
	PageSize = 100
	// MaxRangeDays bounds one query, like a report.
	MaxRangeDays = 366
)

// Status groups are what people actually ask for. "Penjualan" is the money
// that counted; the two undone groups are separate because striking out a
// mis-key and giving a customer their money back are different problems.
const (
	GroupSales     = "sales"
	GroupCancelled = "cancelled"
	GroupRefunded  = "refunded"
)

// Service reads history for one merchant at a time, through the tenant-scoped
// credential — so a filter naming another merchant's outlet finds nothing
// rather than being refused, which is the same answer row-level security gives.
type Service struct {
	pools pg.Pools
}

func New(pools pg.Pools) *Service { return &Service{pools: pools} }

// OrderFilter is one query over receipts. Empty fields are "no constraint".
type OrderFilter struct {
	From, To time.Time
	OutletID string
	// RegisterID narrows to one till in that branch.
	RegisterID string
	// CashierID matches the id the receipt recorded, not the name: a renamed
	// employee must not split into two histories.
	CashierID string
	// Receipt matches the printed number, case-insensitively and from the
	// start, so a half-remembered number still finds the sale.
	Receipt string
	// Group is one of the three above, a single order status, or empty.
	Group string
	// Cursor is what the previous page returned. It is opaque to the caller.
	Cursor string
}

func (f OrderFilter) Validate() error {
	errs := validation.Errors{}
	validateRange(errs, f.From, f.To)
	validateUUID(errs, "outlet", f.OutletID)
	validateUUID(errs, "register", f.RegisterID)
	validateUUID(errs, "cashier", f.CashierID)
	if len(f.Receipt) > 64 {
		errs.Add("receipt", "Nomor struk terlalu panjang.")
	}
	if f.Group != "" && !knownGroup(f.Group) {
		errs.Add("status", "Status tidak dikenal.")
	}
	return errs.Err()
}

func knownGroup(group string) bool {
	switch group {
	case GroupSales, GroupCancelled, GroupRefunded,
		"pending", "preparing", "ready", "served", "paid":
		return true
	}
	return false
}

func validateRange(errs validation.Errors, from, to time.Time) {
	if from.IsZero() {
		errs.Add("from", "Pilih tanggal awal.")
	}
	if to.IsZero() {
		errs.Add("to", "Pilih tanggal akhir.")
	}
	if from.IsZero() || to.IsZero() {
		return
	}
	switch {
	case to.Before(from):
		errs.Add("to", "Tanggal akhir tidak boleh sebelum tanggal awal.")
	case int(to.Sub(from).Hours()/24) >= MaxRangeDays:
		errs.Add("to", fmt.Sprintf("Rentang maksimal %d hari.", MaxRangeDays))
	}
}

func validateUUID(errs validation.Errors, field, value string) {
	if value != "" && !validation.UUID(value) {
		errs.Add(field, "Pilihan tidak dikenal.")
	}
}

// OrderRow is one receipt as a list shows it.
type OrderRow struct {
	ID           string
	Number       string
	BusinessDate time.Time
	PlacedAtMs   int64
	Status       string
	Type         string
	OutletID     string
	OutletName   string
	RegisterID   string
	RegisterName string
	CashierID    string
	CashierName  string

	Subtotal      int64
	Discount      int64
	Tax           int64
	ServiceCharge int64
	Total         int64
	// NetSales is the sale this receipt represents: subtotal less its own
	// discount, before tax and service charge. It is what a report counts, so
	// a list and a report never disagree about one receipt.
	NetSales       int64
	AmountPaid     int64
	PaymentMethod  string
	RefundedAmount *int64
	AuthorizedBy   string
	VoidReason     string
	// RecoveryID is set when this receipt reached the server through a
	// manager's recovery decision rather than an ordinary upload.
	RecoveryID string
}

// Group says which of the three buckets a row belongs to.
func (o OrderRow) Group() string {
	switch o.Status {
	case GroupCancelled, GroupRefunded:
		return o.Status
	}
	return GroupSales
}

// OrderPage is one page and the cursor for the next, empty at the end.
type OrderPage struct {
	Rows []OrderRow
	Next string
	// Totals are for the ROWS ON THIS PAGE, and the field names say so. A
	// running total over a keyset page is the one number people read as the
	// period's total, so the screen labels it per page and the report stays
	// the authority on a period.
	PageNetSales int64
	PageTotal    int64
}

// OrderItemRow is one line of a receipt, with the modifiers it was sold with.
type OrderItemRow struct {
	ID           string
	ProductID    string
	ProductName  string
	VariantName  string
	CategoryName string
	Note         string
	UnitPrice    int64
	Quantity     int64
	LineTotal    int64
	Modifiers    []OrderModifierRow
}

type OrderModifierRow struct {
	GroupName  string
	OptionName string
	PriceDelta int64
}

// OrderDetail is one receipt in full.
type OrderDetail struct {
	OrderRow
	SessionID    string
	DeviceID     string
	DeviceUUID   string
	TableName    string
	CustomerName string
	Note         string
	PromoName    string
	Items        []OrderItemRow
	// SettledAt is when the cancellation or refund was recorded on the server.
	// The till does not record WHO pressed it beyond AuthorizedBy, and a time
	// it never sent is not invented here.
	SettledAt *time.Time
	Revision  int64
}

// orderColumns is the shared projection. The snapshot names come out of the
// payload the till sent; the register name is joined, because a till's name is
// operational rather than part of the receipt.
const orderColumns = `
	o.id::text, COALESCE(o.payload->>'number', ''), o.business_date, o.placed_at_ms, o.status,
	COALESCE(o.payload->>'type', ''), o.outlet_id::text,
	COALESCE(NULLIF(o.payload->>'outlet_name', ''), ol.name),
	o.pos_register_id::text, COALESCE(NULLIF(o.payload->>'pos_name', ''), rg.name),
	COALESCE(o.payload->>'cashier_id', ''), o.cashier_name,
	o.subtotal, o.discount, o.tax, o.service_charge_amount, o.total, o.subtotal - o.discount,
	o.amount_paid, o.payment_method, o.refunded_amount,
	COALESCE(o.authorized_by, ''), COALESCE(o.void_reason, ''),
	COALESCE(rec.recovery_id::text, '')`

const orderJoins = `
	FROM orders o
	JOIN outlets ol ON ol.tenant_id = o.tenant_id AND ol.id = o.outlet_id
	JOIN pos_registers rg ON rg.tenant_id = o.tenant_id AND rg.id = o.pos_register_id
	LEFT JOIN till_recovery_items rec
		ON rec.tenant_id = o.tenant_id AND rec.entity = 'orders' AND rec.entity_id = o.id
		AND rec.status = 'accepted'`

func scanOrderRow(row pgx.CollectableRow) (OrderRow, error) {
	var o OrderRow
	err := row.Scan(&o.ID, &o.Number, &o.BusinessDate, &o.PlacedAtMs, &o.Status, &o.Type,
		&o.OutletID, &o.OutletName, &o.RegisterID, &o.RegisterName, &o.CashierID, &o.CashierName,
		&o.Subtotal, &o.Discount, &o.Tax, &o.ServiceCharge, &o.Total, &o.NetSales,
		&o.AmountPaid, &o.PaymentMethod, &o.RefundedAmount, &o.AuthorizedBy, &o.VoidReason, &o.RecoveryID)
	return o, err
}

// Orders returns one page of receipts, newest first.
func (s *Service) Orders(ctx context.Context, tenantID string, f OrderFilter) (OrderPage, error) {
	if err := f.Validate(); err != nil {
		return OrderPage{}, err
	}
	cursor, err := parseOrderCursor(f.Cursor)
	if err != nil {
		return OrderPage{}, err
	}

	where, args := orderPredicates(tenantID, f)
	args = append(args, cursor.date, cursor.placedAtMs, cursor.id, PageSize+1)
	position := len(args)
	where += fmt.Sprintf(`
		AND ($%d::date IS NULL OR (o.business_date, o.placed_at_ms, o.id) < ($%d::date, $%d::bigint, $%d::uuid))`,
		position-3, position-3, position-2, position-1)

	out := OrderPage{Rows: []OrderRow{}}
	err = pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT`+orderColumns+orderJoins+`
			WHERE `+where+`
			ORDER BY o.business_date DESC, o.placed_at_ms DESC, o.id DESC
			LIMIT $`+strconv.Itoa(position), args...)
		if err != nil {
			return err
		}
		out.Rows, err = pgx.CollectRows(rows, scanOrderRow)
		return err
	})
	if err != nil {
		return OrderPage{}, err
	}
	// One row beyond the page proves there IS a next page. Asking for a count
	// instead would scan the whole range on every scroll.
	if len(out.Rows) > PageSize {
		last := out.Rows[PageSize-1]
		out.Rows = out.Rows[:PageSize]
		out.Next = fmt.Sprintf("%s:%d:%s", last.BusinessDate.Format(time.DateOnly), last.PlacedAtMs, last.ID)
	}
	for _, r := range out.Rows {
		if r.Group() == GroupSales {
			out.PageNetSales += r.NetSales
			out.PageTotal += r.Total
		}
	}
	return out, nil
}

// orderPredicates builds the WHERE every receipt read shares.
func orderPredicates(tenantID string, f OrderFilter) (string, []any) {
	args := []any{tenantID, f.From.Format(time.DateOnly), f.To.Format(time.DateOnly),
		emptyToNil(f.OutletID), emptyToNil(f.RegisterID), emptyToNil(f.CashierID)}
	where := `o.tenant_id = $1
		AND o.business_date BETWEEN $2::date AND $3::date
		AND ($4::uuid IS NULL OR o.outlet_id = $4::uuid)
		AND ($5::uuid IS NULL OR o.pos_register_id = $5::uuid)
		AND ($6::text IS NULL OR o.payload->>'cashier_id' = $6::text)`

	if receipt := strings.TrimSpace(f.Receipt); receipt != "" {
		args = append(args, receipt)
		// A prefix match, so the index on the expression can still be used if
		// one is added; % and _ in the needle are escaped so a search box
		// cannot turn into a full scan for every row.
		where += fmt.Sprintf(" AND upper(o.payload->>'number') LIKE upper($%d) || '%%'", len(args))
	}
	switch f.Group {
	case "":
	case GroupSales:
		where += ` AND o.status NOT IN ('cancelled', 'refunded')`
	case GroupCancelled, GroupRefunded:
		args = append(args, f.Group)
		where += fmt.Sprintf(" AND o.status = $%d", len(args))
	default:
		args = append(args, f.Group)
		where += fmt.Sprintf(" AND o.status = $%d", len(args))
	}
	return where, args
}

func emptyToNil(v string) *string {
	if v == "" {
		return nil
	}
	return &v
}

// Order returns one receipt in full, or ErrNotFound. The id alone is not
// enough: it is checked against this merchant, so a UUID guessed from another
// tenant reads as missing rather than as forbidden.
func (s *Service) Order(ctx context.Context, tenantID, orderID string) (OrderDetail, error) {
	if !validation.UUID(orderID) {
		return OrderDetail{}, ErrNotFound
	}
	var d OrderDetail
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var payload []byte
		rows, err := tx.Query(ctx, `SELECT`+orderColumns+`,
			o.pos_session_id::text, o.device_id::text, COALESCE(dv.device_uuid, ''),
			o.settled_at, o.revision, o.payload`+orderJoins+`
			LEFT JOIN devices dv ON dv.tenant_id = o.tenant_id AND dv.id = o.device_id
			WHERE o.tenant_id = $1 AND o.id = $2::uuid`, tenantID, orderID)
		if err != nil {
			return err
		}
		found, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (OrderDetail, error) {
			var v OrderDetail
			err := row.Scan(&v.ID, &v.Number, &v.BusinessDate, &v.PlacedAtMs, &v.Status, &v.Type,
				&v.OutletID, &v.OutletName, &v.RegisterID, &v.RegisterName, &v.CashierID, &v.CashierName,
				&v.Subtotal, &v.Discount, &v.Tax, &v.ServiceCharge, &v.Total, &v.NetSales,
				&v.AmountPaid, &v.PaymentMethod, &v.RefundedAmount, &v.AuthorizedBy, &v.VoidReason, &v.RecoveryID,
				&v.SessionID, &v.DeviceID, &v.DeviceUUID, &v.SettledAt, &v.Revision, &payload)
			return v, err
		})
		if err != nil {
			return err
		}
		if len(found) == 0 {
			return ErrNotFound
		}
		d = found[0]
		d.TableName, d.CustomerName, d.Note, d.PromoName = payloadStrings(payload)
		d.Items, err = orderItems(ctx, tx, tenantID, d)
		return err
	})
	return d, err
}

// payloadStrings reads the optional labels a till recorded. A payload that
// cannot be parsed leaves them empty rather than failing the page: the money
// columns are relational and already read, and a receipt worth showing must
// not disappear because one label is malformed.
func payloadStrings(raw []byte) (table, customer, note, promo string) {
	var v struct {
		TableName    *string `json:"table_name"`
		CustomerName *string `json:"customer_name"`
		Note         *string `json:"note"`
		PromoName    *string `json:"promo_name"`
	}
	if json.Unmarshal(raw, &v) != nil {
		return "", "", "", ""
	}
	deref := func(p *string) string {
		if p == nil {
			return ""
		}
		return *p
	}
	return deref(v.TableName), deref(v.CustomerName), deref(v.Note), deref(v.PromoName)
}

// orderItems reads the lines and their modifiers. The partition key is in the
// WHERE so this reads one partition, not the whole history.
func orderItems(ctx context.Context, tx pgx.Tx, tenantID string, d OrderDetail) ([]OrderItemRow, error) {
	date := d.BusinessDate.Format(time.DateOnly)
	rows, err := tx.Query(ctx, `
		SELECT it.id::text, COALESCE(it.payload->>'product_id', ''), it.product_name,
		       COALESCE(it.payload->>'variant_name', ''), COALESCE(it.category_name, ''),
		       COALESCE(it.payload->>'note', ''), it.unit_price, it.quantity
		FROM order_items it
		WHERE it.tenant_id = $1 AND it.business_date = $2::date AND it.order_id = $3::uuid
		ORDER BY it.id`, tenantID, date, d.ID)
	if err != nil {
		return nil, err
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (OrderItemRow, error) {
		var i OrderItemRow
		err := row.Scan(&i.ID, &i.ProductID, &i.ProductName, &i.VariantName, &i.CategoryName,
			&i.Note, &i.UnitPrice, &i.Quantity)
		i.LineTotal = i.UnitPrice * i.Quantity
		return i, err
	})
	if err != nil || len(items) == 0 {
		return items, err
	}

	rows, err = tx.Query(ctx, `
		SELECT m.order_item_id::text, m.group_name, m.option_name, m.price_delta
		FROM order_item_modifiers m
		JOIN order_items it ON it.tenant_id = m.tenant_id AND it.business_date = m.business_date AND it.id = m.order_item_id
		WHERE m.tenant_id = $1 AND m.business_date = $2::date AND it.order_id = $3::uuid
		ORDER BY m.order_item_id, m.sort_order, m.id`, tenantID, date, d.ID)
	if err != nil {
		return nil, err
	}
	type attached struct {
		item string
		row  OrderModifierRow
	}
	modifiers, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (attached, error) {
		var a attached
		err := row.Scan(&a.item, &a.row.GroupName, &a.row.OptionName, &a.row.PriceDelta)
		return a, err
	})
	if err != nil {
		return nil, err
	}
	byItem := map[string][]OrderModifierRow{}
	for _, m := range modifiers {
		byItem[m.item] = append(byItem[m.item], m.row)
	}
	for i := range items {
		items[i].Modifiers = byItem[items[i].ID]
	}
	return items, nil
}

// orderCursor is a position in the newest-first ordering.
type orderCursor struct {
	date       *string
	placedAtMs *int64
	id         *string
}

// parseOrderCursor reads back exactly what a previous page produced. A
// hand-edited cursor is refused rather than coerced: it names a position in a
// scan, and a coerced one would silently page through somebody else's ordering.
func parseOrderCursor(cursor string) (orderCursor, error) {
	if cursor == "" {
		return orderCursor{}, nil
	}
	parts := strings.SplitN(cursor, ":", 3)
	if len(parts) != 3 || !validation.UUID(parts[2]) {
		return orderCursor{}, validation.Errors{"cursor": "Halaman tidak dikenal. Muat ulang daftar."}
	}
	if _, err := time.Parse(time.DateOnly, parts[0]); err != nil {
		return orderCursor{}, validation.Errors{"cursor": "Halaman tidak dikenal. Muat ulang daftar."}
	}
	placed, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || placed < 0 {
		return orderCursor{}, validation.Errors{"cursor": "Halaman tidak dikenal. Muat ulang daftar."}
	}
	return orderCursor{date: &parts[0], placedAtMs: &placed, id: &parts[2]}, nil
}
