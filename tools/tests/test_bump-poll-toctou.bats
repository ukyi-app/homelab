#!/usr/bin/env bats
# races-4: bump-poll의 plan(descendant/digest 증명)은 한 스냅샷 기준 — 브랜치를 떼고 push하는 사이
# main이 움직이면 stale 증명을 push할 수 있다. bump-tag.ts --expect-current(Phase 2 구축)로
# 갱신 직전 값의 현재 tag가 플래너가 본 from-tag와 같음을 재증명한다(불일치면 fail-closed).
#
# ★ F-1 이관: 이 증인들의 대상은 **bump-poll.yaml의 셸 루프**였다. 항목 오케스트레이션이
# `tools/run-bump-plan.ts`(테스트된 러너)로 옮겨갔으므로 같은 문장을 러너 소스에 다시 건다 —
# 워크플로에서 사라졌다고 지우면 계약이 조용히 증발한다(호출부가 이사했을 뿐 계약은 그대로다).
# ⚠️ 여기 있는 건 **정적 절반**이다. 실행 증인은 `tools/tests/test_run-bump-plan.bats`가 진짜 git
#    worktree 위에서 갖는다:
#      · expect-current 실효(#1·#3) → "an item whose bump-tag fails BEFORE staging is fail-closed and
#        never reaches ensure": plan 스냅샷의 current.tag를 실제 파일과 어긋나게 주면 그 항목이 죽는다.
#        러너가 스냅샷 대신 라이브 파일을 다시 읽었다면 자기비교(no-op)가 돼 그 증인이 통과했을 것이다.
#      · 항목마다 깨끗한 main에서 시작(#2) → "the base main worktree is left untouched…"(main tip·트리 불변)
#        + "…EFFECTIVELY makes…"의 `main..HEAD == 1커밋` 단언.
#      · 베스포크 핀(#4) → "a bespoke pin item forwards --pin to bump-tag and commits the rewritten
#        inline pin": 커밋된 인라인 핀 스칼라 자체를 대조한다.
#      · writePath(#5) → "each item commits its own writePath+digest-exporter…".
# ⚠️ 중간 단언은 [ ]만. @test 이름은 영어.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  R="$ROOT/tools/run-bump-plan.ts"
  # 주석 제거 뷰 — 주석이 금지·존재 토큰을 **설명**하므로 산문 오탐을 막는다.
  RCODE="$BATS_TEST_TMPDIR/run-bump-plan.code.ts"
  sed 's#^[[:space:]]*//.*$##' "$R" > "$RCODE"
}

@test "the runner passes --expect-current to bump-tag for every item (TOCTOU guard)" {
  # 플래너 item의 from-tag(현재 배포 tag)를 갱신 도구에 재증명용으로 넘긴다.
  grep -q -- '"--expect-current"' "$RCODE"
  # 그 인자는 **bump-tag 호출 argv**에 있어야 한다(다른 데 떠 있으면 아무 일도 하지 않는다).
  run grep -nE 'btArgs.*"--expect-current"' "$RCODE"
  [ "$status" -eq 0 ]
}

@test "each item starts from a fresh worktree cut from base main (snapshot reset)" {
  # 항목마다 base(main)에서 **새 worktree + 새 브랜치**를 뗀다 — 앞 항목의 index/worktree를 물려받지 않는다
  # (옛 셸 루프의 `git checkout -f main` 강제 정리를 공간 격리가 대체했다).
  run grep -nE '"worktree",[[:space:]]*"add"' "$RCODE"
  [ "$status" -eq 0 ]
  run grep -nE '"-b",[[:space:]]*branch,[[:space:]]*base' "$RCODE"
  [ "$status" -eq 0 ]
  run grep -nE 'base[[:space:]]*=[[:space:]]*opts\["--base"\][[:space:]]*\?\?[[:space:]]*"main"' "$RCODE"
  [ "$status" -eq 0 ]
}

@test "expect-current is sourced from the planner snapshot, never re-read from the live tree (F2)" {
  # ⚠️ codex pass1 F2: 브랜치를 뗀 뒤 대상 파일에서 현재 tag를 **다시 읽으면**, main이 움직여도 expect가
  # 같이 움직여 자기비교(no-op)가 된다 → 가드가 죽는다. 반드시 플래너 스냅샷(item.current.tag)에서 온다.
  run grep -nE 'expect[[:space:]]*=[[:space:]]*item\.current\?\.tag' "$RCODE"
  [ "$status" -eq 0 ]
  # ★ 봉인: 러너가 읽는 파일은 **plan.json 하나뿐**이다. 대상 트리를 읽을 수단이 없으면 재읽기도 불가능하다.
  n="$(grep -oE 'readFileSync\(' "$RCODE" | wc -l | tr -d ' ')"
  [ "$n" -eq 1 ] || {
    echo "F2 회귀 위험: 러너의 파일 읽기가 ${n}곳이다(기대 1곳 — plan.json) —"
    echo "  대상 트리를 읽기 시작하면 expect가 라이브 값으로 미끄러져 TOCTOU 가드가 no-op이 된다."
    grep -nE 'readFileSync\(' "$RCODE"
    false
  }
  run grep -nE 'readFileSync\(planPath' "$RCODE"
  [ "$status" -eq 0 ]
}

@test "the runner branches on the bespoke pin descriptor and passes --pin to bump-tag" {
  run grep -nE 'pin[[:space:]]*=[[:space:]]*item\.pin' "$RCODE"
  [ "$status" -eq 0 ]
  run grep -nE 'btArgs\.push\("--pin",[[:space:]]*pin\)' "$RCODE"
  [ "$status" -eq 0 ]
}

@test "the runner git-adds the planner writePath (unifies apps and bespoke lanes)" {
  run grep -nE '"add",[[:space:]]*writePath,[[:space:]]*EXPORTER' "$RCODE"
  [ "$status" -eq 0 ]
}
