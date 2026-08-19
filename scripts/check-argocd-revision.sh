#!/usr/bin/env bash
# ArgoCD **자기레포** 리비전 핀 정합 가드 — 이 레포를 소스로 삼는 모든 ArgoCD 참조가 같은 브랜치를
# 가리키는지, 그리고 (CI에서 main으로 들어갈 때) 그 값이 main인지 강제한다.
#
# 왜: `targetRevision`/`revision`이 **15곳**에 흩어져 있다(아래 열거는 파생이다 — 이 수치는 주석이지 계약이
# 아니다). NUC 이전은 마이그레이션 브랜치에서 이 값을 브랜치 이름으로 바꾸는데, 그 브랜치가 main에
# 그대로 머지되면 **라이브 클러스터의 ArgoCD가 죽은 브랜치를 따라간다**(Application 23개 동시 표류).
# 되돌리기는 쉽지만 그 사이가 장애다. 부분 편집(일부만 바꾸고 일부는 main에 남음)도 같은 클래스다 —
# ApplicationSet의 git generator는 `targetRevision`이 아니라 `revision`이라 특히 빠뜨리기 쉽다.
#
# 두 검사는 **의도적으로 분리**돼 있다:
#   (A) 정합  — 자기레포 참조 전건이 **같은** 값. 인자 없이 항상 검사한다. 마이그레이션 브랜치에서도 green.
#   (B) 고정  — 그 값이 EXPECT_REVISION과 일치. env가 비어 있으면 **건너뛴다**.
# 왜 (B)가 무인자 기본이 아닌가: `tests/gates/test_scan-floor.bats`가 `scripts/*.sh`를 **무인자로 실행해
# rc=0 + 정적 라벨 전건 방출**을 요구한다. (B)를 기본으로 켜면 마이그레이션 브랜치에서 이 가드뿐 아니라
# **scan-floor 게이트까지** red가 되어 그 브랜치의 gate를 통째로 못 쓴다(= G4 ArgoCD 수렴 증명 불가).
# ci.yaml이 main 진입 시에만 EXPECT_REVISION을 채운다.
#
# ⚠️ 자기레포 판정은 **정규화 후 비교**다. 리터럴 URL 문자열 대조는 `.git` 접미사 하나로 눈이 먼다 —
#    ArgoCD는 두 스펠링을 같은 repo로 취급하고, 이 레포의 `renovate.json`도 자기참조 패키지명으로 두
#    스펠링을 나란히 열거한다. 적대 검증에서 비-.git 표기 + 브랜치 값으로 바꾼 트리가 **초록으로 통과**했다.
# ⚠️ 앵커는 `platform/argocd/root/root-app.yaml`의 repoURL이다 — `scripts/bootstrap.sh`가 워킹트리에서
#    직접 apply하는 GitOps 진입점이라 **정의상** 자기레포다. `git remote get-url origin`은 쓰지 않는다:
#    actions/checkout이 `.git` 없는 URL을 심고 포크 CI에서 self가 어긋난다.
# ⚠️ 열거는 모양을 세지 않고 **재귀 하강**한다(`repoURL`을 가진 모든 맵 노드). Application 단일/다중
#    소스, ApplicationSet template의 단일/다중 소스, git generator — 넷을 따로 적으면 다섯 번째 모양이
#    생겼을 때 조용히 빠진다(matrix/merge generator 중첩이 실재하는 경로다).
# yq만(버전 무관). bash 3.2 호환. shellcheck clean.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ROOT_OVERRIDDEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; ROOT_OVERRIDDEN=1; shift 2 ;;
    --expect) EXPECT_REVISION="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
cd "$ROOT"
# shellcheck source=scripts/lib/scan-floor.sh
. "$HERE/lib/scan-floor.sh"
EXPECT_REVISION="${EXPECT_REVISION:-}"
# ⚠️ 값은 **붕괴 경계**이지 현재 도메인 크기(15)가 아니다. 스냅샷을 굳히면 Application 하나를 정당하게
#    철거할 때마다 red가 난다. 경계의 근거: GitOps 척추 — root-app(1) + argocd-app(1) + appset(소스 4 +
#    generator 2 = 6) = 8은 이 레포가 GitOps 레포인 한 구조적으로 사라지지 않는다. 10은 거기에
#    `root/apps/*` 변동 여유를 두면서도 1/3 이상 붕괴는 잡는다. 래칫 아님.
MIN_REFS="${ARGOCD_REVISION_MIN_REFS:-10}"

# URL 정규화 — 스킴·ssh 형태·후행 슬래시·`.git` 접미사·대소문자를 흡수해 host/path만 남긴다.
norm_url() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E \
    -e 's#^[a-z0-9+.-]+://##' \
    -e 's#^[^/@]+@##' \
    -e 's#^([^/:]+):#\1/#' \
    -e 's#/+$##' \
    -e 's#\.git$##'
}

# ── 앵커: 자기레포 URL을 GitOps 진입점에서 파생한다 ─────────────────────────────────────────
ANCHOR="platform/argocd/root/root-app.yaml"
# ⚠️ `|| true` 금지 — yq 실패를 삼키면 SELF가 빈 문자열이 되고 자기레포 참조가 0건이 되어 조용히 초록이다.
# ⚠️ 여기 `[ -f "$ANCHOR" ]` 선검사를 두지 않는다 — 파일이 없으면 아래 yq가 비-0으로 죽어 같은 자리에서
#    잡힌다. 역방향 뮤테이션에서 그 선검사를 지워도 전 테스트가 green이었다 = 지키는 것이 없는 규칙이다
#    (tools/lib/repo-walk.ts:142-145의 판정과 같다 — 죽은 규칙은 남기지 않는다).
anchor_raw="$(yq -r '.spec.source.repoURL' "$ANCHOR")" || {
  echo "FAIL: check-argocd-revision: 앵커를 읽지 못했다(부재/파싱 실패) — $ANCHOR" >&2; exit 1; }
