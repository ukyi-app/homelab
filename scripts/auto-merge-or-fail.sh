#!/usr/bin/env sh
# PR-first auto-merge fallback (races-6) — un-gated 직접 머지를 분기보호에만 의존하지 않는다.
# `gh pr merge --auto`는 이미 clean(체크 완료)인 PR엔 에러를 낸다(라이브 검증된 GitHub 계약).
# 그 폴백을 "PR이 이미 CLEAN일 때"로만 좁힌다: BLOCKED/BEHIND/UNKNOWN이면 시끄럽게 실패해
# required check `gate`를 우회한 직접 머지가 일어나지 않게 한다.
# 사용: GH_TOKEN 환경에서 scripts/auto-merge-or-fail.sh <branch>
set -eu

branch="${1:-}"
[ -n "$branch" ] || { echo "::error::auto-merge-or-fail: branch 인자 필수"; exit 2; }

# 1) 정상 경로: auto-merge 무장(gate 통과 시 GitHub가 머지). 성공하면 끝.
if gh pr merge --auto --squash "$branch"; then
  exit 0
fi

# 2) --auto가 거부됨 → 보통 "이미 clean이라 무장할 게 없음". mergeStateStatus로 확인 후에만 직접 머지.
state="$(gh pr view "$branch" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null || echo UNKNOWN)"
case "$state" in
  CLEAN)
    # gate가 이미 green인 PR — 직접 squash는 분기보호를 우회하지 않는다(required check 충족됨).
    gh pr merge --squash "$branch"
    ;;
  *)
    echo "::error::auto-merge-or-fail: PR '$branch' mergeStateStatus=$state — 직접 머지 거부 (gate 미통과/behind/충돌). 수동 확인 필요."
    exit 1
    ;;
esac
