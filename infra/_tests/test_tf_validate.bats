#!/usr/bin/env bats
# terraform 의존 — 이 파일은 tests/.ci-exclude 등재라 gate에서 돌지 않는다(실행처: advisory iac.yaml).
# ⚠️ terraform을 요구하지 않는 정적 계약(R2 prevent_destroy 신원·app DNS 자원 분리)은
#    infra/_tests/test_tf_static.bats로 갈라져 gate에서 돈다 — 여기 되돌려 넣지 말 것.

@test "make tf-validate exits 0 across all roots" {
  run make tf-validate
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- "cloudflare: validated"
  printf '%s' "$output" | grep -qF -- "tailscale: validated"
  [[ "$output" == *"github: validated"* ]]
}
