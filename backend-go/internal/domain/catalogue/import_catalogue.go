package catalogue

// ImportCatalogue is Fase 2's full catalogue import: create or update,
// matched by id then by sku, all-or-nothing — the same discipline
// ImportPrices already established in import.go, extended from "one column,
// only updates" to "every product field, creates included".
//
// The legacy two-column shape (a header of exactly sku + harga/price) is
// deliberately NOT routed through here: internal/backoffice/catalogue.go
// detects that shape before parsing reaches this file and calls ImportPrices
// unchanged, byte for byte, because scripts/verify-backoffice-crud pins its
// exact toast text and one-shot-apply behaviour. This importer is for every
// other header shape.
//
// Preview and commit are the same validation running twice, not two
// implementations: the Backoffice handler calls this with commit=false to
// show what a file WOULD do, then again with commit=true and the identical
// parsed rows — sent back to the browser and round-tripped, not cached
// server-side — to actually do it. Because commit re-validates from scratch
// against whatever the database says at that moment, a preview can never be
// "confirmed" against data that changed underneath it; there is nothing to
// go stale.

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
)

// MaxCatalogueImportRows bounds one upload, same reasoning as
// MaxImportRows: a menu with room to spare, not a file that arrived by
// mistake. Larger than MaxImportRows because a full row carries every
// column, not just a price, and is more likely to genuinely need the room.
const MaxCatalogueImportRows = 10_000

// CatalogueRow is one line of a full catalogue import file: every cell the
// file's header named, keyed by column name. Fields never holds a key
// outside ImportColumns plus "id" — the HTTP layer refuses an unrecognised
// header before any row reaches here, so this package never has to.
type CatalogueRow struct {
	Line   int
	Fields map[string]string
}

// CatalogueImportResult counts what a preview would do, or what a commit did.
type CatalogueImportResult struct {
	Created, Updated, Unchanged int
}

// legacyPriceListHeader reports whether a header is exactly the two-column
// shape ImportPrices already handles, so the Backoffice handler can route
// there unchanged. Exported because the handler, not this package, decides
// which importer a file goes through.
func LegacyPriceListHeader(header []string) bool {
	if len(header) != 2 {
		return false
	}
	has := map[string]bool{}
	for _, h := range header {
		has[h] = true
	}
	return has["sku"] && (has["harga"] || has["price"])
}

// requiredForCreate are the columns a file must carry in its header before
// any row in it may be a new product — without a category, a new product
// has nowhere to appear on the till's menu grid, and without a name or price
// it is not a product yet.
var requiredForCreate = []string{"name", "category_id", "price"}

