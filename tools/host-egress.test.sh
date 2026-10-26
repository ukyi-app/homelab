#!/usr/bin/env bash
# 파드 egress 규칙(host/egress/, host/lib.sh render_egress) 시험.
#
#   bash tools/host-egress.test.sh          렌더 시험. ci가 부른다. root·nft 없이 돈다.
#   bash tools/host-egress.test.sh --netns  rootless podman 컨테이너 안의 네트워크 네임스페이스에 운영 렌더를 올려
#                                           실제 허용·차단을 본다. ci 밖에서 사람이 돌린다. 호스트 네트워크는 건드리지 않는다.
#
# 렌더 시험은 host/ 사본에 가짜 클러스터 값 파일을 더해 install.sh와 같은 load_cluster -> render_egress를 탄다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 클러스터가 쓰는 시험 이미지와 같다(platform/sandbox). nft·socat·iproute2·nsenter가 들어 있다.
IMAGE="docker.io/nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70"
FAILS=0
CASES=0
pass() { CASES=$((CASES + 1)); printf 'ok   %s\n' "$*"; }
fail() { CASES=$((CASES + 1)); FAILS=$((FAILS + 1)); printf 'FAIL %s\n' "$*" >&2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# host/ 사본을 하나 만들고 그 안의 값 파일을 바꾼다. 원본 host/는 건드리지 않는다.
copy_host() {
  rm -rf "${TMP:?}/$1"
  mkdir -p "$TMP/$1"
  cp -R "$ROOT/host" "$TMP/$1/host"
}

# render <사본> <클러스터>: 사본의 lib.sh로 렌더한다. 실패하면 stderr를 그대로 낸다.
render() {
  (
    # shellcheck source=../host/lib.sh
    . "$TMP/$1/host/lib.sh"
    load_cluster "$2"
    render_egress
  )
}

env_val() {
  # shellcheck disable=SC1090
  (. "$1" && printf '%s' "${!2}")
}

# 값 파일 하나를 prod.env에서 키 몇 개만 바꿔 만든다.
fake_env() {
  local dir="$1" name="$2" k v
  shift 2
  cp "$TMP/$dir/host/clusters/prod.env" "$TMP/$dir/host/clusters/${name}.env"
  while [ "$#" -gt 0 ]; do
    k="${1%%=*}" v="${1#*=}"
    sed -i -E "s|^${k}=.*$|${k}=\"${v}\"|" "$TMP/$dir/host/clusters/${name}.env"
    shift
  done
}

# 규칙 본문에서 주석과 빈 줄을 뺀 체인 한 개의 줄들.
chain_lines() {
  awk -v c="$2" '
    $0 ~ "^[[:space:]]*chain " c " \\{" { on = 1; next }
    on && /^[[:space:]]*}/ { exit }
    on && !/^[[:space:]]*(#|$)/ { sub(/^[[:space:]]+/, ""); print }
  ' "$1"
}

render_tests() {
  local out lines want got i n
  copy_host base

  # --- 운영 값 렌더
  if out="$(render base prod 2>&1)"; then
    printf '%s\n' "$out" >"$TMP/prod.nft"
    pass "prod 렌더"
  else
    fail "prod 렌더 실패: ${out}"
    return
  fi
  local node dns pod svc
  node="$(env_val "$ROOT/host/clusters/prod.env" NODE_IP)"
  pod="$(env_val "$ROOT/host/clusters/prod.env" POD_CIDR)"
  svc="$(env_val "$ROOT/host/clusters/prod.env" SERVICE_CIDR)"
  dns="$(env_val "$ROOT/host/versions.env" NODE_UPSTREAM_DNS)"
  for want in "define NODE_IP = ${node}" "define POD_CIDR = ${pod}" "define SERVICE_CIDR = ${svc}" \
    "define UPSTREAM_DNS = { ${dns// /, } }"; do
    if grep -qxF -- "$want" "$TMP/prod.nft"; then pass "값: ${want}"; else fail "렌더에 '${want}'가 없다"; fi
  done

  # --- forward 체인: 파드 대역만 pod_egress로 넘기고 나머지는 지나간다
  lines="$(chain_lines "$TMP/prod.nft" forward)"
  want=$'type filter hook forward priority filter; policy accept;\nip saddr $POD_CIDR jump pod_egress'
  if [ "$lines" = "$want" ]; then pass "forward 체인은 파드 대역만 pod_egress로 넘긴다"; else fail "forward 체인이 다르다:"$'\n'"${lines}"; fi

  # --- pod_egress 순서: 허용 여섯 -> 로그 -> drop. 허용이 drop 뒤에 오면 쓰이지 않는다.
  lines="$(chain_lines "$TMP/prod.nft" pod_egress)"
  # shellcheck disable=SC2016  # $POD_CIDR 등은 nft 변수 글자 그대로다
  local -a order=(
    '^ct state established,related counter accept$'
    '^ip daddr \{ \$POD_CIDR, \$SERVICE_CIDR \} counter accept$'
    '^ip daddr \$NODE_IP tcp dport \{ 6443, 10250 \} counter accept$'
    '^ip daddr \$UPSTREAM_DNS meta l4proto \{ tcp, udp \} th dport 53 counter accept$'
    '^ip daddr != @nonpublic tcp dport 443 counter accept$'
    '^ip daddr != @nonpublic meta l4proto \{ tcp, udp \} th dport 7844 counter accept$'
    '^limit rate [0-9]+/minute burst [0-9]+ packets log prefix "homelab-egress drop: "$'
    '^counter drop$'
  )
  n="$(grep -c . <<<"$lines")"
  if [ "$n" -ne "${#order[@]}" ]; then
    fail "pod_egress 규칙이 ${n}줄이다(기대 ${#order[@]}):"$'\n'"${lines}"
  else
    i=0
    while IFS= read -r got; do
      [[ "$got" =~ ${order[$i]} ]] || { fail "pod_egress $((i + 1))번째 줄이 다르다: ${got}"; i=-1; break; }
      i=$((i + 1))
    done <<<"$lines"
    [ "$i" -lt 0 ] || pass "pod_egress: established -> 대역 -> 노드 6443·10250 -> DNS 53 -> 공개 443 -> 공개 7844 -> drop"
  fi
  # 열지 않기로 한 포트(Tailscale direct·STUN, 22, 80)가 허용에 끼면 안 된다.
  if grep -E 'accept' <<<"$lines" | grep -qE '41641|3478|dport (22|80)\b'; then
    fail "pod_egress 허용에 41641·3478·22·80이 있다"
  else
    pass "41641·3478·22·80은 허용에 없다"
  fi

  # --- 공개가 아닌 대역(443·7844에서 뺌)
  got="$(sed -n 's/^[[:space:]]*elements = { \(.*\) }$/\1/p' "$TMP/prod.nft")"
  want="10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16"
  if [ "$got" = "$want" ]; then pass "nonpublic = ${want}"; else fail "nonpublic이 다르다: ${got:-없음}"; fi

  # --- 표 이름과 경로가 lib.sh·유닛·규칙에서 같다
  local table rules unit
  table="$(. "$ROOT/host/lib.sh" && printf '%s' "$EGRESS_TABLE")"
  rules="$(. "$ROOT/host/lib.sh" && printf '%s' "$EGRESS_RULES")"
  unit="$ROOT/host/egress/$(. "$ROOT/host/lib.sh" && printf '%s' "$EGRESS_UNIT_NAME")"
  if [ "$(grep -cE "^(delete )?table inet ${table}( \{)?$" "$ROOT/host/egress/egress.nft")" -eq 3 ] \
    && grep -qxF "ExecStart=/usr/sbin/nft -f ${rules}" "$unit" \
    && grep -qxF "ExecReload=/usr/sbin/nft -f ${rules}" "$unit" \
    && grep -qxF "ExecStop=-/usr/sbin/nft delete table inet ${table}" "$unit" \
    && grep -qxF "Before=k3s.service" "$unit"; then
    pass "표 이름(${table})·경로(${rules})가 lib.sh·egress.nft·유닛에서 같다, 유닛은 k3s보다 먼저"
  else
    fail "표 이름·규칙 경로·Before=k3s.service가 lib.sh·host/egress/ 사이에서 어긋난다"
  fi

  # --- VM 모양: LAN이 10.0.0.0/8이어도(E4) 파드·서비스 대역과 겹치지 않으면 렌더된다
  fake_env base t10lan NODE_IP=10.0.2.15
  if render base t10lan >/dev/null 2>&1; then pass "10/8 LAN 노드(10.0.2.15) 렌더"; else fail "10/8 LAN 노드 렌더가 실패했다"; fi

  # --- 거부해야 하는 값
  local -a bad=(
    "tinpod NODE_IP=10.42.3.4"
    "tinsvc NODE_IP=10.43.0.20"
    "tnoprefix POD_CIDR=10.42.0.0"
    "tbadlen SERVICE_CIDR=10.43.0.0/33"
  )
  local c name
  for c in "${bad[@]}"; do
    read -r name c <<<"$c"
    fake_env base "$name" "$c"
    if out="$(render base "$name" 2>&1)"; then fail "${c}를 받아들였다"; else pass "${c} 거부: ${out#FAIL: }"; fi
  done
  copy_host dnsname
  sed -i -E 's|^NODE_UPSTREAM_DNS=.*$|NODE_UPSTREAM_DNS="1.1.1.1 dns.quad9.net"|' "$TMP/dnsname/host/versions.env"
  if out="$(render dnsname prod 2>&1)"; then fail "이름으로 된 업스트림을 받아들였다"; else pass "이름 업스트림 거부: ${out#FAIL: }"; fi

  # --- 두 값 파일의 키가 같다(스크립트는 클러스터 이름으로 분기하지 않는다)
  got="$(diff <(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$ROOT/host/clusters/prod.env" | sort) \
    <(sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$ROOT/host/clusters/vm.env" | sort) || true)"
  if [ -z "$got" ]; then pass "prod.env와 vm.env의 키가 같다"; else fail "prod.env와 vm.env의 키가 다르다:"$'\n'"${got}"; fi
}

# 노드 규칙이 허용하는 53 목적지는 NODE_UPSTREAM_DNS뿐이다. AdGuard가 다른 리졸버를 쓰면 노드 규칙이
# 그 질의를 버려 AdGuard가 뜨지 못한다(bootstrap_dns). 목록이 사는 곳마다 같은지 본다. 0건 추출은 실패다.
upstream_tests() {
  local want got f
  want="$(env_val "$ROOT/host/versions.env" NODE_UPSTREAM_DNS)"
  set_of() { tr -d '"[] ' | tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }
  local sorted
  sorted="$(tr ' ' '\n' <<<"$want" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"

  f="$ROOT/host/etc/systemd/resolved.conf.d/10-k3s-node.conf"
  got="$(sed -n 's/^DNS=//p' "$f")"
  if [ "$got" = "$want" ]; then pass "resolved DNS= = NODE_UPSTREAM_DNS(순서 포함)"; else fail "${f#"$ROOT/"}의 DNS=(${got:-없음})가 ${want}와 다르다"; fi

  f="$ROOT/platform/adguard/templates/configmap.yaml"
  got="$(sed -n 's/^[[:space:]]*bootstrap_dns: \(\[.*\]\)$/\1/p' "$f" | set_of)"
  if [ -n "$got" ] && [ "$got" = "$sorted" ]; then pass "AdGuard bootstrap_dns = NODE_UPSTREAM_DNS"; else fail "${f#"$ROOT/"} bootstrap_dns(${got:-없음})가 ${want}와 다르다"; fi

  f="$ROOT/platform/adguard/templates/deployment.yaml"
  got="$(sed -n 's/^[[:space:]]*nameservers: \(\[.*\]\)$/\1/p' "$f" | set_of)"
  if [ -n "$got" ] && [ "$got" = "$sorted" ]; then pass "AdGuard 파드 nameservers = NODE_UPSTREAM_DNS"; else fail "${f#"$ROOT/"} nameservers(${got:-없음})가 ${want}와 다르다"; fi

  f="$ROOT/platform/adguard/templates/networkpolicy.yaml"
  got="$(sed -n 's|^[[:space:]]*cidr: \([0-9.]*\)/32$|\1|p' "$f" | set_of)"
  if [ -n "$got" ] && [ "$got" = "$sorted" ]; then pass "AdGuard NetworkPolicy 53 대상 = NODE_UPSTREAM_DNS"; else fail "${f#"$ROOT/"}의 /32 대상(${got:-없음})이 ${want}와 다르다"; fi
}

# ------------------------------------------------------------------------------ --netns

# 컨테이너 안에서 돈다. 컨테이너의 netns가 노드, pod·pod2·other·world netns를 veth로 붙인다.
# world는 LAN·tailnet·인터넷을 한데 모은 곳이다(목적지 주소를 lo에 붙이고 모든 포트에 socat이 ok로 답한다).
# shellcheck disable=SC2016  # 컨테이너 안에서 펼친다
NETNS_SCRIPT='
set -euo pipefail
R=/rules.nft
nft -c -f "$R"
nft -f "$R"
NODE_IP="$(sed -n "s/^define NODE_IP = //p" "$R")"
LAN="${NODE_IP%.*}"
FAILS=0
ns() { local n="$1"; shift; nsenter --net="/run/netns/$n" "$@"; }

for n in pod pod2 other world; do ip netns add "$n"; ns "$n" ip link set lo up; done
link() { # link <netns> <노드쪽 주소/길이> <ns쪽 주소/길이> <ns 기본 경로>
  ip link add "v-$1" type veth peer name eth0 netns "$1"
  ip addr add "$2" dev "v-$1"; ip link set "v-$1" up
  ns "$1" ip addr add "$3" dev eth0; ns "$1" ip link set eth0 up
  ns "$1" ip route add default via "$4"
}
link pod 10.42.0.1/24 10.42.0.5/24 10.42.0.1
link pod2 10.42.1.1/24 10.42.1.6/24 10.42.1.1
link other 10.99.0.1/24 10.99.0.5/24 10.99.0.1
ip link add wan0 type veth peer name eth0 netns world
ip addr add "$NODE_IP/24" dev wan0; ip link set wan0 up
ip route add default via "$LAN.1"
ns world ip addr add "$LAN.1/24" dev eth0; ns world ip link set eth0 up
for a in "$LAN.20" 100.100.100.100 172.16.0.1 10.0.0.5 169.254.1.1 1.1.1.1 9.9.9.9 8.8.8.8 203.0.113.10 10.43.0.99; do
  ns world ip addr add "$a/32" dev lo
done
ns world ip route add 10.42.0.0/16 via "$NODE_IP"
ns world ip route add 10.99.0.0/24 via "$NODE_IP"

serve() { # serve <netns|-> <tcp|udp:주소> <포트...>
  local n="$1" p="$2" port; shift 2
  local -a cmd
  for port in "$@"; do
    # UDP는 받은 주소에 묶는다. 0.0.0.0에 묶으면 답이 경로상의 다른 주소에서 나가 클라이언트가 버린다.
    case "$p" in
      tcp) cmd=(socat "TCP4-LISTEN:$port,fork,reuseaddr" "SYSTEM:echo ok") ;;
      udp:*) cmd=(socat "UDP4-RECVFROM:$port,bind=${p#udp:},fork" "SYSTEM:echo ok") ;;
    esac
    if [ "$n" = - ]; then "${cmd[@]}" 2>/dev/null & else ns "$n" "${cmd[@]}" 2>/dev/null & fi
  done
}
serve world tcp 22 53 80 443 7844 8443
for a in 1.1.1.1 9.9.9.9 8.8.8.8 203.0.113.10 "$LAN.1"; do serve world "udp:$a" 53 443 3478 7844 41641; done
serve - tcp 6443 10250 22
serve pod tcp 8080
serve pod2 tcp 8080
sleep 1

