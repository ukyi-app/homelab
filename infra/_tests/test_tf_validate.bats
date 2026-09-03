#!/usr/bin/env bats
# terraform 의존 — 이 파일은 tests/.ci-exclude 등재라 gate에서 돌지 않는다(실행처: advisory iac.yaml).
# ⚠️ terraform을 요구하지 않는 정적 계약(R2 prevent_destroy 신원·app DNS 자원 분리)은
#    infra/_tests/test_tf_static.bats로 갈라져 gate에서 돈다 — 여기 되돌려 넣지 말 것.
# ⚠️ **gate 편입은 평가 후 기각했다**(2026-09-03 실측). `terraform validate`는 provider를 요구해
#    `init` 없이는 3루트 모두 rc=1이고, `init -backend=false -lockfile=readonly`는 콜드에서 11.6s에
#    299MB를 registry.terraform.io에서 받는다. required check가 `gate` 하나뿐이라 그 편입은 전 PR을
#    서드파티 레지스트리 가용성에 매단다. 게다가 이 파일의 결함 클래스는 advisory 잡의 **바로 앞
#    스텝**(같은 init 3루트 + `make tf-validate`)이 이미 덮는다 — 여기 고유한 것은 `<root>: validated`
#    echo 대조뿐이다. 사유 전문과 수치는 tests/.ci-exclude의 이 항목 주석 블록이 소유한다.

@test "make tf-validate exits 0 across all roots" {
  run make tf-validate
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- "cloudflare: validated"
  printf '%s' "$output" | grep -qF -- "tailscale: validated"
  [[ "$output" == *"github: validated"* ]]
}
