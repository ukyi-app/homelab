#!/usr/bin/env bats
# .env.secrets.example의 Telegram 이중 기재가 "같은 값"임을 명시하는지 검증.
# TF_VAR 쌍은 CI 알림(infra/github/secrets.tf)을 공급하므로 삭제 금지 — 존재까지 강제한다.
# ⚠️ @test 이름은 영어만, 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵통과).

EXAMPLE="${BATS_TEST_DIRNAME}/../../.env.secrets.example"

@test "TF_VAR telegram pair is still present (provisions GH Actions secret)" {
  run grep -qE '^export TF_VAR_telegram_bot_token=' "$EXAMPLE"
  [ "$status" -eq 0 ]
  run grep -qE '^export TF_VAR_telegram_chat_id=' "$EXAMPLE"
  [ "$status" -eq 0 ]
}

@test "seed-secrets telegram pair is still present (seeds k8s SOPS secret)" {
  run grep -qE '^export TELEGRAM_BOT_TOKEN=' "$EXAMPLE"
  [ "$status" -eq 0 ]
  run grep -qE '^export TELEGRAM_CHAT_ID=' "$EXAMPLE"
  [ "$status" -eq 0 ]
}

@test "the two pairs are documented as the SAME value (footgun guard)" {
  # 두 쌍이 동일 값이어야 함을 알리는 핵심 키워드가 주석에 있어야 한다.
  run grep -q '동일한 값' "$EXAMPLE"
  [ "$status" -eq 0 ]
  run grep -q 'infra/github/secrets.tf' "$EXAMPLE"
  [ "$status" -eq 0 ]
  run grep -q 'seed-secrets.sh' "$EXAMPLE"
  [ "$status" -eq 0 ]
}

@test "the seed pair shows a derive-from-TF_VAR hint (default expansion)" {
  # ⑦ 블록은 ⑤에서 파생되는 기본값(파라미터 확장)을 제시해야 한다.
  run grep -qF '${TF_VAR_telegram_bot_token}' "$EXAMPLE"
  [ "$status" -eq 0 ]
  run grep -qF '${TF_VAR_telegram_chat_id}' "$EXAMPLE"
  [ "$status" -eq 0 ]
}
