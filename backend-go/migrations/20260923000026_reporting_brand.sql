-- +goose Up
CREATE TABLE daily_brand_rollup (
    tenant_id uuid NOT NULL,
    outlet_id uuid NOT NULL,
    business_date date NOT NULL,
    brand_key text NOT NULL,
    brand_name text NOT NULL DEFAULT '',
    name_at_ms bigint NOT NULL DEFAULT 0,
    gross_sales bigint NOT NULL,
    net_sales bigint NOT NULL,
    items_sold bigint NOT NULL,
    computed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, outlet_id, business_date, brand_key),
    FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id) ON DELETE CASCADE
);
CREATE INDEX daily_brand_rollup_date_idx ON daily_brand_rollup (tenant_id, business_date, outlet_id);
ALTER TABLE daily_brand_rollup ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_brand_rollup FORCE ROW LEVEL SECURITY;
CREATE POLICY daily_brand_rollup_tenant_isolation ON daily_brand_rollup
    USING (tenant_id = app.current_tenant_id()) WITH CHECK (tenant_id = app.current_tenant_id());
GRANT SELECT, INSERT, UPDATE, DELETE ON daily_brand_rollup TO justclick_app;
INSERT INTO report_dirty_slices (tenant_id, outlet_id, business_date)
SELECT tenant_id, outlet_id, business_date FROM daily_sales_rollup
ON CONFLICT (tenant_id, outlet_id, business_date) DO UPDATE
SET generation = report_dirty_slices.generation + 1, changed_at = now();
-- +goose Down
DROP TABLE daily_brand_rollup;
