-- +goose Up

-- Fase 3 paritas: what each installation said it can do.
--
-- A till reports the feature tokens its build honours (X-Device-Capabilities);
-- the Backoffice refuses to switch on a pricing model or assign a custom role
-- while an active device of the branch — or of the business, for roles —
-- cannot honour it. This is deliberately separate from tenant_feature_flags:
-- those are commercial module switches for the Backoffice, these are facts
-- about an app build.
--
-- Written only when the reported set changes, and never through updated_at:
-- updated_at feeds the device revision, and moving it would send every till to
-- /devices/me. The device_auth_version trigger fires only on the token
-- columns, so these writes do not disturb the auth cache generations either;
-- the cache entry of the reporting device is dropped explicitly instead.
ALTER TABLE devices
    ADD COLUMN capabilities             text[] NOT NULL DEFAULT '{}',
    ADD COLUMN capabilities_reported_at timestamptz,
    ADD CONSTRAINT devices_capabilities_size CHECK (cardinality(capabilities) <= 16);

-- +goose Down

ALTER TABLE devices
    DROP CONSTRAINT devices_capabilities_size,
    DROP COLUMN capabilities_reported_at,
    DROP COLUMN capabilities;
