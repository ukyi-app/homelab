#!/usr/bin/env bats
# drift-2: active&&public host가 실제로 resolve되는지(apply 누락으로 DNS 미생성인지) 확인.
# resolver 주입(--fixture)으로 라이브 DNS 없이 fixture 검증. @test 영어, 중간 단언 [ ].
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "reports drift for an active and public host that does not resolve (NXDOMAIN)" {
  d="$BATS_TEST_TMPDIR"
  printf '[{"name":"blog","host":"blog.ukyi.app","public":true,"active":true},{"name":"draft","host":"draft.ukyi.app","public":false,"active":true},{"name":"old","host":"old.ukyi.app","public":true,"active":false}]\n' > "$d/apps.json"
  # fixture: blog는 NXDOMAIN(null). draft(public:false)·old(active:false)는 검사 대상 아님.
  out=$(bun "$ROOT/tools/dns-drift-check.ts" --apps "$d/apps.json" --fixture '{"blog.ukyi.app":null}')
  echo "$out" | jq -e '.drift[] | select(.host=="blog.ukyi.app" and (.reason|test("NXDOMAIN")))'
  echo "$out" | jq -e '.drift | length == 1'
  echo "$out" | jq -e '.transient | length == 0'
  ! echo "$out" | grep -q 'draft.ukyi.app'
  ! echo "$out" | grep -q 'old.ukyi.app'
}

@test "reports no drift when every active and public host resolves" {
  d="$BATS_TEST_TMPDIR"
  printf '[{"name":"blog","host":"blog.ukyi.app","public":true,"active":true}]\n' > "$d/apps.json"
  out=$(bun "$ROOT/tools/dns-drift-check.ts" --apps "$d/apps.json" --fixture '{"blog.ukyi.app":["104.21.0.1"]}')
  echo "$out" | jq -e '.drift | length == 0'
  echo "$out" | jq -e '.transient | length == 0'
}

@test "a transient resolver failure (SERVFAIL/timeout) is NOT counted as drift (F3 tri-state)" {
  # ⚠️ codex pass4 F3: transient는 NXDOMAIN과 구분 — drift 버킷이 아니라 transient 버킷에 들어가야 한다.
  d="$BATS_TEST_TMPDIR"
  printf '[{"name":"blog","host":"blog.ukyi.app","public":true,"active":true}]\n' > "$d/apps.json"
  out=$(bun "$ROOT/tools/dns-drift-check.ts" --apps "$d/apps.json" --fixture '{"blog.ukyi.app":"TRANSIENT"}')
  echo "$out" | jq -e '.drift | length == 0'
  echo "$out" | jq -e '.transient[] | select(.host=="blog.ukyi.app")'
}
