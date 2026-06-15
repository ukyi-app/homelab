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

@test "cronjob waits for pg-rw to be reachable before pg_basebackup (kube-router rule-install gap)" {
  # libpq는 첫 연결 거부에서 즉시 포기 — 새 파드의 첫 ClusterIP 접속이 kube-router 룰 설치 전
  # 갭에 떨어지면 RST(Connection refused)로 job이 실패한다(라이브 검증). 도달 대기 루프가 필요.
  grep -q '/dev/tcp/pg-rw.database.svc/5432' "$cj"
}
@test "cronjob container is hardened (no privesc, all caps dropped, seccomp RuntimeDefault)" {
  grep -q 'allowPrivilegeEscalation: false' "$cj"
  grep -qF 'drop: [ALL]' "$cj"
  grep -q 'type: RuntimeDefault' "$cj"
}
