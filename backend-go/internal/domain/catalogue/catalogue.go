// Package catalogue owns the menu: what a merchant sells, at what price, in
// what shape.
//
// Every write here publishes. The rule the whole package is built around lives
// in syncfeed.Write: the sequence number is allocated inside the writing
// transaction, and the watermark is announced only after it commits. A screen
// that wrote a row without going through this package would produce a product
// no till ever hears about.
//
// Validation lives here too, not in the handlers. The Backoffice is one writer
// today; a bulk import and the platform panel will be others, and none of them
// may accept a row the rest would refuse.
package catalogue

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

var (
	ErrNotFound = errors.New("catalogue: no such row")
	// ErrCategoryInUse refuses a delete rather than cascading it. Retiring a
	// category is a bookkeeping act; retiring the twelve products under it is a
	// menu change, and the person clicking should be the one to say so.
	ErrCategoryInUse = errors.New("catalogue: the category still has products")
)

type Service struct {
	pools  pg.Pools
	feed   *syncfeed.Service
	images ImageStore
	// imageSlots bounds how many uploads decode at once. Decoding a large photo
	// takes tens of megabytes; an unbounded burst of them is how a panel
	// upload takes the API process down.
	imageSlots chan struct{}
}

func NewService(pools pg.Pools, feed *syncfeed.Service, images ImageStore) *Service {
	return &Service{pools: pools, feed: feed, images: images, imageSlots: make(chan struct{}, 2)}
}

type Category struct {
	// ID may be empty on create; the server names the row and returns it.
	ID        string
	Name      string
	IconKey   *string
	SortOrder int
	IsPopular bool
}

type Product struct {
	ID         string
	CategoryID string
	Name       string
	// Integer rupiah. Never float — a cent that does not exist in this currency
	// still rounds a total wrong.
	Price int64
	Cost  *int64
	SKU   *string
	// NULL is not zero: NULL means "use the store's PB1 rate", 0 means
	// "genuinely zero-rated". Collapsing them silently taxes exempt items.
	TaxRate     *float64
	Description *string
	// ImageURL is read-only here: SetProductImage writes it, and SaveProduct
	// leaves it alone, so saving the product form can never drop a photo.
	ImageURL  *string
	IconKey   string
	Available bool
	IsPopular bool
	SortOrder int
}

type Variant struct {
	ID        string
	ProductID string
	Name      string
	// Signed: a smaller size is a negative delta.
	PriceDelta int64
	SortOrder  int
}

func validateCategory(in Category) error {
	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)
	errs.Optional("icon_key", in.IconKey, 64)
	return errs.Err()
}

// SaveCategory creates or updates a category and returns its id.
func (s *Service) SaveCategory(ctx context.Context, tenantID string, in Category) (string, error) {
	in.Name = strings.TrimSpace(in.Name)
	if err := validateCategory(in); err != nil {
		return "", err
	}
	if in.ID != "" && !validation.UUID(in.ID) {
		return "", ErrNotFound
	}

	id := in.ID

	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if in.ID != "" {
			if err := claim(ctx, w.Tx, "categories", tenantID, in.ID); err != nil {
				return err
			}
		}

		seq, err := w.Seq(ctx, "categories")
		if err != nil {
			return err
		}

		return w.Tx.QueryRow(ctx, `
			INSERT INTO categories (id, tenant_id, name, icon_key, sort_order, is_popular, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, $7)
			ON CONFLICT (id) DO UPDATE
			SET name       = EXCLUDED.name,
			    icon_key   = EXCLUDED.icon_key,
			    sort_order = EXCLUDED.sort_order,
			    is_popular = EXCLUDED.is_popular,
			    sync_seq   = EXCLUDED.sync_seq,
			    -- Saving a retired row brings it back. The alternative is an
			    -- owner who re-adds "Minuman", is told the name is taken, and
			    -- cannot see the row that took it.
			    deleted_at = NULL,
			    updated_at = now()
			RETURNING id`,
			in.ID, tenantID, in.Name, in.IconKey, in.SortOrder, in.IsPopular, seq,
		).Scan(&id)
	})
	if err != nil {
		return "", err
	}

	return id, nil
}

