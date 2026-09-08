#!/usr/bin/env bats
# pgdump 헤지 DBS 편집 lib(tools/lib/hedge-dbs.ts) 단위 — provision-db(등록)·teardown-resource(해제)
# 공용 커널. 이 module이 **DBS 줄 문법 전부**(줄 앵커·들여쓰기·인용·뒤따르는 꼬리 보존 · 항목 경계 ·
# 토큰 동일성 · 존재 판정)의 SSOT라, 두 쓰기 주체가 문법을 재유도하면 생기는 무성 skew는 여기
# 단언으로만 고정된다. 형제: test_digest-exporter-lib.bats(APPS 목록).
# ⚠️ 중간 단언은 단일 대괄호만(bash 3.2 [[ ]] 침묵 통과) · @test 이름은 영어(CJK 함정).

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; TMP="$(mktemp -d)"; seed 'app'; }
teardown() { rm -rf "$TMP"; }

# DBS 줄을 통째로 심는다 — 실 매니페스트와 같은 들여쓰기 18칸 + 인용, 그리고 **뒤따르는 주석**.
# 편집 대상이 CronJob args 스크립트 **본문 안의 셸 한 줄**이라 꼬리 한 글자만 잃어도 의미가 변한다.
seed() { printf '                  set -euo pipefail\n                  DBS="%s" # app이 선두 = 복구 우선순위\n                  for DB in ${DBS}; do :; done\n' "$1" > "$TMP/hedge.txt"; }
# 비정준 입력(항목 사이 이중 공백) — 커널의 정준화가 어디서 관측되는지 못 박는 자리.
seed_raw() { printf '                  DBS="%s"\n' "$1" > "$TMP/hedge.txt"; }
run_lib() { bun -e "
  import { addDb, removeDb, hasDb } from '$ROOT/tools/lib/hedge-dbs.ts';
  import { readFileSync } from 'node:fs';
  let t = readFileSync('$TMP/hedge.txt','utf8');
  $1
  process.stdout.write(t);
"; }

@test "addDb appends a token at the tail (never sorted) and is idempotent" {
  # 정렬 금지가 계약이다 — 헤지 루프는 set -e라 선두 DB의 실패가 뒤를 통째로 죽인다. 부트스트랩
  # app(restore_canary 보유)이 선두에 남는 순서가 곧 복구 우선순위다.
  seed 'app shared'
  run run_lib "t = addDb(t,'orders'); t = addDb(t,'orders');"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qxF -- '                  DBS="app shared orders" # app이 선두 = 복구 우선순위'
}

@test "removeDb drops the token idempotently and leaves prefix siblings intact" {
  seed 'app shared shared-archive'
  run run_lib "t = removeDb(t,'shared'); t = removeDb(t,'shared');"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qxF -- '                  DBS="app shared-archive" # app이 선두 = 복구 우선순위'
}

@test "hasDb reads presence through the same grammar as edit (token equality, not substring)" {
  seed 'app shared-archive'
  run run_lib "console.error([hasDb(t,'app'), hasDb(t,'shared-archive'), hasDb(t,'shared'), hasDb(t,'ap')].join(','));"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'true,true,false,false'
}

@test "removeDb of an absent name still canonicalizes whitespace, so callers must gate on hasDb" {
  # 커널의 산출 형식은 **정준**이다(digest-exporter APPS와 같은 계약). 그래서 "없는 이름 제거"는
  # 비정규 공백 위에서 파일을 바꾼다 — 멱등의 책임은 콜사이트의 hasDb 게이트에 있다(L1).
  seed_raw 'app  shared'
  run run_lib "console.error('has=' + hasDb(t,'orders')); t = removeDb(t,'orders');"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'has=false'
  printf '%s' "$output" | grep -qxF -- '                  DBS="app shared"'
}

@test "edit throws fail-loud when the DBS line is missing (format drift)" {
  printf 'apiVersion: batch/v1\nkind: CronJob\n' > "$TMP/hedge.txt"
  run run_lib "t = addDb(t,'orders');"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'DBS'
}

@test "hasDb throws fail-loud on drift so absence never looks like a missing line" {
  printf 'apiVersion: batch/v1\nkind: CronJob\n' > "$TMP/hedge.txt"
  run run_lib "console.error(hasDb(t,'orders'));"
  [ "$status" -ne 0 ]
}

@test "edit refuses a manifest carrying two DBS assignment lines (first-match half update)" {
  # 치환은 첫 매치만 바꾼다 — 2줄이면 한 줄만 고치고 나머지는 영영 낡은 채로 남아, 헤지 잡이
  # 어느 줄을 마지막에 평가하느냐에 따라 결과가 갈린다. 조용한 절반 갱신 대신 fail-loud다.
  printf '                  DBS="app"\n                  DBS="app shared"\n' > "$TMP/hedge.txt"
  run run_lib "t = addDb(t,'orders');"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF '2개'
}
