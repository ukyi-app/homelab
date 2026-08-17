#!/usr/bin/env bash
set -euo pipefail

CHART_VERSION="$(tr -d '[:space:]' < platform/argocd/CHART_VERSION)"
AGE_KEY="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

test -f "${AGE_KEY}" || { echo "FATAL: M0 cluster age key not found at ${AGE_KEY}" >&2; exit 1; }

echo "==> [1/4] namespace argocd"
# shellcheck disable=SC2015  # 의도된 멱등 패턴: ns가 있으면 echo, 없으면 create (if-then-else 아님)
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
# ⚠️ **이 둘은 쌍이다 — 어느 하나도 GitOps로 자동 수렴하지 않는다.**
#    root-app은 `path: platform/argocd/root` + `recurse: true`라 **하강만** 하므로 한 단계 위의
#    `platform/argocd/argocd-app.yaml`을 포착하지 못하고, platform-components appset도
#    `platform/argocd/*`를 exclude한다(`platform/argocd/README.md` — 이중 소유 금지).
#    즉 이 두 줄이 그 두 오브젝트를 만드는 **유일한 자리**다(감사 13).
# ⚠️ 그래서 **리비전 핀을 옮길 때도 이 쌍을 그대로 다시 apply해야 한다.** 한쪽만 하면
#    `Application/argocd`가 죽은 브랜치를 계속 추종하고, 그 브랜치를 지우는 순간 `$values` 소스
#    (`bootstrap-values.yaml`)를 resolve하지 못해 **ArgoCD가 자기 설치본을 reconcile하지 못한다.**
#    검출은 `ArgoCDOutOfSync`(sync_status!~"Synced" — Unknown 포함)가 15분 뒤에 한다. 예방은 여기다.
kubectl apply -f platform/argocd/argocd-app.yaml | sed 's/^/    /'
kubectl apply -f platform/argocd/root/root-app.yaml | sed 's/^/    /'

echo "==> bootstrap complete"
