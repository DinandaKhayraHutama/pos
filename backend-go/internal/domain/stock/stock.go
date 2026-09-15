// Package stock owns the stock ledger and the per-outlet count derived from it.
//
// Three rules carry the design, and each is a failure it prevents:
//
//   - **The ledger is append-only and holds deltas.** Deltas commute, so two
//     tills selling the same item offline converge on the right number the
//     moment both push, with nothing to resolve. A balance anyone may overwrite
//     is where "last writer wins" silently loses a sale.
//   - **The projection moves in the same transaction as the movement.** A
//     count that lagged its ledger would show a till a number the server
//     cannot explain, and a movement acknowledged before its projection
//     committed could be counted twice on the till.
//   - **A stock opname (count) is the one server-wins case.** The till says what
//     it counted; the server turns that into a delta against its own current
//     quantity at ingest, because a physical count is a fact about now and the
//     server has the freshest aggregate.
//
// Negative stock is allowed and flagged, never refused: a sale that happened
// is recorded even when the ledger says the shelf was already empty.
//
// A write locks only what its invariant needs — the projection rows it moves,
// then its branch's two counters — never the merchant.
package stock

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// LowStockThreshold matches the till's Product.lowStockThreshold, so the
// Backoffice and the sell screen flag the same shelves.
const LowStockThreshold int64 = 5

const (
	ReasonOpening     = "opening"
	ReasonReceived    = "received"
	ReasonSale        = "sale"
	ReasonVoidReturn  = "voidReturn"
	ReasonWaste       = "waste"
	ReasonCorrection  = "correction"
	ReasonCount       = "count"
	ReasonTransferIn  = "transferIn"
	ReasonTransferOut = "transferOut"

	SourceDevice     = "device"
	SourceBackoffice = "backoffice"

	// Entity is the push/pull feed name of the ledger.
	Entity = "stock_movements"
)

// maxQuantity bounds one movement. A till counting a warehouse is still far
// below it; a typo of six extra zeros is not.
const maxQuantity int64 = 1_000_000

const maxMillis int64 = 253402300799999 // last millisecond of year 9999

var ErrNotFound = errors.New("stock: no such outlet or product")

// Rejection is a pushed movement refused for what it says. It maps onto the
// push contract's closed set of row codes.
type Rejection struct {
	Code    string
	Message string
}

func (r *Rejection) Error() string { return r.Message }

func reject(code, message string) error { return &Rejection{Code: code, Message: message} }

type Service struct {
	pools pg.Pools
	feed  *syncfeed.Service
}

func NewService(pools pg.Pools, feed *syncfeed.Service) *Service {
	return &Service{pools: pools, feed: feed}
}

// movement is one ledger row about to be written.
type movement struct {
	id, outletID, productID, reason string
	// delta is ignored for a count; apply computes it.
	delta        int64
	counted      *int64
	basis        *int64
	occurredAtMs int64
	source       string
	deviceID     *string
	createdBy    *string
	employeeName string
	productName  string
	note         *string
	refType      *string
	refID        *string
	payload      []byte
}

// Applied is what one movement did once written.
type Applied struct {
	ID           string
	Delta        int64
	BalanceAfter int64
	// StockSeq is the outlet_stock sequence the product's count carries after
	// this movement: any snapshot at or past it already includes it.
	StockSeq int64
	SyncSeq  int64
	Inserted bool
}

type stockKey struct{ outlet, product string }

