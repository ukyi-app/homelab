#!/usr/bin/env bats
# 단일 러너의 수집 집합 불변식. bash 3.2 함정 회피 — 단언은 grep 파이프/[ ]로.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "run-bats.sh lists every test_*.bats except .ci-exclude entries" {
  run bash "$ROOT/scripts/run-bats.sh" --list
  [ "$status" -eq 0 ]
  list="$output"   # run 재호출이 ${output}을 덮으므로 로컬에 보존
  # 포함: 일반 게이트 테스트
  echo "$list" | grep -q 'platform/argocd/root/test_render.bats'
  # 제외: .ci-exclude 멤버 (중간 negate는 침묵 통과 → run+status로 강제)
  run grep -q 'tests/posture/test_internal-by-default.bats' <<<"$list"
  [ "$status" -ne 0 ]
  run grep -q 'tools/tests/test_dev-postgres.bats' <<<"$list"
  [ "$status" -ne 0 ]
}

@test "run-bats.sh --list = all test_*.bats minus platform/charts minus .ci-exclude" {
  gate=$(git -C "$ROOT" ls-files '*test_*.bats' | grep -vE '^platform/charts/' | wc -l | tr -d ' ')
  excl=$(grep -vcE '^[[:space:]]*(#|$)' "$ROOT/tests/.ci-exclude")
  listed=$(bash "$ROOT/scripts/run-bats.sh" --list | grep -c '\.bats$')
  [ "$listed" -eq "$((gate - excl))" ]   # infra prune 없음 — CI-safe infra는 gate
}

@test "run-bats.sh runs under macOS default /bin/bash 3.2 (no mapfile/set -u)" {
  # AGENTS.md bash3.2 함정: 러너가 owner macOS의 /bin/bash로 반드시 동작해야 한다.
  run /bin/bash "$ROOT/scripts/run-bats.sh" --list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'test_.*\.bats'
}

@test "run-bats.sh has executable bit (justfile/CI invoke ./scripts/run-bats.sh directly)" {
  # just ci·ci.yaml이 ./scripts/run-bats.sh 직접 호출 → exec 비트 없으면 깨진다.
  [ -x "$ROOT/scripts/run-bats.sh" ]
}

# ── fd 0 격리 ────────────────────────────────────────────────────────────────────
# 러너는 자기 stdin을 끊는다. 끊지 않으면 @test 안의 스텁이 피연산자 없이 `cat`을 부를 때 그 `cat`이
# **러너를 부른 셸의 stdin**에서 EOF를 기다려 스위트가 통째로 멈춘다 — red가 아니라 hang이라
# 관측되는 것이 아무것도 없다(실측 2026-08-20: 1시간 39분). 전문은
# docs/traps-detail.md 「bats는 stdin을 만지지 않는다 …」가 SSOT.
# ⚠️ CI가 이걸 안 밟는 것은 러너의 성질이 아니라 ci.yaml이 러너를 `&`로 띄우기 때문이다. 즉 이 결함은
#    **로컬만 밟고 CI는 영원히 초록**이므로, 러너 자신이 지키지 않으면 아무도 안 지킨다.

@test "the runner detaches fd 0 before invoking bats" {
  run grep -qF 'exec 0</dev/null' "$ROOT/scripts/run-bats.sh"
  [ "$status" -eq 0 ]
}

