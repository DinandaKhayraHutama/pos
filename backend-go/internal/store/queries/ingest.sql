-- name: AppendIngestLog :exec
INSERT INTO ingest_log (tenant_id, device_id, entity, payload)
VALUES ($1, $2, $3, $4);

-- name: InsertSession :execrows
INSERT INTO pos_sessions (id, tenant_id, outlet_id, pos_register_id, device_id, revision,
 employee_name, opened_at_ms, closed_at_ms, opening_cash, counted_cash, expected_cash, payload)
SELECT (p->>'id')::uuid, $1, $2, $3, $4, (p->>'revision')::bigint,
 p->>'employee_name', (p->>'opened_at_ms')::bigint, (p->>'closed_at_ms')::bigint,
 (p->>'opening_cash')::bigint, (p->>'counted_cash')::bigint, (p->>'expected_cash')::bigint, p
FROM (SELECT $5::jsonb AS p) input
ON CONFLICT (id) DO NOTHING;

-- name: GetSessionForUpdate :one
SELECT * FROM pos_sessions WHERE id = $1 FOR UPDATE;

-- name: UpdateOpenSession :execrows
UPDATE pos_sessions SET revision = (p->>'revision')::bigint,
 closed_at_ms = (p->>'closed_at_ms')::bigint, counted_cash = (p->>'counted_cash')::bigint,
 expected_cash = (p->>'expected_cash')::bigint, payload = p, updated_at = now()
FROM (SELECT $2::jsonb AS p) input
WHERE pos_sessions.id = $1 AND closed_at_ms IS NULL AND revision < (p->>'revision')::bigint;

-- name: OpenSessionHolder :one
SELECT id, employee_name FROM pos_sessions WHERE pos_register_id = $1 AND closed_at_ms IS NULL;

-- name: ReserveOrderID :execrows
INSERT INTO order_dedupe (id, tenant_id, outlet_id, pos_register_id, device_id, business_date)
VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (id) DO NOTHING;

-- name: GetOrderReservation :one
SELECT * FROM order_dedupe WHERE id = $1 FOR UPDATE;

-- name: GetOrder :one
SELECT * FROM orders WHERE business_date = $1 AND id = $2;

-- name: InsertOrder :exec
INSERT INTO orders (business_date, id, tenant_id, outlet_id, pos_register_id, device_id, pos_session_id,
 revision, status, settled_at, placed_at_ms, subtotal, discount, tax, service_charge_amount,
 total, amount_paid, refunded_amount, payment_method, cashier_name, authorized_by, void_reason, customer_id,
 tax_included, rounding_amount, pricing_mismatch, payload)
SELECT $1, (p->>'id')::uuid, $2, $3, $4, $5, (p->>'pos_session_id')::uuid,
 (p->>'revision')::bigint, p->>'status', CASE WHEN p->>'status' IN ('cancelled','refunded') THEN now() END,
 (p->>'placed_at_ms')::bigint, (p->>'subtotal')::bigint, (p->>'discount')::bigint, (p->>'tax')::bigint,
 (p->>'service_charge_amount')::bigint, (p->>'total')::bigint, (p->>'amount_paid')::bigint,
 (p->>'refunded_amount')::bigint, p->>'payment_method', p->>'cashier_name', p->>'authorized_by', p->>'void_reason',
 NULLIF(p->>'customer_id', '')::uuid,
 COALESCE((p->>'tax_included')::bigint, 0), COALESCE((p->>'rounding_amount')::bigint, 0), $7, p
FROM (SELECT $6::jsonb AS p) input;

-- name: UpdateUnsettledOrder :execrows
UPDATE orders SET revision = (p->>'revision')::bigint, status = p->>'status',
 settled_at = CASE WHEN p->>'status' IN ('cancelled','refunded') THEN now() END,
 refunded_amount = (p->>'refunded_amount')::bigint, authorized_by = p->>'authorized_by',
 void_reason = p->>'void_reason', payload = p, updated_at = now()
FROM (SELECT $3::jsonb AS p) input
WHERE business_date = $1 AND orders.id = $2 AND settled_at IS NULL AND revision < (p->>'revision')::bigint;

-- name: InsertOrderItems :exec
INSERT INTO order_items (business_date, id, tenant_id, order_id, product_name, category_name,
 unit_price, unit_cost, quantity, payload)
SELECT $1, (p->>'id')::uuid, $2, $3, p->>'product_name', p->>'category_name',
 (p->>'unit_price')::bigint, (p->>'unit_cost')::bigint, (p->>'quantity')::bigint, p
FROM jsonb_array_elements($4::jsonb) p;

-- name: InsertOrderModifiers :exec
INSERT INTO order_item_modifiers (business_date, id, tenant_id, order_item_id, group_name, option_name, price_delta, sort_order)
SELECT $1, (m->>'id')::uuid, $2, (p->>'id')::uuid, m->>'group_name', m->>'option_name',
 (m->>'price_delta')::bigint, (m->>'sort_order')::integer
FROM jsonb_array_elements($3::jsonb) p CROSS JOIN LATERAL jsonb_array_elements(p->'modifiers') m;

-- name: MarkReportDirty :exec
INSERT INTO report_dirty_slices (tenant_id, outlet_id, business_date) VALUES ($1, $2, $3)
ON CONFLICT (tenant_id, outlet_id, business_date) DO UPDATE
SET generation = report_dirty_slices.generation + 1, changed_at = now();
