-- +goose Up

-- activation_codes.device_id pointed at devices(id) alone, so nothing stopped a
-- code from naming a device belonging to another merchant. Application code
-- never does that today — it links the device it just created in the same
-- tenant-scoped transaction — but "unlikely" is a weaker guarantee than the one
-- the register and issuer columns already have, and the whole point of the
-- composite keys is that a bug in application code cannot produce the row.
--
-- ON DELETE SET NULL names the column explicitly (PostgreSQL 15+): the default
-- would try to null tenant_id too, which is NOT NULL. The code row outlives the
-- device on purpose — it is the audit trail of how that till was set up.
ALTER TABLE activation_codes
    DROP CONSTRAINT activation_codes_device_id_fkey;

ALTER TABLE activation_codes
    ADD CONSTRAINT activation_codes_device_context_fk
    FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id)
    ON DELETE SET NULL (device_id);

-- +goose Down

ALTER TABLE activation_codes
    DROP CONSTRAINT activation_codes_device_context_fk;

ALTER TABLE activation_codes
    ADD CONSTRAINT activation_codes_device_id_fkey
    FOREIGN KEY (device_id) REFERENCES devices (id) ON DELETE SET NULL;
