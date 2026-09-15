-- +goose Up

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE SCHEMA IF NOT EXISTS app;

-- The application must never touch tenant data as a superuser or as the tables'
-- owner: PostgreSQL exempts both from every RLS policy, silently and with no
-- error to notice. justclick_app is neither, so the policies below actually
-- bind. pg.InTenantTx switches to this role for the life of each transaction.
-- +goose StatementBegin
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'justclick_app') THEN
        CREATE ROLE justclick_app NOLOGIN;
    END IF;
END
$$;
-- +goose StatementEnd

GRANT justclick_app TO CURRENT_USER;
GRANT USAGE ON SCHEMA public TO justclick_app;
GRANT USAGE ON SCHEMA app TO justclick_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO justclick_app;

-- Returns NULL when app.tenant_id is unset. Every policy compares against this,
-- so an unresolved tenant matches nothing rather than everything.
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION app.current_tenant_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid
$$;
-- +goose StatementEnd

CREATE TABLE tenants (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text NOT NULL,
    slug       text NOT NULL UNIQUE,
    status     text NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE outlets (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name       text NOT NULL,
    address    text,
    phone      text,
    active     boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, name)
);

CREATE INDEX outlets_tenant_active_idx ON outlets (tenant_id, active);

GRANT SELECT, INSERT, UPDATE, DELETE ON tenants, outlets TO justclick_app;

-- FORCE as well as ENABLE: without it the table owner bypasses every policy,
-- which is a second way to get the failure this is here to prevent.
ALTER TABLE outlets ENABLE ROW LEVEL SECURITY;
ALTER TABLE outlets FORCE ROW LEVEL SECURITY;

CREATE POLICY outlets_tenant_isolation ON outlets
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

-- +goose Down

DROP TABLE outlets;
DROP TABLE tenants;
DROP FUNCTION app.current_tenant_id();
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM justclick_app;
DROP SCHEMA app;
DROP ROLE justclick_app;
