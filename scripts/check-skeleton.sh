#!/usr/bin/env bash
set -euo pipefail
dirs=(
  infra/cloudflare infra/github infra/tailscale infra/k3s-bootstrap
  platform/argocd/root platform/charts/app
  platform/traefik platform/cnpg platform/victoria-stack
  platform/adguard platform/cloudflared platform/tailscale
  platform/sealed-secrets platform/data-conn platform/cache
  platform/network-policies platform/namespaces
  apps tools docs/plans
)
rc=0
for d in "${dirs[@]}"; do
  if [ -d "$d" ]; then echo "OK  $d"; else echo "MISSING $d"; rc=1; fi
done

# bats 네이밍 컨벤션: 모든 추적 *.bats는 test_ 접두여야 한다(run-bats.sh 수집 글롭 전제).
# 미접두 bats는 단일 러너 수집에서 조용히 빠지므로 시끄럽게 실패시킨다. (grep no-match는 || true로 흡수)
unprefixed="$(git ls-files '*.bats' | grep -vE '(^|/)test_[^/]*\.bats$' || true)"
if [ -n "$unprefixed" ]; then
  echo "FAIL: test_ 접두 없는 bats (네이밍 컨벤션 위반):"
  echo "$unprefixed"
  rc=1
fi

# README 디렉토리 지도 드리프트 가드: 모든 platform 컴포넌트(charts 제외)가 README 지도에 나열돼야 한다.
# 새 컴포넌트 추가 시 지도 갱신을 강제(가상명·누락 차단). tools/tests/test_dirmap.bats와 동일 불변식.
# glob 루프(ls 파싱 회피 — SC2011). bash 3.2 안전.
for d in platform/*/; do
  c="$(basename "$d")"
  case "$c" in charts) continue;; esac
  if ! grep -q "$c" README.md; then echo "FAIL: README 디렉토리 지도에 platform 컴포넌트 누락: $c"; rc=1; fi
done

exit $rc
