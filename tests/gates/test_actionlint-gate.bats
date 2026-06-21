#!/usr/bin/env bats
# actionlint가 required gate(ci.yaml)에서 워크플로를 검사하는지 + 설치가 핀+체크섬인지. ⚠️ [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "setup-toolchain has a pinned, checksummed actionlint install step" {
  # YAML은 inputs: + 자식 actionlint: 키 구조 — 리터럴 'inputs.actionlint' 아님(F4). 실제 키를 grep.
  run grep -Eq '^[[:space:]]+actionlint:' .github/actions/setup-toolchain/action.yml
  [ "$status" -eq 0 ]
  run grep -Fq 'rhysd/actionlint' .github/actions/setup-toolchain/action.yml
  [ "$status" -eq 0 ]
  run grep -Fq 'sha256sum -c -' .github/actions/setup-toolchain/action.yml   # 체크섬 검증 패턴
  [ "$status" -eq 0 ]
}

@test "ci.yaml gate runs actionlint" {
  # gate 잡 안 스텝(별도 잡이면 비-required라 무성 회귀 — A.5/F8 가드와 동일 논리)
  run grep -Eq '^\s+run:\s+actionlint|actionlint\b' .github/workflows/ci.yaml
  [ "$status" -eq 0 ]
  run grep -Fq "actionlint: 'true'" .github/workflows/ci.yaml
  [ "$status" -eq 0 ]
}

@test "queue: max mutation-queue contract survives actionlint addition (F3)" {
  # actionlint가 concurrency.queue를 schema-lag로 거부해도 queue:max를 지우면 직렬화 계약 파괴 — 보존 단언.
  for wf in create-database bump-poll bump tf-reconcile create-app; do
    run grep -Fq 'queue: max' ".github/workflows/$wf.yaml"
    [ "$status" -eq 0 ]
  done
}
