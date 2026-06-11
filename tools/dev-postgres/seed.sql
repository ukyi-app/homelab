-- 정제된 이너루프 시드. prod의 원본 행을 여기로 복사하는 것은 절대 금지.
-- 스키마 + 합성/익명화 데이터만. PII(연락처/신원) 컬럼 금지.
CREATE TABLE IF NOT EXISTS app_health_seed (
  id    bigserial PRIMARY KEY,
  label text NOT NULL,
  ok    boolean NOT NULL DEFAULT true
);
INSERT INTO app_health_seed (label) VALUES ('seed-row-1'), ('seed-row-2');
