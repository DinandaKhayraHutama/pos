package tables_test

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/tables"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
)

type fixture struct {
	db   pgtest.DB
	feed *syncfeed.Service
	svc  *tables.Service

	tenantID, otherTenantID       string
	outletA, outletB, otherOutlet string
	tillA, tillB, tillC, tillX    devices.Binding
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
	f.svc = tables.NewService(db.Pools, f.feed)

	scan := func(dst *string, sql string, args ...any) {
		t.Helper()
		require.NoError(t, db.Owner.QueryRow(ctx, sql, args...).Scan(dst))
	}
	scan(&f.tenantID, `INSERT INTO tenants (name, slug) VALUES ('Warung Meja', gen_random_uuid()::text) RETURNING id::text`)
	scan(&f.otherTenantID, `INSERT INTO tenants (name, slug) VALUES ('Warung Lain', gen_random_uuid()::text) RETURNING id::text`)
	scan(&f.outletA, `INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Kemang') RETURNING id::text`, f.tenantID)
	scan(&f.outletB, `INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Bintaro') RETURNING id::text`, f.tenantID)
	scan(&f.otherOutlet, `INSERT INTO outlets (tenant_id, name) VALUES ($1, 'Rahasia') RETURNING id::text`, f.otherTenantID)

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

func uuid() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func (f *fixture) table(t *testing.T, outletID, name string) string {
	t.Helper()
	id, err := f.svc.Save(context.Background(), f.tenantID, tables.Table{
		OutletID: outletID, Name: name, Area: "Lantai 1", Capacity: 4, Active: true,
	})
	require.NoError(t, err)
	return id
}

type status struct {
	status    string
	contested bool
	seq       int64
	deleted   bool
}

func (f *fixture) status(t *testing.T, tableID string) status {
	t.Helper()
	var s status
	require.NoError(t, f.db.Owner.QueryRow(context.Background(), `
		SELECT status, contested, sync_seq, deleted_at IS NOT NULL FROM table_status WHERE table_id = $1`,
		tableID).Scan(&s.status, &s.contested, &s.seq, &s.deleted))
	return s
}

func (f *fixture) tableSeq(t *testing.T, tableID string) int64 {
	t.Helper()
	var seq int64
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		`SELECT sync_seq FROM tables WHERE id = $1`, tableID).Scan(&seq))
	return seq
}

func (f *fixture) events(t *testing.T) int64 {
	t.Helper()
	var n int64
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		`SELECT count(*) FROM table_status_events`).Scan(&n))
	return n
}

// push is what the ingest path does for one pushed row: numbered inside its
// own transaction, published after commit.
func (f *fixture) push(ctx context.Context, b devices.Binding, in tables.DeviceEvent) (tables.Applied, error) {
	var out tables.Applied
	err := f.feed.Write(ctx, b.Tenant.ID, func(ctx context.Context, w *syncfeed.Writer) error {
		var err error
		out, err = f.svc.RecordFromDevice(ctx, w, b, in)
		return err
	})
	return out, err
}

var clientSequence atomic.Int64

func event(tableID, status string, basis, atMs int64) tables.DeviceEvent {
	return tables.DeviceEvent{
		ID: uuid(), Revision: 1, TableID: tableID, Status: status,
		BasisSeq: basis, ClientSeq: clientSequence.Add(1), OccurredAtMs: atMs, EmployeeName: "Siti",
	}
}

func refused(t *testing.T, err error, code string) {
	t.Helper()
	var r *tables.Rejection
	require.True(t, errors.As(err, &r), "expected a rejection, got %v", err)
	require.Equal(t, code, r.Code)
}