// apply writes movements and moves their projection rows, inside w's
// transaction.
//
// Lock order is fixed, and it is what keeps concurrent writers from
// deadlocking: every projection row the write touches, in (outlet, product)
// order, THEN each branch's counters in outlet order — movements before
// stock. A writer that holds a counter has already locked every row it needs.
func apply(ctx context.Context, w *syncfeed.Writer, tenantID string, moves []movement) ([]Applied, error) {
	seen := map[stockKey]bool{}
	var keys []stockKey
	for _, m := range moves {
		k := stockKey{m.outletID, m.productID}
		if !seen[k] {
			seen[k] = true
			keys = append(keys, k)
		}
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].outlet != keys[j].outlet {
			return keys[i].outlet < keys[j].outlet
		}
		return keys[i].product < keys[j].product
	})

	outletIDs := make([]string, len(keys))
	productIDs := make([]string, len(keys))
	for i, k := range keys {
		outletIDs[i], productIDs[i] = k.outlet, k.product
	}

	// A branch's first movement of a product creates its row. The FKs refuse a
	// product or outlet this merchant does not own.
	if _, err := w.Tx.Exec(ctx, `
		INSERT INTO outlet_stock (tenant_id, outlet_id, product_id, qty_on_hand)
		SELECT $1, k.o, k.p, 0
		FROM unnest($2::text[]::uuid[], $3::text[]::uuid[]) AS k(o, p)
		ON CONFLICT (tenant_id, outlet_id, product_id) DO NOTHING`,
		tenantID, outletIDs, productIDs); err != nil {
		return nil, err
	}

	rows, err := w.Tx.Query(ctx, `
		SELECT os.outlet_id::text, os.product_id::text, os.qty_on_hand
		FROM outlet_stock os
		JOIN unnest($2::text[]::uuid[], $3::text[]::uuid[]) AS k(o, p)
		  ON os.outlet_id = k.o AND os.product_id = k.p
		WHERE os.tenant_id = $1
		ORDER BY os.outlet_id, os.product_id
		FOR UPDATE OF os`,
		tenantID, outletIDs, productIDs)
	if err != nil {
		return nil, err
	}
	qty := map[stockKey]int64{}
	for rows.Next() {
		var k stockKey
		var q int64
		if err := rows.Scan(&k.outlet, &k.product, &q); err != nil {
			rows.Close()
			return nil, err
		}
		qty[k] = q
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(qty) != len(keys) {
		return nil, fmt.Errorf("stock: locked %d of %d projection rows", len(qty), len(keys))
	}

	// Numbers, per branch, in branch order.
	movesByOutlet := map[string][]int{}
	var outlets []string
	for i, m := range moves {
		if _, ok := movesByOutlet[m.outletID]; !ok {
			outlets = append(outlets, m.outletID)
		}
		movesByOutlet[m.outletID] = append(movesByOutlet[m.outletID], i)
	}
	sort.Strings(outlets)

	moveSeq := make([]int64, len(moves))
	stockSeq := map[stockKey]int64{}
	for _, outlet := range outlets {
		indices := movesByOutlet[outlet]
		first, err := w.OutletSeqBlock(ctx, Entity, outlet, int64(len(indices)))
		if err != nil {
			return nil, err
		}
		for n, i := range indices {
			moveSeq[i] = first + int64(n)
		}

		var products []stockKey
		for _, k := range keys {
			if k.outlet == outlet {
				products = append(products, k)
			}
		}
		firstStock, err := w.OutletSeqBlock(ctx, "outlet_stock", outlet, int64(len(products)))
		if err != nil {
			return nil, err
		}
		for n, k := range products {
			stockSeq[k] = firstStock + int64(n)
		}
	}

	out := make([]Applied, len(moves))
	for i, m := range moves {
		k := stockKey{m.outletID, m.productID}
		delta := m.delta
		if m.reason == ReasonCount {
			delta = *m.counted - qty[k]
		}
		qty[k] += delta

		if _, err := w.Tx.Exec(ctx, `
			INSERT INTO stock_movements (
				id, tenant_id, outlet_id, product_id, reason, delta_qty, counted_qty, basis_seq,
				balance_after, occurred_at_ms, source, device_id, created_by, employee_name,
				product_name, note, ref_type, ref_id, payload, applied_stock_seq, sync_seq)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18,
			        $19::jsonb, $20, $21)`,
			m.id, tenantID, m.outletID, m.productID, m.reason, delta, m.counted, m.basis,
			qty[k], m.occurredAtMs, m.source, m.deviceID, m.createdBy, m.employeeName,
			m.productName, m.note, m.refType, m.refID, nullableJSON(m.payload), stockSeq[k], moveSeq[i],
		); err != nil {
			return nil, err
		}

		out[i] = Applied{
			ID: m.id, Delta: delta, BalanceAfter: qty[k],
			StockSeq: stockSeq[k], SyncSeq: moveSeq[i], Inserted: true,
		}
	}

	for _, k := range keys {
		if _, err := w.Tx.Exec(ctx, `
			UPDATE outlet_stock SET qty_on_hand = $4, sync_seq = $5, updated_at = now()
			WHERE tenant_id = $1 AND outlet_id = $2 AND product_id = $3`,
			tenantID, k.outlet, k.product, qty[k], stockSeq[k]); err != nil {
			return nil, err
		}
	}

	return out, nil
}

