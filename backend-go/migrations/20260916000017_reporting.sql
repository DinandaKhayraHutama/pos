-- +goose Up

-- Reporting (Fase 7): the rollups a report reads instead of the order tables,
-- and the export and schedule rows behind downloads and e-mailed links.
--
-- A report never scans orders. Every rollup row belongs to one
-- (tenant, outlet, business_date) slice, and a slice is recomputed whole by one
-- River job. The ingest transaction that changes an order marks its slice dirty
-- (report_dirty_slices.generation + 1) and enqueues that job; the job computes
-- every rollup of the slice on one snapshot, then deletes the marker only while
-- the generation it read is still current. A sale that lands while the job
-- runs leaves the marker in place and the job runs again, so a clean marker
-- always means the rollups include everything committed.
--
-- Rollups are not materialized views: those refresh a whole table, which is
-- thirty million rows a month, where one slice is a few hundred.

-- Hours in a report are the merchant's, not the server's. No settings screen
-- writes this yet; every current merchant trades in WIB.
ALTER TABLE tenants ADD COLUMN timezone text NOT NULL DEFAULT 'Asia/Jakarta'
    CONSTRAINT tenants_timezone_shape CHECK (timezone ~ '^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$');

-- Revenue follows the till: every order that is not cancelled or refunded.
-- Undone orders are counted in their own columns, the one place a report shows
-- what revenue excludes.
CREATE TABLE daily_sales_rollup (
    tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id         uuid NOT NULL,
    business_date     date NOT NULL,
    order_count       bigint NOT NULL,
    subtotal          bigint NOT NULL,
    discount          bigint NOT NULL,
    tax               bigint NOT NULL,
    service_charge    bigint NOT NULL,
    revenue           bigint NOT NULL,
    items_sold        bigint NOT NULL,
    cost_of_goods     bigint NOT NULL,
    -- Items that carried a cost. Without it a half-costed catalogue reports a
    -- margin that looks excellent and means nothing.
    costed_items      bigint NOT NULL,
    discounted_orders bigint NOT NULL,
    cancelled_count   bigint NOT NULL,
    cancelled_amount  bigint NOT NULL,
    refunded_count    bigint NOT NULL,
    refunded_amount   bigint NOT NULL,
    computed_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, outlet_id, business_date),
    CONSTRAINT daily_sales_rollup_outlet_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id)
);

-- Net sales carry each order's discount split by largest remainder, so a
-- category column always adds up to subtotal minus discount. Grouped by id:
-- a rename stays one row, and the name shown is resolved when the report runs.
CREATE TABLE daily_category_rollup (
    tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id     uuid NOT NULL,
    business_date date NOT NULL,
    category_key  text NOT NULL,
    category_name text NOT NULL,
    name_at_ms    bigint NOT NULL,
    gross_sales   bigint NOT NULL,
    net_sales     bigint NOT NULL,
    items_sold    bigint NOT NULL,
    PRIMARY KEY (tenant_id, outlet_id, business_date, category_key),
    CONSTRAINT daily_category_rollup_outlet_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id)
);

CREATE TABLE daily_product_rollup (
    tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id       uuid NOT NULL,
    business_date   date NOT NULL,
    -- The product id a line carried, or 'name:' and its name when it had none.
    product_key     text NOT NULL,
    product_name    text NOT NULL,
    name_at_ms      bigint NOT NULL,
    quantity        bigint NOT NULL,
    gross_sales     bigint NOT NULL,
    cost_of_goods   bigint NOT NULL,
    costed_quantity bigint NOT NULL,
    PRIMARY KEY (tenant_id, outlet_id, business_date, product_key),
    CONSTRAINT daily_product_rollup_outlet_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id)
);

CREATE TABLE daily_employee_rollup (
    tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id     uuid NOT NULL,
    business_date date NOT NULL,
    -- The cashier id, or 'name:' and the name for a sale that carried none, so
    -- two people who share a name stay two rows when their ids are known.
    cashier_key   text NOT NULL,
    cashier_name  text NOT NULL,
    name_at_ms    bigint NOT NULL,
    order_count   bigint NOT NULL,
    revenue       bigint NOT NULL,
    discount      bigint NOT NULL,
    PRIMARY KEY (tenant_id, outlet_id, business_date, cashier_key),
    CONSTRAINT daily_employee_rollup_outlet_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id)
);

CREATE TABLE daily_payment_rollup (
    tenant_id      uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id      uuid NOT NULL,
    business_date  date NOT NULL,
    payment_method text NOT NULL,
    order_count    bigint NOT NULL,
    revenue        bigint NOT NULL,
    PRIMARY KEY (tenant_id, outlet_id, business_date, payment_method),
    CONSTRAINT daily_payment_rollup_outlet_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id)
);

-- The hour on the merchant's clock (tenants.timezone) the order was placed.
CREATE TABLE hourly_sales_rollup (
    tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id     uuid NOT NULL,
    business_date date NOT NULL,
    hour          smallint NOT NULL CHECK (hour BETWEEN 0 AND 23),
    order_count   bigint NOT NULL,
    revenue       bigint NOT NULL,
    PRIMARY KEY (tenant_id, outlet_id, business_date, hour),
    CONSTRAINT hourly_sales_rollup_outlet_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id)
);

