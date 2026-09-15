-- +goose Up

-- Schema required by alexedwards/scs/postgresstore.
--
-- Deliberately in PostgreSQL rather than Redis: keeping Redis free of anything
-- authoritative is what makes "flush Redis" a safe thing to do on a live
-- system. Session write volume is trivial next to the device API.
--
-- No tenant_id and no RLS: a session is resolved from its token before any
-- tenant is known, and the tenant it belongs to is inside the session data.
CREATE TABLE sessions (
    token  text PRIMARY KEY,
    data   bytea NOT NULL,
    expiry timestamptz NOT NULL
);

CREATE INDEX sessions_expiry_idx ON sessions (expiry);

GRANT SELECT, INSERT, UPDATE, DELETE ON sessions TO justclick_app;

-- +goose Down

DROP TABLE sessions;
