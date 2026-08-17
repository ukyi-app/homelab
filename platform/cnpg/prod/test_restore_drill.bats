#!/usr/bin/env bats
cj=platform/cnpg/prod/restore-drill-cronjob.yaml
sh=platform/cnpg/prod/restore-drill-script.sh

@test "drill is recurring (weekly cron)" {
  grep -qE 'schedule:\s+"0 5 \* \* 0"' "$cj" # 일요일 05:00
}
@test "drill uses the M6-built pg-tools image" {
  grep -q 'ghcr.io/ukyi-app/pg-tools:18-rclone' "$cj"
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
@test "drill tears the throwaway cluster down — Cluster + PVC + Delete-reclaim SC (no ~50GiB/run leak)" {
  # ⚠️ 여기서는 **정적 계약만** 본다. "정리가 apply보다 **먼저** 돈다"·"복구가 실제로 일어났다"·
  #    "열거 실패를 0건으로 읽지 않는다"는 grep으로 원리적으로 증명할 수 없다(파일 어디에 있든
  #    substring은 매치된다). 그 축은 test_restore_drill_behavior.bats가 스텁 kubectl의 **호출
  #    순서·횟수**와 FAIL 문구로 문다 — 이 @test를 늘리지 말고 그쪽에 추가할 것.
  grep -q 'delete cluster' "$sh"
  grep -q 'delete pvc -l "cnpg.io/cluster=' "$sh"  # Cluster CR만이 아니라 PVC도 삭제
  grep -q 'storageClass: drill-ssd' "$sh"          # Delete reclaim → PVC 삭제 시 PV 자동 제거(수동 delete pv 불필요)
  grep -q 'preflight_purge' "$sh"                  # apply 이전 정리 진입점이 실재한다 (M17)
  grep -q 'SAW_NONHEALTHY' "$sh"                   # 복구가 일어났다는 양성 증인이 실재한다 (M17)
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

@test "drill recovers THIS cluster's archive — serverName is derived, never the k8s Cluster name" {
  # ⚠️ 예전엔 `serverName: ${LIVE_CLUSTER}`였다. NUC에서 k8s Cluster는 `pg`인데 아카이브는 `pg-nuc`라
  #    그 겸직이 깨진다 — 드릴이 **라이브 Mac의 아카이브**를 복구해 NUC row와 비교하고, Mac이 살아
  #    있는 동안 초록이 뜬다. 계획서 G7("NUC 자체 백업 체인 독립 생존")이 거짓 통과하는 경로다.
  grep -q 'ARCHIVE_SERVER=' "$sh"
  grep -q 'parameters.serverName' "$sh"          # 라이브 Cluster에서 파생
  grep -q 'serverName: ${ARCHIVE_SERVER}' "$sh"  # 그 값을 실제로 쓴다
  run grep -nE '^[^#]*serverName: \$\{LIVE_CLUSTER\}' "$sh"
  [ "$status" -ne 0 ]
}

@test "drill fails closed when the archive serverName cannot be derived" {
  # 무엇을 복구할지 모른 채 '복구 가능하다'를 증명할 수는 없다.
  grep -q '어느 아카이브를 복구할지 알 수 없다' "$sh"
}
