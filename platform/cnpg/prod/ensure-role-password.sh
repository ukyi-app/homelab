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
#   1) Database CR이 applied=true가 될 때까지(유한) 대기 — **absent CR도 포함해서** 기다린다:
#      absent CR의 applied=true는 "DROP 완료"라는 뜻이고, 막힌 논리 DB DROP을 재는 자동 신호는
#      이 훅뿐이다(Database CR용 ArgoCD health customization·알림 룰 모두 0건, 2026-09-09 확인).
#   1b) 그다음 spec.ensure=absent인 CR은 롤 검증·마커를 건너뛴다(로그 1줄 + 스킵 카운트, rc 0 유지)
#      — DROP 대상/완료 CR이라 검증할 롤 자체가 없다. 조회 실패·필드 부재는 absent가 아니므로
#      **검증 경로**로 간다(실패가 스킵으로 접히지 않는 방향).
#   2) 롤이 '지금 선언돼 있고 비번이 적용됨'이 될 때까지 폴링 — **두 증인의 곱**이다:
#      ① cluster.status...passwordStatus[<role>].resourceVersion 채워짐(비번 적용)
#      ② cluster.status...byStatus.reconciled 멤버십(role이 지금 선언·reconcile됨 = 존재 증인)
#      (미충족 = CNPG 미적용/미reconcile → 강제하려 Cluster를 annotate해 nudge)
#      ⚠️ ①만 재면 **공허 통과**한다: CNPG는 role DROP 뒤에도 passwordStatus 엔트리를 유지한다
#      (2026-09-09 라이브 — purge PR-B sync에서 pg_roles에 없는 page/page_ro를 verified로 찍고
#      마커까지 썼고, managed.roles에서 완전히 사라진 뒤에도 그 rv가 하루 뒤까지 잔존했다).
#      1b)의 spec.ensure 스킵은 **CR이 아직 있을 때만** 그 창을 덮는다 — 같은 이름으로 재프로비저닝하면
#      CR은 present라 스킵이 안 걸리고 옛 rv가 그대로 통과한다. 그래서 ②를 곱한다. 비번 Secret 값
#      대조는 secrets 읽기 권한이 필요해 경계 밖이다(ensure-role-password-rbac.yaml 헤더).
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
UID_MAX_TRIES="${ERP_UID_MAX_TRIES:-3}"            # ownerRef용 uid 읽기 재시도 상한
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
# role이 cluster.status.managedRolesStatus.byStatus.reconciled에 있는가 = **지금 선언·reconcile된
# managed role**이라는 존재 증인. passwordStatus는 DROP 뒤에도 남지만 reconciled는 선언이 사라지면
# 빠진다(2026-09-09 라이브: managed.roles에 ukkiee만 남은 상태에서 reconciled=[ukkiee]인데
# passwordStatus에는 page/page_ro/trip-mate/trip-mate_ro가 그대로 있었다).
# ⚠️ 조회 실패는 '멤버십 없음'이 되어 fail-closed 방향이다(폴링 소진 → 비-0).
# ⚠️ 파이프 대신 herestring — `kubectl … | grep -q`는 pipefail 아래에서 SIGPIPE 141 거짓 FAIL 클래스다.
role_reconciled() {
  local names
  names="$(kubectl -n "$NS" get cluster "$CLUSTER" \
    -o jsonpath='{range .status.managedRolesStatus.byStatus.reconciled[*]}{@}{"\n"}{end}' 2>/dev/null || true)"
  grep -qxF -- "$1" <<<"$names"
}
# Database CR의 metadata.uid — 마커 ConfigMap의 ownerReferences에 실린다(GC 연결의 유일한 키).
# ⚠️ 유한 재시도한다: 빈 uid는 호출부에서 fail(=cnpg-data Degraded + telegram)인데, 형제 읽기
#    (wait_db_ready·ensure_role)는 전부 재시도하므로 여기만 단발이면 apiserver 일시 오류 1회가
#    곧 알림이 된다. 소진 후 빈 문자열로 끝나는 fail-closed 방향은 그대로다.
db_uid() {
  local uid i
  for ((i=1; i<=UID_MAX_TRIES; i++)); do
    uid="$(kubectl -n "$NS" get database "$1" -o jsonpath='{.metadata.uid}' || true)"
    if [ -n "$uid" ]; then printf '%s' "$uid"; return 0; fi
    if [ "$i" -lt "$UID_MAX_TRIES" ]; then sleep "$POLL_INTERVAL"; fi
  done
  return 0   # 빈 문자열 = 호출부 fail-closed(ownerRef 없는 마커는 쓰지 않는다)
}
# Cluster annotate로 managed-role reconcile을 트리거(비번 값 불변·멱등)
nudge() {
  kubectl -n "$NS" annotate cluster "$CLUSTER" \
    "ensure-role-password.homelab/nudge=$(date -u +%s 2>/dev/null || echo nudge)" --overwrite >/dev/null 2>&1 || true
}

