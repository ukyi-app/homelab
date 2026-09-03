#!/usr/bin/env bats
# owner-local teardown 래퍼(scripts/teardown.sh) 안전 envelope 가드. 파괴/네트워크는 DRY_RUN=1로 차단.
# (@test 이름 영어, 단언은 run+[ ] — bash 3.2 함정 회피)
# ⚠️ 부재 단언 규약(`-eq 1`)은 docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a가 SSOT다.
#    이 파일 고유 사정: 비-0 단언 대부분은 teardown.sh 자신의 **거부 종료코드**(dirty·bad arg·
#    미검증 attestation)라 비대상이고, 전환 대상은 소스 형태를 보는 마지막 @test 하나뿐이다.

# ⚠️ 피연산자 실재 — 이 파일의 거부 레인은 `-ne 0`으로 판정하는데 스크립트가 없으면 bash도
#    비-0(127)을 내 두 채널이 겹친다(실측: teardown.sh 삭제 시 8레인 중 #1·#4가 그대로 초록).
setup() { ROOT="$(git rev-parse --show-toplevel)"; SH="$ROOT/scripts/teardown.sh"; [ -f "$SH" ]; }

@test "teardown wrapper refuses a dirty worktree" {
  run env TEARDOWN_DIRTY=1 DRY_RUN=1 bash "$SH" --app foo
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '거부: 워킹트리 dirty'
}
@test "teardown wrapper dry-run creates a dedicated branch from origin/main" {
  run env TEARDOWN_DIRTY=0 TEARDOWN_TS=20260618 DRY_RUN=1 bash "$SH" --app foo
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "teardown/teardown-app-foo-20260618"
  echo "$output" | grep -q "origin/main"
}
@test "teardown wrapper dry-run prints the allowlist staging set" {
  run env TEARDOWN_DIRTY=0 DRY_RUN=1 bash "$SH" --app foo
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "apps/"
  echo "$output" | grep -q "infra/cloudflare/apps.json"
}
@test "teardown wrapper rejects unknown args" {
  run env DRY_RUN=1 bash "$SH" --bogus x
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '--resource <db|cache>:<name>'
}
@test "teardown wrapper resource mode refuses without REFS_VERIFIED attestation (F1)" {
  run env TEARDOWN_DIRTY=0 DRY_RUN=1 bash "$SH" --resource db:foo
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "REFS_VERIFIED"
}
@test "teardown wrapper resource dry-run passes --refs-verified into the plan command" {
  run env TEARDOWN_DIRTY=0 DRY_RUN=1 REFS_VERIFIED=manual-test bash "$SH" --resource db:foo
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--refs-verified manual-test"
}
@test "teardown wrapper branches from freshly fetched FETCH_HEAD (F7)" {
  # 전체 base-SHA 검증은 mock remote 필요 — 단위 수준에선 FETCH_HEAD 분기를 단언(stale tracking ref 회피).
  grep -qE 'switch -c .* FETCH_HEAD' "$SH"
}
@test "teardown wrapper carries no node/.mjs entrypoints (bun-only)" {
  # ⚠️ 이 @test에는 형제 단언이 없다 — `-ne 0` 형태에서는 teardown.sh를 리네임해도 홀로 초록이었다
  #    (FETCH_HEAD 양성 대조는 다른 @test라 `bats -f` 단일 실행에서는 함께 돌지 않는다).
  run grep -nE 'node tools/|\.mjs' "$SH"
  [ "$status" -eq 1 ]
}
