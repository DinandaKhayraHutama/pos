-- +goose Up

-- Until now the API connected as the database owner and merely SET LOCAL ROLE
-- into justclick_app for tenant-scoped work. That made RLS a matter of
-- discipline: any query that forgot to go through that helper ran as a
-- superuser, and PostgreSQL exempts superusers from every policy silently.
--
-- From here the credential itself is the boundary. justclick_app becomes a
-- LOGIN role the API connects AS, so a forgotten tenant context is refused by
-- the database rather than by convention.
--
-- LOGIN is granted here; the password is set out of band by
-- `justclick roles set-password`, because a password in a migration is a
-- password in version control.
ALTER ROLE justclick_app LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;

-- The escape hatch gets its own credential rather than borrowing a stronger
-- one. Device authentication must resolve a bearer token before any tenant is
-- known, so something has to read across merchants — but it should be a
-- credential that shows up by name in an audit, not the same one every
-- ordinary query already uses.
-- +goose StatementBegin
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'justclick_unscoped') THEN
        CREATE ROLE justclick_unscoped;
    END IF;
END
$$;
-- +goose StatementEnd

ALTER ROLE justclick_unscoped LOGIN NOSUPERUSER BYPASSRLS NOCREATEDB NOCREATEROLE;

-- Membership, so it inherits every table grant justclick_app already has and
-- every one a future migration adds. The only difference between the two
-- credentials is BYPASSRLS.
GRANT justclick_app TO justclick_unscoped;

-- +goose Down

REVOKE justclick_app FROM justclick_unscoped;
ALTER ROLE justclick_unscoped NOLOGIN NOBYPASSRLS;
ALTER ROLE justclick_app NOLOGIN;
