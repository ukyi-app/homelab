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

@test "the ledger's local roster is derived from ci.yaml, not hand-maintained (direction 7 bites)" {
  # ★ ④(원장 → `make -n ci`)만으로는 **원장에 안 적은 커맨드**가 원리적으로 안 보인다. 그래서
  #   `실 도메인 가드` 스텝의 커맨드 10건 중 원장엔 8건만 있었고, `check-locale-collation`·
  #   `check-gh-secret-coverage`가 빠진 채 오래 초록이었다(실측 2026-08-21). 그 목록이 곧
  #   AGENTS.md가 금지하는 하드코딩 소비처 목록이었다.
  #   여기서는 그 사고를 **재현해** 방향 ⑦이 실제로 무는지 본다(픽스처는 원장 사본에만 가한다).
  cp "$ROOT/policy/ci-parity.json" "$BATS_TEST_TMPDIR/orig.json"
  run bun -e '
    const fs = require("fs");
    const p = "policy/ci-parity.json";
    const d = JSON.parse(fs.readFileSync(p, "utf8"));
    for (const s of d.steps) {
      if (s.name.includes("실 도메인") && Array.isArray(s.local)) {
        s.local = s.local.filter((x) => !x.includes("locale-collation"));
      }
    }
    fs.writeFileSync(p, JSON.stringify(d, null, 2) + "\n");
  '
  [ "$status" -eq 0 ]
  run bun tools/check-ci-parity.ts
  mutated_status="$status"; mutated_output="$output"
  cp "$BATS_TEST_TMPDIR/orig.json" "$ROOT/policy/ci-parity.json"   # 무슨 일이 있어도 되돌린다
  [ "$mutated_status" -ne 0 ]
  printf '%s' "$mutated_output" | grep -qF 'check-locale-collation.sh'
  printf '%s' "$mutated_output" | grep -qF '원장 local에 없다'
  # 음성 대조 — 원복하면 초록이다(원복 실패를 다음 테스트가 떠안지 않게 여기서 확인한다).
  run bun tools/check-ci-parity.ts
  [ "$status" -eq 0 ]
}

@test "direction 7 accepts the ledger's own notation — basenames, globs and interpreter prefixes" {
  # ★ 원장의 `local`은 `make -n ci` 출력과 대조되므로 Makefile이 쓰는 형태를 따른다:
  #   basename(`check-ci-parity.ts`) · 글롭(`vmalert-*-firing-e2e.sh`) · 인터프리터 접두
  #   (`bash tests/gates/image-pin-liveness.sh`) · 인자(`tools/audit-orphans.ts --ci`).
  #   전체 경로로만 대조하면 이 방향이 **정상 원장을 물어** 아무도 안 켠다 — 그 표기들이 실제로
  #   원장에 있고 현재 통과한다는 사실로 확인한다.
  run bash -c "grep -c 'vmalert-\*-firing-e2e.sh' '$ROOT/policy/ci-parity.json'"
  [ "$output" -ge 1 ]
  run bash -c "grep -c 'bash tests/gates/image-pin-liveness.sh' '$ROOT/policy/ci-parity.json'"
  [ "$output" -ge 1 ]
  run bash -c "grep -c 'tools/audit-orphans.ts --ci' '$ROOT/policy/ci-parity.json'"
  [ "$output" -ge 1 ]
  run bun tools/check-ci-parity.ts
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

