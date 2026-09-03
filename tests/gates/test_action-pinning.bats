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

  # 오너/레포 축 — 위 정규식은 `@40hex` 형태만 재고 `@` 앞 오너는 무제한이라, 오너를 통째로
  # 공격자 포크로 갈아치우고 그 포크의 유효한 40-hex를 적으면 통과한다(untouched-a-2).
  # allowlist(⊆) — 액션 제거는 정당한 변경이라 등식이 아니라 상한만 강제. 신규 서드파티
  # 액션을 도입하면 이 목록을 같은 커밋에서 갱신할 것(형제 관용구: test_app-token-sha-ssot.bats).
  CANON_ACTIONS=$'actions/checkout\nactions/create-github-app-token\nactions/download-artifact\nactions/setup-node\nactions/upload-artifact\ndocker/build-push-action\ndocker/login-action\ndocker/setup-buildx-action\ndocker/setup-qemu-action\nhashicorp/setup-terraform\noven-sh/setup-bun\nrenovatebot/github-action'
  unknown=$(printf '%s\n' "$uses_lines" | grep -vE 'uses:[[:space:]]+\./' \
    | sed -E 's#.*uses:[[:space:]]+##; s#[@[:space:]].*##' | LC_ALL=C sort -u \
    | grep -vxF "$CANON_ACTIONS" || true)
  [ -z "$unknown" ]  # 비어야 통과. 디버깅: echo "$unknown"로 미승인 오너 확인
}
