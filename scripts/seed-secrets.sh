#!/usr/bin/env bash
set -euo pipefail

# R2 access/secret 키 쌍은 범위 제한된 R2 API 토큰으로 레포 밖에서 발급되어
# env로 주입된다 (terraform output이 아님).
: "${R2_PG_ACCESS_KEY:?set R2_PG_ACCESS_KEY}"
: "${R2_PG_SECRET_KEY:?set R2_PG_SECRET_KEY}"
# 알림 팬아웃 (M5 vmalert/Alertmanager가 소비).
: "${TELEGRAM_BOT_TOKEN:?set TELEGRAM_BOT_TOKEN}"
: "${TELEGRAM_CHAT_ID:?set TELEGRAM_CHAT_ID}"
: "${HEALTHCHECKS_URL:?set HEALTHCHECKS_URL}"
: "${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD}" # Grafana admin 비밀번호 (admin/admin 절대 금지)
# cert-manager DNS-01용 좁은 Cloudflare API 토큰 (*.home.ukyi.app 와일드카드 발급) — Zone DNS:Edit + Zone:Read만.
# ★SEC-1: 브로드 TF 토큰(R2·Tunnel·WAF·Cache·Zone Settings)을 클러스터 Secret에 봉인하던 것에서 분리한다.
#   클러스터(cert-manager)의 CF 노출을 '전체 계정'→'DNS 편집'으로 축소(침해/Secret 유출 시 blast radius 감소).
#   브로드 토큰은 terraform provider 인증 전용(TF_VAR_, Actions secret에만, 클러스터엔 봉인 안 함).
: "${CERT_MANAGER_CF_API_TOKEN:?set CERT_MANAGER_CF_API_TOKEN}"
# 브로드 토큰은 terraform output(아래)·provider 인증에 여전히 필요.
: "${TF_VAR_cloudflare_api_token:?set TF_VAR_cloudflare_api_token}"

CF_OUT=$(terraform -chdir=infra/cloudflare output -json)
TS_OUT=$(terraform -chdir=infra/tailscale output -json)

TUNNEL_TOKEN=$(jq -r '.tunnel_token.value' <<<"$CF_OUT")
R2_ENDPOINT=$(jq -r '.r2_account_endpoint.value' <<<"$CF_OUT")
TS_ID=$(jq -r '.operator_oauth_client_id.value' <<<"$TS_OUT")
TS_SECRET=$(jq -r '.operator_oauth_client_secret.value' <<<"$TS_OUT")

write_enc() { # $1=path; 평문 yaml을 stdin으로 받음 -> 원자적: 평문이 $path에 닿는 일은 절대 없음
  local path="$1"
  mkdir -p "$(dirname "$path")"
  local tmp
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  trap 'rm -f "$tmp" "$tmp.enc"' RETURN
  cat >"$tmp" # 평문은 0600 임시 파일에만 머문다
  sops --encrypt --filename-override "$path" "$tmp" >"$tmp.enc" \
    || { echo "sops failed for $path — NO plaintext written to the target"; return 1; }
  mv "$tmp.enc" "$path" # 원자적: 암호화된 파일만 $path에 놓인다
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
  namespace: tailscale
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
  # 정본(canonical) R2 키 스키마 — barman ObjectStore(AWS_*)와 pg_dump -> rclone 헤지
  # (RCLONE_CONFIG_R2_* + AWS_*, region=auto) 양쪽이 소비한다. 키 이름 변경 금지;
  # object-store.yaml과 pgdump-hedge-cronjob.yaml이 정확히 이 키들을 읽는다.
  AWS_ACCESS_KEY_ID: "${R2_PG_ACCESS_KEY}"
  AWS_SECRET_ACCESS_KEY: "${R2_PG_SECRET_KEY}"
  RCLONE_CONFIG_R2_TYPE: "s3"
  RCLONE_CONFIG_R2_PROVIDER: "Cloudflare"
  RCLONE_CONFIG_R2_ACCESS_KEY_ID: "${R2_PG_ACCESS_KEY}"
  RCLONE_CONFIG_R2_SECRET_ACCESS_KEY: "${R2_PG_SECRET_KEY}"
  RCLONE_CONFIG_R2_ENDPOINT: "${R2_ENDPOINT}"
  RCLONE_CONFIG_R2_REGION: "auto"
EOF

write_enc platform/cache/prod/cache-r2-creds.enc.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cache-r2-creds
  namespace: cache
type: Opaque
stringData:
  # cache-backup CronJob의 rclone R2 업로드(homelab-cache-backups-prod) — cnpg-r2-creds와 동일 계정 전역
  # R2 토큰 재사용, RCLONE_CONFIG_R2_* 서브셋(aws-cli 미사용이라 AWS_* 불요). 키 이름 변경 금지.
  RCLONE_CONFIG_R2_TYPE: "s3"
  RCLONE_CONFIG_R2_PROVIDER: "Cloudflare"
  RCLONE_CONFIG_R2_ACCESS_KEY_ID: "${R2_PG_ACCESS_KEY}"
  RCLONE_CONFIG_R2_SECRET_ACCESS_KEY: "${R2_PG_SECRET_KEY}"
  RCLONE_CONFIG_R2_ENDPOINT: "${R2_ENDPOINT}"
  RCLONE_CONFIG_R2_REGION: "auto"
EOF

# pg-app-credentials: 앱 DB 소유자 role. CNPG initdb(database ns)와 pg_dump 헤지가 소비한다.
# 한 번만 생성해 커밋(SOPS)한다; 재실행/DR 시에는 커밋된 파일이 진실 공급원이다 —
# 재생성하면 복원된 데이터베이스에 박혀 있는 비밀번호와 어긋난다.
# (pg_basebackup은 대신 관리형 `pg-superuser` 시크릿을 쓴다 — REPLICATION 권한이 필요한데
# 앱 role에는 없다.)
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

# M4 restore drill 알림 (실패 시 Telegram, PASS 시 healthchecks ping).
# HEALTHCHECKS_URL은 watchdog과 공유한다 — 드릴 전용 체크를 만들면 분리할 것.
write_enc platform/cnpg/prod/restore-drill-alerting.enc.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: restore-drill-alerting
  namespace: database
type: Opaque
stringData:
  TELEGRAM_BOT_TOKEN: "${TELEGRAM_BOT_TOKEN}"
  TELEGRAM_CHAT_ID: "${TELEGRAM_CHAT_ID}"
  HEALTHCHECKS_URL: "${HEALTHCHECKS_URL}"
EOF

# cert-manager DNS-01 솔버용 Cloudflare API 토큰 (gateway ns의 Issuer가 참조).
# ★SEC-1: 브로드 TF 토큰이 아니라 좁은 cert-manager 전용 토큰(Zone DNS:Edit + Zone:Read)을 봉인한다.
write_enc platform/traefik/prod/cloudflare-api-token.enc.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: gateway
type: Opaque
stringData:
  api-token: "${CERT_MANAGER_CF_API_TOKEN}"
EOF
