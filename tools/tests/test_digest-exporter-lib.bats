#!/usr/bin/env bats
# digest-exporter APPS 편집 lib(create-app/teardown-app/bump-tag 공용) 단위: add/remove/retag 멱등·
# 이름 정렬·존재 판정·fail-loud. 이 module이 APPS 리스트 문법(항목 경계·이름 키·ref 표기·존재 판정)의
# SSOT라, 세 쓰기 주체가 재유도하면 생기는 무성 skew가 여기 단언으로만 고정된다.
# ⚠️ 중간 단언은 단일 대괄호만(bash 3.2 [[ ]] 침묵 통과) · @test 이름은 영어(CJK 함정).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; TMP="$(mktemp -d)"
  printf '            env:\n                - name: APPS\n                  value: ""\n' > "$TMP/de.txt"; }
teardown() { rm -rf "$TMP"; }
run_lib() { bun -e "
  import { addApp, removeApp, hasApp, retagApp } from '$ROOT/tools/lib/digest-exporter.ts';
  import { readFileSync } from 'node:fs';
  let t = readFileSync('$TMP/de.txt','utf8');
  $1
  process.stdout.write(t);
"; }
# APPS value 라인을 통째로 심는다(비정준 입력도 그대로 넣을 수 있어야 한다).
seed() { printf '            env:\n                - name: APPS\n                  value: "%s"\n' "$1" > "$TMP/de.txt"; }
@test "addApp inserts a name=ref token, idempotent and name-sorted" {
  run run_lib "t = addApp(t,'trip-mate-api','ghcr.io/o/trip-mate-api:sha-b'); t = addApp(t,'page','ghcr.io/o/page:sha-a'); t = addApp(t,'page','ghcr.io/o/page:sha-a');"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'value: "page=ghcr.io/o/page:sha-a trip-mate-api=ghcr.io/o/trip-mate-api:sha-b"'
}
@test "removeApp drops the token idempotently" {
  run run_lib "t = addApp(t,'page','ghcr.io/o/page:sha-a'); t = removeApp(t,'page'); t = removeApp(t,'page');"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'value: ""'
}
@test "edit throws fail-loud when APPS value line is missing (format drift)" {
  echo 'no apps here' > "$TMP/de.txt"
  run run_lib "t = addApp(t,'page','x');"
  [ "$status" -ne 0 ]
}

# ── 존재 판정 — 부재(false)와 포맷 드리프트(throw)를 가른다 ─────────────────────────────────
@test "hasApp reads presence through the same grammar as edit" {
  seed "page=ghcr.io/o/page:sha-a trip-mate=ghcr.io/o/trip-mate:sha-b"
  run run_lib "console.error([hasApp(t,'page'), hasApp(t,'trip-mate'), hasApp(t,'blog'), hasApp(t,'pag')].join(','));"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'true,true,false,false'
}
@test "hasApp throws fail-loud when the APPS value line is missing (absence must not look like drift)" {
  echo 'no apps here' > "$TMP/de.txt"
  run run_lib "console.error(hasApp(t,'page'));"
  [ "$status" -ne 0 ]
}

# ── retagApp — 옛 태그의 **모양을 보지 않는다**(손 정규식이 조용히 놓치던 세 부류) ──────────
@test "retagApp moves only the tag and leaves sibling entries untouched" {
  seed "blog=ghcr.io/ukyi-app/blog:sha-0000000 page=ghcr.io/ukyi-app/page:sha-cd48150"
  run run_lib "t = retagApp(t,'blog','sha-deadbee');"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'value: "blog=ghcr.io/ukyi-app/blog:sha-deadbee page=ghcr.io/ukyi-app/page:sha-cd48150"'
}
@test "retagApp rewrites an entry whose owner is not ukyi-app and whose tag is not sha-form" {
  # 손 정규식은 owner를 리터럴로 박고 태그 몸통을 재유도했다 — 둘 다 이 자리에서 무성 skip이었다.
  seed "blog=ghcr.io/other-owner/blog:v1.2.3"
  run run_lib "t = retagApp(t,'blog','sha-deadbee');"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'value: "blog=ghcr.io/other-owner/blog:sha-deadbee"'
}
@test "retagApp keeps a port-bearing registry intact (tag boundary is the colon after the last slash)" {
  seed "blog=reg.io:443/ukyi-app/blog:sha-0000000 page=reg.io:443/ukyi-app/page"
  run run_lib "t = retagApp(t,'blog','sha-deadbee'); t = retagApp(t,'page','sha-feedbee');"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'value: "blog=reg.io:443/ukyi-app/blog:sha-deadbee page=reg.io:443/ukyi-app/page:sha-feedbee"'
}
@test "retagApp on an absent name leaves the entry set unchanged" {
  seed "page=ghcr.io/o/page:sha-a"
  run run_lib "t = retagApp(t,'blog','sha-deadbee');"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'value: "page=ghcr.io/o/page:sha-a"'
}
@test "retagApp canonicalizes a non-canonical APPS value (sort + single space)" {
  # 계약: 정렬·구분자는 커널 산출물 형식이다. 비정준 입력의 재정렬은 위반이 아니다 —
  # 그래서 "이미 최신이면 바이트 동일"은 **APPS가 이미 정준일 때**만 성립한다.
  seed "page=ghcr.io/o/page:sha-a   blog=ghcr.io/o/blog:sha-0000000"
  run run_lib "t = retagApp(t,'blog','sha-0000000');"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'value: "blog=ghcr.io/o/blog:sha-0000000 page=ghcr.io/o/page:sha-a"'
}
