package catalogue_test

import (
	"context"
	"fmt"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
)

func (f fixture) counter(t *testing.T, entity string) int64 {
	t.Helper()

	var seq int64
	require.NoError(t, f.db.Owner.QueryRow(context.Background(),
		`SELECT COALESCE(max(last_seq), 0) FROM sync_counters WHERE scope_key = $1`,
		syncfeed.CompanyScope(f.tenantID, entity)).Scan(&seq))
	return seq
}

func (f fixture) category(t *testing.T, name string) string {
	t.Helper()

	id, err := f.svc.SaveCategory(context.Background(), f.tenantID, catalogue.Category{Name: name})
	require.NoError(t, err)
	return id
}

func requireField(t *testing.T, err error, field string) {
	t.Helper()

	fields, ok := validation.As(err)
	require.True(t, ok, "expected a validation error on %q, got %v", field, err)
	require.Contains(t, fields, field)
}

func TestProductRulesLiveInTheDomain(t *testing.T) {
	f := newFixture(t)
	categoryID := f.category(t, "Makanan")
	rate := 101.0

	for name, tc := range map[string]struct {
		product catalogue.Product
		field   string
	}{
		"negative price": {catalogue.Product{CategoryID: categoryID, Name: "X", Price: -1}, "price"},
		"tax over 100":   {catalogue.Product{CategoryID: categoryID, Name: "X", TaxRate: &rate}, "tax_rate"},
		"no category":    {catalogue.Product{Name: "X"}, "category_id"},
		"nameless":       {catalogue.Product{CategoryID: categoryID}, "name"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := f.svc.SaveProduct(context.Background(), f.tenantID, tc.product)
			requireField(t, err, tc.field)
		})
	}
}

// A retired category still satisfies the foreign key, so only the domain can
// stop a product being filed under a heading no till shows.
func TestAProductCannotBeFiledUnderARetiredCategory(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID := f.category(t, "Musiman")
	require.NoError(t, f.svc.DeleteCategory(ctx, f.tenantID, categoryID))

	_, err := f.svc.SaveProduct(ctx, f.tenantID, catalogue.Product{CategoryID: categoryID, Name: "Es Buah", Price: 10_000})
	requireField(t, err, "category_id")
}

// A variant is a delta on the base price. Whichever of the two moves, the
// result must never be a line that pays the customer.
func TestNoVariantMayTakeAPriceBelowZero(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	productID, err := f.svc.SaveProduct(ctx, f.tenantID, catalogue.Product{
		CategoryID: f.category(t, "Minuman"), Name: "Kopi", Price: 10_000,
	})
	require.NoError(t, err)

	_, err = f.svc.SaveVariant(ctx, f.tenantID, catalogue.Variant{ProductID: productID, Name: "Kecil", PriceDelta: -15_000})
	requireField(t, err, "price_delta")

	_, err = f.svc.SaveVariant(ctx, f.tenantID, catalogue.Variant{ProductID: productID, Name: "Kecil", PriceDelta: -5_000})
	require.NoError(t, err)

	product, err := f.svc.Product(ctx, f.tenantID, productID)
	require.NoError(t, err)
	product.Price = 4_000
	_, err = f.svc.SaveProduct(ctx, f.tenantID, product.Product)
	requireField(t, err, "price")
}

// The sold-out switch is flipped in the middle of a service, often more than
// once. Only a real change may wake the fleet.
func TestAvailabilityPublishesOnlyWhenItMoves(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	productID := f.saveProduct(t, f.category(t, "Makanan"), "Nasi Goreng")
	before := f.counter(t, "products")

	require.NoError(t, f.svc.SetAvailability(ctx, f.tenantID, productID, true))
	require.Equal(t, before, f.counter(t, "products"), "already available: nothing to publish")

	require.NoError(t, f.svc.SetAvailability(ctx, f.tenantID, productID, false))
	require.Equal(t, before+1, f.counter(t, "products"))

	rows := f.rows(t, "products", before)
	require.Len(t, rows, 1)
	require.Equal(t, false, rows[0]["available"])
}

