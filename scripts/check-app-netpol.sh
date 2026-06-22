#!/usr/bin/env bash
# app-owned NetworkPolicy(apps/<app>/deploy/**)는 app-scoped 셀렉터 필수 — 적대 리뷰 Pass1 #2 + Pass2 #2.
# 공유 prod ns에서 빈/광범위 podSelector는 무관 앱 트래픽에 영향(blast radius)을 준다.
# 차트 selectorLabels: app.kubernetes.io/name=차트명(전 앱 공유·비유니크), app.kubernetes.io/instance=Release명(유니크).
# → podSelector.matchLabels에 app.kubernetes.io/instance=<app>(디렉토리명) 존재·일치 필수(name-only/빈 셀렉터 금지).
# 인-레포 앱 0이면 스캔 0건=통과(첫 앱부터 강제되는 계약). yq만(버전 무관). bash 3.2 호환. shellcheck clean.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
done < <(grep -rlE '^kind:[[:space:]]*NetworkPolicy' apps --include='*.yaml' 2>/dev/null || true)
if [ -n "$viol" ]; then
  echo "FAIL: app-owned NetworkPolicy는 app-scoped 셀렉터(app.kubernetes.io/instance=<app>) 필수 — 빈/name-only/불일치 금지:"
  printf '%s' "$viol"
  exit 1
fi
echo "check-app-netpol OK (${count} app-owned NetworkPolicy 검사, 위반 0)"
