#!/usr/bin/env bash
# Render (substitute the pinned arm64 helper image) and apply the dual
# local-path provisioner + both StorageClasses to the cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
export KUBECONFIG="${KUBECONFIG_PATH:-$SCRIPT_DIR/kubeconfig}"

command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not on PATH." >&2; exit 2; }

# Only LOCAL_PATH_HELPER_IMAGE is templated; restrict envsubst to that one var so
# nothing else (e.g. $VOL_DIR inside the setup script) gets clobbered.
render() {
  if command -v envsubst >/dev/null 2>&1; then
    envsubst '${LOCAL_PATH_HELPER_IMAGE}' < "$1"
  else
    sed "s#\${LOCAL_PATH_HELPER_IMAGE}#${LOCAL_PATH_HELPER_IMAGE}#g" "$1"
  fi
}

echo "==> Applying local-path provisioner (helper image: ${LOCAL_PATH_HELPER_IMAGE})…"
render "$SCRIPT_DIR/storage/local-path-provisioner.yaml" | kubectl apply -f -

echo "==> Applying StorageClasses…"
kubectl apply -f "$SCRIPT_DIR/storage/storageclass-standard.yaml"
kubectl apply -f "$SCRIPT_DIR/storage/storageclass-bulk-ssd.yaml"

echo "==> Storage applied. Verify with: kubectl get sc"
