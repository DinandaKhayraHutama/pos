-- +goose Up

-- Fase 3 paritas: business configuration owned by the server.
--
-- Until now PB1, service charge and the receipt's identity lived in each
-- till's SharedPreferences, so two tablets in one shop could total the same
-- basket differently. business_settings holds the merchant's defaults,
-- outlet_settings one branch's overrides (null inherits, zero is a real
-- override). Tills pull both and cache them for offline use; theme, language
-- and printers stay preferences of the device.
--
-- business_settings has no row until the owner saves it, and that absence is
-- meaningful: a till whose merchant has never configured anything keeps the
-- values it was using rather than silently switching to a server default.
CREATE TABLE business_settings (
    tenant_id        uuid PRIMARY KEY REFERENCES tenants(id) ON DELETE CASCADE,
    tax_rate_bp      integer NOT NULL DEFAULT 1000 CHECK (tax_rate_bp BETWEEN 0 AND 10000),
    tax_mode         text    NOT NULL DEFAULT 'exclusive' CHECK (tax_mode IN ('exclusive', 'inclusive')),
    service_enabled  boolean NOT NULL DEFAULT false,
    service_rate_bp  integer NOT NULL DEFAULT 500 CHECK (service_rate_bp BETWEEN 0 AND 10000),
    service_taxable  boolean NOT NULL DEFAULT true,
    rounding_unit    integer NOT NULL DEFAULT 0 CHECK (rounding_unit IN (0, 100, 500, 1000)),
    rounding_mode    text    NOT NULL DEFAULT 'nearest' CHECK (rounding_mode IN ('nearest', 'up', 'down')),
    receipt_logo_url text,
    -- Not published: where the file lives on disk, like products.image_key.
    receipt_logo_key text,
    receipt_footer   text,
    sync_seq         bigint NOT NULL DEFAULT 0,
    deleted_at       timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    -- Octets, not characters: these travel in the covering index, and a
    -- btree tuple may not exceed ~2704 bytes whatever the text is written in.
    CONSTRAINT business_settings_logo_length   CHECK (octet_length(receipt_logo_url) <= 512),
    CONSTRAINT business_settings_footer_length CHECK (octet_length(receipt_footer) <= 600)
);

CREATE INDEX business_settings_sync_feed_idx ON business_settings (tenant_id, sync_seq)
    INCLUDE (tax_rate_bp, tax_mode, service_enabled, service_rate_bp, service_taxable,
             rounding_unit, rounding_mode, receipt_logo_url, receipt_footer, deleted_at);

CREATE TABLE outlet_settings (
    tenant_id             uuid NOT NULL,
    outlet_id             uuid NOT NULL,
    tax_rate_bp           integer CHECK (tax_rate_bp BETWEEN 0 AND 10000),
    tax_mode              text    CHECK (tax_mode IN ('exclusive', 'inclusive')),
    service_enabled       boolean,
    service_rate_bp       integer CHECK (service_rate_bp BETWEEN 0 AND 10000),
    service_taxable       boolean,
    rounding_unit         integer CHECK (rounding_unit IN (0, 100, 500, 1000)),
    rounding_mode         text    CHECK (rounding_mode IN ('nearest', 'up', 'down')),
    receipt_header        text,
    receipt_footer        text,
    show_address          boolean NOT NULL DEFAULT true,
    show_phone            boolean NOT NULL DEFAULT true,
    track_server          boolean NOT NULL DEFAULT false,
    default_sales_type_id uuid,
    -- NULL means every active sales type; an array narrows it.
    sales_type_ids        uuid[],
    payment_group_id      uuid,
    -- The Fase 3 pricing engine is switched on per branch, and only once every
    -- active till of that branch reports it can run it.
    pricing_model         text NOT NULL DEFAULT 'legacy' CHECK (pricing_model IN ('legacy', 'v2')),
    sync_seq              bigint NOT NULL DEFAULT 0,
    deleted_at            timestamptz,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, outlet_id),
    CONSTRAINT outlet_settings_outlet_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT outlet_settings_header_length CHECK (octet_length(receipt_header) <= 600),
    CONSTRAINT outlet_settings_footer_length CHECK (octet_length(receipt_footer) <= 600),
    CONSTRAINT outlet_settings_sales_types_size CHECK (cardinality(sales_type_ids) <= 32)
);

CREATE INDEX outlet_settings_sync_feed_idx ON outlet_settings (tenant_id, outlet_id, sync_seq)
    INCLUDE (tax_rate_bp, tax_mode, service_enabled, service_rate_bp, service_taxable,
             rounding_unit, rounding_mode, receipt_header, receipt_footer, show_address,
             show_phone, track_server, default_sales_type_id, sales_type_ids, payment_group_id,
             pricing_model, deleted_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON business_settings, outlet_settings TO justclick_app;

ALTER TABLE business_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE business_settings FORCE  ROW LEVEL SECURITY;
CREATE POLICY business_settings_tenant_isolation ON business_settings
    USING (tenant_id = app.current_tenant_id()) 
    WITH CHECK (tenant_id = app.current_tenant_id());

ALTER TABLE outlet_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE outlet_settings FORCE  ROW LEVEL SECURITY;
CREATE POLICY outlet_settings_tenant_isolation ON outlet_settings
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

-- The timezone becomes editable, and hourly rollups used to read the CURRENT
-- zone for every order. Freezing today's value here keeps a recompute of an
-- old slice from moving its hours: nothing has ever edited the timezone, so
-- this is exact for every order written before Fase 3, and newer orders carry
-- the offset they were dated with.
ALTER TABLE tenants ADD COLUMN legacy_timezone text;
UPDATE tenants SET legacy_timezone = timezone;

-- +goose Down

ALTER TABLE tenants DROP COLUMN legacy_timezone;
DROP TABLE outlet_settings;
DROP TABLE business_settings;