# -t2: 입력이 끝난 뒤 답을 기다리는 시간. 기본 0.5초면 서버 fork가 늦을 때 답을 놓쳐 허용을 차단으로 읽는다.
# grep -q를 파이프 끝에 두지 않는다. 먼저 끝난 grep이 앞 명령을 SIGPIPE로 죽이면 pipefail이 결과를 뒤집는다.
probe() { # probe <netns|-> <tcp|udp> <주소> <포트>
  local run=()
  [ "$1" = - ] || run=(nsenter --net="/run/netns/$1")
  if [ "$2" = tcp ]; then
    "${run[@]}" timeout 4 socat -t2 -T2 - "TCP4:$3:$4,connect-timeout=1" </dev/null 2>/dev/null | grep -x ok >/dev/null
  else
    echo x | "${run[@]}" timeout 4 socat -t2 -T2 - "UDP4:$3:$4" 2>/dev/null | grep -x ok >/dev/null
  fi
}
expect() { # expect <pass|drop> <설명> <probe 인자...>
  local want="$1" why="$2" got=drop; shift 2
  if probe "$@"; then got=pass; fi
  if [ "$got" = "$want" ]; then printf "ok   %-4s %-4s %s:%s from %s  %s\n" "$want" "$2" "$3" "$4" "$1" "$why"
  else printf "FAIL %-4s(기대 %s) %s %s:%s from %s  %s\n" "$got" "$want" "$2" "$3" "$4" "$1" "$why" >&2; FAILS=$((FAILS + 1)); fi
}

