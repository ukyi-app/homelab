#!/usr/bin/env bash
set -euo pipefail

# R2 access/secret key pairs are minted out-of-band as scoped R2 API tokens
# and provided via env (NOT terraform outputs).
: "${R2_PG_ACCESS_KEY:?set R2_PG_ACCESS_KEY}"
: "${R2_PG_SECRET_KEY:?set R2_PG_SECRET_KEY}"
# Alerting fan-out (consumed by M5 vmalert/Alertmanager).
: "${TELEGRAM_BOT_TOKEN:?set TELEGRAM_BOT_TOKEN}"
: "${TELEGRAM_CHAT_ID:?set TELEGRAM_CHAT_ID}"
: "${HEALTHCHECKS_URL:?set HEALTHCHECKS_URL}"
: "${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD}" # Grafana admin password (NEVER admin/admin)

CF_OUT=$(terraform -chdir=infra/cloudflare output -json)
TS_OUT=$(terraform -chdir=infra/tailscale output -json)

TUNNEL_TOKEN=$(jq -r '.tunnel_token.value' <<<"$CF_OUT")
R2_ENDPOINT=$(jq -r '.r2_account_endpoint.value' <<<"$CF_OUT")
TS_ID=$(jq -r '.operator_oauth_client_id.value' <<<"$TS_OUT")
TS_SECRET=$(jq -r '.operator_oauth_client_secret.value' <<<"$TS_OUT")

write_enc() { # $1=path; plaintext-yaml on stdin -> ATOMIC: plaintext NEVER lands at $path
  local path="$1"
  mkdir -p "$(dirname "$path")"
  local tmp
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  trap 'rm -f "$tmp" "$tmp.enc"' RETURN
  cat >"$tmp" # plaintext stays in a 0600 temp only
  sops --encrypt --filename-override "$path" "$tmp" >"$tmp.enc" \
    || { echo "sops failed for $path — NO plaintext written to the target"; return 1; }
  mv "$tmp.enc" "$path" # atomic: only the ENCRYPTED file lands at $path
  echo "sealed $path"
}

write_enc platform/cloudflared/prod/tunnel.enc.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-tunnel
  namespace: edge
type: Opaque
stringData:
  token: "${TUNNEL_TOKEN}"
EOF

write_enc platform/tailscale/prod/operator-oauth.enc.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: operator-oauth
  namespace: edge
type: Opaque
stringData:
  client_id: "${TS_ID}"
  client_secret: "${TS_SECRET}"
EOF

write_enc platform/cnpg/prod/r2-creds.enc.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cnpg-r2-creds
  namespace: database
type: Opaque
stringData:
  # CANONICAL R2 key schema — consumed by BOTH the barman ObjectStore (AWS_*) and the
  # pg_dump -> rclone hedge (RCLONE_CONFIG_R2_* + AWS_*, region=auto). Do not rename;
  # object-store.yaml and pgdump-hedge-cronjob.yaml read these exact keys.
  AWS_ACCESS_KEY_ID: "${R2_PG_ACCESS_KEY}"
  AWS_SECRET_ACCESS_KEY: "${R2_PG_SECRET_KEY}"
  RCLONE_CONFIG_R2_TYPE: "s3"
  RCLONE_CONFIG_R2_PROVIDER: "Cloudflare"
  RCLONE_CONFIG_R2_ACCESS_KEY_ID: "${R2_PG_ACCESS_KEY}"
  RCLONE_CONFIG_R2_SECRET_ACCESS_KEY: "${R2_PG_SECRET_KEY}"
  RCLONE_CONFIG_R2_ENDPOINT: "${R2_ENDPOINT}"
  RCLONE_CONFIG_R2_REGION: "auto"
EOF

# pg-app-credentials: the app DB owner role. Consumed by CNPG initdb (database ns) and by
# the pg_dump hedge. Generated ONCE and committed (SOPS); on re-run / DR the committed file
# is the source of truth — regenerating would diverge from the password baked into the
# restored database. (pg_basebackup uses the managed `pg-superuser` secret instead — it
# needs REPLICATION, which the app role does not have.)
if [ ! -f platform/cnpg/prod/app-credentials.enc.yaml ]; then
  PG_APP_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)"
  write_enc platform/cnpg/prod/app-credentials.enc.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: pg-app-credentials
  namespace: database
type: kubernetes.io/basic-auth
stringData:
  username: "app"
  password: "${PG_APP_PASSWORD}"
EOF
else
  echo "keep platform/cnpg/prod/app-credentials.enc.yaml (already seeded; the password is load-bearing — never regenerate)"
fi

write_enc platform/victoria-stack/prod/alerting.enc.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: alerting-secrets
  namespace: observability
type: Opaque
stringData:
  TELEGRAM_BOT_TOKEN: "${TELEGRAM_BOT_TOKEN}"
  TELEGRAM_CHAT_ID: "${TELEGRAM_CHAT_ID}"
  HEALTHCHECKS_URL: "${HEALTHCHECKS_URL}"
  GRAFANA_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASSWORD}"
EOF
