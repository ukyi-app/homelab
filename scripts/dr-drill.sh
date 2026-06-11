#!/usr/bin/env bash
# DR drill (R5, POST-M6 수락): 전체 플랫폼이 git + R2 + age 키만으로 재구축됨을 증명한다.
# OrbStack VM(cattle)을 DESTROY하고 RECREATE한 뒤, 플랫폼을 git에서 재부트스트랩하고,
# 워크로드가 돌아오며, 재구축된 노드에서 R2로 DB가 복구됨을(canary 일치) 확인한다.
#
# 안전 설계: 파괴 BEFORE에 canary를 캡처하고 온디맨드 백업을 받아 "복구 가능"을 먼저
# 증명한다 — 복구가 증명되지 않으면 라이브 노드를 절대 파괴하지 않는다. 신선한 prod `pg`는
# bootstrap.initdb로 EMPTY로 뜨며, 실제 prod 데이터는 R2에서 복구된다(docs/runbooks/restore.md).
#
# 노드 유실에도 살아남아야 하는 외부 입력: M0 클러스터 age 키(~/.config/sops/age/keys.txt)와
# Terraform state + R2 백업(둘 다 R2). 네임스페이스만 ArgoCD 재설치는 스모크 체크지 DR이 아니다.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
NS="database"
LIVE_CLUSTER="pg"
DB="app"
KUBECONFIG_PATH="$REPO_ROOT/infra/k3s-bootstrap/kubeconfig"

: "${SOPS_AGE_KEY_FILE:?export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt (노드 유실에도 살아남는 out-of-band 입력)}"
test -s "$SOPS_AGE_KEY_FILE" || { echo "DR DRILL FAIL: age key missing at $SOPS_AGE_KEY_FILE"; exit 1; }

use_live_kubeconfig() { export KUBECONFIG="$KUBECONFIG_PATH"; }
use_live_kubeconfig

echo "==> [0] DR 입력이 노드 유실에도 살아남는지 확인: Terraform state + R2 백업은 R2에 있다"
terraform -chdir=infra/cloudflare state list >/dev/null \
  || { echo "DR DRILL FAIL: TF state(R2 backend) 도달 불가"; exit 1; }

# recover_and_check NAME → R2에서 verify 클러스터를 복구하고 canary count를 echo한 뒤 정리한다.
# drill-ssd(reclaimPolicy=Delete)라 PVC 삭제 시 PV 자동 제거 — 누수 없음, PV RBAC 불필요.
recover_and_check() {
  kubectl apply -f - >/dev/null <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: $1, namespace: ${NS}, labels: { cnpg.io/drill: "true" } }
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
  storage: { size: 40Gi, storageClass: drill-ssd }
  walStorage: { size: 10Gi, storageClass: drill-ssd }
  resources:
    requests: { cpu: 250m, memory: 768Mi }
    limits:   { cpu: "1", memory: 1Gi }
  bootstrap: { recovery: { source: r2-source } }
  externalClusters:
    - name: r2-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters: { barmanObjectName: pg-r2, serverName: ${LIVE_CLUSTER} }
YAML
  local phase=""
  for _ in $(seq 1 80); do
    phase="$(kubectl -n "$NS" get cluster "$1" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "$phase" = "Cluster in healthy state" ] && break
    sleep 15
  done
  local n
  n=$(kubectl -n "$NS" exec "${1}-1" -c postgres -- psql -U postgres -d "$DB" -tAc 'SELECT count(*) FROM restore_canary;' 2>/dev/null || echo 0)
  kubectl -n "$NS" delete cluster "$1" --ignore-not-found --wait=true || true
  kubectl -n "$NS" delete pvc -l "cnpg.io/cluster=$1" --ignore-not-found --wait=true || true
  echo "$n"
}

