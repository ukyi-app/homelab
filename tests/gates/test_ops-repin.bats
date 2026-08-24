#!/usr/bin/env bats
# repin-ops-image 도구 가드(fixture — 라이브 무관). 이미지-중립: pg-tools·skopeo를 같은 도구가 재핀한다. ⚠️ [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  FX="$(mktemp -d)"; mkdir -p "$FX/platform/cache/prod" "$FX/platform/cnpg/prod" "$FX/platform/victoria-stack/prod"
  OLD="sha256:$(printf 'a%.0s' {1..64})"; NEW="sha256:$(printf 'b%.0s' {1..64})"
  # pg-tools 사이트(바닥값 5를 넘긴다): 4파일 + backup-cronjob에 2개 = 5
  for f in platform/cnpg/prod/ensure-role-password-job.yaml platform/cnpg/prod/restore-drill-cronjob.yaml platform/cnpg/prod/pgdump-hedge-cronjob.yaml; do
    printf 'image: ghcr.io/ukyi-app/pg-tools:18-rclone@%s\n' "$OLD" > "$FX/$f"
  done
  printf 'image: ghcr.io/ukyi-app/pg-tools:18-rclone@%s\ninit: ghcr.io/ukyi-app/pg-tools:18-rclone@%s\n' "$OLD" "$OLD" > "$FX/platform/cache/prod/backup-cronjob.yaml"
  # skopeo 사이트(바닥값 2): 소비자 2곳
  printf 'image: ghcr.io/ukyi-app/skopeo:alpine@%s\n' "$OLD" > "$FX/platform/victoria-stack/prod/digest-exporter.yaml"
  printf 'image: ghcr.io/ukyi-app/skopeo:alpine@%s\n' "$OLD" > "$FX/platform/victoria-stack/prod/gha-liveness-exporter.yaml"
  # ⚠️ 도구가 대상을 **레포에서 파생**하므로(하드코딩 목록 폐기 — D-1) 픽스처도 git 레포여야 한다.
  git -C "$FX" init -q
  git -C "$FX" add -A
}
teardown() { rm -rf "$FX"; }

@test "rejects malformed digest" {
  run bun tools/repin-ops-image.ts pg-tools:18-rclone "notadigest" --root "$FX"
  [ "$status" -ne 0 ]
}
@test "rejects an image key not in the catalog" {
  run bun tools/repin-ops-image.ts unknown:tag "$NEW" --root "$FX"
  [ "$status" -eq 2 ]
}
@test "repins every pg-tools site to the new digest" {
  run bun tools/repin-ops-image.ts pg-tools:18-rclone "$NEW" --root "$FX"
  [ "$status" -eq 0 ]
  run grep -rhoE 'pg-tools:18-rclone@sha256:[0-9a-f]{64}' "$FX"
  echo "$output" | grep -q "$NEW"
  echo "$output" | grep -qv "$OLD" || { echo "OLD pg-tools digest가 남았다"; false; }
}
@test "repins every skopeo site to the new digest (2-site image)" {
  run bun tools/repin-ops-image.ts skopeo:alpine "$NEW" --root "$FX"
  [ "$status" -eq 0 ]
  run grep -rhoE 'skopeo:alpine@sha256:[0-9a-f]{64}' "$FX"
  echo "$output" | grep -q "$NEW"
}
@test "repinning one image does not touch the other (per-image isolation)" {
  # pg-tools만 재핀 — skopeo 사이트는 OLD 그대로여야 한다.
  bun tools/repin-ops-image.ts pg-tools:18-rclone "$NEW" --root "$FX" >/dev/null
  run grep -rhoE 'skopeo:alpine@sha256:[0-9a-f]{64}' "$FX"
  echo "$output" | grep -q "$OLD"   # skopeo는 안 바뀜
}
@test "idempotent no-op when already pinned" {
  bun tools/repin-ops-image.ts pg-tools:18-rclone "$NEW" --root "$FX" >/dev/null
  run bun tools/repin-ops-image.ts pg-tools:18-rclone "$NEW" --root "$FX"
  [ "$status" -eq 0 ]; echo "$output" | grep -q "no-op"
}
@test "refuses to run when enumeration collapses (silent no-op guard)" {
  d="$BATS_TEST_TMPDIR/empty"; mkdir -p "$d"; git -C "$d" init -q
  run bun tools/repin-ops-image.ts pg-tools:18-rclone --root "$d" "sha256:$(printf '0%.0s' {1..64})"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "열거 붕괴"
}
