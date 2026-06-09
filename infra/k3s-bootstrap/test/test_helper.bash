#!/usr/bin/env bash
# Shared bats helper. Resolves the bootstrap dir relative to this file.
BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BOOTSTRAP_DIR

# Name of the single OrbStack machine this whole milestone manages (R3).
export ORB_MACHINE="${ORB_MACHINE:-k3s}"
# Gitignored kubeconfig location (Task 1.6 writes here).
export KUBECONFIG_PATH="${KUBECONFIG_PATH:-$BOOTSTRAP_DIR/kubeconfig}"
