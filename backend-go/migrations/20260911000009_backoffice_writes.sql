-- +goose Up

-- What the Backoffice needs before it can write merchant data safely.

-- 1. Promo scoping is explicit.
--
-- Without this, "no promo_outlets rows" would have to MEAN something, and the
-- only useful meaning is "every outlet". That turns unticking the last branch
-- into making the promo company-wide — a discount that silently spreads to
-- 5,000 outlets because someone narrowed it one step too far. With a flag, the
-- same click leaves it live nowhere, which is the direction that costs nothing.
ALTER TABLE promos ADD COLUMN all_outlets boolean NOT NULL DEFAULT true;

-- The covering feed index has to carry the new published column, or every
-- promo pull goes back to the heap. See registry.go.
DROP INDEX promos_sync_feed_idx;
CREATE INDEX promos_sync_feed_idx ON promos (tenant_id, sync_seq)
    INCLUDE (id, name, kind, value, min_spend, active, sort_order, all_outlets, deleted_at);

-- 2. Uploaded product images.
--
-- image_url stays the published column — it is what the till already renders.
-- image_key is the object this server stored for it, and is NOT published: the
-- till has no use for a storage key, and it is what a later sweep uses to tell
-- an image the platform owns from a URL someone typed by hand.
--
-- Keys are content-addressed and immutable, so a replaced image is a new key and
-- the old object is left for that sweep rather than deleted on save: a till that
-- has not pulled the change yet is still showing the old URL.
ALTER TABLE products
    ADD COLUMN image_key text,
    ADD CONSTRAINT products_image_key_length CHECK (image_key IS NULL OR length(image_key) <= 200);

-- +goose Down

ALTER TABLE products
    DROP CONSTRAINT products_image_key_length,
    DROP COLUMN image_key;

DROP INDEX promos_sync_feed_idx;
CREATE INDEX promos_sync_feed_idx ON promos (tenant_id, sync_seq)
    INCLUDE (id, name, kind, value, min_spend, active, sort_order, deleted_at);
ALTER TABLE promos DROP COLUMN all_outlets;
