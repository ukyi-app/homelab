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
  printf '0' >"$OUT/walpolls"
  printf '0' >"$OUT/failpolls"

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
  # ── RPO 축(마커 write → WAL 전환 → 아카이브 대기 → 복구본에서 확인) ──
  # ⚠️ 순서가 있는 케이스가 먼저 와야 한다 — 아래 일반 exec 갈래가 삼키면 안 된다.
  *"exec pg-restore-drill-1"*"WHERE id ="*)
    printf '%s' "${DRILL_MARKER_FOUND:-1}" ;;                       # 복구본의 마커 유무
  *"exec pg-restore-drill-1"*"max(ts)"*)
    printf '%s' "${DRILL_RPO_LAG:-12}" ;;                           # RPO 실측 초
  *"exec pg-1"*"INSERT INTO"*)
    [ "${DRILL_INSERT_FAILS:-0}" = "1" ] && exit 1                  # 프로덕션 write 실패 경로
    # ⚠️ PG 18의 psql은 `INSERT … RETURNING`에서 `-tA`에도 상태 태그 `INSERT 0 1`을 **둘째 줄**로 낸다
    #    (실측 PG 18.4). 스텁이 이를 재현해야 drill.sh의 `head -1` 파싱 가드가 실제로 검증된다 —
    #    없이 `%s|%s`만 내던 예전 스텁은 2026-08-25 라이브 파싱 결함을 원리적으로 못 봤다.
    printf '%s|%s\nINSERT 0 1' "${DRILL_MARKER_ID:-42}" "${DRILL_MARKER_TS:-1700000000}" ;;
  *"exec pg-1"*"pg_walfile_name(pg_switch_wal())"*)
    [ "${DRILL_SWITCH_FAILS:-0}" = "1" ] && exit 1                  # 전환+이름을 한 문장으로
    printf '%s' "${DRILL_MARKER_WAL:-000000010000000000000009}" ;;
  *"exec pg-1"*"failed_count"*)
    n="$(cat "$OUT/failpolls" 2>/dev/null || echo 0)"; n=$((n + 1)); printf '%s' "$n" > "$OUT/failpolls"
    # DRILL_ARCHIVE_FAILS=1 이면 2회차부터 실패 카운터가 오른다(아카이브가 깨진 상태 재현)
    if [ "${DRILL_ARCHIVE_FAILS:-0}" = "1" ] && [ "$n" -gt 1 ]; then printf '9'; else printf '3'; fi ;;
  *"exec pg-1"*"last_archived_wal"*)
    n="$(cat "$OUT/walpolls" 2>/dev/null || echo 0)"; n=$((n + 1)); printf '%s' "$n" > "$OUT/walpolls"
    # 기본: 즉시 따라잡음. DRILL_ARCHIVE_LAGS=1 이면 영원히 뒤처진다(RPO 위반 재현).
    if [ "${DRILL_ARCHIVE_LAGS:-0}" = "1" ]; then printf '000000010000000000000001'
    elif [ "${DRILL_ARCHIVE_AHEAD:-0}" = "1" ]; then printf '00000001000000000000000A'  # 마커를 지나침(>= 판별)
    elif [ "${DRILL_ARCHIVE_HISTORY:-0}" = "1" ]; then printf '00000003.history'        # 형식 가드 대상
    elif [ "${DRILL_ARCHIVE_TIMELINE:-0}" = "1" ]; then printf '000000030000000000000009'
    else printf '%s' "${DRILL_MARKER_WAL:-000000010000000000000009}"; fi ;;
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
    DRILL_RPO_POLL_SECONDS=0 DRILL_RPO_MAX_POLLS=3 \
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

@test "RPO: the marker is written to LIVE and its WAL segment is closed BEFORE the restore starts" {
  # 순서가 전부다. 마커를 apply 뒤에 쓰면 그 쓰기는 복구본에 있을 수 없고,
  # 세그먼트를 닫기 전에 이름을 잡지 않으면 다음 세그먼트를 기다리게 된다.
  run_drill
  [ "$status" -eq 0 ]
  ins="$(kline 'INSERT INTO restore_canary')"
  sw="$(kline 'pg_switch_wal')"
  a="$(kline 'apply -f -')"
  [ -n "$ins" ]
  [ -n "$sw" ]
  [ "$ins" -lt "$sw" ]   # 마커 먼저, 그 다음 세그먼트 닫기
  [ "$sw" -lt "$a" ]     # 둘 다 복구 시작 전
}

@test "RPO: the recovered copy is checked for THAT marker id (not just a row count)" {
  run_drill
  [ "$status" -eq 0 ]
  # 복구본 대상 조회에 마커 id가 실려야 한다 — 행 수 비교로는 신선도를 증명하지 못한다.
  grep -qF 'exec pg-restore-drill-1' "$KLOG"
  run grep -cE 'exec pg-restore-drill-1.*WHERE id = 42' "$KLOG"
  [ "$output" = "1" ]
  grep -qF '마커 42' "$CLOG"            # PASS 본문에 마커 id가 실린다
  grep -qF 'RPO 12초' "$CLOG"           # 이분법이 아니라 **실측 수치**가 실린다
}

@test "RPO: a recovered copy MISSING the marker fails closed (archive is stale)" {
  run_drill DRILL_MARKER_FOUND=0
  [ "$status" -ne 0 ]
  [ ! -s "$METRICS" ]
  grep -qF 'RPO 위반' "$CLOG"
  run grep -cF 'hc.invalid' "$CLOG"
  [ "$output" = "0" ]
}

