#!/usr/bin/env bats
# 전 third-party/reusable 액션 ref가 commit SHA(@40hex)로 핀됐는지 — 공급망 표면 0.
# 로컬 './' ref(컴포지트·reusable 워크플로)는 면제. ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "every non-local action ref is pinned to a 40-hex commit SHA" {
  # ⚠️ 열거 도메인 존재 + 바닥값이 먼저다. 실측: `.github/workflows`·`.github/actions`를 리네임하면
  # grep은 rc=2 + stderr로 죽는데 (a) `|| true`가 rc를, (b) 커맨드 치환이 stdout만 캡처해 stderr를
  # 삼켜 bad=""가 된다 → **134줄 전건 핀 검증과 0줄 검증의 출력이 바이트 단위로 동일**했다.
  # (형제 단언들이 쓰는 `run bash -c`는 bats가 stderr를 $output에 병합해 우연히 fail-loud가 되지만,
  #  커맨드 치환에는 그 우연한 보호조차 없다.) 이 파일은 third-party 액션 핀의 레포 유일 강제선이다 —
  # renovate의 github-actions manager는 비활성이고 다른 검사는 전부 단일 액션 한정이다.
  [ -d .github/workflows ]
  [ -d .github/actions ]
  uses_lines=$(grep -rhnE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]' .github/workflows/ .github/actions/ || true)
  n=$(printf '%s\n' "$uses_lines" | grep -c . || true)
  [ "$n" -ge 80 ]    # 현재 134줄(third-party 70) — 도메인 40% 축소를 견딘다. 래칫 아님
  # uses: 라인 전수 → 로컬 './' 제외 → 나머지(third-party)는 @[0-9a-f]{40} 필수.
  # @vN·@main·@축약SHA 전부 잔존 0. 핀 뒤 '# vN' 주석은 @ 직후가 아니라 무관.
  bad=$(printf '%s\n' "$uses_lines" \
        | grep -vE 'uses:[[:space:]]+\./' \
        | grep -vE 'uses:[[:space:]]+[^@[:space:]]+@[0-9a-f]{40}([[:space:]]|#|$)' || true)
  [ -z "$bad" ]      # 비어야 통과. 디버깅: echo "$bad"로 위반 라인 확인
}