func nullableJSON(b []byte) any {
	if b == nil {
		return nil
	}
	return string(b)
}

// DeviceMovement is a movement as a till pushes it (the StockMovement schema).
type DeviceMovement struct {
	ID           string  `json:"id"`
	Revision     int64   `json:"revision"`
	ProductID    string  `json:"product_id"`
	ProductName  string  `json:"product_name"`
	Reason       string  `json:"reason"`
	DeltaQty     int64   `json:"delta_qty"`
	CountedQty   *int64  `json:"counted_qty"`
	BasisSeq     *int64  `json:"basis_seq"`
	OccurredAtMs int64   `json:"occurred_at_ms"`
	EmployeeID   *string `json:"employee_id"`
	EmployeeName string  `json:"employee_name"`
	Note         *string `json:"note"`
}

// canonical is the form two pushes of one movement are compared in. Revision
// is left out: a movement is immutable, and a refused one sent again from the
// till's dead-letter table carries a newer revision of the same facts.
func (in DeviceMovement) canonical() []byte {
	in.Revision = 0
	b, err := json.Marshal(in)
	if err != nil {
		panic(err) // only JSON-safe primitives
	}
	return b
}

func validateDevice(in DeviceMovement) error {
	bad := func(message string) error { return reject("schema_rejected", message) }

	if !validation.UUID(in.ID) || !validation.UUID(in.ProductID) {
		return bad("Movement and product identifiers must be UUIDs.")
	}
	if in.EmployeeID != nil && !validation.UUID(*in.EmployeeID) {
		return bad("Employee identifier must be a UUID.")
	}
	name := strings.TrimSpace(in.ProductName)
	if name == "" || len([]rune(name)) > 120 || len([]rune(in.EmployeeName)) > 120 {
		return bad("Invalid product or employee name.")
	}
	if in.Note != nil && len([]rune(*in.Note)) > 200 {
		return bad("Note is too long.")
	}
	if in.OccurredAtMs < 0 || in.OccurredAtMs > maxMillis {
		return bad("Invalid movement time.")
	}
	if in.BasisSeq != nil && *in.BasisSeq < 0 {
		return bad("Invalid basis sequence.")
	}
	if in.DeltaQty < -maxQuantity || in.DeltaQty > maxQuantity {
		return bad("Quantity out of range.")
	}

	if in.Reason == ReasonCount {
		if in.CountedQty == nil || *in.CountedQty < 0 || *in.CountedQty > maxQuantity {
			return bad("A count requires a counted quantity of zero or more.")
		}
		return nil
	}
	if in.CountedQty != nil {
		return bad("Only a count carries a counted quantity.")
	}

	// The sign is part of what a reason means. A sale that adds stock is a
	// bug on the till, and recording it would move the shelf the wrong way.
	switch in.Reason {
	case ReasonSale, ReasonWaste:
		if in.DeltaQty >= 0 {
			return bad("A sale or waste must take stock away.")
		}
	case ReasonVoidReturn, ReasonReceived:
		if in.DeltaQty <= 0 {
			return bad("A return or delivery must add stock.")
		}
	case ReasonCorrection, ReasonOpening:
		if in.DeltaQty == 0 {
			return bad("A correction must change the count.")
		}
	default:
		return bad("This reason is not device-writable.")
	}
	return nil
}

