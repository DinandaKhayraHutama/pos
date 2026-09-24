-- +goose Up

-- Fase 3 paritas: roles made of permissions.
--
-- A table for IDENTITY, code for the system permission sets. The three system
-- roles keep taking their permissions from internal/domain/auth/permission.go
-- and mobile/lib/core/auth/permissions.dart, and store an empty list here on
-- purpose (roles_system_permissions): owner stays DERIVED — every permission
-- except the till set — so a permission added next year still reaches every
-- owner without a reseed, which a stored copy could never promise. Only a
-- custom role stores its list.
CREATE TABLE roles (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name              text NOT NULL,
    system_key        text CHECK (system_key IN ('cashier', 'manager', 'owner')),
    permissions       text[] NOT NULL DEFAULT '{}',
    pos_access        boolean NOT NULL DEFAULT true,
    backoffice_access boolean NOT NULL DEFAULT false,
    sort_order        integer NOT NULL DEFAULT 0,
    sync_seq          bigint NOT NULL DEFAULT 0,
    deleted_at        timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT roles_one_per_system_key UNIQUE (tenant_id, system_key),
    CONSTRAINT roles_system_permissions CHECK (system_key IS NULL OR permissions = '{}'),
    -- Every published column travels inside the covering index, whose tuple
    -- may not exceed ~2704 bytes: 32 names of at most ~30 bytes stay well
    -- inside it.
    CONSTRAINT roles_permissions_size CHECK (cardinality(permissions) <= 32),
    CONSTRAINT roles_name_length CHECK (length(name) <= 120)
);

CREATE INDEX roles_sync_feed_idx ON roles (tenant_id, sync_seq)
    INCLUDE (id, name, system_key, permissions, pos_access, backoffice_access, sort_order, deleted_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON roles TO justclick_app;

ALTER TABLE roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE roles FORCE  ROW LEVEL SECURITY;

CREATE POLICY roles_tenant_isolation ON roles
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

-- The three system roles of one merchant, numbered like any feed row: a row
-- left at sync_seq 0 is a row no till ever receives. The tenant context is
-- set for the insert so the policies hold for a non-superuser caller too, and
-- put back afterwards because is_local lasts to the end of the transaction.
-- +goose StatementBegin
CREATE FUNCTION app.seed_system_roles(p_tenant uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    prev text := current_setting('app.tenant_id', true);
    base bigint;
BEGIN
    PERFORM set_config('app.tenant_id', p_tenant::text, true);
    IF NOT EXISTS (SELECT 1 FROM roles WHERE tenant_id = p_tenant AND system_key IS NOT NULL) THEN
        base := app.alloc_sync_block(p_tenant, 'roles', 3);
        INSERT INTO roles (tenant_id, name, system_key, pos_access, backoffice_access, sort_order, sync_seq)
        VALUES (p_tenant, 'Kasir',   'cashier', true, false, 0, base),
               (p_tenant, 'Manajer', 'manager', true, true,  1, base + 1),
               (p_tenant, 'Pemilik', 'owner',   true, true,  2, base + 2);
    END IF;
    PERFORM set_config('app.tenant_id', COALESCE(prev, ''), true);
END
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE FUNCTION app.seed_tenant_roles() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM app.seed_system_roles(NEW.id);
    RETURN NULL;
END
$$;
-- +goose StatementEnd

-- A trigger rather than Go, so every path that creates a merchant — platform
-- onboarding, the CLI, every test fixture, the load harness — gets the rows
-- its employees are about to reference.
CREATE TRIGGER tenants_seed_roles AFTER INSERT ON tenants
    FOR EACH ROW EXECUTE FUNCTION app.seed_tenant_roles();

SELECT app.seed_system_roles(id) FROM tenants;

-- employees.role_id names the role; employees.role is kept, derived from it.
-- Keeping the text is what lets every existing `role = 'owner'` lookup — the
-- last-owner guard, impersonation, the platform's owner listing — keep
-- working unchanged, and what an older till still reads. The trigger below
-- keeps the two from ever disagreeing.
ALTER TABLE employees
    ADD COLUMN role_id uuid,
    ADD COLUMN phone   text,
    ADD CONSTRAINT employees_role_context_fk
        FOREIGN KEY (tenant_id, role_id) REFERENCES roles (tenant_id, id),
    ADD CONSTRAINT employees_phone_length CHECK (length(phone) <= 32);

UPDATE employees e SET role_id = r.id
FROM roles r
WHERE r.tenant_id = e.tenant_id AND r.system_key = e.role;

ALTER TABLE employees ALTER COLUMN role_id SET NOT NULL;

ALTER TABLE employees DROP CONSTRAINT employees_role_check;
ALTER TABLE employees ADD CONSTRAINT employees_role_check
    CHECK (role IN ('cashier', 'manager', 'owner', 'custom'));

CREATE INDEX employees_tenant_role_idx ON employees (tenant_id, role_id);

-- +goose StatementBegin
CREATE FUNCTION app.derive_employee_role() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    -- A write that changed only the text names a system role by key.
    IF TG_OP = 'UPDATE' AND NEW.role_id IS NOT DISTINCT FROM OLD.role_id
       AND NEW.role IS DISTINCT FROM OLD.role THEN
        NEW.role_id := NULL;
    END IF;

    IF NEW.role_id IS NULL THEN
        IF NEW.role = 'custom' THEN
            RAISE EXCEPTION 'a custom role must be named by role_id' USING ERRCODE = '23514';
        END IF;
        SELECT id INTO NEW.role_id FROM roles
        WHERE tenant_id = NEW.tenant_id AND system_key = NEW.role;
    ELSE
        SELECT COALESCE(system_key, 'custom') INTO NEW.role FROM roles
        WHERE tenant_id = NEW.tenant_id AND id = NEW.role_id;
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd

CREATE TRIGGER employees_derive_role BEFORE INSERT OR UPDATE OF role, role_id ON employees
    FOR EACH ROW EXECUTE FUNCTION app.derive_employee_role();

-- role_id is now published, so the covering index has to carry it.
DROP INDEX employees_sync_feed_idx;
CREATE INDEX employees_sync_feed_idx ON employees (tenant_id, sync_seq)
    INCLUDE (id, name, pin_hash, role, role_id, active, sort_order, deleted_at);

-- +goose Down

DROP INDEX employees_sync_feed_idx;
CREATE INDEX employees_sync_feed_idx ON employees (tenant_id, sync_seq)
    INCLUDE (id, name, pin_hash, role, active, sort_order, deleted_at);

DROP TRIGGER employees_derive_role ON employees;
DROP FUNCTION app.derive_employee_role();
DROP INDEX employees_tenant_role_idx;

-- A custom role has no place in the old model; the closest honest reading is
-- the role that grants nothing beyond the till, which is what an old till
-- already made of it.
UPDATE employees SET role = 'cashier' WHERE role = 'custom';
ALTER TABLE employees DROP CONSTRAINT employees_role_check;
ALTER TABLE employees ADD CONSTRAINT employees_role_check
    CHECK (role IN ('cashier', 'manager', 'owner'));

ALTER TABLE employees
    DROP CONSTRAINT employees_phone_length,
    DROP CONSTRAINT employees_role_context_fk,
    DROP COLUMN phone,
    DROP COLUMN role_id;

DROP TRIGGER tenants_seed_roles ON tenants;
DROP FUNCTION app.seed_tenant_roles();
DROP FUNCTION app.seed_system_roles(uuid);
DROP TABLE roles;
