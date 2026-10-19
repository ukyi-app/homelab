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
CLUSTER_KEYS="NODE_NAME NODE_IP NODE_IFACE TAILNET_JOIN KUBE_CONTEXT"
COMMON_KEYS="INSTALL_K3S_VERSION TIMEZONE NODE_UPSTREAM_DNS"
NODE_MAGICDNS=""

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
  unset $COMMON_KEYS $CLUSTER_KEYS
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
  [[ "$NODE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "NODE_IP가 IPv4가 아니다: ${NODE_IP}"
  [[ "$NODE_IFACE" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "NODE_IFACE 형식이 아니다: ${NODE_IFACE}"
  [[ "$KUBE_CONTEXT" =~ ^[a-z0-9][-a-z0-9.]*$ ]] || die "KUBE_CONTEXT 형식이 아니다: ${KUBE_CONTEXT}"
  case "$TAILNET_JOIN" in
    true | false) ;;
    *) die "TAILNET_JOIN은 true 또는 false다: ${TAILNET_JOIN}" ;;
  esac
}

tailscale_self_json() {
  tailscale status --self --peers=false --json 2>/dev/null
}

# TAILNET_JOIN=true면 NODE_MAGICDNS를 채운다. 이름은 env 파일에 두지 않고(tailnet 이름 비공개)
# 실행 때마다 얻는다. 첫 라벨이 NODE_NAME과 다르면 TLS SAN, tailnet kubectl, tailscale ssh
# 확인이 어긋난다. 콘솔에 옛 기기가 남아 있으면 새 등록 이름에 -1이 붙고, 옛 기기를 나중에
# 지워도 이름이 되돌아가지 않는다(C.3.2 0번).
resolve_magicdns() {
  local js state name
  NODE_MAGICDNS=""
  [ "$TAILNET_JOIN" = "true" ] || return 0
  require_cmds tailscale jq
  js="$(tailscale_self_json)" \
    || die "tailscale status가 실패했다. C.3.2 0번(sudo tailscale up --hostname=${NODE_NAME})을 먼저 한다"
  state="$(jq -r '.BackendState // ""' <<<"$js")"
  [ "$state" = "Running" ] || die "Tailscale 상태가 Running이 아니다(${state:-알 수 없음}). C.3.2 0번을 먼저 한다"
  name="$(jq -r '.Self.DNSName // "" | rtrimstr(".")' <<<"$js")"
  case "$name" in
    *.*) ;;
    *) die "MagicDNS 이름을 얻지 못했다. tailnet에서 MagicDNS가 켜져 있는지 본다" ;;
  esac
  [ "${name%%.*}" = "$NODE_NAME" ] \
    || die "Tailscale 기기 이름의 첫 라벨(${name%%.*})이 NODE_NAME(${NODE_NAME})과 다르다. 콘솔에서 옛 기기와 -1 접미를 확인한다(C.3.2 0번)"
  NODE_MAGICDNS="$name"
}

# TAILNET_JOIN=false인 호스트(VM)가 tailnet에 들어가 있으면 멈춘다. 사람 기기로 등록된 VM은
# ACL autogroup:self로 운영 NUC의 모든 포트와 Tailscale SSH root에 닿는다(E8 VM 격리 4번).
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
