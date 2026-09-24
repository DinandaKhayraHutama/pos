package catalogue

// Sales types and the prices that depend on them (Fase 3 paritas).
//
// A product's price for a sale is resolved outlet + sales type → business +
// sales type → products.price, and variant and modifier deltas are added to
// that base exactly once. Prices are a manageCatalogue concern; the sales
// type master itself is business configuration (manageSettings), gated at the
// route.

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pg"
)

var ErrSystemSalesType = errors.New("catalogue: a built-in sales type cannot be deleted")

type SalesType struct {
	ID        string
	Name      string
	SystemKey *string
	UsesTable bool
	Active    bool
	SortOrder int
}

// ListSalesTypes returns every live sales type, built-in first.
func (s *Service) ListSalesTypes(ctx context.Context, tenantID string) ([]SalesType, error) {
	var out []SalesType
	err := readTx(ctx, s, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id::text, name, system_key, uses_table, active, sort_order FROM sales_types
			WHERE tenant_id = $1 AND deleted_at IS NULL
			ORDER BY system_key IS NULL, sort_order, name`, tenantID)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (SalesType, error) {
			var st SalesType
			err := row.Scan(&st.ID, &st.Name, &st.SystemKey, &st.UsesTable, &st.Active, &st.SortOrder)
			return st, err
		})
		return err
	})
	return out, err
}

// SaveSalesType creates or updates a sales type. A built-in one may be renamed,
// reordered or switched off, but keeps its key: that key is what an order's
// wire `type` names, and what an older till still understands.
func (s *Service) SaveSalesType(ctx context.Context, tenantID string, in SalesType) (string, error) {
	in.Name = strings.TrimSpace(in.Name)
	errs := validation.Errors{}
	errs.Name("name", in.Name, 120)
	if err := errs.Err(); err != nil {
		return "", err
	}
	if in.ID != "" && !validation.UUID(in.ID) {
		return "", ErrNotFound
	}
	id := in.ID
	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if in.ID != "" {
			if err := claim(ctx, w.Tx, "sales_types", tenantID, in.ID); err != nil {
				return err
			}
			var same bool
			if err := w.Tx.QueryRow(ctx, `
				SELECT name = $3 AND uses_table = $4 AND active = $5 AND sort_order = $6 AND deleted_at IS NULL
				FROM sales_types WHERE tenant_id = $1 AND id = $2`,
				tenantID, in.ID, in.Name, in.UsesTable, in.Active, in.SortOrder).Scan(&same); err != nil {
				return err
			}
			if same {
				return nil
			}
		}
		seq, err := w.Seq(ctx, "sales_types")
		if err != nil {
			return err
		}
		return w.Tx.QueryRow(ctx, `
			INSERT INTO sales_types (id, tenant_id, name, uses_table, active, sort_order, sync_seq)
			VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, $7)
			ON CONFLICT (id) DO UPDATE
			SET name = EXCLUDED.name, uses_table = EXCLUDED.uses_table, active = EXCLUDED.active,
			    sort_order = EXCLUDED.sort_order, sync_seq = EXCLUDED.sync_seq,
			    deleted_at = NULL, updated_at = now()
			RETURNING id::text`,
			in.ID, tenantID, in.Name, in.UsesTable, in.Active, in.SortOrder, seq).Scan(&id)
	})
	return id, err
}

// DeleteSalesType tombstones a custom sales type and every price set for it,
// business-wide and per outlet. A built-in one is refused; switch it off
// instead. An order that already named it keeps its snapshot of the name.
func (s *Service) DeleteSalesType(ctx context.Context, tenantID, id string) error {
	if !validation.UUID(id) {
		return ErrNotFound
	}
	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		var system *string
		err := w.Tx.QueryRow(ctx, `SELECT system_key FROM sales_types WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL FOR UPDATE`,
			tenantID, id).Scan(&system)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if system != nil {
			return ErrSystemSalesType
		}
		if _, err := retire(ctx, w, "sales_types", "sales_types", "tenant_id = $1 AND id = $2", tenantID, id); err != nil {
			return err
		}
		if _, err := retire(ctx, w, "product_sales_type_prices", "product_sales_type_prices",
			"tenant_id = $1 AND sales_type_id = $2", tenantID, id); err != nil {
			return err
		}
		return retireOutletPrices(ctx, w, "tenant_id = $1 AND sales_type_id = $2", tenantID, id)
	})
}

// Price is one sales-type price of a product. OutletID nil is the
// business-wide price; set, it is that branch's override.
type Price struct {
	SalesTypeID string
	OutletID    *string
	Price       int64
}

// ProductPrices returns a product's live sales-type prices.
func (s *Service) ProductPrices(ctx context.Context, tenantID, productID string) ([]Price, error) {
	if !validation.UUID(productID) {
		return nil, ErrNotFound
	}
	var out []Price
	err := readTx(ctx, s, tenantID, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT sales_type_id::text, NULL::text, price FROM product_sales_type_prices
			WHERE tenant_id = $1 AND product_id = $2 AND deleted_at IS NULL
			UNION ALL
			SELECT sales_type_id::text, outlet_id::text, price FROM outlet_product_sales_type_prices
			WHERE tenant_id = $1 AND product_id = $2 AND deleted_at IS NULL`, tenantID, productID)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (Price, error) {
			var p Price
			err := row.Scan(&p.SalesTypeID, &p.OutletID, &p.Price)
			return p, err
		})
		return err
	})
	return out, err
}

