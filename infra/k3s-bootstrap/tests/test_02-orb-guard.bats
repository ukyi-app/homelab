#!/usr/bin/env bats
load test_helper

setup() {
  STUBDIR="$(mktemp -d)"
  PATH="$STUBDIR:$PATH"
  export PATH STUBDIR
}
teardown() { rm -rf "$STUBDIR"; }

# `list` 출력을 우리가 제어하는 가짜 `orb`를 만든다.
_make_orb() {
  cat >"$STUBDIR/orb" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "list" ]; then printf '%s\n' "$1"; exit 0; fi
exit 0
EOF
  chmod +x "$STUBDIR/orb"
}

@test "passes when exactly one machine named k3s is running" {
  _make_orb $'NAME    STATE      DISTRO          ARCH\nk3s     running    debian bookworm arm64'
  run "$BOOTSTRAP_DIR/orb-guard.sh"
  [ "$status" -eq 0 ]
}

@test "fails when a second machine exists (global cap contention, R3)" {
  _make_orb $'NAME    STATE      DISTRO          ARCH\nk3s     running    debian bookworm arm64\nstray   running    ubuntu noble    arm64'
  run "$BOOTSTRAP_DIR/orb-guard.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one"* ]]
}

@test "fails when the k3s machine is not running" {
  _make_orb $'NAME    STATE      DISTRO          ARCH\nk3s     stopped    debian bookworm arm64'
  run "$BOOTSTRAP_DIR/orb-guard.sh"
  [ "$status" -ne 0 ]
}

@test "orb-guard runs under macOS bash 3.2 without bash-4 builtin errors" {
  # 라이브 회귀: orb-guard.sh가 mapfile(bash 4+)을 쓰면 macOS 기본 bash 3.2에서
  # 'command not found'로 make up이 exit 2가 된다. 시스템 bash가 3.2가 아니면(CI 등) 스킵.
  /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.2' || skip "system /bin/bash is not 3.2"
  _make_orb $'NAME    STATE      DISTRO          ARCH\nk3s     running    debian bookworm arm64'
  run /bin/bash "$BOOTSTRAP_DIR/orb-guard.sh"
  [ "$status" -eq 0 ]
}

@test "orb-guard avoids bash-4-only builtins (mapfile/readarray) for bash 3.2 portability" {
  # 포터블 가드(CI 포함): bootstrap 계층은 macOS 호스트(bash 3.2)에서 돌아야 한다.
  # 명령 위치 사용만 매칭한다(주석 멘션은 허용 — 원래 버그 `mapfile -t`는 줄 시작이라 잡힌다).
  run grep -nE '^[[:space:]]*(mapfile|readarray)([[:space:]]|$)' "$BOOTSTRAP_DIR/orb-guard.sh"
  [ "$status" -ne 0 ]
}
