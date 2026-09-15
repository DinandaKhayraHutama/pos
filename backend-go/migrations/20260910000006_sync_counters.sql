-- +goose Up

-- The sharded successor to Laravel's `tenant_sync_counters`.
--
-- That table held ONE row per merchant, and every catalogue or staff write in
-- the company had to take its lock. The design was correct — see
-- ../backend/app/Domain/Sync/SyncCursor.php for the lost-update proof it
-- exists to provide — but it serialised writes across all 5,000 outlets.
--
-- What must survive the reshaping, and why:
--
--   1. Writer A takes seq 10 and is slow to commit.
--   2. Writer B takes seq 11 and commits immediately.
--   3. A device pulls, sees only row B, and moves its cursor to 11.
--   4. Writer A finally commits. Row 10 is now visible, but the device is
--      already past it and will never ask for it again.
--
-- The product disappears from one till and nobody finds out until someone
-- tries to sell it. `INSERT … ON CONFLICT DO UPDATE … RETURNING` prevents that
-- precisely because PostgreSQL holds the counter row's exclusive lock until the
-- surrounding transaction ENDS — so B cannot take 11 until A has committed 10.
--
-- A plain SEQUENCE would NOT do: nextval() releases immediately and is exempt
-- from rollback, which is the whole failure above.
--
-- The shard axis is the one devices already page along — their cursor is per
-- entity — so catalogue writes no longer queue behind staff writes, and the
-- outlet-scoped form gives the high-volume device feeds a counter per branch.
--
--   company-shared:  't:{tenant}/e:{entity}'
--   outlet-scoped:   't:{tenant}/o:{outlet}/e:{entity}'
CREATE TABLE sync_counters (
    scope_key text PRIMARY KEY,
    -- Not derivable from scope_key in SQL without parsing a string, and RLS
    -- has to compare something. It is also what makes dropping a merchant
    -- take its counters with it.
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    last_seq  bigint NOT NULL
);

-- /sync/changes reads every counter a merchant owns in one statement whenever
-- Redis is cold.
CREATE INDEX sync_counters_tenant_idx ON sync_counters (tenant_id) INCLUDE (scope_key, last_seq);

GRANT SELECT, INSERT, UPDATE, DELETE ON sync_counters TO justclick_app;

ALTER TABLE sync_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_counters FORCE  ROW LEVEL SECURITY;

CREATE POLICY sync_counters_tenant_isolation ON sync_counters
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

-- +goose Down

DROP TABLE sync_counters;
