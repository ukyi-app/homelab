#!/usr/bin/env bash
# OrbStack VM에 homelab의 정확한 플래그 셋으로 k3s 단일 노드를 설치하고,
# 사용 가능한 kubeconfig를 macOS 호스트의 gitignored 경로로 가져온다.
#
# 모드:
#   (기본)               VM 내부에서 설치 실행 후 kubeconfig 가져오기.
#   K3S_PRINT_EXEC=1     INSTALL_K3S_EXEC 출력 후 종료 (오프라인 플래그 계약 테스트용).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
ORB_MACHINE="${ORB_MACHINE:-k3s}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$SCRIPT_DIR/kubeconfig}"

# --- 플래그 계약 (single source of truth) ---------------------------------------
# servicelb는 유지한다(--disable에 없음). SQLite/kine이 기본 데이터스토어다
# (--cluster-init 없음, 따라서 embedded etcd는 쓰지 않는다). secrets-encryption은
# 첫날부터 켠다. 노드 보호용 reserve + eviction으로 폭주 pod가 kubelet을 OOM시키지 못하게 한다.
# 주의: kube-reserved/system-reserved/eviction-hard/image-gc-* 는 KUBELET 플래그라서
# 반드시 --kubelet-arg= 로 전달해야 한다 (k3s server는 단독 플래그로 주면 거부한다).
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
--write-kubeconfig-mode=0600"

if [ "${K3S_PRINT_EXEC:-0}" = "1" ]; then
  printf '%s\n' "$INSTALL_K3S_EXEC"
  exit 0
fi

command -v orb >/dev/null 2>&1 || { echo "FAIL: 'orb' not on PATH." >&2; exit 2; }

echo "==> Installing k3s ${K3S_VERSION} into VM '${ORB_MACHINE}'…"
# 공식 인스톨러를 VM 내부에서 root로 실행한다. K3S_VERSION으로 고정.
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
# OrbStack은 VM이 리슨하는 :6443을 호스트의 127.0.0.1:6443으로 자동 포워딩하고,
# k3s 서빙 인증서는 127.0.0.1을 SAN으로 포함한다 — 따라서 VM 내부 kubeconfig(이미
# https://127.0.0.1:6443 을 가리킴)는 macOS에서 그대로 바로 쓸 수 있다. DNS 재작성은
# 하지 않는다 (OrbStack 2.x에는 k3s.orb.local이 없고, 인증서 SAN도 아니다).
orb -m "$ORB_MACHINE" -u root cat /etc/rancher/k3s/k3s.yaml > "$KUBECONFIG_PATH"
chmod 0600 "$KUBECONFIG_PATH"

echo "==> k3s installed. Use: export KUBECONFIG=${KUBECONFIG_PATH}"
