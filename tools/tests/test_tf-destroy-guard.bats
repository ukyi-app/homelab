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

@test "action.yml declares allow + allow_max inputs and passes ALLOW/ALLOW_MAX env" {
  # allow(정규식): 매칭 address delete를 차단 카운트 제외. allow_max(정수): 자동 허용 상한(대량 삭제 캡).
  grep -qE "^[[:space:]]+allow:" "$ACT" && grep -qE "^[[:space:]]+allow_max:" "$ACT" \
    && grep -qF 'ALLOW:' "$ACT" && grep -qF 'ALLOW_MAX:' "$ACT" \
    && grep -qF 'inputs.allow' "$ACT" && grep -qF 'inputs.allow_max' "$ACT"
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

# ── ALLOW: 자동 관리 표면(app 공개 DNS = cloudflare_dns_record.app[*]) delete를 block 카운트에서 제외 ──
# create-app의 DNS 추가 자동 apply와 대칭으로 teardown의 DNS 삭제도 자동 apply되게 한다.
# 구조적 리소스(apex/www=public[*], tunnel/zone/waf/r2)는 ALLOW와 무관하게 끝까지 차단.
@test "ALLOW excludes matching app-DNS deletes from the block count (teardown auto-applies)" {
  # teardown 시나리오: app DNS(app[*]) 1건 delete + tunnel in-place update → 차단 0건.
  cat > "$TMP/teardown.json" <<'JSON'
{"resource_changes":[
  {"address":"cloudflare_dns_record.app[\"example-api.ukyi.app\"]","change":{"actions":["delete"]}},
  {"address":"cloudflare_zero_trust_tunnel_cloudflared_config.homelab","change":{"actions":["update"]}}
]}
JSON
  run env GITHUB_OUTPUT="$TMP/oa" MODE=block ALLOW='^cloudflare_dns_record\.app\[' PLAN_JSON="$TMP/teardown.json" sh "$SH"
  [ "$status" -eq 0 ] && grep -q '^result=ok$' "$TMP/oa" && grep -q '^destroy_count=0$' "$TMP/oa"
}

@test "ALLOW does NOT exempt apex/www (public[*]) — structural DNS stays blocked (Finding 1)" {
  # apex(zone_name)/www는 cloudflare_dns_record.public[*]라 app allow에 안 걸린다 → 무인 삭제 차단.
  cat > "$TMP/apex.json" <<'JSON'
{"resource_changes":[
  {"address":"cloudflare_dns_record.public[\"ukyi.app\"]","change":{"actions":["delete"]}}
]}
JSON
  run env GITHUB_OUTPUT="$TMP/ox" MODE=block ALLOW='^cloudflare_dns_record\.app\[' PLAN_JSON="$TMP/apex.json" sh "$SH"
  [ "$status" -eq 1 ] && grep -q '^result=blocked-delete$' "$TMP/ox" && grep -q '^destroy_count=1$' "$TMP/ox"
}

@test "ALLOW does not exempt structural deletes (tunnel still blocks even with app allow)" {
  cat > "$TMP/mixed.json" <<'JSON'
{"resource_changes":[
  {"address":"cloudflare_dns_record.app[\"example-api.ukyi.app\"]","change":{"actions":["delete"]}},
  {"address":"cloudflare_zero_trust_tunnel_cloudflared.homelab","change":{"actions":["delete"]}}
]}
JSON
  run env GITHUB_OUTPUT="$TMP/ob" MODE=block ALLOW='^cloudflare_dns_record\.app\[' PLAN_JSON="$TMP/mixed.json" sh "$SH"
  [ "$status" -eq 1 ] && grep -q '^result=blocked-delete$' "$TMP/ob" && grep -q '^destroy_count=1$' "$TMP/ob"
}

@test "ALLOW: a replace(delete+create) of a structural resource still blocks" {
  cat > "$TMP/replace.json" <<'JSON'
{"resource_changes":[
  {"address":"cloudflare_zero_trust_tunnel_cloudflared.homelab","change":{"actions":["delete","create"]}}
]}
JSON
  run env GITHUB_OUTPUT="$TMP/od" MODE=block ALLOW='^cloudflare_dns_record\.app\[' PLAN_JSON="$TMP/replace.json" sh "$SH"
  [ "$status" -eq 1 ] && grep -q '^destroy_count=1$' "$TMP/od"
}

@test "ALLOW empty/unset keeps counting all deletes (backward compatible)" {
  run env GITHUB_OUTPUT="$TMP/oe" MODE=block ALLOW='' PLAN_JSON="$TMP/has-delete.json" sh "$SH"
  [ "$status" -eq 1 ] && grep -q '^destroy_count=2$' "$TMP/oe"
}

# ── ALLOW_MAX: 자동 허용 delete 상한 — 대량 삭제(apps.json 통째 비움)는 무인 apply 차단 (Finding 2) ──
@test "ALLOW_MAX at/under cap: single app-DNS delete auto-applies" {
  cat > "$TMP/one.json" <<'JSON'
{"resource_changes":[
  {"address":"cloudflare_dns_record.app[\"a.ukyi.app\"]","change":{"actions":["delete"]}}
]}
JSON
  run env GITHUB_OUTPUT="$TMP/om1" MODE=block ALLOW='^cloudflare_dns_record\.app\[' ALLOW_MAX=1 PLAN_JSON="$TMP/one.json" sh "$SH"
  [ "$status" -eq 0 ] && grep -q '^destroy_count=0$' "$TMP/om1"
}

@test "ALLOW_MAX over cap: mass app-DNS removal is blocked (apps.json emptied)" {
  # apps.json 통째 비움 = 다수 app DNS delete → 상한 초과 → 자동 허용 취소(전량 차단).
  cat > "$TMP/many.json" <<'JSON'
{"resource_changes":[
  {"address":"cloudflare_dns_record.app[\"a.ukyi.app\"]","change":{"actions":["delete"]}},
  {"address":"cloudflare_dns_record.app[\"b.ukyi.app\"]","change":{"actions":["delete"]}}
]}
JSON
  run env GITHUB_OUTPUT="$TMP/om2" MODE=block ALLOW='^cloudflare_dns_record\.app\[' ALLOW_MAX=1 PLAN_JSON="$TMP/many.json" sh "$SH"
  [ "$status" -eq 1 ] && grep -q '^result=blocked-delete$' "$TMP/om2" && grep -q '^destroy_count=2$' "$TMP/om2"
}
