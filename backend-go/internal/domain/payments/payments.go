// Package payments owns the payment methods a till offers and the groups of
// them assigned to outlets (Fase 3 paritas).
//
// Everything here is RECORDED, not processed: QRIS, EDC and e-wallets are
// noted on the receipt as the cashier saw them settle, and the receipt says
// so. An order's wire payment_method stays the method's KIND, which is what
// every cash-drawer figure compares to 'cash'; the method's own id and name
// travel beside it.
package payments

import (
	"context"
	"errors"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

var (
	ErrNotFound     = errors.New("payments: no such row")
	ErrSystemMethod = errors.New("payments: a built-in method cannot be deleted")
	ErrGroupInUse   = errors.New("payments: the group is assigned to an outlet")
)

// Kinds a method may have. The first three are what every till has always
// understood; the rest exist only at outlets on the version 2 pricing model.
var Kinds = []string{"cash", "card", "qris", "ewallet", "transfer", "other"}

type Method struct {
	ID                string
	Name              string
	Kind              string
	SystemKey         *string
	RequiresReference bool
	Active            bool
	SortOrder         int
}

type Group struct {
	ID        string
	Name      string
	MethodIDs []string
	Active    bool
	SortOrder int
	Outlets   int
}

type Service struct {
	pools pg.Pools
	feed  *syncfeed.Service
}

func NewService(pools pg.Pools, feed *syncfeed.Service) *Service {
	return &Service{pools: pools, feed: feed}
}

func (s *Service) Methods(ctx context.Context, tenantID string) ([]Method, error) {
	var out []Method
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id::text, name, kind, system_key, requires_reference, active, sort_order FROM payment_methods
			WHERE tenant_id = $1 AND deleted_at IS NULL ORDER BY system_key IS NULL, sort_order, name`, tenantID)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Method, error) {
			var m Method
			err := row.Scan(&m.ID, &m.Name, &m.Kind, &m.SystemKey, &m.RequiresReference, &m.Active, &m.SortOrder)
			return m, err
		})
		return err
	})
	return out, err
}

// SaveMethod creates or updates a method. A built-in method keeps its kind;
// its name, order and switch may change.
func (s *Service) SaveMethod(ctx context.Context, tenantID string, in Method) (string, error) {
	in.Name = strings.TrimSpace(in.Name)
	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)
	if !slices.Contains(Kinds, in.Kind) {
		errs.Add("kind", "Pilih jenis pembayaran.")
	}
	if err := errs.Err(); err != nil {
		return "", err
	}
	if in.ID != "" && !validation.UUID(in.ID) {
		return "", ErrNotFound
	}
	id := in.ID
	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if in.ID != "" {
			var system *string
			var same bool
			err := w.Tx.QueryRow(ctx, `
				SELECT system_key, name = $3 AND kind = $4 AND requires_reference = $5 AND active = $6 AND sort_order = $7
				FROM payment_methods WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL FOR UPDATE`,
				tenantID, in.ID, in.Name, in.Kind, in.RequiresReference, in.Active, in.SortOrder).Scan(&system, &same)
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			if err != nil {
				return err
			}
			if system != nil && *system != in.Kind {
				return validation.Errors{"kind": "Jenis metode bawaan tidak bisa diubah."}
			}
			if same {
				return nil
			}
		}
		seq, err := w.Seq(ctx, "payment_methods")
		if err != nil {
			return err
		}
		return w.Tx.QueryRow(ctx, `
			INSERT INTO payment_methods (id, tenant_id, name, kind, requires_reference, active, sort_order, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, $7, $8)
			ON CONFLICT (id) DO UPDATE
			SET name = EXCLUDED.name, kind = EXCLUDED.kind, requires_reference = EXCLUDED.requires_reference,
			    active = EXCLUDED.active, sort_order = EXCLUDED.sort_order, sync_seq = EXCLUDED.sync_seq,
			    deleted_at = NULL, updated_at = now()
			RETURNING id::text`,
			in.ID, tenantID, in.Name, in.Kind, in.RequiresReference, in.Active, in.SortOrder, seq).Scan(&id)
	})
	return id, err
}

// DeleteMethod tombstones a custom method. A group listing it keeps the id
// harmlessly: tills offer only live methods.
func (s *Service) DeleteMethod(ctx context.Context, tenantID, id string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}
	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var system *string
		err := w.Tx.QueryRow(ctx, `SELECT system_key FROM payment_methods WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL FOR UPDATE`,
			tenantID, id).Scan(&system)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if system != nil {
			return ErrSystemMethod
		}
		seq, err := w.Seq(ctx, "payment_methods")
		if err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx, `UPDATE payment_methods SET deleted_at = now(), sync_seq = $3, updated_at = now() WHERE tenant_id = $1 AND id = $2`,
			tenantID, id, seq)
		return err
	})
}

func (s *Service) Groups(ctx context.Context, tenantID string) ([]Group, error) {
	var out []Group
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT g.id::text, g.name, g.method_ids::text[], g.active, g.sort_order,
			       (SELECT count(*) FROM outlet_settings o WHERE o.tenant_id = g.tenant_id AND o.payment_group_id = g.id)
			FROM payment_groups g WHERE g.tenant_id = $1 AND g.deleted_at IS NULL ORDER BY g.sort_order, g.name`, tenantID)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Group, error) {
			var g Group
			err := row.Scan(&g.ID, &g.Name, &g.MethodIDs, &g.Active, &g.SortOrder, &g.Outlets)
			return g, err
		})
		return err
	})
	return out, err
}

