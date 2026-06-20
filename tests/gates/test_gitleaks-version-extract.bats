#!/usr/bin/env bats
# gitleaks 버전 추출이 라인오프셋(grep -A2) 아니라 yq 구조 쿼리인지. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "yq extracts gitleaks rev structurally (line-offset independent, no hardcoded version)" {
  command -v yq >/dev/null || skip "yq 미설치(CI setup-toolchain가 제공)"
  TMP="$(mktemp -d)"
  # gitleaks 블록을 일부러 첫 위치가 아니게(앞에 다른 repo) + 임의 버전 — 라인오프셋 의존이면 깨짐.
  # 실제 .pre-commit-config 버전을 하드코딩하지 않음(F5: 제2 SSOT·bump red 회피).
  printf '%s\n' 'repos:' \
    '  - repo: https://github.com/pre-commit/pre-commit-hooks' \
    '    rev: v4.5.0' \
    '    hooks:' \
    '      - id: end-of-file-fixer' \
    '  - repo: https://github.com/gitleaks/gitleaks' \
    '    rev: v9.9.9' \
    '    hooks:' \
    '      - id: gitleaks' > "$TMP/.pre-commit-config.yaml"
  run bash -c "yq '.repos[] | select(.repo == \"https://github.com/gitleaks/gitleaks\") | .rev' '$TMP/.pre-commit-config.yaml' | sed 's/^v//'"
  [ "$status" -eq 0 ]
  [ "$output" = "9.9.9" ]   # 픽스처 임의 버전 — 실제 버전 무관(구조 추출 증명)
}

@test "ci.yaml gitleaks step no longer uses grep -A2 line-offset extraction" {
  run grep -nE "grep -A2 'gitleaks/gitleaks'" .github/workflows/ci.yaml
  [ "$status" -ne 0 ]
  run grep -Fq 'select(.repo' .github/workflows/ci.yaml
  [ "$status" -eq 0 ]
}
