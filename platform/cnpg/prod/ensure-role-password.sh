#!/usr/bin/env bash
# ensure-role-password — CNPG managed role 비번이 실제로 적용됐음을 결정적으로 보장하는
# ArgoCD PostSync hook Job 스크립트. cnpg-data 앱이 Synced된 뒤 매 sync마다 멱등 실행된다.
#
# 배경(#3 회귀 방지): provision-db가 만든 owner/ro 비번 SealedSecret이 Cluster CR(wave -1)보다
# 늦게 적용되면, CNPG가 비번 Secret 부재 상태로 managed role을 만들어 passwordStatus.<role>.
# resourceVersion이 비어 인증이 실패한다. wave -2(provision-db)는 방어 1층일 뿐이다 —
# 컨트롤러 지연/부분 reconcile/health 동작 변경으로 재현될 수 있어, 이 Job이 결정적 fallback이다.
#
# 동작(각 Database CR의 owner/ro 롤에 대해):
#   0) spec.ensure=absent인 CR은 통째로 건너뛴다(로그 1줄 + 스킵 카운트, rc는 0 유지) —
#      DROP 대상/완료 CR이라 검증할 롤 자체가 없다. ⚠️ 이 문이 없으면 2)가 **공허 통과**한다:
#      CNPG는 role DROP 뒤에도 passwordStatus 엔트리를 유지하므로 rv 존재만 재는 검사가 초록이
#      된다(2026-09-09 라이브 — purge 상태머신 PR-B sync에서 pg_roles에 없는 page/page_ro를
#      verified로 찍고 마커까지 썼다). 이 훅의 RBAC 안에 있는 존재 증인은 CR의 spec.ensure뿐이다:
#      cluster.status.managedRolesStatus.byStatus.reconciled는 ensure: absent로 reconcile된 role도
#      포함하고(같은 날 실측: reconciled=[ukkiee,page,page_ro]), 비번 Secret 값 대조는 secrets
#      읽기 권한이 필요해 경계 밖이다(ensure-role-password-rbac.yaml 헤더).
#   1) Database CR이 applied=true가 될 때까지(유한) 대기
#   2) cluster.status...passwordStatus[<role>].resourceVersion 가 채워질 때까지 폴링
#      (비어있음 = CNPG가 비번 미적용 → reconcile을 강제하려 Cluster를 annotate해 nudge)
#   3) 타임아웃 내 미충족이면 비0 종료(fail-closed) → PostSync hook 실패 → cnpg-data Degraded → 알림
#   4) 성공 시 per-DB freshness 마커 ConfigMap db-<name>-ready 방출
#      ({ownerSecretResourceVersion, roSecretResourceVersion, verifiedAt}) — activate-app이 소비.
#      passwordStatus.<role>.resourceVersion == 적용된 비번 Secret의 metadata.resourceVersion 이므로
#      (라이브 확인), 마커는 그 값을 secret rv로 기록한다. activate-app은 이를 현재 secret rv와 대조해
#      stale(회전 후 미적용/무관 Job 성공)을 거른다. 마커에는 그 Database CR의 ownerReferences를
#      단다 — 훅이 직접 apply하는 리소스라 ArgoCD tracking 밖이고, ownerRef가 없으면 CR 프룬도
#      teardown cleanup도 audit-orphans도 걷지 않아 **영구 고아**가 된다(2026-09-09 라이브 잔재
#      2건: db-page-ready·db-trip-mate-ready, owner가 손으로 삭제).
#
# ★nudge = Cluster annotate. 라이브 검증된 복구 경로다(2026-06-25 인시던트: 비번 Secret 변경만으론
#   CNPG 1.27 managed-role 재적용이 안 됐고, Cluster annotate가 reconcile을 트리거해 복구됐다).
#   annotate는 reconcile 트리거일 뿐 비번 값은 불변 — CNPG 소유권과 무충돌·멱등.
#
# ★ 왜 .ts가 아니라 셸인가: kustomize load-restrictor가 cross-dir 참조를 막아 이 스크립트는
#   kustomization과 same-dir여야 하고, 인클러스터 이미지 pg-tools에는 bun이 없다(bash+kubectl뿐).
#   테스트 가능성은 PATH-stub 단위테스트로 보존한다(test_ensure_role_password.bats).
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
# Database CR의 spec.ensure(present/absent). 조회 실패·필드 부재는 빈 문자열이 되고, 호출부는 그때
# **검증 경로로 간다**(absent 판정만 스킵) — 실패가 스킵으로 접히지 않는 방향이다. stderr는 죽이지
# 않는다: 진단문이 원인을 말해야 한다(형제 열거의 교훈).
db_ensure() {
  kubectl -n "$NS" get database "$1" -o jsonpath='{.spec.ensure}' || true
}
# Database CR의 metadata.uid — 마커 ConfigMap의 ownerReferences에 실린다(GC 연결의 유일한 키).
db_uid() {
  kubectl -n "$NS" get database "$1" -o jsonpath='{.metadata.uid}' || true
}
# Cluster annotate로 managed-role reconcile을 트리거(비번 값 불변·멱등)
nudge() {
  kubectl -n "$NS" annotate cluster "$CLUSTER" \
    "ensure-role-password.homelab/nudge=$(date -u +%s 2>/dev/null || echo nudge)" --overwrite >/dev/null 2>&1 || true
}

