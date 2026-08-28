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


# ── 스캔 신호 (티켓 04) ────────────────────────────────────────────────────────
# 이 가드는 바닥값(MIN_STEPS)은 갖고도 스캔 신호가 **아예 없는** 네 번째 변종이었다.
# 신호가 없으면 관측하는 쪽에서 "돌지 않았다"와 "돌았고 통과했다"가 구별되지 않는다 —
# `check-guard-authority`의 실행 경로 회계가 그 구별을 못 하면 과다 계상으로 기운다.

# 마커의 값은 **실제로 계상한 스텝 수**여야 한다 — 상수나 원장 크기가 아니다.
# `[0-9]+` 형태만 보면 "평가함"과 "0건 붕괴"가 구별되지 않으므로 값을 대조한다.
# ⚠️ 대조 상대는 가드의 **사람용 출력 문구가 아니라** ci.yaml이다. 산문에 계약을 걸면 문구를
#    다듬는 것만으로 증인이 깨지고(리뷰 중 실제로 발생), 이 파일 헤더가 기록한 "하드코딩 5토큰"
#    클래스를 그대로 되풀이한다. 가드와 **같은 원본**에서 파생해야 대조가 의미를 갖는다.
@test "the scan marker counts the gate steps it actually accounted for" {
  run bun "$ROOT/tools/check-ci-parity.ts"
  [ "$status" -eq 0 ]
  marker="$(printf '%s\n' "$output" | sed -n 's/^SCAN: check-ci-parity: //p')"
  expected="$(yq -r '.jobs.gate.steps[] | select(has("run"))' "$ROOT/.github/workflows/ci.yaml" | grep -c '^run:' || true)"
  [ -n "$marker" ]
  # 도메인이 실재한다는 증거 — 0이면 아래 등식이 자기 자신 vacuous가 된다.
  [ "$marker" -gt 0 ]
  [ "$expected" -gt 0 ]
  [ "$marker" = "$expected" ]
}

# 바닥값 실패는 **오류 수집과 분리**되어 즉시 죽고 마커를 내지 않는다.
# 이행 전에는 `fail()`이 배열에 push할 뿐이라 바닥값 진단이 다른 회계 위반과 뒤섞였다 —
# 0건에 가까운 검사에서 나온 위반을 함께 보고하면 잘못된 그림을 준다.
# ⚠️ 붕괴는 **픽스처 cwd**로 만든다 — 이 도구는 process.cwd()를 읽는다. 바닥값에 env 주입을
#    열면 required gate의 붕괴 방어가 `CI_PARITY_MIN_STEPS=0` 한 줄로 꺼진다(한때 그렇게 열었다가
#    되돌렸다). 테스트 편의가 프로덕션 방어를 무르게 하면 안 된다.
@test "an enumeration collapse dies on the floor and withholds the marker" {
  fx="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$fx/.github/workflows"
  printf 'name: ci\non: push\njobs:\n  gate:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' \
    > "$fx/.github/workflows/ci.yaml"
  run bash -c "cd '$fx' && bun '$ROOT/tools/check-ci-parity.ts'"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q '열거 붕괴'
  printf '%s\n' "$output" | grep -q '무측정'
  if printf '%s\n' "$output" | grep -q '^SCAN:'; then
    echo "붕괴 실행이 마커를 냈다: $output"; false
  fi
  # ⚠️ 성공 요약 부재는 **어떤 실패 경로에서도** 참이라 수집 형태와 즉사 형태를 구별하지 못한다
  #    (실측: 그 단언만 두었을 때 catch를 fail()로 되돌려도 전건 green이었다 — 다섯 번째 vacuous 증인).
  #    **구별되는 사실은 진단이 몇 줄이냐다.** 즉사면 바닥값 한 줄이고, 수집이면 그 뒤 원장 대조까지
  #    진행돼 위반이 더 붙는다. 붕괴 진단의 접두는 커널 소유 `FAIL:`이다(guardMain 재접목 — 위반
  #    경로의 ::error:: 채널은 콜사이트 소유로 남고, 바닥값 경로의 GH annotation은 의도적 미사용).
  [ "$(printf '%s\n' "$output" | grep -c '^FAIL: check-ci-parity:')" -eq 1 ]
  if printf '%s\n' "$output" | grep -qE '^::error::ci-parity:|건 실패 \(gate run 스텝'; then
    echo "바닥값이 먼저 죽지 않아 수집 보고까지 진행됐다: $output"; false
  fi
}

# yq 실패의 근본원인 보존 — guardMain 재접목으로 형태가 바뀌었다: 파생 실패는 errors 수집이
# 아니라 enumerate의 throw이고, 커널이 "열거 실패" 진단에 그 원인(argv 접두 + exit 사유)을 담아
# 즉사한다. 순차판의 "앞에서 모인 진단을 먼저 흘린다" 손 처방은 열거가 floor보다 앞에서 끝나는
# 구조가 대체한다 — 원인이 floor 오진("열거 붕괴")으로 위장되지 않고 직접 보고된다.
@test "a derivation failure reports its root cause as an enumeration failure, not a floor misdiagnosis" {
  stub="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 3\n' > "$stub/yq"
  chmod +x "$stub/yq"
  run env PATH="$stub:$PATH" bun "$ROOT/tools/check-ci-parity.ts"
  [ "$status" -ne 0 ]
  # 근본원인이 열거 실패 진단에 담긴다 — 어느 파생이 죽었는지(yq argv 접두)와 사유(exit 3)까지.
  printf '%s\n' "$output" | grep -q '열거 실패'
  printf '%s\n' "$output" | grep -q 'yq'
  printf '%s\n' "$output" | grep -q 'exit 3'
  # floor 오진이 아니다 — 붕괴 문구가 아니라 원인 문구로 죽는다.
  if printf '%s\n' "$output" | grep -q '열거 붕괴'; then
    echo "근본원인이 floor 오진으로 위장됐다: $output"; false
  fi
  # 붕괴 실행은 마커를 내지 않는다.
  if printf '%s\n' "$output" | grep -q '^SCAN:'; then
    echo "붕괴 실행이 마커를 냈다: $output"; false
  fi
}


