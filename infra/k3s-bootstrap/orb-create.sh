#!/usr/bin/env bash
# Create THE single OrbStack VM that hosts k3s. Idempotent: a second run is a no-op
# if the machine already exists. The memory/cpu caps are GLOBAL to OrbStack (R3),
# so we set them unconditionally to the budgeted ceiling (§9/§10).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
ORB_MACHINE="${ORB_MACHINE:-k3s}"
CLOUD_INIT="$SCRIPT_DIR/cloud-init.yaml"

command -v orb >/dev/null 2>&1 || { echo "FAIL: 'orb' not on PATH (install OrbStack)." >&2; exit 2; }
[ -f "$CLOUD_INIT" ] || { echo "FAIL: missing $CLOUD_INIT" >&2; exit 2; }

# Global OrbStack caps — the ceiling, not a reservation (OrbStack returns idle RAM).
echo "==> Setting global OrbStack caps: ${ORB_MEMORY_MIB} MiB / ${ORB_CPU} vCPU"
orb config set memory_mib "$ORB_MEMORY_MIB"
orb config set cpu "$ORB_CPU"

if orb list 2>/dev/null | awk 'NF && $1 != "NAME" {print $1}' | grep -qx "$ORB_MACHINE"; then
  echo "==> Machine '${ORB_MACHINE}' already exists — skipping create (idempotent)."
else
  echo "==> Creating Debian ${DEBIAN_RELEASE} ${DEBIAN_ARCH} machine '${ORB_MACHINE}'…"
  # OrbStack on Apple Silicon defaults to arm64; we name the distro explicitly.
  orb create "debian:${DEBIAN_RELEASE}" "$ORB_MACHINE" -c "$CLOUD_INIT"
fi

# Make k3s the default machine so `orb -m` is optional but explicit elsewhere.
orb default "$ORB_MACHINE" >/dev/null 2>&1 || true
echo "==> Done. Verify with: infra/k3s-bootstrap/orb-guard.sh"
