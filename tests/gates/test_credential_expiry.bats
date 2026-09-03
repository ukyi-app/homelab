#!/usr/bin/env bats
# 자격증명 만료 원장/체커/워크플로 계약(메타갭 ④ W1-B).
# ⚠️ @test 이름은 영어만(한글이면 bats dir-run 인코딩 깨짐 — AGENTS.md).
# ⚠️ 중간 단언은 [ ]/grep만(bash 3.2 [[ ]] 실패 침묵통과 — AGENTS.md).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  s="$ROOT/scripts/check-credential-expiry.sh"
  command -v jq >/dev/null || skip "jq required"
}

# ⚠️ 1항목 픽스처는 `--floor credential-expiry=1`로 자기 크기를 명시한다 — 기본 바닥값은 **커밋된 원장**의
#    크기라, 픽스처가 그걸 물려받으면 여기서 재는 축(만료 판정)이 아니라 바닥값 때문에 죽는다.
# ⚠️ 그 수치를 이 주석에 적지 않는다 — 적으면 드리프트한다. 실측(2026-08-20): 이 주석이 '2'라고
#    적혀 있는 동안 스크립트 기본값은 3, 커밋된 원장은 4항목이었다. **세 곳이 전부 달랐다.**
@test "expiry checker exits 0 when nothing expires within window" {
  tmp="$(mktemp)"; printf '[{"name":"far","expires":"2099-01-01"}]' > "$tmp"
  run bash "$s" --file "$tmp" --days 14 --floor credential-expiry=1
  [ "$status" -eq 0 ]
}

@test "expiry checker exits 1 and names the credential when inside window" {
  tmp="$(mktemp)"
  soon="$(date -v+3d +%Y-%m-%d 2>/dev/null || date -d "+3 days" +%Y-%m-%d)"
  printf '[{"name":"ghcr-pull-pat","expires":"%s"}]' "$soon" > "$tmp"
  run bash "$s" --file "$tmp" --days 14 --floor credential-expiry=1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "ghcr-pull-pat"
}

@test "expiry checker fails loud (exit 2) on malformed json" {
  tmp="$(mktemp)"; printf 'not-json' > "$tmp"
  run bash "$s" --file "$tmp" --days 14
  [ "$status" -eq 2 ]
}

@test "expiry checker fails loud on wrong date format (schema guard)" {
  tmp="$(mktemp)"; printf '[{"name":"x","expires":"2099/01/01"}]' > "$tmp"
  run bash "$s" --file "$tmp" --lint
  [ "$status" -eq 2 ]
}

# ── 열거 붕괴 바닥값 (구 "empty ledger lints OK"의 반전) ──────────────────────────────────────────
# 이 @test는 정확히 뒤집힌 것이다. 예전에는 빈 원장이 lint OK였고(체커 주석이 "빈 배열은 vacuous true
# 허용"이라고 선언했다), 그래서 원장이 통째로 비어도 주간 감시가 "만료 임박 없음" + exit 0을 냈다.
@test "an emptied ledger is an enumeration collapse, not a valid ledger" {
  tmp="$(mktemp)"; printf '[]' > "$tmp"
  run bash "$s" --file "$tmp" --lint
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "열거 붕괴"
}

# ⚠️ **종료코드가 계약이다.** credential-expiry.yaml은 rc=1을 "만료 임박"으로 읽어
# 「자격증명 만료 임박」 제목의 telegram을 보내고 job은 **성공**시킨다(rc≥2만 hard-fail).
# 붕괴를 1로 내면 거짓 제목의 알림이 나가고 job이 초록으로 남는다 — 값 자체를 못박는다.
@test "the collapse exit code is the fail-loud one (2), not the expiring-soon one (1)" {
  tmp="$(mktemp)"; printf '[]' > "$tmp"
  run bash "$s" --file "$tmp" --days 14
  [ "$status" -eq 2 ]
}

@test "the floor is load-bearing: a ledger below the requested floor fails" {
  tmp="$(mktemp)"; printf '[{"name":"only-one","expires":"2099-01-01"}]' > "$tmp"
  run bash "$s" --file "$tmp" --lint --floor credential-expiry=2
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "열거 붕괴"
}