// SetProductPrices replaces a product's sales-type prices with want. A price
// absent from want is retired; one already set to the same value is left
// alone and wakes nobody.
func (s *Service) SetProductPrices(ctx context.Context, tenantID, productID string, want []Price) error {
	if !validation.UUID(productID) {
		return ErrNotFound
	}
	for _, p := range want {
		if !validation.UUID(p.SalesTypeID) || (p.OutletID != nil && !validation.UUID(*p.OutletID)) {
			return validation.Errors{"prices": "Pilihan tidak dikenal."}
		}
		if p.Price < 0 || p.Price > 1_000_000_000_000 {
			return validation.Errors{"prices": "Harga tidak valid."}
		}
	}
	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		if err := claim(ctx, w.Tx, "products", tenantID, productID); err != nil {
			return err
		}
		have := map[string]int64{}
		for _, q := range []string{
			`SELECT sales_type_id::text, '', price FROM product_sales_type_prices
			 WHERE tenant_id = $1 AND product_id = $2 AND deleted_at IS NULL FOR UPDATE`,
			`SELECT sales_type_id::text, outlet_id::text, price FROM outlet_product_sales_type_prices
			 WHERE tenant_id = $1 AND product_id = $2 AND deleted_at IS NULL ORDER BY outlet_id FOR UPDATE`,
		} {
			rows, err := w.Tx.Query(ctx, q, tenantID, productID)
			if err != nil {
				return err
			}
			for rows.Next() {
				var st, outlet string
				var price int64
				if err := rows.Scan(&st, &outlet, &price); err != nil {
					rows.Close()
					return err
				}
				have[outlet+"|"+st] = price
			}
			rows.Close()
			if err := rows.Err(); err != nil {
				return err
			}
		}

		keep := map[string]bool{}
		for _, p := range want {
			outlet := ""
			if p.OutletID != nil {
				outlet = *p.OutletID
			}
			key := outlet + "|" + p.SalesTypeID
			keep[key] = true
			if old, ok := have[key]; ok && old == p.Price {
				continue
			}
			if err := s.writePrice(ctx, w, tenantID, productID, p); err != nil {
				return err
			}
		}
		for key := range have {
			if keep[key] {
				continue
			}
			outlet, st, _ := strings.Cut(key, "|")
			if outlet == "" {
				if _, err := retire(ctx, w, "product_sales_type_prices", "product_sales_type_prices",
					"tenant_id = $1 AND product_id = $2 AND sales_type_id = $3", tenantID, productID, st); err != nil {
					return err
				}
				continue
			}
			if err := retireOutletPrices(ctx, w, "tenant_id = $1 AND product_id = $2 AND sales_type_id = $3 AND outlet_id = $4",
				tenantID, productID, st, outlet); err != nil {
				return err
			}
		}
		return nil
	})
}

