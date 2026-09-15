package catalogue

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

// ProductPageSize keeps a 5,000-product menu from arriving as one page.
const ProductPageSize = 50

type CategoryRow struct {
	Category
	ProductCount int
}

type ProductFilter struct {
	Query      string
	CategoryID string
	// Page is 1-based.
	Page int
}

type ProductRow struct {
	ID           string
	Name         string
	CategoryName string
	SKU          *string
	Price        int64
	Available    bool
	VariantCount int
}

type ProductPage struct {
	Rows    []ProductRow
	Page    int
	HasMore bool
}

type ProductDetail struct {
	Product
	Variants []Variant
}

// Categories lists the live categories, in the order the till shows them.
func (s *Service) Categories(ctx context.Context, tenantID string) ([]CategoryRow, error) {
	var out []CategoryRow

	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT c.id, c.name, c.icon_key, c.sort_order, c.is_popular,
			       (SELECT count(*) FROM products p
			        WHERE p.tenant_id = c.tenant_id AND p.category_id = c.id AND p.deleted_at IS NULL)
			FROM categories c
			WHERE c.tenant_id = $1 AND c.deleted_at IS NULL
			ORDER BY c.sort_order, c.name`, tenantID)
		if err != nil {
			return err
		}

		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (CategoryRow, error) {
			var (
				c     CategoryRow
				count int64
			)
			err := row.Scan(&c.ID, &c.Name, &c.IconKey, &c.SortOrder, &c.IsPopular, &count)
			c.ProductCount = int(count)
			return c, err
		})
		return err
	})

	return out, err
}

// Category returns one live category.
func (s *Service) Category(ctx context.Context, tenantID, id string) (Category, error) {
	if !validation.UUID(id) {
		return Category{}, ErrNotFound
	}

	var c Category
	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, `
			SELECT id, name, icon_key, sort_order, is_popular FROM categories
			WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL`, tenantID, id,
		).Scan(&c.ID, &c.Name, &c.IconKey, &c.SortOrder, &c.IsPopular)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return Category{}, ErrNotFound
	}

	return c, err
}

// Products is the Backoffice list: search by name or SKU, narrow by category,
// one page at a time.
func (s *Service) Products(ctx context.Context, tenantID string, f ProductFilter) (ProductPage, error) {
	if f.Page < 1 {
		f.Page = 1
	}

	page := ProductPage{Page: f.Page}

	category := ""
	if validation.UUID(f.CategoryID) {
		category = f.CategoryID
	}

	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT p.id, p.name, c.name, p.sku, p.price, p.available,
			       (SELECT count(*) FROM product_variants v
			        WHERE v.tenant_id = p.tenant_id AND v.product_id = p.id AND v.deleted_at IS NULL)
			FROM products p
			JOIN categories c ON c.tenant_id = p.tenant_id AND c.id = p.category_id
			WHERE p.tenant_id = $1
			  AND p.deleted_at IS NULL
			  AND ($2 = '' OR p.category_id = NULLIF($2, '')::uuid)
			  AND ($3 = '' OR p.name ILIKE '%' || $3 || '%' ESCAPE '\'
			              OR p.sku  ILIKE '%' || $3 || '%' ESCAPE '\')
			ORDER BY c.sort_order, c.name, p.sort_order, p.name
			LIMIT $4 OFFSET $5`,
			tenantID, category, escapeLike(strings.TrimSpace(f.Query)),
			ProductPageSize+1, (f.Page-1)*ProductPageSize)
		if err != nil {
			return err
		}

		page.Rows, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (ProductRow, error) {
			var (
				p     ProductRow
				count int64
			)
			err := row.Scan(&p.ID, &p.Name, &p.CategoryName, &p.SKU, &p.Price, &p.Available, &count)
			p.VariantCount = int(count)
			return p, err
		})
		return err
	})
	if err != nil {
		return ProductPage{}, err
	}

	// One extra row was asked for, so "is there a next page" costs no count.
	if len(page.Rows) > ProductPageSize {
		page.Rows = page.Rows[:ProductPageSize]
		page.HasMore = true
	}

	return page, nil
}

// Product returns one live product with its live variants.
func (s *Service) Product(ctx context.Context, tenantID, id string) (ProductDetail, error) {
	if !validation.UUID(id) {
		return ProductDetail{}, ErrNotFound
	}

	var d ProductDetail

	err := pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `
			SELECT id, category_id, name, price, cost, sku, tax_rate, description,
			       image_url, icon_key, available, is_popular, sort_order
			FROM products
			WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL`, tenantID, id,
		).Scan(&d.ID, &d.CategoryID, &d.Name, &d.Price, &d.Cost, &d.SKU, &d.TaxRate,
			&d.Description, &d.ImageURL, &d.IconKey, &d.Available, &d.IsPopular, &d.SortOrder); err != nil {
			return err
		}

		rows, err := tx.Query(ctx, `
			SELECT id, product_id, name, price_delta, sort_order FROM product_variants
			WHERE tenant_id = $1 AND product_id = $2 AND deleted_at IS NULL
			ORDER BY sort_order, name`, tenantID, id)
		if err != nil {
			return err
		}

		d.Variants, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Variant, error) {
			var v Variant
			err := row.Scan(&v.ID, &v.ProductID, &v.Name, &v.PriceDelta, &v.SortOrder)
			return v, err
		})
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return ProductDetail{}, ErrNotFound
	}

	return d, err
}

// escapeLike stops a search for "50%" from matching everything.
func escapeLike(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}
