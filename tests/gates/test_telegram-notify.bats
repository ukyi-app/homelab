#!/usr/bin/env bats
# telegram-notify composite action 테스트 — 메시지 계약·escape·용어집·cap.
# ⚠️ bash 3.2: 중간 단언은 [ ]만 사용 — [[ ]] 실패는 침묵 통과.
# action 로직은 notify.sh에 있고, DRY_RUN=1이면 curl 대신 조립된 payload를 출력한다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ACT="$ROOT/.github/actions/telegram-notify/action.yml"
  SH="$ROOT/.github/actions/telegram-notify/notify.sh"
  TMP="$(mktemp -d)"
  export DRY_RUN=1
  export TG_TOKEN="x:y" TG_CHAT="123"
  export GITHUB_STEP_SUMMARY="$TMP/summary"
}
teardown() { rm -rf "$TMP"; }

@test "action.yml is a composite that runs notify.sh and declares contract inputs" {
  run grep -E "using: composite" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "notify\.sh" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "^[[:space:]]+status:" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "^[[:space:]]+source:" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "^[[:space:]]+title:" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "^[[:space:]]+link:" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "^[[:space:]]+bot-token:" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "^[[:space:]]+chat-id:" "$ACT"; [ "$status" -eq 0 ]
}

@test "notify.sh is POSIX sh (no bash-isms)" {
  run head -1 "$SH"; [ "$status" -eq 0 ]
  run grep -E "^#!/usr/bin/env sh|^#!/bin/sh" "$SH"; [ "$status" -eq 0 ]
  run grep -nE '\[\[|\$\{[A-Za-z_]+\^\^|\$\{[A-Za-z_]+//' "$SH"; [ "$status" -ne 0 ]
}

@test "assembled message has parse_mode=HTML, the glyph, bold korean title, korean status" {
  run env STATUS=success SOURCE=배포 TITLE="이미지 갱신" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "parse_mode=HTML"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "✅"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "<b>이미지 갱신</b>"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "성공"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "배포"; [ "$?" -eq 0 ]
}

@test "failure status maps to failure word with red glyph" {
  run env STATUS=failure SOURCE=IaC TITLE="cloudflare apply" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "🔴"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "실패"; [ "$?" -eq 0 ]
}

@test "drift status maps to warning word with warning glyph" {
  run env STATUS=drift SOURCE=IaC수렴 TITLE="tf-reconcile" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "⚠️"; [ "$?" -eq 0 ]
  echo "$output" | grep -q "경고"; [ "$?" -eq 0 ]
}

@test "HTML-escapes <, >, and & in dynamic values" {
  run env STATUS=success SOURCE=감사 TITLE="audit" IDENT="a<b>&c" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "a&lt;b&gt;&amp;c"; [ "$?" -eq 0 ]
  ! echo "$output" | grep -q "a<b>&c"   # raw must NOT survive (마지막 명령이라 유효 — 중간이면 침묵 통과(check-bats-style.sh 강제))
}

@test "ampersand is escaped before angle brackets (no double-escape of entities)" {
  run env STATUS=success SOURCE=감사 TITLE="audit" IDENT="x & y" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "x &amp; y"; [ "$?" -eq 0 ]
  ! echo "$output" | grep -q "&amp;lt;" # no entity got re-escaped (마지막 명령이라 유효 — 중간이면 침묵 통과(check-bats-style.sh 강제))
}

@test "teardown label fix: only the non-empty subject is shown (app set, resource empty)" {
  run env STATUS=success SOURCE=해체 TITLE="teardown" APP="orders" RESOURCE="" \
    IDENT_FROM_APP_OR_RESOURCE=1 sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "orders"; [ "$?" -eq 0 ]
  # the old concat bug glued them; with resource empty the output must not be "orders" + trailing junk
  ! echo "$output" | grep -qE "orders[^ <]"   # 마지막 명령이라 유효 — 중간이면 침묵 통과(check-bats-style.sh 강제)
}

@test "teardown label fix: resource set, app empty -> shows resource only" {
  run env STATUS=success SOURCE=해체 TITLE="teardown" APP="" RESOURCE="db-foo" \
    IDENT_FROM_APP_OR_RESOURCE=1 sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "db-foo"; [ "$?" -eq 0 ]
}

@test "includes the action link arrow when a url is present" {
  run env STATUS=failure SOURCE=변이 TITLE="mutation" \
    LINK="https://github.com/ukyi/homelab/actions/runs/1" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "→ https://github.com/ukyi/homelab/actions/runs/1"; [ "$?" -eq 0 ]
}

@test "omits the arrow line when no url" {
  run env STATUS=success SOURCE=배포 TITLE="x" sh "$SH"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "→ "   # 마지막 명령이라 유효 — 중간이면 침묵 통과(check-bats-style.sh 강제)
}

@test "HTML-escapes the link too (query-string & and angle brackets)" {
  run env STATUS=failure SOURCE=변이 TITLE="mutation" \
    LINK="https://x.test/run?a=1&b=2&t=<x>" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "→ https://x.test/run?a=1&amp;b=2&amp;t=&lt;x&gt;"; [ "$?" -eq 0 ]
  ! echo "$output" | grep -q "a=1&b=2"   # raw & must NOT survive (마지막 명령이라 유효 — 중간이면 침묵 통과(check-bats-style.sh 강제))
}

@test "rejects an unknown status enum" {
  run env STATUS=bogus SOURCE=배포 TITLE="x" sh "$SH"
  [ "$status" -ne 0 ]
}

@test "rejects an unknown source label" {
  run env STATUS=success SOURCE=NotAKoreanLabel TITLE="x" sh "$SH"
  [ "$status" -ne 0 ]
}

@test "optional KST stamp is appended when STAMP=1 (mm/dd hh:mm shape)" {
  run env STATUS=success SOURCE=배포 TITLE="x" STAMP=1 sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "[0-1][0-9]/[0-3][0-9] [0-2][0-9]:[0-5][0-9]"; [ "$?" -eq 0 ]
}

@test "caps oversized body at <=4096 chars and appends omission marker" {
  big="$(head -c 9000 /dev/zero | tr '\0' 'a')"
  run env STATUS=success SOURCE=감사 TITLE="audit" BODY="$big" sh "$SH"
  [ "$status" -eq 0 ]
  # extract the text= field length is hard in pure sh; assert the marker present and total under cap
  echo "$output" | grep -q "…(생략"; [ "$?" -eq 0 ]
  len="$(printf '%s' "$output" | wc -c | tr -d ' ')"
  [ "$len" -le 4200 ]   # payload incl. chat_id/parse_mode wrapper, body itself <=4096
}

@test "best-effort: non-2xx send logs a warning and still exits 0 (no DRY_RUN)" {
  # point the API at an unroutable host so curl returns non-2xx/empty, action must not fail
  run env -u DRY_RUN STATUS=success SOURCE=배포 TITLE="x" \
    TG_API_BASE="http://127.0.0.1:1/bot" sh "$SH"
  [ "$status" -eq 0 ]
  run cat "$GITHUB_STEP_SUMMARY"
  echo "$output" | grep -qi "telegram"; [ "$?" -eq 0 ]
}

@test "accepts the IaC-drift source label emitted by tf-reconcile drift steps (obs-1 live bug)" {
  # tf-reconcile.yaml:163,225가 발화하는 라벨 — enum 건초더미에 빠져 있으면 exit 2(라이브 침묵).
  run env STATUS=drift SOURCE=IaC드리프트 TITLE="github 드리프트" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "IaC드리프트"; [ "$?" -eq 0 ]
}
