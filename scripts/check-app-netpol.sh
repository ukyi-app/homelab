#!/usr/bin/env bash
# app-owned NetworkPolicy(apps/<app>/deploy/**)는 app-scoped 셀렉터 필수 — 적대 리뷰 Pass1 #2 + Pass2 #2.
# 공유 prod ns에서 빈/광범위 podSelector는 무관 앱 트래픽에 영향(blast radius)을 준다.
# 차트 selectorLabels: app.kubernetes.io/name=차트명(전 앱 공유·비유니크), app.kubernetes.io/instance=Release명(유니크).
# → podSelector.matchLabels에 app.kubernetes.io/instance=<app>(디렉토리명) 존재·일치 필수(name-only/빈 셀렉터 금지).
# netpol 미선언(0건)은 통과지만 **매니페스트 열거 0건은 실패**(scan-floor — 아래 참조).
# yq만(버전 무관). bash 3.2 호환. shellcheck clean.
set -euo pipefail
# 워커(tools/lib/repo-walk.ts)는 이 스크립트의 실제 위치 기준으로 찾고, 스캔 대상 트리는 --root로
# 바꿀 수 있다(픽스처). 둘을 분리해야 픽스처 트리에 워커를 복사하지 않아도 된다 —
# check-image-pins.sh·check-app-deploy.sh와 같은 --root 규약.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ROOT_OVERRIDDEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; ROOT_OVERRIDDEN=1; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
cd "$ROOT"
# ⚠️ 열거를 **변수로** 받는다(프로세스 치환 금지 — 워커 실패를 set -e가 전파하지 않아,
# bun이 죽으면 0건 검사 후 `OK … 위반 0`이 찍혔다. 라이브 재현됨).
# 바닥값은 apps-manifests 스캔 건수에 건다 — NetworkPolicy 인스턴스 수가 아니다.
# 인-레포 앱이 netpol을 선언하지 않는 건 정당하지만(0건 통과가 계약), **매니페스트 열거가 0건인 건
# 붕괴다**. 두 0을 가르는 자리가 여기다.
# ⚠️ 값은 **붕괴 경계 1**이지 현재 도메인 크기(6)가 아니다 — 앱당 추적 YAML은 2~3건이다
# (봉인본은 선택: `create-app --sealed` 미지정 = values+kustomization 2건, check-app-deploy의
# all-or-none 불변식이 그 상태를 정당하다고 명시한다). 스냅샷을 굳히면 봉인본 없는 앱 1개짜리
# 정당한 트리를 "열거 붕괴"로 오탐한다(적대 검토 실측). 형제 가드도 같은 경계다 —
# APP_DEPLOY_MIN_SCAN=1 · check-image-pins MIN_SCAN_APPS=1. 래칫 아님.
# shellcheck source=scripts/lib/scan-floor.sh
. "$HERE/lib/scan-floor.sh"
MIN_SCAN="${APP_NETPOL_MIN_SCAN:-1}"

manifests="$(scan_enumerate check-app-netpol bun "$HERE/../tools/lib/repo-walk.ts" --manifests apps-manifests --root "$ROOT")" || exit 1
scanned="$(scan_count "$manifests")"
# ⚠️ 픽스처 모드(--root)엔 바닥값을 적용하지 않는다 — 픽스처 트리는 정당하게 1~2건이다.
# 적용하면 red가 되는 건 **양성** 테스트(clean 셀렉터=통과 기대) 1건뿐이다 — 음성 3건은 단언이
# `-ne 0`이라 바닥값 exit 1도 만족해 green을 유지한다(실측 4 ok / 1 not ok).
# 즉 열거 붕괴를 실제로 증언하는 건 양성 2건(실-레포·clean 픽스처)뿐이다.
if [ "$ROOT_OVERRIDDEN" -eq 1 ]; then
  # 바닥값은 면제하되 **신호는 낸다** — 신호가 아예 없으면 06이 "픽스처 호출"과 "가드 미실행"을
  # 구별할 수 없다. 건수(픽스처는 소수 · 실 트리는 기준선 근처)가 곧 그 판별자다.
  scan_signal check-app-netpol:manifests "$scanned"
else
  scan_floor check-app-netpol:manifests "$scanned" "$MIN_SCAN" || exit 1
fi

netpol_files=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if grep -qE '^kind:[[:space:]]*NetworkPolicy' "$p" 2>/dev/null; then netpol_files="${netpol_files}${p}"$'\n'; fi
done <<< "$manifests"

viol=""
count=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  app="$(echo "$f" | cut -d/ -f2)"   # apps/<app>/deploy/...
  while IFS= read -r inst; do
    count=$((count + 1))
    [ "$inst" = "$app" ] && continue
    viol="${viol}  ${f}: NetworkPolicy podSelector instance='${inst}' (앱 '${app}'와 불일치/비유니크/빈 셀렉터)"$'\n'
  done < <(yq ea "select(.kind==\"NetworkPolicy\") | .spec.podSelector.matchLabels.\"app.kubernetes.io/instance\" // \"\"" "$f")
done <<< "$netpol_files"
# ⚠️ **열거 건수와 불변식 평가 횟수는 다른 수다.** 마커를 하나만 내면 "매니페스트 6건 스캔"이
#    증언되는데 정작 셀렉터 불변식은 0회 평가된 상태가 초록으로 통과한다 — 티켓 08이 잡으려던
#    vacuous green이 마커 계층에서 재현되는 자리다. 두 수를 **다른 라벨로** 낸다.
#    (netpols=0은 정당할 수 있다 — 앱 소유 NetworkPolicy가 아직 없다는 뜻이다. 그래서 바닥값은
#     manifests에만 걸고 여기엔 걸지 않는다. 중요한 건 "몇 번 평가됐나"가 보이는 것이다.)
scan_signal check-app-netpol:netpols "$count"
if [ -n "$viol" ]; then
  echo "FAIL: app-owned NetworkPolicy는 app-scoped 셀렉터(app.kubernetes.io/instance=<app>) 필수 — 빈/name-only/불일치 금지:"
  printf '%s' "$viol"
  exit 1
fi
echo "check-app-netpol OK (매니페스트 ${scanned}건 스캔 · app-owned NetworkPolicy ${count}건 검사, 위반 0)"
