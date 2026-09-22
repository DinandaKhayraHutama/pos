-- +goose Up

-- Reporting F1: the waterfall a sales report is read as, and the product split
-- inside a category. Additive only — existing receipts, drawer snapshots,
-- outbox rows and stock effects are deliberately untouched.
--
-- Two definitions change meaning here, so both are stored rather than derived
-- at read time:
--
--   * gross_sales / all_discount / sales_returns are the waterfall. Gross is
--     every order that was not cancelled, INCLUDING one refunded later, so a
--     refund is visible as a return instead of silently shrinking the day.
--     net = gross - all_discount - sales_returns, which is identically
--     subtotal - discount over the orders revenue already counts.
--   * calculation_version says which rules produced the row. A report counts
--     the rows still at version 1 and says its waterfall is incomplete, rather
--     than showing a new column full of zeroes as a result.
ALTER TABLE daily_sales_rollup
    ADD COLUMN gross_sales         bigint  NOT NULL DEFAULT 0,
    ADD COLUMN all_discount        bigint  NOT NULL DEFAULT 0,
    ADD COLUMN sales_returns       bigint  NOT NULL DEFAULT 0,
    -- Orders whose stored total does not equal subtotal - discount + tax +
    -- service charge. Flagged, never repaired: F1 does not rewrite history.
    ADD COLUMN anomaly_count       bigint  NOT NULL DEFAULT 0,
    ADD COLUMN calculation_version integer NOT NULL DEFAULT 1;

-- Net per product, per cashier and per hour: the same largest-remainder
-- allocation the category split already used, so every breakdown reconciles to
-- the same rupiah.
ALTER TABLE daily_product_rollup  ADD COLUMN net_sales bigint NOT NULL DEFAULT 0;
ALTER TABLE daily_employee_rollup ADD COLUMN net_sales bigint NOT NULL DEFAULT 0;
ALTER TABLE hourly_sales_rollup
    ADD COLUMN net_sales   bigint NOT NULL DEFAULT 0,
    ADD COLUMN gross_sales bigint NOT NULL DEFAULT 0;

-- An export file made under the old rules stays readable and stays labelled as
-- what it is. New rows default to 2; the rows already on disk keep 1.
ALTER TABLE report_exports ADD COLUMN calculation_version integer NOT NULL DEFAULT 1;
ALTER TABLE report_exports ALTER COLUMN calculation_version SET DEFAULT 2;

-- Top items WITHIN a category. Keyed like its two parents so the same rename
-- and deletion rules apply, and allocated in two passes — the order's discount
-- across its categories first, then each category's share across its own
-- products — so this table sums to daily_category_rollup, which sums to net.
CREATE TABLE daily_product_category_rollup (
    tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id     uuid NOT NULL,
    business_date date NOT NULL,
    category_key  text NOT NULL,
    product_key   text NOT NULL,
    product_name  text NOT NULL,
    name_at_ms    bigint NOT NULL,
    quantity      bigint NOT NULL,
    gross_sales   bigint NOT NULL,
    net_sales     bigint NOT NULL,
    PRIMARY KEY (tenant_id, outlet_id, business_date, category_key, product_key),
    CONSTRAINT daily_product_category_rollup_outlet_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id)
);

-- A whole-chain report reads by date across every outlet, like its siblings.
CREATE INDEX daily_product_category_rollup_date_idx
    ON daily_product_category_rollup (tenant_id, business_date);

ALTER TABLE daily_product_category_rollup ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_product_category_rollup FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON daily_product_category_rollup
    USING (tenant_id = app.current_tenant_id()) WITH CHECK (tenant_id = app.current_tenant_id());
GRANT SELECT, INSERT, UPDATE, DELETE ON daily_product_category_rollup TO justclick_app;

-- Every slice that has ever held an order is marked for recompute, including
-- dates older than the nightly window and outlets that have since been switched
-- off — a closed branch still has financial history, and leaving its rows at
-- version 1 would be a permanently incomplete report. The worker drains these
-- a hundred at a time; the markers are durable, so an interrupted backfill
-- resumes rather than restarting.
INSERT INTO report_dirty_slices (tenant_id, outlet_id, business_date)
SELECT tenant_id, outlet_id, business_date FROM orders
UNION
SELECT tenant_id, outlet_id, business_date FROM daily_sales_rollup
ON CONFLICT (tenant_id, outlet_id, business_date) DO UPDATE
SET generation = report_dirty_slices.generation + 1, changed_at = now();

-- +goose Down
DROP TABLE daily_product_category_rollup;
ALTER TABLE report_exports DROP COLUMN calculation_version;
ALTER TABLE hourly_sales_rollup DROP COLUMN gross_sales, DROP COLUMN net_sales;
ALTER TABLE daily_employee_rollup DROP COLUMN net_sales;
ALTER TABLE daily_product_rollup DROP COLUMN net_sales;
ALTER TABLE daily_sales_rollup
    DROP COLUMN gross_sales, DROP COLUMN all_discount, DROP COLUMN sales_returns,
    DROP COLUMN anomaly_count, DROP COLUMN calculation_version;