matrix() {
  expect pass "공개 443" pod tcp 1.1.1.1 443
  expect pass "공개 443" pod tcp 203.0.113.10 443
  expect pass "업스트림 DNS" pod udp 1.1.1.1 53
  expect pass "업스트림 DNS" pod tcp 1.1.1.1 53
  expect pass "업스트림 DNS" pod udp 9.9.9.9 53
  expect drop "업스트림 밖 DNS" pod udp 8.8.8.8 53
  expect drop "업스트림 밖 DNS" pod tcp 8.8.8.8 53
  expect pass "cloudflared" pod tcp 203.0.113.10 7844
  expect pass "cloudflared" pod udp 203.0.113.10 7844
  expect drop "공개 22" pod tcp 203.0.113.10 22
  expect drop "공개 80" pod tcp 203.0.113.10 80
  expect drop "공개 80" pod tcp 1.1.1.1 80
  expect drop "공개 8443" pod tcp 203.0.113.10 8443
  expect drop "QUIC 443" pod udp 203.0.113.10 443
  expect drop "Tailscale direct" pod udp 203.0.113.10 41641
  expect drop "STUN" pod udp 203.0.113.10 3478
  expect drop "공유기" pod tcp "$LAN.1" 80
  expect drop "공유기" pod tcp "$LAN.1" 443
  expect drop "공유기 DNS" pod udp "$LAN.1" 53
  expect drop "LAN 호스트" pod tcp "$LAN.20" 22
  expect drop "LAN 호스트" pod tcp "$LAN.20" 443
  expect drop "tailnet" pod tcp 100.100.100.100 443
  expect drop "172.16/12" pod tcp 172.16.0.1 443
  expect drop "10/8(파드·서비스 밖)" pod tcp 10.0.0.5 443
  expect drop "link-local" pod tcp 169.254.1.1 80
  expect drop "link-local" pod tcp 169.254.1.1 443
  expect pass "파드끼리" pod tcp 10.42.1.6 8080
  expect pass "서비스 대역" pod tcp 10.43.0.99 443
  expect pass "노드 kube API(INPUT)" pod tcp "$NODE_IP" 6443
  expect pass "노드 kubelet(INPUT)" pod tcp "$NODE_IP" 10250
  expect pass "노드 sshd(INPUT, 이 표 밖)" pod tcp "$NODE_IP" 22
  expect pass "LAN -> 파드 반환(established)" world tcp 10.42.0.5 8080
  expect pass "노드 자신(OUTPUT)" - tcp 203.0.113.10 22
  expect pass "파드 대역 밖 forward" other tcp 203.0.113.10 22
}

