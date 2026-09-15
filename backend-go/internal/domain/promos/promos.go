// Package promos owns discounts a merchant configures centrally and tills
// apply at the counter.
//
// Every write publishes through syncfeed.Write, like the catalogue: numbered
// inside the writing transaction, announced after it commits.
//
// Scoping is explicit. all_outlets = true means everywhere, with no scoping
// rows; all_outlets = false means exactly the branches in promo_outlets — and
// with none, nowhere. Absence of rows never reads as "all", or narrowing a
// promo one branch too far would spread a discount across the whole company.
package promos

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

var ErrNotFound = errors.New("promos: no such promo")

const (
	KindPercent = "percent"
	KindAmount  = "amount"
)

type Promo struct {
	ID   string
	Name string
	Kind string
	// Percentage points when Kind is percent, otherwise integer rupiah.
	Value      int64
	MinSpend   int64
	Active     bool
	SortOrder  int
	AllOutlets bool
	// OutletIDs is ignored when AllOutlets is true.
	OutletIDs []string
}

type Service struct {
	pools pg.Pools
	feed  *syncfeed.Service
}

func NewService(pools pg.Pools, feed *syncfeed.Service) *Service {
	return &Service{pools: pools, feed: feed}
}

// List returns live promos, each with the branches it is scoped to.
func (s *Service) List(ctx context.Context, tenantID string) ([]Promo, error) {
	var out []Promo

	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		out, err = load(ctx, tx, tenantID, "")
		return err
	})

	return out, err
}

// Get returns one live promo.
func (s *Service) Get(ctx context.Context, tenantID, id string) (Promo, error) {
	if !validation.UUID(id) {
		return Promo{}, ErrNotFound
	}

	var found []Promo
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		found, err = load(ctx, tx, tenantID, id)
		return err
	})
	if err != nil {
		return Promo{}, err
	}
	if len(found) == 0 {
		return Promo{}, ErrNotFound
	}

	return found[0], nil
}

func load(ctx context.Context, tx pgx.Tx, tenantID, onlyID string) ([]Promo, error) {
	rows, err := tx.Query(ctx, `
		SELECT p.id::text, p.name, p.kind, p.value, p.min_spend, p.active, p.sort_order, p.all_outlets,
		       COALESCE(array_agg(po.outlet_id::text ORDER BY po.outlet_id)
		                FILTER (WHERE po.outlet_id IS NOT NULL), '{}')
		FROM promos p
		LEFT JOIN promo_outlets po
		       ON po.tenant_id = p.tenant_id AND po.promo_id = p.id AND po.deleted_at IS NULL
		WHERE p.tenant_id = $1 AND p.deleted_at IS NULL
		  AND ($2 = '' OR p.id = NULLIF($2, '')::uuid)
		GROUP BY p.id
		ORDER BY p.sort_order, p.name`, tenantID, onlyID)
	if err != nil {
		return nil, err
	}

	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (Promo, error) {
		var p Promo
		err := row.Scan(&p.ID, &p.Name, &p.Kind, &p.Value, &p.MinSpend, &p.Active,
			&p.SortOrder, &p.AllOutlets, &p.OutletIDs)
		return p, err
	})
}

func validate(in Promo) validation.Errors {
	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)

	switch in.Kind {
	case KindPercent:
		// A discount over 100% is a refund with extra steps. The till's own
		// form refuses it, and so does the database.
		if in.Value < 1 || in.Value > 100 {
			errs.Add("value", "Persen harus antara 1 dan 100.")
		}
	case KindAmount:
		if in.Value < 1 {
			errs.Add("value", "Potongan harus lebih dari 0.")
		}
	default:
		errs.Add("kind", "Pilih persen atau nominal.")
	}

	if in.MinSpend < 0 {
		errs.Add("min_spend", "Minimal belanja tidak boleh negatif.")
	}
	if !in.AllOutlets && len(in.OutletIDs) == 0 {
		// Legal, and it would mean "live nowhere" — but nobody saving a form
		// means that. Refusing is kinder than a promo that silently never fires.
		errs.Add("outlets", "Pilih minimal satu outlet, atau berlakukan di semua outlet.")
	}
	for _, id := range in.OutletIDs {
		if !validation.UUID(id) {
			errs.Add("outlets", "Outlet tidak dikenal.")
		}
	}

	return errs
}