func (s *Service) writePrice(ctx context.Context, w *syncfeed.Writer, tenantID, productID string, p Price) error {
	var known bool
	if err := w.Tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM sales_types WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL)`,
		tenantID, p.SalesTypeID).Scan(&known); err != nil {
		return err
	}
	if !known {
		return validation.Errors{"prices": "Jenis penjualan tidak ada lagi."}
	}
	if p.OutletID == nil {
		seq, err := w.Seq(ctx, "product_sales_type_prices")
		if err != nil {
			return err
		}
		_, err = w.Tx.Exec(ctx, `
			INSERT INTO product_sales_type_prices (tenant_id, product_id, sales_type_id, price, sync_seq)
			VALUES ($1, $2, $3, $4, $5)
			ON CONFLICT (tenant_id, product_id, sales_type_id) DO UPDATE
			SET price = EXCLUDED.price, sync_seq = EXCLUDED.sync_seq, deleted_at = NULL, updated_at = now()`,
			tenantID, productID, p.SalesTypeID, p.Price, seq)
		return err
	}
	if err := claim(ctx, w.Tx, "outlets", tenantID, *p.OutletID); err != nil {
		return validation.Errors{"prices": "Outlet tidak dikenal."}
	}
	seq, err := w.OutletSeqBlock(ctx, "outlet_product_sales_type_prices", *p.OutletID, 1)
	if err != nil {
		return err
	}
	_, err = w.Tx.Exec(ctx, `
		INSERT INTO outlet_product_sales_type_prices (tenant_id, outlet_id, product_id, sales_type_id, price, sync_seq)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (tenant_id, outlet_id, product_id, sales_type_id) DO UPDATE
		SET price = EXCLUDED.price, sync_seq = EXCLUDED.sync_seq, deleted_at = NULL, updated_at = now()`,
		tenantID, *p.OutletID, productID, p.SalesTypeID, p.Price, seq)
	return err
}

// retireOutletPrices is retire for the outlet-scoped price feed, whose rows
// must be numbered on their own branch's counter — the company counter would
// publish them where no till pages. Branches are taken in id order, the lock
// order every outlet-scoped writer follows.
func retireOutletPrices(ctx context.Context, w *syncfeed.Writer, where string, args ...any) error {
	rows, err := w.Tx.Query(ctx, fmt.Sprintf(`
		SELECT outlet_id::text, ctid::text FROM outlet_product_sales_type_prices
		WHERE deleted_at IS NULL AND (%s)
		ORDER BY outlet_id, ctid
		FOR UPDATE`, where), args...)
	if err != nil {
		return err
	}
	byOutlet := map[string][]string{}
	var outlets []string
	for rows.Next() {
		var outlet, ctid string
		if err := rows.Scan(&outlet, &ctid); err != nil {
			rows.Close()
			return err
		}
		if !slices.Contains(outlets, outlet) {
			outlets = append(outlets, outlet)
		}
		byOutlet[outlet] = append(byOutlet[outlet], ctid)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, outlet := range outlets {
		ctids := byOutlet[outlet]
		first, err := w.OutletSeqBlock(ctx, "outlet_product_sales_type_prices", outlet, int64(len(ctids)))
		if err != nil {
			return err
		}
		if _, err := w.Tx.Exec(ctx, `
			UPDATE outlet_product_sales_type_prices t
			SET deleted_at = now(), sync_seq = $1 + x.ord - 1, updated_at = now()
			FROM unnest($2::text[]) WITH ORDINALITY AS x(c, ord)
			WHERE t.ctid = x.c::tid`, first, ctids); err != nil {
			return err
		}
	}
	return nil
}

func readTx(ctx context.Context, s *Service, tenantID string, fn func(context.Context, pgx.Tx) error) error {
	return pg.InTenantReadTx(ctx, s.pools.Tenant, tenantID, fn)
}