# 바닥값을 통과한 실행은 커널 규약대로 SCAN 마커를 낸다(06 권위 경로 회계가 "가드가 자기 도메인에
# 닿았는가"를 판정하는 유일한 기계 입력 — tests/gates/test_scan-floor.bats의 집합 대조가 전건 강제).
@test "a passing run emits the scan marker for its ledger domain" {
  run bash "$s" --file "$ROOT/policy/credential-expiry.json" --lint
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^SCAN: credential-expiry: [0-9]+$'
}

# 커밋된 원장이 **기본 바닥값**을 실제로 만족하는가 — 픽스처가 아니라 실 원장에 대한 판정이다.
# 이게 없으면 위 @test들이 전부 픽스처만 재고 실 원장은 아무도 안 보는 상태가 될 수 있다.
@test "the committed ledger satisfies the default floor with no override" {
  run bash "$s" --lint
  [ "$status" -eq 0 ]
}

# 위 @test는 `기본값 <= 원장 크기`만 잰다 — 기본값이 원장보다 **낮은** 여유(slack)는 그대로 통과한다.
# 실측 2026-09-03: 기본값 8 / 원장 10으로 2행이 조용히 사라져도 --lint와 --days 14가 모두 초록이었다
# (#613·#614가 행만 더하고 바닥을 안 올린 결과). 아래가 그 여유를 재는 증인이다 — 수치를 적지 않고
# 커밋된 원장에서 파생하므로 원장이 커져도 드리프트하지 않는다.
@test "the default floor carries no slack: dropping one committed row must collapse the enumeration" {
  tmp="$(mktemp)"
  jq '.[0:-1]' "$ROOT/policy/credential-expiry.json" > "$tmp"
  # 양성 대조: 잘라낸 원장이 스키마상 여전히 유효해야 이 단언이 바닥값을 재는 것이 된다.
  n="$(jq length "$tmp")"; [ "$n" -ge 1 ]
  run bash "$s" --file "$tmp" --lint
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "열거 붕괴"
}

@test "committed credential ledger parses and every entry has name+expires" {
  run bash "$s" --file "$ROOT/policy/credential-expiry.json" --lint
  [ "$status" -eq 0 ]
}

@test "workflow calls the checker via bash and reports via telegram-notify (F4 contract)" {
  W="$ROOT/.github/workflows/credential-expiry.yaml"
  # 실행비트 비의존 — bash로 호출(bats 계약과 일치, F4).
  grep -q 'bash scripts/check-credential-expiry.sh' "$W"
  grep -q 'uses: ./.github/actions/telegram-notify' "$W"
  # 발송 자격은 secrets 참조, source는 등록 enum(자격만료).
  grep -q 'bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}' "$W"
  grep -q 'chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}' "$W"
  grep -q 'source: 자격만료' "$W"
  # workflow_dispatch 진입점은 actor 가드 필수(B6 전수 가드 불변식 — dns-drift/contract-drift와 동일).
  # ⚠️ 트리거 판정은 스텝 `if:`가 아니라 **가드 본문**이 진다. `if:`로 한정하면 push/schedule run의
  #    재실행에서 스텝 자체가 skip되어 경계가 사라진다(함정 원장 「github.actor는 재실행에서 보존된다」).
  #    이 단언이 종전에 그 `if:` 문자열을 계약으로 굳혀 두어, 고치는 변경이 여기서 red를 냈다.
  grep -qF '[ "$EVENT" = "workflow_dispatch" ] || exit 0' "$W"
  grep -q 'vars.HOMELAB_OWNER' "$W"
  # 재실행 축도 함께 요구한다 — 이 진입점의 경계는 두 축이 함께여야 성립한다.
  grep -qF '[ "$ATTEMPT" = "1" ] ||' "$W"
}

@test "credential-expiry source label is registered in the notify.sh enum (forward cross-check)" {
  SH="$ROOT/.github/actions/telegram-notify/notify.sh"
  grep -q '자격만료' "$SH"
}

@test "the retired --min-entries vocabulary is a usage error (exit 2)" {
  # 폐지 어휘가 조용히 무시되지 않는다(kernel-followups 02) — unknown arg 경로가 거부를 소유한다.
  tmp="$(mktemp)"; printf '[{"name":"x","expires":"2099-01-01"}]' > "$tmp"
  run bash "$s" --file "$tmp" --min-entries 1
  rm -f "$tmp"
  [ "$status" -eq 2 ]
}
