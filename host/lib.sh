# shellcheck shell=bash
# install.sh, preflight.sh, verify.sh가 함께 쓰는 함수. 직접 실행하지 않는다.
# 부르는 쪽이 set -euo pipefail을 켠 뒤 source한다.
#
# 클러스터 이름은 host/clusters/<이름>.env를 고르는 데만 쓴다. 이 파일과 스크립트에는
# 클러스터 이름 분기가 없고, 차이는 모두 env 파일의 값에서 나온다(E8 VM 격리 1번).

shopt -s inherit_errexit

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# host/etc/ 안에서 경로를 클러스터 값으로 바꾸는 유일한 자리표시(networkd drop-in 디렉터리).
IFACE_TOKEN='@NODE_IFACE@'
CLUSTER_KEYS="NODE_NAME NODE_IP NODE_IFACE TAILNET_JOIN KUBE_CONTEXT POD_CIDR SERVICE_CIDR"
# 비워 둘 수 있는 클러스터 값. TAILNET_DEVICE_NAME이 비면 NODE_NAME을 쓴다.
OPTIONAL_KEYS="TAILNET_DEVICE_NAME"
COMMON_KEYS="INSTALL_K3S_VERSION TIMEZONE NODE_UPSTREAM_DNS"
NODE_MAGICDNS=""
# 파드 egress 규칙(install.sh --egress). 표 이름은 k3s·Tailscale의 표와 겹치지 않게 따로 둔다.
# 표 이름과 경로는 host/egress/의 두 파일에도 글자로 있다. 바꾸면 셋을 함께 바꾼다.
# shellcheck disable=SC2034  # install.sh·verify.sh가 쓴다
EGRESS_TABLE=homelab_egress
# shellcheck disable=SC2034
EGRESS_RULES=/etc/homelab/egress.nft
EGRESS_UNIT_NAME=homelab-egress.service
# shellcheck disable=SC2034
EGRESS_UNIT="/etc/systemd/system/${EGRESS_UNIT_NAME}"

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

require_cmds() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "명령 ${c}가 없다"
  done
}

# host/가 커밋과 같은지 본다. install은 host/etc/를 root로 /etc에 깔고 verify는 같은 트리로 렌더해
# 라이브와 비교하므로, 커밋 안 한 수정·추적 안 한 파일·무시된 편집기 잔여물(*.conf~ 등)이 있으면
# "Git과 같다"가 거짓이 된다. sudo로 불렸으면 원래 사용자로 git을 부른다(root는 safe.directory에 걸린다).
assert_host_tree_clean() {
  local out
  local -a git_cmd=(git -C "$HOST_DIR" status --porcelain --ignored -- .)
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    git_cmd=(sudo -u "$SUDO_USER" "${git_cmd[@]}")
  fi
  out="$("${git_cmd[@]}" 2>&1)" || die "host/의 git 상태를 읽지 못했다: ${out}"
  [ -z "$out" ] || die "host/에 커밋하지 않은 변경이나 무시된 파일이 있다. 커밋하거나 지운 뒤 다시 실행한다:
${out}"
}

# MagicDNS 전체 이름은 tailnet 이름을 담는다. 출력이 작업 기록(공개 저장소)에 붙을 수 있어 가린다.
mask() {
  local s="$1"
  if [ -n "$NODE_MAGICDNS" ]; then
    s="${s//"$NODE_MAGICDNS"/"<MagicDNS>"}"
  fi
  printf '%s' "$s"
}

