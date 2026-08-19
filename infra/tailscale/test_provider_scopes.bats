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

# ── CI 주입 자리 (2026-08-19) ───────────────────────────────────────────────────────────────
# 위 두 @test는 **코드 레버**(provider.tf/variables.tf)만 본다. 그런데 레버가 풀려 있어도 워크플로가
# 그 값을 넘기지 않으면 CI는 기본값(owner write 집합)을 요청해 403으로 죽는다 — 실측 2026-08-19:
# 시크릿을 등록하고 돌린 첫 run이 정확히 그렇게 실패했다
# (`OAuth client cannot grant scopes "devices:core policy_file dns auth_keys oauth_keys"`).
# 그 주입 자리는 어떤 가드도 보고 있지 않았다. 여기서 잠근다.
# ⚠️ `drift-tailscale`은 policy/workflow-readiness.json에서 required/severity=error다 — 이 주입이
#    사라지면 조용한 회귀가 아니라 **매 30분 red**다.
WF() { printf '%s' "${BATS_TEST_DIRNAME}/../../.github/workflows/tf-reconcile.yaml"; }
# drift-tailscale job 블록만 잘라낸다 — 형제 잡의 같은 키에 속지 않기 위해서다.
ts_job() { awk '/^  drift-tailscale:/{f=1;next} f&&/^  [a-z]/{exit} f' "$(WF)"; }

@test "the workflow injects exactly the read-only scope set into the drift-tailscale plan step" {
  # **정확 일치**가 계약이다 — 이것이 곧 권한 과잉 금지(devices:core/auth_keys 추가)와
  # 권한 부족 금지(하나라도 빠지면 403 또는 허위 드리프트)를 한 줄로 잠근다.
  run ts_job
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- "TF_VAR_ts_oauth_scopes: '[\"policy_file:read\",\"dns:read\",\"oauth_keys:read\"]'"
}

# terraform은 state를 쓴 버전보다 낮은 바이너리로 그 state를 **읽지도 못한다**. 이 루트는 owner
# 로컬 apply 전용이라 state writer가 owner 머신의 terraform이 되고, 그 머신은 이미 1.15.5다 —
# 이 잡의 핀이 형제 잡(1.9.8)으로 "통일"되면 다음 로컬 apply 직후 CI가 죽는다. 그 통일을 막는다.
@test "the drift-tailscale terraform pin matches the owner-local state writer, not its siblings" {
  run ts_job
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- 'terraform_version: "1.15.5"'
  printf '%s' "$output" | grep -qvF -- 'terraform_version: "1.9.8"'
}
