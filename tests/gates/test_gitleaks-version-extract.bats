#!/usr/bin/env bats
# gitleaks 버전 추출이 라인오프셋(grep -A2) 아니라 yq 구조 쿼리인지. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "ci.yaml gitleaks step no longer uses grep -A2 line-offset extraction" {
  run grep -nE "grep -A2 'gitleaks/gitleaks'" .github/workflows/ci.yaml
  # rc 2(파일 부재)를 통과로 읽지 않는다 — grep 무매치는 정확히 rc 1이다.
  [ "$status" -eq 1 ]
  run grep -Fq 'select(.repo' .github/workflows/ci.yaml
  [ "$status" -eq 0 ]
}
