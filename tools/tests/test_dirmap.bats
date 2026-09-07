#!/usr/bin/env bats
# 디렉토리 지도 드리프트 가드 — AGENTS.md 지도의 scripts/·tools/ 행 앵커.
# ⚠️ README.md의 **platform 지도**는 여기 있지 않다: scripts/check-skeleton.sh가 소유한다(정방향 dir→표 +
#    역방향 표→dir + 열거 바닥값). 여기 있던 정방향-only 사본은 그 강한 쪽으로 흡수돼 제거됐다.
#    AGENTS.md 지도에는 그 강한 쪽에 해당하는 소유자가 없어서, 이 파일이 최소 앵커를 진다.
# bash 3.2: 단언은 [ ]/grep만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "AGENTS directory map includes a scripts/ row (tools vs scripts vs k3s-bootstrap boundary)" {
  # 라인번호 브리틀 회피 — 지도 테이블의 scripts/ 행 존재를 앵커로 검사. (@test 이름은 영어 — 한글 인코딩 깨짐)
  run grep -nE '^\| `scripts/`' AGENTS.md
  [ "$status" -eq 0 ]
}

@test "AGENTS tools row exists and its check-doc-index claim is true (the guard really enumerates tools/lib)" {
  # 티켓 34 — AGENTS.md:15의 tools 행은 「top-level·`lib/`는 `.ts`」와 「산출물 로스터는 tools/README.md
  # (check-doc-index 강제)」를 한 문장에 담는다. 착지 전 그 주장은 거짓이었다: 레인 글롭 `tools/*.ts`는
  # 재귀하지 않아 tools/lib/*.ts를 한 파일도 열거하지 않았고, 그 거짓이 에이전트가 세션마다 처음
  # 로드하는 파일에 무증인으로 살았다.
  # 라인번호가 아니라 식별 토큰만 앵커한다(브리틀 회피는 이 파일의 설계 원칙이다).
  run grep -nE '^\| `tools/`' AGENTS.md
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "check-doc-index 강제"
  # 대조 — 그 주장이 참인가: 가드가 실제로 tools/lib을 열거한다.
  run grep -n 'tools/lib/\*\.ts' scripts/check-doc-index.sh
  [ "$status" -eq 0 ]
}
