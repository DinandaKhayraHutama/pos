-- +goose Up
-- Opt in per register on its first coordinated claim. Legacy receipts remain
-- ingestible; a register cannot silently fall back to legacy session opening.
ALTER TABLE pos_registers ADD COLUMN coordinated_sessions boolean NOT NULL DEFAULT false;
ALTER TABLE pos_registers ADD COLUMN receipt_counter bigint NOT NULL DEFAULT 0;

CREATE TABLE till_access (
    token_hash bytea PRIMARY KEY,
    -- Every other tenant-scoped table cascades. Without it, removing a
    -- merchant fails on a table holding nothing but expired sign-ins.
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    device_id uuid NOT NULL,
    employee_id uuid NOT NULL,
    pin_hash text NOT NULL,
    expires_at timestamptz NOT NULL,
    -- Cascades throughout: removing a merchant must not be blocked by a table
    -- of sign-ins. Employees are deactivated, never deleted, so a cascade here
    -- only ever fires as part of removing the merchant itself.
    FOREIGN KEY (tenant_id, device_id) REFERENCES devices(tenant_id,id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, employee_id) REFERENCES employees(tenant_id,id) ON DELETE CASCADE
);
CREATE INDEX till_access_expiry ON till_access(expires_at);

CREATE TABLE till_claims (
    session_id uuid PRIMARY KEY,
    tenant_id uuid NOT NULL,
    outlet_id uuid NOT NULL,
    register_id uuid NOT NULL,
    device_id uuid NOT NULL,
    active_employee_id uuid,
    receipt_start bigint NOT NULL,
    receipt_end bigint NOT NULL,
    FOREIGN KEY (tenant_id,outlet_id,register_id,session_id)
        REFERENCES pos_sessions(tenant_id,outlet_id,pos_register_id,id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id,device_id) REFERENCES devices(tenant_id,id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id,active_employee_id) REFERENCES employees(tenant_id,id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX till_one_active_cashier ON till_claims(tenant_id,active_employee_id)
    WHERE active_employee_id IS NOT NULL;

CREATE TABLE till_operators (
    tenant_id uuid NOT NULL,
    session_id uuid NOT NULL REFERENCES till_claims(session_id) ON DELETE CASCADE,
    employee_id uuid NOT NULL,
    PRIMARY KEY (tenant_id,session_id,employee_id),
    FOREIGN KEY (tenant_id,employee_id) REFERENCES employees(tenant_id,id) ON DELETE CASCADE
);

-- +goose StatementBegin
DO $$ DECLARE tbl text; BEGIN
    FOREACH tbl IN ARRAY ARRAY['till_access','till_claims','till_operators'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', tbl);
        EXECUTE format('CREATE POLICY tenant_isolation ON %I USING (tenant_id = app.current_tenant_id()) WITH CHECK (tenant_id = app.current_tenant_id())', tbl);
    END LOOP;
END $$;
-- +goose StatementEnd

-- +goose Down
DROP TABLE till_operators;
DROP TABLE till_claims;
DROP TABLE till_access;
ALTER TABLE pos_registers DROP COLUMN receipt_counter;
ALTER TABLE pos_registers DROP COLUMN coordinated_sessions;
