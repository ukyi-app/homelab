#!/usr/bin/env bats
# vmalert가 GitOps로 동기화된 룰 변경을 자동 반영하도록 강제한다.
# configCheckInterval이 없으면 vmalert는 mount된 룰 파일 변경을 감시하지 않아, ArgoCD가 ConfigMap을
# 갱신해도 메모리상 옛 룰을 계속 평가한다(수동 rollout restart/-/reload 전까지 silent staleness).
# (중간 단언은 [ ]/grep 단순 명령으로 — bash 3.2에서 [[ ]] 실패 침묵 통과 회피)

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  VMALERT="$ROOT/platform/victoria-stack/vmalert.yaml"
}

@test "vmalert auto-reloads rule files on change (configCheckInterval set)" {
  grep -q 'configCheckInterval' "$VMALERT"
}

@test "crown-jewel DB liveness + non-OOM crashloop alerts are defined" {
  C="$ROOT/platform/victoria-stack/rules/core.yaml"
  grep -q 'alert: PostgresClusterDown' "$C"          # 단일 인스턴스 pg 생존 페이징
  grep -q 'cnpg_collector_up' "$C"                    # pg-1에서 직접 scrape돼 라벨 정확(KSM clobbering 회피)
  grep -q 'absent(cnpg_collector_up' "$C"             # 스크레이프 단절 fail-closed 가드
  run grep -q 'max(kube_pod_status_ready' "$C"; [ "$status" -ne 0 ]  # expr 회귀 금지(주석 언급은 허용)
  grep -q 'alert: PodCrashLooping' "$C"
}

@test "fourth backup (pgdump hedge) has a staleness alert like the other three" {
  R="$ROOT/platform/victoria-stack/rules/r4-storage-backup.yaml"
  grep -q 'alert: PgDumpHedgeStale' "$R"
  grep -q 'pg-dump-hedge-r2' "$R"
  grep -q 'kube_job_status_completion_time' "$R"
}

@test "disk-fill alerts carry a disk label so a critical inhibits the matching warning" {
  R="$ROOT/platform/victoria-stack/rules/r4-storage-backup.yaml"
  [ "$(grep -c 'disk: bulk-ssd' "$R")" -eq 2 ]   # BulkSSDFilling(warning) + BulkSSDAlmostFull(critical)
  grep -q 'disk: standard' "$R"
}
