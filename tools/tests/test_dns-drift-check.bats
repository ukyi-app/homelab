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
  # 중간 negate는 침묵 통과 → run+status로 강제(check-bats-style.sh). $out은 일반 변수라 보존.
  run grep -q 'draft.ukyi.app' <<<"$out"
  [ "$status" -ne 0 ]
  run grep -q 'old.ukyi.app' <<<"$out"
  [ "$status" -ne 0 ]
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

@test "reserved platform hosts from the SSOT are checked for drift (M11 platform_hosts gap)" {
  d="$BATS_TEST_TMPDIR"
  printf '[]\n' > "$d/apps.json"
  printf '{"platform_hosts":["files.ukyi.app","argocd-webhook.ukyi.app"]}\n' > "$d/reserved.json"
  # files는 NXDOMAIN(미apply), argocd-webhook은 resolve
  out=$(bun "$ROOT/tools/dns-drift-check.ts" --apps "$d/apps.json" --reserved "$d/reserved.json" \
    --fixture '{"argocd-webhook.ukyi.app":["104.21.0.1"]}')
  echo "$out" | jq -e '.drift[] | select(.host=="files.ukyi.app" and (.reason|test("예약 platform host")))'
  echo "$out" | jq -e '.drift | length == 1'
}
