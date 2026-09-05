#!/usr/bin/env bats
# ensure-role-password.sh — CNPG managed role 비번 적용을 결정적으로 보장하는 ArgoCD PostSync hook Job 스크립트.
# kubectl/curl을 PATH 스텁으로 대체하고 폴링/nudge/타임아웃/마커 상태머신을 fake-clock(POLL_INTERVAL=0 +
# 유한 MAX_POLLS)으로 결정적으로 검증한다 — 라이브 클러스터 무접근.
# ⚠️ @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐, AGENTS.md). 중간 단언은 [ ]/명령만.

# ⚠️ **피연산자 실재 증인 + 거부 문구 양성 대조.** `run bash "$SCRIPT"`는 스크립트가 없으면
#    rc **127**로 죽어 `-ne 0`을 그대로 만족한다. 실측(2026-09-02, 스크립트를 지운 격리 트리):
#    7건 중 「database-not-ready: fails closed」가 `ok`였다(마커 부재 단언도 빈 로그에 대해 참이다).
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$ROOT/platform/cnpg/prod/ensure-role-password.sh"
  [ -f "$SCRIPT" ]
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
    # 열거 실패(권한 거부·apiserver 오류) 주입 — fail-closed 증인용
    [ -n "${ERP_TEST_ENUM_FAIL:-}" ] && exit 1
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
  printf '%s' "$output" | grep -qF -- 'applied=true 미도달(fail-closed)'
  ! grep -q "apply -f" "$ERP_KLOG"
}

@test "no databases: succeeds vacuously and writes no markers" {
  export ERP_TEST_DBS=""
  run_erp
  [ "$status" -eq 0 ]
  ! grep -q "apply -f" "$ERP_KLOG"
}

@test "enumeration failure fails closed (a denied list is not 'zero databases')" {
  # ⚠️ 위 @test의 vacuous 성공과 **같은 값**이 되면 안 되는 자리다. 예전 스크립트는 열거를
  #    `2>/dev/null || true`로 감싸 권한 거부·apiserver 오류·NS 오타를 전부 "DB 0건"으로 읽고
  #    return 0 했다 — 훅은 Succeeded, ArgoCD는 Synced/Healthy, 마커는 0건이다.
  #    실 트리거는 RBAC 리팩터(지속형)와 sync 중 apiserver 일시 오류다.
  export ERP_TEST_ENUM_FAIL=1
  run_erp
  [ "$status" -ne 0 ]
  ! grep -q "apply -f" "$ERP_KLOG"   # 못 물어본 DB에 마커를 방출하지 않는다
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
  # ⚠️ **배선만으로는 "무조건"이 성립하지 않는다** — 훅이 무언가를 검증하려면 Role에
  #    `postgresql.cnpg.io/databases: get,list`가 있어야 한다. 그 규칙을 지워도 이 파일 7/7이
  #    초록이었고(실측) tests/gates/test_rbac-verbs.bats도 3/3이었다 — 그 게이트는 **쓰기 verb
  #    화이트리스트**(상한)라 읽기 규칙 제거는 원리적으로 위반이 아니다.
  #    이제 열거 실패는 런타임에서 fail-closed로 잡히지만(위 @test), 여기 한 줄이 검출을 머지
  #    시점으로 앞당긴다. `[select(...)] | length` 형태라 `yq -e` false-exit1 함정 비대상이다.
  r="$ROOT/platform/cnpg/prod/ensure-role-password-rbac.yaml"
  v="$(yq ea '[select(.kind=="Role") | .rules[] | select(.resources[]=="databases") | .verbs[]] | sort | join(" ")' "$r")"
  printf '%s' "$v" | grep -qxF -- 'get list'
}

@test "ensure-role-password Job container is hardened (no privesc, all caps dropped, seccomp RuntimeDefault)" {
  # spec-others-2(round8) — 형제 hardened @test 관용구(test_basebackup.bats:34-38)를 그대로 적용.
  # 기존 값은 이미 올바르다(allowPrivilegeEscalation:false·capabilities.drop:[ALL]·pod-level
  # seccompProfile RuntimeDefault) — 값 자체를 바꾸지 않고 등식 witness만 추가한다.
  # 뮤테이션 재현(2026-09-05): allowPrivilegeEscalation false->true 치환 후 이 파일(9/9)·
  # test_security-gates.bats(8/8) 재실행 — 전건 ok(17/17, 변화 없음, 사본으로 원복).
  j="$ROOT/platform/cnpg/prod/ensure-role-password-job.yaml"
  grep -q 'allowPrivilegeEscalation: false' "$j"
  grep -qF 'drop: [ALL]' "$j"
  grep -q 'type: RuntimeDefault' "$j"
}

@test "the configMapGenerator files roster still points at the Job's own script" {
  # 위 @test는 `resources`(렌더 대상) 축만 잰다 — Job이 마운트하는 ConfigMap이 실제로 이
  # 스크립트를 굽는지(configMapGenerator.files)는 required gate 안에서 무증인이었다(2026-09-05
  # 실측: 이 files 항목을 `# MUTATED`로 치환해도 required 레인 전건 초록, ci-exclude 등재
  # test_kustomize_build.bats만 not ok). 리터럴이 아니라 Job의 command[1]에서 파생한다 — 스크립트
  # 개명·경로 드리프트까지 잡는다.
  j="$ROOT/platform/cnpg/prod/ensure-role-password-job.yaml"
  k="$ROOT/platform/cnpg/prod/kustomization.yaml"
  key="$(basename "$(yq '.spec.template.spec.containers[0].command[1]' "$j")")"
  yq '.configMapGenerator[] | select(.name=="ensure-role-password-script") | .files[]' "$k" \
    | grep -qxF "$key"
}
