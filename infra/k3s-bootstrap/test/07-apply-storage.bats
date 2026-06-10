#!/usr/bin/env bats
load test_helper

setup() {
  STUBDIR="$(mktemp -d)"; RENDERED="$STUBDIR/rendered.yaml"
  PATH="$STUBDIR:$PATH"; export PATH STUBDIR RENDERED
  source "$BOOTSTRAP_DIR/versions.env"
  cat >"$STUBDIR/kubectl" <<'EOF'
#!/usr/bin/env bash
# Accumulate every applied manifest into $RENDERED, whether piped via '-f -' or
# read from '-f <file>', so assertions see the full applied set (StorageClass
# applies use files, not stdin, and must not clobber the piped provisioner).
if [ "$1" = "apply" ]; then
  src=""
  while [ $# -gt 0 ]; do
    if [ "$1" = "-f" ]; then src="$2"; shift; fi
    shift
  done
  if [ "$src" = "-" ] || [ -z "$src" ]; then
    cat >> "$RENDERED"
  else
    cat "$src" >> "$RENDERED"
  fi
fi
exit 0
EOF
  chmod +x "$STUBDIR/kubectl"
  # Stub the gate's host-side `diskutil` check (External by default).
  # DISKUTIL_STUB_INTERNAL=1 simulates /Volumes/homelab being a bare dir on the INTERNAL disk.
  cat >"$STUBDIR/diskutil" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "info" ]; then
  if [ "${DISKUTIL_STUB_INTERNAL:-0}" = "1" ]; then echo "   Device Location:           Internal"
  else echo "   Device Location:           External"; fi
fi
exit 0
EOF
  chmod +x "$STUBDIR/diskutil"
  # Stub the gate's VM-side `orb` probe so the suite is hermetic (no real VM). The probe is piped on
  # stdin (orb … sh -s < bulk-gate-probe.sh); the real probe logic is covered by 08-bulk-gate.bats.
  # ORB_STUB_FAIL=1 simulates a non-virtiofs/unwritable external SSD inside the VM.
  cat >"$STUBDIR/orb" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true                 # consume the piped probe script
[ "${ORB_STUB_FAIL:-0}" = "1" ] && { echo "stub: external bulk not available" >&2; exit 11; }
exit 0
EOF
  chmod +x "$STUBDIR/orb"
  export KUBECONFIG_PATH="$STUBDIR/kubeconfig"; : > "$KUBECONFIG_PATH"
}
teardown() { rm -rf "$STUBDIR"; }

@test "renders manifests with the helper image substituted (no literal placeholder)" {
  run "$BOOTSTRAP_DIR/apply-storage.sh"
  [ "$status" -eq 0 ]
  run grep -F '${LOCAL_PATH_HELPER_IMAGE}' "$RENDERED"
  [ "$status" -ne 0 ]                          # placeholder must be gone
  run grep -F "$LOCAL_PATH_HELPER_IMAGE" "$RENDERED"
  [ "$status" -eq 0 ]                          # real digest present
}

@test "applies both StorageClasses" {
  run "$BOOTSTRAP_DIR/apply-storage.sh"
  grep -q 'name: standard' "$RENDERED"
  grep -q 'name: bulk-ssd' "$RENDERED"
}

@test "renders the external-SSD bulk path into the provisioner (no literal placeholder)" {
  run "$BOOTSTRAP_DIR/apply-storage.sh"
  [ "$status" -eq 0 ]
  run grep -F '${BULK_STORAGE_PATH}' "$RENDERED"
  [ "$status" -ne 0 ]                          # placeholder substituted
  run grep -F "$BULK_STORAGE_PATH" "$RENDERED" # the real external path is present
  [ "$status" -eq 0 ]
}

@test "aborts when the host volume is on an INTERNAL disk (diskutil external-device check)" {
  # This is the check that a virtiofs FSTYPE alone CANNOT make: a bare /Volumes/homelab dir on the
  # internal disk would otherwise pass and land bulk on the VM disk.
  DISKUTIL_STUB_INTERNAL=1 run "$BOOTSTRAP_DIR/apply-storage.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not on an EXTERNAL disk"* ]]
  [ ! -s "$RENDERED" ]
}

@test "aborts when the VM-side probe fails (no silent VM-disk fallback)" {
  ORB_STUB_FAIL=1 run "$BOOTSTRAP_DIR/apply-storage.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"external bulk SSD"* ]]
  [ ! -s "$RENDERED" ]                          # gate runs before any apply — nothing rendered
}

@test "BULK_ALLOW_VM_DISK=1 skips the gate and renders the VM-disk fallback path" {
  ORB_STUB_FAIL=1 BULK_ALLOW_VM_DISK=1 run "$BOOTSTRAP_DIR/apply-storage.sh"
  [ "$status" -eq 0 ]                           # gate skipped despite a failing orb stub
  run grep -F "$BULK_VM_DISK_FALLBACK" "$RENDERED"
  [ "$status" -eq 0 ]                           # fallback path rendered into the bulk provisioner
}