// RecordFromDevice applies one pushed movement at the till's bound outlet.
//
// Identity comes from the token: the outlet and device are the binding's, never
// the row's. An exact retry — the same device, the same movement — is accepted
// with what was recorded the first time, including the delta a count was turned
// into; the same id naming anything else is refused as a duplicate.
func (s *Service) RecordFromDevice(ctx context.Context, w *syncfeed.Writer, b devices.Binding, in DeviceMovement) (Applied, error) {
	in.ID = strings.ToLower(in.ID)
	in.ProductID = strings.ToLower(in.ProductID)
	if in.EmployeeID != nil {
		lowered := strings.ToLower(*in.EmployeeID)
		in.EmployeeID = &lowered
	}
	if err := validateDevice(in); err != nil {
		return Applied{}, err
	}
	canonical := in.canonical()

	// Concurrent retries of one movement queue here instead of racing to the
	// primary key, where the loser would read as a duplicate of itself.
	if _, err := w.Tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 72051))`, in.ID); err != nil {
		return Applied{}, err
	}

	var (
		previousDevice  *string
		previousPayload []byte
		previous        Applied
	)
	err := w.Tx.QueryRow(ctx, `
		SELECT device_id::text, payload, delta_qty, balance_after, applied_stock_seq, sync_seq
		FROM stock_movements WHERE tenant_id = $1 AND id = $2`,
		b.Tenant.ID, in.ID).Scan(&previousDevice, &previousPayload,
		&previous.Delta, &previous.BalanceAfter, &previous.StockSeq, &previous.SyncSeq)
	switch {
	case err == nil:
		if previousDevice == nil || *previousDevice != b.Device.ID {
			return Applied{}, reject("duplicate", "Movement belongs to a different device.")
		}
		var stored DeviceMovement
		if json.Unmarshal(previousPayload, &stored) != nil || string(stored.canonical()) != string(canonical) {
			return Applied{}, reject("duplicate", "This identifier already names a different movement.")
		}
		previous.ID = in.ID
		return previous, nil
	case !errors.Is(err, pgx.ErrNoRows):
		return Applied{}, err
	}

	deviceID := b.Device.ID
	applied, err := apply(ctx, w, b.Tenant.ID, []movement{{
		id: in.ID, outletID: b.Outlet.ID, productID: in.ProductID, reason: in.Reason,
		delta: in.DeltaQty, counted: in.CountedQty, basis: in.BasisSeq,
		occurredAtMs: in.OccurredAtMs, source: SourceDevice, deviceID: &deviceID,
		employeeName: in.EmployeeName, productName: strings.TrimSpace(in.ProductName),
		note: in.Note, payload: canonical,
	}})
	if err != nil {
		return Applied{}, err
	}
	return applied[0], nil
}

// Actor is who did a Backoffice write.
type Actor struct {
	EmployeeID string
	Name       string
}

// Adjustment kinds a Backoffice form offers.
const (
	KindReceived      = "received"
	KindWaste         = "waste"
	KindCorrectionIn  = "correction_in"
	KindCorrectionOut = "correction_out"
)

type Adjustment struct {
	OutletID  string
	ProductID string
	Kind      string
	Quantity  int64
	Note      *string
}

type Transfer struct {
	FromOutletID string
	ToOutletID   string
	ProductID    string
	Quantity     int64
	Note         *string
}

func newID(ctx context.Context, tx pgx.Tx) (string, error) {
	var id string
	err := tx.QueryRow(ctx, `SELECT gen_random_uuid()::text`).Scan(&id)
	return id, err
}

// liveNames resolves a product and outlets the merchant still has, or
// ErrNotFound. Row-level security makes another merchant's ids look absent.
func liveNames(ctx context.Context, tx pgx.Tx, tenantID, productID string, outletIDs ...string) (string, error) {
	if !validation.UUID(productID) {
		return "", ErrNotFound
	}
	for _, id := range outletIDs {
		if !validation.UUID(id) {
			return "", ErrNotFound
		}
	}

	var product string
	err := tx.QueryRow(ctx, `SELECT name FROM products WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL`,
		tenantID, productID).Scan(&product)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}

	var live int
	if err := tx.QueryRow(ctx, `
		SELECT count(*) FROM outlets
		WHERE tenant_id = $1 AND id = ANY($2::text[]::uuid[]) AND deleted_at IS NULL`,
		tenantID, outletIDs).Scan(&live); err != nil {
		return "", err
	}
	if live != len(outletIDs) {
		return "", ErrNotFound
	}

	return product, nil
}

func (a Actor) movement(outletID, productID, productName, reason string, delta int64, note *string) movement {
	createdBy := a.EmployeeID
	m := movement{
		outletID: outletID, productID: productID, productName: productName, reason: reason,
		delta: delta, occurredAtMs: time.Now().UnixMilli(), source: SourceBackoffice,
		employeeName: a.Name, note: note,
	}
	if validation.UUID(createdBy) {
		m.createdBy = &createdBy
	}
	return m
}

func validateNote(errs validation.Errors, note *string) {
	errs.Optional("note", note, 200)
}

// Adjust books a delivery, waste or correction at one branch.
func (s *Service) Adjust(ctx context.Context, tenantID string, actor Actor, in Adjustment) error {
	errs := validation.Errors{}
	var reason string
	var delta int64
	switch in.Kind {
	case KindReceived:
		reason, delta = ReasonReceived, in.Quantity
	case KindWaste:
		reason, delta = ReasonWaste, -in.Quantity
	case KindCorrectionIn:
		reason, delta = ReasonCorrection, in.Quantity
	case KindCorrectionOut:
		reason, delta = ReasonCorrection, -in.Quantity
	default:
		errs.Add("kind", "Pilih jenis penyesuaian.")
	}
	if in.Quantity < 1 || in.Quantity > maxQuantity {
		errs.Add("quantity", "Jumlah harus antara 1 dan 1.000.000.")
	}
	validateNote(errs, in.Note)
	if err := errs.Err(); err != nil {
		return err
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		name, err := liveNames(ctx, w.Tx, tenantID, in.ProductID, in.OutletID)
		if err != nil {
			return err
		}
		m := actor.movement(in.OutletID, in.ProductID, name, reason, delta, in.Note)
		if m.id, err = newID(ctx, w.Tx); err != nil {
			return err
		}
		_, err = apply(ctx, w, tenantID, []movement{m})
		return err
	})
}

// Count records a stock opname: the counted quantity replaces the server's
// count, and the movement records the difference.
func (s *Service) Count(ctx context.Context, tenantID string, actor Actor, outletID, productID string, counted int64, note *string) error {
	errs := validation.Errors{}
	if counted < 0 || counted > maxQuantity {
		errs.Add("counted", "Jumlah hitung harus antara 0 dan 1.000.000.")
	}
	validateNote(errs, note)
	if err := errs.Err(); err != nil {
		return err
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		name, err := liveNames(ctx, w.Tx, tenantID, productID, outletID)
		if err != nil {
			return err
		}
		m := actor.movement(outletID, productID, name, ReasonCount, 0, note)
		m.counted = &counted
		if m.id, err = newID(ctx, w.Tx); err != nil {
			return err
		}
		_, err = apply(ctx, w, tenantID, []movement{m})
		return err
	})
}

// Transfer moves stock between two branches in one transaction: a transferOut
// at the source and a transferIn at the destination, sharing one reference, so
// the chain's total never changes and neither half exists without the other.
func (s *Service) Transfer(ctx context.Context, tenantID string, actor Actor, in Transfer) error {
	errs := validation.Errors{}
	if in.Quantity < 1 || in.Quantity > maxQuantity {
		errs.Add("quantity", "Jumlah harus antara 1 dan 1.000.000.")
	}
	if in.ToOutletID == "" || in.ToOutletID == in.FromOutletID {
		errs.Add("to_outlet", "Pilih outlet tujuan yang berbeda.")
	}
	validateNote(errs, in.Note)
	if err := errs.Err(); err != nil {
		return err
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		name, err := liveNames(ctx, w.Tx, tenantID, in.ProductID, in.FromOutletID)
		if err != nil {
			return err
		}
		if _, err := liveNames(ctx, w.Tx, tenantID, in.ProductID, in.ToOutletID); errors.Is(err, ErrNotFound) {
			return validation.Errors{"to_outlet": "Outlet tujuan tidak ditemukan."}
		} else if err != nil {
			return err
		}

		ref, err := newID(ctx, w.Tx)
		if err != nil {
			return err
		}
		refType := "transfer"
		out := actor.movement(in.FromOutletID, in.ProductID, name, ReasonTransferOut, -in.Quantity, in.Note)
		into := actor.movement(in.ToOutletID, in.ProductID, name, ReasonTransferIn, in.Quantity, in.Note)
		for _, m := range []*movement{&out, &into} {
			if m.id, err = newID(ctx, w.Tx); err != nil {
				return err
			}
			m.refType, m.refID = &refType, &ref
		}
		_, err = apply(ctx, w, tenantID, []movement{out, into})
		return err
	})
}

// Level is one product's count at one branch. Qty is nil when the product has
// never had a movement there — untracked, which is not the same as zero.
type Level struct {
	ProductID   string
	ProductName string
	Qty         *int64
	UpdatedAt   *time.Time
}

func likePattern(query string) string {
	escaped := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(strings.TrimSpace(query))
	return "%" + escaped + "%"
}

// Levels lists every live product with its count at one branch, shortest shelf
// first, untracked products last.
func (s *Service) Levels(ctx context.Context, tenantID, outletID, query string) ([]Level, error) {
	if !validation.UUID(outletID) {
		return nil, ErrNotFound
	}

	var out []Level
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var exists bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM outlets WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL)`,
			tenantID, outletID).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			return ErrNotFound
		}

		rows, err := tx.Query(ctx, `
			SELECT p.id::text, p.name,
			       CASE WHEN os.sync_seq > 0 THEN os.qty_on_hand END,
			       CASE WHEN os.sync_seq > 0 THEN os.updated_at END
			FROM products p
			LEFT JOIN outlet_stock os
			       ON os.tenant_id = p.tenant_id AND os.product_id = p.id AND os.outlet_id = $2
			WHERE p.tenant_id = $1 AND p.deleted_at IS NULL
			  AND ($3 = '%%' OR p.name ILIKE $3)
			ORDER BY (os.sync_seq IS NULL OR os.sync_seq = 0), os.qty_on_hand, p.name
			LIMIT 500`, tenantID, outletID, likePattern(query))
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Level, error) {
			var l Level
			err := row.Scan(&l.ProductID, &l.ProductName, &l.Qty, &l.UpdatedAt)
			return l, err
		})
		return err
	})
	return out, err
}