echo "== 1. 규칙만"
matrix
NODE_HITS="$(nft list chain inet homelab_egress pod_egress | sed -n "s/.*dport { 6443, 10250 } counter packets \([0-9]*\) .*/\1/p")"
if [ "$NODE_HITS" = 0 ]; then echo "ok   노드 6443·10250 허용 줄 카운터 0: 파드 -> 노드 IP는 INPUT이라 이 체인에 오지 않는다"
else echo "FAIL 노드 6443·10250 허용 줄 카운터 ${NODE_HITS:-?}" >&2; FAILS=$((FAILS + 1)); fi

echo "== 2. k3s 흉내: 같은 hook의 ip filter FORWARD가 모두 accept해도 이 표의 drop이 이긴다"
printf "%s\n" "table ip filter {" "  chain FORWARD {" "    type filter hook forward priority filter; policy accept;" "    counter accept" "  }" "}" | nft -f -
expect drop "공개 22" pod tcp 203.0.113.10 22
expect drop "tailnet" pod tcp 100.100.100.100 443
expect pass "공개 443" pod tcp 1.1.1.1 443

echo "== 3. k3s-killall 흉내: ip filter 표를 지워도 이 표는 남는다, 다시 올려도 같다"
nft delete table ip filter
if nft list table inet homelab_egress >/dev/null; then echo "ok   table inet homelab_egress 남음"; else echo "FAIL 표가 사라졌다" >&2; FAILS=$((FAILS + 1)); fi
nft -f "$R"
expect drop "공개 22(다시 올린 뒤)" pod tcp 203.0.113.10 22
expect pass "공개 443(다시 올린 뒤)" pod tcp 1.1.1.1 443

