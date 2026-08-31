#!/usr/bin/env bats
# provider OAuth 스코프 가드 — CI의 plan-only 드리프트 감시(`drift-tailscale`)를 여는 유일한 코드 레버.
#
# 병(2026-08-18 발견): provider.tf가 스코프를 **리터럴**로 박고 있었다. 그래서 읽기 전용 OAuth
# 클라이언트를 새로 만들어도 토큰 교환이 403("cannot grant scopes …")으로 죽어, CI가 원리적으로
# 못 돌았다 — policy/workflow-readiness.json의 owner_action이 "plan만 돌므로 write 스코프는
# 불필요하다"고 적고 있었는데 **현행 코드로 실행 불가능한 지시**였다.
# @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐). 중간 단언은 [ ]만(bash 3.2).
# ⚠️ 경로 피연산자를 든 부재 단언은 `[ "$status" -eq 1 ]`이다 — 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
setup() {
  P="${BATS_TEST_DIRNAME}/provider.tf"
  V="${BATS_TEST_DIRNAME}/variables.tf"
}

@test "provider takes scopes from a variable, not a hardcoded list (CI read-only path)" {
  run grep -Eq '^\s*scopes\s*=\s*var\.ts_oauth_scopes\s*$' "$P"
  [ "$status" -eq 0 ]
  # 리터럴 회귀 금지 — 비-주석 줄에 대괄호 리스트가 다시 나타나면 CI 경로가 조용히 닫힌다.
  # 바로 위 var 참조 단언이 같은 provider.tf의 실재를 증언하므로 이 자리는 rc 구별만 채우면 닫힌다.
  run grep -Eq '^[^#]*scopes\s*=\s*\[' "$P"
  [ "$status" -eq 1 ]
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
# 로컬 apply 전용이라 state writer가 owner 머신의 terraform이 된다. 이 잡의 핀이 형제 잡(1.9.8)으로
# "통일"되면 헤드룸이 사라지므로 그 통일을 막는다.
# ✅ 2026-08-19 실측 갱신: 세 루트의 state writer는 **전부 ≤1.9.8이다**(terraform 1.9.8 바이너리로
#    `state list`가 github 8건·tailscale 3건·cloudflare 26건을 정상 열었다 — 더 높은 버전이 썼다면
#    "created by Terraform vX, which is newer than current v1.9.8"로 죽는다). 초판 주석의
#    "그 머신은 이미 1.15.5다"는 **owner 머신 바이너리** 이야기였지 writer가 아니었고, 그 머신(맥미니)은
#    폐기돼 owner 로컬 작업기가 NUC(terraform 1.9.8 정확 핀)로 옮겨갔다. 즉 writer는 1.9.x에 머문다.
#    그래도 이 핀을 내리지 않는다 — 1.15.5는 어떤 writer보다도 높아 안전 여유이고, 내리는 순간
#    형제 잡과 같은 값이 되어 "통일" 리팩터와 구별되지 않는다.
# ⚠️ 핀은 루트마다 독립이다(state writer가 다르므로 통일이 오히려 고장이다).
@test "the drift-tailscale terraform pin matches the owner-local state writer, not its siblings" {
  run ts_job
  [ "$status" -eq 0 ]
  block="$output"
  printf '%s' "$block" | grep -qF -- 'terraform_version: "1.15.5"'
  # 🔴 여기 있던 `grep -qvF`는 **항진명제였다**(2026-08-19 적대 검증). `-v`는 줄 단위 반전이라
  #    여러 줄 입력에서는 "1.9.8을 안 가진 줄"이 항상 존재해 exit 0이 되고, 잡 블록이 통째로
  #    1.9.8로 바뀌어도 통과했다. 즉 이 파일이 막겠다고 선언한 "통일" 회귀를 못 막고 있었다.
  #    부정 단언은 이 레포 관용구대로 run + [ ] 로만 쓴다(중간 `!`는 bash 3.2에서 조용히 통과).
  # ⚠️ 여기는 `-eq 1` 전환 대상이 **아니다** — grep이 경로가 아니라 stdin을 읽어 rc 2 채널이 없다.
  #    대신 위 두 줄이 그 쌍을 이룬다: `run ts_job` rc=0이 비공허 바닥값(WF 부재/잡 블록 소실 시 red),
  #    1.15.5 양성 대조가 같은 술어의 생존을 증언한다. cf. docs/traps-detail.md 「열거 붕괴」③-b
  run bash -c 'printf "%s" "$1" | grep -qF -- '"'"'terraform_version: "1.9.8"'"'"'' _ "$block"
  [ "$status" -ne 0 ]
}
