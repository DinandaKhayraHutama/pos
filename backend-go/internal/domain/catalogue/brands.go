package catalogue

// Brands: a flat label a product may carry, never a hierarchy and never
// scoped to an outlet.
//
// Company-wide for the same reason categories and products are: the menu
// belongs to the business, and stock/sales belong to a branch — see
// migrations/20260910000007_catalogue.sql's own note on that split. A brand
// is strictly optional on a product (Product.BrandID), unlike a category,
// because "which brand" is a marketing/reporting question a merchant may
// simply not have an answer to yet, where "which category" is required for
// the till's own menu grid to have somewhere to put the product.

import (
	"context"
	"strings"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
)

func validateBrand(in Brand) error {
	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)
	return errs.Err()
}

// SaveBrand creates or updates a brand and returns its id. Mirrors
// SaveCategory exactly; see it for the reasoning behind each line.
func (s *Service) SaveBrand(ctx context.Context, tenantID string, in Brand) (string, error) {
	in.Name = strings.TrimSpace(in.Name)
	if err := validateBrand(in); err != nil {
		return "", err
	}
	if in.ID != "" && !validation.UUID(in.ID) {
		return "", ErrNotFound
	}

	id := in.ID

	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if in.ID != "" {
			if err := claim(ctx, w.Tx, "brands", tenantID, in.ID); err != nil {
				return err
			}
		}

		seq, err := w.Seq(ctx, "brands")
		if err != nil {
			return err
		}

		return w.Tx.QueryRow(ctx, `
			INSERT INTO brands (id, tenant_id, name, sort_order, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2, $3, $4, $5)
			ON CONFLICT (id) DO UPDATE
			SET name       = EXCLUDED.name,
			    sort_order = EXCLUDED.sort_order,
			    sync_seq   = EXCLUDED.sync_seq,
			    -- Saving a retired row brings it back — same reasoning as
			    -- SaveCategory: an owner re-adding "Indomilk" should not be told
			    -- the name is taken by a row they cannot see.
			    deleted_at = NULL,
			    updated_at = now()
			RETURNING id`,
			in.ID, tenantID, in.Name, in.SortOrder, seq,
		).Scan(&id)
	})
	if err != nil {
		return "", err
	}

	return id, nil
}

// DeleteBrand tombstones an unused brand. Mirrors DeleteCategory; a brand
// still labelling live products is refused with ErrBrandInUse rather than
// silently clearing brand_id on every one of them out from under an owner who
// did not ask for that.
func (s *Service) DeleteBrand(ctx context.Context, tenantID, id string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var live int
		if err := w.Tx.QueryRow(ctx, `
			SELECT count(*) FROM products
			WHERE tenant_id = $1 AND brand_id = $2 AND deleted_at IS NULL`,
			tenantID, id).Scan(&live); err != nil {
			return err
		}
		if live > 0 {
			return ErrBrandInUse
		}

		retired, err := retire(ctx, w, "brands", "brands", "tenant_id = $1 AND id = $2", tenantID, id)
		if err != nil {
			return err
		}
		if retired == 0 {
			return ErrNotFound
		}

		return nil
	})
}
