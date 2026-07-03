#!/usr/bin/env bats
# races-4: bump-poll의 plan(descendant/digest 증명)은 한 스냅샷 기준 — checkout main 후 push 사이
# main이 움직이면 stale 증명을 push할 수 있다. bump-tag.ts --expect-current(Phase 2 구축)로
# bump 직전 values의 현재 tag가 플래너가 본 from-tag와 같음을 재증명한다(불일치면 fail-closed).
# ⚠️ 중간 단언은 [ ]만. @test 이름은 영어.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  F="$ROOT/.github/workflows/bump-poll.yaml"
}

@test "bump-poll passes --expect-current to bump-tag after checkout main (TOCTOU guard)" {
  # 플래너 item의 from-tag(현재 배포 tag)를 추출해 bump-tag에 재증명용으로 넘긴다.
  grep -q -- "--expect-current" "$F"
  # bump-tag 호출과 같은 라인/스텝에 --digest와 함께 존재해야 한다(같은 명령)
  run grep -E 'bump-tag\.ts .*--expect-current|--expect-current.*bump-tag\.ts' "$F"
  [ "$status" -eq 0 ]
}

@test "bump-poll still checks out main fresh before each branch (snapshot reset)" {
  grep -q "git checkout main" "$F"
}

@test "expect-current is sourced from the planner snapshot, not re-read from live values.yaml (F2)" {
  # ⚠️ codex pass1 F2: checkout 후 values.yaml에서 재읽기하면 main이 움직여도 expect가 같이 움직여
  # 자기비교(no-op)가 된다. 플래너 스냅샷($item의 .current.tag)에서 와야 fail-closed가 실효한다.
  run grep -E 'expect=.*(yq|cat).*values\.yaml' "$F"
  [ "$status" -ne 0 ]
  run grep -E 'expect=.*\.current\.tag' "$F"
  [ "$status" -eq 0 ]
}

@test "bump-poll branches on the bespoke pin descriptor and passes --pin to bump-tag" {
  run grep -E "pin=\\\$\(echo .*jq -r '\.pin // empty'\)" "$F"
  [ "$status" -eq 0 ]
  run grep -E 'bump-tag\.ts .*--pin' "$F"
  [ "$status" -eq 0 ]
}

@test "bump-poll git-adds the planner writePath (unifies apps and bespoke lanes)" {
  run grep -E 'git add "\$writePath"' "$F"
  [ "$status" -eq 0 ]
}
