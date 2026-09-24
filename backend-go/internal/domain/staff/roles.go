package staff

import (
	"context"
	"errors"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/auth"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// Roles (Fase 3 paritas).
//
// The three system roles are rows for identity only: their permissions live
// in internal/domain/auth and cannot be edited or deleted here, so owner stays
// derived and "role lama tidak mendapat akses tambahan tanpa penetapan" holds
// by construction. A custom role is a named list of permissions plus whether
// it signs in on a till, in the Backoffice, or both.

var (
	ErrSystemRole = errors.New("staff: a system role cannot be changed")
	ErrRoleInUse  = errors.New("staff: the role is still held by someone")
)

// RoleInfo is a role as the Backoffice lists it.
type RoleInfo struct {
	ID         string
	Name       string
	SystemKey  *string
	Access     auth.Access
	SortOrder  int
	Holders    int
	Deletable  bool
	Permission []auth.Permission
}

// RoleInput is a custom role as a form submits it.
type RoleInput struct {
	ID          string
	Name        string
	Permissions []string
	POS         bool
	Backoffice  bool
	SortOrder   int
}

// ListRoles returns every live role, system roles first.
func (s *Service) ListRoles(ctx context.Context, tenantID string) ([]RoleInfo, error) {
	var out []RoleInfo
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT r.id::text, r.name, r.system_key, r.permissions, r.pos_access, r.backoffice_access,
			       r.sort_order,
			       (SELECT count(*) FROM employees e
			         WHERE e.tenant_id = r.tenant_id AND e.role_id = r.id AND e.deleted_at IS NULL)
			FROM roles r
			WHERE r.tenant_id = $1 AND r.deleted_at IS NULL
			ORDER BY r.system_key IS NULL, r.sort_order, r.name`, tenantID)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (RoleInfo, error) {
			var (
				ri   RoleInfo
				role roleRow
			)
			err := row.Scan(&ri.ID, &ri.Name, &role.systemKey, &role.permissions, &role.pos, &role.backoffice,
				&ri.SortOrder, &ri.Holders)
			ri.SystemKey = role.systemKey
			_, ri.Access = role.resolve()
			ri.Permission = ri.Access.Permissions()
			ri.Deletable = ri.SystemKey == nil && ri.Holders == 0
			return ri, err
		})
		return err
	})
	return out, err
}

// Role returns one live role.
func (s *Service) Role(ctx context.Context, tenantID, id string) (RoleInfo, error) {
	roles, err := s.ListRoles(ctx, tenantID)
	if err != nil {
		return RoleInfo{}, err
	}
	for _, r := range roles {
		if r.ID == id {
			return r, nil
		}
	}
	return RoleInfo{}, ErrNotFound
}

func validateRole(in *RoleInput) (auth.Access, validation.Errors) {
	in.Name = strings.TrimSpace(in.Name)
	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)

	known := make([]string, 0, len(in.Permissions))
	for _, p := range in.Permissions {
		if !slices.Contains(auth.AllPermissions, auth.Permission(p)) {
			errs.Add("permissions", "Ada izin yang tidak dikenal.")
			continue
		}
		if !slices.Contains(known, p) {
			known = append(known, p)
		}
	}
	in.Permissions = known
	access := auth.CustomAccess(known, in.POS, in.Backoffice)

	if !in.POS && !in.Backoffice {
		errs.Add("access", "Pilih setidaknya akses kasir atau Backoffice.")
	}
	if !in.POS && (access.Grants(auth.Sell) || access.Grants(auth.OpenCloseShift)) {
		errs.Add("access", "Izin berjualan dan membuka shift butuh akses kasir.")
	}
	if in.Backoffice && !hasBackofficePermission(access) {
		// The Backoffice surfaces no till permission, so a role with only
		// those would sign into an empty panel.
		errs.Add("access", "Akses Backoffice butuh setidaknya satu izin di luar kasir.")
	}
	if len(known) > 32 {
		errs.Add("permissions", "Terlalu banyak izin.")
	}
	return access, errs
}

func hasBackofficePermission(a auth.Access) bool {
	for _, p := range a.Permissions() {
		switch p {
		case auth.Sell, auth.OpenCloseShift, auth.ManageTables, auth.ViewOwnOrders, auth.EnterCustomAmount:
		default:
			return true
		}
	}
	return false
}

// SaveRole creates or updates a custom role and returns its id.
//
// Nobody may create or widen a role past their own access (auth.Access.Covers),
// edit a role more powerful than themselves, or edit the role they hold — the
// last is how someone would quietly grant themselves more.
func (s *Service) SaveRole(ctx context.Context, tenantID, actorID string, in RoleInput) (string, error) {
	if in.ID != "" && !validation.UUID(in.ID) {
		return "", ErrNotFound
	}
	access, errs := validateRole(&in)
	if err := errs.Err(); err != nil {
		return "", err
	}

	id := in.ID
	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		actor, system, err := actorAccess(ctx, w.Tx, tenantID, actorID)
		if err != nil {
			return err
		}
		if !system && !actor.Covers(access) {
			return validation.Errors{"permissions": "Anda tidak bisa memberikan izin yang tidak Anda miliki."}
		}

		if in.ID != "" {
			current, err := lockRole(ctx, w.Tx, tenantID, in.ID)
			if err != nil {
				return err
			}
			if current.system != nil {
				return ErrSystemRole
			}
			if !system && !actor.Covers(current.access) {
				return validation.Errors{"permissions": "Anda tidak bisa mengubah peran dengan akses lebih luas dari akses Anda."}
			}
			if !system {
				var holds bool
				if err := w.Tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM employees WHERE tenant_id = $1 AND id = $2 AND role_id = $3)`,
					tenantID, actorID, in.ID).Scan(&holds); err != nil {
					return err
				}
				if holds {
					return validation.Errors{"permissions": "Anda tidak bisa mengubah peran yang Anda pegang sendiri."}
				}
			}
		}

		seq, err := w.Seq(ctx, "roles")
		if err != nil {
			return err
		}
		return w.Tx.QueryRow(ctx, `
			INSERT INTO roles (id, tenant_id, name, permissions, pos_access, backoffice_access, sort_order, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, $7, $8)
			ON CONFLICT (id) DO UPDATE
			SET name = EXCLUDED.name, permissions = EXCLUDED.permissions,
			    pos_access = EXCLUDED.pos_access, backoffice_access = EXCLUDED.backoffice_access,
			    sort_order = EXCLUDED.sort_order, sync_seq = EXCLUDED.sync_seq,
			    deleted_at = NULL, updated_at = now()
			RETURNING id::text`,
			in.ID, tenantID, in.Name, in.Permissions, in.POS, in.Backoffice, in.SortOrder, seq,
		).Scan(&id)
	})
	if err != nil {
		return "", err
	}
	return id, nil
}

