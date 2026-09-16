// Package outlets owns a merchant's branch structure: the outlets it trades
// from and the registers — tills — inside each.
//
// Both are pulled by every till, so every write publishes through
// syncfeed.Write. Both are also links in the device-auth chain, so every write
// that touches an existing row invalidates the cached bindings built from it —
// after the commit, never before: a request that re-cached the binding in
// between would carry the old answer for the life of the cache entry.
//
// Neither is ever deleted. A closed branch still has years of sales pointing at
// it, and a receipt reprinted next year must still name the till it came from;
// deactivation is the only way out, which is also the rule the till follows.
package outlets

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/entitlements"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

var ErrNotFound = errors.New("outlets: no such outlet or register")

// Invalidator is the device-auth cache. Given as an interface so this package
// does not reach into devices, and so a test can observe exactly what was
// invalidated.
type Invalidator interface {
	Bump(ctx context.Context, kind, id string)
}

type Outlet struct {
	ID        string
	Name      string
	Address   *string
	Phone     *string
	Active    bool
	SortOrder int
	// Read-only, filled by List and Get.
	RegisterCount int
	Registers     []Register
}

type Register struct {
	ID       string
	OutletID string
	Name     string
	// Whether this till runs the floor-plan flow. Per register, not per
	// outlet: one counter can seat guests while the next hands food over.
	TableService bool
	Active       bool
	SortOrder    int
	// Read-only: devices currently holding a live token for this till.
	DeviceCount int
}

type Service struct {
	pools pg.Pools
	feed  *syncfeed.Service
	auth  Invalidator
}

func NewService(pools pg.Pools, feed *syncfeed.Service, auth Invalidator) *Service {
	return &Service{pools: pools, feed: feed, auth: auth}
}

