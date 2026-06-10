#!/usr/bin/env bash
# Live cluster contract check for the host substrate (Milestone 1):
#   - node Ready
#   - both StorageClasses present (standard, bulk-ssd)
#   - DISABLED components absent (traefik controller, metrics-server)
#   - KEPT component: servicelb is NOT in the k3s --disable flag contract.
#     svclb pods are created on-demand ONLY when a LoadBalancer Service exists
#     (Traefik in M3), so ZERO svclb pods at M1 is CORRECT — we assert the FLAG
#     contract (the cluster is cattle-rebuilt from k3s-install.sh) instead of
#     pod presence.
#   - secrets-encryption ENABLED
# Designed to be re-run any time; exits non-zero on the first failed invariant.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
ORB_MACHINE="${ORB_MACHINE:-k3s}"
export KUBECONFIG="${KUBECONFIG_PATH:-$SCRIPT_DIR/kubeconfig}"
K3S_INSTALL_SCRIPT="${K3S_INSTALL_SCRIPT:-$SCRIPT_DIR/k3s-install.sh}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> [1] Node Ready?"
nodes="$(kubectl get nodes --no-headers 2>/dev/null || true)"
echo "$nodes" | grep -qw "Ready" || fail "node is not Ready"

echo "==> [2] StorageClasses present?"
sc="$(kubectl get sc --no-headers 2>/dev/null | awk '{print $1}')"
echo "$sc" | grep -qx "standard" || fail "StorageClass 'standard' missing"
echo "$sc" | grep -qx "bulk-ssd" || fail "StorageClass 'bulk-ssd' missing"

echo "==> [3] Disabled components absent? (traefik controller, metrics-server)"
pods="$(kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '{print $1}')"
# Match the controller Deployment pods precisely so the servicelb LB pod
# (svclb-traefik-*) is NOT mistaken for a traefik controller.
echo "$pods" | grep -qE '^traefik-' && fail "traefik controller pod present — must be disabled"
echo "$pods" | grep -qE '^metrics-server' && fail "metrics-server pod present — must be disabled"

echo "==> [4] servicelb KEPT (not in the k3s --disable flag contract)?"
exec_str="$(K3S_PRINT_EXEC=1 "$K3S_INSTALL_SCRIPT")"
case "$exec_str" in
  *servicelb*) fail "servicelb appears in the k3s flags — it must be KEPT, never disabled (it provides Traefik's node-IP LoadBalancer in M3)" ;;
esac

echo "==> [5] secrets-encryption enabled?"
enc="$(orb -m "$ORB_MACHINE" -u root k3s secrets-encrypt status 2>/dev/null || true)"
echo "$enc" | grep -qi "Enabled" || fail "secrets encryption is not Enabled"

echo "OK: host substrate verified (node Ready, both SCs, traefik/metrics-server absent, servicelb kept, secrets-encryption enabled)."
