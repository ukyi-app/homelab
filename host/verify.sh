#!/usr/bin/env bash
# k3s 설치 뒤 라이브 클러스터가 Git(host/)과 같은지 본다. 읽기만 하고 sudo 없이 실행한다(C.3.2 4번).
# 예외 넷: 커널 nft 표, 삭제 원장 파일(0750 디렉터리 안), 샌드박스 프로필(kubelet 디렉터리, 커널 AppArmor 목록), 작업 레인 이미지의
# 파일시스템(0600 파일)은 root만 읽어서 sudo -n(비밀번호를 묻지 않음)으로 읽어 본다.
#
# 사용: host/verify.sh --cluster <이름> [--identity]
#   기본        정체성, 노드 Ready, k3s 버전, 라이브 node-args = 렌더한 k3s-config.yaml,
#               serving cert SAN, local-retain StorageClass, 파드 egress(유닛, 규칙 파일, 대역, 커널 표),
#               inotify 인스턴스 한도(설치된 sysctl 파일, 커널 값), 삭제 원장 SSD(마운트, fstab, 원장 디렉터리·
#               파일 소유·모드, 표식 형식. BULK_SSD_LABEL이 빈 클러스터는 건너뜀), 샌드박스 프로필(containerd 판,
#               호스트 조건, 깔린 파일 소유·모드·해시, AppArmor enforce 적재), 작업 레인 볼륨(유닛, 마운트 원본·ext4·rw·크기,
#               이미지 크기·할당·UUID, data 소유·모드), kubeconfig 권한.
#   --identity  정체성만 본다. 파괴 명령(삭제, 복구, 제거) 앞에서 대상 클러스터를 확인할 때 쓴다.
#
# 종료 코드: 0 통과, 1 실패, 2 실패는 없지만 커널 표를 못 읽어 미검증(sudo 자격이 없다).
# 2를 통과로 읽지 않는다. sudo -v로 자격을 받아 둔 같은 터미널에서 다시 실행하면 0이나 1이 된다.
#
# kubeconfig는 KUBECONFIG가 있으면 그것, 없으면 ~/.kube/<KUBE_CONTEXT>.yaml(install.sh가 씀)이다.
# 모든 kubectl 호출에 --context <KUBE_CONTEXT>를 붙인다. 다른 클러스터의 파일을 가리키면 그 context가
# 없어 실패하고, 이름만 같은 다른 클러스터면 노드 이름에서 멈춘다.
#
# 플래그 문자열이나 Git만 보면 "그렇게 설치할 것이다"만 증명된다. 여기서는 라이브 노드 객체,
# 어노테이션, 실제로 내주는 인증서를 본다. node-name, node-ip는 설치 때만 정해지고, tls-san은 config를
# 바꾼 뒤 재시작해야 인증서에 들어가므로 그 차이가 이 검사의 값이다.
set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FAILS=0
UNVERIFIED=0
# check_inotify가 보는 곳. tools/host-k3s.test.sh가 경로를 바꾼다.
INOTIFY_SRC="$HOST_DIR/etc/sysctl.d/60-inotify.conf"
INOTIFY_DEST=/etc/sysctl.d/60-inotify.conf
INOTIFY_PROC=/proc/sys/fs/inotify/max_user_instances
ok() { printf 'ok   %s\n' "$(mask "$*")"; }
bad() {
  printf 'FAIL %s\n' "$(mask "$*")" >&2
  FAILS=$((FAILS + 1))
}
skip() {
  printf 'SKIP %s\n' "$(mask "$*")" >&2
  UNVERIFIED=$((UNVERIFIED + 1))
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
# k3s.io/node-args 어노테이션에 남긴다. 같은 모양으로 바꿔 통째로 비교한다.
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
# 렌더 SAN이 인증서에 모두 있는지만 본다(lib.sh missing_sans). 인증서에는 config에서 뺀 옛 이름이 남을 수 있다.
# 한 번만 본다. tls-san을 바꾼 재시작 직후에는 옛 인증서가 잠시 나가는데(install.sh wait_serving_sans 주석),
# install.sh --k3s가 새 SAN이 나올 때까지 기다린 뒤 끝난다. 그 뒤로는 새 인증서가 dynamic-cert.json에 있어
# 다음 시작부터 바로 나간다. 여기서 다시 보면 진짜 누락의 FAIL만 늦어진다.
check_san() {
  local tokens want missing n
  tokens="$(serving_sans 10)"
  n="$(grep -c . <<<"$tokens" || true)"
  # 해석이 깨져 0개가 되면 모든 SAN이 "없음"으로 나오는 대신 형식 문제로 갈라 낸다.
  if [ "$n" -lt 3 ]; then
    bad "${NODE_IP}:6443 인증서의 SAN을 ${n}개만 읽었다. 접속이나 openssl 출력 형식을 본다"
    return
  fi
  want="$(tls_sans <<<"$K3S_CFG")"
  if [ -z "$want" ]; then
    bad "host/k3s-config.yaml 렌더 결과에 tls-san이 없다"
    return
  fi
  missing="$(missing_sans "$want" "$tokens")"
  if [ -z "$missing" ]; then
    ok "serving cert SAN에 tls-san $(grep -c . <<<"$want")개가 모두 있다"
  else
    bad "serving cert에 없는 SAN: ${missing//$'\n'/ }. config의 tls-san이 바뀌었으면 sudo host/install.sh --cluster ${CLUSTER} --k3s로 config를 쓰고 k3s를 재시작한다"
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

# 파드 egress 규칙(install.sh --egress). 유닛·파일만으로는 부족하다. 유닛은 oneshot이라 누가 표를 지우거나
# flush ruleset(distro nftables.service 재시작 등)해도 active로 남고, 파일만 바꾸고 reload를 빠뜨려도 파일은
# Git과 같다. 그래서 커널 표를 읽어 렌더 해시, 표가 켜져 있는지(flags), 모든 규칙이 렌더와 같은지 본다
# (lib.sh egress_kernel_problems).
# 대역도 본다. 라이브 대역과 다르면 규칙은 성공한 채 아무 파드에도 걸리지 않는다.
check_egress() {
  local en act want d pod svc js rc problems
  # 꺼져 있거나 없으면 0이 아닌 값으로 끝나지만 상태 글자(disabled, inactive)는 낸다. 그 글자를 본다.
  en="$(systemctl is-enabled "$EGRESS_UNIT_NAME" 2>/dev/null || true)"
  act="$(systemctl is-active "$EGRESS_UNIT_NAME" 2>/dev/null || true)"
  if [ "$en" = "enabled" ] && [ "$act" = "active" ]; then
    ok "${EGRESS_UNIT_NAME} enabled, active"
  else
    bad "${EGRESS_UNIT_NAME}가 enabled·active가 아니다(${en:-없음}, ${act:-없음}). sudo host/install.sh --cluster ${CLUSTER} --egress"
  fi

  want="$(render_egress)"
  if [ ! -r "$EGRESS_RULES" ]; then
    bad "${EGRESS_RULES}가 없다"
  elif d="$(diff <(printf '%s\n' "$want") "$EGRESS_RULES")"; then
    ok "${EGRESS_RULES}가 host/egress/egress.nft 렌더 결과와 같다"
  else
    bad "${EGRESS_RULES}가 Git 렌더와 다르다(< Git, > 라이브). install.sh --egress를 다시 실행한다:"$'\n'"${d}"
  fi
  if cmp -s "$HOST_DIR/egress/${EGRESS_UNIT_NAME}" "$EGRESS_UNIT"; then
    ok "${EGRESS_UNIT}가 Git과 같다"
  else
    bad "${EGRESS_UNIT}가 없거나 host/egress/${EGRESS_UNIT_NAME}와 다르다"
  fi

  if ! pod="$(kc get node "$NODE_NAME" -o jsonpath='{.spec.podCIDR}')"; then
    bad "노드 ${NODE_NAME}의 podCIDR를 읽지 못했다"
  elif [ -z "$pod" ]; then
    # install.sh --k3s가 배정까지 기다린 뒤 끝나므로(wait_pod_cidr) 여기서 비었으면 일시 상태가 아니다.
    bad "노드 podCIDR가 없다. 파드 네트워크(flannel)가 시작하지 않는다. journalctl -u k3s -g PodCIDR로 node-ipam 로그를 본다"
  elif cidr_within "$POD_CIDR" "$pod"; then
    ok "노드 podCIDR ${pod}가 POD_CIDR ${POD_CIDR} 안에 있다"
  else
    bad "노드 podCIDR '${pod}'가 POD_CIDR ${POD_CIDR} 밖이다. egress 규칙이 파드에 걸리지 않는다"
  fi
  svc="$(kc -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}')" || svc=""
  if [ -n "$svc" ] && cidr_within "$SERVICE_CIDR" "$svc"; then
    ok "kubernetes Service ${svc}가 SERVICE_CIDR ${SERVICE_CIDR} 안에 있다"
  else
    bad "kubernetes Service IP '${svc:-없음}'가 SERVICE_CIDR ${SERVICE_CIDR} 밖이다"
  fi

  rc=0
  js="$(egress_kernel_json)" || rc=$?
  case "$rc" in
    0)
      problems="$(egress_kernel_problems <<<"$js")"
      if [ -z "$problems" ]; then
        ok "커널 table inet ${EGRESS_TABLE}: 렌더 해시, 켜져 있음(flags 없음), 체인·규칙·nonpublic이 렌더와 같음"
      else
        bad "커널 table inet ${EGRESS_TABLE}가 Git 렌더와 다르다. sudo host/install.sh --cluster ${CLUSTER} --egress:"$'\n'"${problems}"
      fi
      ;;
    2) skip "커널 table inet ${EGRESS_TABLE}를 읽지 못했다(root 아님, sudo -n 불가). sudo -v 뒤 같은 터미널에서 다시 실행한다" ;;
    *) bad "커널에 table inet ${EGRESS_TABLE}가 없다. 규칙이 꺼져 있다. sudo host/install.sh --cluster ${CLUSTER} --egress" ;;
  esac
}

