#!/usr/bin/env bash
# app-owned NetworkPolicy(apps/<app>/deploy/**)는 app-scoped 셀렉터 필수 — 적대 리뷰 Pass1 #2 + Pass2 #2.
# 공유 prod ns에서 빈/광범위 podSelector는 무관 앱 트래픽에 영향(blast radius)을 준다.
# 차트 selectorLabels(platform/charts/app/templates/_helpers.tpl의 `app.selectorLabels`):
# app.kubernetes.io/name=차트명(전 앱 공유·비유니크) + **app.homelab/instance**=Release명(유니크).
# 표준 app.kubernetes.io/instance는 ArgoCD 예약 라벨이라 의도적으로 회피했다(같은 helper 주석 —
# 값 아닌 '존재'만으로 리소스 트리에서 제외).
# → podSelector.matchLabels에 **차트 인스턴스 라벨**=<app>(디렉토리명) 존재·일치 필수(name-only/빈 셀렉터 금지).
# ⚠️ 그 키를 **리터럴로 손에 들지 않는다** — 예전 판은 app.kubernetes.io/instance를 강제했고 그 키는
#    차트가 내지 않으므로, 가드를 그대로 따라 쓴 app-owned netpol은 아무 파드도 선택하지 못했다
#    (2026-09-03 실측: 차트 실제 키를 쓴 픽스처는 거부되고, 차트가 내지 않는 키를 쓴 픽스처는 통과했다).
#    이제 헬퍼 블록에서 **파생**한다 — 앵커는 키 이름이 아니라 값 `{{ .Release.Name }}`이다(키 이름을
#    앵커로 쓰면 개명 한 번에 파생이 조용히 0건이 된다). 파생 실패는 fail-closed.
#    차트 쪽 등식은 platform/charts/app/tests/test_route.bats가 렌더 산출물에서 같은 키를 단언한다.
# netpol 미선언(0건)은 통과지만 **매니페스트 열거 0건은 실패**(scan-floor — 아래 참조).
# yq만(버전 무관). bash 3.2 호환. shellcheck clean.
set -euo pipefail
# 프롤로그(LC_ALL=C·ROOT 기본값·scan-floor)는 guard_init(scripts/lib/guard.sh)이 소유한다.
# 스캔 대상 트리는 --root로 바꾼다(픽스처) — 워커는 스크립트 위치 기준이라 분리된다
# (check-image-pins.sh·check-app-deploy.sh와 같은 --root 규약).
# shellcheck source=scripts/lib/guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
guard_init check-app-netpol
# 스크립트 위치 — 차트 헬퍼·워커는 **스캔 대상 트리(--root)가 아니라 여기** 기준이다.
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
# 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(kernel-followups 03 — 구 env 폐지).
take_floors "check-app-netpol:manifests" "$@" || exit $?
set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"
SCOPE_NARROWED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; SCOPE_NARROWED=1; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ── 인스턴스 라벨 키 파생(차트 SSOT) ──────────────────────────────────────────────────────────
# `app.selectorLabels` 블록 안에서 값이 `{{ .Release.Name }}`인 줄의 키가 인스턴스 라벨이다.
HELPERS="$SCRIPT_DIR/../platform/charts/app/templates/_helpers.tpl"
if [ ! -r "$HELPERS" ]; then
  echo "check-app-netpol: 차트 헬퍼를 읽을 수 없다($HELPERS) — 키 파생 불가는 통과가 아니다." >&2
  exit 1
