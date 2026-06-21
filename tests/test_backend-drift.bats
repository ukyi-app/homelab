#!/usr/bin/env bats
# terraform backend는 root 안에 있어야 해 공유 불가 → _backend/backend.tf는 template, 각 root가 사본.
# 사본이 발산하면 거짓 SSOT → backend 블록(주석 제외) 일치 강제. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; cd "$ROOT" || exit 1; }

# backend 블록만 추출(주석/공백 제거) — terraform { backend "s3" { ... } }
blk() { grep -vE '^\s*#' "$1" | tr -d '[:space:]'; }

@test "all root backend.tf match the _backend template (no false-SSOT drift)" {
  tmpl="$(blk infra/_backend/backend.tf)"
  [ -n "$tmpl" ]
  for r in cloudflare github tailscale; do
    [ "$(blk infra/$r/backend.tf)" = "$tmpl" ] || { echo "FAIL: infra/$r/backend.tf가 _backend 템플릿과 발산"; false; }
  done
}
