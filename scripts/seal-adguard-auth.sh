#!/usr/bin/env bash
# AdGuard UI 관리자 비밀번호(.env.secrets의 ADGUARD_PASSWORD)를 bcrypt 해시로 만들어
# SealedSecret(platform/adguard/prod/adguard-auth.sealed.yaml: name=adguard-auth, ns=edge, key=PASSWORD_HASH)로 봉인한다.
# 평문도 bcrypt 해시도 stdout/로그에 절대 출력하지 않는다 — 봉인된 암호문 파일만 산출물이다.
# 비밀번호 변경 시 .env.secrets를 고치고 이 스크립트를 다시 돌리면 된다(GitOps 강제라 재배포 시 적용).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CERT="tools/sealed-secrets-cert.pem"
OUT="platform/adguard/prod/adguard-auth.sealed.yaml"

[ -f .env.secrets ] || { echo "seal-adguard-auth: .env.secrets 없음 (.env.secrets.example 참고)" >&2; exit 1; }
[ -f "$CERT" ] || { echo "seal-adguard-auth: $CERT 없음" >&2; exit 1; }
command -v kubeseal >/dev/null || { echo "seal-adguard-auth: kubeseal 필요" >&2; exit 1; }
command -v docker >/dev/null || { echo "seal-adguard-auth: docker 필요(htpasswd bcrypt)" >&2; exit 1; }

# .env.secrets(export VAR="..." 형식)를 source해 ADGUARD_PASSWORD를 읽는다. 값은 로컬 변수로만 보관.
# shellcheck disable=SC1091
. ./.env.secrets >/dev/null 2>&1 || true
pw="${ADGUARD_PASSWORD:-}"
[ -n "$pw" ] || { echo "seal-adguard-auth: ADGUARD_PASSWORD 미설정(.env.secrets)" >&2; exit 1; }

# bcrypt 해시 생성: 평문은 stdin으로만 htpasswd에 전달(인자/ps 노출 없음), cost 10. 출력에서 'x:' 접두 제거.
hash="$(printf '%s' "$pw" | docker run --rm -i httpd:2.4-alpine htpasswd -niBC 10 x | cut -d: -f2)"
# bcrypt($2a/$2b/$2y) 접두 확인 — '$2'는 의도된 리터럴(셸 확장 아님), AdGuard가 받는 형식
# shellcheck disable=SC2016
case "$hash" in
  '$2'*) : ;;
  *) echo "seal-adguard-auth: bcrypt 해시 생성 실패" >&2; exit 1 ;;
esac

# 평문 Secret manifest는 디스크에 쓰지 않고 kubeseal stdin으로만 흐른다(해시도 미출력).
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: adguard-auth\n  namespace: edge\ntype: Opaque\nstringData:\n  PASSWORD_HASH: "%s"\n' "$hash" |
  kubeseal --cert "$CERT" --format yaml --scope strict >"$OUT"

echo "sealed: $OUT (adguard-auth/PASSWORD_HASH, ns=edge, scope=strict)"
