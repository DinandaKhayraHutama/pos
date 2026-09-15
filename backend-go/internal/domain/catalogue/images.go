package catalogue

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/syncfeed"
	"github.com/daniryckidinata/nti_pos/backend-go/internal/domain/validation"
)

// ImageStore keeps the bytes of a product image and says where tills fetch
// them. internal/infra/media is the implementation.
type ImageStore interface {
	Put(ctx context.Context, key string, body []byte) error
	URL(key string) string
}

var errNoImageStore = errors.New("catalogue: no image store is configured")

// SetProductImage replaces a product's photo and returns its public URL.
//
// The file is stored BEFORE the row that names it is published. The other
// order would hand every till a URL that answers 404 until the file lands, and
// a till that fails to load an image falls back to its icon for the rest of
// the session. A file stored for a write that then fails is left behind for a
// later sweep — harmless, because nothing names it.
//
// Uploading the image a product already has changes nothing and wakes nobody:
// the key is the hash of the processed bytes.
func (s *Service) SetProductImage(ctx context.Context, tenantID, productID string, upload []byte) (string, error) {
	if s.images == nil {
		return "", errNoImageStore
	}
	if !validation.UUID(productID) || !validation.UUID(tenantID) {
		return "", ErrNotFound
	}

	// Cheap before expensive: an id from a stale tab should not cost a decode.
	if _, err := s.Product(ctx, tenantID, productID); err != nil {
		return "", err
	}

	select {
	case s.imageSlots <- struct{}{}:
	case <-ctx.Done():
		return "", ctx.Err()
	}
	image, problem := processImage(upload)
	<-s.imageSlots

	if problem != "" {
		return "", validation.Errors{"image": problem}
	}

	key := fmt.Sprintf("products/%s/%x.%s", tenantID, sha256.Sum256(image.body), image.ext)
	if err := s.images.Put(ctx, key, image.body); err != nil {
		return "", fmt.Errorf("store product image: %w", err)
	}
	url := s.images.URL(key)

	err := s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		current, _, err := liveImage(ctx, w, tenantID, productID)
		if err != nil || (current != nil && *current == key) {
			return err
		}

		seq, err := w.Seq(ctx, "products")
		if err != nil {
			return err
		}

		_, err = w.Tx.Exec(ctx, `
			UPDATE products
			SET image_url = $3, image_key = $4, sync_seq = $5, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`,
			tenantID, productID, url, key, seq)
		return err
	})
	if err != nil {
		return "", err
	}

	return url, nil
}

// RemoveProductImage takes the photo off a product, so tills fall back to its
// icon. The stored file is not deleted: a till that has not pulled the change
// is still showing it.
func (s *Service) RemoveProductImage(ctx context.Context, tenantID, productID string) error {
	if !validation.UUID(productID) {
		return ErrNotFound
	}

	return s.feed.Write(ctx, tenantID, func(ctx context.Context, w *syncfeed.Writer) error {
		key, url, err := liveImage(ctx, w, tenantID, productID)
		if err != nil || (key == nil && url == nil) {
			return err
		}

		seq, err := w.Seq(ctx, "products")
		if err != nil {
			return err
		}

		_, err = w.Tx.Exec(ctx, `
			UPDATE products
			SET image_url = NULL, image_key = NULL, sync_seq = $3, updated_at = now()
			WHERE tenant_id = $1 AND id = $2`,
			tenantID, productID, seq)
		return err
	})
}

// liveImage claims a live product and reads what image it has.
func liveImage(ctx context.Context, w *syncfeed.Writer, tenantID, productID string) (key, url *string, err error) {
	if err := claim(ctx, w.Tx, "products", tenantID, productID); err != nil {
		return nil, nil, err
	}

	err = w.Tx.QueryRow(ctx, `
		SELECT image_key, image_url FROM products
		WHERE tenant_id = $1 AND id = $2 AND deleted_at IS NULL`,
		tenantID, productID).Scan(&key, &url)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, ErrNotFound
	}

	return key, url, err
}