@test "RPO: a lagging archive is reported but does not abort (the marker check decides)" {
  # ⚠️ 설계 변경(적대 검증 수용): 여기서 죽으면 "R2 복구가 되는가"라는 주 1회짜리 유일 신호까지
  #    함께 버린다. 아카이브 정체는 WALArchiveStalled(critical, 15분)가 이미 상시 감시한다.
  #    복구본 마커 판정이 이 대기보다 엄격하게 강한 단언이므로 최종 판정을 잃지 않는다.
  run_drill DRILL_ARCHIVE_LAGS=1
  [ "$status" -eq 0 ]
  [ -s "$APPLIED" ]
  printf '%s' "$output" | grep -qF 'rpo attempt'   # 폴링이 실재한다
  grep -qF 'RPO-WAIT-TIMEOUT' "$CLOG"              # 사건은 보고에 남는다
}

@test "RPO: a rising archiver failure_count does NOT abort — it is a cumulative counter, not a level" {
  # ⚠️ 적대 검증 수용: failed_count는 누적이라 재시도로 결국 성공할 일시적 오류에도 오른다.
  #    이 레포는 같은 사실에 이미 판별을 내려놨다 — r4의 WALArchiveStalled는 레벨
  #    (last_failed_time > last_archived_time) + for:15m이다. 증분 1로 끊으면 R2 블립 한 번이
  #    주간 드릴을 통째로 죽인다(backoffLimit 0 · 주 1회 · in-band 무음). 진단 문구로만 쓴다.
  run_drill DRILL_ARCHIVE_LAGS=1 DRILL_ARCHIVE_FAILS=1
  [ "$status" -eq 0 ]
  [ -s "$APPLIED" ]
  grep -qF 'RPO-WAIT-TIMEOUT' "$CLOG"
  run grep -cF '아카이브가 실패하고 있다' "$CLOG"
  [ "$output" = "0" ]                              # 옛 조기중단 문구는 사라졌다
}

@test "RPO: failing to CLOSE the WAL segment fails closed" {
  run_drill DRILL_SWITCH_FAILS=1
  [ "$status" -ne 0 ]
  [ ! -s "$APPLIED" ]
  grep -qF '세그먼트를 닫지 못했다' "$CLOG"
}

@test "RPO: failing to WRITE the marker to production fails closed" {
  # 이 변경의 명분이 "프로덕션 DB에 쓰기를 시작한다"인데, 그 쓰기의 실패 처리가 무검증이었다.
  run_drill DRILL_INSERT_FAILS=1
  [ "$status" -ne 0 ]
  [ ! -s "$APPLIED" ]
  [ ! -s "$METRICS" ]
  grep -qF '라이브에 쓰지 못했다' "$CLOG"
}

@test "RPO: a non-numeric marker id fails closed (schema drift)" {
  run_drill DRILL_MARKER_ID=oops
  [ "$status" -ne 0 ]
  [ ! -s "$APPLIED" ]
  grep -qF '숫자 id를 반환하지 않았다' "$CLOG"
}

@test "RPO: the marker id flows from the INSERT to the recovered-copy query (parameterised, not hardcoded)" {
  # 스텁 기본값 우연이 아니라 '반환받은 값을 그대로 쓴다'를 증명한다.
  run_drill DRILL_MARKER_ID=777 DRILL_MARKER_TS=1699999999
  [ "$status" -eq 0 ]
  run grep -cE 'exec pg-restore-drill-1.*WHERE id = 777 AND .* = 1699999999' "$KLOG"
  [ "$output" = "1" ]
  grep -qF '마커 777' "$CLOG"
}

@test "RPO: an archiver already PAST the marker segment passes (>= not strict equality)" {
  # 앱 동시 쓰기로 아카이버가 마커 세그먼트를 지나치는 것은 정상이다 — 그걸 FAIL로 읽으면 매주 거짓 FAIL이다.
  run_drill DRILL_ARCHIVE_AHEAD=1
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF '아카이브 확인'
  grep -qF 'restore_drill_last_success_timestamp' "$METRICS"
}

@test "RPO: a .history filename never satisfies the comparison (it sorts high and would pass falsely)" {
  # 히스토리 파일은 큐를 앞질러 아카이브된다. 형식 가드가 없으면 00000003.history > 00000001…이라
  # 마커가 안 실렸는데 통과한다 — 이 변경이 없애려는 바로 그 거짓 PASS다.
  run_drill DRILL_ARCHIVE_HISTORY=1
  [ "$status" -eq 0 ]                      # 대기는 타임아웃하지만 마커 판정으로 계속한다
  printf '%s' "$output" | grep -qF 'rpo attempt'
  grep -qF 'RPO-WAIT-TIMEOUT' "$CLOG"      # 조용히 통과하지 않았다는 증거
}

@test "RPO: a timeline change during the drill aborts loudly instead of comparing across timelines" {
  run_drill DRILL_ARCHIVE_TIMELINE=1
  [ "$status" -ne 0 ]
  [ ! -s "$APPLIED" ]
  grep -qF '타임라인이 드릴 중 바뀌었다' "$CLOG"
}

@test "RPO: the wait timing out does NOT kill the run — the marker check still decides" {
  # 아카이브 정체는 WALArchiveStalled가 이미 상시 감시한다. 여기서 죽으면 주 1회짜리
  # "R2 복구가 되는가"라는 유일 신호까지 함께 버린다.
  run_drill DRILL_ARCHIVE_LAGS=1
  [ "$status" -eq 0 ]
  [ -s "$APPLIED" ]                        # 복구를 진행한다
  grep -qF 'RPO-WAIT-TIMEOUT' "$CLOG"      # 사건은 보고에 남는다
  grep -qF 'restore_drill_last_success_timestamp' "$METRICS"
}