# inotify 인스턴스 한도(install.sh --host-config). 설치된 파일(재부팅 뒤에도 systemd-sysctl이 건다)과
# 지금 커널 값을 따로 본다. 커널 값만 보면 손으로 sysctl -w한 값이 재부팅에 사라지는 것을 놓친다.
# 기대 값은 Git 파일에서 읽는다. 한도라 더 큰 값은 통과다.
check_inotify() {
  local want live
  want="$(sed -nE 's/^fs\.inotify\.max_user_instances[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$INOTIFY_SRC")"
  # 줄이 0개나 둘 이상이면 숫자 하나가 아니다. 빈 기대 값으로 비교하면 무엇이든 통과한다.
  if ! [[ "$want" =~ ^[0-9]+$ ]]; then
    bad "${INOTIFY_SRC}에서 fs.inotify.max_user_instances 값 하나를 읽지 못했다"
    return
  fi
  if cmp -s "$INOTIFY_SRC" "$INOTIFY_DEST"; then
    ok "${INOTIFY_DEST}가 Git과 같다"
  else
    bad "${INOTIFY_DEST}가 없거나 Git과 다르다. 재부팅하면 커널 값이 돌아간다. sudo host/install.sh --cluster ${CLUSTER} --host-config"
  fi
  live="$(cat "$INOTIFY_PROC" 2>/dev/null)" || live=""
  if [[ "$live" =~ ^[0-9]+$ ]] && [ "$live" -ge "$want" ]; then
    ok "fs.inotify.max_user_instances ${live}(${want} 이상)"
  else
    bad "fs.inotify.max_user_instances가 ${live:-없음}이다(기대 ${want} 이상). root 데몬(libvirt dnsmasq 등)이 inotify를 만들지 못한다. sudo host/install.sh --cluster ${CLUSTER} --host-config"
  fi
}

