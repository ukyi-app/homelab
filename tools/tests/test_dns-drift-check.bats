#!/usr/bin/env bats
# drift-2: active&&public host가 실제로 resolve되는지(apply 누락으로 DNS 미생성인지) 확인.
# resolver 주입(--fixture)으로 라이브 DNS 없이 fixture 검증. @test 영어, 중간 단언 [ ].
# ⚠️ 예약 host 바닥값(--min-reserved)의 **기본값은 1**(fail-closed)이다 — 형제 reserved-hosts.json이
# 없는 tmp 픽스처는 `--min-reserved 0`으로 **명시** 해제한다. 기본을 0으로 두면 '조용히 꺼진 바닥값'이
# 되어, 라이브에서 파일이 사라져도 아무도 모른다(같은 클래스의 실측 버그가 있었다).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "reports drift for an active and public host that does not resolve (NXDOMAIN)" {
  d="$BATS_TEST_TMPDIR"
  printf '[{"name":"blog","host":"blog.ukyi.app","public":true,"active":true},{"name":"draft","host":"draft.ukyi.app","public":false,"active":true},{"name":"old","host":"old.ukyi.app","public":true,"active":false}]\n' > "$d/apps.json"
  # fixture: blog는 NXDOMAIN(null). draft(public:false)·old(active:false)는 검사 대상 아님.
  out=$(bun "$ROOT/tools/dns-drift-check.ts" --apps "$d/apps.json" --min-reserved 0 --fixture '{"blog.ukyi.app":null}')
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
  out=$(bun "$ROOT/tools/dns-drift-check.ts" --apps "$d/apps.json" --min-reserved 0 --fixture '{"blog.ukyi.app":["104.21.0.1"]}')
  echo "$out" | jq -e '.drift | length == 0'
  echo "$out" | jq -e '.transient | length == 0'
}

@test "a transient resolver failure (SERVFAIL/timeout) is NOT counted as drift (F3 tri-state)" {
  # ⚠️ codex pass4 F3: transient는 NXDOMAIN과 구분 — drift 버킷이 아니라 transient 버킷에 들어가야 한다.
  d="$BATS_TEST_TMPDIR"
  printf '[{"name":"blog","host":"blog.ukyi.app","public":true,"active":true}]\n' > "$d/apps.json"
  out=$(bun "$ROOT/tools/dns-drift-check.ts" --apps "$d/apps.json" --min-reserved 0 --fixture '{"blog.ukyi.app":"TRANSIENT"}')
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
  # 스캔 신호 — stdout이 기계 판독 JSON이라 `SCAN:` 마커 대신 페이로드에 싣는다(CONTRIBUTING 규약).
  echo "$out" | jq -e '.scanned == 2'
}

# 여기부터는 바닥값 자신의 커버리지다. 이게 없으면 바닥값이 조용히 꺼져도(기본값 0으로 되돌리거나
# 검사를 지워도) 위 4개는 그대로 초록이다 — 그게 이 가드가 막으려는 병 그 자체다.

@test "the reserved-host floor fires when the SSOT file is missing (default is fail-closed)" {
  d="$BATS_TEST_TMPDIR"
  printf '[{"name":"blog","host":"blog.ukyi.app","public":true,"active":true}]\n' > "$d/apps.json"
  # 형제 reserved-hosts.json 없음 + 바닥값 미해제 → 앱 레인이 1건이어도 예약 레인 붕괴로 비-0.
  run bun "$ROOT/tools/dns-drift-check.ts" --apps "$d/apps.json" --fixture '{"blog.ukyi.app":["104.21.0.1"]}'
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "열거 붕괴"
}

@test "a corrupt reserved SSOT is a loud failure, not a silent empty list (fail-open direction)" {
  # ⚠️ 바닥값을 **해제하고** 검사한다. 기본값(1)을 켜두면 조용한 `[]`도 바닥값 위반으로 exit 1이 되어
  # "파싱 실패가 loud한가"를 전혀 붙잡지 못한다(둘이 같은 초록/빨강이 된다 — 적대 검토가 지적).
  # `--min-reserved 0`이면 비어도 통과가 정상이므로, 여기서 비-0이면 그건 **파싱 실패** 때문뿐이다.
  d="$BATS_TEST_TMPDIR"
  printf '[]\n' > "$d/apps.json"
  printf 'not json at all\n' > "$d/reserved.json"
  run bun "$ROOT/tools/dns-drift-check.ts" --apps "$d/apps.json" --reserved "$d/reserved.json" --min-reserved 0 --fixture '{}'
  [ "$status" -ne 0 ]
  # 양성 대조: 같은 조건에서 **정상** 파일이면 통과한다(비-0이 파싱 실패에서만 온다는 증거).
  printf '{"platform_hosts":[]}\n' > "$d/reserved.json"
  run bun "$ROOT/tools/dns-drift-check.ts" --apps "$d/apps.json" --reserved "$d/reserved.json" --min-reserved 0 --fixture '{}'
  [ "$status" -eq 0 ]
}

@test "the floor value must be a non-negative integer (never a silently disabled floor)" {
  d="$BATS_TEST_TMPDIR"
  printf '[]\n' > "$d/apps.json"
  # `Number("")===0`이라 빈 값이 바닥값을 조용히 끄는 자리 — 사용법 오류(2)로 거부해야 한다.
  run bun "$ROOT/tools/dns-drift-check.ts" --apps "$d/apps.json" --min-reserved "" --fixture '{}'
  [ "$status" -eq 2 ]
  run bun "$ROOT/tools/dns-drift-check.ts" --apps "$d/apps.json" --min-reserved abc --fixture '{}'
  [ "$status" -eq 2 ]
}

@test "an unknown flag is rejected with the usage exit code" {
  run bun "$ROOT/tools/dns-drift-check.ts" --bogus x
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}
