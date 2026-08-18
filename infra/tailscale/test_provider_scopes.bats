#!/usr/bin/env bats
# provider OAuth 스코프 가드 — CI의 plan-only 드리프트 감시(`drift-tailscale`)를 여는 유일한 코드 레버.
#
# 병(2026-08-18 발견): provider.tf가 스코프를 **리터럴**로 박고 있었다. 그래서 읽기 전용 OAuth
# 클라이언트를 새로 만들어도 토큰 교환이 403("cannot grant scopes …")으로 죽어, CI가 원리적으로
# 못 돌았다 — policy/workflow-readiness.json의 owner_action이 "plan만 돌므로 write 스코프는
# 불필요하다"고 적고 있었는데 **현행 코드로 실행 불가능한 지시**였다.
# @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐). 중간 단언은 [ ]만(bash 3.2).
setup() {
  P="${BATS_TEST_DIRNAME}/provider.tf"
  V="${BATS_TEST_DIRNAME}/variables.tf"
}

@test "provider takes scopes from a variable, not a hardcoded list (CI read-only path)" {
  run grep -Eq '^\s*scopes\s*=\s*var\.ts_oauth_scopes\s*$' "$P"
  [ "$status" -eq 0 ]
  # 리터럴 회귀 금지 — 비-주석 줄에 대괄호 리스트가 다시 나타나면 CI 경로가 조용히 닫힌다.
  run grep -Eq '^[^#]*scopes\s*=\s*\[' "$P"
  [ "$status" -ne 0 ]
}

@test "the default scope set stays the owner's write set (narrowing it breaks local apply)" {
  # ⚠️ 이 기본값은 owner 로컬 apply가 실제로 쓰는 집합이다. CI는 TF_VAR_ts_oauth_scopes로
  #    :read 변종을 주입한다 — 기본값을 좁혀서 CI를 맞추면 apply가 403으로 죽는다.
  run grep -q 'variable "ts_oauth_scopes"' "$V"
  [ "$status" -eq 0 ]
  # ⚠️ `[^\n]*`를 쓰지 말 것 — POSIX ERE의 대괄호 안에서 `\n`은 개행이 아니라 **역슬래시와 n**이라
  #    "dns"의 n을 못 넘어 조용히 실패한다(2026-08-18에 이걸로 한 번 헛짚었다). 줄을 뽑아 -F로 본다.
  line="$(grep -E '^\s*default\s*=' "$V" | head -1)"
  [ -n "$line" ]
  for s in policy_file dns oauth_keys devices:core auth_keys; do
    printf '%s' "$line" | grep -qF -- "\"${s}\""
  done
}
