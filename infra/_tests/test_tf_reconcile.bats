#!/usr/bin/env bats
# tf-reconcile.yml의 안전 불변식 가드:
#  - github/tailscale 루트는 plan-only(무인 apply 절대 금지 — 신뢰 앵커/고-blast-radius).
#  - cloudflare 루트만 apply하며 destroy 가드를 유지한다.
#  - 각 드리프트 잡은 시크릿 부재 시 skip(preflight)되어야 한다.

WF="$BATS_TEST_DIRNAME/../../.github/workflows/tf-reconcile.yml"

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
  run grep -q '무인 apply 차단' "$WF"
  [ "$status" -eq 0 ]
  run grep -qE 'chdir=infra/cloudflare apply' "$WF"
  [ "$status" -eq 0 ]
}
