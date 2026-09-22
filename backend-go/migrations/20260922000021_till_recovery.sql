-- +goose Up
-- Forced closure is explicit. Existing sessions are normal closures.
ALTER TABLE pos_sessions
    ADD COLUMN close_kind text NOT NULL DEFAULT 'normal'
        CHECK (close_kind IN ('normal','forced'));

CREATE TABLE till_recoveries (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id uuid NOT NULL,
    register_id uuid NOT NULL,
    session_id uuid NOT NULL,
    device_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    actor_employee_id uuid,
    actor_name text NOT NULL,
    reason text NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 2000),
    forced_at timestamptz NOT NULL DEFAULT now(),
    order_count_at_takeover bigint NOT NULL CHECK (order_count_at_takeover >= 0),
    expected_cash_at_takeover bigint NOT NULL,
    counted_cash bigint CHECK (counted_cash >= 0),
    status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','reconciled')),
    reconciliation_basis text CHECK (reconciliation_basis IN ('device_checked','device_unavailable')),
    reconciliation_reason text,
    reconciled_at timestamptz,
    reconciled_by_employee_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id,id),
    UNIQUE (tenant_id,operation_id),
    UNIQUE (tenant_id,session_id),
    FOREIGN KEY (tenant_id,outlet_id,register_id,session_id)
        REFERENCES pos_sessions(tenant_id,outlet_id,pos_register_id,id),
    FOREIGN KEY (tenant_id,device_id) REFERENCES devices(tenant_id,id),
    FOREIGN KEY (tenant_id,actor_employee_id) REFERENCES employees(tenant_id,id) ON DELETE SET NULL,
    FOREIGN KEY (tenant_id,reconciled_by_employee_id) REFERENCES employees(tenant_id,id) ON DELETE SET NULL,
    CHECK ((status='open' AND reconciliation_basis IS NULL AND reconciled_at IS NULL)
        OR (status='reconciled' AND reconciliation_basis IS NOT NULL AND reconciled_at IS NOT NULL))
);

ALTER TABLE pos_sessions ADD COLUMN forced_recovery_id uuid;
ALTER TABLE pos_sessions ADD CONSTRAINT pos_sessions_forced_recovery_fk
    FOREIGN KEY (tenant_id,forced_recovery_id) REFERENCES till_recoveries(tenant_id,id);
ALTER TABLE pos_sessions ADD CONSTRAINT pos_sessions_force_metadata
    CHECK ((close_kind='normal' AND forced_recovery_id IS NULL)
        OR (close_kind='forced' AND forced_recovery_id IS NOT NULL));

CREATE TABLE till_recovery_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    recovery_id uuid NOT NULL,
    entity text NOT NULL,
    entity_id uuid NOT NULL,
    revision bigint NOT NULL CHECK (revision > 0),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload)='object'),
    payload_sha256 bytea NOT NULL,
    source_ingest_date date NOT NULL,
    source_ingest_id uuid NOT NULL,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','discarded')),
    decision_reason text,
    decided_at timestamptz,
    decided_by_employee_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id,id),
    UNIQUE (recovery_id,entity,entity_id,revision),
    FOREIGN KEY (tenant_id,recovery_id) REFERENCES till_recoveries(tenant_id,id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id,decided_by_employee_id) REFERENCES employees(tenant_id,id) ON DELETE SET NULL,
    -- Keep the durable audit coordinates for traceability without a foreign
    -- key: ingest_log partitions are deliberately retired after retention,
    -- while the copied recovery payload must remain permanently reviewable.
    CHECK ((status='pending' AND decided_at IS NULL)
        OR (status<>'pending' AND decided_at IS NOT NULL))
);

CREATE TABLE till_recovery_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    recovery_id uuid NOT NULL,
    event_type text NOT NULL CHECK (event_type IN
        ('takeover','item_found','item_accepted','item_discarded','reconciled')),
    actor_employee_id uuid,
    actor_name text,
    detail jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(detail)='object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id,recovery_id) REFERENCES till_recoveries(tenant_id,id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id,actor_employee_id) REFERENCES employees(tenant_id,id) ON DELETE SET NULL
);

CREATE INDEX till_recoveries_open ON till_recoveries(tenant_id,forced_at DESC) WHERE status='open';
CREATE INDEX till_recovery_items_pending ON till_recovery_items(tenant_id,recovery_id,created_at) WHERE status='pending';
CREATE INDEX till_recovery_events_case ON till_recovery_events(tenant_id,recovery_id,created_at);

-- +goose StatementBegin
DO $$ DECLARE tbl text; BEGIN
    FOREACH tbl IN ARRAY ARRAY['till_recoveries','till_recovery_items','till_recovery_events'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', tbl);
        EXECUTE format('CREATE POLICY tenant_isolation ON %I USING (tenant_id = app.current_tenant_id()) WITH CHECK (tenant_id = app.current_tenant_id())', tbl);
    END LOOP;
END $$;
-- +goose StatementEnd

GRANT SELECT, INSERT, UPDATE ON till_recoveries, till_recovery_items TO justclick_app;
GRANT SELECT, INSERT ON till_recovery_events TO justclick_app;

-- +goose Down
ALTER TABLE pos_sessions DROP CONSTRAINT pos_sessions_force_metadata;
ALTER TABLE pos_sessions DROP CONSTRAINT pos_sessions_forced_recovery_fk;
ALTER TABLE pos_sessions DROP COLUMN forced_recovery_id;
DROP TABLE till_recovery_events;
DROP TABLE till_recovery_items;
DROP TABLE till_recoveries;
ALTER TABLE pos_sessions DROP COLUMN close_kind;
