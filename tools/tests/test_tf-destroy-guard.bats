#!/usr/bin/env bats
# tf-destroy-guard composite 테스트 — destroy-count 단일 구현(warn|block).
# ⚠️ bash 3.2: 중간 단언은 [ ]만(​[[ ]] 실패는 침묵 통과). action 로직은 destroy-guard.sh에 있고
# PLAN_JSON 오버라이드로 terraform 없이 단위 검증한다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ACT="$ROOT/.github/actions/tf-destroy-guard/action.yml"
  SH="$ROOT/.github/actions/tf-destroy-guard/destroy-guard.sh"
  TMP="$(mktemp -d)"
  # delete 2건(replace=delete+create 포함) 픽스처
  cat > "$TMP/has-delete.json" <<'JSON'
{"resource_changes":[
  {"address":"a","change":{"actions":["delete"]}},
  {"address":"b","change":{"actions":["delete","create"]}},
  {"address":"c","change":{"actions":["update"]}}
]}
JSON
  # delete 0건
  cat > "$TMP/no-delete.json" <<'JSON'
{"resource_changes":[
  {"address":"a","change":{"actions":["create"]}},
  {"address":"b","change":{"actions":["no-op"]}}
]}
JSON
}
teardown() { rm -rf "$TMP"; }

@test "action.yml is a composite that runs destroy-guard.sh and declares mode input" {
  run grep -E "using: composite" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "destroy-guard\.sh" "$ACT"; [ "$status" -eq 0 ]
  run grep -E "^[[:space:]]+mode:" "$ACT"; [ "$status" -eq 0 ]
}

@test "destroy-guard.sh is POSIX sh (no bashisms)" {
  run grep -E "^#!/usr/bin/env sh|^#!/bin/sh" "$SH"; [ "$status" -eq 0 ]
  run grep -nE '\[\[|\$\{[A-Za-z_]+\^\^|\$\{[A-Za-z_]+//' "$SH"; [ "$status" -ne 0 ]
}

@test "block mode exits 1 with ::error:: when deletes present" {
  run env MODE=block PLAN_JSON="$TMP/has-delete.json" sh "$SH"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '::error::'; [ "$?" -eq 0 ]
  echo "$output" | grep -q '2'; [ "$?" -eq 0 ]
}

@test "block mode exits 0 when no deletes" {
  run env MODE=block PLAN_JSON="$TMP/no-delete.json" sh "$SH"
  [ "$status" -eq 0 ]
  run grep -q '::error::' <<<"$output"; [ "$status" -ne 0 ]
}

@test "warn mode never exits non-zero even with deletes (warning only)" {
  run env MODE=warn PLAN_JSON="$TMP/has-delete.json" sh "$SH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '::warning::'; [ "$?" -eq 0 ]
  run grep -q '::error::' <<<"$output"; [ "$status" -ne 0 ]
}

@test "invalid mode is rejected fail-closed (exit non-zero)" {
  run env MODE=bogus PLAN_JSON="$TMP/no-delete.json" sh "$SH"
  [ "$status" -ne 0 ]
}

@test "the destroy jq selector matches the canonical inline impl" {
  # 기존 인라인 가드(iac.yaml/tf-reconcile.yaml)와 동일한 select(.=="delete") 셀렉터를 SSOT로 유지
  run grep -F 'select(. == "delete")' "$SH"; [ "$status" -eq 0 ]
}

@test "emits typed result=blocked-delete on delete+block and result=ok on no-delete (F1)" {
  # ⚠️ codex pass5 F1: 호출 측이 outcome이 아니라 result로 분기 — blocked-delete만 alert-and-skip.
  run env GITHUB_OUTPUT="$TMP/o1" MODE=block PLAN_JSON="$TMP/has-delete.json" sh "$SH"
  [ "$status" -eq 1 ]
  grep -q '^result=blocked-delete$' "$TMP/o1"
  grep -q '^destroy_count=2$' "$TMP/o1"
  run env GITHUB_OUTPUT="$TMP/o2" MODE=block PLAN_JSON="$TMP/no-delete.json" sh "$SH"
  [ "$status" -eq 0 ]
  grep -q '^result=ok$' "$TMP/o2"
}

@test "emits result=error and exits 2 on a corrupt/missing plan — tooling error, not delete-block (F1)" {
  # 내부 오류(plan 부재/손상)는 delete 차단과 구분돼야 호출 측이 잡을 loud 실패시킨다.
  run env GITHUB_OUTPUT="$TMP/o3" MODE=block PLAN_JSON="$TMP/does-not-exist.json" sh "$SH"
  [ "$status" -eq 2 ]
  grep -q '^result=error$' "$TMP/o3"
  printf 'not json{' > "$TMP/bad.json"
  run env GITHUB_OUTPUT="$TMP/o4" MODE=block PLAN_JSON="$TMP/bad.json" sh "$SH"
  [ "$status" -eq 2 ]
  grep -q '^result=error$' "$TMP/o4"
}
