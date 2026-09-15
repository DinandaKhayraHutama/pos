-- +goose Up
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_self ON tenants
    USING (id = app.current_tenant_id()) WITH CHECK (id = app.current_tenant_id());

-- Versions are database facts, read in the SAME snapshot as the binding.
-- Redis must never attach a post-revocation version to pre-revocation data.
ALTER TABLE tenants ADD COLUMN auth_generation bigint NOT NULL DEFAULT 1;
ALTER TABLE outlets ADD COLUMN auth_generation bigint NOT NULL DEFAULT 1;
ALTER TABLE pos_registers ADD COLUMN auth_generation bigint NOT NULL DEFAULT 1;
-- +goose StatementBegin
CREATE FUNCTION app.advance_auth_generation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.auth_generation := OLD.auth_generation + 1;
    RETURN NEW;
END $$;
-- +goose StatementEnd
CREATE TRIGGER tenant_auth_version BEFORE UPDATE ON tenants FOR EACH ROW EXECUTE FUNCTION app.advance_auth_generation();
CREATE TRIGGER outlet_auth_version BEFORE UPDATE ON outlets FOR EACH ROW EXECUTE FUNCTION app.advance_auth_generation();
CREATE TRIGGER register_auth_version BEFORE UPDATE ON pos_registers FOR EACH ROW EXECUTE FUNCTION app.advance_auth_generation();
-- Device changes invalidate only their own register, never the tenant row.
-- +goose StatementBegin
CREATE FUNCTION app.device_auth_changed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE pos_registers SET auth_generation = auth_generation + 1
      WHERE tenant_id = NEW.tenant_id AND id = NEW.pos_register_id;
    RETURN NEW;
END $$;
-- +goose StatementEnd
CREATE TRIGGER device_auth_version AFTER INSERT OR UPDATE OF token_sha256, token_expires_at, revoked_at ON devices
    FOR EACH ROW EXECUTE FUNCTION app.device_auth_changed();

-- +goose Down
DROP TRIGGER device_auth_version ON devices;
DROP FUNCTION app.device_auth_changed();
DROP TRIGGER register_auth_version ON pos_registers;
DROP TRIGGER outlet_auth_version ON outlets;
DROP TRIGGER tenant_auth_version ON tenants;
DROP FUNCTION app.advance_auth_generation();
ALTER TABLE pos_registers DROP COLUMN auth_generation;
ALTER TABLE outlets DROP COLUMN auth_generation;
ALTER TABLE tenants DROP COLUMN auth_generation;
DROP POLICY tenant_self ON tenants;
ALTER TABLE tenants DISABLE ROW LEVEL SECURITY;
