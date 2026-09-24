// Package tables owns a branch's floor plan and the live status of each table.
//
// A table's definition (name, area, seats, place on the plan) is a Backoffice
// write published to every till in the branch. Its status is written by tills,
// one event per change, and the projection every till pulls back is decided
// here by one rule:
//
//   - A client_seq older than one already recorded for this device/table is
//     superseded, regardless of device clock or network delivery order.
//   - An event made against the table's current status sequence applies and
//     clears any contested mark: its till saw everything before it.
//   - An event following the same device's own latest write applies too. A
//     till that seats a guest and clears the table before it next pulls has
//     raced nobody; the mark is left as it was.
//   - A table no till has ever set has nothing to race.
//   - Anything else raced another till. The later occurred_at_ms wins (the
//     event id breaks a tie), and either way the table is marked contested,
//     so the till shows staff that two people acted on it instead of
//     silently picking one.
//
// Locks follow one order everywhere: rows before counters, and counters in
// registry order (tables before table_status). A device event locks the status
// row, then the branch's table_status counter; a Backoffice write locks the
// table row, then its status row, then the counters. Nothing locks the
// merchant.
package tables

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/devices"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

const (
	StatusAvailable = "available"
	StatusOccupied  = "occupied"
	StatusReserved  = "reserved"

	// OutcomeApplied means the projection took the event's status.
	OutcomeApplied = "applied"
	// OutcomeSuperseded means another till's later write won; the event is
	// kept for audit and the table is marked contested.
	OutcomeSuperseded = "superseded"

	// DefinitionEntity and StatusEntity are the two pulled feeds.
	DefinitionEntity = "tables"
	StatusEntity     = "table_status"
	// EventEntity is the push feed name of a status change.
	EventEntity = "table_status_events"
)

const (
	maxNameLength           = 60
	maxAreaLength           = 60
	maxEmployeeLength       = 120
	maxCapacity             = 100
	maxPosition             = 10000
	maxMillis         int64 = 253402300799999 // last millisecond of year 9999
)

var ErrNotFound = errors.New("tables: no such outlet or table")

// Rejection is a pushed event refused for what it says. It maps onto the push
// contract's closed set of row codes.
type Rejection struct {
	Code    string
	Message string
}

func (r *Rejection) Error() string { return r.Message }

func reject(code, message string) error { return &Rejection{Code: code, Message: message} }

// Table is one table with its live status.
type Table struct {
	ID        string
	OutletID  string
	Name      string
	Area      string
	Capacity  int
	PosX      *int
	PosY      *int
	SortOrder int
	Active    bool

	// Read-only, from the status projection.
	Status     string
	Contested  bool
	StatusAtMs int64
	StatusBy   string
	StatusSeq  int64
}

type Service struct {
	pools pg.Pools
	feed  *syncfeed.Service
}

func NewService(pools pg.Pools, feed *syncfeed.Service) *Service {
	return &Service{pools: pools, feed: feed}
}

const selectTable = `
	SELECT t.id::text, t.outlet_id::text, t.name, t.area, t.capacity, t.pos_x, t.pos_y,
	       t.sort_order, t.active,
	       COALESCE(s.status, 'available'), COALESCE(s.contested, false),
	       COALESCE(s.occurred_at_ms, 0), COALESCE(s.employee_name, ''), COALESCE(s.sync_seq, 0)
	FROM tables t
	LEFT JOIN table_status s ON s.tenant_id = t.tenant_id AND s.table_id = t.id`

func scanTable(row pgx.CollectableRow) (Table, error) {
	var t Table
	err := row.Scan(&t.ID, &t.OutletID, &t.Name, &t.Area, &t.Capacity, &t.PosX, &t.PosY,
		&t.SortOrder, &t.Active, &t.Status, &t.Contested, &t.StatusAtMs, &t.StatusBy, &t.StatusSeq)
	return t, err
}

// List returns every live table at one branch, inactive ones included, with
// its status. ErrNotFound when the branch is not the merchant's.
func (s *Service) List(ctx context.Context, tenantID, outletID string) ([]Table, error) {
	if !validation.UUID(outletID) {
		return nil, ErrNotFound
	}

	var out []Table
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		if err := liveOutlet(ctx, tx, tenantID, outletID); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, selectTable+`
			WHERE t.tenant_id = $1 AND t.outlet_id = $2 AND t.deleted_at IS NULL
			ORDER BY t.area, t.sort_order, lower(t.name)`, tenantID, outletID)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, scanTable)
		return err
	})
	return out, err
}

