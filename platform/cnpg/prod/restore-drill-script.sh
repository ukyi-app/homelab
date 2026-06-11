#!/usr/bin/env bash
# 복원 drill (R1): R2 백업이 실제로 복구 가능함을 증명한다.
# 1) 라이브 클러스터에서 안정적인 row count를 읽는다
# 2) R2에서 복구한 일회용 클러스터를 띄운다
# 3) Ready가 될 때까지 기다린 뒤 같은 row count를 읽는다
# 4) 비교; PASS/FAIL을 Telegram으로 보고; PASS 시 healthchecks를 ping하고
#    restore_drill_last_success_timestamp 메트릭을 push (M5의 CNPGRestoreDrillStale이 읽음)
# 5) 일회용 클러스터는 항상 삭제한다
set -euo pipefail

NS="database"
LIVE_CLUSTER="pg"
DRILL_CLUSTER="pg-restore-drill"
DB="app"
TABLE="${DRILL_TABLE:-restore_canary}" # 라이브 앱/시드가 유지하는 canary 테이블
TG="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
# vmsingle의 Prometheus import 엔드포인트 (M5). 클러스터 내 service를 기본값으로 해 메트릭이
# 항상 전달되게 한다 — M5의 CNPGRestoreDrillStale은 absent()를 쓰므로 시계열이 없으면 영원히 페이징된다.
PUSHGW="${METRICS_PUSH_URL:-http://vmsingle.observability.svc:8428}"

notify() { # $1=emoji-status $2=text
  curl -fsS -X POST "$TG" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=[restore-drill] $1 $2" \
    --data-urlencode "parse_mode=HTML" >/dev/null || true
}

fail() {
  notify "🔴 FAIL" "$1"
  exit 1
}

push_success_metric() { # M5의 CNPGRestoreDrillStale이 읽는 정식 시계열 (vmsingle import API)
  printf 'restore_drill_last_success_timestamp %s\n' "$(date -u +%s)" \
    | curl -fsS --data-binary @- "${PUSHGW}/api/v1/import/prometheus" \
    || fail "could not push restore_drill_last_success_timestamp to ${PUSHGW} (M5 would page on the absent series)"
}

# cleanup은 drill의 Cluster + PVC를 제거한다. drill은 `drill-ssd` StorageClass
# (reclaimPolicy=Delete)를 쓰므로 PVC 삭제 시 PV가 자동 삭제된다 — 클러스터 전역 PV 권한도,
# 실행당 ~50 GiB 누수도 없음. (CNPG는 Cluster 삭제 시 PVC를 지우지 않으므로 직접 지운다.)
cleanup() {
  kubectl -n "$NS" delete cluster "$DRILL_CLUSTER" --ignore-not-found --wait=true || true
  kubectl -n "$NS" delete pvc -l "cnpg.io/cluster=${DRILL_CLUSTER}" --ignore-not-found --wait=true || true
}
trap cleanup EXIT

echo "[drill] expected row count from live cluster"
EXPECTED_ROWS="$(kubectl -n "$NS" exec "${LIVE_CLUSTER}-1" -c postgres -- \
  psql -U postgres -d "$DB" -tAc "SELECT count(*) FROM ${TABLE};")" \
  || fail "could not read live row count"
echo "[drill] EXPECTED_ROWS=${EXPECTED_ROWS}"

echo "[drill] applying throwaway recovery cluster"
kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${DRILL_CLUSTER}
  namespace: ${NS}
  labels: { cnpg.io/drill: "true" }
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
  storage: { size: 40Gi, storageClass: drill-ssd }      # Delete reclaim → PVC 삭제 시 PV 자동 제거 (누수 없음, PV RBAC 불필요)
  walStorage: { size: 10Gi, storageClass: drill-ssd }
  resources:
    requests: { cpu: 250m, memory: 768Mi }
    limits:   { cpu: "1", memory: 1Gi }
  bootstrap:
    recovery:
      source: r2-source
  externalClusters:
    - name: r2-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: pg-r2
          serverName: ${LIVE_CLUSTER}
YAML

echo "[drill] waiting for ${DRILL_CLUSTER} to reach healthy phase"
PHASE=""
for i in $(seq 1 60); do
  PHASE="$(kubectl -n "$NS" get cluster "$DRILL_CLUSTER" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  echo "  attempt ${i}: phase=${PHASE:-<none>}"
  [ "$PHASE" = "Cluster in healthy state" ] && break
  sleep 15
done
[ "$PHASE" = "Cluster in healthy state" ] || fail "drill cluster never became healthy (phase=${PHASE:-none})"

echo "[drill] actual row count from recovered cluster"
ACTUAL_ROWS="$(kubectl -n "$NS" exec "${DRILL_CLUSTER}-1" -c postgres -- \
  psql -U postgres -d "$DB" -tAc "SELECT count(*) FROM ${TABLE};")" \
  || fail "could not read recovered row count"
echo "[drill] ACTUAL_ROWS=${ACTUAL_ROWS}"

# WAL replay가 base backup 이후 쓰인 row를 포함할 수 있으므로 >= 허용.
if [ "$ACTUAL_ROWS" -ge "$EXPECTED_ROWS" ] && [ "$ACTUAL_ROWS" -gt 0 ]; then
  push_success_metric # PASS notify 전에 실행: 메트릭 적재 실패 시 즉시 실패 (아니면 M5의 absent() 알림이 영원히 페이징)
  notify "🟢 PASS" "recovered ${ACTUAL_ROWS} rows (live ${EXPECTED_ROWS}) from R2"
  # dead-man's switch: 진짜 PASS일 때만 ping (healthcheck 정의는 M5 소유)
  curl -fsS -m 10 "${HEALTHCHECKS_URL}" >/dev/null || true
  echo "[drill] PASS"
else
  fail "row mismatch: recovered=${ACTUAL_ROWS} expected>=${EXPECTED_ROWS}"
fi

cleanup
RESID=$(kubectl -n "$NS" get pvc -l "cnpg.io/cluster=${DRILL_CLUSTER}" -o name 2>/dev/null | wc -l | tr -d ' ')
[ "$RESID" = "0" ] || fail "drill cleanup INCOMPLETE: ${RESID} residual drill PVC(s) — storage would leak; check the restore-drill RBAC (pvc/pv delete perms)"
echo "[drill] cleanup done (cluster + PVCs + released PVs — zero residual verified)"