func (s *Service) ImportCatalogue(ctx context.Context, tenantID string, header []string, rows []CatalogueRow, commit bool) (CatalogueImportResult, error) {
	if len(rows) == 0 {
		return CatalogueImportResult{}, ImportErrors{{Line: 0, Message: "Berkas tidak berisi baris produk."}}
	}
	if len(rows) > MaxCatalogueImportRows {
		return CatalogueImportResult{}, ImportErrors{{Line: 0, Message: fmt.Sprintf(
			"Maksimal %d baris per unggahan.", MaxCatalogueImportRows)}}
	}

	writable := map[string]bool{}
	for _, h := range header {
		writable[h] = true
	}
	delete(writable, "id") // identity, never a value to write

	// Whether the header carries enough to create a NEW product is checked
	// per row below, not here: a file that updates existing rows only,
	// naming neither name, category_id nor price, is entirely legitimate
	// right up until some row in it turns out to have no match.
	var problems ImportErrors
	var result CatalogueImportResult

	run := func(ctx context.Context, w *syncfeed.Writer) error {
		// Fase 2's own defence against a race ImportPrices never had to
		// worry about: products.sku carries no unique constraint, and
		// ImportPrices is safe only because FOR UPDATE locks rows that
		// ALREADY exist. Once a file may CREATE rows, two imports racing to
		// create the same new SKU would both see zero existing matches and
		// both insert — this serialises the whole import per tenant so the
		// second one sees the first's row.
		if _, err := w.Tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1)::bigint)`, tenantID); err != nil {
			return err
		}

		live, err := loadLiveProducts(ctx, w, tenantID)
		if err != nil {
			return err
		}
		liveCategories, err := loadLiveIDs(ctx, w, tenantID, "categories")
		if err != nil {
			return err
		}
		liveBrands, err := loadLiveIDs(ctx, w, tenantID, "brands")
		if err != nil {
			return err
		}

		var (
			toWrite []productWrite
			seenSKU = map[string]int{}
			seenID  = map[string]int{}
		)

		for _, r := range rows {
			id := strings.TrimSpace(r.Fields["id"])
			sku := strings.ToLower(strings.TrimSpace(r.Fields["sku"]))

			var current *Product
			var currentID string
			switch {
			case id != "":
				if !validation.UUID(id) {
					problems = append(problems, ImportError{r.Line, "id bukan UUID yang sah."})
					continue
				}
				if seenID[id] != 0 {
					problems = append(problems, ImportError{r.Line,
						fmt.Sprintf("id sudah muncul di baris %d.", seenID[id])})
					continue
				}
				seenID[id] = r.Line
				p, ok := live.byID[id]
				if !ok {
					problems = append(problems, ImportError{r.Line, "id tidak dikenal; produk ini tidak ada."})
					continue
				}
				current, currentID = p, id
			case sku != "" && writable["sku"]:
				matches := live.bySKU[sku]
				switch len(matches) {
				case 0:
					// No existing product carries this SKU: a new one.
				case 1:
					current, currentID = matches[0], matches[0].ID
				default:
					problems = append(problems, ImportError{r.Line,
						fmt.Sprintf("SKU %s dipakai %d produk; perbaiki SKU-nya dulu.", r.Fields["sku"], len(matches))})
					continue
				}
			}

			if sku != "" {
				if seenSKU[sku] != 0 && seenSKU[sku] != r.Line {
					problems = append(problems, ImportError{r.Line,
						fmt.Sprintf("SKU %s sudah muncul di baris %d.", r.Fields["sku"], seenSKU[sku])})
					continue
				}
				seenSKU[sku] = r.Line
			}

			target := Product{ID: currentID}
			if current != nil {
				target = *current
				target.ID = currentID
			} else {
				missing := requiredMissing(writable)
				if len(missing) > 0 {
					problems = append(problems, ImportError{r.Line, fmt.Sprintf(
						"Baris ini butuh produk baru, tapi kolom %s tidak ada di header.",
						strings.Join(missing, ", "))})
					continue
				}
				target.IconKey = "restaurant"
				target.Available = true
			}

			if rowErr := applyRowFields(&target, r, writable, liveCategories, liveBrands); rowErr != "" {
				problems = append(problems, ImportError{r.Line, rowErr})
				continue
			}

			target.Name = strings.TrimSpace(target.Name)
			if strings.TrimSpace(target.IconKey) == "" {
				target.IconKey = "restaurant"
			}
			if errs := validateProduct(target); errs.Err() != nil {
				for field, msg := range errs {
					problems = append(problems, ImportError{r.Line, field + ": " + msg})
				}
				continue
			}

			if current != nil && sameProduct(*current, target) {
				result.Unchanged++
				continue
			}

			toWrite = append(toWrite, productWrite{target: target, creating: current == nil})
		}

		if len(problems) > 0 {
			sort.SliceStable(problems, func(i, j int) bool { return problems[i].Line < problems[j].Line })
			return problems
		}
		if len(toWrite) == 0 {
			return nil
		}
		if !commit {
			// The preview stops here. Nothing above this point wrote a row
			// or reserved a sequence number — only SELECT ... FOR UPDATE,
			// which releases its locks when the transaction ends either
			// way — so running this inside the very same committing
			// transaction as a real import is safe: there is nothing for a
			// rollback to undo that a commit-of-no-writes does not already
			// leave undone.
			result.Created, result.Updated = countCreates(toWrite)
			return nil
		}

		if err := writeProducts(ctx, w, tenantID, toWrite); err != nil {
			return err
		}
		result.Created, result.Updated = countCreates(toWrite)
		return nil
	}

	if err := s.feed.Write(ctx, tenantID, run); err != nil {
		return CatalogueImportResult{}, err
	}

	return result, nil
}

func requiredMissing(writable map[string]bool) []string {
	var missing []string
	for _, c := range requiredForCreate {
		if !writable[c] {
			missing = append(missing, c)
		}
	}
	return missing
}

type productWrite struct {
	target   Product
	creating bool
}

func countCreates(writes []productWrite) (created, updated int) {
	for _, w := range writes {
		if w.creating {
			created++
		} else {
			updated++
		}
	}
	return
}

func sameProduct(a, b Product) bool {
	return a.CategoryID == b.CategoryID &&
		eqStringPtr(a.BrandID, b.BrandID) &&
		a.Name == b.Name &&
		a.Price == b.Price &&
		eqInt64Ptr(a.Cost, b.Cost) &&
		eqStringPtr(a.SKU, b.SKU) &&
		eqFloatPtr(a.TaxRate, b.TaxRate) &&
		eqStringPtr(a.Description, b.Description) &&
		a.IconKey == b.IconKey &&
		a.SortOrder == b.SortOrder &&
		a.Available == b.Available &&
		a.IsPopular == b.IsPopular
}

func eqStringPtr(a, b *string) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}
func eqInt64Ptr(a, b *int64) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}
func eqFloatPtr(a, b *float64) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

// applyRowFields overlays only the columns present in the header onto
// target, which already holds either the current product's values (update)
// or the create defaults set by the caller. Returns a message naming what
// was wrong with the row, or "" when every present column read cleanly.
func applyRowFields(target *Product, r CatalogueRow, writable map[string]bool, liveCategories, liveBrands map[string]bool) string {
	if writable["name"] {
		target.Name = r.Fields["name"]
	}
	if writable["category_id"] {
		id := strings.TrimSpace(r.Fields["category_id"])
		if id == "" {
			return "category_id tidak boleh kosong."
		}
		if !validation.UUID(id) || !liveCategories[id] {
			return "Kategori tidak ditemukan."
		}
		target.CategoryID = id
	}
	if writable["brand_id"] {
		id := strings.TrimSpace(r.Fields["brand_id"])
		if id == "" {
			target.BrandID = nil
		} else if !validation.UUID(id) || !liveBrands[id] {
			return "Brand tidak ditemukan."
		} else {
			target.BrandID = &id
		}
	}
	if writable["sku"] {
		target.SKU = validation.Trimmed(r.Fields["sku"])
	}
	if writable["price"] {
		n, msg := validation.ParseRupiah(r.Fields["price"])
		if msg != "" {
			return "price: " + msg
		}
		target.Price = n
	}
	if writable["cost"] {
		raw := strings.TrimSpace(r.Fields["cost"])
		if raw == "" {
			target.Cost = nil
		} else {
			n, msg := validation.ParseRupiah(raw)
			if msg != "" {
				return "cost: " + msg
			}
			target.Cost = &n
		}
	}
	if writable["tax_rate"] {
		raw := strings.ReplaceAll(strings.TrimSpace(r.Fields["tax_rate"]), ",", ".")
		if raw == "" {
			target.TaxRate = nil
		} else {
			n, err := strconv.ParseFloat(raw, 64)
			if err != nil {
				return "tax_rate: harus angka."
			}
			target.TaxRate = &n
		}
	}
	if writable["description"] {
		target.Description = validation.Trimmed(r.Fields["description"])
	}
	if writable["icon_key"] {
		if ic := strings.TrimSpace(r.Fields["icon_key"]); ic != "" {
			target.IconKey = ic
		}
	}
	if writable["sort_order"] {
		raw := strings.TrimSpace(r.Fields["sort_order"])
		if raw == "" {
			target.SortOrder = 0
		} else {
			n, err := strconv.Atoi(raw)
			if err != nil {
				return "sort_order: harus angka bulat."
			}
			target.SortOrder = n
		}
	}
	if writable["available"] {
		target.Available = parseYesNo(r.Fields["available"])
	}
	if writable["is_popular"] {
		target.IsPopular = parseYesNo(r.Fields["is_popular"])
	}
	return ""
}

func parseYesNo(s string) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "ya", "yes", "true", "1", "on":
		return true
	default:
		return false
	}
}

type liveProducts struct {
	byID  map[string]*Product
	bySKU map[string][]*Product
}

// loadLiveProducts locks every live product of this tenant, the same
// escalation ImportPrices already makes for SKU-matched rows but extended to
// every row this importer might match by id too — a full-file import
// touches more of the menu than a price list ever did.
func loadLiveProducts(ctx context.Context, w *syncfeed.Writer, tenantID string) (liveProducts, error) {
	rows, err := w.Tx.Query(ctx, `
		SELECT p.id::text, p.category_id::text, p.brand_id::text, p.name, p.price, p.cost,
		       p.sku, p.tax_rate, p.description, p.icon_key, p.sort_order, p.available, p.is_popular
		FROM products p
		WHERE p.tenant_id = $1 AND p.deleted_at IS NULL
		FOR UPDATE OF p`, tenantID)
	if err != nil {
		return liveProducts{}, err
	}
	defer rows.Close()

	out := liveProducts{byID: map[string]*Product{}, bySKU: map[string][]*Product{}}
	for rows.Next() {
		p := &Product{}
		var brandID, sku *string
		if err := rows.Scan(&p.ID, &p.CategoryID, &brandID, &p.Name, &p.Price, &p.Cost,
			&sku, &p.TaxRate, &p.Description, &p.IconKey, &p.SortOrder, &p.Available, &p.IsPopular); err != nil {
			return liveProducts{}, err
		}
		p.BrandID, p.SKU = brandID, sku
		out.byID[p.ID] = p
		if sku != nil {
			key := strings.ToLower(strings.TrimSpace(*sku))
			if key != "" {
				out.bySKU[key] = append(out.bySKU[key], p)
			}
		}
	}

	return out, rows.Err()
}

// loadLiveIDs is the same "check it exists before writing" defence
// SaveProduct already runs per row, preloaded once so a 10,000-row import
// does not run 10,000 existence checks.
func loadLiveIDs(ctx context.Context, w *syncfeed.Writer, tenantID, table string) (map[string]bool, error) {
	rows, err := w.Tx.Query(ctx, fmt.Sprintf(
		`SELECT id::text FROM %s WHERE tenant_id = $1 AND deleted_at IS NULL`, table), tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := map[string]bool{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out[id] = true
	}
	return out, rows.Err()
}

// writeProducts upserts every row in one batched statement, numbered from
// one reserved block — the same shape ImportPrices' single-column UPDATE
// uses, generalised to every column a product carries. A create and an
// update are the same statement: COALESCE(id, gen_random_uuid()) is exactly
// what SaveProduct's own single-row INSERT already does.
func writeProducts(ctx context.Context, w *syncfeed.Writer, tenantID string, writes []productWrite) error {
	n := len(writes)
	ids := make([]string, n)
	categoryIDs := make([]string, n)
	brandIDs := make([]*string, n)
	names := make([]string, n)
	prices := make([]int64, n)
	costs := make([]*int64, n)
	skus := make([]*string, n)
	taxRates := make([]*float64, n)
	descriptions := make([]*string, n)
	iconKeys := make([]string, n)
	sortOrders := make([]int32, n)
	availables := make([]bool, n)
	isPopulars := make([]bool, n)

	for i, item := range writes {
		p := item.target
		ids[i] = p.ID
		categoryIDs[i] = p.CategoryID
		brandIDs[i] = p.BrandID
		names[i] = p.Name
		prices[i] = p.Price
		costs[i] = p.Cost
		skus[i] = p.SKU
		taxRates[i] = p.TaxRate
		descriptions[i] = p.Description
		iconKeys[i] = p.IconKey
		sortOrders[i] = int32(p.SortOrder)
		availables[i] = p.Available
		isPopulars[i] = p.IsPopular
	}

	first, err := w.SeqBlock(ctx, "products", int64(n))
	if err != nil {
		return err
	}

	_, err = w.Tx.Exec(ctx, `
		INSERT INTO products
			(id, tenant_id, category_id, brand_id, name, price, cost, sku, tax_rate,
			 description, icon_key, sort_order, available, is_popular, sync_seq)
		SELECT COALESCE(NULLIF(x.id, '')::uuid, gen_random_uuid()), $1, x.category_id::uuid, x.brand_id::uuid,
		       x.name, x.price, x.cost, x.sku, x.tax_rate, x.description, x.icon_key,
		       x.sort_order, x.available, x.is_popular, $2 + x.ord - 1
		FROM unnest($3::text[], $4::text[], $5::text[], $6::text[], $7::bigint[], $8::bigint[],
		            $9::text[], $10::double precision[], $11::text[], $12::text[], $13::int[],
		            $14::bool[], $15::bool[])
			WITH ORDINALITY AS x(id, category_id, brand_id, name, price, cost, sku, tax_rate,
			                      description, icon_key, sort_order, available, is_popular, ord)
		ON CONFLICT (id) DO UPDATE
		SET category_id = EXCLUDED.category_id,
		    brand_id    = EXCLUDED.brand_id,
		    name        = EXCLUDED.name,
		    price       = EXCLUDED.price,
		    cost        = EXCLUDED.cost,
		    sku         = EXCLUDED.sku,
		    tax_rate    = EXCLUDED.tax_rate,
		    description = EXCLUDED.description,
		    icon_key    = EXCLUDED.icon_key,
		    sort_order  = EXCLUDED.sort_order,
		    available   = EXCLUDED.available,
		    is_popular  = EXCLUDED.is_popular,
		    sync_seq    = EXCLUDED.sync_seq,
		    deleted_at  = NULL,
		    updated_at  = now()
		WHERE products.tenant_id = $1`,
		tenantID, first, ids, categoryIDs, brandIDs, names, prices, costs, skus, taxRates,
		descriptions, iconKeys, sortOrders, availables, isPopulars)
	return err
}
