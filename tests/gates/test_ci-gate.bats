#!/usr/bin/env bats
WF=".github/workflows/ci.yaml"

# ⚠️ **구조 판정(F10)** — `cat | grep -F` 리터럴은 주석·비활성 스텝과 실제 `run` 필드를 구별하지
#    못한다. 실측 2026-09-03: ci.yaml의 세 `run:` 줄(typecheck·chart-test·verify:ledger)을
#    `# run: …`로 주석 처리해도 이 파일이 3/3 green이었고, 스텝 **이름을 보존한 채** 원장 스텝의
#    본문만 no-op으로 바꾸면(`run: echo ledger-skipped`) check-ci-parity(25건 전건 계상)·
#    check-guard-authority·test_make-ci-parity까지 전부 초록이라 required gate에서 메모리 원장이
#    사라진 상태를 증언하는 레인이 레포에 0건이었다. ci-parity는 스텝 **이름**으로 계상하므로
#    이 레인이 그 축의 두 번째 겹이다.
# ⚠️ `| .run`을 반드시 붙인다 — 없으면 「yq -e는 값이 false면 exit 1」 축에 스스로 노출된다.
#    형제 선례: tests/gates/test_check-skeleton-gate.bats:12(같은 이유로 이미 전환된 자리).
@test "ci gate has ACTIVE run steps for typecheck, chart-test, ledger gate, and bats (structural, F10)" {
  run yq -e '.jobs.gate.steps[] | select((.run // "") | test("bun run typecheck")) | .run' "$WF"
  [ "$status" -eq 0 ]
  run yq -e '.jobs.gate.steps[] | select((.run // "") | test("make chart-test")) | .run' "$WF"
  [ "$status" -eq 0 ]
  run yq -e '.jobs.gate.steps[] | select((.run // "") | test("verify:ledger")) | .run' "$WF"
  [ "$status" -eq 0 ]
  run yq -e '.jobs.gate.steps[] | select((.run // "") | test("run-bats.sh")) | .run' "$WF"
  [ "$status" -eq 0 ]
}

@test "ci runs on pull_request and uses the setup-bun composite" {
  run yq '.on.pull_request' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  # bun 버전 핀은 setup-bun composite로 이전 — ci가 composite를 채택하고 composite가 핀한다.
  run grep -F 'uses: ./.github/actions/setup-bun' "$WF"
  [ "$status" -eq 0 ]
  # 버전 **값**의 소유자는 tests/gates/test_setup-bun.bats의 CANON 등식 하나뿐이다 — 여기서는
  # composite가 bun-version을 핀한다는 사실만 본다(리터럴을 복제하면 bump가 손편집 7곳이 된다).
  run grep -E 'bun-version: "[0-9.]+"' .github/actions/setup-bun/action.yml
  [ "$status" -eq 0 ]
}

@test "ci and verify workflows declare a concurrency group with cancel-in-progress" {
  run grep -E "^concurrency:" "$WF"
  [ "$status" -eq 0 ]
  run grep -E "cancel-in-progress" "$WF"
  [ "$status" -eq 0 ]
}
