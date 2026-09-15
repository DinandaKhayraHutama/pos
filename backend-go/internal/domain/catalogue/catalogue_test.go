package catalogue_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/media"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/pgtest"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/infra/redisx"
)

type fixture struct {
	db       pgtest.DB
	feed     *syncfeed.Service
	svc      *catalogue.Service
	tenantID string
	mediaDir string
}

func newFixture(t *testing.T) fixture {
	t.Helper()

	db := pgtest.New(t)
	ctx := context.Background()

	url := os.Getenv("REDIS_URL")
	if url == "" {
		t.Fatal("REDIS_URL is not set; catalogue writes publish a watermark")
	}
	rdb, err := redisx.Open(ctx, url)
	require.NoError(t, err)
	t.Cleanup(func() { rdb.Close() })

	feed := syncfeed.NewService(db.Pools, rdb, slog.New(slog.NewTextHandler(io.Discard, nil)))
	// A real store on a real directory: the image tests read back the file a
	// till would fetch, not a stand-in's idea of it.
	mediaDir := t.TempDir()
	images, err := media.Open(mediaDir, "https://pos.example.test/media")
	require.NoError(t, err)
	f := fixture{db: db, feed: feed, mediaDir: mediaDir, svc: catalogue.NewService(db.Pools, feed, images)}

	require.NoError(t, db.Owner.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Warung Alpha', 'alpha') RETURNING id`).Scan(&f.tenantID))

	return f
}

func (f fixture) rows(t *testing.T, entity string, afterSeq int64) []map[string]any {
	t.Helper()

	page, err := f.feed.Pull(context.Background(), f.tenantID, entity, afterSeq, 500)
	require.NoError(t, err)

	out := make([]map[string]any, 0, len(page.Rows))
	for _, raw := range page.Rows {
		var row map[string]any
		require.NoError(t, json.Unmarshal(raw, &row))
		out = append(out, row)
	}

	return out
}

func (f fixture) saveProduct(t *testing.T, categoryID, name string) string {
	t.Helper()

	id, err := f.svc.SaveProduct(context.Background(), f.tenantID, catalogue.Product{
		CategoryID: categoryID, Name: name, Price: 25_000, Available: true,
	})
	require.NoError(t, err)

	return id
}

func TestASavedCategoryReachesTheFeed(t *testing.T) {
	f := newFixture(t)

	id, err := f.svc.SaveCategory(context.Background(), f.tenantID, catalogue.Category{
		Name: "Makanan", SortOrder: 3, IsPopular: true,
	})
	require.NoError(t, err)
	require.NotEmpty(t, id)

	rows := f.rows(t, "categories", 0)
	require.Len(t, rows, 1)
	require.Equal(t, id, rows[0]["id"])
	require.Equal(t, "Makanan", rows[0]["name"])
	require.EqualValues(t, 1, rows[0]["sync_seq"])
	require.Nil(t, rows[0]["deleted_at_ms"])
}

// An edit has to move the row's number, or a till already past it never learns
// the price changed.
func TestAnEditRestampsTheRowSoTillsPastItPullAgain(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	id, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Makanan"})
	require.NoError(t, err)

	same, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{ID: id, Name: "Makanan Berat"})
	require.NoError(t, err)
	require.Equal(t, id, same, "saving with an id must update, never duplicate")

	rows := f.rows(t, "categories", 1)
	require.Len(t, rows, 1)
	require.Equal(t, "Makanan Berat", rows[0]["name"])
	require.EqualValues(t, 2, rows[0]["sync_seq"])
}

func TestDeletingACategoryLeavesATombstoneRatherThanAnAbsence(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	id, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Makanan"})
	require.NoError(t, err)
	require.NoError(t, f.svc.DeleteCategory(ctx, f.tenantID, id))

	rows := f.rows(t, "categories", 1)
	require.Len(t, rows, 1)
	require.Equal(t, id, rows[0]["id"])
	require.NotNil(t, rows[0]["deleted_at_ms"], "a till can never infer a deletion from an absence")
}

// Retiring a category is bookkeeping; retiring the twelve products under it is
// a menu change, and the person clicking should be the one to say so.
func TestACategoryWithProductsRefusesToBeDeleted(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Makanan"})
	require.NoError(t, err)
	productID := f.saveProduct(t, categoryID, "Nasi Goreng")

	require.ErrorIs(t, f.svc.DeleteCategory(ctx, f.tenantID, categoryID), catalogue.ErrCategoryInUse)

	require.NoError(t, f.svc.DeleteProduct(ctx, f.tenantID, productID))
	require.NoError(t, f.svc.DeleteCategory(ctx, f.tenantID, categoryID),
		"once it is empty the category may go")
}

// On the device these tables carry ON DELETE CASCADE, so applying the product's
// tombstone removes its variants and modifier attachments locally. If the
// server left those rows alive, no later page would mention them again and the
// two would disagree permanently — with the till missing rows.
func TestDeletingAProductRetiresEverythingHangingOffIt(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Minuman"})
	require.NoError(t, err)
	productID := f.saveProduct(t, categoryID, "Kopi Susu")

	for _, name := range []string{"Regular", "Large"} {
		_, err := f.svc.SaveVariant(ctx, f.tenantID, catalogue.Variant{
			ProductID: productID, Name: name, PriceDelta: 5_000,
		})
		require.NoError(t, err)
	}

	f.attachModifiers(t, productID)

	require.NoError(t, f.svc.DeleteProduct(ctx, f.tenantID, productID))

	for _, entity := range []string{
		"products", "product_variants", "product_modifier_groups", "product_modifier_options",
	} {
		rows := f.rows(t, entity, 0)
		require.NotEmpty(t, rows, "%s published nothing at all", entity)

		for _, row := range rows {
			require.NotNil(t, row["deleted_at_ms"],
				"%s left a row alive that the device has already deleted locally", entity)
		}
	}
}