func TestTheProductListSearchesFiltersAndPages(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	coffee := f.category(t, "Kopi")
	tea := f.category(t, "Teh")
	for i := range catalogue.ProductPageSize + 5 {
		f.saveProduct(t, coffee, fmt.Sprintf("Kopi %02d", i))
	}
	f.saveProduct(t, tea, "Teh Manis")
	f.saveProduct(t, tea, "Teh Diskon 50%")

	first, err := f.svc.Products(ctx, f.tenantID, catalogue.ProductFilter{Page: 1})
	require.NoError(t, err)
	require.Len(t, first.Rows, catalogue.ProductPageSize)
	require.True(t, first.HasMore)

	second, err := f.svc.Products(ctx, f.tenantID, catalogue.ProductFilter{Page: 2})
	require.NoError(t, err)
	require.Len(t, second.Rows, 7)
	require.False(t, second.HasMore)

	teas, err := f.svc.Products(ctx, f.tenantID, catalogue.ProductFilter{CategoryID: tea})
	require.NoError(t, err)
	require.Len(t, teas.Rows, 2)

	// "%" is a wildcard to ILIKE. Unescaped, this search would match the whole
	// menu instead of the one product that mentions it.
	percent, err := f.svc.Products(ctx, f.tenantID, catalogue.ProductFilter{Query: "50%"})
	require.NoError(t, err)
	require.Len(t, percent.Rows, 1)
	require.Equal(t, "Teh Diskon 50%", percent.Rows[0].Name)
}

// modifierFixture is a group with three options, attached to one product with
// two of them offered and one pre-selected.
type modifierFixture struct {
	productID string
	groupID   string
	options   []string
}

func (f fixture) modifiers(t *testing.T, selection string, required bool) modifierFixture {
	t.Helper()
	ctx := context.Background()

	m := modifierFixture{productID: f.saveProduct(t, f.category(t, "Minuman"), "Kopi Susu")}

	var err error
	m.groupID, err = f.svc.SaveModifierGroup(ctx, f.tenantID, catalogue.ModifierGroup{
		Name: "Gula", SelectionType: selection, Required: required, Active: true,
	})
	require.NoError(t, err)

	for _, name := range []string{"Normal", "Sedikit", "Tanpa"} {
		id, err := f.svc.SaveModifierOption(ctx, f.tenantID, catalogue.ModifierOption{
			GroupID: m.groupID, Name: name, Active: true,
		})
		require.NoError(t, err)
		m.options = append(m.options, id)
	}

	require.NoError(t, f.svc.SaveProductModifiers(ctx, f.tenantID, m.productID, catalogue.ProductModifiers{
		GroupIDs:         []string{m.groupID},
		OptionIDs:        []string{m.options[0], m.options[1]},
		DefaultOptionIDs: []string{m.options[0]},
	}))

	return m
}

// On the device every one of these cascades from the group. Rows left alive
// here would never be mentioned to a till again after it deleted them.
func TestDeletingAModifierGroupRetiresEverythingTheTillCascades(t *testing.T) {
	f := newFixture(t)
	m := f.modifiers(t, catalogue.SelectSingle, false)

	require.NoError(t, f.svc.DeleteModifierGroup(context.Background(), f.tenantID, m.groupID))

	for _, entity := range []string{
		"modifier_groups", "modifier_options", "product_modifier_groups", "product_modifier_options",
	} {
		rows := f.rows(t, entity, 0)
		require.NotEmpty(t, rows, entity)
		for _, row := range rows {
			require.NotNil(t, row["deleted_at_ms"], "%s left a row the till has already cascaded away", entity)
		}
	}
}

func TestDeletingAnOptionRetiresItsProductScoping(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	m := f.modifiers(t, catalogue.SelectMultiple, false)

	require.NoError(t, f.svc.DeleteModifierOption(ctx, f.tenantID, m.options[1]))

	cfg, err := f.svc.ProductModifiers(ctx, f.tenantID, m.productID)
	require.NoError(t, err)
	require.ElementsMatch(t, []string{m.options[0]}, cfg.OptionIDs)

	for _, row := range f.rows(t, "product_modifier_options", 0) {
		if row["option_id"] == m.options[1] {
			require.NotNil(t, row["deleted_at_ms"])
		}
	}
}

