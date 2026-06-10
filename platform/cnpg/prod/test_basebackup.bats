#!/usr/bin/env bats
pvc=platform/cnpg/prod/basebackup-pvc.yaml
cj=platform/cnpg/prod/basebackup-cronjob.yaml
@test "staging PVC is on bulk-ssd (external SSD), never standard" {
  grep -q 'storageClassName: bulk-ssd' "$pvc"
}
@test "cronjob runs pg_basebackup and prunes to 7 days" {
  grep -q 'pg_basebackup' "$cj"
  grep -qE 'mtime \+7' "$cj"
  grep -qE 'schedule:\s+"30 2 \* \* \*"' "$cj" # k8s 5-field cron, 02:30
}
@test "cronjob runs non-root 26 and mounts only bulk-ssd PVC" {
  grep -q 'runAsUser: 26' "$cj"
  grep -q 'claimName: pg-basebackup-local' "$cj"
}
@test "cronjob emits the local-basebackup breadcrumb metric M5 alerts on" {
  grep -q 'cnpg.io/backupRole: local-basebackup' "$cj"
}
