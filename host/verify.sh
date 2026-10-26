#!/usr/bin/env bash
# k3s 설치 뒤 라이브 클러스터가 Git(host/)과 같은지 본다. 읽기만 하고 sudo 없이 실행한다(C.3.2 4번).
#
# 사용: host/verify.sh --cluster <이름> [--identity]
#   기본        정체성, 노드 Ready, k3s 버전, 라이브 node-args = 렌더한 k3s-config.yaml,
#               serving cert SAN, local-retain StorageClass, kubeconfig 권한.
#   --identity  정체성만 본다. 파괴 명령(삭제, 복구, 제거) 앞에서 대상 클러스터를 확인할 때 쓴다.
#
# kubeconfig는 KUBECONFIG가 있으면 그것, 없으면 ~/.kube/<KUBE_CONTEXT>.yaml(install.sh가 씀)이다.
# 모든 kubectl 호출에 --context <KUBE_CONTEXT>를 붙인다. 다른 클러스터의 파일을 가리키면 그 context가
# 없어 실패하고, 이름만 같은 다른 클러스터면 노드 이름에서 멈춘다(옛 assert-cluster-identity.sh를 줄임).
#
# 플래그 문자열이나 Git만 보면 "그렇게 설치할 것이다"만 증명된다. 여기서는 라이브 노드 객체,
# 어노테이션, 실제로 내주는 인증서를 본다. node-name, node-ip는 설치 때만 정해지고, tls-san은 config를
# 바꾼 뒤 재시작해야 인증서에 들어가므로 그 차이가 이 검사의 값이다.
set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FAILS=0
ok() { printf 'ok   %s\n' "$(mask "$*")"; }
bad() {
  printf 'FAIL %s\n' "$(mask "$*")" >&2
  FAILS=$((FAILS + 1))
}

usage() { die "사용: host/verify.sh --cluster <이름> [--identity]"; }

kc() { kubectl --context "$KUBE_CONTEXT" --request-timeout=15s "$@"; }

check_identity() {
  local ctxs nodes
  case "$KUBECONFIG" in
    *:*) ;;
    *) [ -f "$KUBECONFIG" ] || die "kubeconfig 파일이 없다: ${KUBECONFIG}. sudo host/install.sh --cluster ${CLUSTER} --k3s가 쓴다" ;;
  esac
  ctxs="$(kubectl config get-contexts -o name 2>/dev/null)" \
    || die "kubeconfig를 읽지 못했다(${KUBECONFIG})"
  grep -qxF -- "$KUBE_CONTEXT" <<<"$ctxs" \
    || die "kubeconfig(${KUBECONFIG})에 context ${KUBE_CONTEXT}가 없다. 다른 클러스터의 파일일 수 있다"
  nodes="$(kc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')" \
    || die "context ${KUBE_CONTEXT}의 apiserver에 닿지 못했다"
  nodes="${nodes%$'\n'}"
  # 단일 노드 클러스터다. 노드가 NODE_NAME 하나가 아니면 다른 클러스터를 가리킨다.
  [ "$nodes" = "$NODE_NAME" ] \
    || die "context ${KUBE_CONTEXT}의 노드가 '${nodes//$'\n'/ }'다. 기대: ${NODE_NAME} 하나. 다른 클러스터를 가리킨다"
  ok "정체성: context ${KUBE_CONTEXT}, 노드 ${NODE_NAME}"
}

check_ready() {
  if kc wait --for=condition=Ready "node/${NODE_NAME}" --timeout=120s >/dev/null; then
    ok "노드 Ready"
  else
    bad "노드 ${NODE_NAME}가 120초 안에 Ready가 되지 않았다"
  fi
}

check_version() {
  local v
  v="$(kc get node "$NODE_NAME" -o jsonpath='{.status.nodeInfo.kubeletVersion}')" || v=""
  if [ "$v" = "$INSTALL_K3S_VERSION" ]; then
    ok "k3s 버전 ${v}"
  else
    bad "k3s 버전이 핀과 다르다: 라이브 ${v:-없음}, versions.env ${INSTALL_K3S_VERSION}. 핀을 올려도 라이브는 install.sh --k3s를 다시 돌려야 바뀐다"
  fi
}

# k3s는 config.yaml의 키마다 --키=값 플래그를 만들고(목록은 항목마다 하나) 그 목록을
# k3s.io/node-args 어노테이션에 남긴다(옛 verify-cluster.sh:44-61 방식). 같은 모양으로 바꿔 통째로 비교한다.
# config.yaml.d drop-in이나 모르는 키(k3s가 경고만 하고 버림)도 여기서 차이로 드러난다.
check_node_args() {
  local ann live want d
  ann="$(kc get node "$NODE_NAME" -o jsonpath='{.metadata.annotations.k3s\.io/node-args}')" || ann=""
  if [ -z "$ann" ]; then
    bad "라이브 k3s.io/node-args 어노테이션을 읽지 못했다"
    return
  fi
  if ! live="$(node_args_pairs <<<"$ann")"; then
    bad "node-args 형식을 해석하지 못했다: ${ann}"
    return
  fi
  want="$(config_pairs <<<"$K3S_CFG")"
  if [ "$live" = "$want" ]; then
    ok "node-args가 host/k3s-config.yaml 렌더 결과와 같다($(grep -c . <<<"$want")개)"
  else
    # diff는 다르면 1로 끝난다. 여기서는 그 차이가 출력할 내용이다.
    d="$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$live") || true)"
    bad "node-args가 host/k3s-config.yaml과 다르다(< Git, > 라이브):"$'\n'"${d}"
  fi
}