// The till's own saveConfiguration rules, so no tablet ever receives a
// configuration its form would reject — plus one it cannot recover from: a
// required group offering nothing makes the product impossible to sell.
func TestModifierConfigurationFollowsTheTillsRules(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	single := f.modifiers(t, catalogue.SelectSingle, false)
	required := f.modifiers(t, catalogue.SelectMultiple, true)

	stranger, err := f.svc.SaveModifierGroup(ctx, f.tenantID, catalogue.ModifierGroup{
		Name: "Topping", SelectionType: catalogue.SelectMultiple, Active: true,
	})
	require.NoError(t, err)
	strangerOption, err := f.svc.SaveModifierOption(ctx, f.tenantID, catalogue.ModifierOption{
		GroupID: stranger, Name: "Boba", Active: true,
	})
	require.NoError(t, err)

	for name, tc := range map[string]struct {
		product string
		cfg     catalogue.ProductModifiers
	}{
		"option from an unattached group": {single.productID, catalogue.ProductModifiers{
			GroupIDs: []string{single.groupID}, OptionIDs: []string{strangerOption}}},
		"default that is not offered": {single.productID, catalogue.ProductModifiers{
			GroupIDs: []string{single.groupID}, OptionIDs: []string{single.options[0]},
			DefaultOptionIDs: []string{single.options[1]}}},
		"two defaults in a single group": {single.productID, catalogue.ProductModifiers{
			GroupIDs: []string{single.groupID}, OptionIDs: single.options[:2],
			DefaultOptionIDs: single.options[:2]}},
		"required group offering nothing": {required.productID, catalogue.ProductModifiers{
			GroupIDs: []string{required.groupID}}},
	} {
		t.Run(name, func(t *testing.T) {
			requireField(t, f.svc.SaveProductModifiers(ctx, f.tenantID, tc.product, tc.cfg), "modifiers")
		})
	}
}

func TestSavingTheSameModifierConfigurationWakesNobody(t *testing.T) {
	f := newFixture(t)
	m := f.modifiers(t, catalogue.SelectSingle, false)
	groups, options := f.counter(t, "product_modifier_groups"), f.counter(t, "product_modifier_options")

	require.NoError(t, f.svc.SaveProductModifiers(context.Background(), f.tenantID, m.productID,
		catalogue.ProductModifiers{
			GroupIDs:         []string{m.groupID},
			OptionIDs:        []string{m.options[1], m.options[0]},
			DefaultOptionIDs: []string{m.options[0]},
		}))

	require.Equal(t, groups, f.counter(t, "product_modifier_groups"))
	require.Equal(t, options, f.counter(t, "product_modifier_options"))
}

func TestChangingADefaultRestampsOnlyThatRow(t *testing.T) {
	f := newFixture(t)
	m := f.modifiers(t, catalogue.SelectSingle, false)
	before := f.counter(t, "product_modifier_options")

	require.NoError(t, f.svc.SaveProductModifiers(context.Background(), f.tenantID, m.productID,
		catalogue.ProductModifiers{
			GroupIDs:         []string{m.groupID},
			OptionIDs:        []string{m.options[0], m.options[1]},
			DefaultOptionIDs: []string{m.options[1]},
		}))

	// Both rows changed their is_default, and nothing else did.
	require.Equal(t, before+2, f.counter(t, "product_modifier_options"))
}

// Turning "Gula" into a single-choice group while a product pre-selects two
// of its options would hand every till a default no picker can show.
func TestAGroupCannotBeNarrowedBelowAProductsDefaults(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	m := f.modifiers(t, catalogue.SelectMultiple, false)

	require.NoError(t, f.svc.SaveProductModifiers(ctx, f.tenantID, m.productID, catalogue.ProductModifiers{
		GroupIDs: []string{m.groupID}, OptionIDs: m.options[:2], DefaultOptionIDs: m.options[:2],
	}))

	_, err := f.svc.SaveModifierGroup(ctx, f.tenantID, catalogue.ModifierGroup{
		ID: m.groupID, Name: "Gula", SelectionType: catalogue.SelectSingle, Active: true,
	})
	requireField(t, err, "max_select")
}

