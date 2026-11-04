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
# BULK_SSD_LABEL·BULK_MOUNT는 둘 다 비우거나 둘 다 채운다. 비면 SSD 단계(install --bulk-ssd, verify)를 건너뛴다.
OPTIONAL_KEYS="TAILNET_DEVICE_NAME BULK_SSD_LABEL BULK_MOUNT"
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
# 삭제 원장(원장 계약 v1). 경로·소유·파일 이름은 봇(B2)과 PV(platform)가 같은 값을 쓴다. 한쪽만 바꾸지 않는다.
# 봇은 파일을 만들지 않는다. 첫 초기화는 install.sh --bulk-ssd만 한다.
# 소유는 tools/host-bulk.test.sh가 root 없이 돌리려고 바꾼다.
# shellcheck disable=SC2034  # install.sh·verify.sh가 쓴다
{
  FSTAB=/etc/fstab
  LEDGER_PARENT_REL=homelab-bot
  LEDGER_DIR_REL=homelab-bot/deletion-ledger
  LEDGER_FILE=deletions.jsonl
  LEDGER_MARKER=ledger.json
  LEDGER_PARENT_OWNER=0:0
  LEDGER_OWNER=65532:65532
  # 첫 초기화의 generation 원천. 시험이 바꾼다.
  UUID_SRC=/proc/sys/kernel/random/uuid
}

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
  BULK_SSD_LABEL="${BULK_SSD_LABEL:-}"
  BULK_MOUNT="${BULK_MOUNT:-}"
  if [ -n "$BULK_SSD_LABEL" ] || [ -n "$BULK_MOUNT" ]; then
    [ -n "$BULK_SSD_LABEL" ] && [ -n "$BULK_MOUNT" ] \
      || die "BULK_SSD_LABEL과 BULK_MOUNT는 둘 다 비우거나 둘 다 채운다(${file})"
    # ext4 라벨은 16바이트까지다. 공백이 있으면 fstab의 LABEL= 필드가 갈라진다.
    [[ "$BULK_SSD_LABEL" =~ ^[A-Za-z0-9_-]{1,16}$ ]] || die "BULK_SSD_LABEL 형식이 아니다: ${BULK_SSD_LABEL}"
    # 루트(/)·상대 경로·..을 받지 않는다. 원장 경로가 이 아래에 붙는다.
    [[ "$BULK_MOUNT" =~ ^(/[A-Za-z0-9_-]+)+$ ]] || die "BULK_MOUNT는 /로 시작하는 절대 경로다(/ 자체, ., 공백 금지): ${BULK_MOUNT}"
  fi
}

# ------------------------------------------------------------------ 삭제 원장 SSD

# 관리하는 fstab 줄. nofail이라 SSD가 없어도 부팅은 계속된다. 대신 마운트 안 된 /mnt/bulk는 루트 디스크의 빈
# 디렉터리라, 그 아래에 원장을 만들면 봇이 빈 원장을 정상으로 읽는다. 그래서 원장 디렉터리는 마운트 대조 뒤에만
# 만들고, PV(platform)도 원본 디렉터리가 없으면 파드가 뜨지 않는다. noexec·nodev·nosuid: 원장 파일만 둔다.
bulk_fstab_line() {
  printf 'LABEL=%s %s ext4 defaults,nodev,nosuid,noexec,nofail,x-systemd.device-timeout=10s 0 2' "$BULK_SSD_LABEL" "$BULK_MOUNT"
}

# FSTAB에서 이 마운트 지점이나 이 라벨을 쓰는 줄(주석 제외)을 공백을 하나로 맞춰 낸다. 빈 출력이 "없음"이다.
# 한 줄이고 bulk_fstab_line과 같으면 "있음", 그 밖은 충돌이다(같은 지점의 다른 줄, 같은 라벨의 다른 지점, 중복).
fstab_bulk_lines() {
  awk -v mp="$BULK_MOUNT" -v spec="LABEL=${BULK_SSD_LABEL}" \
    'NF && $1 !~ /^#/ && ($2 == mp || $1 == spec) { $1 = $1; print }' "$FSTAB"
}

