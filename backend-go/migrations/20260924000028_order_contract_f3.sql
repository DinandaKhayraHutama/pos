-- +goose Up

-- Fase 3 paritas, contract release (Device API 2.8.0).
--
-- Two new money columns and a flag. Unlike F2's customer_name, which stayed in
-- the payload, these are promoted to columns because every net-sales and
-- every anomaly expression needs them: net sales is now
-- subtotal - discount - tax_included, and the header equation gains
-- rounding_amount.
--
-- All three carry constant defaults, so on the partitioned table this is a
-- catalogue change, not a rewrite. The default 0 is TRUE for every order that
-- already exists — no pre-F3 till could include tax in a price or round a
-- total — so nothing is backfilled and no history is rewritten.
--
-- No CHECK is added. orders' existing CHECK names six columns
-- (20260913000012_financial_ingest.sql), and adding a constraint here would
-- scan every partition. rounding_amount is legitimately negative; the ingest
-- validation (internal/domain/ingest/validate.go) is the guard for both.
ALTER TABLE orders
    ADD COLUMN tax_included     bigint  NOT NULL DEFAULT 0,
    ADD COLUMN rounding_amount  bigint  NOT NULL DEFAULT 0,
    -- The server recomputed the till's pricing snapshot and got a different
    -- figure. Written on insert only; reported as an anomaly, never repaired,
    -- and never a reason to refuse a sale that already happened.
    ADD COLUMN pricing_mismatch boolean NOT NULL DEFAULT false;

-- Numbers a block of sync sequence numbers exactly as syncfeed.AllocSeqBlock
-- does: one INSERT ... ON CONFLICT DO UPDATE, whose row lock is held until the
-- surrounding transaction ends. For triggers that seed feed rows (the system
-- roles, sales types and payment methods of a new merchant), which cannot call
-- Go. Returns the first number of the block.
-- +goose StatementBegin
CREATE FUNCTION app.alloc_sync_block(p_tenant uuid, p_entity text, p_n bigint) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    last bigint;
BEGIN
    INSERT INTO sync_counters (scope_key, tenant_id, last_seq)
    VALUES ('t:' || p_tenant || '/e:' || p_entity, p_tenant, p_n)
    ON CONFLICT (scope_key) DO UPDATE SET last_seq = sync_counters.last_seq + p_n
    RETURNING last_seq INTO last;
    RETURN last - p_n + 1;
END
$$;
-- +goose StatementEnd

-- +goose Down

DROP FUNCTION app.alloc_sync_block(uuid, text, bigint);

ALTER TABLE orders
    DROP COLUMN pricing_mismatch,
    DROP COLUMN rounding_amount,
    DROP COLUMN tax_included;
