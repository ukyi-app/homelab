#!/usr/bin/env bats
# 디렉토리 지도 드리프트 가드 — AGENTS.md 지도의 scripts/ 행 앵커.
# ⚠️ README.md의 **platform 지도**는 여기 있지 않다: scripts/check-skeleton.sh가 소유한다(정방향 dir→표 +
#    역방향 표→dir + 열거 바닥값). 여기 있던 정방향-only 사본은 그 강한 쪽으로 흡수돼 제거됐다.
# bash 3.2: 단언은 [ ]/grep만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "AGENTS directory map includes a scripts/ row (tools vs scripts vs k3s-bootstrap boundary)" {
  # 라인번호 브리틀 회피 — 지도 테이블의 scripts/ 행 존재를 앵커로 검사. (@test 이름은 영어 — 한글 인코딩 깨짐)
  run grep -nE '^\| `scripts/`' AGENTS.md
  [ "$status" -eq 0 ]
}
