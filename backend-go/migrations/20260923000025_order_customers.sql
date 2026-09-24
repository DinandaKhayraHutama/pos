-- +goose Up

-- Keep the stable customer identity beside the immutable customer_name
-- snapshot in payload. There is deliberately no foreign key: merged customer
-- rows remain historical identities and an offline order may arrive after a
-- merge. Reads resolve merged_into_id; writes preserve what the till sent.
ALTER TABLE orders ADD COLUMN customer_id uuid;

CREATE INDEX orders_tenant_customer_business_date_idx
    ON orders (tenant_id, customer_id, business_date DESC)
    WHERE customer_id IS NOT NULL;

-- +goose Down

DROP INDEX orders_tenant_customer_business_date_idx;
ALTER TABLE orders DROP COLUMN customer_id;