func TestAnOptionThatIsADefaultCannotBeSwitchedOff(t *testing.T) {
	f := newFixture(t)
	m := f.modifiers(t, catalogue.SelectSingle, false)

	_, err := f.svc.SaveModifierOption(context.Background(), f.tenantID, catalogue.ModifierOption{
		ID: m.options[0], GroupID: m.groupID, Name: "Normal", Active: false,
	})
	requireField(t, err, "active")
}

func (f fixture) productWithSKU(t *testing.T, categoryID, name, sku string, price int64) string {
	t.Helper()

	id, err := f.svc.SaveProduct(context.Background(), f.tenantID, catalogue.Product{
		CategoryID: categoryID, Name: name, SKU: &sku, Price: price, Available: true,
	})
	require.NoError(t, err)
	return id
}

// Half a price list is worse than either whole one: some tills charge the new
// prices, some the old, and nobody can tell from the file which rows landed.
func TestAPriceListIsAllOrNothing(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID := f.category(t, "Makanan")
	nasi := f.productWithSKU(t, categoryID, "Nasi Goreng", "NG-01", 25_000)
	before := f.counter(t, "products")

	_, err := f.svc.ImportPrices(ctx, f.tenantID, []catalogue.PriceChange{
		{Line: 2, SKU: "NG-01", Price: 27_000},
		{Line: 3, SKU: "TIDAK-ADA", Price: 1_000},
	})

	var problems catalogue.ImportErrors
	require.ErrorAs(t, err, &problems)
	require.Len(t, problems, 1)
	require.Equal(t, 3, problems[0].Line)

	require.Equal(t, before, f.counter(t, "products"), "a refused file must change nothing")
	product, err := f.svc.Product(ctx, f.tenantID, nasi)
	require.NoError(t, err)
	require.EqualValues(t, 25_000, product.Price)
}

// A SKU is not unique in the schema. Guessing which of two products a price
// was meant for is how the wrong item gets repriced.
func TestAnAmbiguousSKUIsRefused(t *testing.T) {
	f := newFixture(t)
	categoryID := f.category(t, "Makanan")
	f.productWithSKU(t, categoryID, "Nasi Goreng", "DUP", 25_000)
	f.productWithSKU(t, categoryID, "Mie Goreng", "dup", 22_000)

	_, err := f.svc.ImportPrices(context.Background(), f.tenantID,
		[]catalogue.PriceChange{{Line: 2, SKU: "Dup", Price: 30_000}})

	var problems catalogue.ImportErrors
	require.ErrorAs(t, err, &problems)
	require.Contains(t, problems[0].Message, "2 produk")
}

// Re-uploading the same list must not wake every till to pull 5,000 unchanged
// rows; the rows that did change each get their own number.
func TestOnlyChangedPricesAreNumbered(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID := f.category(t, "Makanan")
	f.productWithSKU(t, categoryID, "Nasi Goreng", "NG-01", 25_000)
	f.productWithSKU(t, categoryID, "Mie Goreng", "MG-01", 22_000)
	f.productWithSKU(t, categoryID, "Es Teh", "ET-01", 5_000)
	before := f.counter(t, "products")

	result, err := f.svc.ImportPrices(ctx, f.tenantID, []catalogue.PriceChange{
		{Line: 2, SKU: "ng-01", Price: 27_000},
		{Line: 3, SKU: "MG-01", Price: 22_000},
		{Line: 4, SKU: "ET-01", Price: 6_000},
	})
	require.NoError(t, err)
	require.Equal(t, catalogue.ImportResult{Changed: 2, Unchanged: 1}, result)
	require.Equal(t, before+2, f.counter(t, "products"))

	rows := f.rows(t, "products", before)
	require.Len(t, rows, 2)
	require.NotEqual(t, rows[0]["sync_seq"], rows[1]["sync_seq"], "rows may not share a number")

	again, err := f.svc.ImportPrices(ctx, f.tenantID, []catalogue.PriceChange{{Line: 2, SKU: "NG-01", Price: 27_000}})
	require.NoError(t, err)
	require.Equal(t, 0, again.Changed)
	require.Equal(t, before+2, f.counter(t, "products"))
}
