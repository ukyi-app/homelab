#!/usr/bin/env bash
# k3s 설치 앞뒤의 호스트 불변식 확인. 읽기만 하고 sudo 없이 실행한다(C.3.2 1·2번).
#
# 사용: host/preflight.sh --cluster <이름> --before|--after
#   --before  설치 전. 노드 IP가 host/clusters/<이름>.env와 같음, k3s 잔여 경로 부재.
#             타임존·DNS·스왑은 여기서 보지 않는다. 그 값은 install.sh --host-config가 적용하므로,
#             새 VM이나 다시 설치한 호스트가 여기서 멈추면 그 단계에 닿지 못한다.
#   --after   install.sh --host-config 뒤. 스왑 없음, 타임존, systemd-resolved 스텁 꺼짐,
#             /etc/resolv.conf가 loopback·tailnet·자기 주소가 아님, 링크가 DHCP DNS를 거부.
# 항목을 모두 돌고 실패를 모두 출력한 뒤 하나라도 실패면 exit 1이다. 그러면 다음 단계로 가지 않는다.
# 옛 host-preflight.sh:42-216의 6항목을 두 시점으로 나눴다.
set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FAILS=0
ok() { printf 'ok   %s\n' "$*"; }
bad() {
  printf 'FAIL %s\n' "$*" >&2
  FAILS=$((FAILS + 1))
}

usage() { die "사용: host/preflight.sh --cluster <이름> --before|--after"; }

# ---------------------------------------------------------------------------- --before

check_node_ip() {
  local addrs
  if [ ! -e "/sys/class/net/${NODE_IFACE}" ]; then
    bad "인터페이스 ${NODE_IFACE}가 없다(clusters/${CLUSTER}.env NODE_IFACE)"
    return
  fi
  addrs="$(iface_ipv4s)" || addrs=""
  if grep -qxF -- "$NODE_IP" <<<"$addrs"; then
    ok "노드 IP ${NODE_IP}가 ${NODE_IFACE}에 있다"
  else
    bad "노드 IP ${NODE_IP}가 ${NODE_IFACE}에 없다(지금: ${addrs//$'\n'/ }). 이 주소로 k3s가 뜨지 못한다"
  fi
  # node-ip는 설치 때만 정할 수 있어 공유기 DHCP 예약이 전제다. 예약은 스크립트가 볼 수 없다.
  printf '     사람 확인: 공유기 DHCP 예약이 %s를 이 기기에 고정하는가\n' "$NODE_IP"
}

# sudo 없이 경로 유무를 판정한다. 상위 디렉터리를 지날 권한이 없으면 test -e가 "없음"으로 답해
# 잔여물을 놓친다. 그때는 판정 불가로 실패시키고 사람이 sudo test로 본다.
path_state() {
  local p="$1" d="$1"
  if [ -e "$p" ] || [ -L "$p" ]; then
    echo present
    return
  fi
  while [ "$d" != "/" ]; do
    d="$(dirname "$d")"
    if [ -e "$d" ] && [ ! -x "$d" ]; then
      echo unknown
      return
    fi
  done
  echo absent
}

# k3s-uninstall.sh는 /var/lib/rancher/k3s만 지우고 옛 PV 데이터(k3s-storage)를 남긴다. 옛 datastore나
# PV 위에 새 k3s를 깔면 옛 워크로드가 옛 데이터로 살아나 "Git에서 복귀"로 오독한다(B.8 E1).
check_residue() {
  local p
  for p in /var/lib/rancher/k3s /var/lib/rancher/k3s-storage /etc/rancher/k3s; do
    case "$(path_state "$p")" in
      absent) ok "k3s 잔여 경로 없음: ${p}" ;;
      present) bad "k3s 잔여 경로가 있다: ${p}. 지우는 것은 사람 작업이다(k3s-uninstall.sh와 잔여 삭제 뒤 sudo test ! -e로 확인)" ;;
      *) bad "${p}의 상위 디렉터리를 지날 권한이 없어 판정하지 못했다. sudo test ! -e ${p}로 확인한다" ;;
    esac
  done
}

# ----------------------------------------------------------------------------- --after