func TestANewTableIsPublishedWithItsStatusToItsBranchOnly(t *testing.T) {
	f := setup(t)
	ctx := context.Background()

	id := f.table(t, f.outletA, "Meja 1")
	s := f.status(t, id)
	require.Equal(t, tables.StatusAvailable, s.status)
	require.False(t, s.contested)
	require.Positive(t, s.seq)
	require.Positive(t, f.tableSeq(t, id))

	for _, entity := range []string{tables.DefinitionEntity, tables.StatusEntity} {
		page, err := f.feed.PullOutlet(ctx, f.tenantID, f.outletA, entity, 0, 100)
		require.NoError(t, err)
		require.Len(t, page.Rows, 1, entity)

		page, err = f.feed.PullOutlet(ctx, f.tenantID, f.outletB, entity, 0, 100)
		require.NoError(t, err)
		require.Empty(t, page.Rows, "%s must not reach another branch", entity)
	}

	list, err := f.svc.List(ctx, f.tenantID, f.outletA)
	require.NoError(t, err)
	require.Len(t, list, 1)
	require.Equal(t, tables.StatusAvailable, list[0].Status)

	// Row-level security makes another merchant's branch look absent.
	_, err = f.svc.List(ctx, f.otherTenantID, f.outletA)
	require.ErrorIs(t, err, tables.ErrNotFound)
	_, err = f.svc.Get(ctx, f.otherTenantID, id)
	require.ErrorIs(t, err, tables.ErrNotFound)
}

func TestAnEventMadeAgainstTheCurrentStatusApplies(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	id := f.table(t, f.outletA, "Meja 1")

	s0 := f.status(t, id)
	seated, err := f.push(ctx, f.tillA, event(id, tables.StatusOccupied, s0.seq, 1_000))
	require.NoError(t, err)
	require.Equal(t, tables.OutcomeApplied, seated.Outcome)
	require.False(t, seated.Contested)
	require.True(t, seated.Inserted)
	require.Greater(t, seated.StatusSeq, s0.seq)

	s1 := f.status(t, id)
	require.Equal(t, tables.StatusOccupied, s1.status)
	require.Equal(t, seated.StatusSeq, s1.seq)

	// Till B pulled that and clears the table. Its clock being behind does not
	// matter: it saw the status it is changing.
	cleared, err := f.push(ctx, f.tillB, event(id, tables.StatusAvailable, s1.seq, 900))
	require.NoError(t, err)
	require.Equal(t, tables.OutcomeApplied, cleared.Outcome)
	require.False(t, cleared.Contested)
	require.Equal(t, tables.StatusAvailable, f.status(t, id).status)
}

func TestTwoTillsRacingOneTableMarkItContestedAndTheLaterChangeWins(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	id := f.table(t, f.outletA, "Meja 1")

	first, err := f.push(ctx, f.tillA, event(id, tables.StatusOccupied, f.status(t, id).seq, 1_000))
	require.NoError(t, err)

	// Both tills act offline against `first`. A reaches the server first.
	a, err := f.push(ctx, f.tillA, event(id, tables.StatusReserved, first.StatusSeq, 2_000))
	require.NoError(t, err)
	require.Equal(t, tables.OutcomeApplied, a.Outcome)
	require.False(t, a.Contested)

	// B's change was made earlier than A's, against a status A has since moved.
	b, err := f.push(ctx, f.tillB, event(id, tables.StatusAvailable, first.StatusSeq, 1_500))
	require.NoError(t, err)
	require.Equal(t, tables.OutcomeSuperseded, b.Outcome)
	require.True(t, b.Contested)

	s := f.status(t, id)
	require.Equal(t, tables.StatusReserved, s.status, "the later change is kept")
	require.True(t, s.contested, "and the table says two tills raced")
	require.Equal(t, b.StatusSeq, s.seq, "a superseded event still republishes the mark")

	// A later change by B, still against the old status, wins by time.
	c, err := f.push(ctx, f.tillB, event(id, tables.StatusOccupied, first.StatusSeq, 3_000))
	require.NoError(t, err)
	require.Equal(t, tables.OutcomeApplied, c.Outcome)
	require.True(t, c.Contested)
	require.Equal(t, tables.StatusOccupied, f.status(t, id).status)

	// A till that pulled the contested status settles it.
	d, err := f.push(ctx, f.tillA, event(id, tables.StatusAvailable, c.StatusSeq, 3_500))
	require.NoError(t, err)
	require.Equal(t, tables.OutcomeApplied, d.Outcome)
	require.False(t, d.Contested)
	s = f.status(t, id)
	require.Equal(t, tables.StatusAvailable, s.status)
	require.False(t, s.contested)

	// The same instant on both clocks: the event id decides, and it decides the
	// same way on every server.
	tie := f.table(t, f.outletA, "Meja 2")
	base, err := f.push(ctx, f.tillA, event(tie, tables.StatusOccupied, f.status(t, tie).seq, 5_000))
	require.NoError(t, err)
	current, err := f.push(ctx, f.tillA, event(tie, tables.StatusReserved, base.StatusSeq, 6_000))
	require.NoError(t, err)
	var currentID string
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`SELECT event_id::text FROM table_status WHERE table_id = $1`, tie).Scan(&currentID))
	racing := event(tie, tables.StatusAvailable, base.StatusSeq, 6_000)
	raced, err := f.push(ctx, f.tillB, racing)
	require.NoError(t, err)
	require.True(t, raced.Contested)
	if racing.ID > currentID {
		require.Equal(t, tables.OutcomeApplied, raced.Outcome)
	} else {
		require.Equal(t, tables.OutcomeSuperseded, raced.Outcome)
	}
	require.Greater(t, raced.StatusSeq, current.StatusSeq)
}

