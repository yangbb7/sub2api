-- Enable the invite rebate flow by default for existing deployments.
-- Email verification is only enabled automatically when SMTP is already configured;
-- otherwise registration would be blocked because users could not receive codes.

INSERT INTO settings (key, value)
VALUES ('affiliate_enabled', 'true')
ON CONFLICT (key) DO NOTHING;

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

