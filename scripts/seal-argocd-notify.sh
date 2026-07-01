#!/usr/bin/env bash
# telegram 봇 토큰(.env.secrets)을 argocd ns SealedSecret(argocd-notifications-secret)로 봉인한다.
# 컨트롤러는 --secret-name=argocd-notifications-secret에서 $telegram-token을 webhook service URL에 확장 주입한다.
# ⚠️ chatId는 봉인하지 않는다 — notifications-engine은 subscription recipient에 $secret 확장을 하지 않는다
#    (pkg/api/config.go — service.*만 확장). chatId(음수 그룹)는 cm subscriptions recipient에 리터럴로 둔다
#    (비-credential — 토큰 없이는 발송 불가). 봇 토큰만 credential이라 이 SealedSecret이 단독으로 봉인한다.
# 사용: set -a; . .env.secrets; set +a; make seal-argocd-notify
# 평문은 kubeseal stdin으로만 흐른다(값/해시 stdout 미출력) — 산출물은 봉인 YAML 하나뿐.
set -euo pipefail
: "${TELEGRAM_BOT_TOKEN:?set TELEGRAM_BOT_TOKEN in .env.secrets}"
out="platform/argocd/extras/argocd-notifications-secret.sealed.yaml"
# --dry-run=client는 오프라인(라이브 클러스터 불요). --scope strict = ns+name 바인딩(argocd/argocd-notifications-secret).
kubectl create secret generic argocd-notifications-secret \
  --namespace argocd \
  --from-literal=telegram-token="$TELEGRAM_BOT_TOKEN" \
  --dry-run=client -o yaml \
  | kubeseal --cert tools/sealed-secrets-cert.pem --scope strict --format yaml >"$out"
echo "sealed -> $out (argocd-notifications-secret, ns argocd; telegram-token only)"