func TestADevicesOwnFollowUpIsNotARace(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	id := f.table(t, f.outletA, "Meja 1")
	base := f.status(t, id).seq

	// Seated, cleared, and reserved again, all before the till next pulls.
	for i, change := range []struct {
		status string
		atMs   int64
	}{
		{tables.StatusOccupied, 1_000},
		{tables.StatusAvailable, 2_000},
		// Even with the tablet's clock stepping backwards.
		{tables.StatusReserved, 500},
	} {
		applied, err := f.push(ctx, f.tillA, event(id, change.status, base, change.atMs))
		require.NoError(t, err)
		require.Equal(t, tables.OutcomeApplied, applied.Outcome, "change %d", i)
		require.False(t, applied.Contested, "change %d", i)
		require.Equal(t, change.status, f.status(t, id).status)
	}
}

func TestAnExactRetryIsAcceptedWithWhatWasFirstRecorded(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	id := f.table(t, f.outletA, "Meja 1")

	in := event(id, tables.StatusOccupied, f.status(t, id).seq, 1_000)
	first, err := f.push(ctx, f.tillA, in)
	require.NoError(t, err)

	// A re-send from the dead-letter table carries a newer revision.
	in.Revision = 2
	again, err := f.push(ctx, f.tillA, in)
	require.NoError(t, err)
	require.Equal(t, first.StatusSeq, again.StatusSeq)
	require.Equal(t, first.Outcome, again.Outcome)
	require.False(t, again.Inserted)
	require.EqualValues(t, 1, f.events(t))
	require.Equal(t, first.StatusSeq, f.status(t, id).seq, "a retry publishes nothing")

	changed := in
	changed.Status = tables.StatusReserved
	_, err = f.push(ctx, f.tillA, changed)
	refused(t, err, "duplicate")

	_, err = f.push(ctx, f.tillB, in)
	refused(t, err, "duplicate")
	require.EqualValues(t, 1, f.events(t))
}

