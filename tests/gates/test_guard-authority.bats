#!/usr/bin/env bats
# G1 권위 경로 회계(tools/check-guard-authority.ts)의 gate 테스트.
#
# 병: 가드가 추가되고, README에 등재되고, 전 게이트가 초록이고, **CI에서 한 번도 실행되지 않을 수 있다.**
# required check는 `gate` 하나인데 `make verify`는 CI에서 안 돈다 — 두 스텝 목록을 대조하는 것이 없었다.
#
# 이 스위트가 지켜야 할 것은 회계의 **판별력**이다: 권위 0을 잡는가, 그리고 mirror(make verify)를
# 권위로 착각하지 않는가. 픽스처는 최소 레포(git init + ci.yaml + Makefile)로 만든다 — 실 레포로만
# 단언하면 전건 통과라 죽은 가드가 된다(PROGRESS.md 규율: 새 규칙마다 mutation으로 load-bearing 실측).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TOOL="$ROOT/tools/check-guard-authority.ts"
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX/scripts" "$FIX/.github/workflows"
  git -C "$FIX" init -q

  # 세 가드: 권위 있음 / mirror에만 있음 / 아무 데도 없음.
  for g in real mirrored orphan; do
    printf '#!/usr/bin/env bash\necho "check-%s ok"\n' "$g" > "$FIX/scripts/check-$g.sh"
  done

  # ci.yaml gate — check-real만 부른다.
  cat > "$FIX/.github/workflows/ci.yaml" <<'YAML'
name: ci
on: [pull_request]
jobs:
  gate:
    runs-on: ubuntu-24.04-arm
    steps:
      - run: bash scripts/check-real.sh
YAML

  # Makefile — verify(=mirror)는 셋 중 둘을 부르지만 권위가 아니다.
  printf 'verify: ## mirror\n\t@bash scripts/check-mirrored.sh\n\t@bash scripts/check-real.sh\n' > "$FIX/Makefile"

  git -C "$FIX" add -A
}

run_tool() { run bun "$TOOL" --repo-root "$FIX" --min-scan 3 "$@"; }

@test "a guard reachable only through the local mirror (make verify) counts as orphaned" {
  # 이 구분이 회계의 핵심이다 — make verify는 CI에서 돌지 않으므로 거기 있다는 건 보호가 아니다.
  run_tool
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "scripts/check-mirrored.sh"
  echo "$output" | grep -q "비권위 경로만"
}

@test "a guard with no invocation anywhere is reported as orphaned" {
  run_tool
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "scripts/check-orphan.sh"
  echo "$output" | grep -q "어떤 경로에도 없음"
}

