#!/usr/bin/env bats
# owner-local teardown 래퍼(scripts/teardown.sh) 안전 envelope 가드. 파괴/네트워크는 DRY_RUN=1로 차단.
# (@test 이름 영어, 단언은 run+[ ] — bash 3.2 함정 회피)

setup() { ROOT="$(git rev-parse --show-toplevel)"; SH="$ROOT/scripts/teardown.sh"; }

@test "teardown wrapper refuses a dirty worktree" {
  run env TEARDOWN_DIRTY=1 DRY_RUN=1 bash "$SH" --app foo
  [ "$status" -ne 0 ]
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
}
@test "teardown wrapper branches from freshly fetched FETCH_HEAD (F7)" {
  # 전체 base-SHA 검증은 mock remote 필요 — 단위 수준에선 FETCH_HEAD 분기를 단언(stale tracking ref 회피).
  grep -qE 'switch -c .* FETCH_HEAD' "$SH"
}
@test "teardown wrapper carries no node/.mjs entrypoints (bun-only)" {
  run grep -nE 'node tools/|\.mjs' "$SH"
  [ "$status" -ne 0 ]
}
