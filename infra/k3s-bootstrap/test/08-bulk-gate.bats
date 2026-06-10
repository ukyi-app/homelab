#!/usr/bin/env bats
# Exercises the REAL in-VM bulk gate logic (bulk-gate-probe.sh) directly — no orb, no VM — so the
# findmnt/sentinel behaviour is actually covered (Pass-5 #1 adversarial-review fix). The fake
# `findmnt` mimics OrbStack's real behaviour: a subdir of the mac share is NOT its own mountpoint,
# so it resolves ONLY with `-T`. A probe that forgot `-T` would therefore fail this suite.
load test_helper

PROBE="$BOOTSTRAP_DIR/bulk-gate-probe.sh"

setup() {
  STUBDIR="$(mktemp -d)"; WORK="$(mktemp -d)"
  PATH="$STUBDIR:$PATH"; export PATH STUBDIR WORK
  cat >"$STUBDIR/findmnt" <<'EOF'
#!/usr/bin/env sh
# Real OrbStack: `findmnt <subdir>` prints nothing / exits 1; only `findmnt -T <subdir>` resolves.
[ "${FINDMNT_NORESOLVE:-0}" = "1" ] && exit 1
hasT=0; for a in "$@"; do [ "$a" = "-T" ] && hasT=1; done
[ "$hasT" = "1" ] || exit 1
echo "${FINDMNT_FSTYPE:-virtiofs}"
EOF
  chmod +x "$STUBDIR/findmnt"
}
teardown() { rm -rf "$STUBDIR" "$WORK"; }

@test "passes on a writable virtiofs share (and thereby proves the probe uses findmnt -T)" {
  BULK_EXTERNAL_MOUNT="/mnt/mac/Volumes/homelab" BULK_STORAGE_PATH="$WORK/bulk" run sh "$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"external-bulk-probe-ok"* ]]
  [ -d "$WORK/bulk" ]                       # the base dir was created
  [ -z "$(ls -A "$WORK/bulk")" ]            # the sentinel was cleaned up
}

@test "exit 11 when the mount cannot be resolved (fails closed)" {
  FINDMNT_NORESOLVE=1 BULK_EXTERNAL_MOUNT="/mnt/mac/Volumes/homelab" BULK_STORAGE_PATH="$WORK/bulk" run sh "$PROBE"
  [ "$status" -eq 11 ]
}

@test "exit 12 when the share is not virtiofs (e.g. an ext4 VM-disk path)" {
  FINDMNT_FSTYPE=ext4 BULK_EXTERNAL_MOUNT="/var/lib/rancher/k3s-storage/bulk" BULK_STORAGE_PATH="$WORK/bulk" run sh "$PROBE"
  [ "$status" -eq 12 ]
}

@test "exit 13 when the bulk path cannot be created (unwritable parent)" {
  ro="$WORK/ro"; mkdir -p "$ro"; chmod 555 "$ro"
  BULK_EXTERNAL_MOUNT="/mnt/mac/Volumes/homelab" BULK_STORAGE_PATH="$ro/bulk" run sh "$PROBE"
  [ "$status" -eq 13 ]
  chmod 755 "$ro"
}

@test "errors when required env is missing" {
  run sh "$PROBE"
  [ "$status" -ne 0 ]
}
