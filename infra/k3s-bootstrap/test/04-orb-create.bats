#!/usr/bin/env bats
load test_helper

setup() {
  STUBDIR="$(mktemp -d)"; CALLS="$STUBDIR/calls.log"
  PATH="$STUBDIR:$PATH"; export PATH STUBDIR CALLS
  cat >"$STUBDIR/orb" <<'EOF'
#!/usr/bin/env bash
echo "orb $*" >>"$CALLS"
case "$1" in
  list)   cat "${ORB_LIST_FIXTURE:-/dev/null}" ;;  # empty by default = no machines
  config) exit 0 ;;
  create) exit 0 ;;
  *)      exit 0 ;;
esac
EOF
  chmod +x "$STUBDIR/orb"
}
teardown() { rm -rf "$STUBDIR"; }

@test "creates a debian bookworm machine named k3s with cloud-init when none exists" {
  run "$BOOTSTRAP_DIR/orb-create.sh"
  [ "$status" -eq 0 ]
  grep -q 'orb create' "$CALLS"
  grep -q 'debian:bookworm' "$CALLS"
  grep -q -- '-c .*cloud-init.yaml' "$CALLS"
  grep -qE 'orb create .* k3s' "$CALLS"
}

@test "sets the GLOBAL memory and cpu caps (11 GiB / 6 vCPU)" {
  run "$BOOTSTRAP_DIR/orb-create.sh"
  grep -q 'config set memory_mib 11264' "$CALLS"
  grep -q 'config set cpu 6' "$CALLS"
}

@test "is idempotent: does NOT create when k3s already exists" {
  FIX="$STUBDIR/fix"; printf 'NAME  STATE    DISTRO\nk3s   running  debian\n' >"$FIX"
  ORB_LIST_FIXTURE="$FIX" run "$BOOTSTRAP_DIR/orb-create.sh"
  [ "$status" -eq 0 ]
  run grep -c 'orb create' "$CALLS"
  [ "$output" -eq 0 ]
}
