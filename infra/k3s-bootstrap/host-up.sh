#!/usr/bin/env bash
# Idempotent host-substrate orchestrator: bring up the ONE OrbStack VM, install
# k3s with the exact flags, apply storage, then assert the single-machine rule.
# Each step is individually idempotent, so re-running host-up.sh is safe (cattle).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${HOSTUP_BINDIR:-$SCRIPT_DIR}"

echo "===> [1/4] OrbStack VM"
"$BIN/orb-create.sh"
echo "===> [2/4] k3s install + kubeconfig"
"$BIN/k3s-install.sh"
echo "===> [3/4] StorageClasses"
"$BIN/apply-storage.sh"
echo "===> [4/4] R3 single-machine health check"
"$BIN/orb-guard.sh"

echo "===> Host substrate is up. Next: export KUBECONFIG=$SCRIPT_DIR/kubeconfig"
