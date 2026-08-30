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
  # confirm은 디스패처(UI)의 오발사 가드 — CLI는 이미 명시 명령+clean-worktree가 마찰이라 confirm=app 자동 주입(단일 계약 유지)
  printf '{"app":"%s","confirm":"%s"}' "$target" "$target" >/tmp/td-payload.json
  bun tools/validate-mutation.ts --action teardown-app --payload-file /tmp/td-payload.json
  plan_cmd=(bun tools/teardown-app.ts --app "$target" --repo-root .)
  slug="teardown-app-${target}"
  title="chore: ${target} 앱 철거 (teardown-app)"
else
  printf '{"resource":"%s"}' "$target" >/tmp/td-payload.json
  bun tools/validate-mutation.ts --action teardown-resource --payload-file /tmp/td-payload.json
  kind="${target%%:*}"
  name="${target#*:}"
  # teardown-resource는 모든 모드(retain/purge)에 --refs-verified attestation을 fail-closed로 강제한다(F1).
  # owner가 런북(docs/runbooks/teardown-resource.md) 수동 확인(사용 앱 grep + kubectl + 백업) 후 증거 id를
  # REFS_VERIFIED로 전달해야 한다 — 누락 시 즉시 거부(툴은 dry-run에도 요구하므로 래퍼도 선차단).
  REFS_VERIFIED="${REFS_VERIFIED:-}"
  [ -n "$REFS_VERIFIED" ] || { echo "거부: REFS_VERIFIED=<evidence-id> 필요 — 런북 수동 확인 후 증거 id 전달 (make teardown-resource RESOURCE=${target} REFS_VERIFIED=<id>)" >&2; exit 2; }
  plan_cmd=(bun tools/teardown-resource.ts "--${kind}" "$name" --refs-verified "$REFS_VERIFIED" --repo-root .)
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
# ── 스테이징 완전성 판정 [staged-completeness] ─────────────────────────────────────────────────
# 도구가 ALLOWLIST 천장 밖에 쓰면 아래 `git add`가 그 변경을 스테이징하지 않아 커밋에서 **조용히
# 유실**되고 PR이 부분 표면으로 열린다(형제 자리의 실사고: .github/actions/pr-first-commit/action.yml).
# ALLOWLIST는 **상한으로 남긴다** — 재는 것은 열거가 아니라 **잔여물**이다. 포함 판정은 `:(exclude)`
# pathspec으로 git에게 시킨다(아래 `git add $ALLOWLIST`와 같은 매처 — 두 번째 구현이 생기지 않는다).
# 판정은 `git add` **앞**이자 사람의 승인(read) 앞이다 — 뒤에 두면 pathspec 미매치와 구별할 수 없고,
# 승인 뒤에 두면 이미 승인한 플랜이 실패한다.
excl=""
# shellcheck disable=SC2086  # ALLOWLIST는 의도적 단어 분할
for p in $ALLOWLIST; do excl="$excl :(exclude)$p"; done
# shellcheck disable=SC2086  # excl은 pathspec 다중 인자 — 의도적 분할
residue="$(git status --porcelain --untracked-files=all -- . $excl)"
[ -z "$residue" ] || {
  echo "거부: ALLOWLIST 천장 밖 변경이 남는다 — 이대로 커밋하면 유실된다" >&2
  echo "$residue" >&2
  echo "선언된 ALLOWLIST: $ALLOWLIST" >&2
  exit 1
}
# ── [/staged-completeness] ────────────────────────────────────────────────────────────────────
echo "── 플랜(/tmp/td-plan.json) 검토 후 Enter로 PR 생성, Ctrl-C로 중단 ──"
read -r _
# 잔여물 판정이 앞에서 통과했으므로 여기서 남는 비-0은 **진짜 실패**다 — 옛 `2>/dev/null || true`는
# 그 실패(권한·인덱스 잠금·pathspec 미매치)까지 삼켜 빈 커밋으로 PR을 열 수 있었다.
# shellcheck disable=SC2086  # ALLOWLIST는 의도적 단어 분할
git add $ALLOWLIST
git commit -m "$title"
git push -u origin "$branch"
gh pr create --base main --head "$branch" --title "$title" --body-file /tmp/td-plan.json
echo "PR 생성됨 — 머지=철거 승인."