// DeleteCategory tombstones an empty category.
//
// A tombstone, never a DELETE: "this category is gone" is a change a till has
// to receive. It can never infer it from an absence, because a delta page only
// ever says what changed.
func (s *Service) DeleteCategory(ctx context.Context, tenantID, id string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var live int
		if err := w.Tx.QueryRow(ctx, `
			SELECT count(*) FROM products
			WHERE tenant_id = $1 AND category_id = $2 AND deleted_at IS NULL`,
			tenantID, id).Scan(&live); err != nil {
			return err
		}
		if live > 0 {
			return ErrCategoryInUse
		}

		retired, err := retire(ctx, w, "categories", "categories", "tenant_id = $1 AND id = $2", tenantID, id)
		if err != nil {
			return err
		}
		if retired == 0 {
			return ErrNotFound
		}

		return nil
	})
}

func validateProduct(in Product) validation.Errors {
	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)

	if !validation.UUID(in.CategoryID) {
		errs.Add("category_id", "Pilih kategori.")
	}
	if in.Price < 0 {
		errs.Add("price", "Harga tidak boleh negatif.")
	}
	if in.Cost != nil && *in.Cost < 0 {
		errs.Add("cost", "Modal tidak boleh negatif.")
	}
	if in.TaxRate != nil && (*in.TaxRate < 0 || *in.TaxRate > 100) {
		errs.Add("tax_rate", "Tarif pajak harus antara 0 dan 100.")
	}

	errs.Optional("sku", in.SKU, 64)
	errs.Optional("description", in.Description, 500)
	errs.Name("icon_key", in.IconKey, 64)

	return errs
}

// SaveProduct creates or updates a product and returns its id.
func (s *Service) SaveProduct(ctx context.Context, tenantID string, in Product) (string, error) {
	in.Name = strings.TrimSpace(in.Name)
	if strings.TrimSpace(in.IconKey) == "" {
		in.IconKey = "restaurant"
	}
	if in.ID != "" && !validation.UUID(in.ID) {
		return "", ErrNotFound
	}

	errs := validateProduct(in)
	if err := errs.Err(); err != nil {
		return "", err
	}

	id := in.ID

	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if in.ID != "" {
			if err := claim(ctx, w.Tx, "products", tenantID, in.ID); err != nil {
				return err
			}
		}

		// A retired category still satisfies the foreign key, so the database
		// alone would let a product be filed under a heading no till shows.
		var live bool
		if err := w.Tx.QueryRow(ctx, `
			SELECT EXISTS (SELECT 1 FROM categories
			               WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL)`,
			tenantID, in.CategoryID).Scan(&live); err != nil {
			return err
		}
		if !live {
			return validation.Errors{"category_id": "Kategori tidak ditemukan."}
		}

		// A variant is a delta on this price, so lowering the base can push a
		// size below zero — a line that pays the customer.
		if in.ID != "" {
			var cheapest int64
			if err := w.Tx.QueryRow(ctx, `
				SELECT COALESCE(min(price_delta), 0) FROM product_variants
				WHERE tenant_id = $1 AND product_id = $2 AND deleted_at IS NULL`,
				tenantID, in.ID).Scan(&cheapest); err != nil {
				return err
			}
			if in.Price+cheapest < 0 {
				return validation.Errors{"price": "Harga ini membuat salah satu varian bernilai negatif."}
			}
		}

		seq, err := w.Seq(ctx, "products")
		if err != nil {
			return err
		}

		return w.Tx.QueryRow(ctx, `
			INSERT INTO products
				(id, tenant_id, category_id, name, price, cost, sku, tax_rate, description,
				 icon_key, available, is_popular, sort_order, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()),
			        $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
			ON CONFLICT (id) DO UPDATE
			SET category_id = EXCLUDED.category_id,
			    name        = EXCLUDED.name,
			    price       = EXCLUDED.price,
			    cost        = EXCLUDED.cost,
			    sku         = EXCLUDED.sku,
			    tax_rate    = EXCLUDED.tax_rate,
			    description = EXCLUDED.description,
			    icon_key    = EXCLUDED.icon_key,
			    available   = EXCLUDED.available,
			    is_popular  = EXCLUDED.is_popular,
			    sort_order  = EXCLUDED.sort_order,
			    sync_seq    = EXCLUDED.sync_seq,
			    deleted_at  = NULL,
			    updated_at  = now()
			RETURNING id`,
			in.ID, tenantID, in.CategoryID, in.Name, in.Price, in.Cost, in.SKU, in.TaxRate,
			in.Description, in.IconKey, in.Available, in.IsPopular, in.SortOrder, seq,
		).Scan(&id)
	})
	if err != nil {
		return "", err
	}

	return id, nil
}

