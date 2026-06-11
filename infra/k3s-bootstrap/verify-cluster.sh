#!/usr/bin/env bash
# 호스트 기반 계층의 라이브 클러스터 계약 검사 (Milestone 1):
#   - 노드 Ready
#   - 두 StorageClass 존재 (standard, bulk-ssd)
#   - 비활성화된 컴포넌트 부재 (traefik 컨트롤러, metrics-server)
#   - 유지 컴포넌트: servicelb는 k3s --disable 플래그 계약에 없어야 한다.
#     svclb pod는 LoadBalancer Service가 존재할 때만(M3의 Traefik) 온디맨드로
#     생성되므로, M1에서 svclb pod가 0개인 것이 정상이다 — pod 존재 대신
#     플래그 계약을 단언한다(클러스터는 k3s-install.sh로 cattle 재구축되는
#     대상이기 때문).
#   - secrets-encryption 활성화
# 언제든 재실행 가능하게 설계; 첫 번째 불변식 실패에서 non-zero로 종료한다.
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
# 컨트롤러 Deployment pod를 정확히 매칭해 servicelb LB pod(svclb-traefik-*)가
# traefik 컨트롤러로 오인되지 않게 한다.
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
