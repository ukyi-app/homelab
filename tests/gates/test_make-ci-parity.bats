#!/usr/bin/env bats
# make ci == ci.yaml job 'gate' 패리티 — push 전 풀 게이트를 한 명령으로 재현하는 단일 진입점.
#
# ⚠️ **이 파일이 하던 방식이 바로 잡으려던 병이었다.** 예전에는 하드코딩된 5개 토큰(chart·ledger·audit·
#    shellcheck·alertmanager-e2e)이 `make -n ci`에 있는지만 봤다. 목록에 없는 게이트 스텝은 아무리 늘어나도
#    보이지 않는다 — 실측 시점에 gate의 run 스텝 19건 중 **8건**이 make ci에 없었는데 전 검사가 초록이었다
#    (하필 하드코딩된 5개가 전부 미러된 것들이라 우연히 통과했다). 티켓 07의 하드코딩 소비처 목록과 같은 클래스다.
#    ⇒ 스텝 단위 대조는 **tools/check-ci-parity.ts**가 ci.yaml에서 파생해 수행한다. 여기 남는 것은
#      그 도구가 **실제로 배선돼 있는지**와, 도구가 딛고 선 전제(러너 동치·`make -n`의 부수효과 부재)다.
#
# dry-run(make -n) + 정적 grep으로 age/docker 없이도 돈다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "make ci invokes the single bats runner (run-bats.sh)" {
  run make -n ci
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "run-bats.sh"
}

@test "ci.yaml gate invokes the same single bats runner (run-bats.sh)" {
  run grep -q 'run-bats.sh' "$ROOT/.github/workflows/ci.yaml"
  [ "$status" -eq 0 ]
}

@test "the parity accounting runs in BOTH the required gate and make ci" {
  # 한쪽에만 있으면 회계가 반쪽이다 — gate에만 있으면 로컬이 계속 거짓말을 하고,
  # make ci에만 있으면 아무도 강제하지 않는다.
  run grep -q 'check-ci-parity.ts' "$ROOT/.github/workflows/ci.yaml"
  [ "$status" -eq 0 ]
  run make -n ci
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "check-ci-parity.ts"
}

@test "the parity ledger accounts for every gate step (delegates to the tool)" {
  # 실제 판정은 도구가 한다. 여기서는 이 레포 상태에서 그 도구가 통과하는지를 본다 —
  # bats만 돌리는 사람에게도 드리프트가 보이도록.
  run bun "$ROOT/tools/check-ci-parity.ts"
  [ "$status" -eq 0 ]
}

@test "no recipe line uses recursive make — it executes even under 'make -n'" {
  # ⚠️ GNU make는 recipe 줄에 \$(MAKE)가 있으면 -n에서도 그 줄을 **실제로 실행한다**(재귀 make에 플래그를
  #    전파하려는 문서화된 동작). 그런데 이 레포는 `make -n ci` 출력을 **데이터로 읽는다**
  #    (check-ci-parity의 미러 대조 · check-guard-authority의 venue 수집).
  #    실측: 게이트 스텝을 서브-make로 묶었더니 `make -n ci` 한 번에 docker e2e가 통째로 돌았다.
  # 레시피 줄(탭으로 시작)만 본다 — 주석의 설명 문구는 대상이 아니다.
  run bash -c "grep '^	' '$ROOT/Makefile' | grep -F '\$(MAKE)'"
  [ "$status" -ne 0 ]
}

@test "make ci depends on the m6-tools toolchain check" {
  run make -n ci
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "required"
}

@test "memory ledger gate runs in the required gate" {
  # W7: ledger 검사(conftest policy/ledger.rego)는 required gate(ci.yaml: bun run verify:ledger) 한 곳으로 일원화.
  run grep -q 'verify:ledger' "$ROOT/.github/workflows/ci.yaml"
  [ "$status" -eq 0 ]
}

@test "make ci refuses to run while gate-scoped files are untracked (local under-measures)" {
  # ⚠️ 이 레포의 게이트는 대부분 `git ls-files`로 열거한다 → untracked 파일은 **로컬에서 측정 대상 밖**인데
  #    커밋되면 CI에서는 측정된다. 그 상태의 `make ci` 초록은 gate를 재현한 것이 아니다.
  #    실측(2026-07-28): 새 tools/*.ts를 `git add` 전에 검증해 1671건 전건 초록이었는데 커밋 직후 CI가 red.
  # 가드는 ci의 **첫 전제**여야 한다(1분짜리 chart-test 앞에서 끊는다).
  run grep -qE '^ci: ci-guard-tracked ' "$ROOT/Makefile"
  [ "$status" -eq 0 ]

  # 양성 대조: 깨끗한 상태에서는 통과한다(항상 죽는 가드는 아무도 안 쓴다 → 곧 제거된다).
  run make ci-guard-tracked
  [ "$status" -eq 0 ]

  # 핵심 단언(마지막): untracked 파일을 넣으면 마커 + 비-0.
  probe="$ROOT/tools/__ci_parity_probe_$$.ts"
  printf '// probe\n' > "$probe"
  run make ci-guard-tracked
  rm -f "$probe"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'SKIP: ci: 추적되지 않은'
}