// Entry is one ledger line.
type Entry struct {
	ID           string
	Reason       string
	Source       string
	EmployeeName string
	Delta        int64
	BalanceAfter int64
	Counted      *int64
	OccurredAt   time.Time
	Note         *string
	RefType      *string
}

// Detail is one product at one branch, with its recent ledger.
type Detail struct {
	OutletID    string
	OutletName  string
	ProductID   string
	ProductName string
	Qty         *int64
	Ledger      []Entry
}

func (s *Service) Detail(ctx context.Context, tenantID, outletID, productID string) (Detail, error) {
	if !validation.UUID(outletID) || !validation.UUID(productID) {
		return Detail{}, ErrNotFound
	}

	d := Detail{OutletID: outletID, ProductID: productID}
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			SELECT o.name, p.name, CASE WHEN os.sync_seq > 0 THEN os.qty_on_hand END
			FROM outlets o
			JOIN products p ON p.tenant_id = o.tenant_id AND p.id = $3 AND p.deleted_at IS NULL
			LEFT JOIN outlet_stock os
			       ON os.tenant_id = o.tenant_id AND os.outlet_id = o.id AND os.product_id = p.id
			WHERE o.tenant_id = $1 AND o.id = $2 AND o.deleted_at IS NULL`,
			tenantID, outletID, productID).Scan(&d.OutletName, &d.ProductName, &d.Qty)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}

		rows, err := tx.Query(ctx, `
			SELECT id::text, reason, source, employee_name, delta_qty, balance_after, counted_qty,
			       occurred_at_ms, note, ref_type
			FROM stock_movements
			WHERE tenant_id = $1 AND outlet_id = $2 AND product_id = $3
			ORDER BY sync_seq DESC
			LIMIT 100`, tenantID, outletID, productID)
		if err != nil {
			return err
		}
		d.Ledger, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Entry, error) {
			var e Entry
			var at int64
			err := row.Scan(&e.ID, &e.Reason, &e.Source, &e.EmployeeName, &e.Delta, &e.BalanceAfter,
				&e.Counted, &at, &e.Note, &e.RefType)
			e.OccurredAt = time.UnixMilli(at)
			return e, err
		})
		return err
	})
	return d, err
}

// Alert is a tracked shelf at or below the low-stock threshold — negative
// included, which is the case that most needs a person.
type Alert struct {
	OutletID    string
	OutletName  string
	ProductID   string
	ProductName string
	Qty         int64
}

func (s *Service) Alerts(ctx context.Context, tenantID string) ([]Alert, error) {
	var out []Alert
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT o.id::text, o.name, p.id::text, p.name, os.qty_on_hand
			FROM outlet_stock os
			JOIN outlets o  ON o.tenant_id = os.tenant_id AND o.id = os.outlet_id AND o.deleted_at IS NULL
			JOIN products p ON p.tenant_id = os.tenant_id AND p.id = os.product_id AND p.deleted_at IS NULL
			WHERE os.tenant_id = $1 AND os.sync_seq > 0 AND os.qty_on_hand <= $2
			ORDER BY os.qty_on_hand, o.name, p.name
			LIMIT 200`, tenantID, LowStockThreshold)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Alert, error) {
			var a Alert
			err := row.Scan(&a.OutletID, &a.OutletName, &a.ProductID, &a.ProductName, &a.Qty)
			return a, err
		})
		return err
	})
	return out, err
}