# 한 롤이 '비번 적용됨'(passwordStatus.resourceVersion 채워짐)이 될 때까지 보장.
# 성공 시 VERIFIED_RV에 그 rv를 담고 0 반환, 타임아웃이면 fail(비0 종료).
# ⚠️ 이 검사는 **존재하는 role**을 전제한다 — DROP된 role의 엔트리를 CNPG가 유지하기 때문에
#    (헤더 0) 참조), ensure=absent CR은 호출부에서 걸러진 뒤에만 여기 들어온다.
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
# ⚠️ 매니페스트를 printf로 조립한다 — `kubectl create configmap --dry-run=client`에는
#    ownerReferences를 넣는 플래그가 없고, 인클러스터 이미지 pg-tools에는 yq도 bun도 없다
#    (bash+kubectl뿐). ownerRef가 이 함수의 존재 이유의 절반이다(헤더 4) 고아 잔재).
# ⚠️ blockOwnerDeletion은 **의도적으로 달지 않는다** — 그 필드는 owner의 finalizers 하위리소스
#    update 권한을 요구해 RBAC 경계를 넓힌다. 마커는 소비자가 fail-closed로 읽는 캐시라
#    "owner 삭제를 막는" 의미가 없고, 필요한 것은 GC 방향 한쪽뿐이다.
# ⚠️ ownerRef는 **동일 네임스페이스** owner만 유효하다 — Database CR과 마커 둘 다 $NS다.
write_marker() {
  local db="$1" owner_rv="$2" ro_rv="$3" uid="$4" now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  printf '%s\n' \
    'apiVersion: v1' \
    'kind: ConfigMap' \
    'metadata:' \
    "  name: db-${db}-ready" \
    "  namespace: ${NS}" \
    '  ownerReferences:' \
    '    - apiVersion: postgresql.cnpg.io/v1' \
    '      kind: Database' \
    "      name: ${db}" \
    "      uid: ${uid}" \
    'data:' \
    "  ownerSecretResourceVersion: \"${owner_rv}\"" \
    "  roSecretResourceVersion: \"${ro_rv}\"" \
    "  verifiedAt: \"${now}\"" \
    | kubectl -n "$NS" apply -f - >/dev/null
  echo "[erp] db=${db} marker db-${db}-ready written (owner=${owner_rv} ro=${ro_rv} ownerRef=${uid})"
}

main() {
  local dbs db ens uid owner_rv ro_rv count=0 skipped=0
  # ⚠️ 열거 rc를 버리면 안 된다 — 예전 형태(`2>/dev/null || true`)는 권한 거부·apiserver 오류·NS
  #    오타를 전부 "DB 0건"과 **같은 값**으로 접어 훅이 성공으로 끝났다(형제 wait_db_ready/ensure_role은
  #    반대로 fail-closed다). 이 파일이 존재하는 이유(#3 회귀 차단)가 그 침묵으로 무효화된다:
  #    per-DB 마커도 안 나가는데 ArgoCD는 cnpg-data를 Synced/Healthy로 보고한다.
  #    레포 SSOT의 「`findings=$(… || true)` — 검출기가 죽어도 '0곳 OK'를 내는 fail-open」 클래스다.
  #    0건은 여전히 rc 0 + 빈 출력이라 아래 vacuous 성공 의미론은 그대로다. `2>/dev/null`도 없앤다
  #    — 진단 stderr가 실패 원인을 말해야 한다.
  if ! dbs="$(kubectl -n "$NS" get database -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"; then
    fail "Database 열거 실패(권한/접속) — fail-closed"
  fi
  if [ -z "$dbs" ]; then
    echo "[erp] no Database CRs in ns=${NS} — nothing to verify"
    return 0
  fi
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    echo "[erp] === db=${db} (owner=${db}, ro=${db}_ro) ==="
    # ensure=absent = purge 상태머신 PR-A/PR-B가 DROP을 지시한 CR. 검증할 롤이 없으므로 폴링도
    # 마커도 하지 않는다. 스킵은 **성공 카운트 밖**이지만 침묵도 아니다 — 열거 실패(비-0)와
    # 구별되는 rc 0 + 스킵 건수 로그다(마지막 요약 줄).
    ens="$(db_ensure "$db")"
    if [ "$ens" = "absent" ]; then
      skipped=$((skipped + 1))
      echo "[erp] db=${db} spec.ensure=absent — DROP 대상 CR, 롤 검증·마커 생략"
      continue
    fi
    count=$((count + 1))
    wait_db_ready "$db"
    ensure_role "$db";       owner_rv="$VERIFIED_RV"
    ensure_role "${db}_ro";  ro_rv="$VERIFIED_RV"
    # uid 부재 = CR이 중간에 사라졌거나 조회가 깨진 것. ownerRef 없는 마커는 아무도 걷지 못하는
    # 고아가 되므로(티켓 51) 쓰지 않고 fail-closed로 끝낸다.
    uid="$(db_uid "$db")"
    [ -n "$uid" ] || fail "Database ${db} metadata.uid 조회 실패 — ownerRef 없는 마커는 쓰지 않는다(fail-closed)"
    write_marker "$db" "$owner_rv" "$ro_rv" "$uid"
  done <<< "$dbs"
  if [ "$skipped" -gt 0 ]; then
    echo "[erp] all ${count} database(s) verified, per-DB markers fresh (${skipped} ensure=absent CR(s) skipped)"
  else
    echo "[erp] all ${count} database(s) verified, per-DB markers fresh"
  fi
}

main "$@"
