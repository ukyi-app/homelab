#!/usr/bin/env bats
load test_helper

setup() {
  WORK="$(mktemp -d)"; ORDER="$WORK/order.log"; export WORK ORDER
  # Shadow the real sub-scripts with order-logging stubs via HOSTUP_BINDIR.
  mkdir -p "$WORK/bin"
  for s in orb-create.sh k3s-install.sh apply-storage.sh orb-guard.sh; do
    cat >"$WORK/bin/$s" <<EOF
#!/usr/bin/env bash
echo "$s" >> "$ORDER"; exit 0
EOF
    chmod +x "$WORK/bin/$s"
  done
  export HOSTUP_BINDIR="$WORK/bin"
}
teardown() { rm -rf "$WORK"; }

@test "runs sub-steps in order: create, install, storage, guard" {
  run "$BOOTSTRAP_DIR/host-up.sh"
  [ "$status" -eq 0 ]
  run cat "$ORDER"
  [ "${lines[0]}" = "orb-create.sh" ]
  [ "${lines[1]}" = "k3s-install.sh" ]
  [ "${lines[2]}" = "apply-storage.sh" ]
  [ "${lines[3]}" = "orb-guard.sh" ]
}
