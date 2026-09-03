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
#   - substrate 핀 3축(k3s 버전 · local-path provisioner 태그 · helper 이미지 digest)이 라이브와 일치
# 언제든 재실행 가능하게 설계; 첫 번째 불변식 실패에서 non-zero로 종료한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
export KUBECONFIG="${KUBECONFIG_PATH:-$SCRIPT_DIR/kubeconfig}"
# (K3S_INSTALL_SCRIPT 시임은 사라졌다 — [4]가 레포 스크립트를 실행하는 대신 라이브 node-args
#  어노테이션을 보게 됐기 때문이다. 이 파일은 이제 어느 검사에서도 레포 스크립트를 실행하지 않는다.)
# 노드 명령 시임 — 베어메탈에서는 **여기가 곧 노드**라 로컬 sudo다(OrbStack 시절의
# `orb -m <machine> -u root` 간접이 사라진다). 테스트는 스텁을 꽂는다.
K3S_RUN="${K3S_RUN:-sudo}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> [1] Node Ready?"
nodes="$(kubectl get nodes --no-headers 2>/dev/null || true)"
grep -qw "Ready" <<<"$nodes" || fail "node is not Ready"

echo "==> [2] StorageClasses present?"
sc="$(kubectl get sc --no-headers 2>/dev/null | awk '{print $1}')"
grep -qx "standard" <<<"$sc" || fail "StorageClass 'standard' missing"
grep -qx "bulk-ssd" <<<"$sc" || fail "StorageClass 'bulk-ssd' missing"

echo "==> [3] Disabled components absent? (traefik controller, metrics-server)"
pods="$(kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '{print $1}')"
# 컨트롤러 Deployment pod를 정확히 매칭해 servicelb LB pod(svclb-traefik-*)가
# traefik 컨트롤러로 오인되지 않게 한다.
grep -qE '^traefik-' <<<"$pods" && fail "traefik controller pod present — must be disabled"
grep -qE '^metrics-server' <<<"$pods" && fail "metrics-server pod present — must be disabled"

echo "==> [4] servicelb KEPT (not in the k3s --disable flag contract)?"
# ⚠️ 예전엔 레포의 k3s-install.sh를 K3S_PRINT_EXEC=1로 **실행해 그 출력을** grep했다. 그것은
#    "스크립트가 그 플래그를 낼 것이다"만 증명하고 "라이브 서버가 그 플래그로 설치됐다"는 전혀
#    증명하지 않는다 — 아래 [8]의 주석이 바로 그 구별을 이 게이트의 값이라고 적어 놨는데,
#    정작 [4] 자신이 그 반대편에 있었다(라이브 접촉 0). k3s는 설치 시 실제 argv를 노드
#    어노테이션에 남기므로 그것이 라이브 권위다.
node_args="$(kubectl get nodes -o jsonpath='{.items[0].metadata.annotations.k3s\.io/node-args}' 2>/dev/null || true)"
[ -n "$node_args" ] || fail "라이브 node-args 어노테이션을 읽지 못했다 — 설치 플래그 계약을 대조할 수 없다(k3s.io/node-args)"
case "$node_args" in
  *servicelb*) fail "servicelb가 라이브 k3s 플래그에 있다 — KEPT여야 한다(M3에서 Traefik의 노드 IP LoadBalancer를 제공한다). 사후 교정은 k3s 재설치다" ;;
esac
# 라이브 argv를 이미 손에 넣었으니 --secrets-encryption 도 같은 자리에서 본다([5]는 노드 셸이
# 필요해 별도 채널이다 — 여기 검사는 그 전제가 설치 시점에 실제로 있었는지를 값싸게 증명한다).
case "$node_args" in
  *--secrets-encryption*) ;;
  *) fail "라이브 k3s 플래그에 --secrets-encryption 이 없다 — 설치가 그 옵션 없이 됐다" ;;
esac

