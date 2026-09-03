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
  # 비공허 floor — 이 단언은 rc만으로 안 닫힌다: 파이프 끝 grep이 **stdin**을 읽으므로 두 피연산자가
  # 사라져도 sed만 죽고 grep은 빈 입력에 rc 1을 낸다(= "matches 0건"과 "검사 대상 0건"이 같은 초록).
  # 대상 실재를 먼저 못 박는다.
  [ -s "$WAF" ]
  [ -s "$CACHE" ]
  run sh -c "sed -E 's/#.*//' \"$WAF\" \"$CACHE\" | grep -nE '\\bmatches\\b'"
  # rc 2(정규식 오류 등)를 통과로 읽지 않는다 — grep 무매치는 정확히 rc 1이다.
  [ "$status" -eq 1 ]
  # 양성 대조 — 같은 sed|grep 체인이 이 도메인에서 사라질 리 없는 것(ruleset의 `expression =`)을
  # 실제로 잡는가. 체인이 조용히 죽으면 위 단언이 공허해진다. 래칫이 아니다(현재 5건 — 규칙 1개
  # 제거는 견디고, 피연산자 한쪽이 사라지면 red다).
  run sh -c "sed -E 's/#.*//' \"$WAF\" \"$CACHE\" | grep -cE 'expression[[:space:]]*='"
  [ "$status" -eq 0 ]
  [ "$output" -ge 4 ]
}

@test "entitlement gate catches the infix 'http.host matches' form (negative fixture)" {
  # 가드가 실제로 infix matches를 잡는지 증명(잡기 회귀 방지).
  d="$BATS_TEST_TMPDIR"
  printf 'rules = [{ expression = "(http.host matches \\"^x\\")" }]\n' > "$d/bad.tf"
  run sh -c "sed -E 's/#.*//' \"$d/bad.tf\" | grep -nE '\\bmatches\\b'"
  [ "$status" -eq 0 ]
}

@test "ratelimit characteristics are exactly ip.src + cf.colo.id (free-plan set)" {
  # 무료 rate-limit는 ip.src + cf.colo.id 둘 다 필수(누락 시 apply 400 또는 colo 단위 집계로
  # 오집계 — 실제 실패 모드는 waf.tf:40·iac.yaml:59가 적는 「plan은 entitlement 400을 못 잡음 →
  # post-merge apply 거부·main↔live 드리프트」다). 존재만이 아니라 **집합·순서·건수**를 한 줄에
  # 못 박는다 — 원소 삭제/추가 양방향에 red.
  run grep -cE '^[[:space:]]*characteristics[[:space:]]*=[[:space:]]*\["ip\.src",[[:space:]]*"cf\.colo\.id"\]' "$WAF"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}
