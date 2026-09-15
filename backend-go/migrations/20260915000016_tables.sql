-- +goose Up

-- Tables: a branch's floor plan, and what is happening at each table.
--
-- Split in two on purpose. A table's DEFINITION (name, area, seats, place on
-- the floor plan) belongs to the Backoffice and is pulled by every till in the
-- branch, like the menu. Its live STATUS is written by tills: every change is
-- an event in table_status_events (append-only, kept for audit), and
-- table_status is the projection every till in the branch pulls back.
--
-- A status is a value, not a delta, so two tills can genuinely disagree about
-- one table. The rule is last-writer-wins by (occurred_at_ms, event id), but
-- only between writers that could not see each other:
--
--   * an event made against the table's current status sequence applies;
--   * an event continuing the same device's own latest write applies;
--   * an event that raced another till's write is applied or superseded by
--     time, and marks the table CONTESTED, so tills show staff that two people
--     acted on it instead of silently picking one. The next uncontested write
--     clears the mark.
--
-- Both pulled feeds are OUTLET-scoped, like the stock ledger: a till receives
-- its own branch's floor plan and nothing else.

CREATE TABLE tables (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    -- For life: moving a table to another branch would re-file its status
    -- history and every receipt naming it under a shop it never stood in.
    outlet_id   uuid NOT NULL,
    name        text NOT NULL,
    -- Free text ("Lantai 1", "Teras"), the till's `floor`.
    area        text NOT NULL DEFAULT '',
    capacity    integer NOT NULL DEFAULT 2,
    -- Place on a drawn floor plan, in abstract grid units. Optional: a list
    -- grouped by area is a complete floor plan for most shops.
    pos_x       integer,
    pos_y       integer,
    sort_order  integer NOT NULL DEFAULT 0,
    active      boolean NOT NULL DEFAULT true,
    sync_seq    bigint NOT NULL DEFAULT 0,
    deleted_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    -- Lets status and events name the table AND its branch in one key, so a
    -- status can never sit at a branch its table is not in.
    CONSTRAINT tables_outlet_identity UNIQUE (tenant_id, outlet_id, id),
    CONSTRAINT tables_outlet_context_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id),
    -- Bounded because every published column travels inside the covering
    -- index below.
    CONSTRAINT tables_name_length CHECK (length(name) BETWEEN 1 AND 60),
    CONSTRAINT tables_area_length CHECK (length(area) <= 60),
    CONSTRAINT tables_capacity_range CHECK (capacity BETWEEN 1 AND 100),
    CONSTRAINT tables_position_range CHECK (
        (pos_x IS NULL OR pos_x BETWEEN 0 AND 10000)
        AND (pos_y IS NULL OR pos_y BETWEEN 0 AND 10000))
);

-- Every branch may have its own "Meja 1"; one branch may not have two.
CREATE UNIQUE INDEX tables_outlet_name_key ON tables (tenant_id, outlet_id, lower(name))
    WHERE deleted_at IS NULL;

CREATE TABLE table_status (
    tenant_id      uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    table_id       uuid NOT NULL,
    outlet_id      uuid NOT NULL,
    status         text NOT NULL DEFAULT 'available'
        CHECK (status IN ('available', 'occupied', 'reserved')),
    -- When the applied status was set on the till. 0 until a till sets one.
    occurred_at_ms bigint NOT NULL DEFAULT 0 CHECK (occurred_at_ms >= 0),
    -- The event and device behind the applied status. NULL until a till sets
    -- one. device_id is what tells a device's own follow-up write from a race.
    event_id       uuid,
    device_id      uuid,
    employee_name  text NOT NULL DEFAULT '',
    contested      boolean NOT NULL DEFAULT false,
    sync_seq       bigint NOT NULL DEFAULT 0,
    -- Set together with its table's tombstone.
    deleted_at     timestamptz,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, table_id),
    CONSTRAINT table_status_table_context_fk
        FOREIGN KEY (tenant_id, outlet_id, table_id) REFERENCES tables (tenant_id, outlet_id, id),
    CONSTRAINT table_status_employee_name_length CHECK (length(employee_name) <= 120)
);

CREATE TABLE table_status_events (
    -- Chosen by the till offline; the idempotency key when it is pushed.
    id             uuid PRIMARY KEY,
    tenant_id      uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id      uuid NOT NULL,
    table_id       uuid NOT NULL,
    status         text NOT NULL CHECK (status IN ('available', 'occupied', 'reserved')),
    -- The table_status sequence the till had pulled when it made the change.
    basis_seq      bigint NOT NULL CHECK (basis_seq >= 0),
    client_seq     bigint NOT NULL CHECK (client_seq > 0),
    occurred_at_ms bigint NOT NULL CHECK (occurred_at_ms >= 0),
    device_id      uuid NOT NULL,
    employee_name  text NOT NULL DEFAULT '',
    -- applied: the projection took this status. superseded: a later write by
    -- another till won, and the projection kept that one.
    outcome        text NOT NULL CHECK (outcome IN ('applied', 'superseded')),
    -- table_status.sync_seq after this event: any snapshot at or past it
    -- already reflects it.
    status_seq     bigint NOT NULL,
    contested      boolean NOT NULL,
    -- The pushed row exactly as accepted, so an exact retry is recognised and
    -- a different row under the same id is refused.
    payload        jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT table_status_events_table_context_fk
        FOREIGN KEY (tenant_id, outlet_id, table_id) REFERENCES tables (tenant_id, outlet_id, id),
    CONSTRAINT table_status_events_device_context_fk
        FOREIGN KEY (tenant_id, device_id) REFERENCES devices (tenant_id, id),
    CONSTRAINT table_status_events_employee_name_length CHECK (length(employee_name) <= 120)
);

-- The feed indexes lead with the outlet: a till pulls its own branch only.
-- INCLUDE must stay in step with the published columns in syncfeed/registry.go,
-- or a pull stops being an Index Only Scan.
CREATE INDEX tables_sync_feed_idx ON tables (tenant_id, outlet_id, sync_seq)
    INCLUDE (id, name, area, capacity, pos_x, pos_y, sort_order, active, deleted_at);

CREATE INDEX table_status_sync_feed_idx ON table_status (tenant_id, outlet_id, sync_seq)
    INCLUDE (table_id, status, occurred_at_ms, employee_name, contested, deleted_at);

-- One table's history, newest last.
CREATE INDEX table_status_events_table_idx ON table_status_events (tenant_id, table_id, created_at);
CREATE UNIQUE INDEX table_status_events_device_seq_idx ON table_status_events (tenant_id, table_id, device_id, client_seq);

GRANT SELECT, INSERT, UPDATE, DELETE ON tables, table_status, table_status_events TO justclick_app;

-- +goose StatementBegin
DO $$
DECLARE tbl text;
BEGIN
    FOREACH tbl IN ARRAY ARRAY['tables', 'table_status', 'table_status_events'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', tbl);
        EXECUTE format('CREATE POLICY tenant_isolation ON %I USING (tenant_id = app.current_tenant_id()) WITH CHECK (tenant_id = app.current_tenant_id())', tbl);
    END LOOP;
END $$;
-- +goose StatementEnd

-- +goose Down
DROP TABLE table_status_events;
DROP TABLE table_status;
DROP TABLE tables;