fi
INSTANCE_KEY="$(awk '
  /^\{\{- define "app\.selectorLabels"/ { inblk = 1; next }
  inblk && /^\{\{- end/                 { inblk = 0 }
  inblk && index($0, "{{ .Release.Name }}") > 0 { sub(/:.*/, "", $0); print $0; exit }
' "$HELPERS")"
# 라벨 키 문법(영숫자·`/`·`.`·`_`·`-`)만 받는다 — 빈 값·따옴표·공백은 파생 붕괴다(fail-closed).
case "$INSTANCE_KEY" in
  '' | *[!a-zA-Z0-9./_-]*)
    echo "check-app-netpol: 차트 selectorLabels에서 인스턴스 라벨 키를 파생하지 못했다(받은 값: '${INSTANCE_KEY}') — 판정 불가는 통과가 아니다." >&2
    exit 1 ;;
esac

cd "$ROOT"
# ⚠️ 열거를 **변수로** 받는다(프로세스 치환 금지 — 워커 실패를 set -e가 전파하지 않아,
# bun이 죽으면 0건 검사 후 `OK … 위반 0`이 찍혔다. 라이브 재현됨).
# 바닥값은 apps-manifests 스캔 건수에 건다 — NetworkPolicy 인스턴스 수가 아니다.
# 인-레포 앱이 netpol을 선언하지 않는 건 정당하지만(0건 통과가 계약), **매니페스트 열거가 0건인 건
# 붕괴다**. 두 0을 가르는 자리가 여기다.
# ⚠️ 값은 **붕괴 경계**이지 현재 도메인 크기가 아니다 — 앱당 추적 YAML은 2~3건이다
# (봉인본은 선택: `create-app --sealed` 미지정 = values+kustomization 2건, check-app-deploy의
# all-or-none 불변식이 그 상태를 정당하다고 명시한다). 스냅샷을 굳히면 봉인본 없는 앱 1개짜리
# 정당한 트리를 "열거 붕괴"로 오탐한다(적대 검토 실측). 래칫 아님.
# ⚠️ 바닥값 0 — 인-레포 배포 앱이 **0개**다(page #455 · trip-mate-api 이 PR로 철거). 앱이 0개인
#    동안은 매니페스트 열거 0건이 정당해 붕괴와 구별되지 않는다. 앱 온보딩 시 1로 되돌릴 것.
#    형제 가드도 같은 경계다 — check-app-deploy 기본 0 · check-image-pins :apps 기본 0.
MIN_SCAN="$(floor_of check-app-netpol:manifests 0)"

manifests="$(scan_enumerate check-app-netpol bun "$(dirname "${BASH_SOURCE[0]}")/../tools/lib/repo-walk.ts" --manifests apps-manifests --root "$ROOT")" || exit 1
scanned="$(scan_count "$manifests")"
# ⚠️ 픽스처 모드(--root)엔 바닥값을 적용하지 않는다 — 픽스처 트리는 정당하게 1~2건이다.
# 적용하면 red가 되는 건 **양성** 테스트(clean 셀렉터=통과 기대) 1건뿐이다 — 음성 3건은 단언이
# `-ne 0`이라 바닥값 exit 1도 만족해 green을 유지한다(실측 4 ok / 1 not ok).
# 즉 열거 붕괴를 실제로 증언하는 건 양성 2건(실-레포·clean 픽스처)뿐이다.
# 표기는 형제 가드(check-image-pins·check-floor-vocab·check-gh-secret-coverage 등)와 같은 방향이다 —
# 종전의 드모르간 역전형(`-eq 1 && ! floor_set`)은 등가이지만 읽는 사람이 매번 등가를 다시 풀어야 했다.
if [ "$SCOPE_NARROWED" -eq 0 ] || floor_set check-app-netpol:manifests; then
  scan_floor check-app-netpol:manifests "$scanned" "$MIN_SCAN" || exit 1
else
  # 바닥값은 면제하되 **신호는 낸다** — 신호가 아예 없으면 06이 "좁혀진 호출"과 "가드 미실행"을
  # 구별할 수 없다. 건수(픽스처는 소수 · 실 트리는 기준선 근처)가 곧 그 판별자다.
  scan_signal check-app-netpol:manifests "$scanned"
fi

netpol_files=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  # 프리필터는 인용 표기를 관용한다(형제 check-app-deploy.sh:64,67,94와 같은 표기) — `kind: "NetworkPolicy"`는
  # 합법 YAML이고 k8s에도 동일 의미라 kustomize/ArgoCD가 정상 적용하지만, 무관용 리터럴은 그 파일을
  # 후보에서 통째로 빠뜨려 뒤의 yq 판정(:정확한 select(.kind==…))에 도달조차 못 시킨다.
  if grep -qE '^kind:[[:space:]]*["'"'"']?NetworkPolicy["'"'"']?[[:space:]]*(#.*)?$' "$p" 2>/dev/null; then netpol_files="${netpol_files}${p}"$'\n'; fi
done <<< "$manifests"

viol=""
count=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  app="$(echo "$f" | cut -d/ -f2)"   # apps/<app>/deploy/...
  while IFS= read -r inst; do
    count=$((count + 1))
    [ "$inst" = "$app" ] && continue
    viol="${viol}  ${f}: NetworkPolicy podSelector ${INSTANCE_KEY}='${inst}' (앱 '${app}'와 불일치/비유니크/빈 셀렉터)"$'\n'
  done < <(yq ea "select(.kind==\"NetworkPolicy\") | .spec.podSelector.matchLabels.\"${INSTANCE_KEY}\" // \"\"" "$f")
done <<< "$netpol_files"
# ⚠️ **열거 건수와 불변식 평가 횟수는 다른 수다.** 마커를 하나만 내면 "매니페스트 6건 스캔"이
#    증언되는데 정작 셀렉터 불변식은 0회 평가된 상태가 초록으로 통과한다 — 티켓 08이 잡으려던
#    vacuous green이 마커 계층에서 재현되는 자리다. 두 수를 **다른 라벨로** 낸다.
#    (netpols=0은 정당할 수 있다 — 앱 소유 NetworkPolicy가 아직 없다는 뜻이다. 그래서 바닥값은
#     manifests에만 걸고 여기엔 걸지 않는다. 중요한 건 "몇 번 평가됐나"가 보이는 것이다.)
scan_signal check-app-netpol:netpols "$count"
if [ -n "$viol" ]; then
  echo "FAIL: app-owned NetworkPolicy는 app-scoped 셀렉터(${INSTANCE_KEY}=<app>) 필수 — 빈/name-only/불일치 금지:"
  printf '%s' "$viol"
  exit 1
fi
echo "check-app-netpol OK (매니페스트 ${scanned}건 스캔 · app-owned NetworkPolicy ${count}건 검사, 위반 0)"
