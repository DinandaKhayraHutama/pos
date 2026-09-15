-- +goose Up

-- Stock: an append-only ledger of movements, and a per-outlet count derived
-- from it.
--
-- The ledger is the truth. A movement is a signed delta, and deltas commute: two
-- tills that each sell the last unit while offline push -1 and -1, and the
-- outlet lands on -1 below where it started. There is no conflict to resolve,
-- which is the whole reason the ledger — not a balance anyone may overwrite — is
-- what devices and the Backoffice write.
--
-- outlet_stock is a projection of that ledger, kept in the SAME transaction as
-- the movement that changes it. Nothing ever writes it directly and no till ever
-- pushes it: tills pull it as the authoritative snapshot and add the movements
-- they have not had acknowledged yet. A nightly job re-derives it from the
-- ledger and repairs any row that disagrees.
--
-- Negative stock is allowed. Refusing to record a sale that demonstrably
-- happened is the worse failure; the Backoffice flags it instead.
--
-- Both feeds are OUTLET-scoped: numbered on 't:{tenant}/o:{outlet}/e:{entity}'
-- counters, so contention is the two to four tills inside one branch, exactly
-- where a total order is wanted, and never the whole chain.

CREATE TABLE outlet_stock (
    tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id   uuid NOT NULL,
    product_id  uuid NOT NULL,
    qty_on_hand bigint NOT NULL,
    -- 0 only inside the transaction that creates the row: the same statement
    -- sequence numbers it before commit, so no committed row stays at 0.
    sync_seq    bigint NOT NULL DEFAULT 0,
    -- Present because every feed row carries a tombstone column. A projection
    -- row is never tombstoned today.
    deleted_at  timestamptz,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, outlet_id, product_id),
    CONSTRAINT outlet_stock_outlet_context_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id),
    CONSTRAINT outlet_stock_product_context_fk
        FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id)
);

CREATE TABLE stock_movements (
    -- Chosen by whoever wrote the movement. A till names its own UUID offline,
    -- and that UUID is the idempotency key when it is pushed.
    id                uuid PRIMARY KEY,
    tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id         uuid NOT NULL,
    product_id        uuid NOT NULL,
    reason            text NOT NULL CHECK (reason IN (
        'opening', 'received', 'sale', 'voidReturn', 'waste', 'correction',
        'count', 'transferIn', 'transferOut')),
    -- What the movement did to the count. For a count (stock opname) the server
    -- computes it at ingest as counted_qty minus its own current quantity.
    delta_qty         bigint NOT NULL,
    counted_qty       bigint,
    -- The till's snapshot sequence when it counted. Recorded for audit; the
    -- server's own count is what the delta is taken against.
    basis_seq         bigint,
    balance_after     bigint NOT NULL,
    occurred_at_ms    bigint NOT NULL CHECK (occurred_at_ms >= 0),
    source            text NOT NULL CHECK (source IN ('device', 'backoffice')),
    device_id         uuid,
    created_by        uuid,
    employee_name     text NOT NULL DEFAULT '',
    product_name      text NOT NULL,
    note              text,
    ref_type          text,
    ref_id            uuid,
    -- The pushed row exactly as accepted, so an exact retry is recognised and
    -- a different row under the same id is refused.
    payload           jsonb,
    -- outlet_stock.sync_seq once this movement was applied. A till adds a
    -- movement of its own to the snapshot only while its snapshot is older.
    applied_stock_seq bigint NOT NULL,
    sync_seq          bigint NOT NULL,
    deleted_at        timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT stock_movements_outlet_context_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id),
    CONSTRAINT stock_movements_product_context_fk
        FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id),
    CONSTRAINT stock_movements_device_context_fk
        FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id),
    CONSTRAINT stock_movements_count_has_quantity CHECK ((reason = 'count') = (counted_qty IS NOT NULL)),
    CONSTRAINT stock_movements_device_source CHECK ((source = 'device') = (device_id IS NOT NULL)),
    CONSTRAINT stock_movements_device_payload CHECK ((source = 'device') = (payload IS NOT NULL)),
    CONSTRAINT stock_movements_payload_object CHECK (payload IS NULL OR jsonb_typeof(payload) = 'object'),
    -- Bounded because every published column travels inside the covering index
    -- below, and a btree tuple may not exceed ~2704 bytes. Characters are not
    -- bytes: 440 characters of 4-byte UTF-8 still fits.
    CONSTRAINT stock_movements_product_name_length  CHECK (length(product_name) <= 120),
    CONSTRAINT stock_movements_employee_name_length CHECK (length(employee_name) <= 120),
    CONSTRAINT stock_movements_note_length          CHECK (note IS NULL OR length(note) <= 200),
    CONSTRAINT stock_movements_ref_type_length      CHECK (ref_type IS NULL OR length(ref_type) <= 32)
);

-- The feed indexes lead with the outlet: a till pulls its own branch only.
-- INCLUDE must stay in step with the published columns in syncfeed/registry.go,
-- or a pull stops being an Index Only Scan.
CREATE INDEX outlet_stock_sync_feed_idx ON outlet_stock (tenant_id, outlet_id, sync_seq)
    INCLUDE (product_id, qty_on_hand, deleted_at);

CREATE INDEX stock_movements_sync_feed_idx ON stock_movements (tenant_id, outlet_id, sync_seq)
    INCLUDE (id, product_id, product_name, reason, delta_qty, counted_qty, balance_after,
             occurred_at_ms, employee_name, note, source, applied_stock_seq, deleted_at);

-- One product's history at one branch, newest first, and the reconcile sum.
CREATE INDEX stock_movements_ledger_idx ON stock_movements (tenant_id, outlet_id, product_id, sync_seq)
    INCLUDE (delta_qty);

GRANT SELECT, INSERT, UPDATE, DELETE ON outlet_stock, stock_movements TO justclick_app;

-- +goose StatementBegin
DO $$
DECLARE tbl text;
BEGIN
    FOREACH tbl IN ARRAY ARRAY['outlet_stock', 'stock_movements'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', tbl);
        EXECUTE format('CREATE POLICY tenant_isolation ON %I USING (tenant_id = app.current_tenant_id()) WITH CHECK (tenant_id = app.current_tenant_id())', tbl);
    END LOOP;
END $$;
-- +goose StatementEnd

-- +goose Down
DROP TABLE stock_movements;
DROP TABLE outlet_stock;