@test "the fd 0 detachment actually takes effect (the runner's stdin becomes /dev/null)" {
  # ★ 행동 증인 — 정적 grep은 리터럴이 옮겨지거나 조건 뒤로 숨으면 조용히 무력해진다. 러너의
  #   프리앰블을 **바이트 그대로** 실행하고 그 시점의 fd 0이 무엇인지 직접 읽는다.
  # ⚠️ 안쪽에서 bats를 부르지 않는다 — 중첩 bats는 BATS_RUN_TMPDIR을 상속해 **바깥** 스위트의
  #    임시 디렉토리를 정리해버린다(실측 2026-08-20: bats-exec-file이 자기 .out 파일을 잃었다).
  # ⚠️ /proc 의존 — 이 게이트가 도는 venue(NUC·GHA ubuntu)는 둘 다 리눅스다.
  TMPD="$(mktemp -d)"
  # ⚠️ 사본이 $TMPD에 있으면 러너가 `dirname/..`로 계산하는 ROOT가 /tmp가 되어 tests/.ci-exclude를
  #    못 찾는다. ROOT만 실 레포로 고정한다 — fd 0 격리 줄은 바이트 그대로 남는다(그게 피시험 대상이다).
  # 실행 줄(`# run-bats:exec` 표식 3줄 — 두 레인 호출 + exit)만 잘라낸다. run_lane 함수 정의는 남지만 호출이 없다.
  grep -vF '# run-bats:exec' "$ROOT/scripts/run-bats.sh" \
    | sed "s|^ROOT=.*|ROOT='$ROOT'|" > "$TMPD/runner.sh"
  run grep -cF '# run-bats:exec' "$TMPD/runner.sh"
  [ "$output" -eq 0 ]
  printf 'readlink /proc/self/fd/0\n' >> "$TMPD/runner.sh"

  # never-EOF stdin을 물려도 프리앰블 통과 후 fd 0은 /dev/null이어야 한다.
  # ⚠️ `sleep`은 짧게 잡고 stdout을 반드시 끊는다. 러너는 1초 안에 끝나므로 15초면 never-EOF로
  #    충분하고, 더 길게 잡으면 고아가 된 `sleep`이 bats 자신의 종료를 그만큼 붙든다(실측).
  #    stdout을 끊는 이유: 프로세스 치환의 자식은 부모의 stdout(=`run`의 커맨드 치환
  #    파이프)을 상속하므로, 끊지 않으면 러너가 끝나도 그 파이프에 EOF가 오지 않아 `run` 자신이
  #    그 시간만큼 블록한다 — 이 파일이 막으려는 것과 정확히 같은 모양의 hang이다(실측).
  run bash -c "cd '$ROOT' && bash '$TMPD/runner.sh' < <(sleep 15 >/dev/null 2>&1)"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF '/dev/null'

  # 음성 대조 — 격리를 지운 사본은 호출자의 stdin을 그대로 물려받는다. 이게 없으면 위 단언은
  # "어차피 /dev/null이었다"와 구별되지 않는다.
  grep -vF 'exec 0</dev/null' "$TMPD/runner.sh" > "$TMPD/runner-nofd0.sh"
  run bash -c "cd '$ROOT' && bash '$TMPD/runner-nofd0.sh' < <(sleep 15 >/dev/null 2>&1)"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s' \"$output\" | grep -c '/dev/null' || true"
  [ "$output" -eq 0 ]
  rm -rf "$TMPD"
}

@test "the runner does NOT set a per-test timeout (it false-times-out failing nested bats)" {
  # ⚠️ 되돌리고 싶어지는 자리라 명시적으로 문다. `BATS_TEST_TIMEOUT`이 설정돼 있으면 **실패하는**
  #   중첩 bats를 부르는 @test가 타임아웃을 꽉 채우고 red가 된다(실측 2026-08-20:
  #   test_guard-skip-signalling.bats의 "reports failure (not skip)…"가 백스톱 없이는 0초 통과,
  #   BATS_TEST_TIMEOUT=40이면 40초 후 red). 이 레포는 fail-closed를 단언하는 게이트가 다수다.
  run grep -c 'export BATS_TEST_TIMEOUT' "$ROOT/scripts/run-bats.sh"
  [ "$output" -eq 0 ]
  # 근거가 코드에 남아 있어야 다음 사람이 같은 곳을 다시 밟지 않는다.
  run grep -qF '양립 불가' "$ROOT/scripts/run-bats.sh"
  [ "$status" -eq 0 ]
}

