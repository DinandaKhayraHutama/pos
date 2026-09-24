package promos

// Named discounts a cashier picks at the till (Fase 3 paritas). A master of
// their own: an older till applies every promo row to the whole bill, so an
// item-level discount must never travel as a promo.

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// Discount is a named discount. Value nil means the cashier types the amount
// at checkout, which always needs applyManualDiscount; a percent value is in
// basis points.
type Discount struct {
	ID                    string
	Name                  string
	Scope                 string
	Kind                  string
	Value                 *int64
	RequiresAuthorization bool
	Active                bool
	SortOrder             int
}

func (s *Service) Discounts(ctx context.Context, tenantID string) ([]Discount, error) {
	var out []Discount
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id::text, name, scope, kind, value, requires_authorization, active, sort_order FROM discounts
			WHERE tenant_id = $1 AND deleted_at IS NULL ORDER BY sort_order, name`, tenantID)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Discount, error) {
			var d Discount
			err := row.Scan(&d.ID, &d.Name, &d.Scope, &d.Kind, &d.Value, &d.RequiresAuthorization, &d.Active, &d.SortOrder)
			return d, err
		})
		return err
	})
	return out, err
}

func validateDiscount(in *Discount) validation.Errors {
	in.Name = strings.TrimSpace(in.Name)
	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)
	if in.Scope != "bill" && in.Scope != "item" {
		errs.Add("scope", "Pilih berlaku untuk tagihan atau item.")
	}
	switch in.Kind {
	case "percent":
		if in.Value != nil && (*in.Value <= 0 || *in.Value > 10000) {
			errs.Add("value", "Persentase harus antara 0 dan 100.")
		}
	case "amount":
		if in.Value != nil && (*in.Value <= 0 || *in.Value > 1_000_000_000_000) {
			errs.Add("value", "Nominal harus lebih dari nol.")
		}
	default:
		errs.Add("kind", "Pilih persen atau nominal.")
	}
	return errs
}

func (s *Service) SaveDiscount(ctx context.Context, tenantID string, in Discount) (string, error) {
	if err := validateDiscount(&in).Err(); err != nil {
		return "", err
	}
	if in.ID != "" && !validation.UUID(in.ID) {
		return "", ErrNotFound
	}
	id := in.ID
	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if in.ID != "" {
			var same bool
			err := w.Tx.QueryRow(ctx, `
				SELECT name = $3 AND scope = $4 AND kind = $5 AND value IS NOT DISTINCT FROM $6
				       AND requires_authorization = $7 AND active = $8 AND sort_order = $9
				FROM discounts WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL FOR UPDATE`,
				tenantID, in.ID, in.Name, in.Scope, in.Kind, in.Value, in.RequiresAuthorization, in.Active, in.SortOrder).Scan(&same)
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			if err != nil || same {
				return err
			}
		}
		seq, err := w.Seq(ctx, "discounts")
		if err != nil {
			return err
		}
		return w.Tx.QueryRow(ctx, `
			INSERT INTO discounts (id, tenant_id, name, scope, kind, value, requires_authorization, active, sort_order, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, $7, $8, $9, $10)
			ON CONFLICT (id) DO UPDATE
			SET name = EXCLUDED.name, scope = EXCLUDED.scope, kind = EXCLUDED.kind, value = EXCLUDED.value,
			    requires_authorization = EXCLUDED.requires_authorization, active = EXCLUDED.active,
			    sort_order = EXCLUDED.sort_order, sync_seq = EXCLUDED.sync_seq, deleted_at = NULL, updated_at = now()
			RETURNING id::text`,
			in.ID, tenantID, in.Name, in.Scope, in.Kind, in.Value, in.RequiresAuthorization, in.Active, in.SortOrder, seq).Scan(&id)
	})
	return id, err
}

// DeleteDiscount tombstones a discount. Receipts that used it keep its name.
func (s *Service) DeleteDiscount(ctx context.Context, tenantID, id string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}
	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var found bool
		err := w.Tx.QueryRow(ctx, `SELECT true FROM discounts WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL FOR UPDATE`,
			tenantID, id).Scan(&found)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		seq, err := w.Seq(ctx, "discounts")
		if err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx, `UPDATE discounts SET deleted_at = now(), sync_seq = $3, updated_at = now() WHERE tenant_id = $1 AND id = $2`,
			tenantID, id, seq)
		return err
	})
}
