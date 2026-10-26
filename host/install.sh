#!/usr/bin/env bash
# 호스트 설정 적용과 k3s 설치. 사람이 sudo로 한 단계씩 실행한다(C.3.2 2·3번).
#
# 사용:
#   sudo host/install.sh --cluster <이름> --host-config
#   sudo host/install.sh --cluster <이름> --egress
#   sudo host/install.sh --cluster <이름> --k3s
#   sudo host/install.sh --cluster <이름> --egress-off   (되돌리기: 파드 egress 규칙을 끄고 지운다)
#
# 순서가 계약이다: preflight --before -> install --host-config -> preflight --after
#   -> install --egress -> install --k3s -> verify. sudo 단계를 한 파이프라인이나 다른 스크립트로 잇지 않는다.
#   sudo는 비밀번호를 묻는 대화형 단계이고, 사람이 단계마다 결과를 보고 넘어간다(옛 host-up.sh:5-14).
#   --egress를 --k3s보다 먼저 두는 까닭: 첫 파드부터 규칙 아래서 뜬다. 이미 도는 클러스터에는 --egress만
#   따로 실행해도 된다(k3s를 다시 시작하지 않는다). --host-config에 넣지 않은 까닭: 그 단계는 networkd를
#   재구성해 링크가 끊길 수 있고 끄는 짝이 없다. egress는 켜고 끄는 한 쌍이 되돌리기 한 명령이어야 한다.
# 각 모드는 확인을 모두 먼저 하고, 하나라도 실패하면 아무것도 바꾸지 않고 멈춘다.
# 실패를 파이프나 || true로 삼키지 않는다. 옛 bootstrap.sh는 helm 실패를 삼키고 성공을 찍었다(L21).
#
# 다시 실행해도 된다. --host-config는 같은 파일을 다시 쓰고, --k3s는 같은 config로 다시 설치한다.
# k3s 업그레이드는 host/versions.env의 INSTALL_K3S_VERSION을 올린 뒤 --k3s를 다시 실행한다[S51].
set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

K3S_CONFIG=/etc/rancher/k3s/config.yaml
K3S_MANIFESTS=/var/lib/rancher/k3s/server/manifests
K3S_BIN=/usr/local/bin/k3s
NET_WAIT_MAX=30
TMPD=""
TARGETS=""
NET_DROPINS=""
KUBECONFIG_OUT=""

usage() { die "사용: sudo host/install.sh --cluster <이름> --host-config|--egress|--k3s|--egress-off"; }
cleanup() { [ -z "$TMPD" ] || rm -rf "$TMPD"; }
trap cleanup EXIT

# ------------------------------------------------------------------------ --host-config

# resolved drop-in의 DNS= 줄은 정확히 하나이고 NODE_UPSTREAM_DNS와 같아야 한다. 같은 키를 두 번
# 적으면 덮어쓰지 않고 이어 붙어 앞줄이 1순위가 된다(옛 공유기 교착과 같은 종류).
check_dns_dropin() {
  local f="$HOST_DIR/etc/systemd/resolved.conf.d/10-k3s-node.conf" lines
  [ -f "$f" ] || die "resolved drop-in이 없다: ${f}"
  lines="$(grep -E '^[[:space:]]*DNS[[:space:]]*=' "$f" || true)"
  [ "$lines" = "DNS=${NODE_UPSTREAM_DNS}" ] \
    || die "resolved drop-in의 DNS= 줄이 versions.env NODE_UPSTREAM_DNS(${NODE_UPSTREAM_DNS})와 다르거나 하나가 아니다: ${lines:-없음}"
}

