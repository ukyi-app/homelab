#!/usr/bin/env bats
load test_helper

setup() {
  STUBDIR="$(mktemp -d)"
  PATH="$STUBDIR:$PATH"
  export PATH STUBDIR
}
teardown() { rm -rf "$STUBDIR"; }

# Build a fake `orb` whose `list` output we control.
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