// Reconcile re-derives one merchant's projection from its ledger and repairs
// every row that disagrees, returning how many it repaired.
//
// Nothing should ever need repairing — the projection moves in the movement's
// own transaction — so a non-zero answer is a bug to investigate, and the
// caller logs it as one. It exists so that a bug, a manual SQL fix or a restore
// cannot leave a shelf wrong for longer than one night.
//
// Detection reads without locks; each repair then locks its projection row and
// sums the ledger in a later statement. Every movement for that product needs
// the same row lock, so no movement can be in flight when the sum is taken.
func (s *Service) Reconcile(ctx context.Context, tenantID string) (int, error) {
	var suspects []stockKey
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT os.outlet_id::text, os.product_id::text
			FROM outlet_stock os
			WHERE os.tenant_id = $1 AND os.sync_seq > 0
			  AND os.qty_on_hand <> (
			      SELECT COALESCE(sum(sm.delta_qty), 0) FROM stock_movements sm
			      WHERE sm.tenant_id = os.tenant_id AND sm.outlet_id = os.outlet_id
			        AND sm.product_id = os.product_id)`, tenantID)
		if err != nil {
			return err
		}
		suspects, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (stockKey, error) {
			var k stockKey
			err := row.Scan(&k.outlet, &k.product)
			return k, err
		})
		return err
	})
	if err != nil {
		return 0, err
	}

	repaired := 0
	for _, k := range suspects {
		err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
			var current int64
			if err := w.Tx.QueryRow(ctx, `
				SELECT qty_on_hand FROM outlet_stock
				WHERE tenant_id = $1 AND outlet_id = $2 AND product_id = $3 FOR UPDATE`,
				tenantID, k.outlet, k.product).Scan(&current); err != nil {
				return err
			}
			var ledger int64
			if err := w.Tx.QueryRow(ctx, `
				SELECT COALESCE(sum(delta_qty), 0) FROM stock_movements
				WHERE tenant_id = $1 AND outlet_id = $2 AND product_id = $3`,
				tenantID, k.outlet, k.product).Scan(&ledger); err != nil {
				return err
			}
			if current == ledger {
				return nil
			}
			seq, err := w.OutletSeqBlock(ctx, "outlet_stock", k.outlet, 1)
			if err != nil {
				return err
			}
			if _, err := w.Tx.Exec(ctx, `
				UPDATE outlet_stock SET qty_on_hand = $4, sync_seq = $5, updated_at = now()
				WHERE tenant_id = $1 AND outlet_id = $2 AND product_id = $3`,
				tenantID, k.outlet, k.product, ledger, seq); err != nil {
				return err
			}
			repaired++
			return nil
		})
		if err != nil {
			return repaired, err
		}
	}
	return repaired, nil
}
