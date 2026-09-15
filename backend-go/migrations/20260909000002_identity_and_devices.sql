-- +goose Up

CREATE TABLE employees (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name       text NOT NULL,
    -- Globally unique, not per tenant: backoffice login resolves an account
    -- from the address alone, so the same one in two merchants is ambiguous.
    email      text UNIQUE,
    password   text,
    -- bcrypt, pushed down to tills and verified on-device so a cashier can sign
    -- in with no network. Uniqueness within a tenant cannot be an index: bcrypt
    -- is salted, so the same PIN hashes differently every time.
    pin_hash   text,
    role       text NOT NULL CHECK (role IN ('cashier', 'manager', 'owner')),
    active     boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    sync_seq   bigint NOT NULL DEFAULT 0,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id)
);

CREATE INDEX employees_tenant_seq_idx ON employees (tenant_id, sync_seq);
CREATE INDEX employees_tenant_active_idx ON employees (tenant_id, active);

CREATE TABLE pos_registers (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id     uuid NOT NULL,
    name          text NOT NULL,
    table_service boolean NOT NULL DEFAULT true,
    active        boolean NOT NULL DEFAULT true,
    sort_order    integer NOT NULL DEFAULT 0,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    -- Every branch is allowed its own "Kasir 1".
    UNIQUE (outlet_id, name),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, outlet_id, id),
    -- A register pointing at another merchant's outlet is rejected by the
    -- database, so it cannot survive a bug in application code.
    CONSTRAINT pos_registers_outlet_context_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id) ON DELETE CASCADE
);

CREATE INDEX pos_registers_tenant_outlet_idx ON pos_registers (tenant_id, outlet_id);

CREATE TABLE devices (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id        uuid NOT NULL,
    pos_register_id  uuid NOT NULL,
    device_uuid      text NOT NULL,
    label            text,
    platform         text,
    -- The bearer token is never stored. 32 random bytes have enough entropy
    -- that a hash is sufficient, and bcrypt in the auth hot path would cost
    -- ~100ms on every request.
    token_sha256     bytea UNIQUE,
    token_expires_at timestamptz,
    last_seen_at     timestamptz,
    revoked_at       timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, device_uuid),
    UNIQUE (tenant_id, id),
    CONSTRAINT devices_register_context_fk
        FOREIGN KEY (tenant_id, outlet_id, pos_register_id)
        REFERENCES pos_registers (tenant_id, outlet_id, id) ON DELETE CASCADE
);

CREATE INDEX devices_tenant_register_idx ON devices (tenant_id, pos_register_id);

CREATE TABLE activation_codes (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id            uuid NOT NULL,
    pos_register_id      uuid NOT NULL,
    -- HMAC of the code, never the code. The plaintext is returned exactly once,
    -- from the issuing call, and is never written to a row, a log or a
    -- notification — any of which parks a live credential somewhere durable.
    fingerprint          bytea NOT NULL UNIQUE,
    expires_at           timestamptz NOT NULL,
    consumed_at          timestamptz,
    cancelled_at         timestamptz,
    issued_by_employee_id uuid,
    device_id            uuid REFERENCES devices (id) ON DELETE SET NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT activation_codes_register_context_fk
        FOREIGN KEY (tenant_id, outlet_id, pos_register_id)
        REFERENCES pos_registers (tenant_id, outlet_id, id) ON DELETE CASCADE,
    CONSTRAINT activation_codes_issuer_context_fk
        FOREIGN KEY (tenant_id, issued_by_employee_id)
        REFERENCES employees (tenant_id, id) ON DELETE SET NULL
);

-- Only one code may be outstanding per register: issuing a new one cancels any
-- previous, and this makes that structural rather than remembered.
CREATE UNIQUE INDEX activation_codes_one_pending_per_register
    ON activation_codes (pos_register_id)
    WHERE consumed_at IS NULL AND cancelled_at IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE
    ON employees, pos_registers, devices, activation_codes
    TO justclick_app;

ALTER TABLE employees        ENABLE ROW LEVEL SECURITY;
ALTER TABLE employees        FORCE  ROW LEVEL SECURITY;
ALTER TABLE pos_registers    ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos_registers    FORCE  ROW LEVEL SECURITY;
ALTER TABLE devices          ENABLE ROW LEVEL SECURITY;
ALTER TABLE devices          FORCE  ROW LEVEL SECURITY;
ALTER TABLE activation_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE activation_codes FORCE  ROW LEVEL SECURITY;

CREATE POLICY employees_tenant_isolation ON employees
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

CREATE POLICY pos_registers_tenant_isolation ON pos_registers
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

CREATE POLICY devices_tenant_isolation ON devices
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

CREATE POLICY activation_codes_tenant_isolation ON activation_codes
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

-- +goose Down

DROP TABLE activation_codes;
DROP TABLE devices;
DROP TABLE pos_registers;
DROP TABLE employees;
