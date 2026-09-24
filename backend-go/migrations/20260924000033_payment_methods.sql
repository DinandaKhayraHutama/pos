-- +goose Up

-- Fase 3 paritas: payment methods, and groups of them assigned to outlets.
--
-- An order's wire payment_method stays the method's KIND. That is what every
-- drawer calculation compares to 'cash' (ingest/recovery.go, history/sessions.go,
-- the till's shift_repository), so a merchant's "EDC BCA" and "EDC Mandiri"
-- both land as card and the cash in the drawer stays arithmetic nobody had to
-- touch. The method's own id and name travel beside it as a snapshot.
--
-- QRIS, EDC and e-wallets are recorded, not processed: Fase 3 integrates no
-- payment provider, and every non-cash method says so on the receipt.
CREATE TABLE payment_methods (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name               text NOT NULL,
    kind               text NOT NULL CHECK (kind IN ('cash', 'card', 'qris', 'ewallet', 'transfer', 'other')),
    system_key         text CHECK (system_key IN ('cash', 'card', 'qris')),
    requires_reference boolean NOT NULL DEFAULT false,
    active             boolean NOT NULL DEFAULT true,
    sort_order         integer NOT NULL DEFAULT 0,
    sync_seq           bigint NOT NULL DEFAULT 0,
    deleted_at         timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT payment_methods_one_per_system_key UNIQUE (tenant_id, system_key),
    CONSTRAINT payment_methods_system_kind CHECK (system_key IS NULL OR system_key = kind),
    CONSTRAINT payment_methods_name_length CHECK (length(name) <= 120)
);

CREATE INDEX payment_methods_sync_feed_idx ON payment_methods (tenant_id, sync_seq)
    INCLUDE (id, name, kind, system_key, requires_reference, active, sort_order, deleted_at);

-- A named set of methods ("Outlet mal", "Outlet ruko"), assigned to branches
-- through outlet_settings.payment_group_id. A branch with no group offers
-- every active method.
CREATE TABLE payment_groups (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name       text NOT NULL,
    method_ids uuid[] NOT NULL DEFAULT '{}',
    active     boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    sync_seq   bigint NOT NULL DEFAULT 0,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT payment_groups_name_length CHECK (length(name) <= 120),
    CONSTRAINT payment_groups_methods_size CHECK (cardinality(method_ids) <= 32)
);

CREATE INDEX payment_groups_sync_feed_idx ON payment_groups (tenant_id, sync_seq)
    INCLUDE (id, name, method_ids, active, sort_order, deleted_at);

ALTER TABLE outlet_settings ADD CONSTRAINT outlet_settings_payment_group_fk
    FOREIGN KEY (tenant_id, payment_group_id) REFERENCES payment_groups (tenant_id, id);

GRANT SELECT, INSERT, UPDATE, DELETE ON payment_methods, payment_groups TO justclick_app;

ALTER TABLE payment_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_methods FORCE  ROW LEVEL SECURITY;
CREATE POLICY payment_methods_tenant_isolation ON payment_methods
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

ALTER TABLE payment_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_groups FORCE  ROW LEVEL SECURITY;
CREATE POLICY payment_groups_tenant_isolation ON payment_groups
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

-- +goose StatementBegin
CREATE FUNCTION app.seed_system_payment_methods(p_tenant uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    prev text := current_setting('app.tenant_id', true);
    base bigint;
BEGIN
    PERFORM set_config('app.tenant_id', p_tenant::text, true);
    IF NOT EXISTS (SELECT 1 FROM payment_methods WHERE tenant_id = p_tenant AND system_key IS NOT NULL) THEN
        base := app.alloc_sync_block(p_tenant, 'payment_methods', 3);
        INSERT INTO payment_methods (tenant_id, name, kind, system_key, sort_order, sync_seq)
        VALUES (p_tenant, 'Tunai', 'cash', 'cash', 0, base),
               (p_tenant, 'Kartu', 'card', 'card', 1, base + 1),
               (p_tenant, 'QRIS',  'qris', 'qris', 2, base + 2);
    END IF;
    PERFORM set_config('app.tenant_id', COALESCE(prev, ''), true);
END
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE FUNCTION app.seed_tenant_payment_methods() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM app.seed_system_payment_methods(NEW.id);
    RETURN NULL;
END
$$;
-- +goose StatementEnd

CREATE TRIGGER tenants_seed_payment_methods AFTER INSERT ON tenants
    FOR EACH ROW EXECUTE FUNCTION app.seed_tenant_payment_methods();

SELECT app.seed_system_payment_methods(id) FROM tenants;

-- +goose Down

DROP TRIGGER tenants_seed_payment_methods ON tenants;
DROP FUNCTION app.seed_tenant_payment_methods();
DROP FUNCTION app.seed_system_payment_methods(uuid);
ALTER TABLE outlet_settings DROP CONSTRAINT outlet_settings_payment_group_fk;
DROP TABLE payment_groups;
DROP TABLE payment_methods;
