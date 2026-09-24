package backoffice

import (
	"bytes"
	"encoding/csv"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/backoffice/views"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
)

// Handlers here translate forms to domain calls and back. The rules — what a
// valid price is, what a till would reject, what a delete must cascade — live
// in the catalogue package, so the Backoffice cannot accept what another
// writer would refuse.

// ---- categories -----------------------------------------------------------

func categoryForm(c catalogue.Category) views.Form {
	f := views.NewForm()
	f.Values["name"] = c.Name
	f.Values["icon_key"] = optionalString(c.IconKey)
	f.Values["sort_order"] = itoa(c.SortOrder)
	f.Values["is_popular"] = checkbox(c.IsPopular)
	return f
}

func categoryFromForm(f views.Form, id string) (catalogue.Category, *parser) {
	p := newParser(f)
	return catalogue.Category{
		ID:        id,
		Name:      p.text("name"),
		IconKey:   p.optionalText("icon_key"),
		SortOrder: p.integer("sort_order"),
		IsPopular: p.check("is_popular"),
	}, p
}

func (h *Handler) categoriesPage(w http.ResponseWriter, r *http.Request) {
	rows, err := h.catalogue.Categories(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	h.render(w, r, views.CategoriesPage(h.sessionView(r), rows, views.NewForm()))
}

func (h *Handler) createCategory(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}

	in, p := categoryFromForm(f, "")
	err := p.errs.Err()
	if err == nil {
		_, err = h.catalogue.SaveCategory(r.Context(), tenantOf(r), in)
	}

	if err != nil && !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}
	if err == nil {
		f = views.NewForm()
		toast(w, "Kategori ditambahkan.")
	}

	rows, loadErr := h.catalogue.Categories(r.Context(), tenantOf(r))
	if loadErr != nil {
		h.serverError(w, r, loadErr)
		return
	}
	h.render(w, r, views.CategoriesSection(rows, f))
}

func (h *Handler) categoryPage(w http.ResponseWriter, r *http.Request) {
	c, err := h.catalogue.Category(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	h.render(w, r, views.CategoryPage(h.sessionView(r), c.ID, categoryForm(c)))
}

func (h *Handler) updateCategory(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")

	in, p := categoryFromForm(f, id)
	err := p.errs.Err()
	if err == nil {
		_, err = h.catalogue.SaveCategory(r.Context(), tenantOf(r), in)
	}
	if !absorb(&f, err) && h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}
	if err == nil {
		toast(w, "Kategori disimpan.")
	}

	h.render(w, r, views.CategoryForm(id, f))
}

