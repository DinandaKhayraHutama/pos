-- +goose Up
CREATE TABLE pos_sessions (
    id uuid PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id uuid NOT NULL,
    pos_register_id uuid NOT NULL,
    device_id uuid NOT NULL,
    revision bigint NOT NULL CHECK (revision > 0),
    employee_name text NOT NULL,
    opened_at_ms bigint NOT NULL CHECK (opened_at_ms >= 0),
    closed_at_ms bigint,
    opening_cash bigint NOT NULL CHECK (opening_cash >= 0),
    counted_cash bigint,
    expected_cash bigint,
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, outlet_id, pos_register_id, id),
    FOREIGN KEY (tenant_id, outlet_id, pos_register_id) REFERENCES pos_registers(tenant_id, outlet_id, id),
    FOREIGN KEY (tenant_id, device_id) REFERENCES devices(tenant_id, id),
    CHECK (closed_at_ms IS NULL OR closed_at_ms >= opened_at_ms)
);
CREATE UNIQUE INDEX pos_sessions_one_open_register ON pos_sessions(pos_register_id) WHERE closed_at_ms IS NULL;
CREATE INDEX pos_sessions_tenant_outlet ON pos_sessions(tenant_id, outlet_id, opened_at_ms);

-- The UUID is globally reserved, including after an order partition is archived.
-- Identity binding prevents a known UUID from being used by a different till.
CREATE TABLE order_dedupe (
    id uuid PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id uuid NOT NULL,
    pos_register_id uuid NOT NULL,
    device_id uuid NOT NULL,
    business_date date NOT NULL,
    first_seen timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, outlet_id, pos_register_id) REFERENCES pos_registers(tenant_id, outlet_id, id),
    FOREIGN KEY (tenant_id, device_id) REFERENCES devices(tenant_id, id)
);

CREATE TABLE orders (
    business_date date NOT NULL,
    id uuid NOT NULL,
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id uuid NOT NULL,
    pos_register_id uuid NOT NULL,
    device_id uuid NOT NULL,
    pos_session_id uuid NOT NULL,
    revision bigint NOT NULL CHECK (revision > 0),
    status text NOT NULL CHECK (status IN ('pending','preparing','ready','served','paid','cancelled','refunded')),
    settled_at timestamptz,
    placed_at_ms bigint NOT NULL,
    subtotal bigint NOT NULL,
    discount bigint NOT NULL,
    tax bigint NOT NULL,
    service_charge_amount bigint NOT NULL,
    total bigint NOT NULL,
    amount_paid bigint NOT NULL,
    refunded_amount bigint,
    payment_method text NOT NULL,
    cashier_name text NOT NULL,
    authorized_by text,
    void_reason text,
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (business_date, id),
    UNIQUE (business_date, tenant_id, id),
    FOREIGN KEY (tenant_id, outlet_id, pos_register_id, pos_session_id)
        REFERENCES pos_sessions(tenant_id, outlet_id, pos_register_id, id),
    FOREIGN KEY (tenant_id, device_id) REFERENCES devices(tenant_id, id),
    CHECK (subtotal >= 0 AND discount >= 0 AND tax >= 0 AND service_charge_amount >= 0 AND total >= 0 AND amount_paid >= 0),
    CHECK ((status IN ('cancelled','refunded')) = (settled_at IS NOT NULL))
) PARTITION BY RANGE (business_date);
CREATE INDEX orders_outlet_date ON orders(tenant_id, outlet_id, business_date);
CREATE INDEX orders_session ON orders(tenant_id, pos_session_id);
CREATE INDEX orders_rollup ON orders(tenant_id, business_date, outlet_id) INCLUDE(subtotal, discount, total, status);

CREATE TABLE order_items (
    business_date date NOT NULL,
    id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    order_id uuid NOT NULL,
    product_name text NOT NULL,
    category_name text,
    unit_price bigint NOT NULL,
    unit_cost bigint,
    quantity bigint NOT NULL CHECK (quantity > 0),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    PRIMARY KEY (business_date, id),
    UNIQUE (business_date, tenant_id, id),
    FOREIGN KEY (business_date, tenant_id, order_id) REFERENCES orders(business_date, tenant_id, id) ON DELETE CASCADE
) PARTITION BY RANGE (business_date);
CREATE INDEX order_items_order ON order_items(business_date, tenant_id, order_id);

