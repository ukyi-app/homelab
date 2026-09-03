#!/usr/bin/env bats
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일이라 그것으로 닫힌다.
#    (아래 yq 자리는 비대상 — yq의 rc는 값 false와 키 부재를 구별하지 않는다.)
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
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
  # ⚠️ 이 `pg-r2`는 **이중 SSOT**다 — 신원 등호의 정본 증인은 test_object_store.bats의
  #    "the ObjectStore name is the identity every consumer references"(object-store.yaml에서
  #    파생해 소비처 4곳을 잰다). 여기는 그 스크립트가 recovery 부트스트랩을 그리는지 보는
  #    형태 핀이라 개명 시 함께 red가 난다 — 진단은 정본 증인 쪽을 먼저 읽을 것.
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
  [ "$status" -eq 1 ]
}

@test "drill fails closed when the archive serverName cannot be derived" {
  # 무엇을 복구할지 모른 채 '복구 가능하다'를 증명할 수는 없다.
  grep -q '어느 아카이브를 복구할지 알 수 없다' "$sh"
}

@test "the CNPG backup/verify CronJobs are Burstable, not BestEffort (pressure must not evict the janitor first)" {
  # ⚠️ resources가 전무하면 파드가 **BestEffort QoS**가 되어 노드 압박 시 **가장 먼저 evict**된다.
  #    restore-drill은 자기 쓰레기(고아 Cluster + ~50GiB PVC)를 치우는 청소부이기도 하므로,
  #    압박이 청소부를 먼저 죽이고 쓰레기를 남기는 되먹임이 생긴다. 형제 둘은 백업 생산자다.
  # ⚠️ **limits는 요구하지 않는다** — 이 kind를 읽는 게이트가 없어(check-resource-limits.ts의
  #    KINDS에 CronJob/Job 부재) 틀린 limit이 무측정으로 출하되기 때문이다. requests만 잠근다.
  for f in restore-drill-cronjob basebackup-cronjob pgdump-hedge-cronjob; do
    y="platform/cnpg/prod/${f}.yaml"
    cpu="$(yq -e '.spec.jobTemplate.spec.template.spec.containers[0].resources.requests.cpu' "$y")"
    mem="$(yq -e '.spec.jobTemplate.spec.template.spec.containers[0].resources.requests.memory' "$y")"
    # ⚠️ 부재를 `grep -qv`로 재지 않는다 — `-v`는 줄 단위 반전이라 ∀줄 ¬매치가 아니라 ∃줄 ¬매치다.
    #    여기 피연산자는 yq 스칼라 1줄이라 **오늘은 우발적으로 옳았지만**, 값이 두 줄이 되는 날
    #    조용히 공허해지는 잠복형이었다(형제 실측: tests/gates/test_ops-repin.bats — 5줄 중 1줄이
    #    stale이어도 green이었다). 스칼라 비교엔 줄 개념이 없는 `[ … != … ]`가 정확하고, 오늘의
    #    동작을 그대로 보존한다(100m/null/빈 문자열/0 네 값에서 rc 동일 — 2026-08-29 대조).
    [ -n "$cpu" ]
    [ -n "$mem" ]
    [ "$cpu" != "null" ]
    [ "$mem" != "null" ]
  done
}

@test "live psql helper does not use kubectl --request-timeout (v1.36.x breaks in-cluster config)" {
  # ★ 회귀 가드(2026-08-24 진단). kubectl v1.36.x는 `--request-timeout`과 in-cluster REST config
  #   로딩을 상호작용시켜 config를 버리고 localhost:8080으로 폴백한다(값 무관 — 30s·1m 둘 다 재현).
  #   pg-tools 재빌드로 kubectl이 v1.36.3이 되며 매 drill이 RPO 마커 단계에서 결정적으로 죽었다
  #   (8/22·8/25 실측, backoffLimit:0이라 1회 실패가 DR 드릴을 주 단위로 방치). 타임아웃은 kubectl
  #   플래그가 아니라 `timeout` 코어유틸 래퍼로 건다. 이 파일 어디에도 --request-timeout이 없어야 한다.
  # ⚠️ 주석 제외(`^[^#]*`) — 이 파일과 drill.sh **양쪽 주석이 이 함정 문자열을 인용**하므로(고친 함정을
  #    설명하는 컨벤션), 전체 줄 grep은 자기 설명에 걸려 거짓 red를 낸다. 실행되는 코드 줄만 본다.
  run grep -nE '^[^#]*request-timeout' "$sh"
  [ "$status" -eq 1 ] || { echo "drill.sh 코드가 kubectl --request-timeout을 쓴다 (v1.36.x in-cluster 폴백 버그), 또는 스크립트가 사라졌다:"; echo "$output"; false; }
  # 양성 대조: _live_psql이 timeout 래퍼로 여전히 무한 대기를 막는지(플래그 제거가 보호를 없앤 게 아님)
  grep -qE 'timeout [0-9]+ kubectl .*exec' "$sh"
}

@test "the manifest is wired into the kustomization (prune would delete it otherwise)" {
  # ⚠️ cnpg-data App은 prune:true + selfHeal:true라 resources에서 한 줄이 사라지는 것이 곧
  #    클러스터에서의 삭제다 — 유일한 복구 증명이 통째로 없어진다. 위 @test들은 CronJob·스크립트
  #    파일을 직접 grep할 뿐 배선을 안 봐서 배선을 지워도 PR 게이트가 전건 초록이었다(실측).
  #    이 CronJob은 렌더 증인(test_kustomize_build.bats, 게다가 tests/.ci-exclude)조차 없어
  #    이 한 줄이 배선의 유일한 머지-전 증인이다. 사후 검출은 CNPGRestoreDrillStale(≈8.1일)뿐이다.
  # ⚠️ 원문 grep이 아니라 파싱된 resources를 본다(tests/gates/test_dual-run-excludes.bats:51-58 관례).
  run yq '.resources | contains(["restore-drill-cronjob.yaml"])' platform/cnpg/prod/kustomization.yaml
  printf '%s' "$output" | grep -qxF -- 'true'
}
