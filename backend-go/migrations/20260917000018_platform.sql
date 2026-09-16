-- +goose Up

-- Platform administration (Fase 8): the people who run JustClick itself, the
-- limits and features each merchant is sold, support impersonation, and the
-- audit trail every one of those actions leaves.
--
-- The security boundary here is the GRANT, not the application code.
-- Migration 001 set ALTER DEFAULT PRIVILEGES so every new table is granted to
-- justclick_app, the credential every merchant request runs as. Platform tables
-- must NOT be reachable from it: a bug in a Backoffice handler must not be able
-- to read a super admin's password hash or TOTP secret, or raise its own
-- merchant's limits. So each table below is revoked from justclick_app
-- explicitly and granted to justclick_unscoped, the escape hatch the platform
-- panel runs as.

ALTER TABLE tenants
    ADD CONSTRAINT tenants_status_known CHECK (status IN ('active', 'suspended')),
    ADD COLUMN suspended_at timestamptz,
    ADD COLUMN suspended_reason text
        CONSTRAINT tenants_suspended_reason_length
        CHECK (suspended_reason IS NULL OR length(suspended_reason) <= 500);

-- Platform staff. Never belongs to a merchant, so no tenant_id and no RLS.
CREATE TABLE super_admins (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name            text NOT NULL CONSTRAINT super_admins_name_length CHECK (length(name) BETWEEN 1 AND 120),
    email           text NOT NULL CONSTRAINT super_admins_email_length CHECK (length(email) BETWEEN 3 AND 254),
    -- bcrypt. Unlike an employee PIN this is never verified on a tablet, but
    -- the cost stays at the shared constant so there is one hashing rule.
    password        text NOT NULL,
    -- A TOTP secret must be readable to verify a code, so it cannot be hashed.
    -- It is not encrypted with APP_KEY either: nothing durable may be derived
    -- from that key. What protects it is that only justclick_unscoped can read
    -- this table, and that the password is still required alongside it.
    totp_secret     text,
    totp_enabled_at timestamptz,
    -- The last 30-second step a code was accepted for. A code is accepted only
    -- for a strictly later step, so an observed code cannot be replayed.
    totp_last_step  bigint NOT NULL DEFAULT 0,
    active          boolean NOT NULL DEFAULT true,
    last_login_at   timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT super_admins_enabled_totp_has_secret CHECK (totp_enabled_at IS NULL OR totp_secret IS NOT NULL)
);

CREATE UNIQUE INDEX super_admins_email_key ON super_admins (lower(email));

-- High-entropy one-time codes, so SHA-256 is enough — the same rule as device
-- tokens. used_at is claimed with a compare-and-swap, never read then written.
CREATE TABLE super_admin_recovery_codes (
    super_admin_id uuid NOT NULL REFERENCES super_admins (id) ON DELETE CASCADE,
    code_sha256    bytea NOT NULL,
    used_at        timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (super_admin_id, code_sha256)
);

-- alexedwards/scs/postgresstore schema, in its own table: a platform session
-- token is a credential for every merchant at once, and the Backoffice's
-- `sessions` table is readable by justclick_app.
CREATE TABLE platform_sessions (
    token  text PRIMARY KEY,
    data   bytea NOT NULL,
    expiry timestamptz NOT NULL
);

CREATE INDEX platform_sessions_expiry_idx ON platform_sessions (expiry);

-- Append-only. justclick_unscoped may insert and read, never update or delete;
-- a trail its own author can edit is not an audit trail.
--
-- tenant_id carries no foreign key on purpose: deleting a merchant must not
-- delete the record of what was done to it.
CREATE TABLE platform_audit_log (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- clock_timestamp, not now(): several rows written in one transaction must
    -- still sort in the order they happened.
    at               timestamptz NOT NULL DEFAULT clock_timestamp(),
    super_admin_id   uuid REFERENCES super_admins (id),
    action           text NOT NULL CONSTRAINT platform_audit_log_action_shape CHECK (action ~ '^[a-z_]+(\.[a-z_]+)+$'),
    tenant_id        uuid,
    impersonation_id uuid,
    ip               text CONSTRAINT platform_audit_log_ip_length CHECK (ip IS NULL OR length(ip) <= 64),
    detail           jsonb NOT NULL DEFAULT '{}' CONSTRAINT platform_audit_log_detail_object CHECK (jsonb_typeof(detail) = 'object')
);

CREATE INDEX platform_audit_log_at_idx ON platform_audit_log (at DESC);
CREATE INDEX platform_audit_log_tenant_idx ON platform_audit_log (tenant_id, at DESC) WHERE tenant_id IS NOT NULL;
CREATE INDEX platform_audit_log_impersonation_idx ON platform_audit_log (impersonation_id, at) WHERE impersonation_id IS NOT NULL;

-- What a merchant is sold. NULL, and a missing row, both mean unlimited, so
-- every merchant that existed before this migration keeps working unchanged.
CREATE TABLE tenant_limits (
    tenant_id          uuid PRIMARY KEY REFERENCES tenants (id) ON DELETE CASCADE,
    max_outlets        integer CONSTRAINT tenant_limits_outlets_nonnegative CHECK (max_outlets >= 0),
    max_registers      integer CONSTRAINT tenant_limits_registers_nonnegative CHECK (max_registers >= 0),
    max_active_devices integer CONSTRAINT tenant_limits_devices_nonnegative CHECK (max_active_devices >= 0),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         uuid REFERENCES super_admins (id)
);