# ── 레인 분할(병렬 레인 + tests/.gate-serial 직렬 레인) ────────────────────────────────────────────
# 러너는 수집 집합을 파일 단위 병렬 레인과 직렬 레인으로 나눈다. 직렬 레인은 실 체크아웃을 잠깐 바꾸는
# 스위트만 담고, 병렬 레인이 끝난 뒤 혼자 돈다(전문: docs/traps-detail.md 「파일 단위 병렬 bats에서 …」).

@test "--list is unchanged by the serial lane (the lane is scheduling, not a domain)" {
  list="$(bash "$ROOT/scripts/run-bats.sh" --list)"
  n=0
  while IFS= read -r f; do
    case "$f" in ''|\#*) continue;; esac
    n=$((n + 1))
    grep -qFx -- "$f" <<<"$list"
  done < "$ROOT/tests/.gate-serial"
  # 레지스트리가 비면 위 루프는 공허하다 — 그래서 등재 수를 러너의 --plan 보고와 등식으로 묶는다(0이면 0).
  plan_ser="$(bash "$ROOT/scripts/run-bats.sh" --plan | sed -n 's/^serial=//p')"
  [ "$n" -eq "$plan_ser" ]
}

@test "--plan splits the collected set into the two lanes and names every serial file" {
  run bash "$ROOT/scripts/run-bats.sh" --plan
  [ "$status" -eq 0 ]
  plan="$output"
  par="$(sed -n 's/^parallel=//p' <<<"$plan")"
  ser="$(sed -n 's/^serial=//p' <<<"$plan")"
  listed="$(bash "$ROOT/scripts/run-bats.sh" --list | grep -c '\.bats$')"
  [ "$((par + ser))" -eq "$listed" ]
  reg="$(grep -vcE '^[[:space:]]*(#|$)' "$ROOT/tests/.gate-serial" || true)"   # 0건이면 grep -c가 rc 1 — 0은 정당한 값
  [ "$ser" -eq "$reg" ]
  [ "$(grep -c '^serial-file=' <<<"$plan")" -eq "$reg" ]
}

@test "a serial-lane entry outside the collected set fails loud instead of silently emptying the lane" {
  # 러너 사본의 레지스트리 경로만 픽스처로 바꾼다(ROOT는 실 레포 — .ci-exclude 수집은 그대로).
  TMPD="$(mktemp -d)"
  printf '# 사유\ntests/gates/test_no-such-file.bats\n' > "$TMPD/serial"
  sed -e "s|^ROOT=.*|ROOT='$ROOT'|" -e "s|tests/.gate-serial|$TMPD/serial|g" "$ROOT/scripts/run-bats.sh" > "$TMPD/runner.sh"
  run bash "$TMPD/runner.sh" --list
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF '수집 집합에 없다'
  rm -rf "$TMPD"
}

@test "RUNBATS_JOBS must be a positive integer, and 1 selects the serial form for both lanes" {
  run env RUNBATS_JOBS=abc bash "$ROOT/scripts/run-bats.sh" --plan
  [ "$status" -eq 2 ]
  run env RUNBATS_JOBS=0 bash "$ROOT/scripts/run-bats.sh" --plan
  [ "$status" -eq 2 ]
  run env RUNBATS_JOBS=1 bash "$ROOT/scripts/run-bats.sh" --plan
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qx 'jobs=1'
}

@test "the parallel lane pairs --jobs with --no-parallelize-within-files and the runner detaches the GHA step-output files" {
  # 정적 증인 — 파일 안 직렬을 빼고 --jobs만 남기면 setup_file/순서 의존 스위트가 조용히 뒤섞인다.
  run grep -cF 'bats --jobs "$lane_jobs" --no-parallelize-within-files --print-output-on-failure "$@"' "$ROOT/scripts/run-bats.sh"
  [ "$output" -eq 1 ]
  # 병렬 프로세스들이 스텝당 하나뿐인 $GITHUB_OUTPUT에 끼어 쓰지 못하게 러너가 넷을 끊는다.
  run grep -cF 'unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY GITHUB_ENV GITHUB_PATH' "$ROOT/scripts/run-bats.sh"
  [ "$output" -eq 1 ]
}
