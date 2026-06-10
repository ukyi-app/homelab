#!/usr/bin/env bash
# Restore drill (R1): prove R2 backups are actually recoverable.
# 1) read a stable row count from the live cluster
# 2) stand up a throwaway cluster recovered from R2
# 3) wait until it is Ready, read the same row count
# 4) compare; report PASS/FAIL to Telegram; on PASS ping healthchecks + push the
#    restore_drill_last_success_timestamp metric (M5's CNPGRestoreDrillStale reads it)
# 5) always delete the throwaway cluster
set -euo pipefail

NS="database"
LIVE_CLUSTER="pg"
DRILL_CLUSTER="pg-restore-drill"
DB="app"
TABLE="${DRILL_TABLE:-restore_canary}" # canary table maintained by the live app/seed
TG="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
# vmsingle's Prometheus import endpoint (M5). Default to the in-cluster service so the metric is
# ALWAYS delivered — M5's CNPGRestoreDrillStale uses absent(), so a missing series pages forever.
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

push_success_metric() { # canonical series read by M5's CNPGRestoreDrillStale (vmsingle import API)
  printf 'restore_drill_last_success_timestamp %s\n' "$(date -u +%s)" \
    | curl -fsS --data-binary @- "${PUSHGW}/api/v1/import/prometheus" \
    || fail "could not push restore_drill_last_success_timestamp to ${PUSHGW} (M5 would page on the absent series)"
}

# Cleanup removes the drill's Cluster + PVCs. The drill uses the `drill-ssd` StorageClass
# (reclaimPolicy=Delete), so deleting the PVCs AUTO-deletes their PVs — no cluster-wide PV
# permission, no ~50 GiB/run leak. (CNPG does not delete PVCs on Cluster delete, so we do.)
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
  storage: { size: 40Gi, storageClass: drill-ssd }      # Delete reclaim → PVCs auto-remove PVs (no leak, no PV RBAC)
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

# Allow >= because WAL replay may include rows written after the base backup.
if [ "$ACTUAL_ROWS" -ge "$EXPECTED_ROWS" ] && [ "$ACTUAL_ROWS" -gt 0 ]; then
  push_success_metric # BEFORE the PASS notify: fail-hard if the metric can't land (else M5's absent() alert pages forever)
  notify "🟢 PASS" "recovered ${ACTUAL_ROWS} rows (live ${EXPECTED_ROWS}) from R2"
  # dead-man's switch: only ping on a genuine PASS (M5 owns the healthcheck definition)
  curl -fsS -m 10 "${HEALTHCHECKS_URL}" >/dev/null || true
  echo "[drill] PASS"
else
  fail "row mismatch: recovered=${ACTUAL_ROWS} expected>=${EXPECTED_ROWS}"
fi

cleanup
RESID=$(kubectl -n "$NS" get pvc -l "cnpg.io/cluster=${DRILL_CLUSTER}" -o name 2>/dev/null | wc -l | tr -d ' ')
[ "$RESID" = "0" ] || fail "drill cleanup INCOMPLETE: ${RESID} residual drill PVC(s) — storage would leak; check the restore-drill RBAC (pvc/pv delete perms)"
echo "[drill] cleanup done (cluster + PVCs + released PVs — zero residual verified)"