CREATE TABLE order_item_modifiers (
    business_date date NOT NULL,
    id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    order_item_id uuid NOT NULL,
    group_name text NOT NULL,
    option_name text NOT NULL,
    price_delta bigint NOT NULL,
    sort_order integer NOT NULL,
    PRIMARY KEY (business_date, id),
    FOREIGN KEY (business_date, tenant_id, order_item_id) REFERENCES order_items(business_date, tenant_id, id) ON DELETE CASCADE
) PARTITION BY RANGE (business_date);

-- One row per received attempt, not per sale. Retrying grows audit, not money.
CREATE TABLE ingest_log (
    received_date date NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')::date,
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    device_id uuid NOT NULL,
    entity text NOT NULL,
    payload jsonb NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (received_date, id),
    FOREIGN KEY (tenant_id, device_id) REFERENCES devices(tenant_id,id)
) PARTITION BY RANGE (received_date);
CREATE INDEX ingest_log_device ON ingest_log(tenant_id, device_id, received_at);

-- A durable dirty marker is sufficient in Fase 3. Fase 7 owns rollup execution;
-- deleting this marker requires recomputing the corresponding order slice.
CREATE TABLE report_dirty_slices (
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    outlet_id uuid NOT NULL,
    business_date date NOT NULL,
    generation bigint NOT NULL DEFAULT 1,
    changed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, outlet_id, business_date),
    FOREIGN KEY (tenant_id, outlet_id) REFERENCES outlets(tenant_id,id)
);

-- +goose StatementBegin
DO $$
DECLARE tbl text;
BEGIN
    FOREACH tbl IN ARRAY ARRAY['pos_sessions','order_dedupe','orders','order_items','order_item_modifiers','ingest_log','report_dirty_slices'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', tbl);
        EXECUTE format('CREATE POLICY tenant_isolation ON %I USING (tenant_id = app.current_tenant_id()) WITH CHECK (tenant_id = app.current_tenant_id())', tbl);
    END LOOP;
END $$;
-- +goose StatementEnd

-- Maintenance is privileged and accepts no names/ranges from devices. Partition
-- children enforce RLS as well, since table grants permit direct SQL access.
-- +goose StatementBegin
CREATE FUNCTION app.ensure_ingest_partitions() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE tbl text; child text; start_date date; end_date date; n integer;
BEGIN
    PERFORM pg_advisory_xact_lock(741320031);
    FOREACH tbl IN ARRAY ARRAY['orders','order_items','order_item_modifiers','ingest_log'] LOOP
        FOR n IN 0..CASE WHEN tbl = 'ingest_log' THEN 7 ELSE 3 END LOOP
            IF tbl = 'ingest_log' THEN
                start_date := (now() AT TIME ZONE 'UTC')::date + n;
                end_date := start_date + 1;
                child := tbl || '_' || to_char(start_date, 'YYYYMMDD');
            ELSE
                start_date := (date_trunc('month', now() AT TIME ZONE 'UTC') + n * interval '1 month')::date;
                end_date := (start_date + interval '1 month')::date;
                child := tbl || '_' || to_char(start_date, 'YYYY_MM');
            END IF;
            IF to_regclass('public.' || child) IS NULL THEN
                EXECUTE format('CREATE TABLE public.%I PARTITION OF public.%I FOR VALUES FROM (%L) TO (%L)', child, tbl, start_date, end_date);
                EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', child);
                EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', child);
                EXECUTE format('CREATE POLICY tenant_isolation ON public.%I USING (tenant_id = app.current_tenant_id()) WITH CHECK (tenant_id = app.current_tenant_id())', child);
            END IF;
        END LOOP;
        child := tbl || '_default';
        IF to_regclass('public.' || child) IS NULL THEN
            EXECUTE format('CREATE TABLE public.%I PARTITION OF public.%I DEFAULT', child, tbl);
            EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', child);
            EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', child);
            EXECUTE format('CREATE POLICY tenant_isolation ON public.%I USING (tenant_id = app.current_tenant_id()) WITH CHECK (tenant_id = app.current_tenant_id())', child);
        END IF;
    END LOOP;
END $$;
-- +goose StatementEnd
REVOKE ALL ON FUNCTION app.ensure_ingest_partitions() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.ensure_ingest_partitions() TO justclick_unscoped;
SELECT app.ensure_ingest_partitions();

-- +goose Down
DROP FUNCTION app.ensure_ingest_partitions();
DROP TABLE report_dirty_slices;
DROP TABLE ingest_log;
DROP TABLE order_item_modifiers;
DROP TABLE order_items;
DROP TABLE orders;
DROP TABLE order_dedupe;
DROP TABLE pos_sessions;
