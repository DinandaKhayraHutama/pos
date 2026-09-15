package catalogue_test

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
)

// An id from another merchant must read as "not found" on every write path,
// never as a database error. Row-level security hides the row, and an upsert
// that collides with a row it cannot see fails with a policy violation — which
// would surface as a 500 and tell the caller the id exists somewhere.
func TestSavingUnderAnotherMerchantsIDIsNotFound(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	var otherTenant string
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Warung Beta', 'beta') RETURNING id`).Scan(&otherTenant))

	categoryID := f.category(t, "Makanan")
	productID := f.saveProduct(t, categoryID, "Nasi Goreng")
	variantID, err := f.svc.SaveVariant(ctx, f.tenantID, catalogue.Variant{ProductID: productID, Name: "Besar"})
	require.NoError(t, err)
	groupID, err := f.svc.SaveModifierGroup(ctx, f.tenantID, catalogue.ModifierGroup{
		Name: "Gula", SelectionType: catalogue.SelectSingle, Active: true})
	require.NoError(t, err)
	optionID, err := f.svc.SaveModifierOption(ctx, f.tenantID, catalogue.ModifierOption{
		GroupID: groupID, Name: "Normal", Active: true})
	require.NoError(t, err)

	var theirCategory string
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`INSERT INTO categories (tenant_id, name) VALUES ($1, 'Milik Beta') RETURNING id`, otherTenant).Scan(&theirCategory))

	_, err = f.svc.SaveCategory(ctx, otherTenant, catalogue.Category{ID: categoryID, Name: "Curian"})
	require.ErrorIs(t, err, catalogue.ErrNotFound)

	_, err = f.svc.SaveProduct(ctx, otherTenant, catalogue.Product{
		ID: productID, CategoryID: theirCategory, Name: "Curian", Price: 1})
	require.ErrorIs(t, err, catalogue.ErrNotFound)

	_, err = f.svc.SaveModifierGroup(ctx, otherTenant, catalogue.ModifierGroup{
		ID: groupID, Name: "Curian", SelectionType: catalogue.SelectSingle})
	require.ErrorIs(t, err, catalogue.ErrNotFound)

	_, err = f.svc.SaveVariant(ctx, otherTenant, catalogue.Variant{ID: variantID, ProductID: productID, Name: "Curian"})
	require.ErrorIs(t, err, catalogue.ErrNotFound)

	_, err = f.svc.SaveModifierOption(ctx, otherTenant, catalogue.ModifierOption{ID: optionID, GroupID: groupID, Name: "Curian"})
	require.ErrorIs(t, err, catalogue.ErrNotFound)

	// And nothing of ours moved.
	c, err := f.svc.Category(ctx, f.tenantID, categoryID)
	require.NoError(t, err)
	require.Equal(t, "Makanan", c.Name)
}
