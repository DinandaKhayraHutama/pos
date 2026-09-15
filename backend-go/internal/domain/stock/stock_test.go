package stock_test

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/stock"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
)

type fixture struct {
	db   pgtest.DB
	feed *syncfeed.Service
	svc  *stock.Service

	tenantID, otherTenantID    string
	outletA, outletB           string
	otherOutlet                string
	productID, product2ID      string
	otherProductID             string
	tillA, tillB, tillC, tillX devices.Binding
}

// setup gives the service the credentials the server uses: a tenant pool that
// cannot bypass row-level security. Seeding goes through the owner.
func setup(t *testing.T) *fixture {
	t.Helper()
	db := pgtest.New(t)
	ctx := context.Background()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	f := &fixture{db: db}
	f.feed = syncfeed.NewService(db.Pools, nil, logger)
	f.svc = stock.NewService(db.Pools, f.feed)

	scan := func(dst *string, sql string, args ...any) {
		t.Helper()
		require.NoError(t, db.Owner.QueryRow(ctx, sql, args...).Scan(dst))
	}
	scan(&f.tenantID, `INSERT INTO tenants (name, slug) VALUES ('Warung Stok', gen_random_uuid()::text) RETURNING id::text`)
	scan(&f.otherTenantID, `INSERT INTO tenants (name, slug) VALUES ('Warung Lain', gen_random_uuid()::text) RETURNING id::text`)
	scan(&f.outletA, `INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Kemang') RETURNING id::text`, f.tenantID)
	scan(&f.outletB, `INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Bintaro') RETURNING id::text`, f.tenantID)
	scan(&f.otherOutlet, `INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Rahasia') RETURNING id::text`, f.otherTenantID)

	var category, otherCategory string
	scan(&category, `INSERT INTO categories (tenant_id, name) VALUES ($1, 'Minuman') RETURNING id::text`, f.tenantID)
	scan(&otherCategory, `INSERT INTO categories (tenant_id, name) VALUES ($1, 'Minuman') RETURNING id::text`, f.otherTenantID)
	scan(&f.productID, `INSERT INTO products (tenant_id, category_id, name, price) VALUES ($1, $2, 'Es Teh', 5000) RETURNING id::text`, f.tenantID, category)
	scan(&f.product2ID, `INSERT INTO products (tenant_id, category_id, name, price) VALUES ($1, $2, 'Kopi Susu', 18000) RETURNING id::text`, f.tenantID, category)
	scan(&f.otherProductID, `INSERT INTO products (tenant_id, category_id, name, price) VALUES ($1, $2, 'Es Teh', 5000) RETURNING id::text`, f.otherTenantID, otherCategory)

	f.tillA = f.till(t, f.tenantID, f.outletA, "a")
	f.tillB = f.till(t, f.tenantID, f.outletA, "b")
	f.tillC = f.till(t, f.tenantID, f.outletB, "c")
	f.tillX = f.till(t, f.otherTenantID, f.otherOutlet, "x")
	return f
}

func (f *fixture) till(t *testing.T, tenantID, outletID, name string) devices.Binding {
	t.Helper()
	ctx := context.Background()
	var b devices.Binding
	b.Tenant.ID, b.Outlet.ID = tenantID, outletID
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`INSERT INTO pos_registers (tenant_id, outlet_id, name) VALUES ($1, $2, $3) RETURNING id::text`,
		tenantID, outletID, "Kasir "+name).Scan(&b.Register.ID))
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`INSERT INTO devices (tenant_id, outlet_id, pos_register_id, device_uuid) VALUES ($1, $2, $3, $4) RETURNING id::text`,
		tenantID, outletID, b.Register.ID, "tablet-"+name).Scan(&b.Device.ID))
	return b
}

