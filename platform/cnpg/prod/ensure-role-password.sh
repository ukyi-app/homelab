#!/usr/bin/env bash
# ensure-role-password — CNPG managed role 비번이 실제로 적용됐음을 결정적으로 보장하는
# ArgoCD PostSync hook Job 스크립트. cnpg-data 앱이 Synced된 뒤 매 sync마다 멱등 실행된다.
#
# 배경(#3 회귀 방지): provision-db가 만든 owner/ro 비번 SealedSecret이 Cluster CR(wave -1)보다
# 늦게 적용되면, CNPG가 비번 Secret 부재 상태로 managed role을 만들어 passwordStatus.<role>.
# resourceVersion이 비어 인증이 실패한다. wave -2(provision-db Task 1)는 방어 1층일 뿐이다 —
# 컨트롤러 지연/부분 reconcile/health 동작 변경으로 재현될 수 있어, 이 Job이 결정적 fallback이다.
#
# 동작(각 Database CR의 owner/ro 롤에 대해):
#   1) Database CR이 applied=true가 될 때까지(유한) 대기
#   2) cluster.status...passwordStatus[<role>].resourceVersion 가 채워질 때까지 폴링
#      (비어있음 = CNPG가 비번 미적용 → reconcile을 강제하려 Cluster를 annotate해 nudge)
#   3) 타임아웃 내 미충족이면 비0 종료(fail-closed) → PostSync hook 실패 → cnpg-data Degraded → 알림
#   4) 성공 시 per-DB freshness 마커 ConfigMap db-<name>-ready 방출
#      ({ownerSecretResourceVersion, roSecretResourceVersion, verifiedAt}) — activate-app이 소비.
#      passwordStatus.<role>.resourceVersion == 적용된 비번 Secret의 metadata.resourceVersion 이므로
#      (라이브 확인), 마커는 그 값을 secret rv로 기록한다. activate-app은 이를 현재 secret rv와 대조해
#      stale(회전 후 미적용/무관 Job 성공)을 거른다.
#
# ★nudge = Cluster annotate. 라이브 검증된 복구 경로다(2026-06-25 인시던트: 비번 Secret 변경만으론
#   CNPG 1.27 managed-role 재적용이 안 됐고, Cluster annotate가 reconcile을 트리거해 복구됐다).
#   annotate는 reconcile 트리거일 뿐 비번 값은 불변 — CNPG 소유권과 무충돌·멱등.
#
# ★구현 노트: 계획은 tools/ensure-role-password.ts(.ts)를 제안했으나, (a) kustomize load-restrictor가
#   cross-dir 파일 참조를 막아 스크립트는 이 kustomization과 same-dir여야 하고, (b) 인클러스터 이미지는
#   restore-drill과 동일한 pg-tools(bash+kubectl; bun 없음)를 재사용한다. .ts의 목적(테스트 가능한
#   폴링/nudge/타임아웃 상태머신)은 PATH-stub 단위테스트(test_ensure_role_password.bats, 기존 kubeseal
#   스텁 패턴과 동일)로 보존했다 — restore-drill-script.sh 컨벤션을 따른 정당한 편차.
set -euo pipefail

NS="${ERP_NAMESPACE:-database}"
CLUSTER="${ERP_CLUSTER:-pg}"
POLL_INTERVAL="${ERP_POLL_INTERVAL_SECONDS:-10}"   # 폴링 간격(초)
MAX_POLLS="${ERP_MAX_POLLS:-30}"                   # 롤당 30 × 10s ≈ 5분 타임아웃
READY_MAX_POLLS="${ERP_READY_MAX_POLLS:-30}"       # Database Ready 대기 상한
VERIFIED_RV=""                                     # ensure_role 성공 시 검증된 resourceVersion

