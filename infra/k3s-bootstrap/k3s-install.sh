#!/usr/bin/env bash
# NUC 베어메탈 노드에 homelab의 정확한 플래그 셋으로 k3s 단일 노드를 설치하고,
# 사용 가능한 kubeconfig를 gitignored 경로로 회수한다. **노드 위에서 실행한다.**
#
# 모드:
#   (기본)               노드에서 설치 실행 후 kubeconfig 회수.
#   K3S_PRINT_EXEC=1     INSTALL_K3S_EXEC 출력 후 종료 (오프라인 플래그 계약 테스트용).
#
# 시임 (테스트가 꽂는다 — 이 스크립트의 실행 절반은 예전에 커버리지가 **0**이었다):
#   K3S_RUN               권한 상승 명령. 기본 `sudo`. 테스트는 argv 기록기를 꽂는다.
#   K3S_INSTALLER_URL     설치 스크립트 URL. 기본 공식 인스톨러. 테스트는 `file://` 스텁.
#   K3S_READY_TRIES/SLEEP readyz 폴링 예산. 기본 60회×2초. 테스트는 1×0으로 줄인다.
#   K3S_KUBECONFIG_SERVER 설정 시 회수한 kubeconfig의 server URL을 이 값으로 재작성.
#                         (원격 워크스테이션에서 쓰려면 필요 — 미설정 시 노드 로컬 127.0.0.1 그대로)
#
# kubeconfig 정체성: 회수 직후 `kubeconfig-identity.sh`가 context·cluster·user 6필드를
# versions.env의 K3S_KUBECONFIG_NAME으로 각인한다(D-i). 시임이 아니라 **핀**이다 — 라이브 Mac의
# kubeconfig와 경로·포트·노드명이 전부 같아서, 이 이름이 두 클러스터를 가르는 첫 단서다.
#
# ⚠️ 이식 전 이 파일의 :39-63은 **테스트가 한 줄도 없었다**. `test_05-k3s-flags.bats`와
#    `verify-cluster.sh`가 **둘 다** `K3S_PRINT_EXEC=1` 경로만 썼고 그 모드는 플래그를 찍고 조기
#    종료했기 때문이다. 이식에서 가장 크게 바뀌는 절반이 무방비였다 — 위 시임들이 그 구멍을 닫는다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$SCRIPT_DIR/kubeconfig}"
K3S_RUN="${K3S_RUN:-sudo}"
K3S_INSTALLER_URL="${K3S_INSTALLER_URL:-https://get.k3s.io}"
K3S_READY_TRIES="${K3S_READY_TRIES:-60}"
K3S_READY_SLEEP="${K3S_READY_SLEEP:-2}"
K3S_KUBECONFIG_SERVER="${K3S_KUBECONFIG_SERVER:-}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- SAN 조립 (versions.env의 K3S_TLS_SANS에서 파생) -----------------------------
# ⚠️ 열거 붕괴 = 조용한 재앙이다. `--tls-san`은 **설치 시점에만** 정할 수 있어서, 목록이 비거나
#    오타로 짧아진 채 설치되면 교정에 serving cert 삭제가 필요하다. 그래서 for 루프 하나로 끝내지
#    않고 **바닥값**을 건다 — 빈 목록이면 루프가 0회 돌고 종료 상태 0이라 vacuous하게 통과한다
#    (레포가 scan-floor·min_rows로 도처에서 막는 바로 그 클래스).
san_args=""
san_n=0
for _san in ${K3S_TLS_SANS:-}; do
  san_args="${san_args}--tls-san=${_san} "
  san_n=$((san_n + 1))
done
[ "$san_n" -ge 3 ] || fail "K3S_TLS_SANS가 ${san_n}건뿐이다(최소 3) — versions.env 확인. --tls-san은 설치 후 교정이 serving cert 삭제를 요구한다."
case "${K3S_NODE_IP:-}" in
  "") fail "K3S_NODE_IP 미설정 — versions.env 확인. 핀이 없으면 노드 IP가 DHCP/인터페이스 변경을 따라 움직여 netpol 노드 서브넷 allow가 무효가 된다." ;;
esac
case "${K3S_NODE_NAME:-}" in
  "") fail "K3S_NODE_NAME 미설정 — versions.env 확인. 핀이 없으면 노드명이 리눅스 hostname(homelab)이 되는데, 그 이름은 이미 tailnet 프록시 디바이스와 레포를 뜻한다. 게다가 사후 변경은 노드 재등록이라 hostPath PV의 nodeAffinity가 통째로 깨진다." ;;
esac

