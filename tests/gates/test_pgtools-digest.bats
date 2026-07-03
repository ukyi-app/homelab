#!/usr/bin/env bats
# PG 메이저 3-이미지 함정 가드: pg-tools:18-rclone 소비처 5-site가 단일 digest로 일관되게 핀됐는지.
# 부분 갱신(skew)이 PgDumpHedgeStale를 재발시킨다. 순수 grep(CI-safe). ⚠️ [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }
FILES="platform/cache/prod/backup-cronjob.yaml platform/cnpg/prod/ensure-role-password-job.yaml platform/cnpg/prod/restore-drill-cronjob.yaml platform/cnpg/prod/pgdump-hedge-cronjob.yaml"

@test "all pg-tools:18-rclone consumers pin one identical digest (major-skew guard)" {
  digests="$(grep -hoE 'pg-tools:18-rclone@sha256:[0-9a-f]{64}' $FILES | sort -u)"
  n="$(printf '%s\n' "$digests" | grep -c .)"
  [ "$n" -eq 1 ]
}

@test "each expected consumer site is present (5-site registry drift guard)" {
  run grep -cE 'pg-tools:18-rclone@sha256:[0-9a-f]{64}' platform/cache/prod/backup-cronjob.yaml
  [ "$output" -eq 2 ]
  for f in platform/cnpg/prod/ensure-role-password-job.yaml platform/cnpg/prod/restore-drill-cronjob.yaml platform/cnpg/prod/pgdump-hedge-cronjob.yaml; do
    run grep -cE 'pg-tools:18-rclone@sha256:[0-9a-f]{64}' "$f"; [ "$output" -eq 1 ]
  done
}