# 실제로 6443에서 내주는 인증서의 SAN을 본다. tls-san-security(기본 true)를 끄면 SNI로 보낸 이름을 k3s가
# 인증서에 더해(동적 SAN) 검사가 스스로 통과를 만들 수 있다. 켜져 있어도 기대지 않고 SNI 없이 접속한다.
# 렌더 SAN이 인증서에 모두 있는지만 본다. 인증서에는 config에서 뺀 옛 이름이 남을 수 있다.
# 부분 일치로 보지 않는다. 짧은 이름이 빠져도 FQDN 항목에 걸려 통과하던 옛 자리다.
check_san() {
  local pem sans tokens want s missing="" n
  pem="$(timeout 10 openssl s_client -connect "${NODE_IP}:6443" -noservername </dev/null 2>/dev/null)" || pem=""
  sans="$(openssl x509 -noout -ext subjectAltName <<<"$pem" 2>/dev/null)" || sans=""
  tokens="$(tr ',' '\n' <<<"$sans" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed -n -e 's/^DNS://p' -e 's/^IP Address://p')"
  n="$(grep -c . <<<"$tokens" || true)"
  # 해석이 깨져 0개가 되면 모든 SAN이 "없음"으로 나오는 대신 형식 문제로 갈라 낸다.
  if [ "$n" -lt 3 ]; then
    bad "${NODE_IP}:6443 인증서의 SAN을 ${n}개만 읽었다. 접속이나 openssl 출력 형식을 본다"
    return
  fi
  want="$(config_pairs <<<"$K3S_CFG" | awk -F '\t' '$1 == "--tls-san" { print $2 }')"
  if [ -z "$want" ]; then
    bad "host/k3s-config.yaml 렌더 결과에 tls-san이 없다"
    return
  fi
  while IFS= read -r s; do
    grep -qxF -- "$s" <<<"$tokens" || missing+=" ${s}"
  done <<<"$want"
  if [ -z "$missing" ]; then
    ok "serving cert SAN에 tls-san $(grep -c . <<<"$want")개가 모두 있다"
  else
    bad "serving cert에 없는 SAN:${missing}. config의 tls-san이 바뀌었으면 sudo host/install.sh --cluster ${CLUSTER} --k3s로 config를 쓰고 k3s를 재시작한다"
  fi
}

# k3s 자동 배포는 시작 뒤 조금 늦게 적용될 수 있어 잠시 기다린다.
check_storageclass() {
  local got="" i=0
  while [ "$i" -lt 30 ]; do
    got="$(kc get storageclass local-retain -o jsonpath='{.provisioner} {.reclaimPolicy} {.volumeBindingMode}' 2>/dev/null)" || got=""
    [ -z "$got" ] || break
    sleep 2
    i=$((i + 1))
  done
  if [ "$got" = "rancher.io/local-path Retain WaitForFirstConsumer" ]; then
    ok "StorageClass local-retain(Retain, WaitForFirstConsumer)"
  else
    bad "StorageClass local-retain가 기대와 다르다: '${got:-없음}' (기대: rancher.io/local-path Retain WaitForFirstConsumer)"
  fi
}

# kubeconfig에는 cluster-admin 자격이 있다.
check_kubeconfig_mode() {
  local m
  if [ ! -f "$KUBECONFIG" ]; then
    bad "kubeconfig 파일이 아니다: ${KUBECONFIG}"
    return
  fi
  m="$(stat -c %a "$KUBECONFIG")"
  if [ "$m" = "600" ]; then
    ok "kubeconfig 권한 0600"
  else
    bad "kubeconfig 권한이 ${m}다(기대 600): ${KUBECONFIG}"
  fi
}

main() {
  local cluster="" identity_only=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --cluster) [ "$#" -ge 2 ] || usage; cluster="$2"; shift 2 ;;
      --identity) identity_only=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$cluster" ] || usage
  load_cluster "$cluster"
  require_cmds kubectl jq awk sed grep git
  assert_host_tree_clean
  export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/${KUBE_CONTEXT}.yaml}"

  log "verify (cluster=${CLUSTER}, context=${KUBE_CONTEXT}, kubeconfig=${KUBECONFIG})"
  check_identity
  if [ "$identity_only" -eq 1 ]; then
    return 0
  fi

  require_cmds openssl timeout tr stat diff
  resolve_magicdns
  K3S_CFG="$(render_k3s_config)"
  check_ready
  check_version
  check_node_args
  check_san
  check_storageclass
  check_kubeconfig_mode

  if [ "$FAILS" -gt 0 ]; then
    die "verify: ${FAILS}개 실패"
  fi
  log "verify 통과"
}

main "$@"