echo "==> [0.5] canary 캡처 + 검증된 백업 + 파괴 BEFORE 복구 가능성 증명"
EXPECTED=$(kubectl -n "$NS" exec "${LIVE_CLUSTER}-1" -c postgres -- psql -U postgres -d "$DB" -tAc 'SELECT count(*) FROM restore_canary;' 2>/dev/null || echo "")
{ [ -n "$EXPECTED" ] && [ "$EXPECTED" -ge 0 ]; } || { echo "DR ABORT: 라이브 canary를 읽을 수 없음"; exit 1; }
# 온디맨드 백업 → 고정 sleep이 아니라 실제 COMPLETE를 기다린 뒤 신뢰한다.
BK="dr-pre-$(kubectl -n "$NS" get backup -o name 2>/dev/null | wc -l | tr -d ' ')"
kubectl -n "$NS" create -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: ${BK}, namespace: ${NS} }
spec: { cluster: { name: ${LIVE_CLUSTER} }, method: plugin, pluginConfiguration: { name: barman-cloud.cloudnative-pg.io } }
YAML
for _ in $(seq 1 80); do
  [ "$(kubectl -n "$NS" get backup "$BK" -o jsonpath='{.status.phase}' 2>/dev/null)" = "completed" ] && break
  sleep 15
done
[ "$(kubectl -n "$NS" get backup "$BK" -o jsonpath='{.status.phase}' 2>/dev/null)" = "completed" ] \
  || { echo "DR ABORT: 백업 ${BK}가 COMPLETE되지 않음 — 라이브 노드 파괴 거부"; exit 1; }
# 여전히 살아있는 노드에서 그 백업을 verify 클러스터로 복구: R2 복구 가능성이 증명되기
# 전에는 prod를 절대 파괴하지 않는다.
PRE=$(recover_and_check pg-dr-precheck)
{ [ "${PRE:-0}" -ge "$EXPECTED" ] && [ "${PRE:-0}" -gt 0 ]; } \
  || { echo "DR ABORT: 파괴 전 복구 실패(recovered=$PRE < $EXPECTED) — 라이브 노드 파괴 안 함"; exit 1; }
echo "    canary=$EXPECTED, 백업 ${BK} completed, 복구 가능성 증명됨(recovered=$PRE). 파괴 안전."

echo "==> [1] VM 파괴(cattle) — 전체 노드 유실 시뮬레이션"
orb delete -f k3s || true

echo "==> [2] 커밋된 cloud-init/install에서 VM + k3s + StorageClass 재구축(M1)"
bash infra/k3s-bootstrap/host-up.sh
use_live_kubeconfig # host-up.sh가 kubeconfig를 재생성한다

echo "==> [3] make bootstrap — ArgoCD + sops-age Secret + root app, 전부 git에서"
make bootstrap

echo "==> [4] 플랫폼 계층 수렴 대기(root + cnpg operator + data Healthy)"
for app in root cnpg-operator cnpg-data; do
  kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy "application/$app" --timeout=900s
done

echo "==> [5] 재구축된 노드에서 R2로 DB 복구, 파괴 전 canary 검증"
ACTUAL=$(recover_and_check pg-dr-verify)
{ [ "${ACTUAL:-0}" -ge "$EXPECTED" ] && [ "${ACTUAL:-0}" -gt 0 ]; } \
  || { echo "DR DRILL FAIL: recovered canary=$ACTUAL < pre-loss $EXPECTED — R2가 데이터를 복구하지 못함"; exit 1; }
echo "    recovered canary = $ACTUAL (>= pre-loss $EXPECTED) — 재구축 노드에서 R2 데이터 복구 증명됨"

echo "==> [6] 재구축된 플랫폼에서 앱 워크로드가 실제 서빙되는지 검증"
kubectl -n prod rollout status deploy/api --timeout=300s

echo "DR DRILL PASS — VM 재구축; 플랫폼 + 워크로드가 git에서 복귀, 재구축 노드에서 R2 데이터 복구 증명됨(prod 데이터는 docs/runbooks/restore.md로 복구)"
