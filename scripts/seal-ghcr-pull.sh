#!/usr/bin/env bash
# GHCR read 토큰(.env.secrets GHCR_PULL_TOKEN)을 prod NS dockerconfigjson SealedSecret(ghcr-pull)로 봉인.
# 사용: set -a; . .env.secrets; set +a; make seal-ghcr-pull  (토큰 회전 시 재실행 → 결과를 PR로)
set -euo pipefail
: "${GHCR_PULL_TOKEN:?set GHCR_PULL_TOKEN in .env.secrets}"
user="$(gh api user --jq .login)"
out="platform/ghcr-pull/prod/ghcr-pull.sealed.yaml"
kubectl create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username="$user" --docker-password="$GHCR_PULL_TOKEN" \
  --namespace prod --dry-run=client -o yaml \
  | kubeseal --cert tools/sealed-secrets-cert.pem --scope strict --format yaml >"$out"
echo "sealed -> $out (ghcr-pull, ns prod, dockerconfigjson)"
