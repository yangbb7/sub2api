-- Run with psql -v ON_ERROR_STOP=1 -f this-file against an empty test database.
-- All fixtures and migration changes are rolled back.
BEGIN;
CREATE TABLE groups (id integer PRIMARY KEY, models_list_config jsonb NOT NULL DEFAULT '{}');
INSERT INTO groups VALUES (1, '{"openai":["gpt-6-astra"]}');
\ir ../backend/migrations/234_model_allowlist_rolling_compat.sql
\ir ../backend/migrations/235_group_model_allowlist.sql
\ir ../backend/migrations/236_group_model_allowlist_repair.sql

DO $$
BEGIN
    IF (SELECT model_allowlist FROM groups WHERE id = 1) <> '{"openai":["gpt-6-astra"]}'::jsonb THEN
        RAISE EXCEPTION 'legacy data was not preserved';
    END IF;
END $$;

INSERT INTO groups (id, models_list_config) VALUES (2, '{"openai":["legacy"]}');
INSERT INTO groups (id, model_allowlist) VALUES (3, '{"openai":["new"]}');
UPDATE groups SET models_list_config = '{"openai":["rollback"]}' WHERE id = 1;
UPDATE groups SET model_allowlist = '{"openai":["updated"]}' WHERE id = 2;
UPDATE groups SET model_allowlist = '{}' WHERE id = 3;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM groups WHERE models_list_config IS DISTINCT FROM model_allowlist) THEN
        RAISE EXCEPTION 'mixed-version writes diverged';
    END IF;
    IF (SELECT model_allowlist FROM groups WHERE id = 1) <> '{"openai":["rollback"]}'::jsonb
       OR (SELECT models_list_config FROM groups WHERE id = 2) <> '{"openai":["updated"]}'::jsonb
       OR (SELECT models_list_config FROM groups WHERE id = 3) <> '{}'::jsonb THEN
        RAISE EXCEPTION 'mixed-version update or clear failed';
    END IF;
    BEGIN
        UPDATE groups SET model_allowlist = '{"new":1}', models_list_config = '{"old":1}' WHERE id = 1;
        RAISE EXCEPTION 'expected conflicting update to fail';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'conflicting group model allowlist updates' THEN RAISE; END IF;
    END;
END $$;

-- The compatibility migration also accepts a database already on v0.2.4.
DROP TABLE groups;
CREATE TABLE groups (id integer PRIMARY KEY, model_allowlist jsonb NOT NULL DEFAULT '{}');
INSERT INTO groups VALUES (1, '{"openai":["gpt-6-astra"]}');
\ir ../backend/migrations/234_model_allowlist_rolling_compat.sql
\ir ../backend/migrations/234_model_allowlist_rolling_compat.sql
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM groups WHERE models_list_config IS DISTINCT FROM model_allowlist)
       OR (SELECT models_list_config FROM groups WHERE id = 1) <> '{"openai":["gpt-6-astra"]}'::jsonb THEN
        RAISE EXCEPTION 'new-schema compatibility or replay failed';
    END IF;
END $$;
ROLLBACK;
