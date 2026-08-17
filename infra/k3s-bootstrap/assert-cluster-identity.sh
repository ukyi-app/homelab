#!/usr/bin/env bash
# 클러스터 정체성 단언 (D-i, 2026-08-12) — "지금 KUBECONFIG가 가리키는 것이 정말 이 레포가
# 뜻하는 클러스터인가"를 라이브로 확인한다. 파괴적/변이 명령 앞에 세운다.
#
# 왜 필요한가: 라이브 Mac 클러스터와 NUC 클러스터의 kubeconfig는 **경로·포트가 같고**(둘 다
# infra/k3s-bootstrap/kubeconfig · 6443), #449 이후 **k8s 노드명까지 `k3s`로 같아졌다**. 즉
# KUBECONFIG를 잘못 export하면 아무 경고 없이 반대편 클러스터를 때린다.
# ⚠️ kubeconfig의 이름(context/cluster/user)을 나누는 것만으로는 **아무것도 막지 못한다** —
#    레포 전체에 --context 참조가 0건이라 그 이름을 읽는 코드가 없기 때문이다. 이 스크립트가
#    그 이름을 읽는 **첫 코드**이고, 그래서 이름 분리가 여기서 비로소 값을 갖는다.
#
# 세 축을 본다. 하나라도 어긋나면 그건 다른 클러스터다:
#   (1) kubeconfig가 스스로 부르는 이름  = K3S_KUBECONFIG_NAME   (텍스트 — 사람이 헷갈린 자리)
#   (2) 라이브 노드의 InternalIP        = K3S_NODE_IP           (네트워크 — netpol 6곳이 전제)
#   (3) 라이브 노드의 architecture      = K3S_NODE_ARCH         (기기 — Mac은 arm64 VM, NUC은 amd64)
# (3)이 가장 튼튼하다. 이름과 IP는 사람이 바꿀 수 있지만 아키텍처는 기기가 바뀌어야 바뀐다.
#
# ⚠️ serving cert SAN 대조는 **여기 넣지 않는다.** openssl s_client는 도달 불가 호스트에서 75초를
#    매달린다(실측). 그 비용을 모든 변이 명령에 곱할 수 없다 — SAN 검사는 verify-cluster [8]의 몫이다.
#
# 사용: assert-cluster-identity.sh [--warn]
#   기본  : 어긋나면 exit 1 (fail-closed). 변이/파괴 명령 앞.
#   --warn: 어긋나도 exit 0, 경고만. 읽기 전용 관측 명령 앞(새벽 3시에 관측 수단을 잠그지 않는다).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"

MODE="fail"
case "${1:-}" in
  --warn) MODE="warn" ;;
  "") ;;
  *) echo "FAIL: 알 수 없는 인자: $1 (허용: --warn)" >&2; exit 2 ;;
esac

# ⚠️ 경고 문구에 'SKIP: <이름>:' 형태를 쓰지 말 것. tools/check-guard-authority.ts의 SKIP_EMISSION
#    정규식이 그 문자열을 보면 이 타겟을 mirror에서 **권위 venue로 조용히 승격**시킨다.
BAD=0
say_bad() {
  BAD=$((BAD + 1))
  if [ "$MODE" = "warn" ]; then
    echo "WARN: cluster-identity: $*" >&2
    return 0
  fi
  echo "FAIL: cluster-identity: $*" >&2
  exit 1
}

KUBECTL_TIMEOUT="${KUBECTL_TIMEOUT:---request-timeout=15s}"

# (1) 이름 — kubeconfig 자신이 뭐라고 하는가
ctx="$(kubectl config current-context 2>/dev/null || true)"
if [ -z "$ctx" ]; then
  say_bad "current-context를 읽지 못했다 — KUBECONFIG가 설정되지 않았거나 파일이 없다 (export KUBECONFIG=<repo>/infra/k3s-bootstrap/kubeconfig)"
elif [ "$ctx" != "$K3S_KUBECONFIG_NAME" ]; then
  say_bad "context가 '${ctx}'다 — 기대 '${K3S_KUBECONFIG_NAME}' (versions.env). 다른 클러스터의 kubeconfig를 가리키고 있다"
fi

# (2)(3) 라이브 노드 — 텍스트가 맞아도 그 파일이 가리키는 곳이 다를 수 있다
node_json="$(kubectl "$KUBECTL_TIMEOUT" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}|{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true)"
live_ip="${node_json%%|*}"
live_arch="${node_json##*|}"

if [ -z "$node_json" ] || [ "$node_json" = "|" ]; then
  say_bad "라이브 노드를 읽지 못했다 — apiserver에 닿지 않거나 자격이 없다. 도달성부터 확인하라"
else
  [ "$live_ip" = "$K3S_NODE_IP" ] \
    || say_bad "노드 InternalIP가 '${live_ip}'다 — 기대 '${K3S_NODE_IP}' (versions.env). platform/**의 노드 서브넷 allow 6곳이 이 값의 /24를 전제한다"
  [ "$live_arch" = "$K3S_NODE_ARCH" ] \
    || say_bad "노드 architecture가 '${live_arch}'다 — 기대 '${K3S_NODE_ARCH}' (versions.env). 이건 기기가 다르다는 뜻이다"
fi

# ⚠️ warn 모드에서 어긋난 축이 있으면 OK를 찍지 않는다 — 경고를 내고도 "OK"라고 하면 그 줄만 보는
#    사람에게 거짓 신호가 된다. rc는 여전히 0이다(읽기 명령을 막지 않는 것이 warn의 목적이다).
if [ "$BAD" -gt 0 ]; then
  echo "WARN: cluster-identity: 위 ${BAD}건이 어긋났다 — 계속 진행한다(읽기 전용 경로)" >&2
  exit 0
fi
echo "cluster-identity OK (context ${ctx} · node ${live_ip} · ${live_arch})"
