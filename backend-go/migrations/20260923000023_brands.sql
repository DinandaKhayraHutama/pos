-- +goose Up

-- Fase 2 paritas: brands. A flat label a product may carry, company-wide like
-- categories — nothing here is scoped to an outlet, for the same reason
-- categories/products are not: the menu belongs to the business, stock and
-- sales belong to a branch.
CREATE TABLE brands (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name       text NOT NULL,
    sort_order integer NOT NULL DEFAULT 0,
    sync_seq   bigint NOT NULL DEFAULT 0,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    -- Same bound as categories_name_length, for the same reason: every
    -- published column travels inside the covering index below, and a btree
    -- tuple may not exceed ~2704 bytes.
    CONSTRAINT brands_name_length CHECK (length(name) <= 120)
);

-- A product's brand is optional and never required at the database layer: a
-- brandless product is an ordinary product, not an error. ON DELETE SET NULL
-- would let a product silently lose its brand outside the application's own
-- retirement path, so there is deliberately no FK here — the same choice
-- products.category_id would need if categories were optional. Instead
-- catalogue.SaveProduct checks the brand is live before writing, exactly as
-- it already does for category_id, and catalogue.DeleteBrand refuses while
-- products still reference it (ErrBrandInUse), matching ErrCategoryInUse.
ALTER TABLE products
    ADD COLUMN brand_id uuid,
    ADD CONSTRAINT products_brand_context_fk
        FOREIGN KEY (tenant_id, brand_id) REFERENCES brands (tenant_id, id);

CREATE INDEX products_tenant_brand_idx ON products (tenant_id, brand_id) WHERE brand_id IS NOT NULL;

CREATE INDEX brands_sync_feed_idx ON brands (tenant_id, sync_seq)
    INCLUDE (id, name, sort_order, deleted_at);

-- The covering index has to carry brand_id now that it is a published column
-- on products, or every product pull past the tenant's first page falls back
-- to a heap fetch per row. See registry.go and CLAUDE.md's "products" entity.
DROP INDEX products_sync_feed_idx;
CREATE INDEX products_sync_feed_idx ON products (tenant_id, sync_seq)
    INCLUDE (id, category_id, brand_id, name, price, cost, sku, tax_rate, description,
             image_url, icon_key, available, is_popular, sort_order, deleted_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON brands TO justclick_app;

ALTER TABLE brands ENABLE ROW LEVEL SECURITY;
ALTER TABLE brands FORCE  ROW LEVEL SECURITY;

CREATE POLICY brands_tenant_isolation ON brands
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

-- +goose Down

DROP INDEX products_sync_feed_idx;
CREATE INDEX products_sync_feed_idx ON products (tenant_id, sync_seq)
    INCLUDE (id, category_id, name, price, cost, sku, tax_rate, description,
             image_url, icon_key, available, is_popular, sort_order, deleted_at);

ALTER TABLE products
    DROP CONSTRAINT products_brand_context_fk,
    DROP COLUMN brand_id;

DROP TABLE brands;
