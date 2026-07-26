#!/usr/bin/env bash
# app-owned NetworkPolicy(apps/<app>/deploy/**)는 app-scoped 셀렉터 필수 — 적대 리뷰 Pass1 #2 + Pass2 #2.
# 공유 prod ns에서 빈/광범위 podSelector는 무관 앱 트래픽에 영향(blast radius)을 준다.
# 차트 selectorLabels: app.kubernetes.io/name=차트명(전 앱 공유·비유니크), app.kubernetes.io/instance=Release명(유니크).
# → podSelector.matchLabels에 app.kubernetes.io/instance=<app>(디렉토리명) 존재·일치 필수(name-only/빈 셀렉터 금지).
# 인-레포 앱 0이면 스캔 0건=통과(첫 앱부터 강제되는 계약). yq만(버전 무관). bash 3.2 호환. shellcheck clean.
set -euo pipefail
# 워커(tools/lib/repo-walk.ts)는 이 스크립트의 실제 위치 기준으로 찾고, 스캔 대상 트리는 --root로
# 바꿀 수 있다(픽스처). 둘을 분리해야 픽스처 트리에 워커를 복사하지 않아도 된다 —
# check-image-pins.sh·check-app-deploy.sh와 같은 --root 규약.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
cd "$ROOT"
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
done < <(bun "$HERE/../tools/lib/repo-walk.ts" --manifests apps-manifests --root "$ROOT" \
           | while IFS= read -r p; do grep -lE '^kind:[[:space:]]*NetworkPolicy' "$p" 2>/dev/null || true; done)
if [ -n "$viol" ]; then
  echo "FAIL: app-owned NetworkPolicy는 app-scoped 셀렉터(app.kubernetes.io/instance=<app>) 필수 — 빈/name-only/불일치 금지:"
  printf '%s' "$viol"
  exit 1
fi
echo "check-app-netpol OK (${count} app-owned NetworkPolicy 검사, 위반 0)"