# 프로덕션 호출은 floor-free다(리뷰 H-1) — --floor는 테스트 전용 오버라이드이고, gate 스텝이
# 그것을 넘기면 required gate의 바닥값이 argv 한 줄로 꺼진다(env 폐지 결정의 기계 강제 승계).
# 픽스처 자신은 --floor로 자기 바닥값을 낮춰 reconcile까지 도달한다(테스트 호출이라 정당).
@test "a gate step passing --floor is rejected (production calls stay floor-free)" {
  fx="$BATS_TEST_TMPDIR/floored"
  mkdir -p "$fx/.github/workflows" "$fx/policy"
  cat > "$fx/.github/workflows/ci.yaml" <<'YAML'
name: ci
on: push
jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - name: floored
        run: bun tools/check-guard-authority.ts --floor guards=1
YAML
  printf '%s\n' '{"_readme": "fixture", "steps": [{"name": "floored", "status": "excluded", "why": "w", "since": "s", "owner_action": "o"}]}' \
    > "$fx/policy/ci-parity.json"
  run bash -c "cd '$fx' && bun '$ROOT/tools/check-ci-parity.ts' --floor check-ci-parity=1"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q -- "--floor를 넘긴다"
  # 대조군 — 같은 픽스처에서 --floor만 걷어내면 통과한다(픽스처 조립 자체의 실패가 아니다).
  python3 - "$fx/.github/workflows/ci.yaml" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
n = s.replace("bun tools/check-guard-authority.ts --floor guards=1", "bun tools/check-guard-authority.ts")
assert n != s; open(p, "w", encoding="utf-8").write(n)
PY
  run bash -c "cd '$fx' && bun '$ROOT/tools/check-ci-parity.ts' --floor check-ci-parity=1"
  [ "$status" -eq 0 ]
}

# ── mirrored는 자기 자신을 증명할 수 없다 ─────────────────────────────────────────────────────────
# ④는 `makeOut.includes(local)` 하나였다. 그런데 `make -n ci` 출력에는 **호출이 아닌 것**이 두 종류
# 섞여 있다: 전제 프로브 `command -v actionlint`와, 도구 부재 시 이름만 남기는 미평가 라벨
# `echo "actionlint(…)" >> .make-ci-uneval`. 둘 다 그 도구를 **부르지 않는다**.
# ⇒ 실제 호출을 지워도 두 문자열이 남아 대조가 통과했다 — 선언이 자기 자신을 증명한다(실측: 초록).
# 정제 대상은 그 둘뿐이고, 실 레포 mirrored 22항목·local 34문자열에 대한 오탐은 0건이다(실측).
mkparity_fixture() {   # $1=디렉토리  $2=then 절 본문
  mkdir -p "$1/.github/workflows" "$1/policy"
  printf 'name: ci\non: push\njobs:\n  gate:\n    runs-on: ubuntu-latest\n    steps:\n      - name: actionlint\n        run: actionlint\n' \
    > "$1/.github/workflows/ci.yaml"
  printf '%s\n' '{"_readme": "fixture", "steps": [{"name": "actionlint", "status": "mirrored", "local": "actionlint"}]}' \
    > "$1/policy/ci-parity.json"
  printf 'CI_UNEVAL := .make-ci-uneval\nci:\n\t@rm -f $(CI_UNEVAL)\n\t@if command -v actionlint >/dev/null 2>&1; then %s \\\n\t  else echo "actionlint(워크플로 정적 검사)" >> $(CI_UNEVAL); fi\n' \
    "$2" > "$1/Makefile"
}

@test "a probe or an unevaluated label cannot stand in for the call itself (mirrored proves nothing about itself)" {
  # 뮤테이션: 실제 호출만 지운다. 프로브 분기와 else 라벨은 그대로 둔다 — 이것이 오늘의 fail-open이다.
  gone="$BATS_TEST_TMPDIR/gone"
  mkparity_fixture "$gone" ':;'
  run bash -c "cd '$gone' && bun '$ROOT/tools/check-ci-parity.ts' --floor check-ci-parity=1"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q "make -n ci"

  # 대조군 — 같은 픽스처에서 호출만 되살리면 통과한다(픽스처 조립 자체의 실패가 아니다).
  kept="$BATS_TEST_TMPDIR/kept"
  mkparity_fixture "$kept" 'actionlint;'
  run bash -c "cd '$kept' && bun '$ROOT/tools/check-ci-parity.ts' --floor check-ci-parity=1"
  [ "$status" -eq 0 ]
}