-- A missing row means the default in code (internal/domain/entitlements), so a
-- flag added later reaches every merchant without a backfill.
CREATE TABLE tenant_feature_flags (
    tenant_id  uuid NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
    flag       text NOT NULL CONSTRAINT tenant_feature_flags_known CHECK (flag IN ('stock', 'tables', 'promos', 'report_exports')),
    enabled    boolean NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid REFERENCES super_admins (id),
    PRIMARY KEY (tenant_id, flag)
);

-- A support engineer signed in to a merchant's Backoffice as one of its owners.
-- The handoff token moves the grant from the platform panel to the Backoffice
-- cookie: 32 random bytes, stored hashed, valid for a minute, single use.
CREATE TABLE impersonation_sessions (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          uuid NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
    employee_id        uuid NOT NULL,
    super_admin_id     uuid NOT NULL REFERENCES super_admins (id),
    reason             text NOT NULL CONSTRAINT impersonation_sessions_reason_length CHECK (length(reason) BETWEEN 10 AND 500),
    handoff_sha256     bytea UNIQUE,
    handoff_expires_at timestamptz NOT NULL,
    started_at         timestamptz,
    expires_at         timestamptz NOT NULL,
    ended_at           timestamptz,
    ended_by           text CONSTRAINT impersonation_sessions_ended_by_known
                           CHECK (ended_by IN ('admin', 'expired', 'suspended', 'logout', 'replaced')),
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT impersonation_sessions_end_shape CHECK ((ended_at IS NULL) = (ended_by IS NULL)),
    CONSTRAINT impersonation_sessions_employee_fk
        FOREIGN KEY (tenant_id, employee_id) REFERENCES employees (tenant_id, id) ON DELETE CASCADE
);

CREATE INDEX impersonation_sessions_open_admin_idx ON impersonation_sessions (super_admin_id) WHERE ended_at IS NULL;
CREATE INDEX impersonation_sessions_open_tenant_idx ON impersonation_sessions (tenant_id) WHERE ended_at IS NULL;

-- The first sign-in link for an owner created from the platform panel, and its
-- reissue. The token is resolved before any tenant is known, so the table is
-- read through justclick_unscoped only.
CREATE TABLE password_setup_tokens (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    uuid NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
    employee_id  uuid NOT NULL,
    token_sha256 bytea NOT NULL UNIQUE,
    expires_at   timestamptz NOT NULL,
    used_at      timestamptz,
    cancelled_at timestamptz,
    created_by   uuid REFERENCES super_admins (id),
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT password_setup_tokens_employee_fk
        FOREIGN KEY (tenant_id, employee_id) REFERENCES employees (tenant_id, id) ON DELETE CASCADE
);

CREATE INDEX password_setup_tokens_pending_idx ON password_setup_tokens (tenant_id, employee_id)
    WHERE used_at IS NULL AND cancelled_at IS NULL;

-- Unreachable from the merchant credential altogether.
REVOKE ALL ON super_admins, super_admin_recovery_codes, platform_sessions,
    platform_audit_log, password_setup_tokens FROM justclick_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON super_admins, super_admin_recovery_codes,
    platform_sessions, password_setup_tokens TO justclick_unscoped;
GRANT SELECT, INSERT ON platform_audit_log TO justclick_unscoped;

-- Readable by the merchant they describe — limits are enforced inside the
-- merchant's own transaction, and the Backoffice banner reads its impersonation —
-- but written only by the platform.
REVOKE INSERT, UPDATE, DELETE ON tenant_limits, tenant_feature_flags, impersonation_sessions FROM justclick_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON tenant_limits, tenant_feature_flags, impersonation_sessions TO justclick_unscoped;

-- +goose StatementBegin
DO $$
DECLARE tbl text;
BEGIN
    FOREACH tbl IN ARRAY ARRAY['tenant_limits', 'tenant_feature_flags', 'impersonation_sessions'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', tbl);
        EXECUTE format('CREATE POLICY tenant_read ON %I FOR SELECT USING (tenant_id = app.current_tenant_id())', tbl);
    END LOOP;
END $$;
-- +goose StatementEnd

-- The ops page compares applied migrations with the ones the binary embeds.
GRANT SELECT ON goose_db_version TO justclick_unscoped;

-- +goose Down
REVOKE SELECT ON goose_db_version FROM justclick_unscoped;
DROP TABLE password_setup_tokens;
DROP TABLE impersonation_sessions;
DROP TABLE tenant_feature_flags;
DROP TABLE tenant_limits;
DROP TABLE platform_audit_log;
DROP TABLE platform_sessions;
DROP TABLE super_admin_recovery_codes;
DROP TABLE super_admins;
ALTER TABLE tenants
    DROP COLUMN suspended_reason,
    DROP COLUMN suspended_at,
    DROP CONSTRAINT tenants_status_known;
