-- +goose Up
-- Retain 90 complete UTC days. Only children of this exact audit parent can
-- be removed; order/dedupe partitions are never candidates for this function.
-- +goose StatementBegin
CREATE FUNCTION app.prune_ingest_log() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE part record; cutoff date := (now() AT TIME ZONE 'UTC')::date - 90; removed integer := 0; newest date;
BEGIN
    PERFORM pg_advisory_xact_lock(741320031);
    FOR part IN
        SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid
        WHERE i.inhparent='public.ingest_log'::regclass
          AND c.relnamespace='public'::regnamespace
          AND c.relname ~ '^ingest_log_[0-9]{8}$'
    LOOP
        IF to_date(substring(part.relname from '^ingest_log_([0-9]{8})$'),'YYYYMMDD') < cutoff THEN
            EXECUTE format('SELECT max(received_date) FROM public.%I', part.relname) INTO newest;
            IF newest IS NULL OR newest < cutoff THEN
                EXECUTE format('DROP TABLE public.%I', part.relname);
                removed := removed + 1;
            END IF;
        END IF;
    END LOOP;
    DELETE FROM public.ingest_log_default WHERE received_date < cutoff;
    RETURN removed;
END $$;
-- +goose StatementEnd
REVOKE ALL ON FUNCTION app.prune_ingest_log() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.prune_ingest_log() TO justclick_unscoped;

-- +goose Down
DROP FUNCTION app.prune_ingest_log();
