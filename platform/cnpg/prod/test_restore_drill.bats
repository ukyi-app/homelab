#!/usr/bin/env bats
cj=platform/cnpg/prod/restore-drill-cronjob.yaml
sh=platform/cnpg/prod/restore-drill-script.sh

@test "drill is recurring (weekly cron)" {
  grep -qE 'schedule:\s+"0 5 \* \* 0"' "$cj" # 일요일 05:00
}
@test "drill uses the M6-built pg-tools image" {
  grep -q 'ghcr.io/ukyi-app/pg-tools:16-rclone' "$cj"
}
@test "drill bootstraps a FRESH cluster via recovery from R2" {
  grep -q 'bootstrap:' "$sh"
  grep -q 'recovery:' "$sh"
  grep -q 'barmanObjectName: pg-r2' "$sh"
  grep -q 'pg-restore-drill' "$sh" # 일회용 클러스터 이름
}
@test "drill compares row counts and reports pass/fail to Telegram" {
  grep -q 'EXPECTED_ROWS' "$sh"
  grep -q 'ACTUAL_ROWS' "$sh"
  grep -q 'api.telegram.org' "$sh"
  grep -q 'sendMessage' "$sh"
}
@test "drill pushes the restore_drill_last_success_timestamp breadcrumb (M5 alert metric)" {
  grep -q 'restore_drill_last_success_timestamp' "$sh"
}
@test "drill tears the throwaway cluster down — PVC delete + Delete-reclaim SC (no ~50GiB/run leak)" {
  grep -q 'delete cluster' "$sh"
  grep -q 'delete pvc -l "cnpg.io/cluster=' "$sh"  # Cluster CR만이 아니라 PVC도 삭제
  grep -q 'storageClass: drill-ssd' "$sh"          # Delete reclaim → PVC 삭제 시 PV 자동 제거(수동 delete pv 불필요)
  grep -q 'residual drill PVC' "$sh"               # cleanup 후 잔여 PVC 0 검증 가드(거짓통과 'delete pv' substring 제거)
}
@test "drill script passes shellcheck" {
  run shellcheck "$sh"
  [ "$status" -eq 0 ]
}
@test "drill notify renders the shared contract (Korean source label + parse_mode HTML)" {
  grep -q '복원드릴' "$sh"          # 소스 라벨
  grep -q 'parse_mode=HTML' "$sh"   # HTML 모드 유지
  grep -q 'notify-block (test-extracted)' "$sh" # 격리 테스트 추출 마커
}
@test "drill notify supports DRY_RUN (print instead of curl) and HTML-escapes" {
  grep -q 'DRY_RUN' "$sh"
  grep -q 'hx()' "$sh"
}
@test "drill container is hardened (high-priv SA — no privesc, all caps dropped, seccomp RuntimeDefault)" {
  grep -q 'allowPrivilegeEscalation: false' "$cj"
  grep -qF 'drop: [ALL]' "$cj"
  grep -q 'type: RuntimeDefault' "$cj"
}
