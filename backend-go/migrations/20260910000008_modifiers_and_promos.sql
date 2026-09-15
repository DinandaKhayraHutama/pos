-- +goose Up

-- Modifiers and promos: the two catalogue areas the till has always had
-- locally and the server has never known about.
--
-- Both are company-shared and pull-only, like the rest of the menu. The only
-- subtlety is the two join tables, and it is a money-shaped one — see the note
-- on product_modifier_options below.

CREATE TABLE modifier_groups (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name           text NOT NULL,
    selection_type text NOT NULL DEFAULT 'single'
        CHECK (selection_type IN ('single', 'multiple')),
    required       boolean NOT NULL DEFAULT false,
    -- NULL = no upper bound, and only meaningful when selection_type is
    -- 'multiple'; a single group is implicitly capped at one.
    max_select     integer,
    sort_order     integer NOT NULL DEFAULT 0,
    active         boolean NOT NULL DEFAULT true,
    sync_seq       bigint NOT NULL DEFAULT 0,
    deleted_at     timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT modifier_groups_name_length CHECK (length(name) <= 120)
);

CREATE TABLE modifier_options (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    group_id    uuid NOT NULL,
    name        text NOT NULL,
    -- Non-negative, unlike product_variants.price_delta: a modifier adds to a
    -- line, it never discounts one. Discounts are promos, which are audited.
    price_delta bigint NOT NULL DEFAULT 0 CHECK (price_delta >= 0),
    sort_order  integer NOT NULL DEFAULT 0,
    active      boolean NOT NULL DEFAULT true,
    sync_seq    bigint NOT NULL DEFAULT 0,
    deleted_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT modifier_options_group_context_fk
        FOREIGN KEY (tenant_id, group_id) REFERENCES modifier_groups (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT modifier_options_name_length CHECK (length(name) <= 120)
);

-- Which groups a product offers. Reusable and many-to-many: "Toppings" is
-- defined once and attached to every coffee on the menu.
CREATE TABLE product_modifier_groups (
    tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    product_id uuid NOT NULL,
    group_id   uuid NOT NULL,
    sync_seq   bigint NOT NULL DEFAULT 0,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (product_id, group_id),
    CONSTRAINT product_modifier_groups_product_context_fk
        FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT product_modifier_groups_group_context_fk
        FOREIGN KEY (tenant_id, group_id) REFERENCES modifier_groups (tenant_id, id) ON DELETE CASCADE
);

-- Which of an attached group's options this product actually offers — a
-- further narrowing UNDER product_modifier_groups, so "Topping" stays one
-- reusable group while a pastry and a coffee attached to it each show a
-- different subset.
--
-- This is the table the manifest marks apply:"upsert" rather than "replace".
-- The till's ConflictAlgorithm.replace deletes before inserting, and on the
-- device this table's ON DELETE CASCADE hangs off modifier_options — so a
-- "replace" apply of one row would take every product's option scoping with
-- it. Menus would quietly start offering choices nobody priced.
--
-- Keyed by option alone rather than group+option: an option already belongs to
-- exactly one group, and a product either offers it or it does not.
CREATE TABLE product_modifier_options (
    tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    product_id uuid NOT NULL,
    option_id  uuid NOT NULL,
    is_default boolean NOT NULL DEFAULT false,
    sync_seq   bigint NOT NULL DEFAULT 0,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (product_id, option_id),
    CONSTRAINT product_modifier_options_product_context_fk
        FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT product_modifier_options_option_context_fk
        FOREIGN KEY (tenant_id, option_id) REFERENCES modifier_options (tenant_id, id) ON DELETE CASCADE
);

CREATE TABLE promos (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name       text NOT NULL,
    kind       text NOT NULL CHECK (kind IN ('percent', 'amount')),
    -- Percentage points when kind is 'percent', otherwise integer rupiah.
    value      bigint NOT NULL,
    min_spend  bigint NOT NULL DEFAULT 0,
    active     boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    sync_seq   bigint NOT NULL DEFAULT 0,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT promos_name_length CHECK (length(name) <= 120),
    -- A 120% discount is a refund with extra steps, and the till's own form
    -- already refuses it. The rule belongs where both writers meet.
    CONSTRAINT promos_value_range CHECK (
        value > 0 AND (kind <> 'percent' OR value <= 100)
    ),
    CONSTRAINT promos_min_spend_range CHECK (min_spend >= 0)
);

-- Promo scoping is a table, not an array column on promos: a delta feed has to
-- be able to say "this one branch stopped being included", and a rewritten
-- array can only say "the promo changed" — every till in the chain then re-reads
-- a row that did not concern it.
CREATE TABLE promo_outlets (
    tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    promo_id   uuid NOT NULL,
    outlet_id  uuid NOT NULL,
    sync_seq   bigint NOT NULL DEFAULT 0,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (promo_id, outlet_id),
    CONSTRAINT promo_outlets_promo_context_fk
        FOREIGN KEY (tenant_id, promo_id) REFERENCES promos (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT promo_outlets_outlet_context_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id) ON DELETE CASCADE
);

-- The same covering feed index every syncable table gets. The INCLUDE list is
-- the entity's published columns in internal/domain/sync/registry.go and must
-- stay in step with it.
CREATE INDEX modifier_groups_sync_feed_idx ON modifier_groups (tenant_id, sync_seq)
    INCLUDE (id, name, selection_type, required, max_select, sort_order, active, deleted_at);

CREATE INDEX modifier_options_sync_feed_idx ON modifier_options (tenant_id, sync_seq)
    INCLUDE (id, group_id, name, price_delta, sort_order, active, deleted_at);

CREATE INDEX product_modifier_groups_sync_feed_idx ON product_modifier_groups (tenant_id, sync_seq)
    INCLUDE (product_id, group_id, deleted_at);

CREATE INDEX product_modifier_options_sync_feed_idx ON product_modifier_options (tenant_id, sync_seq)
    INCLUDE (product_id, option_id, is_default, deleted_at);

CREATE INDEX promos_sync_feed_idx ON promos (tenant_id, sync_seq)
    INCLUDE (id, name, kind, value, min_spend, active, sort_order, deleted_at);

CREATE INDEX promo_outlets_sync_feed_idx ON promo_outlets (tenant_id, sync_seq)
    INCLUDE (promo_id, outlet_id, deleted_at);

-- The Backoffice reads these the other way round — "what does this product
-- offer", "which branches is this promo live in".
CREATE INDEX modifier_options_tenant_group_idx ON modifier_options (tenant_id, group_id);
CREATE INDEX product_modifier_groups_tenant_group_idx ON product_modifier_groups (tenant_id, group_id);
CREATE INDEX product_modifier_options_tenant_option_idx ON product_modifier_options (tenant_id, option_id);
CREATE INDEX promo_outlets_tenant_outlet_idx ON promo_outlets (tenant_id, outlet_id);

GRANT SELECT, INSERT, UPDATE, DELETE
    ON modifier_groups, modifier_options, product_modifier_groups,
       product_modifier_options, promos, promo_outlets
    TO justclick_app;

ALTER TABLE modifier_groups           ENABLE ROW LEVEL SECURITY;
ALTER TABLE modifier_groups           FORCE  ROW LEVEL SECURITY;
ALTER TABLE modifier_options          ENABLE ROW LEVEL SECURITY;
ALTER TABLE modifier_options          FORCE  ROW LEVEL SECURITY;
ALTER TABLE product_modifier_groups   ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_modifier_groups   FORCE  ROW LEVEL SECURITY;
ALTER TABLE product_modifier_options  ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_modifier_options  FORCE  ROW LEVEL SECURITY;
ALTER TABLE promos                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE promos                    FORCE  ROW LEVEL SECURITY;
ALTER TABLE promo_outlets             ENABLE ROW LEVEL SECURITY;
ALTER TABLE promo_outlets             FORCE  ROW LEVEL SECURITY;

CREATE POLICY modifier_groups_tenant_isolation ON modifier_groups
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

CREATE POLICY modifier_options_tenant_isolation ON modifier_options
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

CREATE POLICY product_modifier_groups_tenant_isolation ON product_modifier_groups
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

CREATE POLICY product_modifier_options_tenant_isolation ON product_modifier_options
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

CREATE POLICY promos_tenant_isolation ON promos
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

CREATE POLICY promo_outlets_tenant_isolation ON promo_outlets
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

-- +goose Down

DROP TABLE promo_outlets;
DROP TABLE promos;
DROP TABLE product_modifier_options;
DROP TABLE product_modifier_groups;
DROP TABLE modifier_options;
DROP TABLE modifier_groups;