# 샌드박스 프로필(install.sh --sandbox-profiles). containerd 판은 root 없이 보고, 파일과 커널 목록은 as_root로 본다.
# 판이 다르면 프로필의 출발점이 라이브 기본값과 어긋난 것이다. k3s를 올리고 프로필을 다시 만들지 않으면 여기서 걸린다.
check_sandbox_profiles() {
  local live p
  live="$(kc get node "$NODE_NAME" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')" || live=""
  if [ "$live" = "containerd://${SANDBOX_PROFILE_CONTAINERD}" ]; then
    ok "containerd ${SANDBOX_PROFILE_CONTAINERD}가 샌드박스 프로필의 판과 같다"
  else
    bad "containerd가 샌드박스 프로필의 판과 다르다: 라이브 ${live:-없음}, versions.env ${SANDBOX_PROFILE_CONTAINERD}. tools/sandbox-profiles/regen.sh로 다시 만들고 다시 잰다"
  fi
  if ! as_root true; then
    skip "샌드박스 프로필: kubelet 디렉터리와 커널 AppArmor 목록은 root만 읽는다. sudo -v 뒤 같은 터미널에서 다시 실행한다"
    return
  fi
  p="$(sandbox_host_problems)"
  if [ -z "$p" ]; then
    ok "샌드박스 호스트 조건: apparmor.service enabled, Ubuntu bwrap·unpriv_bwrap enforce"
  else
    bad "샌드박스 호스트 조건:"$'\n'"${p}"
  fi
  p="$(sandbox_installed_problems)"
  if [ -z "$p" ]; then
    ok "샌드박스 프로필이 Git과 같다(소유·모드·해시, AppArmor enforce)"
  else
    bad "샌드박스 프로필이 Git과 다르다. sudo host/install.sh --cluster ${CLUSTER} --sandbox-profiles:"$'\n'"${p}"
  fi
}

