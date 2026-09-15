-- +goose Up

-- Number every feed row still sitting at sync_seq = 0.
--
-- A till starts from cursor 0 and asks for `sync_seq > 0`, so a row at zero is
-- a row no tablet will ever receive. Every writer now allocates through
-- syncfeed.Write, but rows written before that existed — an Owner provisioned
-- before provisioning numbered its employee, an outlet typed in by hand during
-- development — are still at zero, and nothing would ever move them.
--
-- Numbers come from sync_counters exactly as AllocSeqBlock takes them: one
-- block per tenant and feed, reserved with the same INSERT … ON CONFLICT DO
-- UPDATE, so nothing already handed out is ever reused and a device already
-- past the old mark still receives these rows.
--
-- The table list is this migration's snapshot of the feed registry. It is not
-- expected to change: a feed added later is written through syncfeed.Write
-- from its first row.
-- +goose StatementBegin
DO $$
DECLARE
    feed    text;
    pending record;
    base    bigint;
BEGIN
    FOREACH feed IN ARRAY ARRAY[
        'employees', 'outlets', 'pos_registers', 'categories', 'products',
        'product_variants', 'modifier_groups', 'modifier_options',
        'product_modifier_groups', 'product_modifier_options', 'promos',
        'promo_outlets'
    ] LOOP
        FOR pending IN EXECUTE format(
            'SELECT tenant_id, count(*) AS n FROM %I WHERE sync_seq = 0 GROUP BY tenant_id', feed)
        LOOP
            INSERT INTO sync_counters (scope_key, tenant_id, last_seq)
            VALUES ('t:' || pending.tenant_id || '/e:' || feed, pending.tenant_id, pending.n)
            ON CONFLICT (scope_key) DO UPDATE SET last_seq = sync_counters.last_seq + pending.n
            RETURNING last_seq - pending.n INTO base;

            -- One number per row, in creation order. Rows may not share a
            -- number: a page boundary inside a tie strands the rest of it.
            EXECUTE format(
                'UPDATE %I t SET sync_seq = $1 + s.rn
                   FROM (SELECT ctid AS c, row_number() OVER (ORDER BY created_at, ctid) AS rn
                           FROM %I WHERE tenant_id = $2 AND sync_seq = 0) s
                  WHERE t.ctid = s.c', feed, feed)
            USING base, pending.tenant_id;
        END LOOP;
    END LOOP;
END
$$;
-- +goose StatementEnd

-- +goose Down

-- Nothing to undo. The numbers are valid cursors either way, and handing them
-- back would let a device that has already pulled these rows miss their next
-- change.
SELECT 1;
