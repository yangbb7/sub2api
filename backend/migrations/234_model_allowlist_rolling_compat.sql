-- Run before upstream 235 so the serving v0.2.1 instance and rollback image
-- can keep using models_list_config while v0.2.4 uses model_allowlist.
ALTER TABLE groups
    ADD COLUMN IF NOT EXISTS models_list_config JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS model_allowlist JSONB NOT NULL DEFAULT '{}'::jsonb;

UPDATE groups SET model_allowlist = models_list_config
 WHERE COALESCE(model_allowlist, '{}'::jsonb) = '{}'::jsonb
   AND COALESCE(models_list_config, '{}'::jsonb) <> '{}'::jsonb;
UPDATE groups SET models_list_config = model_allowlist
 WHERE models_list_config IS DISTINCT FROM model_allowlist;

CREATE OR REPLACE FUNCTION gateway_sync_group_model_allowlist()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF COALESCE(NEW.model_allowlist, '{}'::jsonb) = '{}'::jsonb THEN
            NEW.model_allowlist := COALESCE(NEW.models_list_config, '{}'::jsonb);
        END IF;
        NEW.models_list_config := NEW.model_allowlist;
    ELSIF NEW.model_allowlist IS DISTINCT FROM OLD.model_allowlist THEN
        IF NEW.models_list_config IS DISTINCT FROM OLD.models_list_config
           AND NEW.models_list_config IS DISTINCT FROM NEW.model_allowlist THEN
            RAISE EXCEPTION 'conflicting group model allowlist updates';
        END IF;
        NEW.models_list_config := NEW.model_allowlist;
    ELSIF NEW.models_list_config IS DISTINCT FROM OLD.models_list_config THEN
        NEW.model_allowlist := NEW.models_list_config;
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS gateway_group_model_allowlist_compat ON groups;
CREATE TRIGGER gateway_group_model_allowlist_compat
BEFORE INSERT OR UPDATE ON groups
FOR EACH ROW EXECUTE FUNCTION gateway_sync_group_model_allowlist();
