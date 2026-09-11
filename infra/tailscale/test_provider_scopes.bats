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
  O="${BATS_TEST_DIRNAME}/outputs.tf"
  OAUTH="${BATS_TEST_DIRNAME}/oauth.tf"
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
  # 위 루프는 멤버십만 잰다(원소 수 상한 0줄) — 기본값에 원소를 추가해도(실측
  # P4: auth_keys, all:write 추가) 무증인이었다. 리스트 전체 리터럴 일치로 상한까지 닫는다
  # (`terraform fmt`가 간격을 고정하므로 -F가 안전 — make tf-validate가 그 전제를 지킨다).
  printf '%s' "$line" | grep -qF -- '["policy_file", "dns", "oauth_keys", "devices:core", "auth_keys"]'
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
  # ⚠️ 위 부분문자열 grep은 위치에 무감하다 — 같은 리터럴을 주석으로 옮겨도(잡 블록 안이라
  # ts_job 추출엔 남는다) 매치한다(실측 P2). 행두·행말 앵커로 "주입 줄 자신"만 겨냥한다
  # (`-var` 오버라이드는 terraform이 TF_VAR_보다 우선시켜 이 앵커도 원리적으로 못 보는 축이다 —
  # 그 경로는 어차피 read-only OAuth client가 403을 내 loud red이므로 별도 단언은 생략한다).
  printf '%s' "$output" | grep -qE "^[[:space:]]+TF_VAR_ts_oauth_scopes: '\[\"policy_file:read\",\"dns:read\",\"oauth_keys:read\"\]'\$"
}

# owner 버전 갱신 시 plan-only CI가 뒤처지지 않도록 현재 승인 버전을 검증한다.
# 형제 잡과 같은 값이어도 된다. 과거의 버전 차이 자체는 운영 계약이 아니다.
@test "the drift-tailscale terraform pin matches the approved owner version" {
  run ts_job
  [ "$status" -eq 0 ]
  local block="$output" expected
  run sed -n 's/^[[:space:]]*required_version = "= \([0-9.]*\)".*/\1/p' "$BATS_TEST_DIRNAME/../github/versions.tf"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  expected="$output"
  run sed -n 's/^[[:space:]]*terraform_version: "\([0-9.]*\)".*/\1/p' <<< "$block"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

# ── outputs.tf sensitive 플래그 · oauth.tf scopes/tags 증인 ────────────────────────────────────
# 위 @test들은 provider.tf(CI 토큰 교환 스코프)·variables.tf(owner 로컬 apply 기본값)만 본다.
# outputs.tf(실 OAuth 클라이언트 시크릿 output의 sensitive 플래그)와 oauth.tf(k8s-operator
# 자신의 scopes/tags — 클러스터가 실제로 쓰는 자격)는 이 파일도 test_acl_guard.bats도 열지 않아
# 무증인이었다(sensitive=false 뮤테이션·scopes/tags 확대 뮤테이션 모두 9/9 ok — 실측).

@test "both tailscale oauth outputs stay sensitive=true (the secret is a live k8s Secret value)" {
  # sensitive=false로 뒤집히면 owner 로컬 terraform apply/output이 실 OAuth 클라이언트 시크릿을
  # 터미널에 평문 출력한다(AGENTS.md: 시크릿 값은 채팅/로그에 절대 출력 금지). 출력 블록 수 대비
  # sensitive=true 수를 세어 신규 output 추가에도 자동으로 닫힌다(acl_guard.bats류 건수 등식과 동형).
  [ "$(grep -cE '^\s*sensitive\s*=\s*true' "$O")" -eq "$(grep -cE '^output "' "$O")" ]
}

@test "the k8s-operator client's own scopes/tags stay pinned (this is the live cluster credential)" {
  # 이 리소스는 클러스터 안 tailscale-operator가 실제로 쓰는 자격이다 — provider.tf의 CI plan-only
  # 토큰(위 @test들)과 다른 값 축. scopes에 all:write류를 더하면 tailnet 전체 write 권한이,
  # tags를 확대하면 다른 태그로 디바이스 등록이 가능해진다. 행두·행말 앵커 전체 리터럴 일치로
  # 원소 추가·순서 변경·삭제 전부를 한 줄씩 닫는다(terraform fmt가 간격을 고정 — make tf-validate
  # 가 그 전제를 지킨다).
  run grep -Eq '^\s*scopes\s*=\s*\["devices:core", "auth_keys"\]\s*$' "$OAUTH"
  [ "$status" -eq 0 ]
  run grep -Eq '^\s*tags\s*=\s*\["tag:k8s-operator"\]\s*$' "$OAUTH"
  [ "$status" -eq 0 ]
}
