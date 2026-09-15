package catalogue_test

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/jpeg"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/catalogue"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
)

func testJPEG(t *testing.T, w, h int, shade uint8) []byte {
	t.Helper()

	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{R: shade, G: 80, B: 40, A: 255})
		}
	}

	var buf bytes.Buffer
	require.NoError(t, jpeg.Encode(&buf, img, nil))
	return buf.Bytes()
}

// storedFile maps a published URL back to the file a till would receive.
func (f fixture) storedFile(t *testing.T, publicURL string) []byte {
	t.Helper()

	u, err := url.Parse(publicURL)
	require.NoError(t, err)
	key := strings.TrimPrefix(u.Path, "/media/")

	body, err := os.ReadFile(filepath.Join(f.mediaDir, filepath.FromSlash(key)))
	require.NoError(t, err, "the published URL must name a file that was actually stored")
	return body
}

// The promise to the till: the URL it pulls names a file that already exists,
// processed — never the upload as sent.
func TestAnUploadedImageReachesTheFeedAsAStoredFile(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	productID := f.saveProduct(t, f.category(t, "Minuman"), "Kopi Susu")
	before := f.counter(t, "products")

	publicURL, err := f.svc.SetProductImage(ctx, f.tenantID, productID, testJPEG(t, 2400, 1200, 200))
	require.NoError(t, err)
	require.True(t, strings.HasPrefix(publicURL, "https://pos.example.test/media/products/"+f.tenantID+"/"))

	rows := f.rows(t, "products", before)
	require.Len(t, rows, 1, "one new number for one change")
	require.Equal(t, publicURL, rows[0]["image_url"])
	require.NotContains(t, rows[0], "image_key", "the storage key is the server's business, not the till's")

	cfg, err := jpeg.DecodeConfig(bytes.NewReader(f.storedFile(t, publicURL)))
	require.NoError(t, err)
	require.Equal(t, [2]int{1024, 512}, [2]int{cfg.Width, cfg.Height})
}

// Re-uploading the same photo — a double click, a retry — is the same key, so
// no till is woken to pull a row that did not change.
func TestUploadingTheSameImageAgainWakesNobody(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	productID := f.saveProduct(t, f.category(t, "Minuman"), "Kopi Susu")
	upload := testJPEG(t, 400, 300, 120)

	first, err := f.svc.SetProductImage(ctx, f.tenantID, productID, upload)
	require.NoError(t, err)
	before := f.counter(t, "products")

	second, err := f.svc.SetProductImage(ctx, f.tenantID, productID, upload)
	require.NoError(t, err)
	require.Equal(t, first, second)
	require.Equal(t, before, f.counter(t, "products"))

	third, err := f.svc.SetProductImage(ctx, f.tenantID, productID, testJPEG(t, 400, 300, 10))
	require.NoError(t, err)
	require.NotEqual(t, first, third, "a different picture is a different, permanent address")
	require.Equal(t, before+1, f.counter(t, "products"))

	f.storedFile(t, first) // the old file stays: a till that has not synced still shows it
}

// The product form no longer carries the image, so saving it must not be the
// thing that silently drops the photo from every till.
func TestSavingTheProductFormKeepsItsImage(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	productID := f.saveProduct(t, f.category(t, "Minuman"), "Kopi Susu")
	publicURL, err := f.svc.SetProductImage(ctx, f.tenantID, productID, testJPEG(t, 300, 300, 90))
	require.NoError(t, err)

	product, err := f.svc.Product(ctx, f.tenantID, productID)
	require.NoError(t, err)
	product.Name = "Kopi Susu Aren"
	product.ImageURL = nil
	_, err = f.svc.SaveProduct(ctx, f.tenantID, product.Product)
	require.NoError(t, err)

	again, err := f.svc.Product(ctx, f.tenantID, productID)
	require.NoError(t, err)
	require.NotNil(t, again.ImageURL)
	require.Equal(t, publicURL, *again.ImageURL)
}

func TestRemovingAnImagePublishesTheIconFallback(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	productID := f.saveProduct(t, f.category(t, "Minuman"), "Kopi Susu")
	_, err := f.svc.SetProductImage(ctx, f.tenantID, productID, testJPEG(t, 300, 300, 90))
	require.NoError(t, err)
	before := f.counter(t, "products")

	require.NoError(t, f.svc.RemoveProductImage(ctx, f.tenantID, productID))
	rows := f.rows(t, "products", before)
	require.Len(t, rows, 1)
	require.Nil(t, rows[0]["image_url"])

	require.NoError(t, f.svc.RemoveProductImage(ctx, f.tenantID, productID))
	require.Equal(t, before+1, f.counter(t, "products"), "removing nothing wakes nobody")
}

func TestARefusedUploadNamesTheImageField(t *testing.T) {
	f := newFixture(t)
	productID := f.saveProduct(t, f.category(t, "Minuman"), "Kopi Susu")
	before := f.counter(t, "products")

	_, err := f.svc.SetProductImage(context.Background(), f.tenantID, productID,
		[]byte(`<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>`))

	fields, ok := validation.As(err)
	require.True(t, ok, "got %v", err)
	require.Contains(t, fields, "image")
	require.Equal(t, before, f.counter(t, "products"))

	entries, err := os.ReadDir(f.mediaDir)
	require.NoError(t, err)
	for _, e := range entries {
		require.True(t, strings.HasPrefix(e.Name(), "."), "a refused upload stored %s", e.Name())
	}
}

func TestAnImageCannotBeSetOnAnotherMerchantsOrARetiredProduct(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()

	var otherTenant string
	require.NoError(t, f.db.Owner.QueryRow(ctx,
		`INSERT INTO tenants (name, slug) VALUES ('Warung Beta', 'beta') RETURNING id`).Scan(&otherTenant))

	productID := f.saveProduct(t, f.category(t, "Minuman"), "Kopi Susu")
	upload := testJPEG(t, 100, 100, 50)

	_, err := f.svc.SetProductImage(ctx, otherTenant, productID, upload)
	require.ErrorIs(t, err, catalogue.ErrNotFound)
	require.ErrorIs(t, f.svc.RemoveProductImage(ctx, otherTenant, productID), catalogue.ErrNotFound)

	require.NoError(t, f.svc.DeleteProduct(ctx, f.tenantID, productID))
	_, err = f.svc.SetProductImage(ctx, f.tenantID, productID, upload)
	require.ErrorIs(t, err, catalogue.ErrNotFound)
}
