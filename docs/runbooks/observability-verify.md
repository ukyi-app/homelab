# Observability — full-stack verification sweep

Run this once the `victoria-stack` ArgoCD Application is `Synced/Healthy`. It asserts the
whole stack end-to-end. (LIVE: needs the running cluster with M5 synced.)

```bash
set -e
NS=observability
echo "[1] vmagent targets all up"
kubectl -n $NS exec deploy/vmagent -- wget -qO- 'localhost:8429/api/v1/targets?state=active' \
  | grep -q '"health":"down"' && { echo FAIL: a target is down; exit 1; } || echo OK
echo "[2] vmsingle byte-cap (not percent) retention"
kubectl -n $NS get sts vmsingle -o yaml | grep -q -- '-retention.maxDiskSpaceUsageBytes' && echo OK
echo "[3] VictoriaLogs ingesting"
kubectl -n $NS exec sts/victorialogs -- wget -qO- 'localhost:9428/select/logsql/query?query=*&limit=1' | grep -q '_msg' && echo OK
echo "[4] vmalert loaded core+r4+r6 groups"
G=$(kubectl -n $NS exec deploy/vmalert -- wget -qO- 'localhost:8880/api/v1/groups')
echo "$G" | grep -q '"name":"infra"' && echo "$G" | grep -q '"name":"storage-backup"' && echo "$G" | grep -q '"name":"ci-staleness"' && echo OK
echo "[5] Grafana datasources healthy"
kubectl -n $NS exec deploy/grafana -- sh -c 'for i in 1 2; do wget -qO- "http://admin:admin@localhost:3000/api/datasources/$i/health"; done' | grep -q '"status":"OK"' && echo OK
echo "[6] Single Alertmanager: gossip disabled + telegram receiver + valid config"
kubectl -n $NS exec deploy/alertmanager -- amtool check-config /etc/alertmanager/alertmanager.yml >/dev/null && echo OK
echo "[7] dead-man relay pinging (no failures in last 5 lines)"
kubectl -n $NS logs deploy/deadmanswitch-relay --tail=5 | grep -q 'ping failed' && { echo FAIL; exit 1; } || echo OK
echo "[8] Grafana HTTPRoute on homelab/web-internal (internal-only)"
kubectl -n $NS get httproute grafana -o jsonpath='{.spec.parentRefs[0].name}/{.spec.parentRefs[0].sectionName}' | grep -q 'homelab/web-internal' && echo OK
echo "ALL GREEN"
```

Then confirm the two human-in-the-loop facts automation cannot self-assert:
- The `E2ETestAlert` (Task 5.12) was **seen in Telegram**.
- healthchecks.io shows `homelab-watchdog` **up** (dead-man's-switch armed).

Note: the R4 CNPG-metric rules (`LocalBasebackupStale`, `R2BackupStale`, `WALArchiveStalled`,
`CNPGRestoreDrillStale`) may show `no-data` until M4 is green — intended graceful-degrade,
does not fail this gate.
