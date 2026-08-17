#!/usr/bin/env bats
# restore-drill **행위** 게이트(M17) — grep이 아니라 스크립트를 실제로 실행해
# "pre-flight 정리가 apply보다 먼저 돈다"·"복구가 실제로 일어났다"·"열거 실패 ≠ 0건"을
# 스텁 kubectl/curl의 호출 순서·횟수와 FAIL 문구로 단언한다.
# 선례: tests/gates/test_digest-exporter-producer.bats(스텁 PATH + argv 순서·줄번호 단언),
#       platform/cnpg/prod/test_ensure_role_password.bats(kubectl 스텁 + 호출 로그, 같은 디렉토리),
#       tests/test_destroy-node.bats(argv 기록기 + 부재 단언 + 양성 대조).
# ⚠️ @test 이름은 영어만(check-skeleton.sh의 CJK 가드 — 디렉토리 실행 시 인코딩이 깨진다).
# ⚠️ 중간 단언은 `[ … ]`/단순 명령/`run …; [ … ]`만 — 줄머리 `!`/`[[`는 check-bats-style.sh가 hard-zero.
# ⚠️ CI 러너엔 kubectl이 없다 — 스텁이 PATH 선두가 아니면 죽는 것이 맞다(라이브 접근 사고 방지).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SH="$ROOT/platform/cnpg/prod/restore-drill-script.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$BIN" "$OUT"
  KLOG="$OUT/kubectl.argv" # 줄 번호가 곧 호출 순서
  CLOG="$OUT/curl.argv"
  APPLIED="$OUT/applied.yaml"
  METRICS="$OUT/metrics.txt"
  : >"$KLOG"
  : >"$CLOG"
  : >"$APPLIED"
  : >"$METRICS"
  printf '0' >"$OUT/cluster" # 기본: drill 잔여물 없음
  printf '0' >"$OUT/pvc"
  printf '0' >"$OUT/phasepolls"
  printf '0' >"$OUT/pvclists"

  cat >"$BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KLOG"
case "$*" in
  *"plugins["*)
    printf 'pg-nuc' ;;
  *"get cluster pg-restore-drill"*"status.phase"*)
    n="$(cat "$OUT/phasepolls")"; n=$((n + 1)); printf '%s' "$n" > "$OUT/phasepolls"
    if [ "${DRILL_STUB_INSTANT_HEALTHY:-0}" = "1" ] || [ "$n" -ge 2 ]; then
      printf 'Cluster in healthy state'
    else
      printf 'Setting up primary'
    fi ;;
  *"get cluster -o name"*)
    [ "$(cat "$OUT/cluster")" = "1" ] && printf 'cluster.postgresql.cnpg.io/pg-restore-drill\n'
    printf 'cluster.postgresql.cnpg.io/pg\n' ;;          # 라이브 pg는 항상 있다(스코프 음성 대조)
  *"get pvc -o name"*)
    n="$(cat "$OUT/pvclists")"; n=$((n + 1)); printf '%s' "$n" > "$OUT/pvclists"
    [ "${DRILL_LIST_FAILS:-0}" = "1" ] && exit 1
    [ "$n" -gt "${DRILL_LIST_FAILS_AFTER:-999999}" ] && exit 1
    [ "$(cat "$OUT/pvc")" = "1" ] && printf 'persistentvolumeclaim/pg-restore-drill-1\npersistentvolumeclaim/pg-restore-drill-1-wal\n'
    printf 'persistentvolumeclaim/pg-1\n' ;;             # 라이브 PVC(스코프 음성 대조)
  *"delete cluster"*)
    [ "${DRILL_DELETE_FAILS:-0}" = "1" ] || printf '0' > "$OUT/cluster" ;;
  *"delete pvc"*|*"delete persistentvolumeclaim/"*)
    [ "${DRILL_DELETE_FAILS:-0}" = "1" ] || printf '0' > "$OUT/pvc" ;;
  *"apply -f -"*)
    cat >> "$APPLIED"; printf '1' > "$OUT/cluster"; printf '1' > "$OUT/pvc" ;;
  *"exec pg-restore-drill-1"*) printf '%s' "${DRILL_ROWS_DRILL:-7}" ;;
  *"exec pg-1"*)               printf '%s' "${DRILL_ROWS_LIVE:-5}" ;;
esac
exit 0
STUB
  # curl 스텁: 메트릭 push만 stdin을 읽는다(telegram/healthchecks는 stdin이 없어 cat하면 블록된다).
  cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLOG"
