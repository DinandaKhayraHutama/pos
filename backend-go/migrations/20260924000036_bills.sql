-- +goose Up

-- Fase 4 paritas: saved bills and the restaurant order cycle.
--
-- A bill is NOT a receipt. `orders` stays the final, immutable receipt; a bill
-- is the mutable thing a table runs up before it pays, owned by exactly one
-- till at a time. Saving a bill takes no money and moves no stock. Sending
-- lines to the kitchen (a dispatch) is what consumes stock, once; settling the
-- bill writes the receipt and consumes nothing a second time.
--
-- Additive: no existing table changes meaning. `orders` gains nothing — a
-- receipt names its bill in its payload, and `bills.closed_order_id` is the
-- link the other way.

-- One seating at one table: opened online so two tills cannot both seat it,
-- closed online once no bill on it is still open. Paying a bill does not
-- close it — the guests may still be sitting there.
CREATE TABLE table_sessions (
    id                    uuid PRIMARY KEY,
    tenant_id             uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id             uuid NOT NULL,
    table_id              uuid NOT NULL,
    table_name            text NOT NULL,
    guest_count           integer CHECK (guest_count IS NULL OR guest_count BETWEEN 1 AND 1000),
    opened_at_ms          bigint NOT NULL CHECK (opened_at_ms >= 0),
    opened_by_device_id   uuid NOT NULL,
    opened_by_employee_id uuid,
    opened_by_name        text NOT NULL,
    closed_at_ms          bigint,
    closed_by_device_id   uuid,
    closed_by_name        text,
    created_at            timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT table_sessions_table_fk
        FOREIGN KEY (tenant_id, outlet_id, table_id) REFERENCES tables (tenant_id, outlet_id, id),
    CONSTRAINT table_sessions_opened_by_fk
        FOREIGN KEY (tenant_id, opened_by_device_id) REFERENCES devices (tenant_id, id),
    CONSTRAINT table_sessions_closed_by_fk
        FOREIGN KEY (tenant_id, closed_by_device_id) REFERENCES devices (tenant_id, id),
    CONSTRAINT table_sessions_names CHECK (length(table_name) <= 255 AND length(opened_by_name) <= 255
        AND (closed_by_name IS NULL OR length(closed_by_name) <= 255)),
    CONSTRAINT table_sessions_closed CHECK (closed_at_ms IS NULL OR closed_at_ms >= opened_at_ms)
);
-- One seating per table at a time: the database, not a check-then-insert,
-- decides which of two tills racing for the same table wins.
CREATE UNIQUE INDEX table_sessions_one_open ON table_sessions (tenant_id, table_id)
    WHERE closed_at_ms IS NULL;
CREATE INDEX table_sessions_outlet_open ON table_sessions (tenant_id, outlet_id)
    WHERE closed_at_ms IS NULL;

CREATE TABLE bills (
    id                    uuid PRIMARY KEY,
    tenant_id             uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id             uuid NOT NULL,
    -- The till that opened it. Never changes: a bill handed to another till
    -- keeps its origin, only its owner moves.
    pos_register_id       uuid NOT NULL,
    created_device_id     uuid NOT NULL,
    -- The one till that may edit it. NULL while parked on the server, waiting
    -- for any till of the outlet to claim it.
    owner_device_id       uuid,
    owner_session_id      uuid,
    -- Raised by every park, claim and forced release. A snapshot or dispatch
    -- carrying an older generation comes from a till that no longer owns the
    -- bill and is refused, whatever its revision.
    owner_generation      bigint NOT NULL CHECK (owner_generation > 0),
    -- The bill's own edit counter, as the owning till numbered it.
    revision              bigint NOT NULL CHECK (revision > 0),
    number                text NOT NULL,
    status                text NOT NULL CHECK (status IN ('open', 'closed', 'cancelled')),
    table_session_id      uuid,
    table_name            text,
    customer_name         text,
    -- sum(unit_price * quantity) of the lines: the list shows it, reports never
    -- read it. A bill is not revenue until its receipt exists.
    subtotal              bigint NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    line_count            integer NOT NULL DEFAULT 0 CHECK (line_count >= 0),
    opened_at_ms          bigint NOT NULL CHECK (opened_at_ms >= 0),
    closed_order_id       uuid,
    closed_business_date  date,
    closed_at             timestamptz,
    cancelled_at          timestamptz,
    parked_at             timestamptz,
    -- The last accepted snapshot, exactly as the till sent it, so an exact
    -- retry is recognised and a changed one is not mistaken for it.
    payload               jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT bills_register_fk
        FOREIGN KEY (tenant_id, outlet_id, pos_register_id) REFERENCES pos_registers (tenant_id, outlet_id, id),
    CONSTRAINT bills_created_device_fk
        FOREIGN KEY (tenant_id, created_device_id) REFERENCES devices (tenant_id, id),
    CONSTRAINT bills_owner_device_fk
        FOREIGN KEY (tenant_id, owner_device_id) REFERENCES devices (tenant_id, id),
    CONSTRAINT bills_table_session_fk
        FOREIGN KEY (tenant_id, table_session_id) REFERENCES table_sessions (tenant_id, id),
    CONSTRAINT bills_owner_pair CHECK ((owner_device_id IS NULL) = (owner_session_id IS NULL)),
    CONSTRAINT bills_closed_has_order CHECK ((status = 'closed') = (closed_order_id IS NOT NULL)),
    CONSTRAINT bills_names CHECK (length(number) BETWEEN 1 AND 64
        AND (table_name IS NULL OR length(table_name) <= 255)
        AND (customer_name IS NULL OR length(customer_name) <= 255))
);
CREATE INDEX bills_open_outlet ON bills (tenant_id, outlet_id) WHERE status = 'open';
CREATE INDEX bills_open_owner_session ON bills (tenant_id, owner_session_id) WHERE status = 'open';
CREATE INDEX bills_open_owner_device ON bills (tenant_id, owner_device_id) WHERE status = 'open';
CREATE INDEX bills_table_session ON bills (tenant_id, table_session_id) WHERE table_session_id IS NOT NULL;
CREATE INDEX bills_recent ON bills (tenant_id, outlet_id, updated_at DESC);