# --cluster 값으로 공통 값과 클러스터 값을 읽고 형식을 확인한다.
load_cluster() {
  local name="$1" file key val
  case "$name" in
    '' | *[!a-z0-9-]*) die "--cluster 값이 잘못됐다: '${name}' (소문자, 숫자, -만)" ;;
  esac
  file="$HOST_DIR/clusters/${name}.env"
  [ -f "$file" ] || die "클러스터 값 파일이 없다: ${file}"
  # 부르는 셸 환경에 같은 이름이 남아 있으면 env 파일에서 빠진 키가 조용히 채워진다. 먼저 지운다.
  # shellcheck disable=SC2086
  unset $COMMON_KEYS $CLUSTER_KEYS $OPTIONAL_KEYS
  # shellcheck source=versions.env
  . "$HOST_DIR/versions.env"
  # shellcheck source=clusters/prod.env
  . "$file"
  CLUSTER="$name"
  for key in $COMMON_KEYS $CLUSTER_KEYS; do
    val="${!key:-}"
    [ -n "$val" ] || die "${key}가 비어 있다(host/versions.env 또는 ${file})"
    case "$val" in
      *CHANGE_ME*) die "${file}의 ${key}가 자리표시(CHANGE_ME)다. 이 클러스터를 준비할 때 채운다" ;;
    esac
  done
  [[ "$INSTALL_K3S_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] \
    || die "INSTALL_K3S_VERSION 형식이 아니다: ${INSTALL_K3S_VERSION} (예: v1.36.5+k3s1. 채널 이름 금지)"
  [[ "$NODE_NAME" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] \
    || die "NODE_NAME이 DNS 라벨이 아니다: ${NODE_NAME}"
  TAILNET_DEVICE_NAME="${TAILNET_DEVICE_NAME:-$NODE_NAME}"
  [[ "$TAILNET_DEVICE_NAME" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] \
    || die "TAILNET_DEVICE_NAME이 DNS 라벨이 아니다(MagicDNS 전체 이름이 아니라 첫 라벨만 둔다): ${TAILNET_DEVICE_NAME}"
  [[ "$NODE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "NODE_IP가 IPv4가 아니다: ${NODE_IP}"
  [[ "$NODE_IFACE" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "NODE_IFACE 형식이 아니다: ${NODE_IFACE}"
  [[ "$KUBE_CONTEXT" =~ ^[a-z0-9][-a-z0-9.]*$ ]] || die "KUBE_CONTEXT 형식이 아니다: ${KUBE_CONTEXT}"
  for key in POD_CIDR SERVICE_CIDR; do
    [[ "${!key}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] \
      || die "${key}가 IPv4 CIDR이 아니다: ${!key}"
  done
  case "$TAILNET_JOIN" in
    true | false) ;;
    *) die "TAILNET_JOIN은 true 또는 false다: ${TAILNET_JOIN}" ;;
  esac
}

tailscale_self_json() {
  tailscale status --self --peers=false --json 2>/dev/null
}

# TAILNET_JOIN=true면 NODE_MAGICDNS를 채운다. 전체 이름은 env 파일에 두지 않고(tailnet 이름 비공개)
# 실행 때마다 얻는다. 첫 라벨은 TAILNET_DEVICE_NAME(비면 NODE_NAME)과 같아야 한다. 다르면 TLS SAN,
# tailnet kubectl, 이름으로 하는 ssh 확인이 어긋난다. 콘솔에 옛 기기가 남아 있으면 새 등록 이름에 -1이
# 붙고, 옛 기기를 나중에 지워도 이름이 되돌아가지 않는다(C.3.2 0번). 그 사고를 이 비교가 잡는다.
resolve_magicdns() {
  local js state name
  NODE_MAGICDNS=""
  [ "$TAILNET_JOIN" = "true" ] || return 0
  require_cmds tailscale jq
  js="$(tailscale_self_json)" \
    || die "tailscale status가 실패했다. C.3.2 0번(sudo tailscale up --hostname=${TAILNET_DEVICE_NAME})을 먼저 한다"
  state="$(jq -r '.BackendState // ""' <<<"$js")"
  [ "$state" = "Running" ] || die "Tailscale 상태가 Running이 아니다(${state:-알 수 없음}). C.3.2 0번을 먼저 한다"
  name="$(jq -r '.Self.DNSName // "" | rtrimstr(".")' <<<"$js")"
  case "$name" in
    *.*) ;;
    *) die "MagicDNS 이름을 얻지 못했다. tailnet에서 MagicDNS가 켜져 있는지 본다" ;;
  esac
  [ "${name%%.*}" = "$TAILNET_DEVICE_NAME" ] \
    || die "Tailscale 기기 이름의 첫 라벨(${name%%.*})이 TAILNET_DEVICE_NAME(${TAILNET_DEVICE_NAME})과 다르다. 콘솔에서 옛 기기와 -1 접미를 확인한다(C.3.2 0번). 이름을 일부러 바꿨으면 host/clusters/${CLUSTER}.env의 TAILNET_DEVICE_NAME을 고친다"
  NODE_MAGICDNS="$name"
}

# TAILNET_JOIN=false인 호스트(VM)가 tailnet에 들어가 있으면 멈춘다. 사람 기기로 등록된 VM은
# 운영자 ACL로 운영 NUC의 SSH·kubectl 포트에, self 규칙으로 사람 기기 전체에 닿는다(E8 VM 격리 4번).
assert_not_in_tailnet() {
  local js state
  [ "$TAILNET_JOIN" = "false" ] || return 0
  command -v tailscale >/dev/null 2>&1 || return 0
  js="$(tailscale_self_json)" || return 0
  state="$(jq -r '.BackendState // ""' <<<"$js")"
  [ "$state" != "Running" ] \
    || die "TAILNET_JOIN=false인데 이 호스트가 tailnet에 들어가 있다. tailscale logout 뒤 콘솔에서 기기를 지운다"
}

# host/k3s-config.yaml의 자리표시를 채워 출력한다. TAILNET_JOIN=false면 MagicDNS 줄을 뺀다.
# envsubst를 쓰지 않는다. 모르는 변수를 조용히 빈 값으로 바꾸기 때문이다. 대신 남은 ${가 있으면 멈춘다.
render_k3s_config() {
  local line out=""
  # shellcheck disable=SC2016  # 작은따옴표 안의 ${...}는 자리표시 글자 그대로다
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *'${NODE_MAGICDNS}'*) [ "$TAILNET_JOIN" = "true" ] || continue ;;
    esac
    line="${line//'${NODE_NAME}'/"$NODE_NAME"}"
    line="${line//'${NODE_IP}'/"$NODE_IP"}"
    line="${line//'${NODE_MAGICDNS}'/"$NODE_MAGICDNS"}"
    case "${line#"${line%%[![:space:]]*}"}" in
      '#'*) ;;
      *'${'*) die "k3s-config.yaml에 채우지 못한 자리표시가 있다: ${line}" ;;
    esac
    out+="${line}"$'\n'
  done <"$HOST_DIR/k3s-config.yaml"
  if [ "$TAILNET_JOIN" = "true" ] && [ -z "$NODE_MAGICDNS" ]; then
    die "TAILNET_JOIN=true인데 NODE_MAGICDNS가 비어 있다(resolve_magicdns를 먼저 부른다)"
  fi
  printf '%s' "$out"
}

# k3s config(평평한 키, 스칼라나 문자열 목록만)를 "--키<TAB>값" 줄로 바꿔 정렬한다.
# k3s가 config를 플래그로 바꾸는 방식(목록은 항목마다 플래그 하나)과 같은 모양이라
# 라이브 k3s.io/node-args 어노테이션과 바로 비교할 수 있다. 모르는 형식 줄은 BAD로 낸다.
# yq를 쓰지 않는다. NUC의 yq는 개인 mise 설치라 root PATH와 새 호스트에 있다고 볼 수 없다.
config_pairs() {
  awk '
    function clean(v) {
      sub(/[[:space:]]+#.*$/, "", v)
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
      return v
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[a-z0-9-]+:/ {
      key = $0; sub(/:.*/, "", key)
      val = $0; sub(/^[^:]*:/, "", val); val = clean(val)
      if (val != "") print "--" key "\t" val
      next
    }
    /^[[:space:]]+-[[:space:]]/ {
      if (key == "") { print "BAD\t" $0; next }
      item = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", item)
      print "--" key "\t" clean(item)
      next
    }
    { print "BAD\t" $0 }
  ' | LC_ALL=C sort
}

# k3s.io/node-args 어노테이션(JSON 배열)을 config_pairs와 같은 모양으로 바꾼다.
# 맨 앞의 하위 명령 server는 뺀다. 플래그와 값이 짝이 맞지 않으면 실패한다.
node_args_pairs() {
  jq -r '
    (if .[0] == "server" then .[1:] else . end) as $a
    | if ($a | length) % 2 != 0 then error("플래그와 값의 짝이 맞지 않는다")
      else range(0; $a | length; 2) as $i | "\($a[$i])\t\($a[$i + 1])" end
  ' | LC_ALL=C sort
}

# host/etc/의 모든 파일을 "원본<TAB>대상" 줄로 낸다. 확장자로 거르지 않는다. 옛 화이트리스트는
# 목록 밖 확장자를 조용히 빠뜨렸다. 0건이면 성공으로 읽지 않고 멈춘다.
etc_targets() {
  local src rel dest n=0
  while IFS= read -r -d '' src; do
    rel="${src#"$HOST_DIR/etc/"}"
    dest="/etc/${rel//"$IFACE_TOKEN"/"$NODE_IFACE"}"
    [[ ! "$dest" =~ @[A-Z_]+@ ]] || die "경로에 채우지 못한 자리표시가 있다: ${dest}"
    printf '%s\t%s\n' "$src" "$dest"
    n=$((n + 1))
  done < <(find "$HOST_DIR/etc" -type f -print0 | LC_ALL=C sort -z)
  [ "$n" -ge 1 ] || die "host/etc/에서 파일을 찾지 못했다"
}

# etc_targets 가운데 networkd drop-in 대상 경로만 낸다.
network_dropin_targets() {
  local targets
  targets="$(etc_targets)"
  awk -F '\t' '$2 ~ /^\/etc\/systemd\/network\/[^\/]+\.network\.d\// { print $2 }' <<<"$targets"
}

# NODE_IFACE의 networkd 링크 상태 파일 경로. networkd가 이 링크에 실제로 적용한 값이 있다.
# /run/systemd/netif/leases/의 DNS=는 DHCP가 준 원본이라 UseDNS=false여도 남는다. 혼동하지 않는다.
link_state_file() {
  local idx
  idx="$(cat "/sys/class/net/${NODE_IFACE}/ifindex" 2>/dev/null)" \
    || die "인터페이스 ${NODE_IFACE}가 없다(host/clusters/${CLUSTER}.env의 NODE_IFACE)"
  printf '/run/systemd/netif/links/%s' "$idx"
}

# NODE_IFACE에 붙은 IPv4 주소 목록(접두 길이 없이).
iface_ipv4s() {
  ip -o -4 addr show dev "$NODE_IFACE" 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }'
}

# IPv4 주소를 정수로 낸다. 형식이 아니면 1로 끝난다.
ipv4_int() {
  local a b c d
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}"
  [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ] || return 1
  printf '%d' $(((a << 24) | (b << 16) | (c << 8) | d))
}

# cidr_within <바깥 CIDR> <주소 또는 CIDR>: 둘째가 첫째 안에 통째로 들어가면 0.
cidr_within() {
  local onet olen inet ilen o i mask
  onet="${1%/*}" olen="${1#*/}"
  inet="${2%/*}" ilen=32
  case "$2" in */*) ilen="${2#*/}" ;; esac
  [[ "$olen" =~ ^[0-9]+$ ]] && [[ "$ilen" =~ ^[0-9]+$ ]] || return 1
  [ "$olen" -le 32 ] && [ "$ilen" -le 32 ] && [ "$ilen" -ge "$olen" ] || return 1
  o="$(ipv4_int "$onet")" || return 1
  i="$(ipv4_int "$inet")" || return 1
  mask=$(((0xffffffff << (32 - olen)) & 0xffffffff))
  [ $((o & mask)) -eq $((i & mask)) ]
}

# 해시 자리표시(@EGRESS_HASH@)를 남긴 렌더. 해시는 이 글자 전체의 sha256이다.
egress_unhashed() {
  local d dns=""
  # LAN이 10.0.0.0/8이면 노드 IP가 파드·서비스 대역 안에 들 수 있다(B.8 E4). 그러면 대역 허용이
  # LAN 호스트까지 열고, k3s 자체도 경로가 꼬인다.
  if cidr_within "$POD_CIDR" "$NODE_IP" || cidr_within "$SERVICE_CIDR" "$NODE_IP"; then
    die "NODE_IP ${NODE_IP}가 POD_CIDR ${POD_CIDR}나 SERVICE_CIDR ${SERVICE_CIDR} 안에 있다"
  fi
  for d in $NODE_UPSTREAM_DNS; do
    ipv4_int "$d" >/dev/null || die "NODE_UPSTREAM_DNS에 IPv4가 아닌 값이 있다: ${d}"
    dns+="${dns:+, }${d}"
  done
  printf '# host/install.sh --egress가 쓴 파일이다. 고치려면 Git의 원본을 고치고 다시 실행한다.\n'
  printf '# 원본: host/egress/egress.nft, 값: host/clusters/%s.env, host/versions.env\n' "$CLUSTER"
  printf 'define NODE_IP = %s\n' "$NODE_IP"
  printf 'define POD_CIDR = %s\n' "$POD_CIDR"
  printf 'define SERVICE_CIDR = %s\n' "$SERVICE_CIDR"
  printf 'define UPSTREAM_DNS = { %s }\n\n' "$dns"
  cat "$HOST_DIR/egress/egress.nft"
}

# 파드 egress 규칙(host/egress/egress.nft) 앞에 클러스터 값을 nft define으로 붙이고 표 comment에
# 렌더 해시를 넣어 낸다. 규칙 본문은 nft 변수만 쓰므로 렌더 결과를 nft -c로 그대로 확인할 수 있다.
# install.sh가 이 출력을 EGRESS_RULES로 쓰고, verify.sh가 같은 출력과 라이브 파일·커널 표를 대조한다.
render_egress() {
  local t h
  # 부르는 쪽이 if 안이면 errexit이 꺼져 있다. 렌더 실패를 직접 끝낸다(die는 서브셸만 끝낸다).
  t="$(egress_unhashed)" || exit 1
  [[ "$t" == *'comment "@EGRESS_HASH@"'* ]] || die "host/egress/egress.nft에 comment \"@EGRESS_HASH@\"가 없다"
  h="sha256:$(printf '%s\n' "$t" | sha256sum | cut -d ' ' -f 1)"
  printf '%s\n' "${t//@EGRESS_HASH@/"$h"}"
}

# 렌더 결과(stdin)의 체인별 규칙 줄 수를 {"체인":수} JSON으로 낸다. 주석·빈 줄·base chain 선언 줄은 세지 않는다.
egress_rule_counts() {
  awk '
    /^[[:space:]]*chain [a-z_]+ \{/ { c = $2; n[c] = 0; order[++k] = c; next }
    c == "" { next }
    /^[[:space:]]*}/ { c = ""; next }
    /^[[:space:]]*(#|$)/ || /^[[:space:]]*type [a-z]+ hook / { next }
    { n[c]++ }
    END { printf "{"; for (i = 1; i <= k; i++) printf "%s\"%s\":%d", (i > 1 ? "," : ""), order[i], n[order[i]]; print "}" }
  '
}

# 커널의 egress 표를 nft JSON으로 낸다. root면 nft로, 아니면 sudo -n(비밀번호를 묻지 않는다)으로 읽는다.
# 0: 읽음, 1: 읽을 권한은 있는데 표가 없거나 nft가 실패, 2: 권한이 없어 읽지 못함(미검증).
# 커널 nft 표는 root만 읽는다. 일반 사용자에게 nft 권한을 주지 않는다(쓰기와 같은 권한이다).
egress_kernel_json() {
  local -a nft=(nft)
  if [ "$(id -u)" -ne 0 ]; then
    sudo -n true 2>/dev/null || return 2
    nft=(sudo -n nft)
  fi
  "${nft[@]}" -j list table inet "$EGRESS_TABLE" 2>/dev/null || return 1
}

# 커널 표(stdin, egress_kernel_json 출력)를 지금 Git 렌더와 대조해 문제를 한 줄씩 낸다. 빈 출력이 통과다.
# 표 comment의 해시가 렌더 해시와 같아야 한다(파일만 바꾸고 reload를 빠뜨리면 여기서 걸린다). 올린 뒤
# 누가 규칙·원소를 지우거나 끼워 넣은 것은 체인별 규칙 수와 아래 모양 검사로 잡는다.
egress_kernel_problems() {
  local js rendered hash counts nonpublic dns
  js="$(cat)"
  rendered="$(render_egress)" || exit 1
  hash="$(sed -n 's/^[[:space:]]*comment "\(sha256:[0-9a-f]*\)"$/\1/p' <<<"$rendered")"
  counts="$(egress_rule_counts <<<"$rendered")"
  nonpublic="$(sed -n 's/^[[:space:]]*elements = { \(.*\) }$/\1/p' <<<"$rendered" | tr -d ' ' | tr ',' '\n' | jq -R . | jq -cs 'sort')"
  # shellcheck disable=SC2086  # 공백으로 나눈 목록이다
  dns="$(printf '%s\n' $NODE_UPSTREAM_DNS | jq -R . | jq -cs 'sort')"
  jq -r --arg hash "$hash" --arg pod "$POD_CIDR" --arg svc "$SERVICE_CIDR" --arg node "$NODE_IP" \
    --argjson counts "$counts" --argjson nonpublic "$nonpublic" --argjson dns "$dns" '
    def noc: map(select(has("counter") | not));
    def verdicts: [.[] | to_entries[0].key | select(IN("accept", "drop", "jump", "goto", "return", "reject", "queue"))];
    def ipint: split(".") | map(tonumber) | .[0] * 16777216 + .[1] * 65536 + .[2] * 256 + .[3];
    def pfx($s): ($s | split("/")) as $p | {prefix: {addr: $p[0], len: ($p[1] | tonumber)}};
    def covers($outer; $inner):
      ($outer.prefix.len) as $ol | ($inner.prefix.len) as $il | pow(2; 32 - $ol) as $b
      | $il >= $ol and ((($outer.prefix.addr | ipint) / $b | floor) == (($inner.prefix.addr | ipint) / $b | floor));
    def vals: if type == "object" and has("set") then .set else [.] end;
    def ip($f): {payload: {protocol: "ip", field: $f}};
    def m($op; $left): [.[] | .match? // empty | select(.op == $op and .left == $left) | .right];
    def estab: (m("in"; {ct: {key: "state"}}) == [["established", "related"]]) and (verdicts == ["accept"]);
    def node_api: (m("=="; ip("daddr")) == [$node])
      and (m("=="; {payload: {protocol: "tcp", field: "dport"}}) | map(vals | sort)) == [[6443, 10250]]
      and verdicts == ["accept"] and length == 3;
    def cluster_bands:
      if length == 2 and verdicts == ["accept"] and (m("=="; ip("daddr")) | length) == 1
      then (m("=="; ip("daddr"))[0] | vals) as $r
        | all(pfx($pod), pfx($svc); . as $i | any($r[]; type == "object" and has("prefix") and covers(.; $i)))
      else false end;
    def upstream_dns: (m("=="; ip("daddr")) | map(vals | sort)) == [$dns]
      and (m("=="; {meta: {key: "l4proto"}}) | map(vals | sort)) == [["tcp", "udp"]]
      and m("=="; {payload: {protocol: "th", field: "dport"}}) == [53] and verdicts == ["accept"] and length == 4;
    def public_443: m("!="; ip("daddr")) == ["@nonpublic"]
      and m("=="; {payload: {protocol: "tcp", field: "dport"}}) == [443] and verdicts == ["accept"] and length == 3;
    def public_7844: m("!="; ip("daddr")) == ["@nonpublic"]
      and (m("=="; {meta: {key: "l4proto"}}) | map(vals | sort)) == [["tcp", "udp"]]
      and m("=="; {payload: {protocol: "th", field: "dport"}}) == [7844] and verdicts == ["accept"] and length == 4;
    def only_drop: . == [{drop: null}];
    def middle_ok: verdicts == ["accept"] or (verdicts == [] and any(.[]; has("log")));
    (.nftables // []) as $n
    | [$n[] | .table? // empty] as $t
    | [$n[] | .chain? // empty] as $c
    | [$n[] | .set? // empty | select(.name == "nonpublic")] as $s
    | def rules($ch): [$n[] | .rule? // empty | select(.chain == $ch) | .expr | noc];
      def body($ch; $need): rules($ch) as $r
        | (if ($r | length) < 2 then "\($ch): 규칙이 \($r | length)개다" else empty end),
          (if ($r | length) >= 2 and ($r[0] | estab | not) then "\($ch): 첫 규칙이 ct state established,related accept가 아니다" else empty end),
          (if ($r | length) >= 2 and ($r[-1] | only_drop | not) then "\($ch): 끝 규칙이 drop이 아니다" else empty end),
          (if ($r | length) >= 2 and ([$r[1:-1][] | middle_ok] | all | not) then "\($ch): drop 앞에 accept·log가 아닌 규칙이 있다" else empty end),
          ($need[] as [$name, $ok] | if $ok then empty else "\($ch): 필수 허용이 없다: \($name)" end);
    (if ($t | length) == 0 then "표 inet homelab_egress가 없다" else empty end),
    (if ($t | length) == 1 and $t[0].comment != $hash
      then "표 해시가 지금 렌더와 다르다(커널 \($t[0].comment // "없음"), 렌더 \($hash)). 파일만 바꾸고 reload를 빠뜨렸거나 다른 규칙이 올라와 있다"
      else empty end),
    (if ($t | length) == 0 then empty else (
      (if ([$c[] | select(.hook != null) | "\(.name)/\(.hook)/\(.type)/\(.policy)"] | sort) == ["forward/forward/filter/accept", "input/input/filter/accept"]
        then empty else "base chain이 forward·input(filter, policy accept) 둘이 아니다" end),
      (if ([$c[] | .name] | sort) == ($counts | keys | sort) then empty else "체인 목록이 렌더와 다르다: \([$c[] | .name] | sort | join(","))" end),
      ($counts | to_entries[] | . as $e | rules($e.key) | length as $k
        | if $k == $e.value then empty else "\($e.key): 규칙 수 \($k), 렌더 \($e.value)" end),
      (if rules("forward") == [[{match: {op: "==", left: ip("saddr"), right: pfx($pod)}}, {jump: {target: "pod_egress"}}]]
        then empty else "forward: 파드 대역(\($pod)) 출발만 pod_egress로 넘기는 규칙 하나가 아니다" end),
      (if rules("input") == [[{match: {op: "!=", left: {meta: {key: "iifname"}}, right: "lo"}},
                              {match: {op: "==", left: ip("saddr"), right: pfx($pod)}}, {jump: {target: "pod_to_node"}}]]
        then empty else "input: lo 밖의 파드 대역(\($pod)) 출발만 pod_to_node로 넘기는 규칙 하나가 아니다" end),
      body("pod_egress"; [
        ["파드·서비스 대역", any(rules("pod_egress")[]; cluster_bands)],
        ["노드 6443·10250", any(rules("pod_egress")[]; node_api)],
        ["업스트림 DNS 53", any(rules("pod_egress")[]; upstream_dns)],
        ["공개 TCP 443", any(rules("pod_egress")[]; public_443)],
        ["공개 7844", any(rules("pod_egress")[]; public_7844)]
      ]),
      body("pod_to_node"; [["노드 6443·10250", any(rules("pod_to_node")[]; node_api)]]),
      (if ($s | length) == 1 and ([$s[0].elem[] | if type == "object" then "\(.prefix.addr)/\(.prefix.len)" else . end] | sort) == $nonpublic
        then empty else "set nonpublic 원소가 렌더와 다르다" end)
    ) end)
  ' <<<"$js"
}