# 지금 BULK_MOUNT에 걸린 마운트를 "원본 형식 옵션 라벨" 줄로 낸다. --mountpoint만 쓴다. findmnt -T는 마운트가 없으면
# 상위 루트 파일시스템을 답해 "마운트됨"으로 읽힌다(설계 B.4 H8). 여러 줄이면 겹쳐 마운트된 것이다.
# 마운트가 없으면 findmnt가 1로 끝난다. 그 경우는 빈 출력으로 낸다.
bulk_mount_lines() {
  findmnt -n -r -o SOURCE,FSTYPE,OPTIONS,LABEL --mountpoint "$BULK_MOUNT" 2>/dev/null || true
}

# bulk_mount_problem [기대 장치]: BULK_MOUNT가 라벨 장치의 ext4로 쓰기 가능하게 하나만 마운트돼 있으면 빈 출력,
# 아니면 이유 한 줄. 기대 장치를 주면(install, root가 blkid로 찾은 것) 원본이 그 장치인지도 본다.
# 라벨만 맞으면 같은 라벨의 다른 디스크(예: 복제한 디스크)를 받을 수 있어 install은 장치까지 맞춘다.
bulk_mount_problem() {
  local lines src fstype opts label
  lines="$(bulk_mount_lines)"
  if [ -z "$lines" ]; then
    printf '%s에 마운트가 없다\n' "$BULK_MOUNT"
    return
  fi
  if [ "$(grep -c . <<<"$lines")" -ne 1 ]; then
    printf '%s에 마운트가 여러 개 겹쳐 있다: %s\n' "$BULK_MOUNT" "${lines//$'\n'/; }"
    return
  fi
  read -r src fstype opts label <<<"$lines"
  if [ -n "${1:-}" ] && [ "$(readlink -f -- "$src")" != "$(readlink -f -- "$1")" ]; then
    printf '%s의 원본이 %s다(기대 %s)\n' "$BULK_MOUNT" "$src" "$1"
  elif [ -z "$label" ]; then
    printf '%s의 원본 %s 라벨을 읽지 못했다(기대 %s)\n' "$BULK_MOUNT" "$src" "$BULK_SSD_LABEL"
  elif [ "$label" != "$BULK_SSD_LABEL" ]; then
    printf '%s의 원본 %s 라벨이 %s다(기대 %s)\n' "$BULK_MOUNT" "$src" "$label" "$BULK_SSD_LABEL"
  elif [ "$fstype" != ext4 ]; then
    printf '%s의 형식이 %s다(기대 ext4)\n' "$BULK_MOUNT" "$fstype"
  else
    case ",${opts}," in
      *,rw,*) ;;
      *) printf '%s가 쓰기 가능(rw)이 아니다: %s. ext4 오류로 읽기 전용이 됐을 수 있다\n' "$BULK_MOUNT" "$opts" ;;
    esac
  fi
}

# stat_problem <stat -c '%u:%g %a %F' 출력> <기대 소유> <기대 모드> <기대 종류> <이름>: 다르면 한 줄 설명, 같으면 빈 출력.
# 빈 파일은 %F가 "regular empty file"이라 regular file로 맞춘다. 심링크는 따라가지 않는다(stat에 -L 없음).
stat_problem() {
  local got="${1/regular empty file/regular file}" expect="$2 $3 $4"
  [ "$got" = "$expect" ] || printf '%s: %s (기대 %s)\n' "$5" "${got:-없음}" "$expect"
}

# ledger_marker_ok <파일 내용>: 원장 계약 v1의 표식이면 0. 정확히 한 줄 + 개행이다. 봇(B2)이 같은 형식을 검사한다.
ledger_marker_ok() {
  local re
  re='^\{"format":"homelab-bot-deletion-ledger","version":1,"generation":"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}","initializedAt":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"\}'$'\n''$'
  [[ "$1" =~ $re ]]
}