// Get returns one live table.
func (s *Service) Get(ctx context.Context, tenantID, id string) (Table, error) {
	if !validation.UUID(id) {
		return Table{}, ErrNotFound
	}

	var out Table
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, selectTable+`
			WHERE t.tenant_id = $1 AND t.id = $2 AND t.deleted_at IS NULL`, tenantID, id)
		if err != nil {
			return err
		}
		out, err = pgx.CollectOneRow(rows, scanTable)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	return out, err
}

func liveOutlet(ctx context.Context, tx pgx.Tx, tenantID, outletID string) error {
	var live bool
	if err := tx.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM outlets WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL)`,
		tenantID, outletID).Scan(&live); err != nil {
		return err
	}
	if !live {
		return ErrNotFound
	}
	return nil
}

func validateTable(in *Table) error {
	in.Name = strings.TrimSpace(in.Name)
	in.Area = strings.TrimSpace(in.Area)

	errs := validation.Errors{}
	errs.Name("name", in.Name, maxNameLength)
	if utf8.RuneCountInString(in.Area) > maxAreaLength {
		errs.Add("area", "Area maksimal 60 karakter.")
	}
	if in.Capacity < 1 || in.Capacity > maxCapacity {
		errs.Add("capacity", "Jumlah kursi harus 1 sampai 100.")
	}
	if in.PosX != nil && (*in.PosX < 0 || *in.PosX > maxPosition) {
		errs.Add("pos_x", "Posisi harus 0 sampai 10000.")
	}
	if in.PosY != nil && (*in.PosY < 0 || *in.PosY > maxPosition) {
		errs.Add("pos_y", "Posisi harus 0 sampai 10000.")
	}
	return errs.Err()
}

var errNameTaken = validation.Errors{"name": "Nama meja ini sudah dipakai di outlet ini."}

// Save creates or updates a table and returns its id.
//
// A new table is published together with its status row, in one transaction,
// so no till ever holds a table without a status sequence to act against. A
// table stays in the branch it was created in.
func (s *Service) Save(ctx context.Context, tenantID string, in Table) (string, error) {
	if err := validateTable(&in); err != nil {
		return "", err
	}
	if !validation.UUID(in.OutletID) || (in.ID != "" && !validation.UUID(in.ID)) {
		return "", ErrNotFound
	}

	id := in.ID
	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if in.ID != "" {
			outlet, err := lockTable(ctx, w.Tx, tenantID, in.ID)
			if err != nil {
				return err
			}
			if outlet != in.OutletID {
				return ErrNotFound
			}
		} else if err := liveOutlet(ctx, w.Tx, tenantID, in.OutletID); err != nil {
			return err
		}

		seq, err := w.OutletSeqBlock(ctx, DefinitionEntity, in.OutletID, 1)
		if err != nil {
			return err
		}

		if in.ID != "" {
			_, err = w.Tx.Exec(ctx, `
				UPDATE tables
				SET name = $3, area = $4, capacity = $5, pos_x = $6, pos_y = $7,
				    sort_order = $8, active = $9, sync_seq = $10, updated_at = now()
				WHERE tenant_id = $1 AND id = $2`,
				tenantID, in.ID, in.Name, in.Area, in.Capacity, in.PosX, in.PosY,
				in.SortOrder, in.Active, seq)
			if isUnique(err, "tables_outlet_name_key") {
				return errNameTaken
			}
			return err
		}

		err = w.Tx.QueryRow(ctx, `
			INSERT INTO tables (tenant_id, outlet_id, name, area, capacity, pos_x, pos_y,
			                    sort_order, active, sync_seq)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
			RETURNING id::text`,
			tenantID, in.OutletID, in.Name, in.Area, in.Capacity, in.PosX, in.PosY,
			in.SortOrder, in.Active, seq).Scan(&id)
		if isUnique(err, "tables_outlet_name_key") {
			return errNameTaken
		}
		if err != nil {
			return err
		}

		statusSeq, err := w.OutletSeqBlock(ctx, StatusEntity, in.OutletID, 1)
		if err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx, `
			INSERT INTO table_status (tenant_id, table_id, outlet_id, sync_seq)
			VALUES ($1, $2, $3, $4)`, tenantID, id, in.OutletID, statusSeq)
		return err
	})
	if err != nil {
		return "", err
	}
	return id, nil
}

// SetActive enables or retires a table. A retired table keeps its status: one
// retired while a guest is seated still has to be cleared on the till.
func (s *Service) SetActive(ctx context.Context, tenantID, id string, active bool) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var outlet string
		var current bool
		err := w.Tx.QueryRow(ctx, `
			SELECT outlet_id::text, active FROM tables
			WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL
			FOR UPDATE`, tenantID, id).Scan(&outlet, &current)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		// Flipping a switch to where it already is must not wake every till in
		// the branch to pull a row that did not change.
		if err != nil || current == active {
			return err
		}

		seq, err := w.OutletSeqBlock(ctx, DefinitionEntity, outlet, 1)
		if err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx, `
			UPDATE tables SET active = $3, sync_seq = $4, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`, tenantID, id, active, seq)
		return err
	})
}

// Delete tombstones a table and its status together. Receipts keep the table's
// name, which they copied at checkout; its status history stays for audit.
func (s *Service) Delete(ctx context.Context, tenantID, id string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		outlet, err := lockTable(ctx, w.Tx, tenantID, id)
		if err != nil {
			return err
		}
		if _, err := w.Tx.Exec(ctx, `
			SELECT 1 FROM table_status WHERE tenant_id = $1 AND table_id = $2 FOR UPDATE`,
			tenantID, id); err != nil {
			return err
		}

		seq, err := w.OutletSeqBlock(ctx, DefinitionEntity, outlet, 1)
		if err != nil {
			return err
		}
		statusSeq, err := w.OutletSeqBlock(ctx, StatusEntity, outlet, 1)
		if err != nil {
			return err
		}

		if _, err := w.Tx.Exec(ctx, `
			UPDATE tables SET deleted_at = now(), sync_seq = $3, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`, tenantID, id, seq); err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx, `
			UPDATE table_status SET deleted_at = now(), sync_seq = $3, updated_at = now()
			WHERE tenant_id = $1 AND table_id = $2`, tenantID, id, statusSeq)
		return err
	})
}

func lockTable(ctx context.Context, tx pgx.Tx, tenantID, id string) (string, error) {
	var outlet string
	err := tx.QueryRow(ctx, `
		SELECT outlet_id::text FROM tables
		WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL
		FOR UPDATE`, tenantID, id).Scan(&outlet)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	return outlet, err
}

func isUnique(err error, constraint string) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505" && pgErr.ConstraintName == constraint
}

// DeviceEvent is a status change as a till pushes it (the TableStatusEvent
// schema).
type DeviceEvent struct {
	ID           string `json:"id"`
	Revision     int64  `json:"revision"`
	TableID      string `json:"table_id"`
	Status       string `json:"status"`
	BasisSeq     int64  `json:"basis_seq"`
	ClientSeq    int64  `json:"client_seq"`
	OccurredAtMs int64  `json:"occurred_at_ms"`
	EmployeeName string `json:"employee_name"`
}

// canonical is the form two pushes of one event are compared in. Revision is
// left out: an event is immutable, and one sent again from the till's
// dead-letter table carries a newer revision of the same facts.
func (e DeviceEvent) canonical() []byte {
	raw, _ := json.Marshal(struct {
		ID           string `json:"id"`
		TableID      string `json:"table_id"`
		Status       string `json:"status"`
		BasisSeq     int64  `json:"basis_seq"`
		ClientSeq    int64  `json:"client_seq"`
		OccurredAtMs int64  `json:"occurred_at_ms"`
		EmployeeName string `json:"employee_name"`
	}{e.ID, e.TableID, e.Status, e.BasisSeq, e.ClientSeq, e.OccurredAtMs, e.EmployeeName})
	return raw
}

// Applied is what one event did once recorded.
type Applied struct {
	// StatusSeq is table_status.sync_seq after the event: a snapshot at or past
	// it already reflects it.
	StatusSeq int64
	Outcome   string
	Contested bool
	Inserted  bool
}

func validateDevice(in DeviceEvent) error {
	bad := func(message string) error { return reject("schema_rejected", message) }
	if !validation.UUID(in.ID) || !validation.UUID(in.TableID) {
		return bad("A table status event needs a UUID id and table_id.")
	}
	switch in.Status {
	case StatusAvailable, StatusOccupied, StatusReserved:
	default:
		return bad("Unknown table status.")
	}
	if in.BasisSeq < 0 || in.ClientSeq < 1 {
		return bad("basis_seq must be nonnegative and client_seq must be positive.")
	}
	if in.OccurredAtMs < 0 || in.OccurredAtMs > maxMillis {
		return bad("occurred_at_ms is out of range.")
	}
	if utf8.RuneCountInString(in.EmployeeName) > maxEmployeeLength {
		return bad("employee_name is too long.")
	}
	return nil
}

// RecordFromDevice applies one pushed status change at the till's bound outlet.
//
// Identity comes from the token: the outlet and device are the binding's. A
// table outside that outlet, retired by a tombstone, or another merchant's
// (row-level security hides it) is refused. An exact retry from the same device
// is accepted with what was recorded the first time; the same id naming
// anything else is refused as a duplicate.
func (s *Service) RecordFromDevice(ctx context.Context, w *syncfeed.Writer, b devices.Binding, in DeviceEvent) (Applied, error) {
	in.ID = strings.ToLower(in.ID)
	in.TableID = strings.ToLower(in.TableID)
	in.EmployeeName = strings.TrimSpace(in.EmployeeName)
	if err := validateDevice(in); err != nil {
		return Applied{}, err
	}
	canonical := in.canonical()

	// Concurrent retries of one event queue here instead of racing to the
	// primary key, where the loser would read as a duplicate of itself.
	if _, err := w.Tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 72052))`, in.ID); err != nil {
		return Applied{}, err
	}

	var (
		previousDevice  string
		previousPayload []byte
		previous        Applied
	)
	err := w.Tx.QueryRow(ctx, `
		SELECT device_id::text, payload, status_seq, outcome, contested
		FROM table_status_events WHERE tenant_id = $1 AND id = $2`,
		b.Tenant.ID, in.ID).Scan(&previousDevice, &previousPayload,
		&previous.StatusSeq, &previous.Outcome, &previous.Contested)
	switch {
	case err == nil:
		if previousDevice != b.Device.ID {
			return Applied{}, reject("duplicate", "Event belongs to a different device.")
		}
		var stored DeviceEvent
		if json.Unmarshal(previousPayload, &stored) != nil || string(stored.canonical()) != string(canonical) {
			return Applied{}, reject("duplicate", "This identifier already names a different event.")
		}
		return previous, nil
	case !errors.Is(err, pgx.ErrNoRows):
		return Applied{}, err
	}

	var (
		currentAtMs      int64
		currentEvent     *string
		currentDevice    *string
		currentContested bool
		currentSeq       int64
	)
	err = w.Tx.QueryRow(ctx, `
		SELECT s.occurred_at_ms, s.event_id::text, s.device_id::text, s.contested, s.sync_seq
		FROM table_status s
		JOIN tables t ON t.tenant_id = s.tenant_id AND t.id = s.table_id
		WHERE s.tenant_id = $1 AND s.table_id = $2 AND s.outlet_id = $3
		  AND s.deleted_at IS NULL AND t.deleted_at IS NULL
		FOR UPDATE OF s`,
		b.Tenant.ID, in.TableID, b.Outlet.ID).Scan(&currentAtMs, &currentEvent, &currentDevice,
		&currentContested, &currentSeq)
	if errors.Is(err, pgx.ErrNoRows) {
		return Applied{}, reject("schema_rejected", "This table is not at this till's outlet.")
	}
	if err != nil {
		return Applied{}, err
	}

	outcome, contested := OutcomeApplied, false
	if in.BasisSeq > currentSeq {
		return Applied{}, reject("schema_rejected", "basis_seq is ahead of this table.")
	}
	// Fase 4: a seated table (an open table session) is freed only by closing
	// its seating online, once no bill on it is still open. A status event
	// from the older per-till path — a queued one from before the branch
	// switched to saved bills, or an old build — must not clear or re-book
	// it underneath the guests; it is recorded, and superseded.
	var seated bool
	if err := w.Tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM table_sessions
		WHERE tenant_id = $1 AND table_id = $2 AND closed_at_ms IS NULL)`, b.Tenant.ID, in.TableID).Scan(&seated); err != nil {
		return Applied{}, err
	}
	sessionHolds := seated && in.Status != StatusOccupied
	var lastClientSeq int64
	if err := w.Tx.QueryRow(ctx, `SELECT COALESCE(MAX(client_seq), 0) FROM table_status_events
		WHERE tenant_id=$1 AND table_id=$2 AND device_id=$3`,
		b.Tenant.ID, in.TableID, b.Device.ID).Scan(&lastClientSeq); err != nil {
		return Applied{}, err
	}
	switch {
	case sessionHolds:
		outcome, contested = OutcomeSuperseded, currentContested
	case in.ClientSeq <= lastClientSeq:
		outcome, contested = OutcomeSuperseded, currentContested
	case in.BasisSeq == currentSeq:
		// Made against what the table shows now.
	case currentEvent == nil:
		// No till has set this table yet; there is nothing to race.
	case currentDevice != nil && *currentDevice == b.Device.ID:
		// Following this device's own latest write.
		contested = currentContested
	default:
		contested = true
		later := in.OccurredAtMs > currentAtMs ||
			(in.OccurredAtMs == currentAtMs && in.ID > *currentEvent)
		if !later {
			outcome = OutcomeSuperseded
		}
	}

	seq, err := w.OutletSeqBlock(ctx, StatusEntity, b.Outlet.ID, 1)
	if err != nil {
		return Applied{}, err
	}

	if outcome == OutcomeApplied {
		_, err = w.Tx.Exec(ctx, `
			UPDATE table_status
			SET status = $3, occurred_at_ms = $4, event_id = $5, device_id = $6,
			    employee_name = $7, contested = $8, sync_seq = $9, updated_at = now()
			WHERE tenant_id = $1 AND table_id = $2`,
			b.Tenant.ID, in.TableID, in.Status, in.OccurredAtMs, in.ID, b.Device.ID,
			in.EmployeeName, contested, seq)
	} else {
		_, err = w.Tx.Exec(ctx, `
			UPDATE table_status SET contested = $4, sync_seq = $3, updated_at = now()
			WHERE tenant_id = $1 AND table_id = $2`,
			b.Tenant.ID, in.TableID, seq, contested)
	}
	if err != nil {
		return Applied{}, err
	}

	if _, err := w.Tx.Exec(ctx, `
		INSERT INTO table_status_events (
			id, tenant_id, outlet_id, table_id, status, basis_seq, occurred_at_ms,
			device_id, employee_name, outcome, status_seq, contested, payload, client_seq)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13::jsonb, $14)`,
		in.ID, b.Tenant.ID, b.Outlet.ID, in.TableID, in.Status, in.BasisSeq, in.OccurredAtMs,
		b.Device.ID, in.EmployeeName, outcome, seq, contested, string(canonical), in.ClientSeq); err != nil {
		return Applied{}, err
	}

	return Applied{StatusSeq: seq, Outcome: outcome, Contested: contested, Inserted: true}, nil
}

// SetFromSeating moves a table's live status because a seating (Fase 4
// table session) opened or closed, inside the caller's transaction.
//
// A seating is decided online, so there is no device event to record and no
// race to judge: the status is the server's, the mark of any earlier contest
// is cleared, and the row is numbered on the outlet's status feed like every
// other change, so tills pull it on their next poll. The table_status row is
// locked before the counter, the order every writer of this feed keeps.
func SetFromSeating(ctx context.Context, w *syncfeed.Writer, tenantID, outletID, tableID, status, employeeName string, atMs int64) (int64, error) {
	var found bool
	if err := w.Tx.QueryRow(ctx, `SELECT true FROM table_status
		WHERE tenant_id = $1 AND table_id = $2 AND outlet_id = $3 FOR UPDATE`,
		tenantID, tableID, outletID).Scan(&found); err != nil {
		return 0, err
	}
	seq, err := w.OutletSeqBlock(ctx, StatusEntity, outletID, 1)
	if err != nil {
		return 0, err
	}
	if len([]rune(employeeName)) > 120 {
		employeeName = string([]rune(employeeName)[:120])
	}
	_, err = w.Tx.Exec(ctx, `
		UPDATE table_status
		SET status = $3, occurred_at_ms = $4, event_id = NULL, device_id = NULL,
		    employee_name = $5, contested = false, sync_seq = $6, updated_at = now()
		WHERE tenant_id = $1 AND table_id = $2`,
		tenantID, tableID, status, atMs, employeeName, seq)
	return seq, err
}
