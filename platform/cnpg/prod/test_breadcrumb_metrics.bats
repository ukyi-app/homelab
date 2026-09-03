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
  # ⚠️ 이 @test 이름이 약속하는 판정 조건은 **위치**다 — vmagent의 pod-annotations job은
  #    role:pod라 **파드**의 주석만 읽는다(vmagent-scrape-config.yaml:46-58). 주석이 Cluster CR
  #    자신의 metadata.annotations에만 붙으면 인스턴스 파드엔 아무것도 상속되지 않는다.
  #    예전 판(파일 전역 grep 3개)은 그 세 토큰이 **같은 블록 안**에 있는지 안 봐서, 주석을
  #    inheritedMetadata 밖으로 이설해도 8/8 초록이었다(실측). yq 경로가 존재+위치+값을 한 번에
  #    잰다(경로 부재 = null → `yq -e` rc 1 → 대입 실패로 red).
  #    값이 문자열 "true"/"9187"이라 이 레포의 `yq -e` false-exit1 함정(test_cluster_params.bats:91-95)
  #    비대상이다. prometheus.io/path는 현행대로 미측정(범위 확대 금지).
  # 정정: 이 회귀는 라이브 블라인드가 아니다 — 같은 :9187에서 오는 cnpg_collector_up도 함께
  #    사라져 PostgresClusterDown(core.yaml:151-155, absent 가지, for:3m, critical)이 페이징한다.
  #    실질 손해는 트리아지 오도이고, 여기 값은 머지-전 정적 증인이다.
  c=platform/cnpg/prod/cluster.yaml
  a="$(yq -e '.spec.inheritedMetadata.annotations."prometheus.io/scrape"' "$c")"
  printf '%s' "$a" | grep -qxF -- 'true'
  p="$(yq -e '.spec.inheritedMetadata.annotations."prometheus.io/port"' "$c")"
  printf '%s' "$p" | grep -qxF -- '9187'
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
