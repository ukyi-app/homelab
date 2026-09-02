#!/usr/bin/env bats
# bash 3.2(macOS 기본) 전용 함정 가드 — **CI(bash 5.2)가 원리적으로 못 잡는 클래스**를 정적으로 막는다.
#
# 함정: `"$VAR한글"`처럼 `$VAR` 바로 뒤에 비-ASCII 바이트가 붙으면 bash 3.2는 그 바이트를 **변수명에
# 포함**시켜 `VAR<byte>: unbound variable`로 죽는다(`set -u`). bash 5.2는 정상 동작한다 — 즉 게이트는
# 초록인데 오너 머신에서만 터진다. 하필 이 패턴은 진단 메시지에 잘 쓰여서 **실패를 설명해야 하는 바로
# 그 경로에서** 스크립트가 죽는다(라이브 실측: bash 3.2.57 → `V<byte>: unbound variable` / 5.2 → 정상).
# 처방: `${VAR}한글`.
#
# ⚠️ 검출은 `LC_ALL=C grep -E '[^ -~]'`다. `grep -P`를 쓰면 **macOS BSD grep이 -P를 지원하지 않아**
#    이 가드가 조용히 0건을 찾는다(실측: 그 형태로 처음 썼더니 버그를 되돌려 넣어도 초록이었다).
#    `[^ -~]` = LC_ALL=C에서 출력 가능 ASCII 밖 바이트 → BSD·GNU 양쪽에서 동일하게 동작한다.
#
# ⚠️ 전체-줄 주석만 면제한다(행말 주석은 면제하지 않는다). 주석에서도 `${VAR}`로 쓰면 그만이고,
#    "코드인지 주석인지"를 셸로 정확히 가르려 들면 그 파서가 새 사각지대가 된다.
#
# @test 이름은 영어 — 디렉토리 단위 실행 시 한글 이름 인코딩이 깨진다(AGENTS.md 규약).

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT"; }

# 열거자는 한 곳이다 — 아래 바닥값이 **스캐너가 실제로 쓴** 열거를 재야 한다.
# 글롭 리터럴을 바닥값 줄에 다시 적으면 이 줄의 오타를 그 바닥값이 못 잡는다(실측).
list_sh() { git ls-files '*.sh'; }

scan_unbraced() {
  # 전 추적 *.sh에서 `$VAR<비-ASCII>` 를 찾는다. 전체-줄 주석은 건너뛴다. 출력 = 발견 줄 목록.
  list_sh | while IFS= read -r f; do
    LC_ALL=C command grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$f" 2>/dev/null | while IFS= read -r hit; do
      ln="${hit%%:*}"
      line="$(sed -n "${ln}p" "$f")"
      case "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')" in '#'*) continue ;; esac
      printf '%s:%s\n' "$f" "$hit"
    done
  done
}

@test "no tracked shell script interpolates a bare \$VAR immediately followed by a non-ASCII byte" {
  run scan_unbraced
  [ "$status" -eq 0 ]
  # 열거 붕괴 바닥값 — 글롭이 깨지면 이 전칭("no tracked shell script …")이 공허하게 참이 된다.
  # 이 가드는 CI(bash 5.2)가 원리적으로 못 잡는 클래스의 유일한 집행자라 공허가 곧 실명이다.
  [ "$(list_sh | grep -c .)" -ge 60 ]
  if [ -n "$output" ]; then
    echo "bash 3.2에서 죽는 보간 — \${VAR}로 감싸라 (CI는 bash 5.2라 초록이다):"
    printf '%s\n' "$output"
    false
  fi
}

@test "the scanner actually detects the pattern (mutation witness — a broken detector reads as clean)" {
  # 이 가드의 검출기가 실제로 무는지 픽스처로 증명한다. `grep -P`를 쓰던 첫 구현은 BSD grep에서
  # 아무것도 못 찾아 **버그를 되돌려 넣어도 초록**이었다 — 그 클래스를 여기서 막는다.
  fixture="$BATS_TEST_TMPDIR/bad.sh"
  printf '%s\n' '#!/bin/sh' 'V=7' 'echo "평가($V회)"' > "$fixture"
  run bash -c "LC_ALL=C command grep -cE '\\\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' '$fixture'"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  # 중괄호 형태는 잡히지 않아야 한다(오탐 없음).
  printf '%s\n' '#!/bin/sh' 'V=7' 'echo "평가(${V}회)"' > "$fixture"
  run bash -c "LC_ALL=C command grep -cE '\\\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' '$fixture'"
  [ "$output" = "0" ]
}

@test "the trap is real on bash 3.2 and absent on bash 5.x (why CI cannot catch it)" {
  run /bin/bash -c 'set -u; V=7; echo "평가($V회)"'
  if [ "$status" -eq 0 ]; then
    # bash 5.x — 이 인터프리터에선 함정이 재현되지 않는다(= CI가 못 잡는 이유).
    [ "$output" = "평가(7회)" ]
  else
    # bash 3.2 — 죽는다는 것이 증명됐다. 중괄호 형태는 반드시 살아야 한다.
    run /bin/bash -c 'set -u; V=7; echo "평가(${V}회)"'
    [ "$status" -eq 0 ]
    [ "$output" = "평가(7회)" ]
  fi
}
