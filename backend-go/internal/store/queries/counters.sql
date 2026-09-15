-- name: AllocateSyncBlock :one
INSERT INTO sync_counters (scope_key, tenant_id, last_seq)
VALUES ($1, $2, $3)
ON CONFLICT (scope_key) DO UPDATE SET last_seq = sync_counters.last_seq + EXCLUDED.last_seq
RETURNING last_seq;

-- name: ReadSyncCounter :one
SELECT last_seq FROM sync_counters WHERE scope_key = $1;

-- name: ReadSyncCounters :many
SELECT scope_key, last_seq FROM sync_counters WHERE tenant_id = $1;

-- name: ReadSyncCountersByKeys :many
SELECT scope_key, last_seq FROM sync_counters WHERE scope_key = ANY(@scope_keys::text[]);