func TestEventsOutsideTheTillsBranchOrContractAreRefused(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	id := f.table(t, f.outletA, "Meja 1")
	before := f.status(t, id)

	_, err := f.push(ctx, f.tillC, event(id, tables.StatusOccupied, before.seq, 1_000))
	refused(t, err, "schema_rejected")
	_, err = f.push(ctx, f.tillX, event(id, tables.StatusOccupied, before.seq, 1_000))
	refused(t, err, "schema_rejected")
	_, err = f.push(ctx, f.tillA, event(uuid(), tables.StatusOccupied, before.seq, 1_000))
	refused(t, err, "schema_rejected")

	for name, mutate := range map[string]func(*tables.DeviceEvent){
		"unknown status":          func(e *tables.DeviceEvent) { e.Status = "dirty" },
		"negative basis":          func(e *tables.DeviceEvent) { e.BasisSeq = -1 },
		"future basis":            func(e *tables.DeviceEvent) { e.BasisSeq = before.seq + 1 },
		"missing client sequence": func(e *tables.DeviceEvent) { e.ClientSeq = 0 },
		"id not a uuid":           func(e *tables.DeviceEvent) { e.ID = "table-1" },
		"table no uuid":           func(e *tables.DeviceEvent) { e.TableID = "table_123" },
		"time too large":          func(e *tables.DeviceEvent) { e.OccurredAtMs = 1 << 62 },
	} {
		in := event(id, tables.StatusOccupied, before.seq, 1_000)
		mutate(&in)
		_, err := f.push(ctx, f.tillA, in)
		refused(t, err, "schema_rejected")
		_ = name
	}

	require.EqualValues(t, 0, f.events(t))
	require.Equal(t, before, f.status(t, id))
}

func TestLateEarlierEventFromSameTillCannotUndoItsNewerStatus(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	id := f.table(t, f.outletA, "Meja 1")
	basis := f.status(t, id).seq
	older := event(id, tables.StatusOccupied, basis, 2000)
	newer := event(id, tables.StatusAvailable, basis, 1000) // clock went backwards
	_, err := f.push(ctx, f.tillA, newer)
	require.NoError(t, err)
	late, err := f.push(ctx, f.tillA, older)
	require.NoError(t, err)
	require.Equal(t, tables.OutcomeSuperseded, late.Outcome)
	require.False(t, late.Contested)
	require.Equal(t, tables.StatusAvailable, f.status(t, id).status)
	retry, err := f.push(ctx, f.tillA, older)
	require.NoError(t, err)
	require.Equal(t, late.StatusSeq, retry.StatusSeq)
	require.False(t, retry.Inserted)
	require.EqualValues(t, 2, f.events(t))
}

func TestTheBackofficeValidatesRetiresAndTombstones(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	id := f.table(t, f.outletA, "Meja 1")

	fieldErrors := func(err error) validation.Errors {
		t.Helper()
		errs, ok := validation.As(err)
		require.True(t, ok, "expected field errors, got %v", err)
		return errs
	}

	_, err := f.svc.Save(ctx, f.tenantID, tables.Table{OutletID: f.outletA, Name: "meja 1", Capacity: 2})
	require.Contains(t, fieldErrors(err), "name", "names are unique per branch, whatever the case")
	_, err = f.svc.Save(ctx, f.tenantID, tables.Table{OutletID: f.outletA, Name: "Meja 2", Capacity: 0})
	require.Contains(t, fieldErrors(err), "capacity")
	x := -1
	_, err = f.svc.Save(ctx, f.tenantID, tables.Table{OutletID: f.outletA, Name: "Meja 2", Capacity: 2, PosX: &x})
	require.Contains(t, fieldErrors(err), "pos_x")

	// Another branch may have its own Meja 1.
	_, err = f.svc.Save(ctx, f.tenantID, tables.Table{OutletID: f.outletB, Name: "Meja 1", Capacity: 2, Active: true})
	require.NoError(t, err)

	// A table never moves branch, and another merchant cannot touch it.
	_, err = f.svc.Save(ctx, f.tenantID, tables.Table{ID: id, OutletID: f.outletB, Name: "Meja 1", Capacity: 2})
	require.ErrorIs(t, err, tables.ErrNotFound)
	_, err = f.svc.Save(ctx, f.otherTenantID, tables.Table{ID: id, OutletID: f.outletA, Name: "Meja 1", Capacity: 2})
	require.ErrorIs(t, err, tables.ErrNotFound)

	// Retiring twice publishes once.
	require.NoError(t, f.svc.SetActive(ctx, f.tenantID, id, false))
	retired := f.tableSeq(t, id)
	require.NoError(t, f.svc.SetActive(ctx, f.tenantID, id, false))
	require.Equal(t, retired, f.tableSeq(t, id))

	// A retired table still takes status changes: a seated guest must be cleared.
	_, err = f.push(ctx, f.tillA, event(id, tables.StatusAvailable, f.status(t, id).seq, 1_000))
	require.NoError(t, err)

	// Deleting tombstones the table and its status together, so both feeds tell
	// the till, and the till can no longer write it.
	statusBefore := f.status(t, id).seq
	require.NoError(t, f.svc.Delete(ctx, f.tenantID, id))
	require.Greater(t, f.tableSeq(t, id), retired)
	s := f.status(t, id)
	require.True(t, s.deleted)
	require.Greater(t, s.seq, statusBefore)

	_, err = f.push(ctx, f.tillA, event(id, tables.StatusOccupied, s.seq, 2_000))
	refused(t, err, "schema_rejected")
	_, err = f.svc.Get(ctx, f.tenantID, id)
	require.ErrorIs(t, err, tables.ErrNotFound)
	require.ErrorIs(t, f.svc.Delete(ctx, f.tenantID, id), tables.ErrNotFound)
	list, err := f.svc.List(ctx, f.tenantID, f.outletA)
	require.NoError(t, err)
	require.Empty(t, list)

	// The name is free again once the table is gone.
	_, err = f.svc.Save(ctx, f.tenantID, tables.Table{OutletID: f.outletA, Name: "Meja 1", Capacity: 2, Active: true})
	require.NoError(t, err)
}