# telegram 알림(best-effort, restore-drill-alerting 재사용). 미설정이면 조용히 생략 — 하드 의존 아님.
notify_fail() {
  local detail="$1" stamp text
  echo "::error::ensure-role-password: ${detail}"
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
  stamp="$(TZ=Asia/Seoul date '+%m/%d %H:%M' 2>/dev/null || true)"
  text="🔴 <b>DB 롤 비번 적용</b> — 실패
대상: ${detail}"
  [ -n "$stamp" ] && text="${text}
시각: ${stamp} KST"
  curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "parse_mode=HTML" >/dev/null 2>&1 || true
}
fail() { notify_fail "$1"; exit 1; }

# cluster passwordStatus[<role>].resourceVersion — bracket notation(하이픈/언더스코어 롤명 안전), 없으면 빈 문자열
pwstatus_rv() {
  kubectl -n "$NS" get cluster "$CLUSTER" \
    -o jsonpath="{.status.managedRolesStatus.passwordStatus['$1'].resourceVersion}" 2>/dev/null || true
}
# Cluster annotate로 managed-role reconcile을 트리거(비번 값 불변·멱등)
nudge() {
  kubectl -n "$NS" annotate cluster "$CLUSTER" \
    "ensure-role-password.homelab/nudge=$(date -u +%s 2>/dev/null || echo nudge)" --overwrite >/dev/null 2>&1 || true
}

# 한 롤이 '비번 적용됨'(passwordStatus.resourceVersion 채워짐)이 될 때까지 보장.
# 성공 시 VERIFIED_RV에 그 rv를 담고 0 반환, 타임아웃이면 fail(비0 종료).
ensure_role() {
  local role="$1" got i
  for ((i=1; i<=MAX_POLLS; i++)); do
    got="$(pwstatus_rv "$role")"
    if [ -n "$got" ]; then
      VERIFIED_RV="$got"
      echo "[erp] role=${role} verified (rv=${got})"
      return 0
    fi
    echo "[erp] role=${role} passwordStatus empty — nudge ${i}/${MAX_POLLS}"
    nudge
    sleep "$POLL_INTERVAL"
  done
  fail "role=${role} 비번 미적용: passwordStatus.resourceVersion이 ${MAX_POLLS}회 폴링 내 채워지지 않음(fail-closed)"
}

# Database CR이 applied=true가 될 때까지 대기(유한); 미도달이면 fail
wait_db_ready() {
  local db="$1" applied i
  for ((i=1; i<=READY_MAX_POLLS; i++)); do
    applied="$(kubectl -n "$NS" get database "$db" -o jsonpath='{.status.applied}' 2>/dev/null || true)"
    [ "$applied" = "true" ] && return 0
    echo "[erp] db=${db} not ready (applied=${applied:-<none>}) ${i}/${READY_MAX_POLLS}"
    sleep "$POLL_INTERVAL"
  done
  fail "Database ${db} applied=true 미도달(fail-closed)"
}

# per-DB freshness 마커 ConfigMap upsert(멱등): db-<name>-ready
write_marker() {
  local db="$1" owner_rv="$2" ro_rv="$3" now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  kubectl -n "$NS" create configmap "db-${db}-ready" \
    --from-literal=ownerSecretResourceVersion="$owner_rv" \
    --from-literal=roSecretResourceVersion="$ro_rv" \
    --from-literal=verifiedAt="$now" \
    --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
  echo "[erp] db=${db} marker db-${db}-ready written (owner=${owner_rv} ro=${ro_rv})"
}

main() {
  local dbs db owner_rv ro_rv count=0
  dbs="$(kubectl -n "$NS" get database -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [ -z "$dbs" ]; then
    echo "[erp] no Database CRs in ns=${NS} — nothing to verify"
    return 0
  fi
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    count=$((count + 1))
    echo "[erp] === db=${db} (owner=${db}, ro=${db}_ro) ==="
    wait_db_ready "$db"
    ensure_role "$db";       owner_rv="$VERIFIED_RV"
    ensure_role "${db}_ro";  ro_rv="$VERIFIED_RV"
    write_marker "$db" "$owner_rv" "$ro_rv"
  done <<< "$dbs"
  echo "[erp] all ${count} database(s) verified, per-DB markers fresh"
}

main "$@"