# 스왑은 OOM으로 죽어야 할 파드를 느리게만 만들어 실패가 늦게 드러난다(H6).
# 세 갈래가 각각 다른 실패다. 지금 켜짐, fstab으로 재부팅 때 돌아옴, zram으로 돌아옴.
check_swap() {
  local hdr n fs_n z found=""
  if [ ! -r /proc/swaps ]; then
    bad "/proc/swaps를 읽지 못했다"
  else
    # 커널은 스왑이 0개여도 헤더 한 줄을 낸다. 헤더가 없으면 "스왑 없음"이 아니라 파싱 실패다.
    hdr="$(awk 'NR == 1 { print $1 }' /proc/swaps)"
    n="$(awk 'NR > 1 && NF { n++ } END { print n + 0 }' /proc/swaps)"
    if [ "$hdr" != "Filename" ]; then
      bad "/proc/swaps 첫 줄이 헤더가 아니다. 형식이 달라 스왑 0개를 믿을 수 없다"
    elif [ "$n" -ne 0 ]; then
      bad "활성 스왑이 ${n}개 있다. install.sh --host-config가 swapoff를 했는지 본다"
    else
      ok "활성 스왑 없음"
    fi
  fi
  # 주석 줄(#/swap.img none swap ...)을 세지 않게 첫 필드의 #을 거른다. 부분 일치(swap 문자열)는
  # noswap 같은 정상 마운트 옵션에 걸리므로 셋째 필드(type)만 본다.
  fs_n="$(awk 'NF && $1 !~ /^#/ && $3 == "swap" { n++ } END { print n + 0 }' /etc/fstab)"
  if [ "$fs_n" -eq 0 ]; then
    ok "fstab에 swap 항목 없음"
  else
    bad "fstab에 swap 항목이 ${fs_n}개 있다. 재부팅하면 스왑이 돌아온다"
  fi
  for z in /etc/systemd/zram-generator.conf /etc/systemd/zram-generator.conf.d/*.conf; do
    [ -e "$z" ] && found+=" ${z}"
  done
  if [ -z "$found" ]; then
    ok "zram 설정 없음"
  else
    bad "zram 설정이 있다:${found}. 재부팅하면 스왑이 돌아온다"
  fi
}

# 진실원은 /etc/localtime 심링크다. Ubuntu 26.04에는 /etc/timezone이 없다.
check_timezone() {
  local target
  if [ ! -L /etc/localtime ]; then
    bad "/etc/localtime이 심링크가 아니다. sudo timedatectl set-timezone ${TIMEZONE}"
    return
  fi
  target="$(readlink /etc/localtime)"
  if [ "${target##*/zoneinfo/}" = "$TIMEZONE" ] && [ "$target" != "${target##*/zoneinfo/}" ]; then
    ok "타임존 ${TIMEZONE}"
  else
    bad "타임존이 ${TIMEZONE}가 아니다(/etc/localtime -> ${target}). CronJob 일정이 밀린다"
  fi
}

# 스텁이 켜져 있으면 노드 질의가 127.0.0.53으로 가고, portmap DNAT가 그것을 AdGuard 파드로 끈다.
# 설정 파일(재부팅 뒤에도 꺼짐)과 지금의 리스너(지금 꺼짐)를 따로 본다.
check_stub() {
  local f v="" line listen
  for f in /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d/*.conf; do
    [ -r "$f" ] || continue
    line="$(sed -n 's/^[[:space:]]*DNSStubListener[[:space:]]*=[[:space:]]*//p' "$f" | tail -n 1)"
    [ -z "$line" ] || v="$line"
  done
  case "${v,,}" in
    no | false | off | 0) ok "DNSStubListener=${v} (설정)" ;;
    *) bad "DNSStubListener가 꺼져 있지 않다(설정 값: ${v:-없음, 기본 yes})" ;;
  esac
  if ! listen="$(ss -Hlnu 2>/dev/null && ss -Hlnt 2>/dev/null)"; then
    bad "ss로 :53 리스너를 읽지 못했다"
    return
  fi
  # awk | grep -q로 잇지 않는다. grep -q가 먼저 끝나면 awk가 SIGPIPE로 죽고 pipefail이
  # 그것을 실패로 읽어 "리스너 없음"이 된다. 출력을 먼저 다 받은 뒤 grep에 넘긴다.
  listen="$(awk '{ print $4 }' <<<"$listen")"
  if grep -Eq '^127\.0\.0\.5[34](%[^:]+)?:53$' <<<"$listen"; then
    bad "systemd-resolved 스텁(127.0.0.53/54:53)이 지금 듣고 있다. systemctl restart systemd-resolved가 필요하다"
  else
    ok "스텁 리스너 없음"
  fi
}

