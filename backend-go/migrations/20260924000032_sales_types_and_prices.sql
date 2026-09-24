-- +goose Up

-- Fase 3 paritas: sales types and the prices that depend on them.
--
-- The three types the till always had (dineIn, takeaway, delivery) become
-- system rows, so an order's `type` keeps its old wire values; a merchant's
-- own types ("GoFood", "Grosir") travel as `custom` plus the sales type's id
-- and name. Custom types only exist at branches running the version 2 pricing
-- model, which an older till cannot be part of.
CREATE TABLE sales_types (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name       text NOT NULL,
    system_key text CHECK (system_key IN ('dineIn', 'takeaway', 'delivery')),
    uses_table boolean NOT NULL DEFAULT false,
    active     boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    sync_seq   bigint NOT NULL DEFAULT 0,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT sales_types_one_per_system_key UNIQUE (tenant_id, system_key),
    CONSTRAINT sales_types_name_length CHECK (length(name) <= 120)
);

CREATE INDEX sales_types_sync_feed_idx ON sales_types (tenant_id, sync_seq)
    INCLUDE (id, name, system_key, uses_table, active, sort_order, deleted_at);

-- Price resolution: outlet + sales type, then business + sales type, then
-- products.price. Two tables because the feed scope differs: one branch's
-- override must not travel to every till in the company.
CREATE TABLE product_sales_type_prices (
    tenant_id     uuid NOT NULL,
    product_id    uuid NOT NULL,
    sales_type_id uuid NOT NULL,
    price         bigint NOT NULL CHECK (price BETWEEN 0 AND 1000000000000),
    sync_seq      bigint NOT NULL DEFAULT 0,
    deleted_at    timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, product_id, sales_type_id),
    CONSTRAINT product_sales_type_prices_product_fk
        FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT product_sales_type_prices_type_fk
        FOREIGN KEY (tenant_id, sales_type_id) REFERENCES sales_types (tenant_id, id) ON DELETE CASCADE
);

CREATE INDEX product_sales_type_prices_sync_feed_idx ON product_sales_type_prices (tenant_id, sync_seq)
    INCLUDE (product_id, sales_type_id, price, deleted_at);

CREATE TABLE outlet_product_sales_type_prices (
    tenant_id     uuid NOT NULL,
    outlet_id     uuid NOT NULL,
    product_id    uuid NOT NULL,
    sales_type_id uuid NOT NULL,
    price         bigint NOT NULL CHECK (price BETWEEN 0 AND 1000000000000),
    sync_seq      bigint NOT NULL DEFAULT 0,
    deleted_at    timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, outlet_id, product_id, sales_type_id),
    CONSTRAINT outlet_product_sales_type_prices_outlet_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT outlet_product_sales_type_prices_product_fk
        FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT outlet_product_sales_type_prices_type_fk
        FOREIGN KEY (tenant_id, sales_type_id) REFERENCES sales_types (tenant_id, id) ON DELETE CASCADE
);

CREATE INDEX outlet_product_sales_type_prices_sync_feed_idx
    ON outlet_product_sales_type_prices (tenant_id, outlet_id, sync_seq)
    INCLUDE (product_id, sales_type_id, price, deleted_at);

ALTER TABLE outlet_settings ADD CONSTRAINT outlet_settings_default_sales_type_fk
    FOREIGN KEY (tenant_id, default_sales_type_id) REFERENCES sales_types (tenant_id, id);

GRANT SELECT, INSERT, UPDATE, DELETE ON sales_types, product_sales_type_prices,
    outlet_product_sales_type_prices TO justclick_app;

ALTER TABLE sales_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales_types FORCE  ROW LEVEL SECURITY;
CREATE POLICY sales_types_tenant_isolation ON sales_types
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

ALTER TABLE product_sales_type_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_sales_type_prices FORCE  ROW LEVEL SECURITY;
CREATE POLICY product_sales_type_prices_tenant_isolation ON product_sales_type_prices
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

ALTER TABLE outlet_product_sales_type_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE outlet_product_sales_type_prices FORCE  ROW LEVEL SECURITY;
CREATE POLICY outlet_product_sales_type_prices_tenant_isolation ON outlet_product_sales_type_prices
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

-- +goose StatementBegin
CREATE FUNCTION app.seed_system_sales_types(p_tenant uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    prev text := current_setting('app.tenant_id', true);
    base bigint;
BEGIN
    PERFORM set_config('app.tenant_id', p_tenant::text, true);
    IF NOT EXISTS (SELECT 1 FROM sales_types WHERE tenant_id = p_tenant AND system_key IS NOT NULL) THEN
        base := app.alloc_sync_block(p_tenant, 'sales_types', 3);
        INSERT INTO sales_types (tenant_id, name, system_key, uses_table, sort_order, sync_seq)
        VALUES (p_tenant, 'Makan di tempat', 'dineIn',   true,  0, base),
               (p_tenant, 'Bawa pulang',     'takeaway', false, 1, base + 1),
               (p_tenant, 'Pesan antar',     'delivery', false, 2, base + 2);
    END IF;
    PERFORM set_config('app.tenant_id', COALESCE(prev, ''), true);
END
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE FUNCTION app.seed_tenant_sales_types() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM app.seed_system_sales_types(NEW.id);
    RETURN NULL;
END
$$;
-- +goose StatementEnd

CREATE TRIGGER tenants_seed_sales_types AFTER INSERT ON tenants
    FOR EACH ROW EXECUTE FUNCTION app.seed_tenant_sales_types();

SELECT app.seed_system_sales_types(id) FROM tenants;

-- +goose Down

DROP TRIGGER tenants_seed_sales_types ON tenants;
DROP FUNCTION app.seed_tenant_sales_types();
DROP FUNCTION app.seed_system_sales_types(uuid);
ALTER TABLE outlet_settings DROP CONSTRAINT outlet_settings_default_sales_type_fk;
DROP TABLE outlet_product_sales_type_prices;
DROP TABLE product_sales_type_prices;
DROP TABLE sales_types;