# 한 롤이 '지금 선언돼 있고 비번이 적용됨'이 될 때까지 보장 — passwordStatus rv **∧** reconciled
# 멤버십(헤더 2)). 성공 시 VERIFIED_RV에 그 rv를 담고 0 반환, 타임아웃이면 fail(비0 종료).
# ⚠️ 호출부의 ensure=absent 스킵은 이 검사에 role 존재를 보장해 주지 못한다 — CR이 프룬된 뒤나
#    같은 이름으로 재프로비저닝하는 창에서는 CR이 present이기 때문이다. 존재 증인은 ②뿐이다.
ensure_role() {
  local role="$1" got rec i
  for ((i=1; i<=MAX_POLLS; i++)); do
    got="$(pwstatus_rv "$role")"
    if role_reconciled "$role"; then rec=yes; else rec=no; fi
    if [ -n "$got" ] && [ "$rec" = "yes" ]; then
      VERIFIED_RV="$got"
      echo "[erp] role=${role} verified (rv=${got})"
      return 0
    fi
    echo "[erp] role=${role} not verified (rv=${got:-<empty>} reconciled=${rec}) — nudge ${i}/${MAX_POLLS}"
    nudge
    sleep "$POLL_INTERVAL"
  done
  fail "role=${role} 비번 미적용/미선언: passwordStatus.resourceVersion 채워짐 ∧ byStatus.reconciled 멤버십이 ${MAX_POLLS}회 폴링 내 동시 충족되지 않음(fail-closed)"
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
# ⚠️ 이름 스칼라는 **인용한다**. kubectl은 sigs.k8s.io/yaml(=YAML 1.1)로 디코드해 no/on/y/yes를
#    bool로 읽는데, 그 이름들은 RESOURCE_NAME_RE(tools/lib/identity.ts)가 허용하고 예약어도 아니다.
#    2026-09-09 실측: 인용 없는 `name: no`는 `json: cannot unmarshal bool into Go struct field
#    OwnerReference.metadata.ownerReferences.name`으로 apply가 죽고 → 훅 비-0 → cnpg-data 전체 Degraded.
write_marker() {
  local db="$1" owner_rv="$2" ro_rv="$3" uid="$4" now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  printf '%s\n' \
    'apiVersion: v1' \
    'kind: ConfigMap' \
    'metadata:' \
    "  name: \"db-${db}-ready\"" \
    "  namespace: \"${NS}\"" \
    '  ownerReferences:' \
    '    - apiVersion: postgresql.cnpg.io/v1' \
    '      kind: Database' \
    "      name: \"${db}\"" \
    "      uid: \"${uid}\"" \
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
    # ⚠️ 스킵은 이 대기 **뒤**다. absent CR의 applied=true는 "DROP 완료"라는 뜻이고, 막힌 DROP을
    #    재는 자동 신호는 이 훅뿐이다(Database CR용 ArgoCD health customization 0건 · cnpg Database
    #    알림 룰 0건, 2026-09-09). 스킵을 앞에 두면 그 실패가 rc 0으로 조용해진다.
    wait_db_ready "$db"
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
