#!/usr/bin/env bash
# Install k3s single-node into the OrbStack VM with the EXACT homelab flag set,
# then retrieve a usable kubeconfig to a gitignored path on the macOS host.
#
# Modes:
#   (default)            run the install inside the VM, fetch kubeconfig.
#   K3S_PRINT_EXEC=1     print INSTALL_K3S_EXEC and exit (offline flag-contract test).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
ORB_MACHINE="${ORB_MACHINE:-k3s}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$SCRIPT_DIR/kubeconfig}"

# --- The flag contract (single source of truth) ---------------------------------
# servicelb is KEPT (absent from --disable). SQLite/kine is the default datastore
# (no --cluster-init, so we do NOT get embedded etcd). secrets-encryption on from
# day one. Node-protection reserves + eviction so a runaway pod can't OOM kubelet.
INSTALL_K3S_EXEC="server \
--disable=traefik,local-storage,metrics-server \
--disable-helm-controller \
--flannel-backend=vxlan \
--kube-reserved=cpu=250m,memory=512Mi \
--system-reserved=cpu=250m,memory=512Mi \
--eviction-hard=memory.available<250Mi,nodefs.available<10% \
--image-gc-high-threshold=80 \
--image-gc-low-threshold=70 \
--secrets-encryption \
--write-kubeconfig-mode=0644 \
--default-local-storage-path=${INTERNAL_STORAGE_PATH}"

if [ "${K3S_PRINT_EXEC:-0}" = "1" ]; then
  printf '%s\n' "$INSTALL_K3S_EXEC"
  exit 0
fi

command -v orb >/dev/null 2>&1 || { echo "FAIL: 'orb' not on PATH." >&2; exit 2; }

echo "==> Installing k3s ${K3S_VERSION} into VM '${ORB_MACHINE}'…"
# Run the official installer INSIDE the VM as root, pinned to K3S_VERSION.
orb -m "$ORB_MACHINE" -u root bash -c "\
  set -euo pipefail; \
  export INSTALL_K3S_VERSION='${K3S_VERSION}'; \
  export INSTALL_K3S_EXEC=\"${INSTALL_K3S_EXEC}\"; \
  curl -sfL https://get.k3s.io | sh -s -"

echo "==> Waiting for k3s API to come up…"
orb -m "$ORB_MACHINE" -u root bash -c "\
  for i in \$(seq 1 60); do \
    k3s kubectl get --raw=/readyz >/dev/null 2>&1 && exit 0; sleep 2; \
  done; echo 'k3s API did not become ready' >&2; exit 1"

echo "==> Retrieving kubeconfig to ${KUBECONFIG_PATH} (gitignored)…"
# The in-VM kubeconfig points at 127.0.0.1; rewrite to the VM's OrbStack DNS name
# so it is reachable from macOS. k3s.orb.local resolves to the VM (OrbStack DNS).
orb -m "$ORB_MACHINE" -u root cat /etc/rancher/k3s/k3s.yaml \
  | sed 's#https://127.0.0.1:6443#https://k3s.orb.local:6443#' \
  > "$KUBECONFIG_PATH"
chmod 0600 "$KUBECONFIG_PATH"

echo "==> k3s installed. Use: export KUBECONFIG=${KUBECONFIG_PATH}"
