#!/usr/bin/env bats
# 자격증명 만료 원장/체커/워크플로 계약(메타갭 ④ W1-B).
# ⚠️ @test 이름은 영어만(한글이면 bats dir-run 인코딩 깨짐 — AGENTS.md).
# ⚠️ 중간 단언은 [ ]/grep만(bash 3.2 [[ ]] 실패 침묵통과 — AGENTS.md).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  s="$ROOT/scripts/check-credential-expiry.sh"
  command -v jq >/dev/null || skip "jq required"
}

@test "expiry checker exits 0 when nothing expires within window" {
  tmp="$(mktemp)"; printf '[{"name":"far","expires":"2099-01-01"}]' > "$tmp"
  run bash "$s" --file "$tmp" --days 14
  [ "$status" -eq 0 ]
}

@test "expiry checker exits 1 and names the credential when inside window" {
  tmp="$(mktemp)"
  soon="$(date -v+3d +%Y-%m-%d 2>/dev/null || date -d "+3 days" +%Y-%m-%d)"
  printf '[{"name":"ghcr-pull-pat","expires":"%s"}]' "$soon" > "$tmp"
  run bash "$s" --file "$tmp" --days 14
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

@test "empty ledger lints OK (vacuous array is valid)" {
  tmp="$(mktemp)"; printf '[]' > "$tmp"
  run bash "$s" --file "$tmp" --lint
  [ "$status" -eq 0 ]
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
  grep -q "if: github.event_name == 'workflow_dispatch'" "$W"
  grep -q 'vars.HOMELAB_OWNER' "$W"
}

@test "credential-expiry source label is registered in the notify.sh enum (forward cross-check)" {
  SH="$ROOT/.github/actions/telegram-notify/notify.sh"
  grep -q '자격만료' "$SH"
}
