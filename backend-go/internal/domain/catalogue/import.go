package catalogue

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
)

// MaxImportRows bounds one upload. A price list for a 5,000-product menu fits
// with room to spare; anything past this is more likely the wrong file.
const MaxImportRows = 10_000

// PriceChange is one line of an uploaded price list.
type PriceChange struct {
	// Line is the row number in the file, so a rejection can point at it.
	Line  int
	SKU   string
	Price int64
}

type ImportResult struct {
	Changed   int
	Unchanged int
}

type ImportError struct {
	Line    int
	Message string
}

// ImportErrors is every problem found in a file, in line order.
type ImportErrors []ImportError

func (e ImportErrors) Error() string {
	parts := make([]string, 0, len(e))
	for _, x := range e {
		parts = append(parts, fmt.Sprintf("line %d: %s", x.Line, x.Message))
	}
	return "catalogue: import refused: " + strings.Join(parts, "; ")
}

// ImportPrices applies a price list all or nothing.
//
// All or nothing because a half-applied price list is worse than either
// outcome: some tills charge the new prices, some the old, and nobody can say
// from the file which rows made it. So every line is checked first — the SKU
// must name exactly one live product, the price must be a whole rupiah amount
// that keeps every variant non-negative — and one bad line refuses the file.
//
// Only prices that actually change are numbered. Re-uploading the same list
// must not wake every till in the company to pull 5,000 unchanged rows.
func (s *Service) ImportPrices(ctx context.Context, tenantID string, rows []PriceChange) (ImportResult, error) {
	if len(rows) == 0 {
		return ImportResult{}, ImportErrors{{Line: 0, Message: "Berkas tidak berisi baris harga."}}
	}
	if len(rows) > MaxImportRows {
		return ImportResult{}, ImportErrors{{Line: 0, Message: fmt.Sprintf(
			"Maksimal %d baris per unggahan.", MaxImportRows)}}
	}

	var result ImportResult

	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		live, err := productsBySKU(ctx, w.Tx, tenantID)
		if err != nil {
			return err
		}

		var (
			problems ImportErrors
			ids      []string
			prices   []int64
			seen     = map[string]int{}
		)

		for _, row := range rows {
			key := strings.ToLower(strings.TrimSpace(row.SKU))

			switch matches := live[key]; {
			case key == "":
				problems = append(problems, ImportError{row.Line, "SKU kosong."})
			case seen[key] != 0:
				problems = append(problems, ImportError{row.Line,
					fmt.Sprintf("SKU %s sudah muncul di baris %d.", row.SKU, seen[key])})
			case len(matches) == 0:
				problems = append(problems, ImportError{row.Line,
					fmt.Sprintf("SKU %s tidak cocok dengan produk mana pun.", row.SKU)})
			case len(matches) > 1:
				// A SKU is not unique in the schema, and guessing which product
				// a price was meant for is how the wrong item gets repriced.
				problems = append(problems, ImportError{row.Line,
					fmt.Sprintf("SKU %s dipakai %d produk; perbaiki SKU-nya dulu.", row.SKU, len(matches))})
			case row.Price < 0:
				problems = append(problems, ImportError{row.Line, "Harga tidak boleh negatif."})
			case row.Price+matches[0].cheapestVariant < 0:
				problems = append(problems, ImportError{row.Line,
					"Harga ini membuat salah satu varian bernilai negatif."})
			case row.Price == matches[0].price:
				result.Unchanged++
			default:
				ids = append(ids, matches[0].id)
				prices = append(prices, row.Price)
			}

			if key != "" && seen[key] == 0 {
				seen[key] = row.Line
			}
		}

		if len(problems) > 0 {
			sort.SliceStable(problems, func(i, j int) bool { return problems[i].Line < problems[j].Line })
			return problems
		}
		if len(ids) == 0 {
			return nil
		}

		first, err := w.SeqBlock(ctx, "products", int64(len(ids)))
		if err != nil {
			return err
		}

		if _, err := w.Tx.Exec(ctx, `
			UPDATE products p
			SET price = x.price, sync_seq = $2 + x.ord - 1, updated_at = now()
			FROM unnest($3::text[], $4::bigint[]) WITH ORDINALITY AS x(id, price, ord)
			WHERE p.tenant_id = $1 AND p.id = x.id::uuid`,
			tenantID, first, ids, prices); err != nil {
			return err
		}

		result.Changed = len(ids)
		return nil
	})
	if err != nil {
		return ImportResult{}, err
	}

	return result, nil
}

type skuMatch struct {
	id              string
	price           int64
	cheapestVariant int64
}

// productsBySKU locks every live product that carries a SKU. The lock is what
// makes the price comparison above true at commit: without it a price edited
// in another tab between the check and the write would be silently overwritten
// by a file that was built against the old one.
func productsBySKU(ctx context.Context, tx pgx.Tx, tenantID string) (map[string][]skuMatch, error) {
	rows, err := tx.Query(ctx, `
		SELECT p.id::text, lower(trim(p.sku)), p.price,
		       COALESCE((SELECT min(v.price_delta) FROM product_variants v
		                 WHERE v.tenant_id = p.tenant_id AND v.product_id = p.id
		                   AND v.deleted_at IS NULL), 0)
		FROM products p
		WHERE p.tenant_id = $1 AND p.deleted_at IS NULL
		  AND p.sku IS NOT NULL AND trim(p.sku) <> ''
		FOR UPDATE OF p`, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := map[string][]skuMatch{}
	for rows.Next() {
		var (
			sku string
			m   skuMatch
		)
		if err := rows.Scan(&m.id, &sku, &m.price, &m.cheapestVariant); err != nil {
			return nil, err
		}
		out[sku] = append(out[sku], m)
	}

	return out, rows.Err()
}