-- A batch of lines sent to the kitchen. The lines and the stock it consumed
-- never change once accepted; only its kitchen status moves forward.
CREATE TABLE kitchen_dispatches (
    id                    uuid PRIMARY KEY,
    tenant_id             uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id             uuid NOT NULL,
    bill_id               uuid NOT NULL,
    device_id             uuid NOT NULL,
    pos_session_id        uuid NOT NULL,
    status                text NOT NULL CHECK (status IN ('queued', 'preparing', 'ready', 'served', 'cancelled')),
    revision              bigint NOT NULL CHECK (revision > 0),
    occurred_at_ms        bigint NOT NULL CHECK (occurred_at_ms >= 0),
    employee_name         text NOT NULL,
    status_changed_at_ms  bigint NOT NULL CHECK (status_changed_at_ms >= 0),
    -- The immutable part as first accepted: lines and stock effects.
    payload               jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT kitchen_dispatches_bill_fk
        FOREIGN KEY (tenant_id, bill_id) REFERENCES bills (tenant_id, id),
    CONSTRAINT kitchen_dispatches_device_fk
        FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id),
    CONSTRAINT kitchen_dispatches_names CHECK (length(employee_name) <= 255)
);
CREATE INDEX kitchen_dispatches_bill ON kitchen_dispatches (tenant_id, bill_id);
CREATE INDEX kitchen_dispatches_active ON kitchen_dispatches (tenant_id, outlet_id)
    WHERE status IN ('queued', 'preparing', 'ready');

CREATE TABLE bill_lines (
    id           uuid PRIMARY KEY,
    tenant_id    uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    bill_id      uuid NOT NULL,
    seq          integer NOT NULL CHECK (seq >= 0),
    -- A snapshot, not a reference: a product deleted later must not take a
    -- line of an open bill, or a receipt's history, with it.
    product_id   uuid,
    product_name text NOT NULL,
    quantity     bigint NOT NULL CHECK (quantity > 0),
    unit_price   bigint NOT NULL CHECK (unit_price >= 0),
    custom       boolean NOT NULL DEFAULT false,
    -- Set once, by the dispatch that sent the line to the kitchen. A
    -- dispatched line may no longer be edited or removed.
    dispatch_id  uuid,
    payload      jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    UNIQUE (tenant_id, id),
    CONSTRAINT bill_lines_bill_fk
        FOREIGN KEY (tenant_id, bill_id) REFERENCES bills (tenant_id, id),
    CONSTRAINT bill_lines_dispatch_fk
        FOREIGN KEY (tenant_id, dispatch_id) REFERENCES kitchen_dispatches (tenant_id, id),
    CONSTRAINT bill_lines_custom CHECK (NOT custom OR product_id IS NULL),
    CONSTRAINT bill_lines_names CHECK (length(product_name) BETWEEN 1 AND 255)
);
CREATE INDEX bill_lines_bill ON bill_lines (tenant_id, bill_id, seq);

