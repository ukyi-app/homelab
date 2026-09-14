#!/usr/bin/env bash
# 선택적 CNPG 관측 경로. Telegram 설정·응답과 독립적으로 정상/경고를 보낸다.
set -euo pipefail
[ -n "${AIOPS_ENDPOINT:-}" ] && [ -r "${AIOPS_AUTH_FILE:-/run/aiops/authorization}" ] || exit 0
check="${1:-}"; target="${2:-}"; status="${3:-}"
case "$check" in restore-drill|ensure-role-password) ;; *) exit 2 ;; esac
case "$status" in healthy) completed=true ;; warning) completed=false ;; *) exit 2 ;; esac
[[ "$target" =~ ^[a-z0-9-]+/[a-z0-9-]+$ ]] || exit 2
# 주소에 토큰을 넣지 않는다. 숫자 사설 주소의 고정 수신 경로만 허용한다.
[[ "$AIOPS_ENDPOINT" =~ ^http://(10\.[0-9.]+|192\.168\.[0-9.]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9.]+):21980/sources/cnpg$ ]] || exit 2
stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
run_id="${HOSTNAME:-cnpg}-${stamp}"
[[ "$run_id" =~ ^[a-zA-Z0-9:.-]+$ ]] || exit 2
printf '{"check":"%s","target":"%s","runId":"%s","observedAt":"%s","status":"%s","completed":%s,"revision":null}\n' \
  "$check" "$target" "$run_id" "$stamp" "$status" "$completed" |
  curl -fsS --connect-timeout 2 --max-time 5 -X POST "$AIOPS_ENDPOINT" \
    --header @"${AIOPS_AUTH_FILE:-/run/aiops/authorization}" --header 'Content-Type: application/json' --data-binary @- >/dev/null 2>&1 || {
      printf '%s\n' 'AIOps observation delivery failed' >&2
      exit 1
    }
