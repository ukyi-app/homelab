#!/usr/bin/env bats
# build.yaml은 telegram-notify로 빌드 결과를 알린다(source=배포, if: always()).
# ⚠️ 중간 단언은 [ ]만.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  BUILD="$ROOT/.github/workflows/build.yaml"
}

@test "build.yaml invokes the telegram-notify composite" {
  grep -q './.github/actions/telegram-notify' "$BUILD"
}

# ⚠️ **구조 판정.** 무앵커 `grep -q 'if: always()'`는 그 함정을 *설명하는* 주석(build.yaml:154)이
#    토큰을 자급하므로, 조건을 성공-only로 뒤집는 편집에 증인이 없다. 실측 2026-09-03:
#    build.yaml:156을 `if: success()`로 바꿔도 이 파일이 4/4 green이었고 레포 전역에 대체 증인이
#    0건이다(telegram-callsites·workflow-readiness는 전부 skip된 job 축). build.yaml은 pg-tools·
#    skopeo의 GHCR push 경로라, 알림이 성공에서만 나가면 push 실패가 Actions UI에만 묻힌다.
#    선례: tests/gates/test_ci-build.bats:16-24(줄번호 grep → .jobs.build.steps[] 구조 비교).
@test "build.yaml notify step runs on always() so failures are visible" {
  run yq -e '.jobs.build.steps[] | select((.uses // "") | test("telegram-notify")) | .if' "$BUILD"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qx 'always()'
}

@test "build.yaml notify uses the deploy source label and job.status" {
  grep -q 'source: 배포' "$BUILD"
  grep -q 'status: ' "$BUILD"
  grep -q 'job.status' "$BUILD"
}

@test "build notify source label is a member of the notify.sh enum" {
  # notify.sh enum 건초더미에 '배포'가 있어야 한다(dead label 송신 차단).
  grep -q ' 배포 ' "$ROOT/.github/actions/telegram-notify/notify.sh"
}
