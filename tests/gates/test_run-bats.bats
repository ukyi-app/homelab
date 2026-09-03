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

@test "run-bats.sh has executable bit (Makefile/CI invoke ./scripts/run-bats.sh directly)" {
  # Task 0.5가 make ci·ci.yaml에서 ./scripts/run-bats.sh 직접 호출 → exec 비트 없으면 깨진다.
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
  grep -vF 'bats --print-output-on-failure "${SELECTED[@]}"' "$ROOT/scripts/run-bats.sh" \
    | sed "s|^ROOT=.*|ROOT='$ROOT'|" > "$TMPD/runner.sh"
  run grep -cF 'bats --print-output-on-failure "${SELECTED[@]}"' "$TMPD/runner.sh"
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
