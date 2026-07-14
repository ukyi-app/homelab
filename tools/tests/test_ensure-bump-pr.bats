#!/usr/bin/env bats
# ensure-bump-pr — bump PR 멱등 게이트(같은 bump = 같은 브랜치 = 열린 PR 1개).
#
# 회귀(test_tags=regression): 중복 bump PR 버그를 RED로 고정한다. bump-poll.yaml이 run마다
# 새 브랜치(bump-poll/<app>-<RUN_ID>)로 PR을 열고 main은 머지 전까지 옛 digest라, 같은 후보로
# 매 10분 새 PR이 난다(라이브: page sha-815abb… 11분에 PR 3개 — 1개만 머지, 나머지 충돌 잔류).
# 기대(수정 후): 신뢰하는 열린 PR이 있으면 skip, 그게 DIRTY면 rebuild.
#
# 보존(태그 없음): 신뢰 경계는 절대 넓히지 않는다 — 포크/타인 PR은 배포를 억제할 수 없고(공개 레포!),
# 잘못된 입력은 조용한 create로 흐르지 않는다(fail-closed).
#
# ⚠️ 중간 복합 단언 금지([ a ] && [ b ]는 bash 3.2 set -e에서 침묵 통과) → 한 줄에 [ ] 하나씩.
# ⚠️ @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1
  FX="$BATS_TEST_TMPDIR"
  APP="page"
  # 배포 핀 tag: sha- + 40 hex (라이브 중복 PR을 낸 그 커밋 형태)
  TAG="sha-815abb1$(printf '%033d' 0)"
  BRANCH="bump-poll/${APP}-${TAG}"
}

# writer App 작성자의 라이브 표기 — `gh pr list --json author`는 App을 `app/<slug>`로 준다
# (`<slug>[bot]`이 아니다. 실측: {"is_bot":true,"login":"app/ukyi-homelab-writer"}).
writer_author() { printf '{"is_bot":true,"login":"app/ukyi-homelab-writer"}'; }

# gh pr list --head <branch> --state open --json number,isCrossRepository,mergeStateStatus,author
# 의 **원시 스키마** 그대로 픽스처를 만든다(필드명이 틀리면 프로덕션에서 깨진다).
write_prs() { printf '%s' "$1" > "$FX/prs.json"; }

run_ensure() {
  run bun tools/ensure-bump-pr.ts --app "$APP" --tag "$TAG" --prs "$FX/prs.json"
}

# ---------------------------------------------------------------------------
# 회귀 — 현재 RED
# ---------------------------------------------------------------------------

# bats test_tags=regression
@test "an open same-repo writer PR for the same bump suppresses a duplicate create (skip)" {
  write_prs "[{\"number\":350,\"isCrossRepository\":false,\"mergeStateStatus\":\"CLEAN\",\"author\":$(writer_author)}]"
  run_ensure
  [ "$status" -eq 0 ]

  # 하네스 확인: 도구가 그 사실을 관측은 했는가(배선이 죽었다면 버그가 아니라 테스트 결함이다).
  echo "$output" | jq -e '.observed.trusted.number == 350' > /dev/null \
    || { echo "harness: 도구가 열린 PR 사실을 관측하지 못했다(observed 배선 확인)"; echo "$output"; false; }

  action="$(echo "$output" | jq -r '.action')"
  [ "$action" = "skip" ] || {
    echo "duplicate bump PR: ensure-bump-pr still says '$action' while PR #350 (same-repo, writer) already proposes ${BRANCH}"
    echo "--- output ---"; echo "$output"
    false
  }
  # skip은 어느 PR이 진행 중인지 지목해야 한다(호출부가 로그로 추적).
  echo "$output" | jq -e '.pr == 350' > /dev/null \
    || { echo "duplicate bump PR: skip must name the in-flight PR (#350)"; false; }
}

# bats test_tags=regression
@test "an open same-repo writer PR that went DIRTY is rebuilt, not duplicated (rebuild)" {
  # DIRTY 교착: 유일한 PR이 충돌나면 이후 폴링이 전부 skip → 깨끗한 대체 PR이 영영 안 생겨
  # 배포가 조용히 멈춘다(pr-sweeper는 DIRTY를 무시). 최신 main에서 브랜치를 재구축해야 한다.
  write_prs "[{\"number\":351,\"isCrossRepository\":false,\"mergeStateStatus\":\"DIRTY\",\"author\":$(writer_author)}]"
  run_ensure
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.observed.trusted.mergeStateStatus == "DIRTY"' > /dev/null \
    || { echo "harness: 도구가 DIRTY 상태를 관측하지 못했다"; echo "$output"; false; }

  action="$(echo "$output" | jq -r '.action')"
  [ "$action" = "rebuild" ] || {
    echo "duplicate bump PR: ensure-bump-pr still says '$action' while PR #351 (same-repo, writer) is DIRTY on ${BRANCH} — must rebuild the branch from main, not open another PR"
    echo "--- output ---"; echo "$output"
    false
  }
  echo "$output" | jq -e '.pr == 351' > /dev/null \
    || { echo "duplicate bump PR: rebuild must name the PR to refresh (#351)"; false; }
}