// SetAvailability is the "sold out" switch — the one catalogue change made in
// the middle of a service, usually from a phone.
//
// It reads before it numbers anything: flipping a switch to where it already
// is must not wake every till in the company to pull a row that did not change.
func (s *Service) SetAvailability(ctx context.Context, tenantID, id string, available bool) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var current bool
		err := w.Tx.QueryRow(ctx, `
			SELECT available FROM products
			WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL
			FOR UPDATE`, tenantID, id).Scan(&current)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if current == available {
			return nil
		}

		seq, err := w.Seq(ctx, "products")
		if err != nil {
			return err
		}

		_, err = w.Tx.Exec(ctx, `
			UPDATE products SET available = $3, sync_seq = $4, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`, tenantID, id, available, seq)
		return err
	})
}

// DeleteProduct tombstones a product and everything that hangs off it.
//
// The cascade is not optional. On the device these tables carry ON DELETE
// CASCADE, so applying the product's tombstone deletes its variants and its
// modifier attachments locally — and if the server left those rows alive, no
// later page would ever mention them again. The till and the server would
// disagree permanently, in the direction where the till is missing rows.
func (s *Service) DeleteProduct(ctx context.Context, tenantID, id string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		retired, err := retire(ctx, w, "products", "products", "tenant_id = $1 AND id = $2", tenantID, id)
		if err != nil {
			return err
		}
		if retired == 0 {
			return ErrNotFound
		}

		// Registry order: dependants after the row they depend on, which is
		// also the order that keeps two writers from taking the same counters
		// in opposite directions.
		for _, dependant := range []string{
			"product_variants", "product_modifier_groups", "product_modifier_options",
		} {
			if _, err := retire(ctx, w, dependant, dependant,
				"tenant_id = $1 AND product_id = $2", tenantID, id); err != nil {
				return err
			}
		}

		return nil
	})
}

// SaveVariant creates or updates one size or option of a product.
func (s *Service) SaveVariant(ctx context.Context, tenantID string, in Variant) (string, error) {
	in.Name = strings.TrimSpace(in.Name)

	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)
	if err := errs.Err(); err != nil {
		return "", err
	}
	if !validation.UUID(in.ProductID) || (in.ID != "" && !validation.UUID(in.ID)) {
		return "", ErrNotFound
	}

	id := in.ID

	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if in.ID != "" {
			if err := claim(ctx, w.Tx, "product_variants", tenantID, in.ID); err != nil {
				return err
			}
		}

		var base int64
		err := w.Tx.QueryRow(ctx, `
			SELECT price FROM products
			WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL`,
			tenantID, in.ProductID).Scan(&base)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if base+in.PriceDelta < 0 {
			return validation.Errors{"price_delta": "Selisih ini membuat harga varian negatif."}
		}

		seq, err := w.Seq(ctx, "product_variants")
		if err != nil {
			return err
		}

		err = w.Tx.QueryRow(ctx, `
			INSERT INTO product_variants
				(id, tenant_id, product_id, name, price_delta, sort_order, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, $7)
			ON CONFLICT (id) DO UPDATE
			SET name        = EXCLUDED.name,
			    price_delta = EXCLUDED.price_delta,
			    sort_order  = EXCLUDED.sort_order,
			    sync_seq    = EXCLUDED.sync_seq,
			    deleted_at  = NULL,
			    updated_at  = now()
			-- A variant never moves between products: on the till it is the
			-- product's child, and re-parenting it would leave the old parent's
			-- cached options pointing at a row that now belongs elsewhere.
			WHERE product_variants.product_id = EXCLUDED.product_id
			RETURNING id`,
			in.ID, tenantID, in.ProductID, in.Name, in.PriceDelta, in.SortOrder, seq,
		).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	if err != nil {
		return "", err
	}

	return id, nil
}

// DeleteVariant tombstones one variant.
func (s *Service) DeleteVariant(ctx context.Context, tenantID, id string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		retired, err := retire(ctx, w, "product_variants", "product_variants",
			"tenant_id = $1 AND id = $2", tenantID, id)
		if err != nil {
			return err
		}
		if retired == 0 {
			return ErrNotFound
		}

		return nil
	})
}
