#!/usr/bin/env bash
# owner-local teardown 래퍼 — 구 teardown reusable 워크플로의 안전 envelope를 로컬에 이식(A.5 F2, C-F1).
# clean-worktree 가드 → origin/main fetch → teardown/<target>-<ts> 전용 브랜치(fresh main 기반) 생성 →
# 툴(plan) → allowlist staging → PR(gh). App 토큰이 아니라 owner 본인 gh 자격(owner=admin).
# fresh main 기반 전용 브랜치라 stale main/무관 커밋이 teardown PR에 실리지 않는다(C-F1).
# purge(--delete-data)는 런북 절차로만. 사용: scripts/teardown.sh --app <name> | --resource <db|cache>:<name>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

DRY_RUN="${DRY_RUN:-0}"
ALLOWLIST="apps/ docs/memory-ledger.md infra/cloudflare/apps.json platform/"
BASE_REF="${TEARDOWN_BASE_REF:-origin/main}"
dirty="${TEARDOWN_DIRTY:-$([ -n "$(git status --porcelain)" ] && echo 1 || echo 0)}"
ts="${TEARDOWN_TS:-$(date +%Y%m%d%H%M%S)}"

mode=""; target=""
case "${1:-}" in
  --app) mode="app"; target="${2:-}" ;;
  --resource) mode="resource"; target="${2:-}" ;;
  *) echo "사용: $0 --app <name> | --resource <db|cache>:<name>" >&2; exit 2 ;;
esac
[ -n "$target" ] || { echo "대상 누락" >&2; exit 2; }

# clean-worktree 가드 — 전용 브랜치로 전환하기 전 미커밋 작업 보호
[ "$dirty" = "0" ] || { echo "거부: 워킹트리 dirty — 정리/스태시 후 재실행" >&2; exit 1; }

# 입력 형식 검증(validate-mutation 계약 재사용) + 툴 명령·제목·slug 결정
if [ "$mode" = "app" ]; then
  printf '{"app":"%s"}' "$target" >/tmp/td-payload.json
  node tools/validate-mutation.mjs --action teardown-app --payload-file /tmp/td-payload.json
  plan_cmd=(node tools/teardown-app.mjs --app "$target" --repo-root .)
  slug="teardown-app-${target}"
  title="chore: ${target} 앱 철거 (teardown-app)"
else
  printf '{"resource":"%s"}' "$target" >/tmp/td-payload.json
  node tools/validate-mutation.mjs --action teardown-resource --payload-file /tmp/td-payload.json
  kind="${target%%:*}"
  name="${target#*:}"
  plan_cmd=(node tools/teardown-resource.mjs "--${kind}" "$name" --repo-root .)
  slug="teardown-resource-${kind}-${name}"
  title="chore: ${target} retain tombstone (teardown-resource)"
fi
branch="teardown/${slug}-${ts}"

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] base: ${BASE_REF} (fresh fetch → FETCH_HEAD, F7)"
  echo "[dry-run] dedicated branch: ${branch}"
  echo "[dry-run] plan: ${plan_cmd[*]}"
  echo "[dry-run] staging allowlist: ${ALLOWLIST}"
  echo "[dry-run] PR title: ${title}"
  exit 0
fi

# fresh main 기반 전용 브랜치 — FETCH_HEAD로 분기(remote-tracking ref stale 엣지 회피, refspec/버전 무관 — C-F1·F7)
git fetch origin main
git switch -c "$branch" FETCH_HEAD
"${plan_cmd[@]}" | tee /tmp/td-plan.json
[ -n "$(git status --porcelain)" ] || { echo "변경 없음 — 멱등 no-op"; exit 0; }
echo "── 플랜(/tmp/td-plan.json) 검토 후 Enter로 PR 생성, Ctrl-C로 중단 ──"
read -r _
# shellcheck disable=SC2086  # ALLOWLIST는 의도적 단어 분할(없는 경로는 git이 무시)
git add $ALLOWLIST 2>/dev/null || true
git commit -m "$title"
git push -u origin "$branch"
gh pr create --base main --head "$branch" --title "$title" --body-file /tmp/td-plan.json
echo "PR 생성됨 — 머지=철거 승인."
