#!/usr/bin/env bash
# Render (substitute the pinned arm64 helper image + the bulk node path) and apply the dual
# local-path provisioner + both StorageClasses to the cluster. Before wiring bulk-ssd, GATE on the
# external SSD actually being mounted + writable INSIDE the VM (Pass-5 Open Item #1), so bulk-ssd
# never silently lands on the VM disk and gets lost on a cattle rebuild.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
export KUBECONFIG="${KUBECONFIG_PATH:-$SCRIPT_DIR/kubeconfig}"
ORB_MACHINE="${ORB_MACHINE:-k3s}"

command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not on PATH." >&2; exit 2; }

# --- bulk-ssd backing-store gate (Pass-5 Open Item #1) -------------------------------------------
# bulk-ssd must live on the EXTERNAL SSD that OrbStack shares into the VM (virtiofs), never silently
# on the VM/internal disk (lost on a cattle rebuild). Two independent checks, both required:
#   (1) HOST-side (macOS `diskutil`): $BULK_EXTERNAL_HOST_PATH is on a physically EXTERNAL disk. A
#       virtiofs FSTYPE cannot tell the external SSD from the boot disk (the whole mac tree is one
#       virtiofs mount in the VM), so external-vs-internal is decided here, authoritatively.
#   (2) VM-side (bulk-gate-probe.sh via orb): the share resolves to virtiofs (findmnt -T) AND the
#       bulk path is writable from inside the VM as root.
# Escape hatch for a dev/inner-loop run without the SSD: BULK_ALLOW_VM_DISK=1 falls back to the VM
# disk (non-persistent across rebuild).
gate_fail() {
  {
    echo "FAIL: $1"
    echo "      This guards bulk-ssd from silently landing on the VM disk and being lost on rebuild (Pass-5 #1)."
    echo "      Fix: create the external 'homelab' APFS volume + grant OrbStack access — see docs/runbooks/external-ssd.md."
    echo "      Dev/inner-loop without the SSD: BULK_ALLOW_VM_DISK=1 $0"
  } >&2
  exit 1
}
if [ "${BULK_ALLOW_VM_DISK:-0}" = "1" ]; then
  echo "WARN: BULK_ALLOW_VM_DISK=1 — bulk-ssd uses the VM disk (${BULK_VM_DISK_FALLBACK}); data is LOST on a VM rebuild. Dev/inner-loop only." >&2
  BULK_STORAGE_PATH="$BULK_VM_DISK_FALLBACK"
else
  # (1) HOST-side external-device check.
  command -v diskutil >/dev/null 2>&1 || gate_fail "'diskutil' not on PATH — needed to confirm ${BULK_EXTERNAL_HOST_PATH} is an external disk (or set BULK_ALLOW_VM_DISK=1)."
  # `|| true`: under `set -e`+pipefail a missing path makes `diskutil` exit non-zero, which would
  # otherwise abort the script HERE (silently) instead of reaching the loud gate_fail below.
  loc="$(diskutil info "$BULK_EXTERNAL_HOST_PATH" 2>/dev/null | awk -F': *' '/Device Location/{print $2}' | tr -d '[:space:]' || true)"
  echo "==> Host check: ${BULK_EXTERNAL_HOST_PATH} Device Location = ${loc:-<none>}"
  [ "$loc" = "External" ] || gate_fail "${BULK_EXTERNAL_HOST_PATH} is not on an EXTERNAL disk (Device Location='${loc:-not mounted}'). Create the 'homelab' APFS volume on the external SSD — a bare dir on the internal disk does NOT count."
  # (2) VM-side virtiofs + writability probe (the real logic lives in bulk-gate-probe.sh).
  command -v orb >/dev/null 2>&1 || gate_fail "'orb' not on PATH — needed to verify the external bulk SSD from inside the VM (or set BULK_ALLOW_VM_DISK=1)."
  echo "==> VM check: probing ${BULK_EXTERNAL_MOUNT} (path ${BULK_STORAGE_PATH}) inside VM '${ORB_MACHINE}'…"
  orb -m "$ORB_MACHINE" -u root env \
        BULK_EXTERNAL_MOUNT="$BULK_EXTERNAL_MOUNT" BULK_STORAGE_PATH="$BULK_STORAGE_PATH" \
        sh -s < "$SCRIPT_DIR/bulk-gate-probe.sh" \
    || gate_fail "external bulk SSD not a writable virtiofs share at ${BULK_EXTERNAL_MOUNT} inside VM '${ORB_MACHINE}'."
  echo "==> External bulk SSD OK (external disk, virtiofs, writable)."
fi
export BULK_STORAGE_PATH

# LOCAL_PATH_HELPER_IMAGE + BULK_STORAGE_PATH are templated; restrict envsubst to those two vars so
# nothing else (e.g. $VOL_DIR inside the setup script) gets clobbered.
render() {
  if command -v envsubst >/dev/null 2>&1; then
    # envsubst's SHELL-FORMAT arg is a literal list of ${VAR} names — single quotes are required.
    # shellcheck disable=SC2016
    envsubst '${LOCAL_PATH_HELPER_IMAGE} ${BULK_STORAGE_PATH}' < "$1"
  else
    sed -e "s#\${LOCAL_PATH_HELPER_IMAGE}#${LOCAL_PATH_HELPER_IMAGE}#g" \
        -e "s#\${BULK_STORAGE_PATH}#${BULK_STORAGE_PATH}#g" "$1"
  fi
}

echo "==> Applying local-path provisioner (helper image: ${LOCAL_PATH_HELPER_IMAGE}; bulk path: ${BULK_STORAGE_PATH})…"
render "$SCRIPT_DIR/storage/local-path-provisioner.yaml" | kubectl apply -f -

echo "==> Applying StorageClasses…"
kubectl apply -f "$SCRIPT_DIR/storage/storageclass-standard.yaml"
kubectl apply -f "$SCRIPT_DIR/storage/storageclass-bulk-ssd.yaml"

echo "==> Storage applied. Verify with: kubectl get sc"