@test "a guard invoked by the ci gate is not reported (authoritative >= 1)" {
  run_tool
  out="$output"
  run grep -q "scripts/check-real.sh" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "overlapping venues pass — authoritative>=1 plus N non-authoritative is not double ownership" {
  # 초안 모델이 `count == 1`이었다면 check-real(gate + make verify)이 이중소유 오탐이었다(design-r1 R-2).
  # 비권위 경로를 더 늘려도 판정이 바뀌지 않아야 한다.
  printf 'verify: ## mirror\n\t@bash scripts/check-real.sh\n\nci: ## mirror2\n\t@bash scripts/check-real.sh\n' > "$FIX/Makefile"
  rm "$FIX/scripts/check-mirrored.sh" "$FIX/scripts/check-orphan.sh"
  git -C "$FIX" add -A
  run bun "$TOOL" --repo-root "$FIX" --min-scan 1
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "전건 권위 경로 ≥1"
}

@test "a scheduled workflow is an authoritative venue" {
  cat > "$FIX/.github/workflows/cron.yaml" <<'YAML'
name: cron
on:
  schedule:
    - cron: "0 3 * * 1"
jobs:
  sweep:
    runs-on: ubuntu-24.04-arm
    steps:
      - run: bash scripts/check-orphan.sh --days 14
YAML
  git -C "$FIX" add -A
  run_tool
  out="$output"
  run grep -q "scripts/check-orphan.sh" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "invocation through a shell variable binding is detected (no false orphan)" {
  # 실측 형태: CHECK="$ROOT/scripts/check-x.sh" … run bash "$CHECK"
  # (tools/tests/test_app-deploy.bats:7,45). 직접 경로만 보면 그 가드가 고아로 오탐된다.
  printf 'verify: ## mirror\n\t@true\n' > "$FIX/Makefile"
  cat > "$FIX/.github/workflows/ci.yaml" <<'YAML'
name: ci
on: [pull_request]
jobs:
  gate:
    runs-on: ubuntu-24.04-arm
    steps:
      - run: |
          C="scripts/check-orphan.sh"
          bash "$C"
YAML
  rm "$FIX/scripts/check-real.sh" "$FIX/scripts/check-mirrored.sh"
  git -C "$FIX" add -A
  run bun "$TOOL" --repo-root "$FIX" --min-scan 1
  [ "$status" -eq 0 ]
}

@test "a mere mention in a comment is not an invocation" {
  # 주석의 언급이 권위로 둔갑하면 회계가 통째로 vacuous해진다.
  printf 'verify: ## mirror\n\t@true\n' > "$FIX/Makefile"
  cat > "$FIX/.github/workflows/ci.yaml" <<'YAML'
name: ci
on: [pull_request]
jobs:
  gate:
    runs-on: ubuntu-24.04-arm
    steps:
      - run: |
          # scripts/check-orphan.sh 는 여기서 부르지 않는다(주석일 뿐)
          true
YAML
  rm "$FIX/scripts/check-real.sh" "$FIX/scripts/check-mirrored.sh"
  git -C "$FIX" add -A
  run bun "$TOOL" --repo-root "$FIX" --min-scan 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "scripts/check-orphan.sh"
}

# 리뷰 실측: mirror를 이름(`verify`/`ci`)으로 선언하던 동안 타깃을 `verify-all`로 개명하기만 해도
# "로컬에만 있고 CI엔 없는 가드"가 통과했다. mirror는 이름이 아니라 성질로 판정해야 한다.
@test "a local mirror is non-authoritative under any target name (not a hardcoded name list)" {
  rm -f "$FIX/scripts/check-real.sh" "$FIX/scripts/check-orphan.sh"
  for name in verify verify-all local-checks; do
    printf '%s: ## local mirror\n\t@bash scripts/check-mirrored.sh\n' "$name" > "$FIX/Makefile"
    git -C "$FIX" add -A
    run bun "$TOOL" --repo-root "$FIX" --min-scan 1
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "scripts/check-mirrored.sh"
  done
}

# 반대 갈래 — skip 신호 규약(티켓 01)을 쓰는 가드를 부르는 make 타깃은 권위다. 그 마커가
# "이 도메인은 CI에 없을 수 있다"는 선언이고, 그때 owner-local 엔트리포인트가 유일한 권위이기 때문.
@test "a make target invoking a SKIP-convention guard is authoritative (owner-local)" {
  printf '#!/usr/bin/env bash\necho "SKIP: mirrored: 도메인 없음"; exit 4\n' > "$FIX/scripts/check-mirrored.sh"
  printf 'whatever: ## owner-local\n\t@bash scripts/check-mirrored.sh\n' > "$FIX/Makefile"
  rm -f "$FIX/scripts/check-real.sh" "$FIX/scripts/check-orphan.sh"
  git -C "$FIX" add -A
  run bun "$TOOL" --repo-root "$FIX" --min-scan 1
  [ "$status" -eq 0 ]
}

# 리뷰 실측: 따옴표 안의 `|`·`;`·`()`를 연산자로 쪼개는 바람에 grep/yq **패턴**이 명령 head로
# 승격돼, 호출이 0건인 가드가 권위를 얻었다(vacuous pass).
@test "a guard path inside a quoted pattern is not an invocation" {
  rm -f "$FIX/scripts/check-real.sh" "$FIX/scripts/check-mirrored.sh"
  printf 'verify: ## mirror\n\t@true\n' > "$FIX/Makefile"
  cat > "$FIX/.github/workflows/ci.yaml" <<'YAML'
name: ci
on: [pull_request]
jobs:
  gate:
    runs-on: ubuntu-24.04-arm
    steps:
      - run: |
          grep -qE "foo|scripts/check-orphan.sh" some-file
          yq -e '.jobs.gate.steps[] | select((.run // "") | test("scripts/check-orphan.sh"))' f.yaml
YAML
  git -C "$FIX" add -A
  run bun "$TOOL" --repo-root "$FIX" --min-scan 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "scripts/check-orphan.sh"
}

# 반대 방향의 실패(거짓 red)가 더 나쁘다 — 셸 키워드 뒤 호출을 못 보면 정당한 가드가 고아로 오탐된다.
@test "an invocation behind a shell keyword (then/do) is detected" {
  rm -f "$FIX/scripts/check-real.sh" "$FIX/scripts/check-mirrored.sh"
  printf 'verify: ## mirror\n\t@true\n' > "$FIX/Makefile"
  cat > "$FIX/.github/workflows/ci.yaml" <<'YAML'
name: ci
on: [pull_request]
jobs:
  gate:
    runs-on: ubuntu-24.04-arm
    steps:
      - run: |
          if [ -f x ]; then bash scripts/check-orphan.sh; fi
YAML
  git -C "$FIX" add -A
  run bun "$TOOL" --repo-root "$FIX" --min-scan 1
  [ "$status" -eq 0 ]
}

@test "the enumeration floor fires when the guard scope collapses" {
  run bun "$TOOL" --repo-root "$FIX" --min-scan 9999
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "열거 붕괴"
}

@test "every guard in the real repo has an authoritative path" {
  run bun "$TOOL" --repo-root "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "전건 권위 경로 ≥1"
}
