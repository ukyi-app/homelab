#!/usr/bin/env bats
# ensure-role-password.sh — CNPG managed role 비번 적용을 결정적으로 보장하는 ArgoCD PostSync hook Job 스크립트.
# kubectl/curl을 PATH 스텁으로 대체하고 폴링/nudge/타임아웃/마커 상태머신을 fake-clock(POLL_INTERVAL=0 +
# 유한 MAX_POLLS)으로 결정적으로 검증한다 — 라이브 클러스터 무접근.
# ⚠️ @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐, AGENTS.md). 중간 단언은 [ ]/명령만.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$ROOT/platform/cnpg/prod/ensure-role-password.sh"
  TMP="$(mktemp -d)"
  export ERP_KLOG="$TMP/klog"           # 모든 kubectl 호출 기록
  export ERP_NUDGE_FILE="$TMP/nudges"   # nudge(annotate) 누적 횟수
  : > "$ERP_KLOG"; printf '0' > "$ERP_NUDGE_FILE"
  # fake-clock — 실제 sleep 없이 유한 폴링으로 타임아웃 상태머신을 결정적으로 돌린다
  export ERP_POLL_INTERVAL_SECONDS=0
  export ERP_MAX_POLLS=4
  export ERP_READY_MAX_POLLS=4
  export ERP_TEST_DBS="page"
  export ERP_TEST_DB_APPLIED="true"
  export ERP_TEST_SCENARIO="applied"

  mkdir -p "$TMP/bin"
  # kubectl 스텁: 호출을 기록하고 시나리오에 따라 jsonpath 응답을 흉내낸다(클러스터 무접근).
  cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$ERP_KLOG"
args="$*"
case "$args" in
  *"get database"*"items"*)            # DB 목록 열거
    printf '%s\n' $ERP_TEST_DBS ;;
  *"get database"*"status.applied"*)   # Database CR Ready 검사
    printf '%s' "$ERP_TEST_DB_APPLIED" ;;
  *"passwordStatus"*)                  # 롤 passwordStatus.resourceVersion
    n="$(cat "$ERP_NUDGE_FILE" 2>/dev/null || echo 0)"
    case "$ERP_TEST_SCENARIO" in
      applied)  printf '100' ;;
      eventual) if [ "${n:-0}" -ge 1 ]; then printf '100'; else printf ''; fi ;;
      never)    printf '' ;;
    esac ;;
  *"annotate cluster"*)                # nudge — 카운터 증가(비번 값 불변, reconcile 트리거 흉내)
    n="$(cat "$ERP_NUDGE_FILE" 2>/dev/null || echo 0)"; printf '%s' "$((n+1))" > "$ERP_NUDGE_FILE" ;;
  *"create configmap"*)                # 마커 생성(dry-run yaml) — 파이프로 apply에 전달
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: marker\n' ;;
  *"apply -f"*)                        # 마커 upsert — stdin 소비
    cat >/dev/null ;;
  *) : ;;
esac
exit 0
STUB
  chmod +x "$TMP/bin/kubectl"
  # curl 스텁(telegram best-effort) — 무해 성공
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/curl"; chmod +x "$TMP/bin/curl"
}
teardown() { rm -rf "$TMP"; }

run_erp() { PATH="$TMP/bin:$PATH" run bash "$SCRIPT"; }
nudge_count() { cat "$ERP_NUDGE_FILE"; }

@test "already-applied DB: succeeds with no nudge and writes a fresh per-DB marker" {
  export ERP_TEST_SCENARIO="applied"
  run_erp
  [ "$status" -eq 0 ]
  [ "$(nudge_count)" = "0" ]                       # 멱등 — 이미 적용된 DB는 nudge하지 않는다
  grep -q "create configmap db-page-ready" "$ERP_KLOG"
  grep -q "ownerSecretResourceVersion=100" "$ERP_KLOG"
  grep -q "roSecretResourceVersion=100" "$ERP_KLOG"
  grep -q "apply -f" "$ERP_KLOG"                   # 마커 실제 upsert
}

@test "eventual: nudges (Cluster annotate) until passwordStatus populates, then writes the marker" {
  export ERP_TEST_SCENARIO="eventual"
  run_erp
  [ "$status" -eq 0 ]
  [ "$(nudge_count)" -ge 1 ]                        # 비어있을 때 reconcile 트리거(nudge)
  grep -q "create configmap db-page-ready" "$ERP_KLOG"
}

@test "never-applied: fails closed (non-zero) after exhausting polls, writes no marker" {
  export ERP_TEST_SCENARIO="never"
  run_erp
  [ "$status" -ne 0 ]                               # fail-closed → PostSync hook 실패 → cnpg-data Degraded
  [ "$(nudge_count)" = "$ERP_MAX_POLLS" ]           # 매 폴링마다 nudge 시도
  ! grep -q "apply -f" "$ERP_KLOG"                  # 미검증 DB엔 마커 방출 금지
}

@test "database-not-ready: fails closed when the Database CR never reaches applied=true" {
  export ERP_TEST_DB_APPLIED="false"
  run_erp
  [ "$status" -ne 0 ]
  ! grep -q "apply -f" "$ERP_KLOG"
}

@test "no databases: succeeds vacuously and writes no markers" {
  export ERP_TEST_DBS=""
  run_erp
  [ "$status" -eq 0 ]
  ! grep -q "apply -f" "$ERP_KLOG"
}

@test "idempotent: a second run on an already-applied DB also succeeds with no nudge" {
  export ERP_TEST_SCENARIO="applied"
  run_erp; [ "$status" -eq 0 ]
  : > "$ERP_KLOG"; printf '0' > "$ERP_NUDGE_FILE"
  run_erp; [ "$status" -eq 0 ]
  [ "$(nudge_count)" = "0" ]
}

@test "ensure-role-password Job is an unconditional fail-closed PostSync hook, registered in cnpg-data" {
  j="$ROOT/platform/cnpg/prod/ensure-role-password-job.yaml"
  grep -q 'argocd.argoproj.io/hook: PostSync' "$j"
  grep -q 'backoffLimit: 0' "$j"                   # 실패는 조용한 재시도가 아니라 Degraded로 표면화
  grep -q 'ensure-role-password.sh' "$j"
  k="$ROOT/platform/cnpg/prod/kustomization.yaml"
  grep -q 'ensure-role-password-job.yaml' "$k"     # 매 sync마다 무조건 실행되도록 등록
  grep -q 'ensure-role-password-rbac.yaml' "$k"
}
