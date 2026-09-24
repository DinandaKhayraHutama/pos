-- +goose Up

-- Customer exports contain personal data. Keep a tenant-scoped, append-only
-- record of who produced each file without retaining another copy of the file.
CREATE TABLE customer_export_events (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    actor_id    uuid NOT NULL,
    row_count   integer NOT NULL CHECK (row_count >= 0),
    exported_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT customer_export_events_actor_fk
        FOREIGN KEY (tenant_id, actor_id) REFERENCES employees(tenant_id, id)
);

CREATE INDEX customer_export_events_tenant_time_idx
    ON customer_export_events (tenant_id, exported_at DESC);

GRANT SELECT, INSERT ON customer_export_events TO justclick_app;

ALTER TABLE customer_export_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_export_events FORCE ROW LEVEL SECURITY;

CREATE POLICY customer_export_events_tenant_isolation ON customer_export_events
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

-- +goose Down

DROP TABLE customer_export_events;
