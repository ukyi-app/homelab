#!/usr/bin/env bats
# repin-pgtools 도구 가드(fixture — 라이브 무관). ⚠️ [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  FX="$(mktemp -d)"; mkdir -p "$FX/platform/cache/prod" "$FX/platform/cnpg/prod"
  OLD="sha256:$(printf 'a%.0s' {1..64})"; NEW="sha256:$(printf 'b%.0s' {1..64})"
  for f in platform/cache/prod/backup-cronjob.yaml platform/cnpg/prod/ensure-role-password-job.yaml platform/cnpg/prod/restore-drill-cronjob.yaml platform/cnpg/prod/pgdump-hedge-cronjob.yaml; do
    printf 'image: ghcr.io/ukyi-app/pg-tools:18-rclone@%s\n' "$OLD" > "$FX/$f"
  done
  printf 'image: ghcr.io/ukyi-app/pg-tools:18-rclone@%s\ninit: ghcr.io/ukyi-app/pg-tools:18-rclone@%s\n' "$OLD" "$OLD" > "$FX/platform/cache/prod/backup-cronjob.yaml"
}
teardown() { rm -rf "$FX"; }

@test "rejects malformed digest" {
  run bun tools/repin-pgtools.ts "notadigest" --root "$FX"
  [ "$status" -ne 0 ]
}
@test "repins every site to the new digest" {
  run bun tools/repin-pgtools.ts "$NEW" --root "$FX"
  [ "$status" -eq 0 ]
  run grep -rl "$OLD" "$FX"; [ -z "$output" ]   # OLD digest가 어느 파일에도 안 남음(재귀 grep은 파일별 라인)
  run grep -rhoE 'pg-tools:18-rclone@sha256:[0-9a-f]{64}' "$FX"
  echo "$output" | grep -q "$NEW"
}
@test "idempotent no-op when already pinned" {
  bun tools/repin-pgtools.ts "$NEW" --root "$FX" >/dev/null
  run bun tools/repin-pgtools.ts "$NEW" --root "$FX"
  [ "$status" -eq 0 ]; echo "$output" | grep -q "no-op"
}