func newUUID(t *testing.T) string {
	t.Helper()
	var b [16]byte
	_, err := rand.Read(b[:])
	require.NoError(t, err)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func ptr[T any](v T) *T { return &v }

// push is what the ingest path does for one pushed row: numbered inside its
// own transaction, published after commit.
func (f *fixture) push(ctx context.Context, b devices.Binding, in stock.DeviceMovement) (stock.Applied, error) {
	var out stock.Applied
	err := f.feed.Write(ctx, b.Tenant.ID, func(ctx context.Context, w *syncfeed.Writer) error {
		var err error
		out, err = f.svc.RecordFromDevice(ctx, w, b, in)
		return err
	})
	return out, err
}

func movement(id, productID, reason string, delta int64) stock.DeviceMovement {
	return stock.DeviceMovement{
		ID: id, Revision: 1, ProductID: productID, ProductName: "Es Teh", Reason: reason,
		DeltaQty: delta, OccurredAtMs: time.Now().UnixMilli(), EmployeeName: "Siti",
	}
}

func (f *fixture) qty(t *testing.T, outletID, productID string) int64 {
	t.Helper()
	var q int64
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		`SELECT qty_on_hand FROM outlet_stock WHERE outlet_id = $1 AND product_id = $2`,
		outletID, productID).Scan(&q))
	return q
}

func (f *fixture) ledger(t *testing.T, outletID, productID string) (sum int64, rows int) {
	t.Helper()
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		`SELECT COALESCE(sum(delta_qty), 0), count(*) FROM stock_movements WHERE outlet_id = $1 AND product_id = $2`,
		outletID, productID).Scan(&sum, &rows))
	return sum, rows
}

func (f *fixture) receive(t *testing.T, outletID, productID string, qty int64) {
	t.Helper()
	require.NoError(t, f.svc.Adjust(context.Background(), f.tenantID, stock.Actor{Name: "Owner"},
		stock.Adjustment{OutletID: outletID, ProductID: productID, Kind: stock.KindReceived, Quantity: qty}))
}

func rejectionCode(err error) string {
	var r *stock.Rejection
	if errors.As(err, &r) {
		return r.Code
	}
	return ""
}

// The Fase 5 gate: two tills sell the same item offline for an hour, both push,
// and the outlet — and every till pulling it — lands on the right number.
func TestTwoTillsSellingOfflineConvergeOnTheOutletQuantity(t *testing.T) {
	f := setup(t)
	ctx := context.Background()

	f.receive(t, f.outletA, f.productID, 20)

	type queued struct {
		till devices.Binding
		m    stock.DeviceMovement
	}
	// Each till rings up fifteen sales of the same item, each believing the
	// shelf is its own.
	var outbox []queued
	for i := 0; i < 15; i++ {
		outbox = append(outbox,
			queued{f.tillA, movement(newUUID(t), f.productID, stock.ReasonSale, -1)},
			queued{f.tillB, movement(newUUID(t), f.productID, stock.ReasonSale, -1)})
	}

	// Both reconnect at once, and every push is sent three times, as if each
	// response had been lost on the way back.
	var wg sync.WaitGroup
	failures := make(chan error, len(outbox)*3)
	for attempt := 0; attempt < 3; attempt++ {
		for _, q := range outbox {
			wg.Add(1)
			go func(q queued) {
				defer wg.Done()
				if _, err := f.push(ctx, q.till, q.m); err != nil {
					failures <- err
				}
			}(q)
		}
	}
	wg.Wait()
	close(failures)
	for err := range failures {
		require.NoError(t, err)
	}

	require.EqualValues(t, -10, f.qty(t, f.outletA, f.productID),
		"20 received and 30 sold: the shortfall is recorded, never refused")
	sum, rows := f.ledger(t, f.outletA, f.productID)
	require.EqualValues(t, -10, sum)
	require.Equal(t, 31, rows, "three sends of every sale are still one movement each")

	// What the till pulls is what the centre shows.
	page, err := f.feed.PullOutlet(ctx, f.tenantID, f.outletA, "outlet_stock", 0, 100)
	require.NoError(t, err)
	require.Len(t, page.Rows, 1)
	var row map[string]any
	require.NoError(t, json.Unmarshal(page.Rows[0], &row))
	require.EqualValues(t, -10, row["qty_on_hand"])

	levels, err := f.svc.Levels(ctx, f.tenantID, f.outletA, "Es Teh")
	require.NoError(t, err)
	require.Len(t, levels, 1)
	require.EqualValues(t, -10, *levels[0].Qty)

	alerts, err := f.svc.Alerts(ctx, f.tenantID)
	require.NoError(t, err)
	require.Len(t, alerts, 1)
	require.EqualValues(t, -10, alerts[0].Qty)
}