echo "==> [5] secrets-encryption enabled?"
enc="$($K3S_RUN k3s secrets-encrypt status 2>/dev/null || true)"
grep -qi "Enabled" <<<"$enc" || fail "secrets encryption is not Enabled"

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
# ⚠️ **부분일치로 대조하면 안 된다.** 라이브 SAN은 `DNS:nuc-15-pro, DNS:nuc-15-pro.tailcf1ac6.ts.net,
#    IP Address:192.168.117.15, …` 형태라, grep -F 'nuc-15-pro' 는 FQDN 항목에도 매치된다 —
#    짧은 이름이 cert에서 **빠져도 초록**이 되던 자리다(실측). 토큰으로 잘라 정확일치로 본다.
san_tokens="$(printf '%s' "$cert_sans" | tr ',' '\n' \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^DNS://' -e 's/^IP Address://')"
tok_n="$(printf '%s\n' "$san_tokens" | grep -c . || true)"
# ⚠️ 토큰화가 깨져 0건이 되면 아래 루프가 전건 missing을 내는 게 아니라, 형식 변화를 SAN 부재로
#    오진한다. 바닥값이 그 오진을 형식 문제로 분리한다(k3s 기본 SAN만 해도 8건이 넘는다).
[ "$tok_n" -ge 5 ] || fail "serving cert SAN 토큰이 ${tok_n}건뿐이다(최소 5) — openssl 출력 형식이 예상과 다르다"
san_missing=""
san_checked=0
for _san in ${K3S_TLS_SANS:-}; do
  san_checked=$((san_checked + 1))
  grep -qxF -- "$_san" <<<"$san_tokens" || san_missing="${san_missing} ${_san}"
done
# ⚠️ 목록이 비면 루프가 0회 돌고 통과한다 — 바닥값이 그 vacuous green을 막는다(k3s-install.sh와 같은 규약).
[ "$san_checked" -ge 3 ] || fail "K3S_TLS_SANS가 ${san_checked}건뿐이다(최소 3) — versions.env 확인"
[ -z "$san_missing" ] || fail "serving cert에 없는 SAN:${san_missing} — 사후 추가는 serving cert 삭제·재생성이 필요하다"

echo "==> [9] live node name matches the pin (hostPath PV nodeAffinity depends on it)?"
# ⚠️ [8]과 같은 이유로 **라이브 노드 오브젝트**를 본다. `--node-name`은 설치 시점에만 정해지고,
#    사후 변경은 노드 재등록이라 hostPath PV의 nodeAffinity가 통째로 깨진다 — 즉 표류를 늦게
#    발견할수록 비싸다. 플래그 문자열 grep으로는 "설치가 실제로 그 이름으로 됐다"를 못 증명한다.
nname="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$nname" ] || fail "라이브 노드명을 읽지 못했다 — 이름 핀을 대조할 수 없다"
[ "$nname" = "$K3S_NODE_NAME" ] || fail "node name drift: live '${nname}' != pinned '$K3S_NODE_NAME' (versions.env). hostPath PV의 nodeAffinity가 이 값을 담으므로, 지금 고치려면 노드 재등록 + PV 재작성이다."

echo "==> [10] local-path provisioner image matches the pin (LOCAL_PATH_PROVISIONER_VERSION)?"
# ⚠️ 왜 여기인가: [6]이 이미 같은 자리에서 K3S_VERSION↔라이브 kubeletVersion을 재는데, substrate 핀
#    **3개 중 나머지 둘**(provisioner 태그·helper digest)은 라이브 대조자가 레포 전역에 0건이었다.
#    실측 2026-09-03: git v0.0.37 / 라이브 v0.0.36 · git dc2d74b2… / 라이브 fd8d9aa6… — 세 축 전부
#    갈렸는데 신호를 낸 것은 없었다(핀은 2026-08-17 #420·#421·#417에 올랐고 라이브는 부트스트랩 값).
# ⚠️ **한계를 정직하게**: 이 스크립트의 유일한 호출자는 `host-up.sh:34`이고 그건 apply-storage 직후다
#    — 재구축 경로에서는 [6]과 마찬가지로 거의 항진명제다. 여기 두는 값은 "주기 신호"가 아니라
#    ① 세 축의 **비대칭 해소**(하나만 재던 상태를 끝낸다)와 ② 이 파일이 표방하는 "언제든 재실행
#    가능"(헤더 :12)한 owner 수동 대조가 실제로 세 축을 다 본다는 것이다. 상주 드리프트를 재는
#    캐던스는 별건이다(ADR-0007 결정 2 형태의 게이지 + vmalert warning).
lpp_images="$(kubectl -n local-path-storage get deploy \
  -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null | grep . || true)"