func TestConcurrentChangesAndEditsNeitherDeadlockNorLoseAnEvent(t *testing.T) {
	f := setup(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	ids := make([]string, 4)
	for i := range ids {
		ids[i] = f.table(t, f.outletA, fmt.Sprintf("Meja %d", i+1))
	}
	statuses := []string{tables.StatusOccupied, tables.StatusReserved, tables.StatusAvailable}

	const perTill = 20
	var wg sync.WaitGroup
	errs := make(chan error, 3*perTill*2)
	for w, till := range []devices.Binding{f.tillA, f.tillB} {
		wg.Add(1)
		go func(w int, till devices.Binding) {
			defer wg.Done()
			for i := 0; i < perTill; i++ {
				in := event(ids[(i+w)%len(ids)], statuses[i%len(statuses)], 0, int64(i*10+w))
				if _, err := f.push(ctx, till, in); err != nil {
					errs <- err
				}
			}
		}(w, till)
	}
	// The Backoffice edits and retires the same tables meanwhile.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < perTill; i++ {
			k := i % len(ids)
			if err := f.svc.SetActive(ctx, f.tenantID, ids[k], i%2 == 1); err != nil {
				errs <- err
			}
			if _, err := f.svc.Save(ctx, f.tenantID, tables.Table{
				ID: ids[k], OutletID: f.outletA, Name: fmt.Sprintf("Meja %d", k+1), Capacity: 2 + i%3, Active: true,
			}); err != nil {
				errs <- err
			}
		}
	}()
	wg.Wait()
	close(errs)
	for err := range errs {
		require.NoError(t, err)
	}

	require.EqualValues(t, 2*perTill, f.events(t))
	for _, id := range ids {
		var newest int64
		require.NoError(t, f.db.Owner.QueryRow(ctx,
			`SELECT max(status_seq) FROM table_status_events WHERE table_id = $1`, id).Scan(&newest))
		require.Equal(t, newest, f.status(t, id).seq, "the projection carries its newest event's number")
	}
	var distinct int64
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`SELECT count(DISTINCT status_seq) FROM table_status_events`).Scan(&distinct))
	require.EqualValues(t, 2*perTill, distinct, "no two events share a number")
}
