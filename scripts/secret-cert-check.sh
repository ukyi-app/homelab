#!/usr/bin/env bash
# 봉인 전 preflight — 커밋된 sealed-secrets cert(tools/sealed-secrets-cert.pem)가 라이브 컨트롤러
# cert와 fingerprint로 일치하는지 검사한다. 불일치(stale)면 새로 봉인한 SealedSecret을 라이브
# 컨트롤러가 복호 못 한다(컨트롤러 키 회전 후 늦게 드러남) — 봉인 전에 잡는다. read-only(fetch만).
# sealing-key-dr-gate.sh:155-168 로직 재사용. 라이브 fetch 불가(오프라인)면 검증 스킵 — **exit 2**로
# 신호해 자동화가 "검증됨(0)"·"stale 실패(1)"·"검증 못함(2)"을 혼동하지 않게 한다(fail-open 가시화).
set -euo pipefail

CERT="tools/sealed-secrets-cert.pem"
NS="sealed-secrets"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cert) CERT="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    -h|--help) echo "usage: secret-cert-check.sh [--cert <pem>] [--namespace <ns>]"; exit 0 ;;
    *) echo "알 수 없는 옵션: $1"; exit 2 ;;
  esac
done

[ -f "$CERT" ] || { echo "secret-cert-check: committed cert 없음: $CERT"; exit 1; }

command -v kubeseal >/dev/null 2>&1 || { echo "⚠️ secret-cert-check: kubeseal 없음 — 검증 스킵(SKIP exit 2)"; exit 2; }

live="$(kubeseal --controller-namespace "$NS" --fetch-cert 2>/dev/null || true)"
if [ -z "$live" ]; then
  echo "⚠️ secret-cert-check: 라이브 cert fetch 실패(KUBECONFIG/클러스터 접근 확인) — 검증 못 함(SKIP exit 2, 봉인 전 수동 확인 권장)"
  exit 2
fi

fp_live="$(printf '%s' "$live" | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)"
fp_have="$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 2>/dev/null || true)"

[ -n "$fp_have" ] || { echo "secret-cert-check: committed cert 읽기 실패: $CERT"; exit 1; }
if [ -z "$fp_live" ]; then echo "⚠️ secret-cert-check: 라이브 cert 파싱 실패 — 검증 못 함(SKIP exit 2)"; exit 2; fi

if [ "$fp_live" != "$fp_have" ]; then
  echo "secret-cert-check: STALE — committed cert($CERT)가 라이브 컨트롤러 cert와 불일치."
  echo "  → 지금 봉인하면 새 컨트롤러가 복호 못 한다. 봉인 전 교정 필요:"
  echo "  복구책: (a) 백업 키 복원으로 active 승격, 또는"
  echo "          (b) kubeseal --controller-namespace $NS --fetch-cert > $CERT 갱신·재커밋·전파."
  exit 1
fi
echo "secret-cert-check OK: committed cert == 라이브 컨트롤러 cert (봉인 안전)"
