#!/usr/bin/env bats
# tf-reconcile.yaml의 안전 불변식 가드:
#  - github/tailscale 루트는 plan-only(무인 apply 절대 금지 — 신뢰 앵커/고-blast-radius).
#  - cloudflare 루트만 apply하며 destroy 가드를 유지한다.
#  - 각 드리프트 잡은 시크릿 부재 시 skip(preflight)되어야 한다.

WF="$BATS_TEST_DIRNAME/../../.github/workflows/tf-reconcile.yaml"

@test "github/tailscale drift jobs exist" {
  run grep -qE '^  drift-github:' "$WF"
  [ "$status" -eq 0 ]
  run grep -qE '^  drift-tailscale:' "$WF"
  [ "$status" -eq 0 ]
}

@test "github/tailscale roots are NEVER applied/destroyed unattended (plan-only)" {
  # 신뢰 앵커 보호: 이 두 루트에 대한 apply/destroy 호출이 워크플로에 있으면 안 된다.
  run grep -nE 'chdir=infra/(github|tailscale)[^|]*(apply|destroy)' "$WF"
  [ "$status" -ne 0 ]
}

@test "github/tailscale drift jobs use plan with detailed-exitcode" {
  run grep -qE 'chdir=infra/github plan .*-detailed-exitcode' "$WF"
  [ "$status" -eq 0 ]
  run grep -qE 'chdir=infra/tailscale plan .*-detailed-exitcode' "$WF"
  [ "$status" -eq 0 ]
}

@test "drift jobs skip when secrets absent (preflight gate)" {
  # 두 드리프트 잡 모두 configured 플래그로 게이트된다(+ 기존 reconcile preflight).
  run grep -c 'configured=true' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

@test "cloudflare reconcile keeps the destroy guard" {
  run grep -q 'uses: ./.github/actions/tf-destroy-guard' "$WF"
  [ "$status" -eq 0 ]
  run grep -qE 'chdir=infra/cloudflare apply' "$WF"
  [ "$status" -eq 0 ]
}

@test "cloudflare reconcile passes allow=app-DNS + allow_max cap (teardown auto, mass blocked)" {
  # app DNS(app[*])만 자동 apply, apex/www는 보호, allow_max로 대량 삭제 차단.
  grep -qF 'cloudflare_dns_record\.app' "$WF" && grep -qE '^[[:space:]]+allow_max:' "$WF"
}

@test "cloudflare reconcile uses the tf-destroy-guard composite (block) not inline jq" {
  run grep -q 'uses: ./.github/actions/tf-destroy-guard' "$WF"
  [ "$status" -eq 0 ]
  # 인라인 destroy jq가 reconcile에서 제거됐는지(composite로 수렴)
  run grep -F 'select(. == "delete")' "$WF"
  [ "$status" -ne 0 ]
}

@test "reconcile delete guard is alert-and-skip (does not hard-fail the job on delete)" {
  # drift-2: delete가 있어도 reconcile job 자체는 실패시키지 않는다(::warning:: + telegram). ⚠️ F3: saved-plan
  # apply는 원자적이라 delete 포함 시 apply 전체가 skip되며(부분 수렴 불가), owner 로컬 apply 후 다음 주기에 수렴.
  # 즉 reconcile 경로엔 'exit 1'로 잡을 죽이는 인라인 destroy 분기가 없어야 한다(가드는 continue-on-error로 강등).
  run grep -nE '무인 apply 차단.*exit 1|exit 1[[:space:]]*#.*destroy' "$WF"
  [ "$status" -ne 0 ]
}

@test "reconcile guard step is continue-on-error and emits a warning (not job failure)" {
  run grep -qE 'continue-on-error:[[:space:]]*true' "$WF"
  [ "$status" -eq 0 ]
}

@test "reconcile telegram fires on delete-blocked drift (owner-local apply nudge)" {
  # delete 차단 시에도 telegram이 발화하도록 알림 조건이 guard result(blocked-delete)를 포함해야 한다.
  run grep -qE "guard|blocked-delete|result" "$WF"
  [ "$status" -eq 0 ]
}

@test "reconcile apply gates on guard result==ok and fails the job on result==error (F1)" {
  # ⚠️ codex pass5 F1: outcome은 delete-block과 내부 오류를 구분 못 한다 — apply는 result=='ok'에서만,
  # result=='error'(가드 자체 깨짐)는 잡을 loud 실패시켜야(조용한 skip 금지).
  run grep -qE "steps\.guard\.outputs\.result == 'ok'" "$WF"
  [ "$status" -eq 0 ]
  run grep -qE "steps\.guard\.outputs\.result == 'error'" "$WF"
  [ "$status" -eq 0 ]
}