# loopback은 portmap DNAT에 걸린다. tailnet 주소(100.100.100.100 등)는 MagicDNS를 거쳐 tailnet
# 전역 nameserver, 곧 이 클러스터의 AdGuard로 간다. 노드 자신의 주소는 노드에게 LOCAL이라 역시
# DNAT에 걸린다. 셋 다 노드 이름 해석을 클러스터에 묶어 콜드스타트 교착을 만든다.
check_resolv_conf() {
  local ns self a al total=0 problems=""
  if [ ! -r /etc/resolv.conf ]; then
    bad "/etc/resolv.conf를 읽지 못했다"
    return
  fi
  ns="$(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf)"
  self="$(ip -o addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print tolower($4) }')" || self=""
  if [ -z "$self" ]; then
    bad "인터페이스 주소를 읽지 못해 자기 주소 검사를 할 수 없다"
    return
  fi
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    total=$((total + 1))
    al="${a,,}"
    al="${al%%\%*}"
    case "$al" in
      127.* | ::1 | 0.0.0.0 | ::) problems+=" ${a}(loopback)" ;;
      # 100.64.0.0/10과 Tailscale ULA. 주소는 출력하지 않는다.
      100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].* | fd7a:115c:a1e0:*)
        problems+=" (tailnet 주소)" ;;
      *) if grep -qxF -- "$al" <<<"$self"; then problems+=" ${a}(자기 주소)"; fi ;;
    esac
  done <<<"$ns"
  # nameserver 줄이 0개면 위 반복이 한 번도 돌지 않고 통과해 버린다. 0개는 실패다.
  if [ "$total" -eq 0 ]; then
    bad "/etc/resolv.conf에 nameserver가 없다"
  elif [ -n "$problems" ]; then
    bad "/etc/resolv.conf nameserver가 클러스터에 묶인다:${problems}"
  else
    ok "/etc/resolv.conf nameserver ${total}개, loopback·tailnet·자기 주소 아님"
  fi
}

# networkd drop-in은 설치만 하고 reconfigure하지 않으면 잠들어 있다. 그동안 링크는 DHCP DNS를
# 받고 그 값이 전역 DNS=보다 우선한다. 파일 내용이 아니라 networkd가 링크에 적용한 상태를 본다.
check_link_dns() {
  local lf dns dropins p expected
  if ! lf="$(link_state_file)"; then
    FAILS=$((FAILS + 1))
    return
  fi
  if [ ! -r "$lf" ]; then
    bad "링크 상태 파일 ${lf}가 없다. networkd가 ${NODE_IFACE}를 관리하지 않으면 drop-in이 쓰이지 않는다"
    return
  fi
  # 키가 없는 것을 "값 없음"으로 읽지 않는다. 형식이 바뀐 것일 수 있다.
  if ! grep -q '^DNS=' "$lf" || ! grep -q '^NETWORK_FILE_DROPINS=' "$lf"; then
    bad "${lf}에 DNS= 또는 NETWORK_FILE_DROPINS= 키가 없다. 형식이 달라 링크 DNS를 믿을 수 없다"
    return
  fi
  dns="$(sed -n 's/^DNS=//p' "$lf")"
  dns="${dns//\"/}"
  if [ -z "$dns" ]; then
    ok "${NODE_IFACE} 링크 DNS 비어 있음"
  else
    bad "${NODE_IFACE} 링크가 DNS를 받고 있다(${dns}). 링크 DNS는 전역 DNS=보다 우선한다. sudo networkctl reconfigure ${NODE_IFACE}"
  fi
  dropins="$(sed -n 's/^NETWORK_FILE_DROPINS=//p' "$lf")"
  dropins="${dropins//\"/}"
  expected="$(network_dropin_targets)"
  if [ -z "$expected" ]; then
    bad "host/etc/에 networkd drop-in이 없다"
    return
  fi
  # 지금 DNS가 비어 있어도 drop-in이 안 실렸으면 DHCP 갱신 때 다시 채워진다.
  while IFS= read -r p; do
    case " ${dropins} " in
      *" ${p} "*) ok "${NODE_IFACE}에 drop-in 로드됨: ${p}" ;;
      *) bad "${NODE_IFACE}에 drop-in이 로드되지 않았다: ${p} (로드됨: ${dropins:-없음})" ;;
    esac
  done <<<"$expected"
}

# ------------------------------------------------------------------------------ main

main() {
  local cluster="" mode=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --cluster) [ "$#" -ge 2 ] || usage; cluster="$2"; shift 2 ;;
      --before | --after) [ -z "$mode" ] || usage; mode="$1"; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$cluster" ] && [ -n "$mode" ] || usage
  load_cluster "$cluster"
  require_cmds ip awk sed grep ss

  log "preflight ${mode} (cluster=${CLUSTER}, node=${NODE_NAME})"
  case "$mode" in
    --before)
      check_node_ip
      check_residue
      ;;
    --after)
      check_swap
      check_timezone
      check_stub
      check_resolv_conf
      check_link_dns
      ;;
  esac

  if [ "$FAILS" -gt 0 ]; then
    die "preflight ${mode}: ${FAILS}개 실패. 다음 단계로 가지 않는다"
  fi
  log "preflight ${mode} 통과"
}

main "$@"
