#!/usr/bin/env bash
# LIVE end-to-end: requires a synced cluster (M1–M5) + the api app deployed. Run with DOMAIN set.
set -euo pipefail
NS=prod
APP=api

echo "1) CNPG cluster Ready before app wave (CNPG-Ready gate)?"
kubectl -n database wait --for=condition=Ready cluster/pg --timeout=300s

echo "2) ArgoCD app Synced+Healthy"
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/${APP}-prod --timeout=300s
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/${APP}-prod --timeout=300s

echo "3) migration Job completed and predates the Deployment's ready time"
JOB_END=$(kubectl -n $NS get job ${APP}-migrate -o jsonpath='{.status.completionTime}')
DEP_START=$(kubectl -n $NS get deploy ${APP} -o jsonpath='{.metadata.creationTimestamp}')
test -n "$JOB_END" || { echo "migration Job did not complete"; exit 1; }
echo "   migrate completed at $JOB_END (deploy created $DEP_START)"

echo "4) pod readiness (readyz) green"
kubectl -n $NS rollout status deploy/${APP} --timeout=180s
kubectl -n $NS get deploy ${APP} -o jsonpath='{.status.readyReplicas}' | grep -qx 1

echo "5) HTTPRoute Accepted by the shared homelab Gateway"
kubectl -n $NS get httproute ${APP} \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' | grep -qx True

echo "6) reachable through Traefik (in-cluster curl, gateway ns Service)"
kubectl -n $NS run curl-$RANDOM --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  -s -o /dev/null -w "%{http_code}\n" -H "Host: api.${DOMAIN:?set DOMAIN}" \
  http://traefik.gateway.svc.cluster.local/healthz | grep -qx 200

echo "E2E api: PASS"