func (h *Handler) deleteCategory(w http.ResponseWriter, r *http.Request) {
	err := h.catalogue.DeleteCategory(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if errors.Is(err, catalogue.ErrCategoryInUse) {
		toastError(w, "Kategori masih berisi produk. Pindahkan atau hapus produknya dulu.")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	redirect(w, r, "/backoffice/catalogue/categories")
}

// ---- products -------------------------------------------------------------

func (h *Handler) categoryOptions(r *http.Request) ([]views.Option, error) {
	rows, err := h.catalogue.Categories(r.Context(), tenantOf(r))
	if err != nil {
		return nil, err
	}

	out := make([]views.Option, 0, len(rows))
	for _, c := range rows {
		out = append(out, views.Option{Value: c.ID, Label: c.Name})
	}
	return out, nil
}

func productForm(p catalogue.Product) views.Form {
	f := views.NewForm()
	f.Values["name"] = p.Name
	f.Values["category_id"] = p.CategoryID
	f.Values["price"] = i64toa(p.Price)
	if p.Cost != nil {
		f.Values["cost"] = i64toa(*p.Cost)
	}
	f.Values["sku"] = optionalString(p.SKU)
	f.Values["brand_id"] = optionalString(p.BrandID)
	if p.TaxRate != nil {
		f.Values["tax_rate"] = strconv.FormatFloat(*p.TaxRate, 'f', -1, 64)
	}
	f.Values["description"] = optionalString(p.Description)
	f.Values["icon_key"] = p.IconKey
	f.Values["sort_order"] = itoa(p.SortOrder)
	f.Values["available"] = checkbox(p.Available)
	f.Values["is_popular"] = checkbox(p.IsPopular)
	return f
}

func productFromForm(f views.Form, id string) (catalogue.Product, *parser) {
	p := newParser(f)
	return catalogue.Product{
		ID:          id,
		CategoryID:  p.text("category_id"),
		Name:        p.text("name"),
		Price:       p.money("price"),
		Cost:        p.optionalMoney("cost"),
		SKU:         p.optionalText("sku"),
		BrandID:     p.optionalText("brand_id"),
		TaxRate:     p.optionalRate("tax_rate"),
		Description: p.optionalText("description"),
		IconKey:     p.text("icon_key"),
		Available:   p.check("available"),
		IsPopular:   p.check("is_popular"),
		SortOrder:   p.integer("sort_order"),
	}, p
}

func (h *Handler) productsPage(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	filter := views.ProductFilter{
		Query:      r.URL.Query().Get("q"),
		CategoryID: r.URL.Query().Get("category"),
		Page:       max(page, 1),
	}

	result, err := h.catalogue.Products(r.Context(), tenantOf(r), catalogue.ProductFilter{
		Query: filter.Query, CategoryID: filter.CategoryID, Page: filter.Page,
	})
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	// Search, filter and paging swap only the list; a full navigation to the
	// same URL — a bookmark, a refresh — gets the whole page.
	if isHX(r) && r.Header.Get("HX-Target") == "product-list" {
		h.render(w, r, views.ProductList(filter, result))
		return
	}

	categories, err := h.categoryOptions(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	h.render(w, r, views.ProductsPage(h.sessionView(r), categories, filter, result))
}

func (h *Handler) newProductPage(w http.ResponseWriter, r *http.Request) {
	categories, err := h.categoryOptions(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	brands, err := h.brandOptions(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	f := views.NewForm()
	f.Values["available"] = "on"
	f.Values["icon_key"] = "restaurant"
	h.render(w, r, views.ProductNewPage(h.sessionView(r), withBlank(categories), brands, f))
}

func (h *Handler) createProduct(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}

	in, p := productFromForm(f, "")
	err := p.errs.Err()
	var id string
	if err == nil {
		id, err = h.catalogue.SaveProduct(r.Context(), tenantOf(r), in)
	}
	if err == nil {
		redirect(w, r, "/backoffice/catalogue/products/"+id)
		return
	}
	if !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}

	categories, loadErr := h.categoryOptions(r)
	if loadErr != nil {
		h.serverError(w, r, loadErr)
		return
	}
	brands, loadErr := h.brandOptions(r)
	if loadErr != nil {
		h.serverError(w, r, loadErr)
		return
	}
	h.render(w, r, views.ProductForm("/backoffice/catalogue/products", withBlank(categories), brands, f))
}

func (h *Handler) productPage(w http.ResponseWriter, r *http.Request) {
	tenantID, id := tenantOf(r), chi.URLParam(r, "id")

	product, err := h.catalogue.Product(r.Context(), tenantID, id)
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	categories, err := h.categoryOptions(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}
	brands, err := h.brandOptions(r)
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	groups, modifiers, err := h.productModifiers(r, id)
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	h.render(w, r, views.ProductPage(h.sessionView(r), id, categories, brands,
		productForm(product.Product), product.ImageURL, product.Variants, groups, modifiers))
}

func (h *Handler) updateProduct(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")

	in, p := productFromForm(f, id)
	err := p.errs.Err()
	if err == nil {
		_, err = h.catalogue.SaveProduct(r.Context(), tenantOf(r), in)
	}
	if !absorb(&f, err) && h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}
	if err == nil {
		toast(w, "Produk disimpan.")
	}

	categories, loadErr := h.categoryOptions(r)
	if loadErr != nil {
		h.serverError(w, r, loadErr)
		return
	}
	brands, loadErr := h.brandOptions(r)
	if loadErr != nil {
		h.serverError(w, r, loadErr)
		return
	}
	h.render(w, r, views.ProductForm("/backoffice/catalogue/products/"+id, categories, brands, f))
}

func (h *Handler) setProductAvailability(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		h.renderStatus(w, r, http.StatusBadRequest, views.ErrorCard("Formulir tidak terbaca."))
		return
	}
	tenantID, id := tenantOf(r), chi.URLParam(r, "id")

	err := h.catalogue.SetAvailability(r.Context(), tenantID, id, r.PostFormValue("available") == "on")
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	product, err := h.catalogue.Product(r.Context(), tenantID, id)
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	h.render(w, r, views.ProductRow(catalogue.ProductRow{
		ID: product.ID, Name: product.Name, SKU: product.SKU, Price: product.Price,
		Available: product.Available, VariantCount: len(product.Variants),
		CategoryName: h.categoryName(r, product.CategoryID),
	}))
}

func (h *Handler) categoryName(r *http.Request, id string) string {
	c, err := h.catalogue.Category(r.Context(), tenantOf(r), id)
	if err != nil {
		return ""
	}
	return c.Name
}

func (h *Handler) deleteProduct(w http.ResponseWriter, r *http.Request) {
	err := h.catalogue.DeleteProduct(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	redirect(w, r, "/backoffice/catalogue/products")
}

// ---- product image ------------------------------------------------------

// maxImageUploadBytes leaves room for the multipart framing around the largest
// image the domain accepts, and is enforced before anything is buffered.
const maxImageUploadBytes = catalogue.MaxImageBytes + 1<<20

func (h *Handler) uploadProductImage(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	r.Body = http.MaxBytesReader(w, r.Body, maxImageUploadBytes)
	if err := r.ParseMultipartForm(maxImageUploadBytes); err != nil {
		h.renderProductImage(w, r, id, "Berkas tidak terbaca atau lebih dari 10 MB.")
		return
	}
	defer r.MultipartForm.RemoveAll()

	file, _, err := r.FormFile("image")
	if err != nil {
		h.renderProductImage(w, r, id, "Pilih berkas gambar.")
		return
	}
	defer file.Close()

	data, err := io.ReadAll(io.LimitReader(file, catalogue.MaxImageBytes+1))
	if err != nil {
		h.renderProductImage(w, r, id, "Berkas tidak terbaca.")
		return
	}

	_, err = h.catalogue.SetProductImage(r.Context(), tenantOf(r), id, data)
	if fields, ok := validation.As(err); ok {
		h.renderProductImage(w, r, id, fields["image"])
		return
	}
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	toast(w, "Gambar disimpan. Till menerimanya pada sinkron berikutnya.")
	h.renderProductImage(w, r, id, "")
}

func (h *Handler) removeProductImage(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	err := h.catalogue.RemoveProductImage(r.Context(), tenantOf(r), id)
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	toast(w, "Gambar dihapus.")
	h.renderProductImage(w, r, id, "")
}

// renderProductImage re-reads the product, so the card shows what is stored
// rather than what the request hoped for.
func (h *Handler) renderProductImage(w http.ResponseWriter, r *http.Request, productID, problem string) {
	product, err := h.catalogue.Product(r.Context(), tenantOf(r), productID)
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	h.render(w, r, views.ProductImageCard(productID, product.ImageURL, problem))
}

// ---- variants -------------------------------------------------------------

func (h *Handler) saveVariant(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	tenantID, productID, variantID := tenantOf(r), chi.URLParam(r, "id"), chi.URLParam(r, "variantID")

	p := newParser(f)
	in := catalogue.Variant{
		ID: variantID, ProductID: productID,
		Name: p.text("name"), PriceDelta: p.money("price_delta"), SortOrder: p.integer("sort_order"),
	}
	err := p.errs.Err()
	if err == nil {
		_, err = h.catalogue.SaveVariant(r.Context(), tenantID, in)
	}
	if !absorb(&f, err) && h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	failed := ""
	if err != nil {
		failed = variantID
		if failed == "" {
			failed = "new"
		}
	} else {
		f = views.NewForm()
		toast(w, "Varian disimpan.")
	}

	h.renderVariants(w, r, productID, failed, f)
}

func (h *Handler) deleteVariant(w http.ResponseWriter, r *http.Request) {
	productID := chi.URLParam(r, "id")

	err := h.catalogue.DeleteVariant(r.Context(), tenantOf(r), chi.URLParam(r, "variantID"))
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	toast(w, "Varian dihapus.")
	h.renderVariants(w, r, productID, "", views.NewForm())
}

func (h *Handler) renderVariants(w http.ResponseWriter, r *http.Request, productID, failed string, f views.Form) {
	product, err := h.catalogue.Product(r.Context(), tenantOf(r), productID)
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	h.render(w, r, views.VariantsCard(productID, product.Variants, failed, f))
}

// ---- product modifier configuration --------------------------------------

func (h *Handler) productModifiers(r *http.Request, productID string) ([]catalogue.ModifierGroup, views.Form, error) {
	groups, err := h.catalogue.ModifierGroups(r.Context(), tenantOf(r))
	if err != nil {
		return nil, views.Form{}, err
	}

	cfg, err := h.catalogue.ProductModifiers(r.Context(), tenantOf(r), productID)
	if err != nil {
		return nil, views.Form{}, err
	}

	f := views.NewForm()
	f.Multi["group"] = cfg.GroupIDs
	f.Multi["option"] = cfg.OptionIDs
	f.Multi["default"] = cfg.DefaultOptionIDs
	return groups, f, nil
}

func (h *Handler) saveProductModifiers(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r, "group", "option", "default")
	if !ok {
		return
	}
	productID := chi.URLParam(r, "id")

	err := h.catalogue.SaveProductModifiers(r.Context(), tenantOf(r), productID, catalogue.ProductModifiers{
		GroupIDs:         f.Multi["group"],
		OptionIDs:        f.Multi["option"],
		DefaultOptionIDs: f.Multi["default"],
	})
	if !absorb(&f, err) && h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	groups, saved, loadErr := h.productModifiers(r, productID)
	if loadErr != nil {
		h.serverError(w, r, loadErr)
		return
	}
	if err == nil {
		// Re-read rather than echo: what the till will receive is what was
		// stored, and showing the stored state is the only honest confirmation.
		f = saved
		toast(w, "Modifier produk disimpan.")
	}

	h.render(w, r, views.ProductModifiersCard(productID, groups, f))
}

// ---- price-list import ----------------------------------------------------

func (h *Handler) importPage(w http.ResponseWriter, r *http.Request) {
	h.render(w, r, views.ImportPage(h.sessionView(r)))
}

// maxImportBytes bounds the upload before anything is parsed. A 10,000-line
// price list is a few hundred kilobytes.
const maxImportBytes = 2 << 20

// applyLegacyPriceList is what importPrices used to run as its own HTTP
// handler, unchanged: scripts/verify-backoffice-crud pins its toast text and
// its one-shot-apply behaviour, so this keeps reading and behaving exactly
// as it always has. importProducts (catalogue_io.go) is the route's actual
// entry point now and calls here only when the upload is the legacy
// two-column shape; raw is the upload's bytes, already read once by it.
func (h *Handler) applyLegacyPriceList(w http.ResponseWriter, r *http.Request, raw []byte) {
	rows, problems := readPriceList(bytes.NewReader(raw))
	if len(problems) > 0 {
		h.render(w, r, views.ImportResult(0, 0, problems))
		return
	}

	result, err := h.catalogue.ImportPrices(r.Context(), tenantOf(r), rows)
	var refused catalogue.ImportErrors
	switch {
	case errors.As(err, &refused):
		h.render(w, r, views.ImportResult(0, 0, refused))
	case err != nil:
		h.serverError(w, r, err)
	default:
		toast(w, "Harga diterapkan.")
		h.render(w, r, views.ImportResult(result.Changed, result.Unchanged, nil))
	}
}

// readPriceList parses a CSV with an "sku" column and a "harga" (or "price")
// column. Semicolons are accepted as well as commas, because that is what a
// spreadsheet saves under an Indonesian locale. Every unreadable line is
// reported, so one upload shows every problem rather than the first.
func readPriceList(src io.Reader) ([]catalogue.PriceChange, []catalogue.ImportError) {
	raw, err := io.ReadAll(src)
	if err != nil {
		return nil, []catalogue.ImportError{{Message: "Berkas tidak terbaca."}}
	}
	// Excel writes a byte-order mark before the header, which would otherwise
	// make the first column name start with an invisible character.
	text := strings.TrimPrefix(string(raw), string(rune(0xFEFF)))

	reader := csv.NewReader(strings.NewReader(text))
	firstLine, _, _ := strings.Cut(text, "\n")
	if strings.Count(firstLine, ";") > strings.Count(firstLine, ",") {
		reader.Comma = ';'
	}
	reader.FieldsPerRecord = -1

	records, err := reader.ReadAll()
	if err != nil || len(records) == 0 {
		return nil, []catalogue.ImportError{{Message: "Berkas bukan CSV yang valid."}}
	}

	skuCol, priceCol := -1, -1
	for i, name := range records[0] {
		switch strings.ToLower(strings.TrimSpace(name)) {
		case "sku":
			skuCol = i
		case "harga", "price":
			priceCol = i
		}
	}
	if skuCol < 0 || priceCol < 0 {
		return nil, []catalogue.ImportError{{Line: 1, Message: `Baris pertama harus berisi kolom "sku" dan "harga".`}}
	}

	var (
		rows     []catalogue.PriceChange
		problems []catalogue.ImportError
	)
	for i, record := range records[1:] {
		line := i + 2
		if len(record) <= max(skuCol, priceCol) {
			if strings.TrimSpace(strings.Join(record, "")) != "" {
				problems = append(problems, catalogue.ImportError{Line: line, Message: "Kolom kurang."})
			}
			continue
		}

		price, message := parseRupiah(record[priceCol])
		if message == "" && strings.TrimSpace(record[priceCol]) == "" {
			message = "Harga kosong."
		}
		if message != "" {
			problems = append(problems, catalogue.ImportError{Line: line, Message: message})
			continue
		}

		rows = append(rows, catalogue.PriceChange{Line: line, SKU: record[skuCol], Price: price})
	}

	return rows, problems
}

// ---- modifier groups and options -----------------------------------------

func groupForm(g catalogue.ModifierGroup) views.Form {
	f := views.NewForm()
	f.Values["name"] = g.Name
	f.Values["selection_type"] = g.SelectionType
	if g.MaxSelect != nil {
		f.Values["max_select"] = itoa(*g.MaxSelect)
	}
	f.Values["sort_order"] = itoa(g.SortOrder)
	f.Values["required"] = checkbox(g.Required)
	f.Values["active"] = checkbox(g.Active)
	return f
}

func groupFromForm(f views.Form, id string) (catalogue.ModifierGroup, *parser) {
	p := newParser(f)
	return catalogue.ModifierGroup{
		ID:            id,
		Name:          p.text("name"),
		SelectionType: p.text("selection_type"),
		Required:      p.check("required"),
		MaxSelect:     p.optionalInteger("max_select"),
		SortOrder:     p.integer("sort_order"),
		Active:        p.check("active"),
	}, p
}

func newGroupForm() views.Form {
	f := views.NewForm()
	f.Values["selection_type"] = catalogue.SelectSingle
	f.Values["active"] = "on"
	return f
}

func (h *Handler) modifiersPage(w http.ResponseWriter, r *http.Request) {
	groups, err := h.catalogue.ModifierGroups(r.Context(), tenantOf(r))
	if err != nil {
		h.serverError(w, r, err)
		return
	}

	h.render(w, r, views.ModifiersPage(h.sessionView(r), groups, newGroupForm()))
}

func (h *Handler) createModifierGroup(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}

	in, p := groupFromForm(f, "")
	err := p.errs.Err()
	var id string
	if err == nil {
		id, err = h.catalogue.SaveModifierGroup(r.Context(), tenantOf(r), in)
	}
	if err == nil {
		redirect(w, r, "/backoffice/catalogue/modifiers/"+id)
		return
	}
	if !absorb(&f, err) {
		h.serverError(w, r, err)
		return
	}

	groups, loadErr := h.catalogue.ModifierGroups(r.Context(), tenantOf(r))
	if loadErr != nil {
		h.serverError(w, r, loadErr)
		return
	}
	h.render(w, r, views.ModifiersSection(groups, f))
}