echo "== 4. 끄기(--egress-off의 nft 부분) 뒤에는 막히지 않는다"
nft delete table inet homelab_egress
expect pass "공개 22(끈 뒤)" pod tcp 203.0.113.10 22

[ "$FAILS" -eq 0 ] || { echo "netns: ${FAILS}개 실패" >&2; exit 1; }
echo "netns 통과"
'

netns_test() {
  local out
  command -v podman >/dev/null 2>&1 || { fail "podman이 없다"; return; }
  copy_host base
  out="$(render base prod 2>&1)" || { fail "prod 렌더 실패: ${out}"; return; }
  printf '%s\n' "$out" >"$TMP/prod.nft"
  # --network none: 컨테이너 netns에는 lo만 있고 밖으로 나가는 길이 없다. 시험은 그 안에서 만든 netns끼리다.
  # NET_ADMIN·SYS_ADMIN은 rootless의 user namespace 안 권한이라 호스트의 nft·링크에는 닿지 않는다.
  if podman run --rm -i --network none --cap-add NET_ADMIN,SYS_ADMIN --sysctl net.ipv4.ip_forward=1 \
    -v "$TMP/prod.nft:/rules.nft:ro,Z" "$IMAGE" bash -c "$NETNS_SCRIPT"; then
    pass "netns 시험(운영 렌더)"
  else
    fail "netns 시험"
  fi
}

case "${1:-}" in
  "")
    render_tests
    upstream_tests
    ;;
  --netns) netns_test ;;
  *) echo "사용: bash tools/host-egress.test.sh [--netns]" >&2; exit 2 ;;
esac

# 0건 통과는 실패다(B.8 E7).
[ "$CASES" -gt 0 ] || { echo "FAIL 시험이 0건이다" >&2; exit 1; }
[ "$FAILS" -eq 0 ] || { echo "host-egress: ${FAILS}/${CASES} 실패" >&2; exit 1; }
echo "host-egress: ${CASES}건 통과"
