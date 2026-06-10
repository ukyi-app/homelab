# Runbook — PostgreSQL Restore (CloudNativePG)

Three independent recovery paths exist (3-2-1). Prefer them in this order; each is
verified continuously (see "Verification").

## 0. Triage
- `kubectl cnpg status pg -n database` — is the live cluster recoverable in place?
- Check the latest restore-drill result in Telegram and the M5 `CNPGRestoreDrillStale` alert.

## Path A — Full recovery from R2 (offsite, primary DR path)
Stand up a NEW cluster (never recover onto the broken one):
```bash
kubectl apply -n database -f - <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: pg-restored, namespace: database }
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
  storage:    { size: 40Gi, storageClass: standard }
  walStorage: { size: 10Gi, storageClass: standard }
  bootstrap:
    recovery:
      source: r2-source
  externalClusters:
    - name: r2-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters: { barmanObjectName: pg-r2, serverName: pg }
YAML
kubectl cnpg status pg-restored -n database   # wait for "Cluster in healthy state"
```
Point-in-time (PITR): add under `bootstrap.recovery`:
```yaml
      recoveryTarget:
        targetTime: "2026-06-09 14:30:00.00000+00"
```
Then re-point apps/Pooler at `pg-restored` (rename or update `Pooler.spec.cluster.name`).

## Path B — Logical restore from the pg_dump hedge (barman/WAL-format failure)
```bash
rclone copyto r2:homelab-pg-backups-prod/pgdump/<latest>.dump.gz /tmp/d.gz
gunzip -c /tmp/d.gz | pg_restore --clean --if-exists \
  --host=pg-rw.database.svc --username=app --dbname=app --no-password
```
Use when Path A fails SigV4/region/WAL replay. `AWS_REGION=auto` is mandatory for R2.

## Path C — Local pg_basebackup (fast, on-node, last 7 days)
Tarballs live on `bulk-ssd` PVC `pg-basebackup-local`:
```bash
# exec into a tools pod with the PVC mounted; extract base.tar.gz into a fresh PGDATA,
# then start postgres with the streamed WAL. Local copy only — no offsite guarantee.
```

## Verification (these run automatically)
- Weekly `pg-restore-drill` CronJob: reads `count(*) FROM restore_canary` on live,
  recovers a throwaway `pg-restore-drill` cluster from R2, compares row counts,
  reports 🟢/🔴 to Telegram, pings healthchecks.io on PASS, pushes the
  `restore_drill_last_success_timestamp` metric, then deletes the cluster.
- `ScheduledBackup pg-daily-r2` (03:00); the M5 `R2BackupStale` alert reads
  `cnpg_collector_last_available_backup_timestamp`.
- `cnpg-local-basebackup` CronJob (02:30); the M5 `LocalBasebackupStale` alert reads
  `kube_job_status_completion_time{job_name=~"cnpg-local-basebackup.*"}`.
- Run a drill on demand: `kubectl -n database create job drill-now --from=cronjob/pg-restore-drill`.
  (Requires the M6-built `ghcr.io/<GH_USER>/pg-tools:16-rclone` image.)

## RTO/RPO
- RPO ≈ 5 min (archive_timeout=5min continuous WAL archiving).
- RTO ≈ time to recover a 40Gi cluster from R2 (typically minutes on this dataset).