# 작업 레인 고정 크기 볼륨(install.sh --task-state-volume). 읽기만 한다. 값 파일로 건너뛰지 않는다. 운영·VM이 task.enabled를 함께 쓴다.
# 마운트가 없으면 이미지를 더 보지 않고, 대신 루트 디스크 쪽에 data가 생겼는지 본다. 그것이 있으면 상한 없이 PV가 붙는다.
check_task_state_volume() {
  local en p
  if cmp -s "$HOST_DIR/task-state/${TASK_STATE_UNIT_NAME}" "$TASK_STATE_UNIT"; then
    ok "${TASK_STATE_UNIT}가 Git과 같다"
  else
    bad "${TASK_STATE_UNIT}가 없거나 host/task-state/와 다르다. sudo host/install.sh --cluster ${CLUSTER} --task-state-volume"
  fi
  en="$(systemctl is-enabled "$TASK_STATE_UNIT_NAME" 2>/dev/null || true)"
  if [ "$en" = enabled ]; then
    ok "${TASK_STATE_UNIT_NAME} enabled"
  else
    bad "${TASK_STATE_UNIT_NAME}가 enabled가 아니다(${en:-없음}). 재부팅하면 작업 레인 파드가 뜨지 않는다"
  fi
  p="$(task_state_mount_problem)"
  if [ -n "$p" ]; then
    bad "${p}. sudo host/install.sh --cluster ${CLUSTER} --task-state-volume"
    if [ -z "$(task_state_mount_lines)" ] && { [ -e "$TASK_STATE_DATA" ] || [ -L "$TASK_STATE_DATA" ]; }; then
      bad "마운트 안 된 루트 디스크 쪽에 ${TASK_STATE_DATA}가 있다. 크기 상한 없이 PV가 이 디렉터리를 붙일 수 있다"
    fi
    return
  fi
  ok "${TASK_STATE_MOUNT} 마운트(${TASK_STATE_IMAGE}, ext4, rw, nodev, nosuid, 상한 ${TASK_STATE_BYTES}바이트)"
  p="$(task_state_file_problems)"
  if [ -z "$p" ]; then
    ok "이미지 크기 ${TASK_STATE_BYTES}바이트, 미리 할당, ${TASK_STATE_IMAGE_OWNER} 0600"
  else
    bad "이미지가 기대와 다르다:"$'\n'"${p}"
  fi
  p="$(stat_problem "$(stat -c '%u:%g %a %F' -- "$TASK_STATE_DATA" 2>/dev/null)" "$TASK_STATE_DATA_OWNER" 2770 directory "$TASK_STATE_DATA")"
  if [ -z "$p" ]; then
    ok "${TASK_STATE_DATA}(${TASK_STATE_DATA_OWNER} 2770)"
  else
    bad "data 디렉터리가 기대와 다르다: ${p}"
  fi
  if ! as_root true; then
    skip "작업 레인 이미지 fs·UUID: 0600 파일이라 root만 읽는다. sudo -v 뒤 같은 터미널에서 다시 실행한다"
    return
  fi
  p="$(task_state_fs_problems)"
  if [ -z "$p" ]; then
    ok "이미지 ext4, UUID가 기록과 같다"
  else
    bad "이미지 파일시스템이 기대와 다르다:"$'\n'"${p}"
  fi
}