-- The discount and void audit: discounts by the promo or authoriser label the
-- till recorded, and cancellations and refunds by who authorised them.
CREATE TABLE daily_adjustment_rollup (
    tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id     uuid NOT NULL,
    business_date date NOT NULL,
    kind          text NOT NULL CHECK (kind IN ('discount', 'cancelled', 'refunded')),
    label         text NOT NULL,
    order_count   bigint NOT NULL,
    amount        bigint NOT NULL,
    PRIMARY KEY (tenant_id, outlet_id, business_date, kind, label),
    CONSTRAINT daily_adjustment_rollup_outlet_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id)
);

-- A whole-chain report reads by date across every outlet.
CREATE INDEX daily_sales_rollup_date_idx ON daily_sales_rollup (tenant_id, business_date);
CREATE INDEX daily_category_rollup_date_idx ON daily_category_rollup (tenant_id, business_date);
CREATE INDEX daily_product_rollup_date_idx ON daily_product_rollup (tenant_id, business_date);
CREATE INDEX daily_employee_rollup_date_idx ON daily_employee_rollup (tenant_id, business_date);
CREATE INDEX daily_payment_rollup_date_idx ON daily_payment_rollup (tenant_id, business_date);
CREATE INDEX hourly_sales_rollup_date_idx ON hourly_sales_rollup (tenant_id, business_date);
CREATE INDEX daily_adjustment_rollup_date_idx ON daily_adjustment_rollup (tenant_id, business_date);
CREATE INDEX report_dirty_slices_date_idx ON report_dirty_slices (tenant_id, business_date);

CREATE TABLE report_schedules (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    created_by  uuid,
    frequency   text NOT NULL CHECK (frequency IN ('daily', 'weekly', 'monthly')),
    format      text NOT NULL CHECK (format IN ('csv', 'xlsx', 'pdf')),
    outlet_id   uuid,
    recipients  text[] NOT NULL CHECK (cardinality(recipients) BETWEEN 1 AND 10),
    active      boolean NOT NULL DEFAULT true,
    next_run_at timestamptz NOT NULL,
    last_run_at timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT report_schedules_outlet_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id)
);

CREATE INDEX report_schedules_due_idx ON report_schedules (next_run_at) WHERE active;

CREATE TABLE report_exports (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    -- The employee who asked, or NULL for a scheduled run.
    requested_by    uuid,
    schedule_id     uuid,
    format          text NOT NULL CHECK (format IN ('csv', 'xlsx', 'pdf')),
    outlet_id       uuid,
    date_from       date NOT NULL,
    date_to         date NOT NULL,
    status          text NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued', 'running', 'done', 'failed')),
    file_key        text,
    byte_size       bigint,
    error           text,
    -- An e-mailed download link carries a random token. Only its hash is
    -- stored, and the link stops working at link_expires_at.
    token_sha256    bytea,
    link_expires_at timestamptz,
    delivered_at    timestamptz,
    delivery_error  text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz,
    UNIQUE (tenant_id, id),
    CONSTRAINT report_exports_range CHECK (date_to >= date_from AND date_to - date_from <= 366),
    CONSTRAINT report_exports_outlet_fk
        FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets (tenant_id, id),
    -- A deleted schedule keeps its past exports; a pending one is no longer mailed.
    CONSTRAINT report_exports_schedule_fk
        FOREIGN KEY (tenant_id, schedule_id) REFERENCES report_schedules (tenant_id, id)
        ON DELETE SET NULL (schedule_id),
    CONSTRAINT report_exports_error_length CHECK (error IS NULL OR length(error) <= 500),
    CONSTRAINT report_exports_delivery_error_length CHECK (delivery_error IS NULL OR length(delivery_error) <= 500)
);

CREATE INDEX report_exports_tenant_created_idx ON report_exports (tenant_id, created_at DESC);
-- One export per schedule run: a retried scan must not mail a report twice.
CREATE UNIQUE INDEX report_exports_schedule_period_key ON report_exports (schedule_id, date_from, date_to)
    WHERE schedule_id IS NOT NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON
    daily_sales_rollup, daily_category_rollup, daily_product_rollup, daily_employee_rollup,
    daily_payment_rollup, hourly_sales_rollup, daily_adjustment_rollup,
    report_schedules, report_exports
TO justclick_app;

-- +goose StatementBegin
DO $$
DECLARE tbl text;
BEGIN
    FOREACH tbl IN ARRAY ARRAY[
        'daily_sales_rollup', 'daily_category_rollup', 'daily_product_rollup',
        'daily_employee_rollup', 'daily_payment_rollup', 'hourly_sales_rollup',
        'daily_adjustment_rollup', 'report_schedules', 'report_exports'
    ] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', tbl);
        EXECUTE format('CREATE POLICY tenant_isolation ON %I USING (tenant_id = app.current_tenant_id()) WITH CHECK (tenant_id = app.current_tenant_id())', tbl);
    END LOOP;
END $$;
-- +goose StatementEnd

-- +goose Down
DROP TABLE report_exports;
DROP TABLE report_schedules;
DROP INDEX report_dirty_slices_date_idx;
DROP TABLE daily_adjustment_rollup;
DROP TABLE hourly_sales_rollup;
DROP TABLE daily_payment_rollup;
DROP TABLE daily_employee_rollup;
DROP TABLE daily_product_rollup;
DROP TABLE daily_category_rollup;
DROP TABLE daily_sales_rollup;
ALTER TABLE tenants DROP COLUMN timezone;
