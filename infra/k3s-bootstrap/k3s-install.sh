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
# NOTE: kube-reserved/system-reserved/eviction-hard/image-gc-* are KUBELET flags,
# so they MUST be passed via --kubelet-arg= (k3s server rejects them as bare flags).
INSTALL_K3S_EXEC="server \
--disable=traefik,local-storage,metrics-server \
--disable-helm-controller \
--flannel-backend=vxlan \
--kubelet-arg=kube-reserved=cpu=250m,memory=512Mi \
--kubelet-arg=system-reserved=cpu=250m,memory=512Mi \
--kubelet-arg=eviction-hard=memory.available<250Mi,nodefs.available<10% \
--kubelet-arg=image-gc-high-threshold=80 \
--kubelet-arg=image-gc-low-threshold=70 \
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
# OrbStack auto-forwards the VM's listening :6443 to the host's 127.0.0.1:6443, and
# the k3s serving cert lists 127.0.0.1 as a SAN — so the in-VM kubeconfig (already
# pointing at https://127.0.0.1:6443) is directly usable from macOS as-is. No DNS
# rewrite (there is no k3s.orb.local in OrbStack 2.x, and it is not a cert SAN).
orb -m "$ORB_MACHINE" -u root cat /etc/rancher/k3s/k3s.yaml > "$KUBECONFIG_PATH"
chmod 0600 "$KUBECONFIG_PATH"

echo "==> k3s installed. Use: export KUBECONFIG=${KUBECONFIG_PATH}"
