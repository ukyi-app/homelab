#!/usr/bin/env bash
# GHCR read 토큰(.env.secrets GHCR_PULL_TOKEN)을 observability NS dockerconfigjson SealedSecret(ghcr-read)로
# 봉인 — digest-exporter가 private GHCR 패키지(page·trip-mate-api)를 skopeo inspect하기 위한 read 자격.
# strict-scope라 prod ghcr-pull 재사용 불가(seal-files-secrets와 동일 사유). 회전 시 재실행 → 결과를 PR로.
set -euo pipefail
: "${GHCR_PULL_TOKEN:?set GHCR_PULL_TOKEN in .env.secrets}"
user="$(gh api user --jq .login)"
out="platform/victoria-stack/prod/ghcr-read.sealed.yaml"
kubectl create secret docker-registry ghcr-read \
  --docker-server=ghcr.io --docker-username="$user" --docker-password="$GHCR_PULL_TOKEN" \
  --namespace observability --dry-run=client -o yaml \
  | kubeseal --cert tools/sealed-secrets-cert.pem --scope strict --format yaml >"$out"
echo "sealed -> $out (ghcr-read, ns observability, dockerconfigjson)"