-- Every online coordination of a bill or a table: park, claim, a manager's
-- forced release, seating and clearing. Append-only. operation_id is the
-- idempotency key a till stores before it asks, so a lost reply costs a
-- retry, never a second claim.
CREATE TABLE bill_events (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id          uuid NOT NULL,
    bill_id            uuid,
    table_session_id   uuid,
    event_type         text NOT NULL CHECK (event_type IN (
        'park', 'claim', 'force_park', 'table_open', 'table_close')),
    operation_id       uuid,
    device_id          uuid,
    actor_employee_id  uuid,
    actor_name         text NOT NULL DEFAULT '',
    from_generation    bigint,
    to_generation      bigint,
    detail             jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(detail) = 'object'),
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT bill_events_bill_fk
        FOREIGN KEY (tenant_id, bill_id) REFERENCES bills (tenant_id, id),
    CONSTRAINT bill_events_table_session_fk
        FOREIGN KEY (tenant_id, table_session_id) REFERENCES table_sessions (tenant_id, id),
    CONSTRAINT bill_events_device_fk
        FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id),
    CONSTRAINT bill_events_subject CHECK (bill_id IS NOT NULL OR table_session_id IS NOT NULL)
);
CREATE UNIQUE INDEX bill_events_operation ON bill_events (tenant_id, operation_id)
    WHERE operation_id IS NOT NULL;
CREATE INDEX bill_events_bill ON bill_events (tenant_id, bill_id, created_at);

-- The movements a receipt, a dispatch or a cancellation committed are found by
-- their source. ingestSale already counted a receipt's effects this way with
-- no index behind it — a scan of the whole ledger on every receipt push.
CREATE INDEX stock_movements_ref_idx ON stock_movements (tenant_id, ref_type, ref_id)
    WHERE ref_id IS NOT NULL;

-- Saved bills are switched on per branch, and only once every active till of
-- that branch reports it understands them (capability bills-v1): an older
-- till would read a table held by a bill as free and sell past it.
ALTER TABLE outlet_settings
    ADD COLUMN bill_model text NOT NULL DEFAULT 'legacy' CHECK (bill_model IN ('legacy', 'v1'));

-- The covering index must list every published column, or a pull stops being
-- an Index Only Scan.
DROP INDEX outlet_settings_sync_feed_idx;
CREATE INDEX outlet_settings_sync_feed_idx ON outlet_settings (tenant_id, outlet_id, sync_seq)
    INCLUDE (tax_rate_bp, tax_mode, service_enabled, service_rate_bp, service_taxable,
             rounding_unit, rounding_mode, receipt_header, receipt_footer, show_address,
             show_phone, track_server, default_sales_type_id, sales_type_ids, payment_group_id,
             pricing_model, bill_model, deleted_at);

GRANT SELECT, INSERT, UPDATE ON table_sessions, bills, kitchen_dispatches TO justclick_app;
-- Lines not yet sent to the kitchen are replaced wholesale by the next
-- snapshot; a dispatched line is protected by the domain, not by the grant.
GRANT SELECT, INSERT, UPDATE, DELETE ON bill_lines TO justclick_app;
GRANT SELECT, INSERT ON bill_events TO justclick_app;

-- +goose StatementBegin
DO $$
DECLARE tbl text;
BEGIN
    FOREACH tbl IN ARRAY ARRAY['table_sessions', 'bills', 'kitchen_dispatches', 'bill_lines', 'bill_events'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', tbl);
        EXECUTE format('CREATE POLICY tenant_isolation ON %I USING (tenant_id = app.current_tenant_id()) WITH CHECK (tenant_id = app.current_tenant_id())', tbl);
    END LOOP;
END $$;
-- +goose StatementEnd

-- +goose Down

DROP INDEX outlet_settings_sync_feed_idx;
CREATE INDEX outlet_settings_sync_feed_idx ON outlet_settings (tenant_id, outlet_id, sync_seq)
    INCLUDE (tax_rate_bp, tax_mode, service_enabled, service_rate_bp, service_taxable,
             rounding_unit, rounding_mode, receipt_header, receipt_footer, show_address,
             show_phone, track_server, default_sales_type_id, sales_type_ids, payment_group_id,
             pricing_model, deleted_at);
ALTER TABLE outlet_settings DROP COLUMN bill_model;
DROP INDEX stock_movements_ref_idx;
DROP TABLE bill_events;
DROP TABLE bill_lines;
DROP TABLE kitchen_dispatches;
DROP TABLE bills;
DROP TABLE table_sessions;
