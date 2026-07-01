#!/usr/bin/env bash
# telegram 봇 토큰+chatId(.env.secrets)를 argocd ns SealedSecret(argocd-notifications-secret)로 봉인한다.
# 컨트롤러(argocd-notifications-controller)는 --secret-name=argocd-notifications-secret에서 $telegram-token을,
# cm subscriptions recipient는 $telegram-chat-id를 읽는다(키명 = notifier/recipient 참조와 일치).
# 사용: set -a; . .env.secrets; set +a; make seal-argocd-notify
# 평문은 kubeseal stdin으로만 흐른다(값/해시 stdout 미출력) — 산출물은 봉인 YAML 하나뿐.
set -euo pipefail
: "${TELEGRAM_BOT_TOKEN:?set TELEGRAM_BOT_TOKEN in .env.secrets}"
: "${TELEGRAM_CHAT_ID:?set TELEGRAM_CHAT_ID in .env.secrets}"
out="platform/argocd/extras/argocd-notifications-secret.sealed.yaml"
# --dry-run=client는 오프라인(라이브 클러스터 불요). --scope strict = ns+name 바인딩(argocd/argocd-notifications-secret).
kubectl create secret generic argocd-notifications-secret \
  --namespace argocd \
  --from-literal=telegram-token="$TELEGRAM_BOT_TOKEN" \
  --from-literal=telegram-chat-id="$TELEGRAM_CHAT_ID" \
  --dry-run=client -o yaml \
  | kubeseal --cert tools/sealed-secrets-cert.pem --scope strict --format yaml >"$out"
echo "sealed -> $out (argocd-notifications-secret, ns argocd)"
