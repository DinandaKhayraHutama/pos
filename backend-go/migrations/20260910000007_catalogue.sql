-- +goose Up

-- The menu, and the sync columns the branch tables were missing.
--
-- Shared across the chain, never per outlet: the Flutter app already draws that
-- line (mobile/CLAUDE.md, "Multi-outlet") — menu, prices and variants belong to
-- the business, while stock and sales belong to a branch. Nothing here carries
-- an outlet_id for that reason.
--
-- Column names and types mirror the till's SQLite schema on purpose, so a
-- pulled row can be written straight through the repository the app already
-- has rather than through a translation layer nobody would keep in step.
-- Money is integer rupiah, never float.
--
-- Three columns are on every syncable table:
--   tenant_id  — the isolation boundary, on every row without exception
--   sync_seq   — the cursor devices page through
--   deleted_at — a tombstone, because "this product is gone" is a change a till
--                must RECEIVE; it can never infer it from an absence.

CREATE TABLE categories (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name       text NOT NULL,
    icon_key   text,
    sort_order integer NOT NULL DEFAULT 0,
    is_popular boolean NOT NULL DEFAULT false,
    sync_seq   bigint NOT NULL DEFAULT 0,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    -- Load-bearing, not tidiness: every published column travels inside the
    -- covering index below, and a btree tuple may not exceed ~2704 bytes.
    -- Without a bound here an over-long name is an INSERT that fails deep
    -- inside an index with a message naming nothing the operator recognises.
    CONSTRAINT categories_name_length     CHECK (length(name) <= 120),
    CONSTRAINT categories_icon_key_length CHECK (icon_key IS NULL OR length(icon_key) <= 64)
);

