#!/usr/bin/env bash
set -euo pipefail

CHART_VERSION="$(tr -d '[:space:]' < platform/argocd/CHART_VERSION)"
AGE_KEY="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

test -f "${AGE_KEY}" || { echo "FATAL: M0 cluster age key not found at ${AGE_KEY}" >&2; exit 1; }

echo "==> [1/4] namespace argocd"
kubectl get ns argocd >/dev/null 2>&1 \
  && echo "    namespace argocd already exists" \
  || kubectl create ns argocd

echo "==> [2/4] sops-age cluster key Secret (idempotent; file key keys.txt)"
kubectl -n argocd create secret generic sops-age \
  --from-file=keys.txt="${AGE_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f - \
  | sed 's/^/    /'

echo "==> [3/4] helm upgrade --install argo-cd (pinned ${CHART_VERSION})"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
# helm 실패가 grep 파이프라인+|| true에 삼켜져 exit 0으로 위장됐던 라이브 버그 — 실패는 즉시 중단.
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "${CHART_VERSION}" \
  --values platform/argocd/bootstrap-values.yaml \
  --wait --timeout 10m \
  || { echo "FATAL: argo-cd helm install failed" >&2; exit 1; }
helm -n argocd status argocd | grep -E 'STATUS|REVISION' | sed 's/^/    /' || true

echo "==> [4/4] apply root app-of-apps + ArgoCD self-manage"
kubectl apply -f platform/argocd/argocd-app.yaml | sed 's/^/    /'
kubectl apply -f platform/argocd/root/root-app.yaml | sed 's/^/    /'

echo "==> bootstrap complete"