// SaveGroup creates or updates a group. Every method it names must be a live
// method of this merchant.
func (s *Service) SaveGroup(ctx context.Context, tenantID string, in Group) (string, error) {
	in.Name = strings.TrimSpace(in.Name)
	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)
	if len(in.MethodIDs) == 0 {
		errs.Add("methods", "Pilih setidaknya satu metode.")
	}
	if len(in.MethodIDs) > 32 {
		errs.Add("methods", "Terlalu banyak metode.")
	}
	for _, id := range in.MethodIDs {
		if !validation.UUID(id) {
			errs.Add("methods", "Pilihan tidak dikenal.")
		}
	}
	if err := errs.Err(); err != nil {
		return "", err
	}
	if in.ID != "" && !validation.UUID(in.ID) {
		return "", ErrNotFound
	}
	id := in.ID
	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var known int
		if err := w.Tx.QueryRow(ctx, `SELECT count(*) FROM payment_methods WHERE tenant_id = $1 AND deleted_at IS NULL AND id = ANY($2::uuid[])`,
			tenantID, in.MethodIDs).Scan(&known); err != nil {
			return err
		}
		if known != len(in.MethodIDs) {
			return validation.Errors{"methods": "Ada metode yang tidak ada lagi."}
		}
		if in.ID != "" {
			var same bool
			err := w.Tx.QueryRow(ctx, `
				SELECT name = $3 AND method_ids = $4::uuid[] AND active = $5 AND sort_order = $6
				FROM payment_groups WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL FOR UPDATE`,
				tenantID, in.ID, in.Name, in.MethodIDs, in.Active, in.SortOrder).Scan(&same)
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			if err != nil || same {
				return err
			}
		}
		seq, err := w.Seq(ctx, "payment_groups")
		if err != nil {
			return err
		}
		return w.Tx.QueryRow(ctx, `
			INSERT INTO payment_groups (id, tenant_id, name, method_ids, active, sort_order, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2, $3, $4::uuid[], $5, $6, $7)
			ON CONFLICT (id) DO UPDATE
			SET name = EXCLUDED.name, method_ids = EXCLUDED.method_ids, active = EXCLUDED.active,
			    sort_order = EXCLUDED.sort_order, sync_seq = EXCLUDED.sync_seq, deleted_at = NULL, updated_at = now()
			RETURNING id::text`,
			in.ID, tenantID, in.Name, in.MethodIDs, in.Active, in.SortOrder, seq).Scan(&id)
	})
	return id, err
}

// DeleteGroup tombstones a group no outlet uses. One still assigned is
// refused: unassigning it would silently widen that branch to every method.
func (s *Service) DeleteGroup(ctx context.Context, tenantID, id string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}
	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var found bool
		err := w.Tx.QueryRow(ctx, `SELECT true FROM payment_groups WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL FOR UPDATE`,
			tenantID, id).Scan(&found)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		var used bool
		if err := w.Tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM outlet_settings WHERE tenant_id = $1 AND payment_group_id = $2)`,
			tenantID, id).Scan(&used); err != nil {
			return err
		}
		if used {
			return ErrGroupInUse
		}
		seq, err := w.Seq(ctx, "payment_groups")
		if err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx, `UPDATE payment_groups SET deleted_at = now(), sync_seq = $3, updated_at = now() WHERE tenant_id = $1 AND id = $2`,
			tenantID, id, seq)
		return err
	})
}
