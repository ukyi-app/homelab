#!/usr/bin/env bats
# 전 third-party/reusable 액션 ref가 commit SHA(@40hex)로 핀됐는지 — 공급망 표면 0.
# 로컬 './' ref(컴포지트·reusable 워크플로)는 면제. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "every non-local action ref is pinned to a 40-hex commit SHA" {
  # uses: 라인 전수 → 로컬 './' 제외 → 나머지(third-party)는 @[0-9a-f]{40} 필수.
  # @vN·@main·@축약SHA 전부 잔존 0. 핀 뒤 '# vN' 주석은 @ 직후가 아니라 무관.
  bad=$(grep -rhnE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]' .github/workflows/ .github/actions/ \
        | grep -vE 'uses:[[:space:]]+\./' \
        | grep -vE 'uses:[[:space:]]+[^@[:space:]]+@[0-9a-f]{40}([[:space:]]|#|$)' || true)
  [ -z "$bad" ]      # 비어야 통과. 디버깅: echo "$bad"로 위반 라인 확인
}
