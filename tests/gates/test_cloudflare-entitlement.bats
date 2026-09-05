#!/usr/bin/env bats
# drift-5: Cloudflare 무료 플랜 entitlement를 정적 강제(현재는 주석 + apply-time 400으로만 드러남).
#  - rate-limit period == 10 && mitigation_timeout == 10 (무료 유일 허용값)
#  - 모든 ruleset 식에 matches( 정규식 연산자 금지(Business/WAF Advanced 전용 → 400 "not entitled")
# ⚠️ bash 3.2: 중간 단언은 [ ]만. 순수 grep — terraform/cluster 비접촉(required gate-safe).
#
# [critic-cloudflare-values, 6라운드] 이 파일이 waf.tf를 이미 읽으므로 **값 축** 전반의 required-gate
# 홈으로 함께 쓴다 — waf.tf의 rule enabled/action 값과 zone_settings.tf의 setting_id↔value 쌍은
# 어떤 가드도 안 보고 있었다(비평가 실증: 두 룰 enabled=false+action=log 무력화, always_use_https
# off·min_tls_version 1.0 전건 23/24 초록 — 유일 미탐은 환경 전제로 baseline도 실패하는 terraform
# validate). 도달성: iac.yaml:11-13 push-apply 무인, destroy-guard(iac.yaml:214-221)는 delete/replace만
# 봐서 update(값 변경)는 원리적으로 못 막는다. cache.tf·oauth·rulesets 등 다른 값 축은 여기서 손대지
# 않는다(7라운드 축 W).

WAF="$BATS_TEST_DIRNAME/../../infra/cloudflare/waf.tf"
CACHE="$BATS_TEST_DIRNAME/../../infra/cloudflare/cache.tf"
ZS="$BATS_TEST_DIRNAME/../../infra/cloudflare/zone_settings.tf"

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

@test "waf rules stay enabled and blocking (not silently downgraded to a log-only ruleset)" {
  # [critic-cloudflare-values] 위 @test들은 rate-limit **파라미터**(period/mitigation_timeout/characteristics)
  # 값 축만 잰다 — enabled/action 값 축은 무증인이었다(비평가 실증: traversal-block + ip-rate-limit
  # 두 룰을 enabled=false·action=log로 무력화해도 초록). 3개 룰(traversal·disallowed-methods·
  # ip-rate-limit) 전부 켜져 있고 block인지 건수로 앵커한다(추가·삭제·무력화 전부 red).
  [ "$(grep -cE '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true' "$WAF")" -eq 3 ]
  [ "$(grep -cE '^[[:space:]]*action[[:space:]]*=[[:space:]]*"block"' "$WAF")" -eq 3 ]
}

@test "zone_settings pins every setting_id -> value pair (edge hardening SSOT, no silent downgrade)" {
  # [critic-cloudflare-values] zone_settings.tf를 읽는 가드가 0건이었다(비평가 실증: always_use_https
  # off·min_tls_version 1.0 뮤테이션에 전건 초록 — 이 파일 자체가 무증인이었다). 리소스 총수 등식
  # (추가·삭제 축) + setting_id별 값 앵커(변조 축)를 함께 건다.
  [ "$(grep -cE '^resource "cloudflare_zone_setting"' "$ZS")" -eq 9 ]
  for pair in \
    'always_use_https:"on"' \
    'min_tls_version:"1.2"' \
    'tls_1_3:"on"' \
    'opportunistic_encryption:"off"' \
    'automatic_https_rewrites:"on"' \
    'browser_check:"on"' \
    'security_level:"medium"' \
    'email_obfuscation:"on"' \
  ; do
    id="${pair%%:*}"; val="${pair#*:}"
    awk -v id="$id" '$0 ~ "setting_id[[:space:]]*=[[:space:]]*\"" id "\"" {f=1} f{print} f&&/^}/{exit}' "$ZS" \
      | grep -qE "value[[:space:]]*=[[:space:]]*${val}" \
      || { echo "FAIL: zone_setting $id <-> $val 결합 부재"; false; }
  done
  # security_header(nested HSTS 객체)는 스칼라 value가 아니라 별도로 앵커한다.
  block="$(awk '/setting_id[[:space:]]*=[[:space:]]*"security_header"/{f=1} f{print} f&&/^}/{exit}' "$ZS")"
  [ -n "$block" ]
  printf '%s' "$block" | grep -qE 'enabled[[:space:]]*=[[:space:]]*true'
  printf '%s' "$block" | grep -qE 'include_subdomains[[:space:]]*=[[:space:]]*true'
}