// Save creates or updates a promo and its scoping, and returns its id.
//
// Only the scoping that changed is written. Re-stamping unchanged
// promo_outlets rows would wake every till in the company to pull rows that
// did not change.
func (s *Service) Save(ctx context.Context, tenantID string, in Promo) (string, error) {
	in.Name = strings.TrimSpace(in.Name)
	if in.AllOutlets {
		in.OutletIDs = nil
	}
	in.OutletIDs = dedupe(in.OutletIDs)

	if err := validate(in).Err(); err != nil {
		return "", err
	}
	if in.ID != "" && !validation.UUID(in.ID) {
		return "", ErrNotFound
	}

	id := in.ID

	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if in.ID != "" {
			// An upsert naming another merchant's id would collide with a row
			// row-level security hides and fail as a policy violation — a 500 that
			// also says the id exists. Claiming it first makes it "not found".
			var found bool
			err := w.Tx.QueryRow(ctx,
				`SELECT true FROM promos WHERE tenant_id = $1 AND id = $2 FOR UPDATE`,
				tenantID, in.ID).Scan(&found)
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			if err != nil {
				return err
			}
		}

		if len(in.OutletIDs) > 0 {
			var known int
			if err := w.Tx.QueryRow(ctx, `
				SELECT count(*) FROM outlets
				WHERE tenant_id = $1 AND id = ANY($2::text[]::uuid[]) AND deleted_at IS NULL`,
				tenantID, in.OutletIDs).Scan(&known); err != nil {
				return err
			}
			if known != len(in.OutletIDs) {
				return validation.Errors{"outlets": "Outlet tidak ditemukan."}
			}
		}

		seq, err := w.Seq(ctx, "promos")
		if err != nil {
			return err
		}

		if err := w.Tx.QueryRow(ctx, `
			INSERT INTO promos
				(id, tenant_id, name, kind, value, min_spend, active, sort_order, all_outlets, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, $7, $8, $9, $10)
			ON CONFLICT (id) DO UPDATE
			SET name        = EXCLUDED.name,
			    kind        = EXCLUDED.kind,
			    value       = EXCLUDED.value,
			    min_spend   = EXCLUDED.min_spend,
			    active      = EXCLUDED.active,
			    sort_order  = EXCLUDED.sort_order,
			    all_outlets = EXCLUDED.all_outlets,
			    sync_seq    = EXCLUDED.sync_seq,
			    deleted_at  = NULL,
			    updated_at  = now()
			RETURNING id`,
			in.ID, tenantID, in.Name, in.Kind, in.Value, in.MinSpend, in.Active,
			in.SortOrder, in.AllOutlets, seq,
		).Scan(&id); err != nil {
			return err
		}

		return writeScope(ctx, w, tenantID, id, in.OutletIDs)
	})
	if err != nil {
		return "", err
	}

	return id, nil
}

// writeScope brings promo_outlets to exactly want, touching only the difference.
func writeScope(ctx context.Context, w *syncfeed.Writer, tenantID, promoID string, want []string) error {
	rows, err := w.Tx.Query(ctx, `
		SELECT outlet_id::text FROM promo_outlets
		WHERE tenant_id = $1 AND promo_id = $2 AND deleted_at IS NULL
		FOR UPDATE`, tenantID, promoID)
	if err != nil {
		return err
	}
	current, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}

	var add, drop []string
	for _, id := range want {
		if !slices.Contains(current, id) {
			add = append(add, id)
		}
	}
	for _, id := range current {
		if !slices.Contains(want, id) {
			drop = append(drop, id)
		}
	}

	if len(add) > 0 {
		first, err := w.SeqBlock(ctx, "promo_outlets", int64(len(add)))
		if err != nil {
			return err
		}
		if _, err := w.Tx.Exec(ctx, `
			INSERT INTO promo_outlets (tenant_id, promo_id, outlet_id, sync_seq)
			SELECT $1, $2, x.id::uuid, $3 + x.ord - 1
			FROM unnest($4::text[]) WITH ORDINALITY AS x(id, ord)
			ON CONFLICT (promo_id, outlet_id) DO UPDATE
			SET deleted_at = NULL, sync_seq = EXCLUDED.sync_seq, updated_at = now()`,
			tenantID, promoID, first, add); err != nil {
			return err
		}
	}

	if len(drop) > 0 {
		return retireScope(ctx, w, tenantID, promoID, drop)
	}

	return nil
}

// retireScope tombstones scoping rows, one sequence number each. With no
// outlet ids it retires every row the promo has.
func retireScope(ctx context.Context, w *syncfeed.Writer, tenantID, promoID string, outletIDs []string) error {
	rows, err := w.Tx.Query(ctx, `
		SELECT outlet_id::text FROM promo_outlets
		WHERE tenant_id = $1 AND promo_id = $2 AND deleted_at IS NULL
		  -- A nil slice arrives as NULL, not as an empty array, and
		  -- cardinality(NULL) = 0 is NULL: without the IS NULL arm, "retire
		  -- everything" would quietly retire nothing.
		  AND ($3::text[] IS NULL OR cardinality($3::text[]) = 0
		       OR outlet_id = ANY($3::text[]::uuid[]))
		ORDER BY outlet_id
		FOR UPDATE`, tenantID, promoID, outletIDs)
	if err != nil {
		return err
	}
	doomed, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil || len(doomed) == 0 {
		return err
	}

	first, err := w.SeqBlock(ctx, "promo_outlets", int64(len(doomed)))
	if err != nil {
		return err
	}

	_, err = w.Tx.Exec(ctx, `
		UPDATE promo_outlets po
		SET deleted_at = now(), sync_seq = $3 + x.ord - 1, updated_at = now()
		FROM unnest($4::text[]) WITH ORDINALITY AS x(id, ord)
		WHERE po.tenant_id = $1 AND po.promo_id = $2 AND po.outlet_id = x.id::uuid`,
		tenantID, promoID, first, doomed)
	return err
}

// Delete tombstones a promo and its scoping. On the device promo_outlets hangs
// off promos, so scoping rows left alive here would never be mentioned to the
// till again after it deleted them locally.
func (s *Service) Delete(ctx context.Context, tenantID, id string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var live bool
		if err := w.Tx.QueryRow(ctx, `
			SELECT EXISTS (SELECT 1 FROM promos
			               WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL)`,
			tenantID, id).Scan(&live); err != nil {
			return err
		}
		if !live {
			return ErrNotFound
		}

		seq, err := w.Seq(ctx, "promos")
		if err != nil {
			return err
		}
		if _, err := w.Tx.Exec(ctx, `
			UPDATE promos SET deleted_at = now(), sync_seq = $3, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`, tenantID, id, seq); err != nil {
			return err
		}

		return retireScope(ctx, w, tenantID, id, nil)
	})
}

func dedupe(ids []string) []string {
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		id = strings.TrimSpace(id)
		if id != "" && !slices.Contains(out, id) {
			out = append(out, id)
		}
	}
	return out
}