CREATE TABLE products (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    category_id uuid NOT NULL,
    name        text NOT NULL,
    price       bigint NOT NULL,
    cost        bigint,
    sku         text,
    -- Nullable on purpose, and NOT the same as zero: NULL means "use the
    -- store's PB1 rate", 0 means "genuinely zero-rated". Collapsing the two
    -- silently starts taxing exempt items.
    tax_rate    double precision,
    description text,
    image_url   text,
    icon_key    text NOT NULL DEFAULT 'restaurant',
    available   boolean NOT NULL DEFAULT true,
    is_popular  boolean NOT NULL DEFAULT false,
    sort_order  integer NOT NULL DEFAULT 0,
    sync_seq    bigint NOT NULL DEFAULT 0,
    deleted_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    -- A product pointing at another merchant's category is refused by the
    -- database, so it cannot survive a bug in application code.
    CONSTRAINT products_category_context_fk
        FOREIGN KEY (tenant_id, category_id) REFERENCES categories (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT products_name_length        CHECK (length(name) <= 120),
    CONSTRAINT products_sku_length         CHECK (sku IS NULL OR length(sku) <= 64),
    CONSTRAINT products_description_length CHECK (description IS NULL OR length(description) <= 500),
    CONSTRAINT products_image_url_length   CHECK (image_url IS NULL OR length(image_url) <= 500),
    CONSTRAINT products_icon_key_length    CHECK (length(icon_key) <= 64)
);

CREATE TABLE product_variants (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    product_id  uuid NOT NULL,
    name        text NOT NULL,
    -- Signed: a smaller size is a negative delta. A delta rather than an
    -- absolute price, so changing a base price does not silently invalidate
    -- every variant under it.
    price_delta bigint NOT NULL DEFAULT 0,
    sort_order  integer NOT NULL DEFAULT 0,
    sync_seq    bigint NOT NULL DEFAULT 0,
    deleted_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT product_variants_product_context_fk
        FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT product_variants_name_length CHECK (length(name) <= 120)
);

-- The branch tables join the pull feed. Until now a register renamed in the
-- Backoffice never reached the till already activated against it: outlets and
-- pos_registers were written once from the activation payload and never pulled
-- again.
ALTER TABLE outlets
    ADD COLUMN sync_seq   bigint NOT NULL DEFAULT 0,
    ADD COLUMN deleted_at timestamptz,
    ADD CONSTRAINT outlets_name_length    CHECK (length(name) <= 120),
    ADD CONSTRAINT outlets_address_length CHECK (address IS NULL OR length(address) <= 255);

ALTER TABLE pos_registers
    ADD COLUMN sync_seq   bigint NOT NULL DEFAULT 0,
    ADD COLUMN deleted_at timestamptz,
    ADD CONSTRAINT pos_registers_name_length CHECK (length(name) <= 120);

ALTER TABLE employees
    ADD CONSTRAINT employees_name_length CHECK (length(name) <= 120);

-- Every pull is the same shape of query — "this tenant, after this seq, in seq
-- order" — so every syncable table gets the same index, and INCLUDE carries the
-- published columns so the scan never touches the heap. With 15,000 devices
-- pulling, this is the most consequential index family in the schema.
--
-- The INCLUDE list must stay in step with the entity's published columns in
-- internal/domain/sync/registry.go. A column published but not included turns
-- an Index Only Scan into an Index Scan with a heap fetch per row, which is the
-- difference the fan-out test measures.
CREATE INDEX categories_sync_feed_idx ON categories (tenant_id, sync_seq)
    INCLUDE (id, name, icon_key, sort_order, is_popular, deleted_at);

CREATE INDEX products_sync_feed_idx ON products (tenant_id, sync_seq)
    INCLUDE (id, category_id, name, price, cost, sku, tax_rate, description,
             image_url, icon_key, available, is_popular, sort_order, deleted_at);

CREATE INDEX product_variants_sync_feed_idx ON product_variants (tenant_id, sync_seq)
    INCLUDE (id, product_id, name, price_delta, sort_order, deleted_at);

CREATE INDEX outlets_sync_feed_idx ON outlets (tenant_id, sync_seq)
    INCLUDE (id, name, address, active, sort_order, deleted_at);

CREATE INDEX pos_registers_sync_feed_idx ON pos_registers (tenant_id, sync_seq)
    INCLUDE (id, outlet_id, name, table_service, active, sort_order, deleted_at);

-- employees_tenant_seq_idx already existed; this is the covering form of it.
-- Note what is absent from the payload, and therefore from here: `email` and
-- `password`. A browser credential is of no use to a till, and copying it to
-- every tablet in every branch would put it somewhere far easier to reach than
-- the server. `pin_hash` travels because offline sign-in genuinely needs it,
-- and it is a hash the device verifies locally, never a plaintext PIN.
DROP INDEX employees_tenant_seq_idx;
CREATE INDEX employees_sync_feed_idx ON employees (tenant_id, sync_seq)
    INCLUDE (id, name, pin_hash, role, active, sort_order, deleted_at);

CREATE INDEX products_tenant_category_idx ON products (tenant_id, category_id);
CREATE INDEX product_variants_tenant_product_idx ON product_variants (tenant_id, product_id);

GRANT SELECT, INSERT, UPDATE, DELETE
    ON categories, products, product_variants
    TO justclick_app;

ALTER TABLE categories       ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories       FORCE  ROW LEVEL SECURITY;
ALTER TABLE products         ENABLE ROW LEVEL SECURITY;
ALTER TABLE products         FORCE  ROW LEVEL SECURITY;
ALTER TABLE product_variants ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_variants FORCE  ROW LEVEL SECURITY;

CREATE POLICY categories_tenant_isolation ON categories
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

CREATE POLICY products_tenant_isolation ON products
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

CREATE POLICY product_variants_tenant_isolation ON product_variants
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

-- +goose Down

DROP TABLE product_variants;
DROP TABLE products;
DROP TABLE categories;

DROP INDEX employees_sync_feed_idx;
CREATE INDEX employees_tenant_seq_idx ON employees (tenant_id, sync_seq);

ALTER TABLE employees
    DROP CONSTRAINT employees_name_length;

ALTER TABLE pos_registers
    DROP CONSTRAINT pos_registers_name_length,
    DROP COLUMN deleted_at,
    DROP COLUMN sync_seq;

ALTER TABLE outlets
    DROP CONSTRAINT outlets_address_length,
    DROP CONSTRAINT outlets_name_length,
    DROP COLUMN deleted_at,
    DROP COLUMN sync_seq;
