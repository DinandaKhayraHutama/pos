-- +goose Up

ALTER TABLE daily_sales_rollup
    ADD COLUMN tax_included bigint NOT NULL DEFAULT 0,
    ADD COLUMN rounding bigint NOT NULL DEFAULT 0;

CREATE TABLE daily_sales_type_rollup (
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id uuid NOT NULL,
    business_date date NOT NULL,
    sales_type_key text NOT NULL,
    sales_type_name text NOT NULL,
    order_count bigint NOT NULL,
    revenue bigint NOT NULL,
    net_sales bigint NOT NULL,
    PRIMARY KEY (tenant_id, outlet_id, business_date, sales_type_key),
    FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets(tenant_id, id)
);
CREATE INDEX daily_sales_type_rollup_date_idx ON daily_sales_type_rollup(tenant_id, business_date);

CREATE TABLE daily_payment_method_rollup (
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id uuid NOT NULL,
    business_date date NOT NULL,
    payment_method_key text NOT NULL,
    payment_method_name text NOT NULL,
    payment_kind text NOT NULL,
    order_count bigint NOT NULL,
    revenue bigint NOT NULL,
    PRIMARY KEY (tenant_id, outlet_id, business_date, payment_method_key),
    FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets(tenant_id, id)
);
CREATE INDEX daily_payment_method_rollup_date_idx ON daily_payment_method_rollup(tenant_id, business_date);

ALTER TABLE daily_sales_type_rollup ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_sales_type_rollup FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON daily_sales_type_rollup
    USING (tenant_id = app.current_tenant_id()) WITH CHECK (tenant_id = app.current_tenant_id());
ALTER TABLE daily_payment_method_rollup ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_payment_method_rollup FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON daily_payment_method_rollup
    USING (tenant_id = app.current_tenant_id()) WITH CHECK (tenant_id = app.current_tenant_id());
GRANT SELECT, INSERT, UPDATE, DELETE ON daily_sales_type_rollup, daily_payment_method_rollup TO justclick_app;

INSERT INTO report_dirty_slices (tenant_id, outlet_id, business_date)
SELECT tenant_id, outlet_id, business_date FROM orders
UNION SELECT tenant_id, outlet_id, business_date FROM daily_sales_rollup
ON CONFLICT (tenant_id, outlet_id, business_date) DO UPDATE
SET generation = report_dirty_slices.generation + 1, changed_at = now();

-- +goose Down
DROP TABLE daily_payment_method_rollup;
DROP TABLE daily_sales_type_rollup;
ALTER TABLE daily_sales_rollup DROP COLUMN rounding, DROP COLUMN tax_included;
