-- +goose Up

-- Fase 3 paritas: named discounts a cashier picks at the till.
--
-- A master of its own rather than more rows in `promos`: an older till pulls
-- promos and applies every one of them to the whole bill, so an item-level
-- discount stored there would be misapplied silently. `value` null means the
-- cashier types the amount (and so needs applyManualDiscount); a fixed value
-- without requires_authorization is usable by anyone who can sell.
CREATE TABLE discounts (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id              uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name                   text NOT NULL,
    scope                  text NOT NULL CHECK (scope IN ('bill', 'item')),
    kind                   text NOT NULL CHECK (kind IN ('percent', 'amount')),
    value                  bigint,
    requires_authorization boolean NOT NULL DEFAULT false,
    active                 boolean NOT NULL DEFAULT true,
    sort_order             integer NOT NULL DEFAULT 0,
    sync_seq               bigint NOT NULL DEFAULT 0,
    deleted_at             timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT discounts_name_length CHECK (length(name) <= 120),
    -- Percent is basis points: 10000 is the whole line or bill.
    CONSTRAINT discounts_value_range CHECK (
        value IS NULL OR (value >= 0 AND (kind <> 'percent' OR value <= 10000) AND value <= 1000000000000))
);

CREATE INDEX discounts_sync_feed_idx ON discounts (tenant_id, sync_seq)
    INCLUDE (id, name, scope, kind, value, requires_authorization, active, sort_order, deleted_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON discounts TO justclick_app;

ALTER TABLE discounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE discounts FORCE  ROW LEVEL SECURITY;
CREATE POLICY discounts_tenant_isolation ON discounts
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

-- +goose Down

DROP TABLE discounts;
