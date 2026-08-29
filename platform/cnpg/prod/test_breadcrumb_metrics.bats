#!/usr/bin/env bats
# ⚠️ 피연산자가 **상대 경로**다 — 이 파일은 레포 루트에서 실행해야 rc가 의미를 갖는다
#    (실행처: scripts/run-bats.sh:21-22가 `cd "$ROOT"` 한다).

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
  # ⚠️ 이 @test의 두 자리는 **`-eq 1` 전환으로 안 닫힌다** — 형태가 서로 다른 이유로 각각 다르다.
  #    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③-a
  #
  # ① `ls`는 "무매치"와 "경로째 부재"를 **둘 다 rc 2**로 뭉개므로 전환이 원리적으로 불가능하다.
  #    처방대로 극성이 반대인 `find`로 바꾼다(경로 부재=rc 1 / 무매치=rc 0 + 빈 stdout).
  #    예전 `ls … ; [ -ne 0 ]`은 platform/cnpg/prod가 통째로 사라져도 초록이었다.
  run find platform/cnpg/prod -maxdepth 1 -name 'alert-rules.yaml'
  [ "$status" -eq 0 ] # 디렉토리 실재 = 비공허 바닥값
  [ -z "$output" ]
  #
  # ② 아래는 **재귀 디렉토리** 부재 단언이다 — 존재하되 빈 디렉토리와 무매치가 같은 rc 1이라
  #    rc 하나로는 도메인이 빈 것을 못 본다. 비공허 바닥값과 양성 대조를 한 쌍으로 건다.
  #    양성 대조의 술어가 `kind: PrometheusRule`이 아닌 것은 그 kind가 레포 어디에도 없기 때문이다
  #    (2026-08-29 실측: `grep -rl --include='*.yaml' 'kind: PrometheusRule' .` = 0건). 대신 이 파일
  #    @test 1이 이미 읽는 CNPG Cluster manifest를 같은 재귀 술어로 잡아 도메인·술어 생존을 증언한다.
  run grep -rl --include='*.yaml' 'kind: Cluster' platform/cnpg
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # YAML manifest로 한정 — 이 문자열을 언급하는 이 .bats 파일 자신이 매칭되지 않도록
  run grep -rl --include='*.yaml' 'kind: PrometheusRule' platform/cnpg
  [ "$status" -eq 1 ]
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
