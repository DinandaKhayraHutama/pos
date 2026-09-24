-- +goose Up

-- Fase 2 paritas: customers. Company-scoped like brands and categories —
-- a customer belongs to the business, not a branch, the same split every
-- other master in this schema already draws.
--
-- Unlike every other master a till pulls, a customer may be CREATED by a
-- till: a cashier meets someone new and types their name in at the counter.
-- The device mints the id itself and that id is the idempotency key for the
-- push — see ingest.go's handling of the "customers" entity. Editing an
-- existing customer, by contrast, is Backoffice-only: the wire protocol
-- carries no revision/base-version concept a till and a browser could both
-- race to bump, so a push here is INSERT-only (ON CONFLICT DO NOTHING) and
-- never an update. A till that wants to correct a name it typed asks a
-- person with Backoffice access to fix it there.
CREATE TABLE customers (
    id          uuid PRIMARY KEY,
    tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name        text NOT NULL,
    phone       text,
    email       text,
    address     text,
    note        text,
    -- Digits only, no leading zero variance, no country-code punctuation —
    -- good enough to flag "these two rows probably answer the same phone,"
    -- which is all a duplicate BADGE needs. Never used to refuse a row: two
    -- honestly different customers can share a landline.
    phone_norm  text,
    email_norm  text,
    -- A merged-away customer is never deleted: its orders still name it, and
    -- deleting it would turn "who bought this" into a foreign key pointing
    -- at nothing. merged_into_id says "read me as that row instead" to
    -- anything doing the reading; nothing here resolves it automatically —
    -- see the domain package's own note on why resolution belongs at read
    -- time, never at write time.
    merged_into_id uuid,
    active      boolean NOT NULL DEFAULT true,
    sync_seq    bigint NOT NULL DEFAULT 0,
    deleted_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    CONSTRAINT customers_name_length    CHECK (length(name) <= 120),
    CONSTRAINT customers_phone_length   CHECK (phone IS NULL OR length(phone) <= 32),
    CONSTRAINT customers_email_length   CHECK (email IS NULL OR length(email) <= 255),
    CONSTRAINT customers_address_length CHECK (address IS NULL OR length(address) <= 255),
    CONSTRAINT customers_note_length    CHECK (note IS NULL OR length(note) <= 500),
    -- A row can point at another row to say "read me as that one instead,"
    -- but never at itself — a one-hop cycle would make every reader that
    -- follows merged_into_id loop forever.
    CONSTRAINT customers_not_self_merged CHECK (merged_into_id IS NULL OR merged_into_id <> id),
    CONSTRAINT customers_merge_context_fk
        FOREIGN KEY (tenant_id, merged_into_id) REFERENCES customers (tenant_id, id)
);

-- Non-unique on purpose: this is a duplicate BADGE, not a duplicate REFUSAL.
-- Two customers can legitimately share a phone number (a shared household
-- landline, a couple that gives the same number) and an import must not
-- reject a legitimate second row for that reason — Fase 2's own decision is
-- "flag it, let a person merge if it really is the same customer."
CREATE INDEX customers_phone_norm_idx ON customers (tenant_id, phone_norm) WHERE phone_norm IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX customers_email_norm_idx ON customers (tenant_id, email_norm) WHERE email_norm IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX customers_tenant_name_idx ON customers (tenant_id, name);

CREATE INDEX customers_sync_feed_idx ON customers (tenant_id, sync_seq)
    INCLUDE (id, name, phone, email, address, note, active, deleted_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON customers TO justclick_app;

ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers FORCE  ROW LEVEL SECURITY;

CREATE POLICY customers_tenant_isolation ON customers
    USING (tenant_id = app.current_tenant_id())
    WITH CHECK (tenant_id = app.current_tenant_id());

-- +goose Down

DROP TABLE customers;