// DeleteRole tombstones an unused custom role. A role someone still holds is
// refused (ErrRoleInUse), like a category that still has products: moving
// people to another role is a decision, not bookkeeping.
func (s *Service) DeleteRole(ctx context.Context, tenantID, actorID, id string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}
	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		current, err := lockRole(ctx, w.Tx, tenantID, id)
		if err != nil {
			return err
		}
		if current.system != nil {
			return ErrSystemRole
		}
		actor, system, err := actorAccess(ctx, w.Tx, tenantID, actorID)
		if err != nil {
			return err
		}
		if !system && !actor.Covers(current.access) {
			return ErrSystemRole
		}
		var held bool
		if err := w.Tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM employees WHERE tenant_id = $1 AND role_id = $2 AND deleted_at IS NULL)`,
			tenantID, id).Scan(&held); err != nil {
			return err
		}
		if held {
			return ErrRoleInUse
		}
		seq, err := w.Seq(ctx, "roles")
		if err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx, `UPDATE roles SET deleted_at = now(), sync_seq = $3, updated_at = now() WHERE tenant_id = $1 AND id = $2`,
			tenantID, id, seq)
		return err
	})
}

// lockRole claims a live role row before it is changed, so an id belonging to
// another merchant is a not-found rather than an RLS error.
func lockRole(ctx context.Context, tx pgx.Tx, tenantID, id string) (assignableRole, error) {
	var (
		out  assignableRole
		role roleRow
	)
	err := tx.QueryRow(ctx, `
		SELECT id::text, system_key, permissions, pos_access, backoffice_access FROM roles
		WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL FOR UPDATE`, tenantID, id).
		Scan(&out.id, &role.systemKey, &role.permissions, &role.pos, &role.backoffice)
	if errors.Is(err, pgx.ErrNoRows) {
		return assignableRole{}, ErrNotFound
	}
	if err != nil {
		return assignableRole{}, err
	}
	out.system = role.systemKey
	_, out.access = role.resolve()
	return out, nil
}
