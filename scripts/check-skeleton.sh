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
exit $rc