lpp_n="$(printf '%s\n' "$lpp_images" | grep -c . || true)"
# ⚠️ 열거가 0이면 "위반 0"이 아니라 아무것도 안 본 것이다 — 듀얼 provisioner라 바닥값은 2다.
[ "$lpp_n" -ge 2 ] || fail "local-path-storage의 provisioner Deployment 이미지를 ${lpp_n}건만 읽었다(기대 >=2, internal·bulk) — 네임스페이스/이름이 바뀌었거나 apply-storage가 안 돌았다"
# ⚠️ 위반을 **모아서** 비었는지 본다. `grep -qv`는 줄 단위 반전이라 부재를 재지 못한다(레포 함정).
lpp_bad="$(printf '%s\n' "$lpp_images" | grep -vxF -- "rancher/local-path-provisioner:${LOCAL_PATH_PROVISIONER_VERSION}" || true)"
[ -z "$lpp_bad" ] || fail "local-path provisioner image drift: live '$(printf '%s' "$lpp_bad" | tr '\n' ' ')' != pinned 'rancher/local-path-provisioner:${LOCAL_PATH_PROVISIONER_VERSION}' (versions.env). 수렴 경로는 owner-local apply-storage.sh다 — Renovate bump 머지만으로는 라이브가 안 바뀐다."

echo "==> [11] local-path helper pod image matches the pin (LOCAL_PATH_HELPER_IMAGE)?"
# helper 이미지는 두 ConfigMap의 `helperPod.yaml` 안에 있다(apply-storage.sh가 envsubst로 치환).
# 이건 **모든 PV의 mkdir/rm을 수행하는 이미지**이고 digest 핀이라, tag가 같아도 digest가 갈리면 다른 것이다.
helper_seen=0
helper_bad=""
for _cm in local-path-config-internal local-path-config-bulk; do
  _hp="$(kubectl -n local-path-storage get cm "$_cm" -o jsonpath='{.data.helperPod\.yaml}' 2>/dev/null || true)"
  _img="$(printf '%s\n' "$_hp" | awk '/^[[:space:]]*image:[[:space:]]/{sub(/^[[:space:]]*image:[[:space:]]*/,""); print; exit}')"
  [ -n "$_img" ] || { helper_bad="${helper_bad} ${_cm}(image 줄 없음)"; continue; }
  helper_seen=$((helper_seen + 1))
  [ "$_img" = "$LOCAL_PATH_HELPER_IMAGE" ] || helper_bad="${helper_bad} ${_cm}:${_img}"
done
# ⚠️ 루프가 0회 돌거나 두 ConfigMap이 다 비면 위 단언들이 전부 vacuous다 — 바닥값이 그것을 가른다.
[ "$helper_seen" -ge 2 ] || fail "helperPod 이미지를 ${helper_seen}건만 읽었다(기대 2, internal·bulk):${helper_bad}"
[ -z "$helper_bad" ] || fail "local-path helper image drift:${helper_bad} != pinned '${LOCAL_PATH_HELPER_IMAGE}' (versions.env). helper는 모든 PV 디렉토리의 mkdir/rm을 수행한다 — digest가 갈리면 재구축이 다른 기판을 만든다."

echo "OK: host substrate verified (node Ready, both SCs, traefik/metrics-server absent, servicelb kept, secrets-encryption enabled, k3s ver pinned, node-ip pinned, node-name ${nname} pinned, ${san_checked} SANs on the live cert, ${lpp_n} provisioner images + ${helper_seen} helper images pinned)."