# sshd_config.d는 키마다 먼저 읽힌 값이 이긴다. 우리 파일보다 사전순으로 앞선 .conf가 있으면
# 하드닝이 조용히 진다.
check_sshd_order() {
  local ours o c sorted earlier=""
  ours="$(awk -F '\t' '$2 ~ /^\/etc\/ssh\/sshd_config\.d\// { print $2 }' <<<"$TARGETS")"
  [ -n "$ours" ] || return 0
  for c in /etc/ssh/sshd_config.d/*.conf; do
    [ -e "$c" ] || continue
    if grep -qxF -- "$c" <<<"$ours"; then continue; fi
    while IFS= read -r o; do
      # 로케일 정렬은 -와 숫자 순서가 다를 수 있다. 바이트 순서로 비교한다.
      sorted="$(printf '%s\n%s\n' "$(basename "$c")" "$(basename "$o")" | LC_ALL=C sort)"
      if [ "${sorted%%$'\n'*}" = "$(basename "$c")" ]; then earlier+=" ${c}"; fi
    done <<<"$ours"
  done
  [ -z "$earlier" ] || die "sshd drop-in보다 사전순으로 앞선 파일이 있다:${earlier}. 먼저 읽힌 값이 이겨 하드닝이 무력화된다"
}

# networkd drop-in 디렉터리 이름이 링크가 실제로 쓰는 .network 파일 이름과 맞아야 한다.
# 다르면 파일을 깔아도 조용히 무효다(netplan 아닌 호스트, 인터페이스 이름 오타).
check_network_target() {
  local lf netfile want d
  lf="$(link_state_file)"
  [ -r "$lf" ] || die "링크 상태 파일 ${lf}가 없다. networkd가 ${NODE_IFACE}를 관리하지 않는다"
  netfile="$(sed -n 's/^NETWORK_FILE=//p' "$lf")"
  [ -n "$netfile" ] || die "${NODE_IFACE}에 적용된 .network 파일이 없다(${lf})"
  want="$(basename "$netfile").d"
  # 목록을 먼저 받아 비었는지 본다. < <(...)로 바로 읽으면 만드는 쪽이 실패해도 반복이 0번 돌고 통과한다.
  NET_DROPINS="$(network_dropin_targets)"
  [ -n "$NET_DROPINS" ] || die "host/etc/에 networkd drop-in이 없다"
  while IFS= read -r d; do
    d="$(basename "$(dirname "$d")")"
    [ "$d" = "$want" ] || die "networkd drop-in 디렉터리(${d})가 ${NODE_IFACE}의 .network(${netfile})와 맞지 않는다"
  done <<<"$NET_DROPINS"
  grep -qxF -- "$NODE_IP" <<<"$(iface_ipv4s)" \
    || die "노드 IP ${NODE_IP}가 ${NODE_IFACE}에 없다. preflight --before부터 다시 본다"
}

# if 조건 안에서 불리므로 set -e가 꺼진다. 실패는 모두 직접 1로 돌려준다(그러면 reconfigure한다).
dropins_loaded() {
  local lf dropins p
  [ -n "$NET_DROPINS" ] || return 1
  lf="$(link_state_file)" || return 1
  [ -r "$lf" ] || return 1
  dropins="$(sed -n 's/^NETWORK_FILE_DROPINS=//p' "$lf")" || return 1
  dropins="${dropins//\"/}"
  while IFS= read -r p; do
    case " ${dropins} " in *" ${p} "*) ;; *) return 1 ;; esac
  done <<<"$NET_DROPINS"
}

# reconfigure 뒤 링크가 다시 섰는지 두 가지를 함께 본다. networkd 판정(configured)은 주소 없이도
# 나올 수 있고, 주소는 networkd가 아직 configuring일 때 먼저 붙을 수 있다.
net_settled() {
  local setup
  setup="$(networkctl --no-legend list "$NODE_IFACE" 2>/dev/null | awk '{ print $5 }')" || return 1
  [ "$setup" = "configured" ] || return 1
  grep -qxF -- "$NODE_IP" <<<"$(iface_ipv4s)"
}

# drop-in이 실리고 링크가 다시 설 때까지 NET_WAIT_MAX초 기다린다. 넘으면 1을 돌려준다.
wait_net() {
  local i=0
  until dropins_loaded && net_settled; do
    [ "$i" -lt "$NET_WAIT_MAX" ] || return 1
    sleep 1
    i=$((i + 1))
  done
  echo "    ${1} 뒤 ${NODE_IP} 복귀, drop-in 실림(${i}초)"
}

remove_fstab_swap() {
  local bak tmp
  # 주석 줄(#/swap.img ...)은 건드리지 않게 첫 필드의 #을 거르고, 셋째 필드(type)만 본다.
  if ! awk 'NF && $1 !~ /^#/ && $3 == "swap" { f = 1 } END { exit !f }' /etc/fstab; then
    echo "    fstab에 swap 항목 없음"
    return
  fi
  bak="/etc/fstab.pre-host-install.$(date +%Y%m%d%H%M%S)"
  cp -p /etc/fstab "$bak"
  tmp="$TMPD/fstab"
  awk 'NF && $1 !~ /^#/ && $3 == "swap" { next } { print }' /etc/fstab >"$tmp"
  install -m 0644 -o root -g root "$tmp" /etc/fstab
  echo "    fstab에서 swap 항목을 지웠다(백업 ${bak})"
}

host_config() {
  local src dest net_changed=0 i
  local -a sshd_new=()

  log "확인"
  TARGETS="$(etc_targets)"
  check_dns_dropin
  check_sshd_order
  check_network_target
  if [ "$TAILNET_JOIN" = "true" ]; then
    resolve_magicdns
  else
    assert_not_in_tailnet
  fi
  require_cmds systemctl networkctl timedatectl systemd-tmpfiles sshd swapoff

  log "[1/7] host/etc 파일 복사(0644 root:root)"
  while IFS=$'\t' read -r src dest; do
    case "$dest" in
      /etc/systemd/network/*) cmp -s "$src" "$dest" || net_changed=1 ;;
      /etc/ssh/sshd_config.d/*)
        # sshd -t가 실패하면 되돌리려고 이전 파일을 남긴다. sshd를 재시작하기 전이라 접속은 그대로다.
        i="${#sshd_new[@]}"
        if [ -e "$dest" ]; then cp -p "$dest" "$TMPD/sshd.$i"; fi
        sshd_new+=("$dest")
        ;;
    esac
    install -D -m 0644 -o root -g root "$src" "$dest"
    echo "    ${dest}"
  done <<<"$TARGETS"

  # 복사 바로 뒤에 본다. 뒤 단계가 set -e로 끝나면 EXIT trap이 백업을 지워, 검증 안 된 sshd
  # drop-in이 되돌릴 길 없이 남고 다음 재부팅 때 LAN sshd가 뜨지 않는다.
  if ! sshd -t; then
    for i in "${!sshd_new[@]}"; do
      if [ -e "$TMPD/sshd.$i" ]; then
        install -m 0644 -o root -g root "$TMPD/sshd.$i" "${sshd_new[$i]}"
      else
        rm -f "${sshd_new[$i]}"
      fi
    done
    die "sshd -t가 실패했다. 이번에 바꾼 sshd drop-in을 이전 상태로 되돌렸다. sshd는 재시작하지 않았다"
  fi

  log "[2/7] 스왑 끄기(H6)"
  swapoff -a
  remove_fstab_swap

  log "[3/7] 타임존 ${TIMEZONE}"
  # 파일로 쓰지 않는다. /etc/timezone은 Ubuntu 26.04에 없고 진실원은 /etc/localtime 심링크다.
  timedatectl set-timezone "$TIMEZONE"

  log "[4/7] Tailscale DNS 받지 않기"
  if [ "$TAILNET_JOIN" = "true" ]; then
    # tailscale의 ~. 라우팅이 노드의 모든 질의를 MagicDNS로 가져가고, 그 뒤는 tailnet 전역
    # nameserver(이 클러스터의 AdGuard)다. 이 기기에만 걸리고 tailnet 설정은 바꾸지 않는다.
    # OS를 다시 설치해 tailnet에 다시 등록했으면 이 값도 다시 걸어야 한다(H5).
    tailscale set --accept-dns=false
  else
    echo "    TAILNET_JOIN=false라 건너뛴다"
  fi

  log "[5/7] /etc/resolv.conf를 resolved의 업스트림 목록으로"
  # 스텁을 끄면 127.0.0.53 파일이 생기지 않는다. 그대로 두면 이름 해석이 통째로 죽는다.
  ln -sfn ../run/systemd/resolve/resolv.conf /etc/resolv.conf

  log "[6/7] 서비스 반영"
  # 재부팅을 요구하면 "적용했다"가 거짓이 된다. 지금 상태를 만든다.
  while IFS=$'\t' read -r src dest; do
    case "$dest" in /etc/tmpfiles.d/*) systemd-tmpfiles --create "$dest" ;; esac
  done <<<"$TARGETS"
  systemctl daemon-reload
  systemctl restart systemd-resolved
  systemctl restart systemd-journald
  # 소켓 활성화(ssh.socket)면 연결마다 설정을 새로 읽으므로 이 줄은 아무 일도 하지 않는다.
  systemctl try-reload-or-restart ssh.service

  log "[7/7] networkd drop-in 적용(${NODE_IFACE})"
  # systemd 259의 reload는 내용이 바뀐 .network(drop-in 포함)를 쓰는 링크를 스스로 재구성한다.
  # 그 뒤 reconfigure를 또 부르면 운영 Wi-Fi 링크가 두 번 끊긴다. 그래서 reload 뒤 drop-in이 실리고
  # 링크가 다시 설 때까지 기다리고, 상한까지 안 실렸을 때만 reconfigure한다. 재구성 동안 DHCP를
  # 다시 받아 NODE_IP가 약 2초 사라지므로, 다음 단계가 그 틈을 밟지 않게 복귀를 기다린 뒤 끝낸다.
  networkctl reload
  if [ "$net_changed" -eq 0 ] && dropins_loaded && net_settled; then
    echo "    drop-in이 이미 같은 내용으로 실려 있다. 재구성하지 않는다"
  else
    echo "    reload가 ${NODE_IFACE}를 재구성한다: ${NODE_IP}가 잠시 사라졌다 돌아온다"
    # drop-in 파일 이름이 옛 것과 같아 링크 상태 파일만으로는 새 내용이 실렸는지 가를 수 없다.
    # 재구성이 시작되기 전의 "이미 선 상태"를 복귀로 읽지 않게 잠깐 기다린 뒤 본다.
    sleep 3
    wait_net "reload" || {
      echo "    reload 뒤 drop-in이 실리지 않았다. networkctl reconfigure ${NODE_IFACE}"
      networkctl reconfigure "$NODE_IFACE"
      wait_net "reconfigure" \
        || die "${NET_WAIT_MAX}초 안에 drop-in이 실린 채 ${NODE_IP}가 ${NODE_IFACE}로 돌아오지 않았다. networkctl status ${NODE_IFACE}와 공유기 DHCP 예약을 본다"
    }
  fi

  log "호스트 설정 완료. 다음: host/preflight.sh --cluster ${CLUSTER} --after"
}

# ------------------------------------------------------------------------------ --egress

# 커널에 올라간 표가 기대한 모양인지 본다: forward hook 체인 하나, 파드 대역만 pod_egress로 넘김,
# pod_egress의 첫 줄은 established 허용, 마지막 줄은 drop. 실패는 1로 돌려준다.
check_egress_kernel() {
  local js
  js="$(nft -j list table inet "$EGRESS_TABLE" 2>/dev/null)" || return 1
  jq -e --arg pod "$POD_CIDR" '
    [.nftables[] | .chain? // empty] as $c
    | [.nftables[] | .rule? // empty] as $r
    | [$r[] | select(.chain == "pod_egress")] as $p
    | ([$c[] | select(.hook == "forward")] | length) == 1
      and ([$r[] | select(.chain == "forward") | .expr | tostring] | length) == 1
      and ([$r[] | select(.chain == "forward") | .expr[] | .jump?.target // empty] == ["pod_egress"])
      and ([$r[] | select(.chain == "forward") | .expr[] | .match?.right.prefix? // empty
            | "\(.addr)/\(.len)"] == [$pod])
      and ($p | length) >= 2
      and ($p[0].expr | any(.match?.left.ct?.key == "state"))
      and ($p[-1].expr | any(has("drop")))
  ' <<<"$js" >/dev/null
}

egress_on() {
  local rules

  log "확인"
  require_cmds nft systemctl install
  # 노드 IP 허용과 대역 검사가 이 값에서 온다. 다른 호스트의 값 파일로 돌리면 여기서 멈춘다.
  grep -qxF -- "$NODE_IP" <<<"$(iface_ipv4s)" \
    || die "노드 IP ${NODE_IP}가 ${NODE_IFACE}에 없다. --cluster 값이 이 호스트의 것인지 본다"
  rules="$(render_egress)"
  printf '%s\n' "$rules" >"$TMPD/egress.nft"
  # -c는 같은 트랜잭션을 커널에 검사만 시킨다. 문법·커널 지원이 틀리면 아무것도 바꾸기 전에 멈춘다.
  nft -c -f "$TMPD/egress.nft" || die "nft -c가 렌더한 규칙을 거부했다. 아무것도 바꾸지 않았다"
  echo "    렌더한 값: node ${NODE_IP}, pod ${POD_CIDR}, service ${SERVICE_CIDR}, dns ${NODE_UPSTREAM_DNS}"

  log "[1/3] 규칙·유닛 파일 쓰기"
  install -d -m 0755 -o root -g root "$(dirname "$EGRESS_RULES")"
  install -m 0644 -o root -g root "$TMPD/egress.nft" "$EGRESS_RULES"
  install -m 0644 -o root -g root "$HOST_DIR/egress/${EGRESS_UNIT_NAME}" "$EGRESS_UNIT"
  echo "    ${EGRESS_RULES}"
  echo "    ${EGRESS_UNIT}"

  log "[2/3] ${EGRESS_UNIT_NAME} 켜기"
  systemctl daemon-reload
  systemctl enable "$EGRESS_UNIT_NAME"
  # restart를 쓰지 않는다. ExecStop이 표를 지운 뒤 다시 올려서 그 사이 규칙이 빈다.
  # 켜져 있으면 reload가 파일로 표를 통째 바꾼다(빈 순간 없음).
  if systemctl is-active --quiet "$EGRESS_UNIT_NAME"; then
    systemctl reload "$EGRESS_UNIT_NAME"
  else
    systemctl start "$EGRESS_UNIT_NAME"
  fi

  log "[3/3] 커널 규칙 확인"
  check_egress_kernel \
    || die "커널의 table inet ${EGRESS_TABLE}가 기대와 다르다. sudo nft list table inet ${EGRESS_TABLE}로 본다. 끄기: sudo host/install.sh --cluster ${CLUSTER} --egress-off"
  nft list table inet "$EGRESS_TABLE"

  log "파드 egress 규칙 적용 완료"
  echo "    막힌 연결: journalctl -k -g homelab-egress (분당 10건까지 기록)"
  echo "    되돌리기: sudo host/install.sh --cluster ${CLUSTER} --egress-off"
  echo "    다음: k3s가 없으면 --k3s, 이미 돌면 host/verify.sh --cluster ${CLUSTER} (sudo 없이)"
}

egress_off() {
  local dir

  log "확인"
  require_cmds nft systemctl

  log "[1/2] ${EGRESS_UNIT_NAME} 끄고 지우기"
  if [ -e "$EGRESS_UNIT" ]; then
    # --now가 ExecStop으로 표를 지운다.
    systemctl disable --now "$EGRESS_UNIT_NAME"
  fi
  # 유닛이 없었거나 ExecStop이 실패했어도 표가 남지 않게 한 번 더 본다.
  if nft list table inet "$EGRESS_TABLE" >/dev/null 2>&1; then
    nft delete table inet "$EGRESS_TABLE"
  fi
  rm -f "$EGRESS_UNIT" "$EGRESS_RULES"
  dir="$(dirname "$EGRESS_RULES")"
  if [ -d "$dir" ]; then rmdir --ignore-fail-on-non-empty "$dir"; fi
  systemctl daemon-reload

  log "[2/2] 확인"
  if nft list table inet "$EGRESS_TABLE" >/dev/null 2>&1; then
    die "table inet ${EGRESS_TABLE}가 아직 있다"
  fi
  log "파드 egress 규칙을 껐다"
  echo "    지금은 NetworkPolicy만 남았다. 새 파드는 시작 직후 약 1초 동안 egress가 열린다(설계 B.8 E5)."
  echo "    host/verify.sh는 egress 항목에서 실패한다. 다시 켜기: sudo host/install.sh --cluster ${CLUSTER} --egress"
}

# --------------------------------------------------------------------------------- --k3s

# node-name, node-ip, tls-san은 설치 때만 정할 수 있다. 이미 깔린 config와 이 셋이 다르면
# 다시 설치해도 반영되지 않고(노드 재등록, serving cert 재발급 필요) hostPath PV의 nodeAffinity가
# 깨질 수 있다. 그때는 멈추고 사람이 k3s-uninstall.sh부터 다시 한다.
check_install_time_keys() {
  # grep -E는 \t를 탭으로 읽지 않는다. 진짜 탭 문자를 넣는다.
  local new_cfg="$1" filter=$'^--(node-name|node-ip|tls-san)\t' old new
  [ -e "$K3S_CONFIG" ] || return 0
  old="$(config_pairs <"$K3S_CONFIG" | grep -E "$filter" || true)"
  new="$(config_pairs <<<"$new_cfg" | grep -E "$filter" || true)"
  [ "$old" = "$new" ] \
    || die "기존 ${K3S_CONFIG}와 node-name/node-ip/tls-san이 다르다. 설치 뒤에는 바꿀 수 없다. k3s-uninstall.sh와 잔여 경로 삭제 뒤 preflight --before부터 다시 한다"
}

write_user_kubeconfig() {
  local user home group dest tmp before after
  # sudo로 실행했으면 그 사람의 홈에 쓴다. 저장소 안에는 쓰지 않는다(공개 저장소, cluster-admin 자격).
  user="${SUDO_USER:-root}"
  home="$(getent passwd "$user" | cut -d: -f6)" || die "사용자 ${user}를 찾지 못했다"
  group="$(id -gn "$user")" || die "사용자 ${user}의 그룹을 찾지 못했다"
  if [ -z "$home" ] || [ ! -d "$home" ]; then
    die "${user}의 홈 디렉터리를 찾지 못했다"
  fi
  dest="${home}/.kube/${KUBE_CONTEXT}.yaml"
  tmp="$TMPD/kubeconfig"
  install -m 0600 /etc/rancher/k3s/k3s.yaml "$tmp"

  # k3s 기본 kubeconfig는 context, cluster, user 이름이 모두 default다. 두 클러스터(prod, vm)가
  # 공존하면 경로, 포트, 이름이 같아 KUBECONFIG를 잘못 고르면 조용히 반대편을 조작한다(B.8 E2).
  # 6개 이름 칸에 KUBE_CONTEXT를 각인한다. 칸을 줄 앞부터 고정해 namespace: default 같은 자리는 두고,
  # sed는 0건 치환도 성공으로 끝나므로 앞뒤 개수를 센다.
  before="$(grep -cE '^(  name|- name|    cluster|    user|current-context): default$' "$tmp" || true)"
  [ "$before" = "6" ] || die "k3s.yaml 모양이 예상과 다르다(default 이름 칸 ${before}개, 기대 6)"
  sed -i -E \
    -e "s/^(  name|- name|    cluster|    user|current-context): default\$/\\1: ${KUBE_CONTEXT}/" \
    "$tmp"
  after="$(grep -cE "^(  name|- name|    cluster|    user|current-context): ${KUBE_CONTEXT}\$" "$tmp" || true)"
  [ "$after" = "6" ] || die "kubeconfig 이름 각인이 ${after}칸만 됐다(기대 6)"
  # server는 127.0.0.1 그대로 둔다. k3s와 tailscaled 사이에 순서가 없어 부팅 직후 tailscale0이
  # 없는 때가 있다. 운영자 기기 사본만 server를 MagicDNS 이름으로 바꾼다(SAN에 있음).

  if [ ! -d "${home}/.kube" ]; then
    install -d -m 0700 -o "$user" -g "$group" "${home}/.kube"
  fi
  install -m 0600 -o "$user" -g "$group" "$tmp" "$dest"
  KUBECONFIG_OUT="$dest"
}

k3s_install() {
  local cfg pairs url installer f ver i restart

  log "확인"
  # 2번이 끝났는지 다시 본다. 실패하면 3번으로 가지 않는다(C.3.2).
  "$HOST_DIR/preflight.sh" --cluster "$CLUSTER" --after
  if [ "$TAILNET_JOIN" = "true" ]; then
    resolve_magicdns
  else
    assert_not_in_tailnet
  fi
  require_cmds curl install sh head
  cfg="$(render_k3s_config)"
  pairs="$(config_pairs <<<"$cfg")"
  if grep -q '^BAD' <<<"$pairs"; then
    die "host/k3s-config.yaml에 verify.sh가 대조할 수 없는 형식이 있다(평평한 키, 스칼라나 문자열 목록만)"
  fi
  check_install_time_keys "$cfg"
  echo "    렌더한 설정(플래그 형태):"
  mask "      ${pairs//$'\n'/$'\n'      }"
  echo

  # 설치 스크립트도 이 버전 태그의 것을 받는다. get.k3s.io는 늘 최신 스크립트다.
  # curl | sh로 잇지 않는다. 받은 파일을 확인한 뒤 실행한다.
  url="https://raw.githubusercontent.com/k3s-io/k3s/${INSTALL_K3S_VERSION}/install.sh"
  installer="$TMPD/k3s-install.sh"
  log "k3s 설치 스크립트 받기(${INSTALL_K3S_VERSION})"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$installer" "$url" \
    || die "설치 스크립트를 받지 못했다: ${url}"
  [ "$(head -c 2 "$installer")" = '#!' ] || die "받은 설치 스크립트가 셸 스크립트가 아니다: ${url}"

  log "${K3S_CONFIG} 쓰기(0600)"
  install -d -m 0755 /etc/rancher /etc/rancher/k3s
  printf '%s' "$cfg" >"$TMPD/config.yaml"
  # 설치 스크립트는 바이너리·유닛·env 파일 해시가 그대로면 k3s를 재시작하지 않는다. config.yaml은
  # 그 해시에 없어서, 다시 실행해 config만 바뀌면 재시작을 강제해야 새 값이 적용된다.
  restart=false
  if [ -e "$K3S_CONFIG" ] && ! cmp -s "$TMPD/config.yaml" "$K3S_CONFIG"; then
    restart=true
  fi
  install -m 0600 -o root -g root "$TMPD/config.yaml" "$K3S_CONFIG"

  log "k3s 자동 배포 매니페스트 쓰기(${K3S_MANIFESTS})"
  # k3s가 시작할 때마다 이 디렉터리를 다시 적용한다. local-retain StorageClass가 Argo CD보다 먼저 선다.
  install -d -m 0755 /var/lib/rancher /var/lib/rancher/k3s
  install -d -m 0700 /var/lib/rancher/k3s/server "$K3S_MANIFESTS"
  for f in "$HOST_DIR"/k3s-manifests/*.yaml; do
    [ -e "$f" ] || die "host/k3s-manifests/에 매니페스트가 없다"
    install -m 0600 -o root -g root "$f" "${K3S_MANIFESTS}/$(basename "$f")"
    echo "    ${K3S_MANIFESTS}/$(basename "$f")"
  done

  log "k3s ${INSTALL_K3S_VERSION} 설치"
  # 빈 환경으로 실행한다. 부르는 셸에 K3S_URL이 남아 있으면 agent로 깔리고, INSTALL_K3S_CHANNEL,
  # INSTALL_K3S_EXEC, K3S_* 값은 설치 스크립트가 k3s.service.env로 옮겨 적는다.
  # 플래그는 모두 config.yaml에 있다. 하위 명령은 기본값 server다.
  env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    INSTALL_K3S_VERSION="$INSTALL_K3S_VERSION" \
    INSTALL_K3S_FORCE_RESTART="$restart" \
    sh "$installer"

  log "API 준비 대기"
  i=0
  until "$K3S_BIN" kubectl get --raw=/readyz >/dev/null 2>&1; do
    [ "$i" -lt 90 ] || die "k3s API가 180초 안에 준비되지 않았다. journalctl -u k3s를 본다"
    sleep 2
    i=$((i + 1))
  done
  # k3s.service는 Restart=always라 크래시루프여도 failed가 되지 않는다. systemd 실패 감시로는
  # 못 보고, 평소 생존은 외부 생존 감시(Watchdog)가 본다.
  ver="$("$K3S_BIN" --version)"
  [[ "$ver" == *"$INSTALL_K3S_VERSION"* ]] || die "설치된 k3s 버전이 핀과 다르다: ${ver%%$'\n'*}"

  log "kubeconfig 쓰기"
  write_user_kubeconfig

  log "k3s 설치 완료"
  echo "    kubeconfig: ${KUBECONFIG_OUT} (context ${KUBE_CONTEXT}, 0600)"
  echo "    다음: KUBECONFIG=${KUBECONFIG_OUT} host/verify.sh --cluster ${CLUSTER} (sudo 없이)"
}

# ------------------------------------------------------------------------------ main

main() {
  local cluster="" mode=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --cluster) [ "$#" -ge 2 ] || usage; cluster="$2"; shift 2 ;;
      --host-config | --egress | --egress-off | --k3s) [ -z "$mode" ] || usage; mode="$1"; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$cluster" ] && [ -n "$mode" ] || usage
  [ "$(id -u)" -eq 0 ] || die "sudo로 실행한다: sudo host/install.sh --cluster ${cluster} ${mode}"
  load_cluster "$cluster"
  require_cmds jq awk sed grep ip cmp git
  # 되돌리기는 host/의 파일을 깔지 않는다. 급할 때 작업 사본이 더러워도 막지 않는다.
  [ "$mode" = "--egress-off" ] || assert_host_tree_clean
  TMPD="$(mktemp -d)"

  log "install ${mode} (cluster=${CLUSTER}, node=${NODE_NAME}, ip=${NODE_IP}, iface=${NODE_IFACE}, tailnet=${TAILNET_JOIN})"
  case "$mode" in
    --host-config) host_config ;;
    --egress) egress_on ;;
    --egress-off) egress_off ;;
    --k3s) k3s_install ;;
  esac
}

main "$@"