# tailnet TLS 감시(install.sh --tls-monitor). 결과 파일은 누구나 읽어 sudo가 필요 없다.
check_tls_monitor() {
  local src dest en act p
  if [ "$TAILNET_JOIN" != "true" ]; then
    if grep -qxF "$TLS_MONITOR_DISABLED_LINE" "$TLS_MONITOR_PROM" 2>/dev/null; then
      ok "${TLS_MONITOR_PROM}에 끔 표시 있음(호스트가 tailnet에 들지 않아 타이머 없음)"
    else
      bad "${TLS_MONITOR_PROM}에 끔 표시가 없다. TailnetTLSMissing이 울린다. sudo host/install.sh --cluster ${CLUSTER} --tls-monitor"
    fi
    return
  fi
  while IFS=$'\t' read -r src dest _; do
    if cmp -s "$src" "$dest"; then
      ok "${dest}가 Git과 같다"
    else
      bad "${dest}가 없거나 ${src#"$HOST_DIR"/}와 다르다. sudo host/install.sh --cluster ${CLUSTER} --tls-monitor"
    fi
  done < <(tls_monitor_files)
  en="$(systemctl is-enabled "$TLS_MONITOR_TIMER" 2>/dev/null || true)"
  act="$(systemctl is-active "$TLS_MONITOR_TIMER" 2>/dev/null || true)"
  if [ "$en" = enabled ] && [ "$act" = active ]; then
    ok "${TLS_MONITOR_TIMER} enabled, active"
  else
    bad "${TLS_MONITOR_TIMER}가 enabled·active가 아니다(${en:-없음}, ${act:-없음})"
  fi
  p="$(tls_monitor_output_problems)"
  if [ -z "$p" ]; then
    ok "tailnet TLS 수집 결과가 최근 것이고 실패가 없다"
  else
    bad "tailnet TLS 수집 결과:"$'\n'"${p}"
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
  # 노드의 kubectl은 k3s 멀티콜 바이너리다(설치 스크립트가 kubectl -> k3s 심링크를 건다). 멀티콜은 kubectl로 넘기기
  # 전에 debug·data-dir·prefer-bundled-bin을 config 파일에서 찾고(k3s v1.36.5+k3s1 cmd/k3s/main.go:114·134·152),
  # 비root는 /etc/rancher/k3s/config.yaml(0600)을 못 읽어 호출마다 "WARN open ...: permission denied"를 낸다
  # (pkg/configfilearg/defaultparser.go MustFindString). 판정에는 영향이 없고 출력만 덮는다. 셋 다 host/k3s-config.yaml에
  # 없어, 빈 파일을 config로 가리켜도 정해지는 값(기본값)은 지금과 같다. k3s가 아닌 kubectl은 이 변수를 보지 않는다.
  # 안쪽 kubectl의 k3s.yaml 권한 경고(pkg/kubectl/main.go:31-38)는 위처럼 KUBECONFIG를 늘 주므로 나지 않는다.
  export K3S_CONFIG_FILE=/dev/null

  log "verify (cluster=${CLUSTER}, context=${KUBE_CONTEXT}, kubeconfig=${KUBECONFIG})"
  check_identity
  if [ "$identity_only" -eq 1 ]; then
    return 0
  fi

  require_cmds openssl timeout tr stat diff cmp systemctl sha256sum findmnt lsblk readlink losetup
  resolve_magicdns
  K3S_CFG="$(render_k3s_config)"
  check_ready
  check_version
  check_node_args
  check_san
  check_storageclass
  check_egress
  check_inotify
  check_bulk_ssd
  check_sandbox_profiles
  check_task_state_volume
  check_tls_monitor
  check_kubeconfig_mode
  finish
}

