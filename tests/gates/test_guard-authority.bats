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

run_tool() { run bun "$TOOL" --repo-root "$FIX" --floor guards=3 "$@"; }

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
  run bun "$TOOL" --repo-root "$FIX" --floor guards=1
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
  run bun "$TOOL" --repo-root "$FIX" --floor guards=1
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
          #scripts/check-orphan.sh 는 여기서 부르지 않는다(주석일 뿐 — 공백 없는 형태라야
          # commandHeads 토큰화가 아니라 stripComment이 load-bearing이 된다)
          true
YAML
  rm "$FIX/scripts/check-real.sh" "$FIX/scripts/check-mirrored.sh"
  git -C "$FIX" add -A
  run bun "$TOOL" --repo-root "$FIX" --floor guards=1
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
    run bun "$TOOL" --repo-root "$FIX" --floor guards=1
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
  run bun "$TOOL" --repo-root "$FIX" --floor guards=1
  [ "$status" -eq 0 ]
}

@test "a make target invoking a guard_skip-routed guard is authoritative (helper era)" {
  # 07 이관 후 콜사이트에는 emission이 없다 — 헬퍼 호출 자체가 skip 규약 사용의 증거다(티켓 11,
  # 02에서 오탐 때문에 연기했던 확장). 이 인식이 없으면 헬퍼 경유 가드의 owner-local 권위가 죽는다.
  # ⚠️ 호출 행은 실 트리 형태(verify-runbook-index.sh:15)를 그대로 밟는다 — `${#files[@]}`의 `#`이
  # guard_skip **앞**에 있어, 주석-제외를 행 전역 문자클래스로 쓰면 이 행이 통째로 미탐이 된다(실측).
  printf '#!/usr/bin/env bash\n. scripts/lib/guard.sh\nguard_init check-mirrored\nfiles=()\nif [ ${#files[@]} -eq 0 ]; then guard_skip check-mirrored "도메인 없음"; fi\n' > "$FIX/scripts/check-mirrored.sh"
  printf 'whatever: ## owner-local\n\t@bash scripts/check-mirrored.sh\n' > "$FIX/Makefile"
  rm -f "$FIX/scripts/check-real.sh" "$FIX/scripts/check-orphan.sh"
  git -C "$FIX" add -A
  run bun "$TOOL" --repo-root "$FIX" --floor guards=1
  [ "$status" -eq 0 ]
}

@test "a make target invoking a ts guard that calls skip(...) is authoritative" {
  mkdir -p "$FIX/tools"
  printf 'import { skip } from "./lib/cli.ts";\nif (!process.env.DOMAIN) skip("check-tsguard", "도메인 없음");\n' > "$FIX/tools/check-tsguard.ts"
  printf 'whatever: ## owner-local\n\t@bun tools/check-tsguard.ts\n' > "$FIX/Makefile"
  rm -f "$FIX/scripts/check-real.sh" "$FIX/scripts/check-mirrored.sh" "$FIX/scripts/check-orphan.sh"
  git -C "$FIX" add -A
  run bun "$TOOL" --repo-root "$FIX" --floor guards=1
  [ "$status" -eq 0 ]
}

@test "the real repo keeps make verify as a mirror (no self-promotion)" {
  # 리뷰 실측(11): 이 도구 자신의 주석 산문(백틱 인라인 코드 안의 TS 헬퍼 호출 모양)이 분기 ③에
  # 매치하면 스스로 skipGuards에 들어가고, 자신을 부르는 make verify가 owner-local로 승격된다 —
  # "make verify에만 있는 가드는 고아"라는 이 회계의 전제가 실 트리에서 무효가 된다.
  # ⚠️ make:ci는 여기 안 넣는다 — ci recipe 자신이 SKIP 규약을 직접 쓴다(untracked 가드·미평가
  #    원장, `make -n ci`에 'SKIP: ci:' 방출 2건 실측)라 ② 레인의 **정당한** owner-local이다.
  bun "$TOOL" --json --repo-root "$ROOT" > "$BATS_TEST_TMPDIR/report.json"
  cat > "$BATS_TEST_TMPDIR/assert.ts" <<'TS'
const r = await Bun.file(process.argv[2]).json();
const bad = r.report.flatMap((g: { authoritative: string[] }) => g.authoritative)
  .filter((v: string) => v === "make:verify");
if (bad.length) { console.error("owner-local로 승격된 mirror: " + bad.join(", ")); process.exit(1); }
console.log("mirrors stay mirrors");
TS
  run bun "$BATS_TEST_TMPDIR/assert.ts" "$BATS_TEST_TMPDIR/report.json"
  [ "$status" -eq 0 ]
}