case "$*" in *import/prometheus*) cat >> "$METRICS" ;; esac
exit 0
STUB
  chmod +x "$BIN/kubectl" "$BIN/curl"
}

seed_survivor() {
  printf '1' >"$OUT/cluster"
  printf '1' >"$OUT/pvc"
}

# ⚠️ set -u라 TELEGRAM_*/HEALTHCHECKS_URL은 반드시 준다(TG·ping이 무조건 확장된다).
run_drill() {
  run env PATH="$BIN:$PATH" OUT="$OUT" KLOG="$KLOG" CLOG="$CLOG" APPLIED="$APPLIED" METRICS="$METRICS" \
    TELEGRAM_BOT_TOKEN=tok TELEGRAM_CHAT_ID=123 \
    HEALTHCHECKS_URL='http://hc.invalid/ping' METRICS_PUSH_URL='http://vm.invalid:8428' \
    DRILL_POLL_INTERVAL_SECONDS=0 DRILL_MAX_POLLS=4 \
    DRILL_PURGE_POLL_SECONDS=0 DRILL_PURGE_MAX_POLLS=3 \
    "$@" bash "$SH"
}
kline() { grep -nF -- "$1" "$KLOG" | head -1 | cut -d: -f1; }
kcount() { grep -cF -- "$1" "$KLOG" || true; }

@test "pre-flight purges the drill Cluster before the very first apply (call order, not grep)" {
  run_drill
  [ "$status" -eq 0 ]
  d="$(kline 'delete cluster pg-restore-drill')"
  a="$(kline 'apply -f -')"
  [ -n "$d" ] # 양성 대조: pre-flight가 실재한다
  [ -n "$a" ] # 양성 대조: apply가 실재한다
  [ "$d" -lt "$a" ] # ★ M17의 핵심 불변식
}

@test "pre-flight purges the drill PVCs too, also before the first apply" {
  run_drill
  [ "$status" -eq 0 ]
  p="$(kline 'delete pvc -l cnpg.io/cluster=pg-restore-drill')"
  a="$(kline 'apply -f -')"
  [ -n "$p" ]
  [ "$p" -lt "$a" ] # Cluster만 지우면 남은 PGDATA 재사용으로 같은 거짓 PASS가 재현된다
}

@test "the remnant sweep is name-scoped: the live pg cluster and its PVC are never deleted" {
  seed_survivor
  run_drill
  [ "$status" -eq 0 ]
  run grep -nE '(^| )delete (cluster pg( |$)|persistentvolumeclaim/pg-1( |$))' "$KLOG"
  [ "$status" -ne 0 ]
  # 양성 대조: 같은 정규식이 실제로 무언가를 잡을 수 있다(검출기가 썩지 않았다)
  printf 'delete cluster pg --ignore-not-found\n' >"$OUT/fixture"
  run grep -nE '(^| )delete (cluster pg( |$)|persistentvolumeclaim/pg-1( |$))' "$OUT/fixture"
  [ "$status" -eq 0 ]
}

@test "a survivor is swept and the run CONTINUES to a real restore, tagged ORPHAN-FOUND" {
  seed_survivor
  run_drill
  [ "$status" -eq 0 ]
  [ -s "$APPLIED" ] # 중단하지 않는다 — 청소 후 진짜 복구를 돌린다
  grep -qF 'restore_drill_last_success_timestamp' "$METRICS"
  grep -qF 'ORPHAN-FOUND' "$CLOG" # 사건이 검색 가능한 고정 토큰으로 남는다
  grep -qF '복원드릴' "$CLOG"        # 기존 enum 라벨 재사용(신규 발화처 등록 불필요)
}

@test "a clean run carries no ORPHAN-FOUND tag (the tag is not vacuously always present)" {
  run_drill
  [ "$status" -eq 0 ]
  run grep -cF 'ORPHAN-FOUND' "$CLOG"
  [ "$output" = "0" ]
}

@test "a survivor that refuses to die aborts before apply, and the polling is what decides" {
  seed_survivor
  run_drill DRILL_DELETE_FAILS=1
  [ "$status" -ne 0 ]
  [ ! -s "$APPLIED" ]
  [ ! -s "$METRICS" ]
  # ★ 폴링이 실재한다는 판별 가능한 증거 — purge 루프를 지우고 return 0으로 바꾸면 둘 다 사라진다
  printf '%s' "$output" | grep -qF 'purge attempt'
  grep -qF '수렴하지 않는다' "$CLOG"
  run grep -cF '지웠는지 확인할 수 없다' "$CLOG"
  [ "$output" = "0" ] # 열거 실패 갈래와 혼동되지 않는다
}

