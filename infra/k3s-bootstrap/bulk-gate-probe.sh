#!/usr/bin/env sh
# In-VM half of the bulk-ssd backing-store gate (Pass-5 Open Item #1). apply-storage.sh pipes this
# into the k3s VM as root (`orb -m k3s -u root env … sh -s < bulk-gate-probe.sh`); it is also run
# DIRECTLY by test/08-bulk-gate.bats so the real findmnt/sentinel logic is actually exercised.
#
# It confirms the bulk path is on the OrbStack macOS virtiofs share and is WRITABLE from inside the
# VM (mirrors the local-path helper pod's root identity). It does NOT decide external-vs-internal —
# under OrbStack the whole mac tree is ONE virtiofs mount, so a virtiofs FSTYPE cannot tell the
# external SSD from the boot disk; that discrimination is done HOST-side by apply-storage.sh via
# macOS `diskutil` (Device Location: External).
#
# Inputs (env): BULK_EXTERNAL_MOUNT, BULK_STORAGE_PATH.
set -eu
: "${BULK_EXTERNAL_MOUNT:?BULK_EXTERNAL_MOUNT unset}"
: "${BULK_STORAGE_PATH:?BULK_STORAGE_PATH unset}"

# findmnt MUST use -T: under OrbStack a subdirectory of the mac share is not its own mountpoint, so a
# plain `findmnt <subdir>` prints nothing and exits 1. -T resolves to the containing mount.
fstype="$(findmnt -no FSTYPE -T "$BULK_EXTERNAL_MOUNT" 2>/dev/null || true)"
[ -n "$fstype" ] || { echo "not resolvable to a mount: $BULK_EXTERNAL_MOUNT" >&2; exit 11; }
[ "$fstype" = virtiofs ] || { echo "not the OrbStack mac share (fstype=$fstype): $BULK_EXTERNAL_MOUNT" >&2; exit 12; }

mkdir -p "$BULK_STORAGE_PATH" || { echo "mkdir failed: $BULK_STORAGE_PATH" >&2; exit 13; }
s="$BULK_STORAGE_PATH/.k3s-bulk-sentinel.$$"
if echo homelab-bulk-ok > "$s" 2>/dev/null && grep -q homelab-bulk-ok "$s" 2>/dev/null; then
  rm -f "$s"
else
  rm -f "$s" 2>/dev/null || true
  echo "read/write failed: $BULK_STORAGE_PATH" >&2
  exit 14
fi
echo external-bulk-probe-ok
