#!/usr/bin/env bats
# drift-5: Cloudflare 무료 플랜 entitlement를 정적 강제(현재는 주석 + apply-time 400으로만 드러남).
#  - rate-limit period == 10 && mitigation_timeout == 10 (무료 유일 허용값)
#  - 모든 ruleset 식에 matches( 정규식 연산자 금지(Business/WAF Advanced 전용 → 400 "not entitled")
# ⚠️ bash 3.2: 중간 단언은 [ ]만. 순수 grep — terraform/cluster 비접촉(required gate-safe).

WAF="$BATS_TEST_DIRNAME/../../infra/cloudflare/waf.tf"
CACHE="$BATS_TEST_DIRNAME/../../infra/cloudflare/cache.tf"

@test "waf ratelimit period is exactly 10 (free-plan only value)" {
  run grep -cE '^[[:space:]]*period[[:space:]]*=[[:space:]]*10([[:space:]]|$|#)' "$WAF"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "waf ratelimit mitigation_timeout is exactly 10 (free-plan only value)" {
  run grep -cE '^[[:space:]]*mitigation_timeout[[:space:]]*=[[:space:]]*10([[:space:]]|$|#)' "$WAF"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "waf has no non-10 period (catches drift to 60/300/etc)" {
  # period = <10이 아닌 숫자>를 찾으면 실패. (100=requests_per_period라 'period ='로 앵커)
  run grep -nE '^[[:space:]]*period[[:space:]]*=[[:space:]]*[0-9]+' "$WAF"
  [ "$status" -eq 0 ]
  # 모든 period 라인이 10이어야: 전체 period 라인 수 == 10인 period 라인 수
  total="$(grep -cE '^[[:space:]]*period[[:space:]]*=[[:space:]]*[0-9]+' "$WAF")"
  tens="$(grep -cE '^[[:space:]]*period[[:space:]]*=[[:space:]]*10([[:space:]]|$|#)' "$WAF")"
  [ "$total" -eq "$tens" ]
}

@test "no 'matches' regex operator in any cloudflare ruleset expression (infix or call)" {
  # ⚠️ codex restale2 F2: Cloudflare `matches`는 **infix 연산자**다 — `http.host matches "..."`(괄호 없음).
  # `matches(`만 막으면 infix 형태가 게이트를 통과해 apply 400. 주석(인라인 포함)을 sed로 제거한 뒤 `\bmatches\b`
  # 토큰을 잡는다(라인 43의 'matches 미사용' 인라인 주석 false-positive 회피). starts_with()만 허용.
  run sh -c "sed -E 's/#.*//' \"$WAF\" \"$CACHE\" | grep -nE '\\bmatches\\b'"
  [ "$status" -ne 0 ]
}

@test "entitlement gate catches the infix 'http.host matches' form (negative fixture)" {
  # 가드가 실제로 infix matches를 잡는지 증명(잡기 회귀 방지).
  d="$BATS_TEST_TMPDIR"
  printf 'rules = [{ expression = "(http.host matches \\"^x\\")" }]\n' > "$d/bad.tf"
  run sh -c "sed -E 's/#.*//' \"$d/bad.tf\" | grep -nE '\\bmatches\\b'"
  [ "$status" -eq 0 ]
}

@test "ratelimit characteristics include the mandatory cf.colo.id" {
  # 무료 rate-limit는 ip.src + cf.colo.id 필수(누락 시 apply 400) — entitlement 인접 가드.
  run grep -qE 'characteristics[[:space:]]*=.*cf\.colo\.id' "$WAF"
  [ "$status" -eq 0 ]
}
