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
export KUBECONFIG="${KUBECONFIG_PATH:-$SCRIPT_DIR/kubeconfig}"
K3S_INSTALL_SCRIPT="${K3S_INSTALL_SCRIPT:-$SCRIPT_DIR/k3s-install.sh}"
# 노드 명령 시임 — 베어메탈에서는 **여기가 곧 노드**라 로컬 sudo다(OrbStack 시절의
# `orb -m <machine> -u root` 간접이 사라진다). 테스트는 스텁을 꽂는다.
K3S_RUN="${K3S_RUN:-sudo}"

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
enc="$($K3S_RUN k3s secrets-encrypt status 2>/dev/null || true)"
echo "$enc" | grep -qi "Enabled" || fail "secrets encryption is not Enabled"

echo "==> [6] k3s version pinned to versions.env (K3S_VERSION)?"
kver="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || true)"
[ "$kver" = "$K3S_VERSION" ] || fail "k3s version drift: live '${kver:-<none>}' != pinned '$K3S_VERSION' (versions.env)"

echo "==> [7] node InternalIP matches the pin (netpol node-subnet allows depend on it)?"
nip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
[ "$nip" = "$K3S_NODE_IP" ] || fail "node InternalIP drift: live '${nip:-<none>}' != pinned '$K3S_NODE_IP' (versions.env). platform/**의 노드 서브넷 allow 6곳이 이 값의 /24를 전제한다."

echo "==> [8] apiserver serving cert carries every pinned SAN?"
# ⚠️ 이 검사가 **라이브 cert**를 본다는 점이 핵심이다. 스크립트가 방출하는 플래그 문자열을 grep하면
#    "스크립트가 그 플래그를 낼 것이다"만 증명되고 "라이브 서버가 그 플래그로 설치됐다"는 전혀
#    증명되지 않는다 — `--tls-san`은 설치 시점에만 정해지므로 그 구분이 곧 이 게이트의 값이다.
cert_sans="$($K3S_RUN openssl x509 -in /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt \
             -noout -ext subjectAltName 2>/dev/null || true)"
[ -n "$cert_sans" ] || fail "serving cert의 SAN을 읽지 못했다 — /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt"
san_missing=""
san_checked=0
for _san in ${K3S_TLS_SANS:-}; do
  san_checked=$((san_checked + 1))
  printf '%s' "$cert_sans" | grep -qF -- "$_san" || san_missing="${san_missing} ${_san}"
done
# ⚠️ 목록이 비면 루프가 0회 돌고 통과한다 — 바닥값이 그 vacuous green을 막는다(k3s-install.sh와 같은 규약).
[ "$san_checked" -ge 3 ] || fail "K3S_TLS_SANS가 ${san_checked}건뿐이다(최소 3) — versions.env 확인"
[ -z "$san_missing" ] || fail "serving cert에 없는 SAN:${san_missing} — 사후 추가는 serving cert 삭제·재생성이 필요하다"

echo "OK: host substrate verified (node Ready, both SCs, traefik/metrics-server absent, servicelb kept, secrets-encryption enabled, k3s ver pinned, node-ip pinned, ${san_checked} SANs on the live cert)."
