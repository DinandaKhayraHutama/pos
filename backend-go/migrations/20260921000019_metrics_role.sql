-- +goose Up

-- A fourth credential, and like the other three its privileges ARE its
-- purpose: postgres_exporter reads pg_stat_* and nothing else.
--
-- The obvious shortcut is to point the exporter at the owner, and it is the
-- wrong one twice over: it is a superuser connection held open for the
-- convenience of a graph, and it would read every merchant's rows while doing
-- it. pg_monitor is a built-in role that grants exactly the statistics views
-- and none of the data.
--
-- LOGIN is granted here; the password is set out of band by
-- `justclick roles set-password`, from METRICS_DB_PASSWORD — a password in a
-- migration is a password in version control.
-- +goose StatementBegin
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'justclick_metrics') THEN
        CREATE ROLE justclick_metrics;
    END IF;
END
$$;
-- +goose StatementEnd

ALTER ROLE justclick_metrics LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;

GRANT pg_monitor TO justclick_metrics;

-- The database name is configurable (POSTGRES_DB), so it is read rather than
-- written down.
-- +goose StatementBegin
DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO justclick_metrics', current_database());
END
$$;
-- +goose StatementEnd

-- Deliberately NOT granted: membership of justclick_app, and therefore no
-- table grants at all. Row-level security would hide merchant rows from it
-- anyway (it holds no BYPASSRLS), but the grant is the boundary, and this role
-- has no business selecting from a table in the first place.

-- +goose Down

-- +goose StatementBegin
DO $$
BEGIN
    EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM justclick_metrics', current_database());
END
$$;
-- +goose StatementEnd
REVOKE pg_monitor FROM justclick_metrics;
ALTER ROLE justclick_metrics NOLOGIN;
