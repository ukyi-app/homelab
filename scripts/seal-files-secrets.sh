#!/usr/bin/env bash
# files 컴포넌트 SealedSecret 2종 봉인(owner-local):
#   1) files-keys      : API 키 레지스트리 JSON(keys.json) — secret 파일마운트용
#   2) ghcr-pull(files): private GHCR pull dockerconfigjson(files ns 전용; prod 것은 strict-scope라 재사용 불가)
# 사용: set -a; . .env.secrets; set +a; make seal-files-secrets
#   .env.secrets 필요: GHCR_PULL_TOKEN(read:packages), FILES_KEYS_JSON(키 레지스트리 JSON, camelCase)
# 평문/해시는 stdout/로그에 절대 출력하지 않는다 — 봉인 파일만 산출.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CERT="tools/sealed-secrets-cert.pem"
NS="files"
: "${GHCR_PULL_TOKEN:?set GHCR_PULL_TOKEN in .env.secrets}"
: "${FILES_KEYS_JSON:?set FILES_KEYS_JSON in .env.secrets (키 레지스트리 JSON)}"
# 봉인 전 keys.json 계약 검증(camelCase·필수필드) — 오타/snake_case 조기 차단
printf '%s' "$FILES_KEYS_JSON" | jq -e 'type=="array" and all(.[]; has("id") and has("sha256") and has("service"))' >/dev/null \
  || { echo "seal-files-secrets: FILES_KEYS_JSON 형식 오류(배열·id/sha256/service 필수)" >&2; exit 1; }
[ -f "$CERT" ] || { echo "seal-files-secrets: $CERT 없음" >&2; exit 1; }
command -v kubeseal >/dev/null || { echo "seal-files-secrets: kubeseal 필요" >&2; exit 1; }

# 1) files-keys: keys.json을 stringData 단일 키로 → 파일마운트
{
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: files-keys\n  namespace: %s\ntype: Opaque\nstringData:\n  keys.json: |\n' "$NS"
  printf '%s\n' "$FILES_KEYS_JSON" | sed 's/^/    /'
} | kubeseal --cert "$CERT" --scope strict --format yaml > platform/files/prod/files-keys.sealed.yaml

# 2) files-ns ghcr-pull dockerconfigjson
user="$(gh api user --jq .login)"
kubectl create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username="$user" --docker-password="$GHCR_PULL_TOKEN" \
  --namespace "$NS" --dry-run=client -o yaml \
  | kubeseal --cert "$CERT" --scope strict --format yaml > platform/files/prod/ghcr-pull.sealed.yaml

echo "sealed -> platform/files/prod/{files-keys,ghcr-pull}.sealed.yaml (ns=$NS, scope=strict)"
