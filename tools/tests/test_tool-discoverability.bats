#!/usr/bin/env bats
# 툴링 발견성 — 읽기전용 진입점 make audit + `--help`는 stdout·exit 0 표준.
#
# 스코프는 **homelab 통합 CLI가 라우팅하는 전 표면**과 고빈도 단독 도구 2개다. 노드 열거는
# lib/verbs.ts VERBS 파생이라 손 목록이 없다(리프 + 그룹 노드 + top-level), 그리고 `mcp`는
# VERBS 밖(transport 모드)이지만 CLI가 라우팅하는 표면이므로 **명시 포함**한다.
#
# ⚠️ 도입 커밋(5f330c0, 2026-06-16)의 헤더는 「16개 도구 전체 --help/통합 CLI는 F3 P2」라는 유예를
#    적었다. 그 시점 tools/ 실행물은 16개였고 오늘은 34개다. 유예의 절반(통합 CLI)은 착지했지만
#    **유예를 회수하는 티켓은 존재한 적이 없다** — 그래서 여기서 정리한다:
#      · CLI TREE 전 노드로 넓힌다(이 파일의 아래 @test).
#      · tools/ 34개 전 도구 확장은 **유예가 아니라 기각**이다. 실측: `--help` 문자열을 어떤 형태로든
#        갖는 도구가 6개뿐이라 넓히면 red 28건이고, 그 28개는 대부분 워크플로가 고정 argv로 부르는
#        비대화형 산출물이다(사람이 --help를 구할 표면이 아니다). 발견성의 SSOT는 tools/README.md
#        로스터이고 그쪽은 check-doc-index가 강제한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(인코딩 함정).
bats_require_minimum_version 1.5.0

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "audit-orphans --help prints usage and exits 0" {
  run bun tools/audit-orphans.ts --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "audit-orphans"
  echo "$output" | grep -q -- "--ci"
}

@test "poll-ghcr --help prints usage and exits 0 (was: unknown-arg exit 2)" {
  run bun tools/poll-ghcr.ts --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "poll-ghcr"
  echo "$output" | grep -q -- "--root"
}

@test "make audit runs the read-only static drift audit" {
  run make -n audit
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "audit-orphans"
}

@test "every homelab CLI node answers --help on stdout with exit 0 and no stderr (leaves, groups, mcp, top-level)" {
  # 열거는 catalog 파생 — 손 목록이면 동사 추가가 조용히 게이트 밖으로 나간다.
  nodes="$(bun -e '
    import { VERBS } from "./tools/lib/verbs.ts";
    const leaves = VERBS.map((v) => v.path.join(" "));
    const groups = [...new Set(VERBS.filter((v) => v.path.length > 1).map((v) => v.path[0]))];
    // mcp는 transport 모드라 VERBS 밖이지만 CLI가 라우팅하는 표면이라 명시 포함한다.
    for (const n of [...leaves, ...groups, "mcp"]) console.log(n);
  ')"
  want="$(printf '%s\n' "$nodes" | grep -c .)"
  # 빈 열거 = red. 리프 10 + 그룹 3 + mcp = 14가 오늘의 실측이고, 바닥값은 붕괴만 잡는다.
  [ "$want" -ge 14 ]
  n=0
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    # ⚠️ 의도적 비인용 확장 — "db create"는 argv 두 토큰이어야 한다.
    # shellcheck disable=SC2086
    run --separate-stderr bun tools/homelab.ts $node --help
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ -z "$stderr" ]
    n=$(( n + 1 ))
  done <<EOF
$nodes
EOF
  # 상한 — 열거한 노드를 **전부** 돌았다(루프 붕괴 시 n < want로 red).
  [ "$n" -eq "$want" ]
  # top-level까지 같은 표준을 지킨다(노드 열거 밖이라 따로 잰다).
  run --separate-stderr bun tools/homelab.ts --help
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ -z "$stderr" ]
}
