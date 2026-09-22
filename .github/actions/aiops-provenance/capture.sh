#!/usr/bin/env bash
# AIOps 검사 출처 캡처 — actions/checkout 직후, HEAD·워크트리 변이 앞에서 실행한다.
#
# 여기서 고정한 source revision만 관측 `revision`이 된다. 실행 중 만든 제안 커밋(PR head)은
# 출처가 아니다 — 관측 composite는 proposal-revision 입력으로만 별도 필드에 싣는다.
#
# 판정 셋:
#   ① HEAD가 해석되고 40자 소문자 hex다.
#   ② 이 시점 워크트리가 오염되지 않았다(추적 변경·untracked 0) — 오염된 트리는 commit SHA가
#      실제 실행 코드를 기술하지 못하므로 캡처를 거부한다.
#   ③ main 도달성은 여기서 증명하지 않는다 — shallow checkout에는 main 이력이 없고, 권위 검사는
#      collector가 GitHub API compare로 수행한다(수집 계약 `artifact-revision-not-trusted-main`).
#      이 스크립트의 책임은 "checkout 시점의 출처를 봉인해 변이 앞에서 전달"까지다.
#
# main 재checkout 생산자는 source revision이 runHeadSha(GITHUB_SHA)와 다를 수 있다(bump 계열 —
# workflow_sha 고정). 그 둘을 같은 값으로 접는 일괄 fallback은 금지다.
set -euo pipefail

revision="$(git rev-parse --verify HEAD)" || {
  echo "::error::aiops-provenance: HEAD 해석 실패 — actions/checkout 뒤, HEAD 변이 앞에서 호출해야 한다"
  exit 1
}
case "$revision" in
  *[!0-9a-f]*)
    echo "::error::aiops-provenance: revision 형식 불량: '$revision'"
    exit 1
    ;;
esac
if [ "${#revision}" -ne 40 ]; then
  echo "::error::aiops-provenance: revision 길이 불량(${#revision}) — 40자 소문자 hex가 아니다"
  exit 1
fi

dirty="$(git status --porcelain --untracked-files=all)"
if [ -n "$dirty" ]; then
  echo "::error::aiops-provenance: 워크트리가 오염됐다 — 이 시점 revision은 실행 코드를 기술하지 못한다(캡처를 checkout 직후로 옮겨라)"
  printf '%s\n' "$dirty"
  exit 1
fi

{
  echo "source-revision=$revision"
  echo "run-head-sha=${RUN_HEAD_SHA:-}"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT 미설정 — GHA 밖 직접 실행은 출력 파일을 지정해야 한다}"
