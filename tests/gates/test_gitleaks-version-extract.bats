#!/usr/bin/env bats
# gitleaks 버전 추출이 라인오프셋(grep -A2) 아니라 yq 구조 쿼리인지. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "ci.yaml gitleaks step no longer uses grep -A2 line-offset extraction" {
  run grep -nE "grep -A2 'gitleaks/gitleaks'" .github/workflows/ci.yaml
  [ "$status" -ne 0 ]
  run grep -Fq 'select(.repo' .github/workflows/ci.yaml
  [ "$status" -eq 0 ]
}