case "$anchor_raw" in
  ""|null) echo "FAIL: check-argocd-revision: 앵커에 .spec.source.repoURL이 없다 — $ANCHOR" >&2; exit 1 ;;
esac
SELF="$(norm_url "$anchor_raw")"

# ── 열거: 후보를 추적 파일에서 파생 ─────────────────────────────────────────────────────────
# 선필터는 **도메인 그 자체**(`repoURL`)다. `argoproj.io`로 거르면 `argocd.argoproj.io/sync-wave`
# 어노테이션 때문에 Helm 템플릿(Go 템플릿이라 YAML 파서가 죽는다)까지 딸려와, 파싱 실패를
# 예외 처리하려다 결국 `|| true`로 rc를 삼키게 된다 — 그게 이 가드가 피하려는 바로 그 구멍이다.
# `repoURL`을 키로 가진 노드가 있는 파일은 반드시 그 문자열을 담으므로 빠뜨림이 없다(YAML 키).
# (`projects.yaml`의 AppProject는 `sourceRepos` 허용목록이라 리비전 핀이 아니다 — 정당하게 도메인 밖.)
candidates="$(scan_enumerate check-argocd-revision:files \
  git grep -lI --untracked -e 'repoURL' -- '*.yaml' '*.yml')" || exit 1

# 각 후보에서 `repoURL`을 가진 **모든** 맵 노드를 재귀로 뽑는다. 값은 targetRevision → revision 순으로,
# 둘 다 없으면 센티넬. 센티넬은 죽은 규칙이 아니다 — 아래에서 실제로 fail시키고 bats가 그것을 죽인다
# (ArgoCD는 리비전 미지정 시 HEAD를 따라가므로 핀이 아예 없는 자기레포 소스는 이 가드의 정반대 상태다).
EXPR='.. | select(tag == "!!map" and has("repoURL"))
      | [.repoURL, (.targetRevision // .revision // "«no-revision»")] | @tsv'

refs=""      # "<file>\t<url>\t<value>" 줄들 (자기레포만)
total=0      # repoURL 노드 전체(외부 포함) — 열거 자체가 살아있는지의 직교 증인
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # ⚠️ `|| true` 금지(위와 같은 이유). 파싱 불가 YAML 하나가 도메인에서 조용히 빠지는 자리다.
  out="$(yq -r "$EXPR" "$f")" || {
    echo "FAIL: check-argocd-revision: yq 파싱 실패 — $f" >&2; exit 1; }
  while IFS= read -r line; do
    # 다중 문서 출력의 `---` 구분자와 빈 줄을 버린다. 실 데이터 줄은 반드시 탭을 포함한다.
    printf '%s' "$line" | grep -q "$(printf '\t')" || continue
    url="${line%%	*}"; rev="${line#*	}"
    total=$((total + 1))
    [ "$(norm_url "$url")" = "$SELF" ] || continue
    refs="${refs}${f}	${url}	${rev}"$'\n'
  done <<< "$out"
done <<< "$candidates"

n_refs="$(printf '%s' "$refs" | grep -c . || true)"
scan_signal check-argocd-revision:repourls "$total"
scan_floor check-argocd-revision:refs "$n_refs" "$MIN_REFS" || exit 1

# ── (0) 핀 부재 ────────────────────────────────────────────────────────────────────────────
missing="$(printf '%s' "$refs" | grep -F '	«no-revision»' || true)"
if [ -n "$missing" ]; then
  echo "FAIL: check-argocd-revision: 자기레포 소스에 리비전 핀이 없다(ArgoCD가 HEAD를 따라간다):" >&2
  printf '%s\n' "$missing" | sed 's/^/  /' >&2
  exit 1
fi

# ── (A) 정합 — 전건이 같은 값 ───────────────────────────────────────────────────────────────
values="$(printf '%s' "$refs" | sed 's/.*	//' | LC_ALL=C sort -u)"
n_values="$(printf '%s' "$values" | grep -c . || true)"
if [ "$n_values" -ne 1 ]; then
  echo "FAIL: check-argocd-revision: 자기레포 리비전이 갈렸다(${n_values}종) — 부분 편집 skew:" >&2
  printf '%s' "$refs" | sed 's/^/  /' >&2
  exit 1
fi

# ── (B) 고정 — EXPECT_REVISION이 주어졌을 때만 ──────────────────────────────────────────────
if [ -n "$EXPECT_REVISION" ]; then
  printf '%s' "$values" | grep -qxF "$EXPECT_REVISION" || {
    echo "FAIL: check-argocd-revision: 리비전이 '${values}'인데 '${EXPECT_REVISION}'이어야 한다." >&2
    echo "  main에 마이그레이션 브랜치 핀이 들어가려는 중이다 — 머지하면 라이브 ArgoCD가 그 브랜치를 따라간다." >&2
    exit 1; }
fi

if [ "$ROOT_OVERRIDDEN" -eq 1 ]; then
  echo "check-argocd-revision OK [fixture] (자기레포 참조 ${n_refs}건 전부 '${values}')"
else
  echo "check-argocd-revision OK (repoURL 노드 ${total}건 중 자기레포 ${n_refs}건, 전부 '${values}'${EXPECT_REVISION:+ · main 고정 확인})"
fi