# --- 플래그 계약 (single source of truth) ---------------------------------------
# servicelb는 유지한다(--disable에 없음). SQLite/kine이 기본 데이터스토어다
# (--cluster-init 없음, 따라서 embedded etcd는 쓰지 않는다). secrets-encryption은
# 첫날부터 켠다. 노드 보호용 reserve + eviction으로 폭주 pod가 kubelet을 OOM시키지 못하게 한다.
# 주의: kube-reserved/system-reserved/eviction-hard/image-gc-* 는 KUBELET 플래그라서
# 반드시 --kubelet-arg= 로 전달해야 한다 (k3s server는 단독 플래그로 주면 거부한다).
#
# ⚠️ --node-ip: 베어메탈 신규. tailscale0(100.109.208.81)이 이미 떠 있는 상태로 설치되므로
#    자동검출에 맡기지 않는다. 실측상 기본 경로는 wlo1이라 자동검출도 같은 값을 고르지만
#    (`ip route get 1.1.1.1` → src 192.168.117.15), 임대·인터페이스 변경에 대해 고정한다.
# ⚠️ --flannel-iface는 넣지 않는다 — flannel은 --node-ip가 속한 인터페이스를 따라가므로
#    중복 선언이고, NIC 이름은 IP보다 바뀔 여지가 크다(핀을 두 개 두면 어긋날 자리가 생긴다).
# ⚠️ eviction-hard의 nodefs는 **D4 한시 운용 기간에 의미가 바뀐다**: bulk를 노드 내장 디스크에
#    두면 bulk 증가가 nodefs를 밀어 클러스터 전역 축출을 유발한다(VM 시절 bulk는 virtiofs라
#    nodefs가 아니었다). 상세는 nuc-port-g2.md B1.
INSTALL_K3S_EXEC="server \
--node-ip=${K3S_NODE_IP} \
--node-name=${K3S_NODE_NAME} \
${san_args}\
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

# --- 실행 -----------------------------------------------------------------------
# ⚠️ OrbStack 시절엔 `orb -m <machine> -u root`로 VM 안에 들어갔다. 베어메탈에서는 **여기가 곧
#    노드**이므로 그 간접이 사라진다. 대신 권한 상승이 필요하고, `ukyi`의 sudo는 패스워드를
#    요구하므로(실측) 이 스크립트는 **대화형으로** 실행된다 — 비대화형 자동화 경로가 아니다.
# ⚠️ 여기서 리눅스 hostname을 찍지 않는다. 이 노드는 hostname이 `homelab`이고 k8s 노드명은
#    `k3s`다(D-h) — 설치 로그가 `node=homelab`이라 말하면 D-h가 피하려던 바로 그 혼동을
#    우리 손으로 다시 만드는 셈이다. 둘 다 찍되 무엇이 무엇인지 이름을 붙인다.
echo "==> k3s ${K3S_VERSION} 설치 (k8s node-name=${K3S_NODE_NAME}, node-ip=${K3S_NODE_IP}, SAN ${san_n}건; linux hostname=$(hostname))…"
curl -sfL "$K3S_INSTALLER_URL" | $K3S_RUN env \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC" \
  sh -s -

echo "==> k3s API 기동 대기…"
_ready=0
_i=0
while [ "$_i" -lt "$K3S_READY_TRIES" ]; do
  if $K3S_RUN k3s kubectl get --raw=/readyz >/dev/null 2>&1; then _ready=1; break; fi
  _i=$((_i + 1))
  [ "$K3S_READY_SLEEP" = "0" ] || sleep "$K3S_READY_SLEEP"
done
[ "$_ready" = "1" ] || fail "k3s API가 준비되지 않았다(${K3S_READY_TRIES}회 시도). journalctl -u k3s 를 보라."

echo "==> kubeconfig 회수 → ${KUBECONFIG_PATH} (gitignored)…"
# ⚠️ `>` 리다이렉트를 먼저 열면 회수가 실패해도 **빈 파일이 남는다** — 그 상태의 kubeconfig는
#    "존재하지만 쓸 수 없는" 가장 나쁜 형태다. 임시 파일에 받아 성공했을 때만 자리를 바꾼다.
_tmp="${KUBECONFIG_PATH}.tmp.$$"
# shellcheck disable=SC2064  # $_tmp를 지금 값으로 고정해야 한다(EXIT 시점 재평가 아님)
trap "rm -f '$_tmp'" EXIT
$K3S_RUN cat /etc/rancher/k3s/k3s.yaml > "$_tmp" || fail "kubeconfig 회수 실패 — /etc/rancher/k3s/k3s.yaml"
[ -s "$_tmp" ] || fail "회수한 kubeconfig가 비어 있다"
# 정체성 각인(D-i) — k3s의 기본 이름(context·cluster·user 전부 `default`)을 이 클러스터 이름으로
# 바꾼다. 라이브 Mac의 kubeconfig와 경로·포트·노드명이 전부 같아서, 이 이름이 두 클러스터를 가르는
# 첫 텍스트 단서다. 위임하는 이유: 소급 적용(이미 회수된 파일)이 **같은 구현**을 써야 하기 때문이다.
# ⚠️ server는 노드 로컬에서 127.0.0.1을 그대로 둔다 — k3s는 tailscaled와 순서 관계가 없어
#    부팅 직후 tailscale0이 아직 없는 창이 있다. 원격용 사본에만 K3S_KUBECONFIG_SERVER를 준다.
if [ -n "$K3S_KUBECONFIG_SERVER" ]; then
  "$SCRIPT_DIR/kubeconfig-identity.sh" --file "$_tmp" --name "$K3S_KUBECONFIG_NAME" --server "$K3S_KUBECONFIG_SERVER" \
    || fail "kubeconfig 정체성 각인 실패(server=${K3S_KUBECONFIG_SERVER})"
else
  "$SCRIPT_DIR/kubeconfig-identity.sh" --file "$_tmp" --name "$K3S_KUBECONFIG_NAME" \
    || fail "kubeconfig 정체성 각인 실패"
fi
mv "$_tmp" "$KUBECONFIG_PATH"
chmod 0600 "$KUBECONFIG_PATH"

echo "==> k3s 설치 완료. export KUBECONFIG=${KUBECONFIG_PATH}"