// List returns every outlet, active or not, with how many registers it has.
func (s *Service) List(ctx context.Context, tenantID string) ([]Outlet, error) {
	var out []Outlet

	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT o.id::text, o.name, o.address, o.phone, o.active, o.sort_order,
			       (SELECT count(*) FROM pos_registers r
			        WHERE r.tenant_id = o.tenant_id AND r.outlet_id = o.id AND r.deleted_at IS NULL)
			FROM outlets o
			WHERE o.tenant_id = $1 AND o.deleted_at IS NULL
			ORDER BY o.active DESC, o.sort_order, o.name`, tenantID)
		if err != nil {
			return err
		}

		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Outlet, error) {
			var (
				o     Outlet
				count int64
			)
			err := row.Scan(&o.ID, &o.Name, &o.Address, &o.Phone, &o.Active, &o.SortOrder, &count)
			o.RegisterCount = int(count)
			return o, err
		})
		return err
	})

	return out, err
}

// Get returns one outlet with its registers.
func (s *Service) Get(ctx context.Context, tenantID, id string) (Outlet, error) {
	if !validation.UUID(id) {
		return Outlet{}, ErrNotFound
	}

	var o Outlet

	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `
			SELECT id::text, name, address, phone, active, sort_order FROM outlets
			WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL`, tenantID, id,
		).Scan(&o.ID, &o.Name, &o.Address, &o.Phone, &o.Active, &o.SortOrder); err != nil {
			return err
		}

		rows, err := tx.Query(ctx, `
			SELECT r.id::text, r.outlet_id::text, r.name, r.table_service, r.active, r.sort_order,
			       (SELECT count(*) FROM devices d
			        WHERE d.tenant_id = r.tenant_id AND d.pos_register_id = r.id AND d.revoked_at IS NULL)
			FROM pos_registers r
			WHERE r.tenant_id = $1 AND r.outlet_id = $2 AND r.deleted_at IS NULL
			ORDER BY r.active DESC, r.sort_order, r.name`, tenantID, id)
		if err != nil {
			return err
		}

		o.Registers, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Register, error) { return scanRegister(row) })
		o.RegisterCount = len(o.Registers)
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return Outlet{}, ErrNotFound
	}

	return o, err
}

// Register returns one register.
func (s *Service) Register(ctx context.Context, tenantID, id string) (Register, error) {
	if !validation.UUID(id) {
		return Register{}, ErrNotFound
	}

	var r Register
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		r, err = scanRegister(tx.QueryRow(ctx, `
			SELECT r.id::text, r.outlet_id::text, r.name, r.table_service, r.active, r.sort_order,
			       (SELECT count(*) FROM devices d
			        WHERE d.tenant_id = r.tenant_id AND d.pos_register_id = r.id AND d.revoked_at IS NULL)
			FROM pos_registers r
			WHERE r.tenant_id = $1 AND r.id = $2 AND r.deleted_at IS NULL`, tenantID, id))
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return Register{}, ErrNotFound
	}

	return r, err
}

func scanRegister(row pgx.Row) (Register, error) {
	var (
		r     Register
		count int64
	)
	err := row.Scan(&r.ID, &r.OutletID, &r.Name, &r.TableService, &r.Active, &r.SortOrder, &count)
	r.DeviceCount = int(count)
	return r, err
}

// SaveOutlet creates or updates an outlet and returns its id.
func (s *Service) SaveOutlet(ctx context.Context, tenantID string, in Outlet) (string, error) {
	in.Name = strings.TrimSpace(in.Name)

	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)
	errs.Optional("address", in.Address, 255)
	errs.Optional("phone", in.Phone, 32)
	if err := errs.Err(); err != nil {
		return "", err
	}
	if in.ID != "" && !validation.UUID(in.ID) {
		return "", ErrNotFound
	}

	id := in.ID

	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if in.ID != "" {
			if err := claim(ctx, w.Tx, "outlets", tenantID, in.ID); err != nil {
				return err
			}
		}
		if err := s.enforceSwitchOn(ctx, w.Tx, "outlets", tenantID, in.ID, in.Active); err != nil {
			return asField(err)
		}

		seq, err := w.Seq(ctx, "outlets")
		if err != nil {
			return err
		}

		err = w.Tx.QueryRow(ctx, `
			INSERT INTO outlets (id, tenant_id, name, address, phone, active, sort_order, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, $7, $8)
			ON CONFLICT (id) DO UPDATE
			SET name       = EXCLUDED.name,
			    address    = EXCLUDED.address,
			    phone      = EXCLUDED.phone,
			    active     = EXCLUDED.active,
			    sort_order = EXCLUDED.sort_order,
			    sync_seq   = EXCLUDED.sync_seq,
			    updated_at = now()
			WHERE outlets.deleted_at IS NULL
			RETURNING id::text`,
			in.ID, tenantID, in.Name, in.Address, in.Phone, in.Active, in.SortOrder, seq,
		).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if isUnique(err, "outlets_tenant_id_name_key") {
			return validation.Errors{"name": "Nama outlet ini sudah dipakai."}
		}
		return err
	})
	if err != nil {
		return "", err
	}

	// A rename changes what every till in the branch shows, and closing it
	// must stop them working now — not when their cached binding expires.
	if in.ID != "" {
		s.auth.Bump(ctx, "outlet", id)
	}

	return id, nil
}

// SetOutletActive opens or closes a branch.
func (s *Service) SetOutletActive(ctx context.Context, tenantID, id string, active bool) error {
	if err := s.setActive(ctx, tenantID, "outlets", id, active); err != nil {
		return err
	}

	s.auth.Bump(ctx, "outlet", id)
	return nil
}

// SaveRegister creates or updates a till and returns its id.
//
// A till belongs to one outlet for life. Moving it would orphan the devices
// bound to it — their composite key names the outlet — and re-file its drawer
// history under a branch it never traded in.
func (s *Service) SaveRegister(ctx context.Context, tenantID string, in Register) (string, error) {
	in.Name = strings.TrimSpace(in.Name)

	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)
	if err := errs.Err(); err != nil {
		return "", err
	}
	if !validation.UUID(in.OutletID) || (in.ID != "" && !validation.UUID(in.ID)) {
		return "", ErrNotFound
	}

	id := in.ID

	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if in.ID != "" {
			if err := claim(ctx, w.Tx, "pos_registers", tenantID, in.ID); err != nil {
				return err
			}
		}

		var live bool
		if err := w.Tx.QueryRow(ctx, `
			SELECT EXISTS (SELECT 1 FROM outlets
			               WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL)`,
			tenantID, in.OutletID).Scan(&live); err != nil {
			return err
		}
		if !live {
			return ErrNotFound
		}
		if err := s.enforceSwitchOn(ctx, w.Tx, "pos_registers", tenantID, in.ID, in.Active); err != nil {
			return asField(err)
		}

		seq, err := w.Seq(ctx, "pos_registers")
		if err != nil {
			return err
		}

		err = w.Tx.QueryRow(ctx, `
			INSERT INTO pos_registers
				(id, tenant_id, outlet_id, name, table_service, active, sort_order, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, $7, $8)
			ON CONFLICT (id) DO UPDATE
			SET name          = EXCLUDED.name,
			    table_service = EXCLUDED.table_service,
			    active        = EXCLUDED.active,
			    sort_order    = EXCLUDED.sort_order,
			    sync_seq      = EXCLUDED.sync_seq,
			    updated_at    = now()
			WHERE pos_registers.outlet_id = EXCLUDED.outlet_id
			  AND pos_registers.deleted_at IS NULL
			RETURNING id::text`,
			in.ID, tenantID, in.OutletID, in.Name, in.TableService, in.Active, in.SortOrder, seq,
		).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if isUnique(err, "pos_registers_outlet_id_name_key") {
			return validation.Errors{"name": "Nama till ini sudah dipakai di outlet ini."}
		}
		return err
	})
	if err != nil {
		return "", err
	}

	if in.ID != "" {
		s.auth.Bump(ctx, "register", id)
	}

	return id, nil
}

// SetRegisterActive enables or retires one till. Retiring it signs out every
// tablet bound to it on their next request.
func (s *Service) SetRegisterActive(ctx context.Context, tenantID, id string, active bool) error {
	if err := s.setActive(ctx, tenantID, "pos_registers", id, active); err != nil {
		return err
	}

	s.auth.Bump(ctx, "register", id)
	return nil
}

// setActive flips one row's switch, and numbers it only if it moved: flipping a
// switch to where it already is must not wake every till to pull a row that
// did not change.
func (s *Service) setActive(ctx context.Context, tenantID, table, id string, active bool) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var current bool
		// table is one of two constants from this file, never request input.
		err := w.Tx.QueryRow(ctx, `SELECT active FROM `+table+`
			WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL
			FOR UPDATE`, tenantID, id).Scan(&current)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil || current == active {
			return err
		}
		if active {
			if err := entitlements.Enforce(ctx, w.Tx, tenantID, limitFor[table]); err != nil {
				return err
			}
		}

		seq, err := w.Seq(ctx, table)
		if err != nil {
			return err
		}

		_, err = w.Tx.Exec(ctx, `UPDATE `+table+`
			SET active = $3, sync_seq = $4, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`, tenantID, id, active, seq)
		return err
	})
}

var limitFor = map[string]entitlements.Limit{
	"outlets":       entitlements.Outlets,
	"pos_registers": entitlements.Registers,
}

// enforceSwitchOn applies the merchant's limit to a save that would leave a row
// active which is not active now: a new row created active, or an existing one
// switched back on. Saving a row that is already on, or leaving it off, counts
// nothing. The caller has already claimed the row, which is the lock order the
// limit expects.
func (s *Service) enforceSwitchOn(ctx context.Context, tx pgx.Tx, table, tenantID, id string, active bool) error {
	if !active {
		return nil
	}
	if id != "" {
		var current bool
		// table is one of two constants from this file, never request input.
		err := tx.QueryRow(ctx, `SELECT active FROM `+table+`
			WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL`, tenantID, id).Scan(&current)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil || current {
			return err
		}
	}
	return entitlements.Enforce(ctx, tx, tenantID, limitFor[table])
}

// asField reports a reached limit beside the name input, the way the form
// reports every other refusal a person can act on.
func asField(err error) error {
	var limit *entitlements.LimitError
	if errors.As(err, &limit) {
		return validation.Errors{"name": limit.Message()}
	}
	return err
}

func isUnique(err error, constraint string) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505" && pgErr.ConstraintName == constraint
}

// claim confirms an id being updated belongs to this merchant and locks it.
// Without it, an upsert naming another merchant's id collides with a row that
// row-level security hides and fails as a policy violation: a 500 where the
// answer is "not found", and one that says the id exists somewhere.
func claim(ctx context.Context, tx pgx.Tx, table, tenantID, id string) error {
	var found bool
	// table is one of two constants from this file, never request input.
	err := tx.QueryRow(ctx, `SELECT true FROM `+table+`
		WHERE tenant_id = $1 AND id = $2 FOR UPDATE`, tenantID, id).Scan(&found)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	return err
}
