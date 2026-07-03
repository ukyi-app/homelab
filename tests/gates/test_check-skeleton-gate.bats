#!/usr/bin/env bats
# check-skeleton이 required gate(ci.yaml job 'gate')에서 실행되는지 + verify.yaml 중복 제거.
# yq 구조 파싱(주석/비활성 스텝 false-positive 차단, F10). ⚠️ [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  if ! command -v yq >/dev/null; then
    [ -z "${CI:-}" ] || { echo "FAIL: CI인데 yq 부재 — gate 구조 검증 불가(dead-green 방지)"; return 1; }
    skip "yq 미설치(로컬만 — CI는 setup-toolchain 제공)"
  fi
}

@test "required gate has an ACTIVE run step invoking check-skeleton.sh (structural, F10)" {
  # 주석/비활성 텍스트가 아니라 jobs.gate.steps[]의 실제 run 필드
  run yq -e '.jobs.gate.steps[] | select((.run // "") | test("scripts/check-skeleton.sh")) | .run' .github/workflows/ci.yaml
  [ "$status" -eq 0 ]
}

@test "verify.yaml no longer runs check-skeleton (single authority, structural)" {
  run yq -e '.jobs.verify.steps[] | select((.run // "") | test("check-skeleton"))' .github/workflows/verify.yaml
  [ "$status" -ne 0 ]
}

@test "make ci mirrors check-skeleton" {
  run awk '/^ci:/{c=1} c && /check-skeleton/{print}' Makefile
  [ -n "$output" ]
}

@test "ci gate setup-toolchain enables kustomize + yq (render guard cannot silently skip in CI, F6/F10)" {
  # jobs.gate.steps[]의 setup-toolchain 스텝 with.kustomize/with.yq가 'true'(주석 아닌 실제 필드)
  run yq -e '.jobs.gate.steps[] | select((.uses // "") | test("setup-toolchain")) | (.with.kustomize == "true" and .with.yq == "true")' .github/workflows/ci.yaml
  [ "$status" -eq 0 ]; [ "$output" = "true" ]
}

@test "check-skeleton FAILS when README component table lists a nonexistent platform dir (reverse tie)" {
  run bash -c 'sed "s/| \`files\`/| \`ghostcomp\`/" README.md > /tmp/ck_readme_$$ && CK_README=/tmp/ck_readme_$$ ./scripts/check-skeleton.sh; rc=$?; rm -f /tmp/ck_readme_$$; exit $rc'
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "ghostcomp"
}