@test "prose mentioning the helpers does not promote a guard to the skip convention" {
  # 02 리뷰의 오탐 2형("skip(cert" 문자열·"// skip(4)" 주석) + 산문·대입 — 규약을 다루는 코드는
  # 규약을 쓰는 가드가 아니다. 이들이 승격되면 mirror 타깃이 조용히 권위로 둔갑한다.
  printf '#!/usr/bin/env bash\nh="guard_skip"\necho "헬퍼(guard_skip / skip()) 경유만"\necho "skip(cert"\n# skip(4)은 내지 않는다\necho ok\n' > "$FIX/scripts/check-mirrored.sh"
  printf 'whatever: ## still a mirror\n\t@bash scripts/check-mirrored.sh\n' > "$FIX/Makefile"
  rm -f "$FIX/scripts/check-real.sh" "$FIX/scripts/check-orphan.sh"
  git -C "$FIX" add -A
  run bun "$TOOL" --repo-root "$FIX" --floor guards=1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "비권위 경로만"
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
  run bun "$TOOL" --repo-root "$FIX" --floor guards=1
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
  run bun "$TOOL" --repo-root "$FIX" --floor guards=1
  [ "$status" -eq 0 ]
}

@test "the enumeration floor fires when the guard scope collapses" {
  run bun "$TOOL" --repo-root "$FIX" --floor guards=9999
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "열거 붕괴"
}

@test "every guard in the real repo has an authoritative path" {
  run bun "$TOOL" --repo-root "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "전건 권위 경로 ≥1"
}

# ── 스캔 커널 이행 (티켓 02) ───────────────────────────────────────────────────
# 바닥값 주입이 raw 문자열을 Number() **앞에서** 판정해야 한다. `Number("")===0`이고
# `n < NaN`은 항상 false라, coercion 뒤에 검증하면 오타 하나가 바닥값을 조용히 끈다.

@test "a malformed --floor value is rejected instead of silently disabling the floor" {
  for bad in abc "" 1.5 -1; do
    run bun "$TOOL" --floor "guards=$bad"
    [ "$status" -eq 2 ]
    out="$output"
    # 바닥값이 꺼진 채 초록이 되면 마커가 나간다 — 나가면 안 된다.
    run grep -q "^SCAN:" <<<"$out"
    [ "$status" -ne 0 ]
  done
}

# 억제는 출력 채널의 성질이지 판정의 성질이 아니다 — JSON 모드에서도 바닥값은 본다.
@test "the json mode still enforces the enumeration floor" {
  run bun "$TOOL" --json --floor guards=9999
  [ "$status" -ne 0 ]
  out="$output"
  run grep -q "열거 붕괴" <<<"$out"
  [ "$status" -eq 0 ]
  # 붕괴한 실행은 마커도 JSON도 내지 않는다.
  run grep -q "^SCAN:" <<<"$out"
  [ "$status" -ne 0 ]
}

# 라벨 = 바닥값이 걸린 열거 도메인 하나. venues는 **바닥값이 걸리지 않은** 카운트 자리라
# 검사한 수(권위 venue)와 보고한 수(전체 venue)가 다르다 — 그 성질이 보존돼야 한다.
#
# ⚠️ 마커의 **존재와 숫자꼴**만 보면 이 단언은 vacuous다 — 실측: 신호 대상을 authoritativeVenues로
#    바꿔(297→265, 성질 파괴) 돌려도 45건 전부 green이었다. 그래서 **값**을 대조한다.
@test "the venues marker counts every venue, not just the authoritative ones" {
  run bun "$TOOL"
  [ "$status" -eq 0 ]
  marker="$(printf '%s\n' "$output" | sed -n 's/^SCAN: check-guard-authority:venues: //p')"
  guards_marker="$(printf '%s\n' "$output" | sed -n 's/^SCAN: check-guard-authority:guards: //p')"
  [ -n "$marker" ]
  [ -n "$guards_marker" ]
  # 두 라벨은 서로 다른 도메인을 센다 — 같은 수면 라벨을 나눌 이유가 없다.
  [ "$marker" -ne "$guards_marker" ]
  # 핵심: 마커가 세는 것은 **전체** venue다. JSON 모드의 venues 필드가 그 정의이므로 값이 같아야 한다.
  run bun "$TOOL" --json
  [ "$status" -eq 0 ]
  total="$(printf '%s\n' "$output" | jq -r '.venues')"
  [ "$marker" = "$total" ]
  # 그 구별이 **관측 가능**해야 이 단언이 의미를 갖는다 — 비권위(mirror) venue가 0이면
  # 전체와 권위가 같아져 위 대조가 자기 자신 vacuous가 된다.
  nonauth="$(printf '%s\n' "$output" | jq -r '[.report[].nonAuthoritative[]] | unique | length')"
  [ "$nonauth" -gt 0 ]
}

# venue 수집이 붕괴하면 **어느 도메인의 마커도** 나가지 않는다 — guardMain 일괄 방출(17 재접목).
# 순차판은 guards 마커가 먼저 나가 "앞 도메인 유지"였지만, 붕괴한 실행의 어떤 건수도 "검사했다"로
# 읽히면 안 된다. 권위 venue 축도 셋째 도메인으로 승격돼 같은 실행에서 함께 보고된다(13 리뷰 ②).
@test "a venue collapse withholds every marker and reports both venue floors (batch emission)" {
  tmp="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$tmp"
  git -C "$tmp" init -q
  run bun "$TOOL" --repo-root "$tmp" --floor guards=0
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'check-guard-authority:venues:.*열거 붕괴'
  printf '%s\n' "$output" | grep -q 'check-guard-authority:authoritative-venues:.*열거 붕괴'
  if printf '%s\n' "$output" | grep -q '^SCAN:'; then
    echo "붕괴 실행이 마커를 냈다: $output"; false
  fi
}