# ---------------------------------------------------------------------------
# 보존 — red baseline에서 이미 GREEN이어야 한다(수정 후에도 GREEN)
# ---------------------------------------------------------------------------

@test "no open PR for the branch creates the bump PR" {
  write_prs '[]'
  run_ensure
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "create"'
  echo "$output" | jq -e '.observed.trusted == null'
}

@test "a fork (cross-repo) PR on the same branch name is never trusted (still create)" {
  # 공개 레포 — 포크 PR은 같은 브랜치명 + 그럴듯한 본문을 아무나 올릴 수 있다. 이걸 신뢰하면
  # 포크 PR 하나로 배포를 무기한 억제할 수 있다(억제 = 공격 표면) → 신뢰 0.
  write_prs '[{"number":400,"isCrossRepository":true,"mergeStateStatus":"CLEAN","author":{"is_bot":false,"login":"drive-by"}}]'
  run_ensure
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "create"'
  echo "$output" | jq -e '.observed.trusted == null'
  echo "$output" | jq -e '.observed.prs[0].trusted == false'
}

@test "a same-repo PR authored by someone other than the writer App is not trusted (still create)" {
  write_prs '[{"number":401,"isCrossRepository":false,"mergeStateStatus":"CLEAN","author":{"is_bot":false,"login":"ukkiee"}}]'
  run_ensure
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "create"'
  echo "$output" | jq -e '.observed.trusted == null'
}

@test "the writer App is recognized in both gh (app/<slug>) and REST (<slug>[bot]) login forms" {
  # 표기 계약 고정: gh CLI는 `app/ukyi-homelab-writer`, REST/GraphQL은 `ukyi-homelab-writer[bot]`.
  # 한쪽만 인식하면 신뢰 판정이 조용히 무너져(=trusted 0) 중복 PR이 그대로 남는다.
  write_prs '[{"number":352,"isCrossRepository":false,"mergeStateStatus":"BLOCKED","author":{"is_bot":true,"login":"ukyi-homelab-writer[bot]"}}]'
  run_ensure
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.observed.trusted.number == 352'
}

@test "malformed PR JSON fails closed instead of silently creating a duplicate" {
  write_prs 'not json at all'
  run_ensure
  [ "$status" -ne 0 ]
  if echo "$output" | grep -q '"action"'; then
    echo "fail-closed 위반: 깨진 입력인데 판정을 냈다(조용한 create 금지)"; echo "$output"; false
  fi
}

@test "empty PR input fails closed (an empty read is not 'no open PRs')" {
  # 빈 출력은 "열린 PR 0건"이 아니라 조회 실패일 수 있다 → 조용히 create로 흘리면 버그 재현.
  write_prs ''
  run_ensure
  [ "$status" -ne 0 ]
  if echo "$output" | grep -q '"action"'; then
    echo "fail-closed 위반: 빈 입력인데 판정을 냈다"; echo "$output"; false
  fi
}

@test "a non-array top level fails closed (gh pr list --json returns an array)" {
  write_prs '{"number":350}'
  run_ensure
  [ "$status" -ne 0 ]
  if echo "$output" | grep -q '"action"'; then
    echo "fail-closed 위반: 배열이 아닌 입력인데 판정을 냈다"; echo "$output"; false
  fi
}

@test "a PR object missing the schema fields fails closed (field-name drift guard)" {
  # gh --json 필드명이 바뀌거나 오타가 나면(예: crossRepository) 조용히 trusted 0이 되어
  # 중복 PR이 되살아난다 → 스키마 위반은 판정하지 않는다.
  write_prs '[{"number":350,"crossRepository":false,"mergeStateStatus":"CLEAN","author":{"login":"app/ukyi-homelab-writer"}}]'
  run_ensure
  [ "$status" -ne 0 ]
  if echo "$output" | grep -q '"action"'; then
    echo "fail-closed 위반: 스키마 위반 입력인데 판정을 냈다"; echo "$output"; false
  fi
}

@test "the branch name is deterministic per bump (no RUN_ID — same bump converges to one branch)" {
  # 결정적 브랜치가 중복 PR 픽스의 토대다: run마다 브랜치가 달라지면 조회할 대상 자체가 없다.
  write_prs '[]'
  run_ensure
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg b "$BRANCH" '.branch == $b'
}

@test "ensure-bump-pr --help prints usage and exits 0" {
  run bun tools/ensure-bump-pr.ts --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "ensure-bump-pr"
  echo "$output" | grep -q -- "--prs"
}