# 삭제 원장 SSD(install.sh --bulk-ssd). 읽기만 한다. 원장 파일 내용은 출력하지 않는다(기억 ID·시각).
# 마운트가 없으면 원장을 더 보지 않고, 대신 루트 디스크 쪽에 원장 경로가 생겼는지 본다. 그것이 있으면
# SSD 없이 PV가 붙어 봇이 빈 원장을 볼 수 있다.
check_bulk_ssd() {
  local n fl p parent dir f m out
  if [ -z "$BULK_SSD_LABEL" ]; then
    ok "삭제 원장 SSD: 이 클러스터는 쓰지 않는다(BULK_SSD_LABEL 빈 값)"
    return
  fi
  parent="${BULK_MOUNT}/${LEDGER_PARENT_REL}"
  dir="${BULK_MOUNT}/${LEDGER_DIR_REL}"
  f="${dir}/${LEDGER_FILE}"
  m="${dir}/${LEDGER_MARKER}"
  # 비root는 장치를 직접 못 읽는다. lsblk는 udev가 읽어 둔 라벨을 낸다.
  n="$(lsblk -r -n -o LABEL 2>/dev/null | grep -cxF -- "$BULK_SSD_LABEL" || true)"
  if [ "$n" = 1 ]; then ok "라벨 ${BULK_SSD_LABEL} 블록 장치 1개"; else bad "라벨 ${BULK_SSD_LABEL} 블록 장치가 ${n}개다(기대 1)"; fi
  fl="$(fstab_bulk_lines)"
  if [ "$fl" = "$(bulk_fstab_line)" ]; then
    ok "fstab ${BULK_MOUNT} 줄이 기대와 같다"
  else
    bad "fstab의 ${BULK_MOUNT}·LABEL=${BULK_SSD_LABEL} 줄이 기대와 다르다(지금: ${fl:-없음}). sudo host/install.sh --cluster ${CLUSTER} --bulk-ssd"
  fi
  p="$(bulk_mount_problem "")"
  if [ -n "$p" ]; then
    bad "${p}. sudo host/install.sh --cluster ${CLUSTER} --bulk-ssd"
    if [ -e "$parent" ] || [ -L "$parent" ]; then
      bad "마운트 안 된 루트 디스크 쪽에 ${parent}가 있다. SSD 없이 원장 PV가 이 디렉터리를 붙일 수 있다"
    fi
    return
  fi
  ok "${BULK_MOUNT} 마운트(ext4, rw, 라벨 ${BULK_SSD_LABEL})"
  p="$(stat_problem "$(stat -c '%u:%g %a %F' -- "$parent" 2>/dev/null)" "$LEDGER_PARENT_OWNER" 755 directory "$parent")"
  p+="$(stat_problem "$(stat -c '%u:%g %a %F' -- "$dir" 2>/dev/null)" "$LEDGER_OWNER" 750 directory "$dir")"
  if [ -n "$p" ]; then
    bad "원장 디렉터리가 계약 v1과 다르다:"$'\n'"${p}"
    return
  fi
  ok "원장 디렉터리 ${dir}(${LEDGER_OWNER} 0750)"
  if ! as_root true; then
    skip "원장 파일 소유·모드·표식: 0750 디렉터리 안이라 root만 읽는다. sudo -v 뒤 같은 터미널에서 다시 실행한다"
    return
  fi
  p="$(stat_problem "$(as_root stat -c '%u:%g %a %F' -- "$f" 2>/dev/null)" "$LEDGER_OWNER" 600 "regular file" "$f")"
  p+="$(stat_problem "$(as_root stat -c '%u:%g %a %F' -- "$m" 2>/dev/null)" "$LEDGER_OWNER" 600 "regular file" "$m")"
  if [ -n "$p" ]; then
    bad "원장 파일이 계약 v1과 다르다:"$'\n'"${p}"
    return
  fi
  read_exact out as_root cat -- "$m" 2>/dev/null || out=""
  if ledger_marker_ok "$out"; then
    ok "원장 파일 ${LEDGER_FILE}·${LEDGER_MARKER}(${LEDGER_OWNER} 0600), 표식 형식 v1"
  else
    bad "${m}가 원장 계약 v1의 한 줄 형식이 아니다"
  fi
}

# 실패가 하나라도 있으면 1, 실패 없이 미검증이 있으면 2, 모두 확인했을 때만 0.
finish() {
  if [ "$FAILS" -gt 0 ]; then
    die "verify: ${FAILS}개 실패"
  fi
  if [ "$UNVERIFIED" -gt 0 ]; then
    printf 'UNVERIFIED: verify: 실패 0, 미검증 %s개. 통과가 아니다(종료 코드 2)\n' "$UNVERIFIED" >&2
    exit 2
  fi
  log "verify 통과"
}

# tools/host-egress.test.sh(check_egress·finish), tools/host-k3s.test.sh(check_san·check_inotify), tools/host-sandbox-profiles.test.sh(check_sandbox_profiles),
# tools/host-task-state.test.sh(check_task_state_volume)가 source한다. 그때는 main을 돌리지 않는다.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