func TestAnExactRetryIsAcceptedWithWhatWasFirstRecorded(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	f.receive(t, f.outletA, f.productID, 5)

	sale := movement(newUUID(t), f.productID, stock.ReasonSale, -2)
	first, err := f.push(ctx, f.tillA, sale)
	require.NoError(t, err)
	require.True(t, first.Inserted)
	require.EqualValues(t, 3, first.BalanceAfter)

	f.receive(t, f.outletA, f.productID, 10) // the shelf moves on in between

	again, err := f.push(ctx, f.tillA, sale)
	require.NoError(t, err)
	require.False(t, again.Inserted)
	require.Equal(t, first.StockSeq, again.StockSeq)
	require.Equal(t, first.BalanceAfter, again.BalanceAfter)
	require.Equal(t, first.Delta, again.Delta)

	// Sent again from the till's dead-letter table: a newer revision of the
	// same facts is the same movement.
	requeued := sale
	requeued.Revision = 2
	_, err = f.push(ctx, f.tillA, requeued)
	require.NoError(t, err)

	changed := sale
	changed.DeltaQty = -3
	_, err = f.push(ctx, f.tillA, changed)
	require.Equal(t, "duplicate", rejectionCode(err))

	_, err = f.push(ctx, f.tillB, sale)
	require.Equal(t, "duplicate", rejectionCode(err), "another till cannot claim this movement")

	require.EqualValues(t, 13, f.qty(t, f.outletA, f.productID))
	_, rows := f.ledger(t, f.outletA, f.productID)
	require.Equal(t, 3, rows)
}

// A physical count is a fact about now, and the server has the freshest total.
func TestACountBecomesADeltaAgainstTheServersQuantity(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	f.receive(t, f.outletA, f.productID, 10)

	// Till B's sale reaches the server before till A's count does.
	_, err := f.push(ctx, f.tillB, movement(newUUID(t), f.productID, stock.ReasonSale, -1))
	require.NoError(t, err)

	count := movement(newUUID(t), f.productID, stock.ReasonCount, 0)
	count.CountedQty = ptr(int64(7))
	count.BasisSeq = ptr(int64(1))
	applied, err := f.push(ctx, f.tillA, count)
	require.NoError(t, err)
	require.EqualValues(t, -2, applied.Delta, "9 on the server, 7 on the shelf")
	require.EqualValues(t, 7, applied.BalanceAfter)
	require.EqualValues(t, 7, f.qty(t, f.outletA, f.productID))

	_, err = f.push(ctx, f.tillB, movement(newUUID(t), f.productID, stock.ReasonSale, -1))
	require.NoError(t, err)

	retried, err := f.push(ctx, f.tillA, count)
	require.NoError(t, err)
	require.EqualValues(t, -2, retried.Delta, "a retry is not a second count")
	require.EqualValues(t, 6, f.qty(t, f.outletA, f.productID))
	sum, _ := f.ledger(t, f.outletA, f.productID)
	require.EqualValues(t, 6, sum)
}

