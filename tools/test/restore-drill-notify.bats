#!/usr/bin/env bats
# restore-drill notify() — 공유 메시지 계약 + DRY_RUN 렌더를 격리 검증한다.
# 스크립트 본문은 source 시 즉시 kubectl/ trap EXIT를 실행하므로 notify()만 떼어 테스트한다.
# ⚠️ @test 이름은 영어만, 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵통과).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SRC="$ROOT/platform/cnpg/prod/restore-drill-script.sh"
  EX="$BATS_TEST_TMPDIR/notify.sh"
  # notify()와 그 헬퍼(hx: HTML-escape)를 BEGIN/END 마커 사이에서 추출한다.
  sed -n '/# >>> notify-block (test-extracted)/,/# <<< notify-block (test-extracted)/p' "$SRC" > "$EX"
  # curl을 호출하면 안 된다(격리). 호출 시 즉시 실패하도록 스텁.
  cat > "$BATS_TEST_TMPDIR/curl" <<'STUB'
#!/usr/bin/env bash
echo "CURL_WAS_CALLED $*" >&2
exit 42
STUB
  chmod +x "$BATS_TEST_TMPDIR/curl"
}

# notify()를 격리 셸에서 호출하는 헬퍼. DRY_RUN=1 → curl 대신 text를 stdout으로.
run_notify() {
  run env PATH="$BATS_TEST_TMPDIR:$PATH" \
    DRY_RUN=1 TELEGRAM_BOT_TOKEN=tok TELEGRAM_CHAT_ID=123 \
    bash -c 'set -euo pipefail; source "$1"; shift; notify "$@"' _ "$EX" "$@"
}

@test "notify extraction yields a sourceable block with a notify function" {
  [ -s "$EX" ]
  run grep -c 'notify()' "$EX"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "DRY_RUN PASS renders glyph+word, source label, and key:value details" {
  run_notify PASS "복구 ${ACTUAL_ROWS:-7}행 (라이브 5행)"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '✅'
  printf '%s\n' "$output" | grep -q '성공'
  printf '%s\n' "$output" | grep -q '복원드릴'
  printf '%s\n' "$output" | grep -q '<b>'
}

@test "DRY_RUN FAIL renders the failure glyph and word" {
  run_notify FAIL "라이브 row count를 읽지 못함"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '🔴'
  printf '%s\n' "$output" | grep -q '실패'
  printf '%s\n' "$output" | grep -q '복원드릴'
}

@test "DRY_RUN never invokes curl (stub would print CURL_WAS_CALLED)" {
  run_notify PASS "x"
  [ "$status" -eq 0 ]
  run bash -c 'printf "%s" "$1" | grep -c CURL_WAS_CALLED || true' _ "$output"
  [ "$output" = "0" ]
}

@test "notify HTML-escapes dynamic values (< > & become entities, no raw <script)" {
  run_notify FAIL 'tbl <script> a&b >x'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '&lt;script&gt;'
  printf '%s\n' "$output" | grep -q 'a&amp;b'
  run bash -c 'printf "%s" "$1" | grep -c "<script>" || true' _ "$output"
  [ "$output" = "0" ]
}

@test "notify keeps parse_mode=HTML semantics (bold title tag present)" {
  run_notify PASS "복구 7행"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '<b>'
  printf '%s\n' "$output" | grep -q '</b>'
}
