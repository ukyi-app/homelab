#!/usr/bin/env bats

@test "Cluster enables the barman WAL archiver (feeds barman_cloud_* + pg_stat_archiver metrics)" {
  grep -q 'isWALArchiver: true' platform/cnpg/prod/cluster.yaml
}
@test "local basebackup Job is named so kube_job_status_completion_time can match it" {
  grep -q 'name: cnpg-local-basebackup' platform/cnpg/prod/basebackup-cronjob.yaml
}
@test "restore drill pushes restore_drill_last_success_timestamp" {
  grep -q 'restore_drill_last_success_timestamp' platform/cnpg/prod/restore-drill-script.sh
}
@test "M4 authors NO vmalert / PrometheusRule (those are M5-owned)" {
  run bash -c "ls platform/cnpg/prod/alert-rules.yaml 2>/dev/null"
  [ "$status" -ne 0 ]
  # YAML manifest로 한정 — 이 문자열을 언급하는 이 .bats 파일 자신이 매칭되지 않도록
  run bash -c "grep -rl --include='*.yaml' 'kind: PrometheusRule' platform/cnpg 2>/dev/null"
  [ -z "$output" ]
}

# --- M5 알림이 읽는 메트릭이 실제 export되는 이름과 일치하는지 강제 (CNPG 1.29 + barman-cloud plugin) ---
# 배경: in-tree cnpg_collector backup/archive 메트릭은 plugin 환경에서 deprecated(0)거나 부재다.
# plugin은 barman_cloud_* 접두사로, WAL 아카이빙 상태는 pg_stat_archiver로 export한다.
# (중간 단언은 [ ]/grep 단순 명령으로 — bash 3.2에서 [[ ]] 실패 침묵 통과 회피)

@test "Cluster inherits prometheus.io annotations so vmagent scrapes CNPG :9187" {
  # 이 주석이 없으면 vmagent의 pod-annotations job이 pg 파드를 건너뛰어 모든 cnpg/barman 시리즈가 부재.
  grep -q 'inheritedMetadata:' platform/cnpg/prod/cluster.yaml
  grep -q 'prometheus.io/scrape: "true"' platform/cnpg/prod/cluster.yaml
  grep -q 'prometheus.io/port: "9187"' platform/cnpg/prod/cluster.yaml
}

@test "R2BackupStale reads the barman-cloud plugin backup metric, not the deprecated in-tree one" {
  grep -q 'barman_cloud_cloudnative_pg_io_last_available_backup_timestamp' platform/victoria-stack/prod/rules/r4-storage-backup.yaml
  # deprecated in-tree 메트릭(plugin에서 항상 0)이 남아있으면 안 된다
  run grep -c 'cnpg_collector_last_available_backup_timestamp' platform/victoria-stack/prod/rules/r4-storage-backup.yaml
  [ "$output" -eq 0 ]
}

@test "WALArchiveStalled reads pg_stat_archiver metrics, not the absent in-tree archive metrics" {
  grep -q 'cnpg_pg_stat_archiver_last_failed_time' platform/victoria-stack/prod/rules/r4-storage-backup.yaml
  grep -q 'cnpg_pg_stat_archiver_last_archived_time' platform/victoria-stack/prod/rules/r4-storage-backup.yaml
  # plugin 환경에서 export되지 않는 in-tree archive 메트릭이 남아있으면 안 된다
  run grep -cE 'cnpg_collector_last_(archived|failed_archive)_time' platform/victoria-stack/prod/rules/r4-storage-backup.yaml
  [ "$output" -eq 0 ]
}

@test "CNPGRestoreDrillStale uses last_over_time, not bare instant absent() (weekly single-sample push)" {
  # 주간 단발 import는 instant staleness 윈도 밖에서 안 보여 bare absent()가 영구 오발화한다 —
  # 임계값보다 넓은 윈도의 last_over_time으로 마지막 성공 push를 찾아야 한다.
  grep -q 'last_over_time(restore_drill_last_success_timestamp' platform/victoria-stack/prod/rules/r4-storage-backup.yaml
  # bare instant 형태(absent(restore_drill_last_success_timestamp))가 남아있으면 안 된다
  run grep -c 'absent(restore_drill_last_success_timestamp)' platform/victoria-stack/prod/rules/r4-storage-backup.yaml
  [ "$output" -eq 0 ]
}