func TestMovementsThatContradictTheirReasonAreRefused(t *testing.T) {
	f := setup(t)
	ctx := context.Background()

	cases := map[string]stock.DeviceMovement{
		"a sale that adds stock":            movement(newUUID(t), f.productID, stock.ReasonSale, 1),
		"a delivery that removes stock":     movement(newUUID(t), f.productID, stock.ReasonReceived, -1),
		"a correction that changes nothing": movement(newUUID(t), f.productID, stock.ReasonCorrection, 0),
		"a count with no counted quantity":  movement(newUUID(t), f.productID, stock.ReasonCount, 0),
		"a transfer from a till":            movement(newUUID(t), f.productID, stock.ReasonTransferIn, 1),
		"a product that is not a UUID":      movement(newUUID(t), "p_1726000000000", stock.ReasonSale, -1),
	}
	withCount := movement(newUUID(t), f.productID, stock.ReasonSale, -1)
	withCount.CountedQty = ptr(int64(3))
	cases["a sale carrying a counted quantity"] = withCount

	for name, m := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := f.push(ctx, f.tillA, m)
			require.Equal(t, "schema_rejected", rejectionCode(err), "%v", err)
		})
	}

	// Another merchant's product is refused by the database itself.
	_, err := f.push(ctx, f.tillA, movement(newUUID(t), f.otherProductID, stock.ReasonSale, -1))
	var pgErr *pgconn.PgError
	require.ErrorAs(t, err, &pgErr)
	require.Equal(t, "23503", pgErr.Code)

	var n int
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT count(*) FROM stock_movements`).Scan(&n))
	require.Zero(t, n)
}

func TestATransferMovesStockBetweenBranchesInOneStep(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	actor := stock.Actor{Name: "Owner"}
	f.receive(t, f.outletA, f.productID, 5)

	require.NoError(t, f.svc.Transfer(ctx, f.tenantID, actor, stock.Transfer{
		FromOutletID: f.outletA, ToOutletID: f.outletB, ProductID: f.productID, Quantity: 3,
	}))
	require.EqualValues(t, 2, f.qty(t, f.outletA, f.productID))
	require.EqualValues(t, 3, f.qty(t, f.outletB, f.productID))

	var refs int
	require.NoError(t, f.db.Owner.QueryRow(ctx, `
		SELECT count(DISTINCT ref_id) FROM stock_movements
		WHERE reason IN ('transferIn', 'transferOut')`).Scan(&refs))
	require.Equal(t, 1, refs, "both halves share one reference")

	err := f.svc.Transfer(ctx, f.tenantID, actor, stock.Transfer{
		FromOutletID: f.outletA, ToOutletID: f.outletA, ProductID: f.productID, Quantity: 1,
	})
	errs, ok := validation.As(err)
	require.True(t, ok, "%v", err)
	require.Contains(t, errs, "to_outlet")

	err = f.svc.Transfer(ctx, f.tenantID, actor, stock.Transfer{
		FromOutletID: f.outletA, ToOutletID: f.otherOutlet, ProductID: f.productID, Quantity: 1,
	})
	errs, ok = validation.As(err)
	require.True(t, ok, "another merchant's branch is not a destination: %v", err)
	require.Contains(t, errs, "to_outlet")
	require.EqualValues(t, 2, f.qty(t, f.outletA, f.productID))
}

func TestABackofficeCountAndAdjustmentsValidateBeforeWriting(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	actor := stock.Actor{Name: "Owner"}

	err := f.svc.Adjust(ctx, f.tenantID, actor, stock.Adjustment{
		OutletID: f.outletA, ProductID: f.productID, Kind: stock.KindWaste, Quantity: 0,
	})
	errs, ok := validation.As(err)
	require.True(t, ok)
	require.Contains(t, errs, "quantity")

	require.NoError(t, f.svc.Adjust(ctx, f.tenantID, actor, stock.Adjustment{
		OutletID: f.outletA, ProductID: f.productID, Kind: stock.KindWaste, Quantity: 4,
	}))
	require.EqualValues(t, -4, f.qty(t, f.outletA, f.productID))

	require.NoError(t, f.svc.Count(ctx, f.tenantID, actor, f.outletA, f.productID, 12, nil))
	require.EqualValues(t, 12, f.qty(t, f.outletA, f.productID))

	detail, err := f.svc.Detail(ctx, f.tenantID, f.outletA, f.productID)
	require.NoError(t, err)
	require.EqualValues(t, 12, *detail.Qty)
	require.Len(t, detail.Ledger, 2)
	require.Equal(t, stock.ReasonCount, detail.Ledger[0].Reason)
	require.EqualValues(t, 16, detail.Ledger[0].Delta)

	require.ErrorIs(t, f.svc.Adjust(ctx, f.tenantID, actor, stock.Adjustment{
		OutletID: f.otherOutlet, ProductID: f.productID, Kind: stock.KindReceived, Quantity: 1,
	}), stock.ErrNotFound)
}

func TestStockIsInvisibleToAnotherMerchant(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	f.receive(t, f.outletA, f.productID, 3)
	_, err := f.push(ctx, f.tillA, movement(newUUID(t), f.productID, stock.ReasonSale, -1))
	require.NoError(t, err)

	_, err = f.svc.Levels(ctx, f.otherTenantID, f.outletA, "")
	require.ErrorIs(t, err, stock.ErrNotFound)
	alerts, err := f.svc.Alerts(ctx, f.otherTenantID)
	require.NoError(t, err)
	require.Empty(t, alerts)
	_, err = f.svc.Detail(ctx, f.otherTenantID, f.outletA, f.productID)
	require.ErrorIs(t, err, stock.ErrNotFound)

	for _, entity := range []string{"outlet_stock", "stock_movements"} {
		page, err := f.feed.PullOutlet(ctx, f.otherTenantID, f.outletA, entity, 0, 100)
		require.NoError(t, err)
		require.Empty(t, page.Rows, entity)
	}

	// With no tenant context at all, the application credential reads nothing.
	for _, table := range []string{"outlet_stock", "stock_movements"} {
		var n int
		require.NoError(t, f.db.Pools.Tenant.QueryRow(ctx, "SELECT count(*) FROM "+table).Scan(&n))
		require.Zero(t, n, table)
	}

	// And a movement cannot be claimed across merchants by reusing its id.
	var claimed string
	require.NoError(t, f.db.Owner.QueryRow(ctx, `SELECT id::text FROM stock_movements WHERE source = 'device'`).Scan(&claimed))
	_, err = f.push(ctx, f.tillX, movement(claimed, f.otherProductID, stock.ReasonSale, -1))
	require.Error(t, err)
	require.EqualValues(t, 2, f.qty(t, f.outletA, f.productID))
}

func TestOutletFeedsPageAndCountOneBranchOnly(t *testing.T) {
	f := setup(t)
	ctx := context.Background()

	_, err := f.push(ctx, f.tillA, movement(newUUID(t), f.productID, stock.ReasonReceived, 4))
	require.NoError(t, err)
	_, err = f.push(ctx, f.tillA, movement(newUUID(t), f.product2ID, stock.ReasonReceived, 2))
	require.NoError(t, err)
	_, err = f.push(ctx, f.tillC, movement(newUUID(t), f.productID, stock.ReasonReceived, 9))
	require.NoError(t, err)

	a, err := f.feed.PullOutlet(ctx, f.tenantID, f.outletA, "stock_movements", 0, 100)
	require.NoError(t, err)
	require.Len(t, a.Rows, 2)
	require.EqualValues(t, 2, a.NextSeq)
	for _, raw := range a.Rows {
		var row map[string]any
		require.NoError(t, json.Unmarshal(raw, &row))
		require.Equal(t, f.outletA, row["outlet_id"])
		require.NotNil(t, row["stock_seq"])
	}

	b, err := f.feed.PullOutlet(ctx, f.tenantID, f.outletB, "outlet_stock", 0, 100)
	require.NoError(t, err)
	require.Len(t, b.Rows, 1)
	require.EqualValues(t, 1, b.NextSeq, "branch B has its own counter")

	cursors, err := f.feed.DeviceCursors(ctx, f.tenantID, f.outletA)
	require.NoError(t, err)
	require.EqualValues(t, 2, cursors["stock_movements"])
	require.EqualValues(t, 2, cursors["outlet_stock"])

	_, err = f.feed.Pull(ctx, f.tenantID, "outlet_stock", 0, 100)
	require.ErrorIs(t, err, syncfeed.ErrOutletRequired)
}

func TestReconcileRepairsOnlyARowThatDrifted(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	f.receive(t, f.outletA, f.productID, 8)
	f.receive(t, f.outletA, f.product2ID, 3)

	repaired, err := f.svc.Reconcile(ctx, f.tenantID)
	require.NoError(t, err)
	require.Zero(t, repaired, "a projection kept in the movement's transaction never drifts")

	var before int64
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`SELECT sync_seq FROM outlet_stock WHERE outlet_id = $1 AND product_id = $2`, f.outletA, f.productID).Scan(&before))
	_, err = f.db.Owner.Exec(ctx, `UPDATE outlet_stock SET qty_on_hand = 999 WHERE outlet_id = $1 AND product_id = $2`, f.outletA, f.productID)
	require.NoError(t, err)

	repaired, err = f.svc.Reconcile(ctx, f.tenantID)
	require.NoError(t, err)
	require.Equal(t, 1, repaired)
	require.EqualValues(t, 8, f.qty(t, f.outletA, f.productID))

	var after int64
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`SELECT sync_seq FROM outlet_stock WHERE outlet_id = $1 AND product_id = $2`, f.outletA, f.productID).Scan(&after))
	require.Greater(t, after, before, "the repair is numbered, so tills pull it")

	repaired, err = f.svc.Reconcile(ctx, f.tenantID)
	require.NoError(t, err)
	require.Zero(t, repaired)
}

// Transfers lock two branches, sales one, adjustments one — in every
// combination at once. A fixed lock order means none of them deadlocks, and
// the ledger and the projection agree afterwards.
func TestConcurrentWritersAcrossBranchesNeitherDeadlockNorDrift(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	actor := stock.Actor{Name: "Owner"}
	for _, outlet := range []string{f.outletA, f.outletB} {
		for _, product := range []string{f.productID, f.product2ID} {
			f.receive(t, outlet, product, 100)
		}
	}

	var wg sync.WaitGroup
	failures := make(chan error, 200)
	run := func(fn func() error) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := fn(); err != nil {
				failures <- err
			}
		}()
	}
	for i := 0; i < 20; i++ {
		product := f.productID
		if i%2 == 1 {
			product = f.product2ID
		}
		run(func() error {
			return f.svc.Transfer(ctx, f.tenantID, actor, stock.Transfer{FromOutletID: f.outletA, ToOutletID: f.outletB, ProductID: product, Quantity: 1})
		})
		run(func() error {
			return f.svc.Transfer(ctx, f.tenantID, actor, stock.Transfer{FromOutletID: f.outletB, ToOutletID: f.outletA, ProductID: product, Quantity: 2})
		})
		saleA := movement(newUUID(t), product, stock.ReasonSale, -1)
		saleC := movement(newUUID(t), product, stock.ReasonSale, -1)
		run(func() error { _, err := f.push(ctx, f.tillA, saleA); return err })
		run(func() error { _, err := f.push(ctx, f.tillC, saleC); return err })
	}
	wg.Wait()
	close(failures)
	for err := range failures {
		require.NoError(t, err)
	}

	var total int64
	for _, outlet := range []string{f.outletA, f.outletB} {
		for _, product := range []string{f.productID, f.product2ID} {
			sum, _ := f.ledger(t, outlet, product)
			require.Equal(t, sum, f.qty(t, outlet, product))
			total += sum
		}
	}
	require.EqualValues(t, 400-40, total, "transfers conserve the chain; only the 40 sales left it")
	repaired, err := f.svc.Reconcile(ctx, f.tenantID)
	require.NoError(t, err)
	require.Zero(t, repaired)
}
