-- Keep email verification explicit for deployments that predate the setting.
-- Only enable it automatically when SMTP is already configured; otherwise users
-- could be blocked from registration without any way to receive a code.

INSERT INTO settings (key, value)
SELECT
    'email_verify_enabled',
    CASE
        WHEN EXISTS (
            SELECT 1 FROM settings WHERE key = 'smtp_host' AND BTRIM(value) <> ''
        )
        AND EXISTS (
            SELECT 1 FROM settings WHERE key = 'smtp_password' AND BTRIM(value) <> ''
        )
        AND EXISTS (
            SELECT 1 FROM settings WHERE key = 'smtp_from' AND BTRIM(value) <> ''
        )
        THEN 'true'
        ELSE 'false'
    END
WHERE NOT EXISTS (
    SELECT 1 FROM settings WHERE key = 'email_verify_enabled'
);

UPDATE settings
SET value = 'true'
WHERE key = 'email_verify_enabled'
  AND value <> 'true'
  AND EXISTS (
      SELECT 1 FROM settings WHERE key = 'smtp_host' AND BTRIM(value) <> ''
  )
  AND EXISTS (
      SELECT 1 FROM settings WHERE key = 'smtp_password' AND BTRIM(value) <> ''
  )
  AND EXISTS (
      SELECT 1 FROM settings WHERE key = 'smtp_from' AND BTRIM(value) <> ''
  );