func (h *Handler) modifierGroupPage(w http.ResponseWriter, r *http.Request) {
	g, err := h.catalogue.ModifierGroup(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	h.render(w, r, views.ModifierGroupPage(h.sessionView(r), g, groupForm(g)))
}

func (h *Handler) updateModifierGroup(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	id := chi.URLParam(r, "id")

	in, p := groupFromForm(f, id)
	err := p.errs.Err()
	if err == nil {
		_, err = h.catalogue.SaveModifierGroup(r.Context(), tenantOf(r), in)
	}
	if !absorb(&f, err) && h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}
	if err == nil {
		toast(w, "Grup disimpan.")
	}

	h.render(w, r, views.ModifierGroupForm(id, f))
}

func (h *Handler) deleteModifierGroup(w http.ResponseWriter, r *http.Request) {
	err := h.catalogue.DeleteModifierGroup(r.Context(), tenantOf(r), chi.URLParam(r, "id"))
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	redirect(w, r, "/backoffice/catalogue/modifiers")
}

func (h *Handler) saveModifierOption(w http.ResponseWriter, r *http.Request) {
	f, ok := h.parseForm(w, r)
	if !ok {
		return
	}
	groupID, optionID := chi.URLParam(r, "id"), chi.URLParam(r, "optionID")

	p := newParser(f)
	in := catalogue.ModifierOption{
		ID: optionID, GroupID: groupID,
		Name: p.text("name"), PriceDelta: p.money("price_delta"),
		SortOrder: p.integer("sort_order"), Active: p.check("active"),
	}
	err := p.errs.Err()
	if err == nil {
		_, err = h.catalogue.SaveModifierOption(r.Context(), tenantOf(r), in)
	}
	if !absorb(&f, err) && h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	failed := ""
	if err != nil {
		failed = optionID
		if failed == "" {
			failed = "new"
		}
	} else {
		f = views.NewForm()
		toast(w, "Opsi disimpan.")
	}

	h.renderOptions(w, r, groupID, failed, f)
}

func (h *Handler) deleteModifierOption(w http.ResponseWriter, r *http.Request) {
	groupID := chi.URLParam(r, "id")

	err := h.catalogue.DeleteModifierOption(r.Context(), tenantOf(r), chi.URLParam(r, "optionID"))
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	toast(w, "Opsi dihapus.")
	h.renderOptions(w, r, groupID, "", views.NewForm())
}

func (h *Handler) renderOptions(w http.ResponseWriter, r *http.Request, groupID, failed string, f views.Form) {
	g, err := h.catalogue.ModifierGroup(r.Context(), tenantOf(r), groupID)
	if h.failed(w, r, err, catalogue.ErrNotFound) {
		return
	}

	h.render(w, r, views.OptionsCard(g, failed, f))
}

// withBlank puts an empty choice first, so a new product's category has to be
// picked on purpose instead of defaulting to whatever sorts first.
func withBlank(options []views.Option) []views.Option {
	return append([]views.Option{{Value: "", Label: "— pilih kategori —"}}, options...)
}