@test "purge re-fires the deletes every poll and the EXIT trap does not double it" {
  seed_survivor
  run_drill DRILL_DELETE_FAILS=1
  [ "$status" -ne 0 ]
  # DRILL_PURGE_MAX_POLLS=3 → 정확히 3회. 1회면 재발사 없음, 6회면 trap이 pre-flight 앞에 무장돼 있다.
  run kcount 'delete cluster pg-restore-drill'
  [ "$output" = "3" ]
}

@test "enumeration failure at the gate is not read as zero remnants (fail-closed)" {
  run_drill DRILL_LIST_FAILS=1
  [ "$status" -ne 0 ]
  [ ! -s "$APPLIED" ]
  [ ! -s "$METRICS" ]
  grep -qF '열거하지 못했다' "$CLOG"
}

@test "enumeration failure DURING purge reports enumeration, not finalizers" {
  seed_survivor
  run_drill DRILL_LIST_FAILS_AFTER=2
  [ "$status" -ne 0 ]
  [ ! -s "$APPLIED" ]
  grep -qF '확인할 수 없다' "$CLOG"
  run grep -cF '수렴하지 않는다' "$CLOG"
  [ "$output" = "0" ] # 틀린 원인(finalizer/operator)을 지목하지 않는다
}

@test "a cluster that is already healthy on the FIRST poll fails: no recovery happened" {
  run_drill DRILL_STUB_INSTANT_HEALTHY=1
  [ "$status" -ne 0 ]
  [ ! -s "$METRICS" ]
  run grep -cF 'hc.invalid' "$CLOG"
  [ "$output" = "0" ]
  grep -qF '첫 폴링에 이미 healthy' "$CLOG"
}

@test "the happy path observes a non-healthy phase before healthy (the witness is reachable)" {
  run_drill
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'phase=Setting up primary'
  printf '%s' "$output" | grep -qF 'phase=Cluster in healthy state'
}

@test "happy path applies a fresh recovery bootstrap aimed at the derived archive (positive control)" {
  run_drill
  [ "$status" -eq 0 ]
  grep -qF 'bootstrap:' "$APPLIED"
  grep -qF 'barmanObjectName: pg-r2' "$APPLIED"
  grep -qF 'serverName: pg-nuc' "$APPLIED" # 라이브 Cluster에서 파생된 값이 실제로 실렸다
  grep -qF 'restore_drill_last_success_timestamp' "$METRICS"
}

@test "happy path pushes the metric before pinging the dead-man switch (M5 ordering contract)" {
  run_drill
  [ "$status" -eq 0 ]
  m="$(grep -nF 'import/prometheus' "$CLOG" | head -1 | cut -d: -f1)"
  h="$(grep -nF 'hc.invalid' "$CLOG" | head -1 | cut -d: -f1)"
  [ -n "$m" ]
  [ -n "$h" ]
  [ "$m" -lt "$h" ]
}

@test "the script uses only verbs the restore-drill Role grants (no patch/replace/update/edit)" {
  run_drill
  [ "$status" -eq 0 ]
  run grep -nE '(^|[[:space:]])(patch|replace|update|edit|scale|annotate|label)([[:space:]]|$)' "$KLOG"
  [ "$status" -ne 0 ]
  # 양성 대조: 같은 정규식이 실제로 금지 동사를 잡는다(검출기 부패 방지)
  printf -- '-n database patch cluster pg-restore-drill\n' >"$OUT/fixture"
  run grep -nE '(^|[[:space:]])(patch|replace|update|edit|scale|annotate|label)([[:space:]]|$)' "$OUT/fixture"
  [ "$status" -eq 0 ]
}

@test "the residual-check failure text ships without the RBAC misattribution (doc-lock, code not comment)" {
  run grep -cF 'pvc/pv delete perms' "$SH"
  [ "$output" = "0" ]
  # 주석이 아니라 **배포되는 문자열**임을 고정한다 — 주석에도 같은 문구가 있어 단순 grep은 공허하다.
  run bash -c "grep -nF 'PV 권한은 설계상 없다' '$SH' | grep -v '^[0-9]*:[[:space:]]*#'"
  [ "$status" -eq 0 ]
}