// Rows may not share a sequence number: a page boundary landing inside a tie
// strands every row still sitting at it, because the next request asks for
// strictly greater.
func TestACascadeGivesEveryRetiredRowItsOwnNumber(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Minuman"})
	require.NoError(t, err)
	productID := f.saveProduct(t, categoryID, "Kopi Susu")

	for _, name := range []string{"Regular", "Large", "Jumbo"} {
		_, err := f.svc.SaveVariant(ctx, f.tenantID, catalogue.Variant{ProductID: productID, Name: name})
		require.NoError(t, err)
	}

	require.NoError(t, f.svc.DeleteProduct(ctx, f.tenantID, productID))

	seen := map[float64]bool{}
	for _, row := range f.rows(t, "product_variants", 0) {
		seq, ok := row["sync_seq"].(float64)
		require.True(t, ok)
		require.False(t, seen[seq], "two variants share sequence number %v", seq)
		seen[seq] = true
	}
	require.Len(t, seen, 3)
}

// Otherwise an owner who re-adds "Minuman" is told the name is taken and cannot
// see the row that took it.
func TestSavingARetiredRowBringsItBack(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	id, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Makanan"})
	require.NoError(t, err)
	require.NoError(t, f.svc.DeleteCategory(ctx, f.tenantID, id))

	_, err = f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{ID: id, Name: "Makanan"})
	require.NoError(t, err)

	rows := f.rows(t, "categories", 2)
	require.Len(t, rows, 1)
	require.Nil(t, rows[0]["deleted_at_ms"])
}

func TestDeletingSomethingThatIsAlreadyGoneIsRefused(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	id, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Makanan"})
	require.NoError(t, err)
	require.NoError(t, f.svc.DeleteCategory(ctx, f.tenantID, id))

	require.ErrorIs(t, f.svc.DeleteCategory(ctx, f.tenantID, id), catalogue.ErrNotFound)

	// The failed attempt rolled back with its number, so the counter did not
	// move and no till is told to re-pull for nothing.
	cursors, err := f.feed.Cursors(ctx, f.tenantID)
	require.NoError(t, err)
	require.EqualValues(t, 2, cursors["categories"])
}

// NULL and 0 are different tax answers: NULL means "use the store's PB1 rate",
// 0 means "genuinely zero-rated". Collapsing them silently taxes exempt items.
func TestAZeroTaxRateSurvivesTheRoundTripDistinctFromNull(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	categoryID, err := f.svc.SaveCategory(ctx, f.tenantID, catalogue.Category{Name: "Makanan"})
	require.NoError(t, err)

	zero := 0.0
	exempt, err := f.svc.SaveProduct(ctx, f.tenantID, catalogue.Product{
		CategoryID: categoryID, Name: "Beras", Price: 15_000, TaxRate: &zero,
	})
	require.NoError(t, err)

	storeRate, err := f.svc.SaveProduct(ctx, f.tenantID, catalogue.Product{
		CategoryID: categoryID, Name: "Nasi Goreng", Price: 25_000,
	})
	require.NoError(t, err)

	byID := map[string]map[string]any{}
	for _, row := range f.rows(t, "products", 0) {
		byID[row["id"].(string)] = row
	}

	require.EqualValues(t, 0, byID[exempt]["tax_rate"])
	require.Nil(t, byID[storeRate]["tax_rate"])
}

// attachModifiers gives a product one modifier group and one option, through
// the same publish path the Backoffice will use in Fase 2B.
func (f fixture) attachModifiers(t *testing.T, productID string) {
	t.Helper()

	require.NoError(t, f.feed.Write(context.Background(), f.tenantID,
		func(ctx context.Context, w *syncfeed.Writer) error {
			groupSeq, err := w.Seq(ctx, "modifier_groups")
			if err != nil {
				return err
			}

			var groupID string
			if err := w.Tx.QueryRow(ctx, `
				INSERT INTO modifier_groups (tenant_id, name, sync_seq)
				VALUES ($1, 'Level Gula', $2) RETURNING id`,
				f.tenantID, groupSeq).Scan(&groupID); err != nil {
				return err
			}

			optionSeq, err := w.Seq(ctx, "modifier_options")
			if err != nil {
				return err
			}

			var optionID string
			if err := w.Tx.QueryRow(ctx, `
				INSERT INTO modifier_options (tenant_id, group_id, name, price_delta, sync_seq)
				VALUES ($1, $2, 'Less Sugar', 0, $3) RETURNING id`,
				f.tenantID, groupID, optionSeq).Scan(&optionID); err != nil {
				return err
			}

			linkSeq, err := w.Seq(ctx, "product_modifier_groups")
			if err != nil {
				return err
			}
			if _, err := w.Tx.Exec(ctx, `
				INSERT INTO product_modifier_groups (tenant_id, product_id, group_id, sync_seq)
				VALUES ($1, $2, $3, $4)`, f.tenantID, productID, groupID, linkSeq); err != nil {
				return err
			}

			scopeSeq, err := w.Seq(ctx, "product_modifier_options")
			if err != nil {
				return err
			}
			_, err = w.Tx.Exec(ctx, `
				INSERT INTO product_modifier_options (tenant_id, product_id, option_id, sync_seq)
				VALUES ($1, $2, $3, $4)`, f.tenantID, productID, optionID, scopeSeq)
			return err
		}))
}