# read_exact <변수> <명령...>: 명령 출력을 끝 개행까지 그대로 변수에 담는다. $(cat)은 끝 개행을 지워
# "한 줄 + 개행"을 가릴 수 없다. 같은 이유로 이 함수의 결과도 $(...)로 받지 않고 변수로 넘긴다.
read_exact() {
  local __c
  __c="$("${@:2}" && printf .)" || return 1
  printf -v "$1" '%s' "${__c%.}"
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
#
# 값이 빈 키(key: "" 또는 항목 없는 key:)도 "--키<TAB>"로 낸다. k3s는 빈 값도 --키=로 넘겨 키가 없을 때의
# 기본값과 다르다(cluster-domain: ""는 cluster.local이 아니다). 이 줄을 버리면 재시작 판단이 틀린다.
#
# config_pairs exact: install.sh가 재시작할지 고를 때 쓴다. 따옴표를 벗기지 않고 파일 순서를 지킨다.
# "0600"과 0600은 YAML에서 문자열과 8진수 정수라 k3s에 다른 값이 가고, 목록은 뒤 항목이 앞 항목을 덮을 수 있다.
# 주석과 빈 줄만 빼므로, 두 config의 exact 출력이 같으면 k3s가 받는 값도 같다.
config_pairs() {
  if [ "${1:-}" = exact ]; then
    config_pairs_awk 1
  else
    config_pairs_awk 0 | LC_ALL=C sort
  fi
}

config_pairs_awk() {
  awk -v exact="$1" '
    # 한 줄 스칼라. 따옴표 안의 #은 주석이 아니다. 닫히지 않은 따옴표, 닫은 뒤 주석 밖 글자는 bad.
    function scalar(v,   q, i, n, c) {
      bad = 0
      sub(/^[[:space:]]+/, "", v)
      q = substr(v, 1, 1)
      if (q != "\"" && q != "'\''") {
        sub(/[[:space:]]+#.*$/, "", v)
        sub(/[[:space:]]+$/, "", v)
        return v
      }
      n = length(v)
      for (i = 2; i <= n; i++) {
        c = substr(v, i, 1)
        if (q == "\"" && c == "\\") { i++; continue }
        if (c == q) {
          if (q == "'\''" && substr(v, i + 1, 1) == q) { i++; continue }
          break
        }
      }
      if (i > n || substr(v, i + 1) !~ /^([[:space:]]+#.*)?[[:space:]]*$/) { bad = 1; return "" }
      v = substr(v, 1, i)
      if (!exact && q == "\"") v = substr(v, 2, length(v) - 2)
      return v
    }
    # 값 없이 끝난 키: 다음 줄이 목록 항목이 아니면 빈 값이다.
    function flush() { if (pend != "") print "--" pend "\t"; pend = "" }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[a-z0-9-]+:/ {
      flush()
      key = $0; sub(/:.*/, "", key)
      raw = $0; sub(/^[^:]*:/, "", raw)
      list = ""
      if (raw ~ /^[[:space:]]*(#.*)?$/) { pend = key; list = key; next }
      val = scalar(raw)
      if (bad || raw !~ /^[[:space:]]/) { print "BAD\t" $0; next }
      print "--" key "\t" val
      next
    }
    /^[[:space:]]+-[[:space:]]/ {
      pend = ""
      raw = $0; sub(/^[[:space:]]+-/, "", raw)
      val = scalar(raw)
      if (list == "" || bad) { print "BAD\t" $0; next }
      print "--" list "\t" val
      next
    }
    { flush(); list = ""; print "BAD\t" $0 }
    END { flush() }
  '
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

# k3s config(stdin)의 tls-san 값을 한 줄에 하나씩 낸다.
tls_sans() { config_pairs | awk -F '\t' '$1 == "--tls-san" { print $2 }'; }

# NODE_IP:6443이 SNI 없이 내주는 서빙 인증서의 SAN(DNS·IP)을 한 줄에 하나씩 낸다. 못 받으면 빈 출력이다.
# 인자는 접속 상한(초). verify.sh check_san과 install.sh --k3s의 재시작 뒤 대기가 같은 판정을 쓴다.
# SNI를 보내지 않는 까닭은 verify.sh check_san 주석.
serving_sans() {
  local pem sans
  pem="$(timeout "$1" openssl s_client -connect "${NODE_IP}:6443" -noservername </dev/null 2>/dev/null)" || pem=""
  sans="$(openssl x509 -noout -ext subjectAltName <<<"$pem" 2>/dev/null)" || sans=""
  tr ',' '\n' <<<"$sans" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed -n -e 's/^DNS://p' -e 's/^IP Address://p'
}

# missing_sans <tls_sans 출력> <serving_sans 출력>: 인증서에 없는 tls-san을 한 줄에 하나씩 낸다.
# 줄 전체로 비교한다. 부분 일치는 짧은 이름이 빠져도 FQDN 항목에 걸려 통과한다.
missing_sans() {
  local s
  while IFS= read -r s; do
    [ -z "$s" ] || grep -qxF -- "$s" <<<"$2" || printf '%s\n' "$s"
  done <<<"$1"
}

# host/etc/의 모든 파일을 "원본<TAB>대상" 줄로 낸다. 확장자로 거르지 않는다. 화이트리스트는
# 목록 밖 확장자를 조용히 빠뜨린다. 0건이면 성공으로 읽지 않고 멈춘다.
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

# 렌더 결과(stdin)의 체인별 로그 규칙(limit rate N/단위 burst M packets log prefix "...")을 nft JSON 모양으로 낸다.
# {"체인":[{"limit":{...}},{"log":{...}}]}. 커널 판정이 로그 자리를 이 값과 정확히 대조한다.
egress_log_rules() {
  sed -n -E \
    -e 's/^[[:space:]]*chain ([a-z_]+) \{.*/C \1/p' \
    -e 's/^[[:space:]]*limit rate ([0-9]+)\/([a-z]+) burst ([0-9]+) packets log prefix "([^"]*)"$/L \1 \2 \3 \4/p' \
    | awk '$1 == "C" { c = $2; next } $1 == "L" { p = $0; sub(/^L [^ ]+ [^ ]+ [^ ]+ /, "", p); print c "\t" $2 "\t" $3 "\t" $4 "\t" p }' \
    | jq -R -s -c '
      [split("\n")[] | select(length > 0) | split("\t")
        | {key: .[0], value: [{limit: {rate: (.[1] | tonumber), burst: (.[3] | tonumber), per: .[2]}}, {log: {prefix: .[4]}}]}]
      | from_entries'
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
# 표 comment의 해시가 렌더 해시와 같아야 한다(파일만 바꾸고 reload를 빠뜨리면 여기서 걸린다). 해시는 올린 뒤
# 규칙을 바꿔도 따라 바뀌지 않는다. 그래서 체인마다 규칙을 자리별로 렌더의 규칙과 정확히 대조한다. 허용 verdict나
# 대역 포함만 보면 끝 drop이 남은 채 그 앞 로그 규칙을 counter accept로 바꾼 것, 클러스터 대역을 10.0.0.0/8로
# 넓힌 것이 통과한다. 주소는 구간으로 바꿔 비교한다. nft는 인접 CIDR을 합쳐 올리므로
# (10.42.0.0/16 + 10.43.0.0/16 -> 10.42.0.0/15) 합친 것은 같게, 넓힌 것은 다르게 읽는다.
# 표 flags도 본다. dormant는 규칙을 그대로 둔 채 base chain을 떼어 표 전체를 끈다.
# 아래 want는 host/egress/egress.nft의 규칙 줄과 하나씩 짝이다. 규칙을 바꾸면 둘을 함께 고친다. 줄 수가
# 어긋나면 여기서 실패하고, 실제 nft 출력과의 대조는 tools/host-egress.test.sh(--netns 포함)가 한다.
egress_kernel_problems() {
  local js rendered hash counts logs nonpublic dns
  js="$(cat)"
  rendered="$(render_egress)" || exit 1
  hash="$(sed -n 's/^[[:space:]]*comment "\(sha256:[0-9a-f]*\)"$/\1/p' <<<"$rendered")"
  counts="$(egress_rule_counts <<<"$rendered")"
  logs="$(egress_log_rules <<<"$rendered")"
  nonpublic="$(sed -n 's/^[[:space:]]*elements = { \(.*\) }$/\1/p' <<<"$rendered" | tr -d ' ' | tr ',' '\n' | jq -R . | jq -cs .)"
  # shellcheck disable=SC2086  # 공백으로 나눈 목록이다
  dns="$(printf '%s\n' $NODE_UPSTREAM_DNS | jq -R . | jq -cs .)"
  jq -r --arg hash "$hash" --arg pod "$POD_CIDR" --arg svc "$SERVICE_CIDR" --arg node "$NODE_IP" \
    --argjson counts "$counts" --argjson logs "$logs" --argjson nonpublic "$nonpublic" --argjson dns "$dns" '
    def ipint: if type == "string" and test("^[0-9]+([.][0-9]+){3}$")
      then split(".") | map(tonumber) | .[0] * 16777216 + .[1] * 65536 + .[2] * 256 + .[3] else null end;
    # 주소 원소 하나 -> [첫 주소, 끝 주소]. 모르는 꼴은 숫자가 아닌 쌍이라 어떤 기대와도 같지 않다.
    def span:
      if type == "string" then ipint as $a | [$a, $a]
      elif type == "object" and has("prefix") and (.prefix.addr | ipint) != null then
        pow(2; 32 - .prefix.len) as $b | ((((.prefix.addr | ipint) / $b) | floor) * $b) as $f | [$f, $f + $b - 1]
      elif type == "object" and has("range") then [(.range[0] | ipint), (.range[1] | ipint)]
      else [null, tojson] end;
    # 주소 하나나 익명 set -> 겹치거나 맞닿은 구간을 합친 목록
    def spans: [(if type == "object" and has("set") then .set[] else . end) | span] | sort
      | reduce .[] as $x ([]; (length - 1) as $i
          | if $i >= 0 and (.[$i][1] | type) == "number" and ($x[0] | type) == "number" and $x[0] <= .[$i][1] + 1
            then .[$i][1] = ([.[$i][1], $x[1]] | max) else . + [$x] end);
    def addr: . == {payload: {protocol: "ip", field: "daddr"}} or . == {payload: {protocol: "ip", field: "saddr"}};
    # 같은 뜻이면 같은 값: counter는 뺀다(세기만 한다). 주소는 구간 목록, 나머지 set·목록은 정렬.
    def canon: map(select(has("counter") | not))
      | map(if has("match") then .match |= (.left as $l | .right |= (
          if ($l | addr) and ((type == "string" and startswith("@")) | not) then {spans: spans}
          elif type == "object" and has("set") then {set: (.set | sort)}
          elif type == "array" then sort
          else . end)) else . end);
    def ip($f): {payload: {protocol: "ip", field: $f}};
    def eq($l; $r): {match: {op: "==", left: $l, right: $r}};
    def ne($l; $r): {match: {op: "!=", left: $l, right: $r}};
    def pfx($s): ($s | split("/")) as $p | {prefix: {addr: $p[0], len: ($p[1] | tonumber)}};
    def r_accept: {accept: null};
    def w_estab: ["established 반환", [{match: {op: "in", left: {ct: {key: "state"}}, right: ["established", "related"]}}, r_accept]];
    def w_node: ["노드 6443·10250", [eq(ip("daddr"); $node), eq({payload: {protocol: "tcp", field: "dport"}}; {set: [6443, 10250]}), r_accept]];
    def w_log($ch): ["verdict 없는 로그", ($logs[$ch] // [{"렌더에 로그 줄이 없다": null}])];
    def w_drop: ["끝 drop", [{drop: null}]];
    def want: {
      forward: [["파드 대역 출발 -> pod_egress", [eq(ip("saddr"); pfx($pod)), {jump: {target: "pod_egress"}}]]],
      input: [["lo 밖 파드 대역 출발 -> pod_to_node",
        [ne({meta: {key: "iifname"}}; "lo"), eq(ip("saddr"); pfx($pod)), {jump: {target: "pod_to_node"}}]]],
      pod_egress: [w_estab,
        ["파드·서비스 대역", [eq(ip("daddr"); {set: [pfx($pod), pfx($svc)]}), r_accept]],
        w_node,
        ["업스트림 DNS 53", [eq(ip("daddr"); {set: $dns}), eq({meta: {key: "l4proto"}}; {set: ["tcp", "udp"]}),
          eq({payload: {protocol: "th", field: "dport"}}; 53), r_accept]],
        ["공개 TCP 443", [ne(ip("daddr"); "@nonpublic"), eq({payload: {protocol: "tcp", field: "dport"}}; 443), r_accept]],
        ["공개 7844", [ne(ip("daddr"); "@nonpublic"), eq({meta: {key: "l4proto"}}; {set: ["tcp", "udp"]}),
          eq({payload: {protocol: "th", field: "dport"}}; 7844), r_accept]],
        w_log("pod_egress"), w_drop],
      pod_to_node: [w_estab, w_node, w_log("pod_to_node"), w_drop]
    };
    (.nftables // []) as $n
    | [$n[] | .table? // empty] as $t
    | [$n[] | .chain? // empty] as $c
    | [$n[] | .set? // empty | select(.name == "nonpublic")] as $s
    | def rules($ch): [$n[] | .rule? // empty | select(.chain == $ch) | .expr];
      def body($ch): rules($ch) as $r | want[$ch] as $w
        | (if ($r | length) == ($w | length) then empty else "\($ch): 규칙 수 \($r | length), 렌더 \($w | length)" end),
          (range(0; [($r | length), ($w | length)] | min) as $i
            | if ($r[$i] | canon) == ($w[$i][1] | canon) then empty
              else "\($ch): \($i + 1)번째 규칙이 렌더의 \($w[$i][0]) 규칙과 다르다: \($r[$i] | map(select(has("counter") | not)) | tojson)" end);
    (if (want | map_values(length)) == $counts then empty
      else "판정의 기대 규칙(host/lib.sh egress_kernel_problems)이 렌더(host/egress/egress.nft)와 어긋난다. 둘을 함께 고친다" end),
    (if ($t | length) == 0 then "표 inet homelab_egress가 없다" else empty end),
    (if ($t | length) == 1 and $t[0].comment != $hash
      then "표 해시가 지금 렌더와 다르다(커널 \($t[0].comment // "없음"), 렌더 \($hash)). 파일만 바꾸고 reload를 빠뜨렸거나 다른 규칙이 올라와 있다"
      else empty end),
    (if ($t | length) == 1 and ($t[0].flags // [] | if type == "array" then . else [.] end | length) > 0
      then "표 flags가 \($t[0].flags | tojson)다(렌더에는 없다). dormant면 규칙이 남아 있어도 표 전체가 패킷을 보지 않는다"
      else empty end),
    (if ($t | length) == 0 then empty else (
      ([$c[] | select(.hook != null) | "\(.name)/\(.hook)/\(.type)/\(.prio)/\(.policy)"] | sort) as $b
      | (if $b == ["forward/forward/filter/0/accept", "input/input/filter/0/accept"] then empty
         else "base chain이 forward·input(filter, priority 0, policy accept) 둘이 아니다: \($b | join(", "))" end),
      (if ([$c[] | .name] | sort) == ($counts | keys | sort) then empty else "체인 목록이 렌더와 다르다: \([$c[] | .name] | sort | join(","))" end),
      (want | keys_unsorted[] as $ch | body($ch)),
      (if ($s | length) == 1 and ({set: $s[0].elem} | spans) == ({set: ($nonpublic | map(pfx(.)))} | spans)
        then empty else "set nonpublic 원소가 렌더와 다르다" end)
    ) end)
  ' <<<"$js"
}
