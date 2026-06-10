-- Sanitized inner-loop seed. NEVER copy raw prod rows here.
-- Only schema + synthetic/anonymized data. No PII (contact/identity) columns.
CREATE TABLE IF NOT EXISTS app_health_seed (
  id    bigserial PRIMARY KEY,
  label text NOT NULL,
  ok    boolean NOT NULL DEFAULT true
);
INSERT INTO app_health_seed (label) VALUES ('seed-row-1'), ('seed-row-2');
