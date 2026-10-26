#!/usr/bin/env bash
# 파드 egress 규칙(host/egress/, host/lib.sh render_egress) 시험. 같은 host/lib.sh의 Tailscale 기기 이름 대조
# (resolve_magicdns, TAILNET_DEVICE_NAME)도 여기서 본다.
#
#   bash tools/host-egress.test.sh          렌더 시험과 verify.sh 판정(가짜 sudo·nft). ci가 부른다. root·nft 없이 돈다.
#   bash tools/host-egress.test.sh --netns  rootless podman 컨테이너 안의 네트워크 네임스페이스에 운영 렌더를 올려
#                                           실제 허용·차단과 실제 커널 표에 대한 verify.sh 판정을 본다.
#                                           ci 밖에서 사람이 돌린다. 호스트 네트워크는 건드리지 않는다.
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

# check_order <렌더 파일> <체인> <통과 설명> <정규식...>: 체인의 줄이 정규식과 수·순서까지 같아야 한다.
check_order() {
  local file="$1" chain="$2" desc="$3" lines got n i=0
  shift 3
  lines="$(chain_lines "$file" "$chain")"
  n="$(grep -c . <<<"$lines" || true)"
  if [ "$n" -ne "$#" ]; then
    fail "${chain} 규칙이 ${n}줄이다(기대 $#):"$'\n'"${lines}"
    return
  fi
  while IFS= read -r got; do
    i=$((i + 1))
    [[ "$got" =~ ${!i} ]] || { fail "${chain} ${i}번째 줄이 다르다: ${got}"; return; }
  done <<<"$lines"
  pass "${chain}: ${desc}"
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

  # --- base chain 둘: 파드 대역 출발만 넘기고 나머지는 지나간다. input은 노드 자신이 보낸 것(lo)을 뺀다.
  # shellcheck disable=SC2016  # $POD_CIDR 등은 nft 변수 글자 그대로다
  check_order "$TMP/prod.nft" forward "파드 대역 출발만 pod_egress로" \
    '^type filter hook forward priority filter; policy accept;$' \
    '^ip saddr \$POD_CIDR jump pod_egress$'
  # shellcheck disable=SC2016
  check_order "$TMP/prod.nft" input "lo 밖의 파드 대역 출발만 pod_to_node로" \
    '^type filter hook input priority filter; policy accept;$' \
    '^iifname != "lo" ip saddr \$POD_CIDR jump pod_to_node$'

  # --- 순서: 허용 -> 로그 -> drop. 허용이 drop 뒤에 오면 쓰이지 않는다.
  # shellcheck disable=SC2016
  check_order "$TMP/prod.nft" pod_egress "established -> 대역 -> 노드 6443·10250 -> DNS 53 -> 공개 443 -> 공개 7844 -> drop" \
    '^ct state established,related counter accept$' \
    '^ip daddr \{ \$POD_CIDR, \$SERVICE_CIDR \} counter accept$' \
    '^ip daddr \$NODE_IP tcp dport \{ 6443, 10250 \} counter accept$' \
    '^ip daddr \$UPSTREAM_DNS meta l4proto \{ tcp, udp \} th dport 53 counter accept$' \
    '^ip daddr != @nonpublic tcp dport 443 counter accept$' \
    '^ip daddr != @nonpublic meta l4proto \{ tcp, udp \} th dport 7844 counter accept$' \
    '^limit rate [0-9]+/minute burst [0-9]+ packets log prefix "homelab-egress drop: "$' \
    '^counter drop$'
  # shellcheck disable=SC2016
  check_order "$TMP/prod.nft" pod_to_node "established -> 노드 6443·10250 -> drop" \
    '^ct state established,related counter accept$' \
    '^ip daddr \$NODE_IP tcp dport \{ 6443, 10250 \} counter accept$' \
    '^limit rate [0-9]+/minute burst [0-9]+ packets log prefix "homelab-egress node drop: "$' \
    '^counter drop$'
  # 열지 않기로 한 포트(Tailscale direct·STUN, 22, 80)가 허용에 끼면 안 된다.
  lines="$(chain_lines "$TMP/prod.nft" pod_egress; chain_lines "$TMP/prod.nft" pod_to_node)"
  if grep -E 'accept' <<<"$lines" | grep -qE '41641|3478|dport (22|80)\b'; then
    fail "허용에 41641·3478·22·80이 있다"
  else
    pass "41641·3478·22·80은 허용에 없다"
  fi

  # --- 렌더 해시: 표 comment가 자리표시를 뺀 렌더의 sha256이고, 값이나 본문이 바뀌면 달라진다.
  # verify.sh가 이 해시로 커널 표가 지금 렌더로 올라와 있는지(reload를 빠뜨리지 않았는지) 본다.
  local h1 h2 unhashed
  h1="$(sed -n 's/^[[:space:]]*comment "\(sha256:[0-9a-f]\{64\}\)"$/\1/p' "$TMP/prod.nft")"
  # shellcheck source=../host/lib.sh
  unhashed="$(. "$TMP/base/host/lib.sh" && load_cluster prod && egress_unhashed)"
  if [ -n "$h1" ] && [ "$h1" = "sha256:$(printf '%s\n' "$unhashed" | sha256sum | cut -d ' ' -f 1)" ] \
    && ! grep -q '@EGRESS_HASH@' "$TMP/prod.nft"; then
    pass "표 comment = 렌더 해시(${h1:0:19}…), 자리표시 없음"
  else
    fail "표 comment 해시가 없거나 렌더와 다르다: ${h1:-없음}"
  fi
  fake_env base thash NODE_IP=192.168.117.16
  h2="$(render base thash | sed -n 's/^[[:space:]]*comment "\(sha256:[0-9a-f]*\)"$/\1/p')"
  if [ -n "$h2" ] && [ "$h2" != "$h1" ]; then pass "값이 바뀌면 해시가 바뀐다"; else fail "NODE_IP를 바꿔도 해시가 같다"; fi

  # --- 체인별 규칙 수(verify.sh가 커널 규칙 수와 대조한다)
  # shellcheck source=../host/lib.sh
  got="$(. "$TMP/base/host/lib.sh" && egress_rule_counts <"$TMP/prod.nft")"
  want='{"forward":1,"input":1,"pod_to_node":4,"pod_egress":8}'
  if [ "$got" = "$want" ]; then pass "규칙 수 ${want}"; else fail "규칙 수가 다르다: ${got}"; fi

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

# verify.sh의 check_egress·finish를 가짜 명령으로 돌리는 도구를 TMP에 만든다. ci와 --netns가 함께 쓴다.
#   stub/: id·sudo·nft는 STUB_* 값에 따라 흉내 내고, 값이 없으면 PATH의 다음 진짜 명령을 부른다.
#          systemctl·kubectl은 늘 가짜다(유닛 enabled·active, 라이브 podCIDR·Service IP).
#   vh.sh <host 사본> <작업 폴더>: 렌더를 작업 폴더에 깔린 파일로 두고 check_egress, finish. 종료 코드가 verify의 것이다.
make_verify_kit() {
  mkdir -p "$TMP/stub"
  cat >"$TMP/stub/id" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = -u ] && [ -n "${STUB_UID:-}" ]; then echo "$STUB_UID"; exit 0; fi
PATH="${PATH#*:}" exec id "$@"
STUB
  cat >"$TMP/stub/sudo" <<'STUB'
#!/usr/bin/env bash
case "${STUB_SUDO:-no}" in
  no) echo "sudo: a password is required" >&2; exit 1 ;;
  yes) [ "${1:-}" != -n ] || shift; exec "$@" ;;
esac
STUB
  cat >"$TMP/stub/nft" <<'STUB'
#!/usr/bin/env bash
case "${STUB_NFT:-real}" in
  real) PATH="${PATH#*:}" exec nft "$@" ;;
  missing) echo "Error: No such file or directory" >&2; exit 1 ;;
  empty) echo '{"nftables": [{"metainfo": {"version": "1.1.6"}}]}' ;;
esac
STUB
  cat >"$TMP/stub/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in is-enabled) echo enabled ;; is-active) echo active ;; *) exit 9 ;; esac
STUB
  cat >"$TMP/stub/kubectl" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" get node "*) printf '10.42.0.0/24' ;;
  *" get svc kubernetes "*) printf '10.43.0.1' ;;
  *) exit 9 ;;
esac
STUB
  cat >"$TMP/vh.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. "$1/verify.sh"
load_cluster prod
EGRESS_RULES="$2/egress.nft"
EGRESS_UNIT="$2/homelab-egress.service"
mkdir -p "$2"
render_egress >"$EGRESS_RULES"
cp "$1/egress/homelab-egress.service" "$EGRESS_UNIT"
check_egress
finish
STUB
  chmod +x "$TMP"/stub/* "$TMP/vh.sh"
}

# 커널 표를 읽지 못하거나 표가 없으면 verify가 0으로 끝나면 안 된다(#919 리뷰 P2).
# 실제 커널 표에 대한 양성·음성은 --netns가 본다.
verify_tests() {
  local out rc c want_rc want_text desc
  copy_host base
  make_verify_kit
  local -a cases=(
    "2|SKIP|root 아님, sudo -n 불가 -> 미검증(2)|STUB_UID=1000 STUB_SUDO=no"
    "1|커널에 table inet homelab_egress가 없다|sudo -n 되고 표 없음 -> 실패(1)|STUB_UID=1000 STUB_SUDO=yes STUB_NFT=missing"
    "1|커널에 table inet homelab_egress가 없다|root이고 표 없음 -> 실패(1)|STUB_UID=0 STUB_NFT=missing"
    "1|표 inet homelab_egress가 없다|nft가 빈 목록을 냄 -> 실패(1)|STUB_UID=1000 STUB_SUDO=yes STUB_NFT=empty"
  )
  for c in "${cases[@]}"; do
    IFS='|' read -r want_rc want_text desc c <<<"$c"
    rc=0
    # shellcheck disable=SC2086  # c는 VAR=값 목록이다
    out="$(env $c PATH="$TMP/stub:$PATH" bash "$TMP/vh.sh" "$TMP/base/host" "$TMP/vw" 2>&1)" || rc=$?
    if [ "$rc" = "$want_rc" ] && grep -qF -- "$want_text" <<<"$out" && ! grep -q '^verify 통과\|^==> verify 통과' <<<"$out"; then
      pass "verify ${desc}"
    else
      fail "verify ${desc}: 종료 ${rc}"$'\n'"${out}"
    fi
  done
}

# egress_kernel_problems를 nft JSON으로 직접 시험한다. ci에는 nft가 없어 --netns가 보는 실제 커널 대신,
# 운영 렌더를 nft 1.1.6에 올려 받은 `nft -j list table` 출력을 fixture로 두고 고친다(해시·nonpublic만 채운다).
# 클러스터 대역 두 /16은 nft가 /15 하나로 합친 그대로다. egress.nft 규칙을 바꾸면 이 fixture도 다시 받는다.
kernel_json_tests() {
  local hash np base row want desc mut out
  copy_host kj
  fake_env kj tkj NODE_IP=192.168.117.15 POD_CIDR=10.42.0.0/16 SERVICE_CIDR=10.43.0.0/16
  sed -i -E 's|^NODE_UPSTREAM_DNS=.*$|NODE_UPSTREAM_DNS="1.1.1.1 9.9.9.9"|' "$TMP/kj/host/versions.env"
  hash="$(render kj tkj | sed -n 's/^[[:space:]]*comment "\(sha256:[0-9a-f]*\)"$/\1/p')"
  # nonpublic의 CGNAT 대역 글자는 gitleaks tailscale-ip 룰이 접두 길이 없이 잡는다. 렌더 줄에서 만든다.
  np="$(render kj tkj | sed -n 's/^[[:space:]]*elements = { \(.*\) }$/\1/p' | tr -d ' ' | tr ',' '\n' \
    | jq -R 'split("/") | {prefix: {addr: .[0], len: (.[1] | tonumber)}}' | jq -cs .)"
  base="$(jq -c --arg h "$hash" --argjson np "$np" \
    '(.nftables[] | select(.table) | .table.comment) = $h | (.nftables[] | select(.set) | .set.elem) = $np' <<'JSON'
{"nftables":[{"metainfo":{"version":"1.1.6","release_name":"Commodore Bullmoose #7","json_schema_version":1}},
{"table":{"family":"inet","name":"homelab_egress","handle":2,"comment":"@HASH@"}},
{"chain":{"family":"inet","table":"homelab_egress","name":"forward","handle":1,"type":"filter","hook":"forward","prio":0,"policy":"accept"}},
{"chain":{"family":"inet","table":"homelab_egress","name":"input","handle":2,"type":"filter","hook":"input","prio":0,"policy":"accept"}},
{"chain":{"family":"inet","table":"homelab_egress","name":"pod_to_node","handle":3}},
{"chain":{"family":"inet","table":"homelab_egress","name":"pod_egress","handle":4}},
{"set":{"family":"inet","name":"nonpublic","table":"homelab_egress","type":"ipv4_addr","handle":5,"flags":["interval"],"elem":"@NONPUBLIC@"}},
{"rule":{"family":"inet","table":"homelab_egress","chain":"forward","handle":6,"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":{"prefix":{"addr":"10.42.0.0","len":16}}}},{"jump":{"target":"pod_egress"}}]}},
{"rule":{"family":"inet","table":"homelab_egress","chain":"input","handle":7,"expr":[{"match":{"op":"!=","left":{"meta":{"key":"iifname"}},"right":"lo"}},{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":{"prefix":{"addr":"10.42.0.0","len":16}}}},{"jump":{"target":"pod_to_node"}}]}},
{"rule":{"family":"inet","table":"homelab_egress","chain":"pod_to_node","handle":8,"expr":[{"match":{"op":"in","left":{"ct":{"key":"state"}},"right":["established","related"]}},{"counter":{"packets":0,"bytes":0}},{"accept":null}]}},
{"rule":{"family":"inet","table":"homelab_egress","chain":"pod_to_node","handle":10,"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"daddr"}},"right":"192.168.117.15"}},{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":{"set":[6443,10250]}}},{"counter":{"packets":0,"bytes":0}},{"accept":null}]}},
{"rule":{"family":"inet","table":"homelab_egress","chain":"pod_to_node","handle":11,"expr":[{"limit":{"rate":10,"burst":20,"per":"minute"}},{"log":{"prefix":"homelab-egress node drop: "}}]}},
{"rule":{"family":"inet","table":"homelab_egress","chain":"pod_to_node","handle":12,"expr":[{"counter":{"packets":0,"bytes":0}},{"drop":null}]}},
{"rule":{"family":"inet","table":"homelab_egress","chain":"pod_egress","handle":13,"expr":[{"match":{"op":"in","left":{"ct":{"key":"state"}},"right":["established","related"]}},{"counter":{"packets":0,"bytes":0}},{"accept":null}]}},
{"rule":{"family":"inet","table":"homelab_egress","chain":"pod_egress","handle":15,"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"daddr"}},"right":{"set":[{"prefix":{"addr":"10.42.0.0","len":15}}]}}},{"counter":{"packets":0,"bytes":0}},{"accept":null}]}},
{"rule":{"family":"inet","table":"homelab_egress","chain":"pod_egress","handle":17,"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"daddr"}},"right":"192.168.117.15"}},{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":{"set":[6443,10250]}}},{"counter":{"packets":0,"bytes":0}},{"accept":null}]}},
{"rule":{"family":"inet","table":"homelab_egress","chain":"pod_egress","handle":20,"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"daddr"}},"right":{"set":["1.1.1.1","9.9.9.9"]}}},{"match":{"op":"==","left":{"meta":{"key":"l4proto"}},"right":{"set":["tcp","udp"]}}},{"match":{"op":"==","left":{"payload":{"protocol":"th","field":"dport"}},"right":53}},{"counter":{"packets":0,"bytes":0}},{"accept":null}]}},
{"rule":{"family":"inet","table":"homelab_egress","chain":"pod_egress","handle":21,"expr":[{"match":{"op":"!=","left":{"payload":{"protocol":"ip","field":"daddr"}},"right":"@nonpublic"}},{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":443}},{"counter":{"packets":0,"bytes":0}},{"accept":null}]}},
{"rule":{"family":"inet","table":"homelab_egress","chain":"pod_egress","handle":23,"expr":[{"match":{"op":"!=","left":{"payload":{"protocol":"ip","field":"daddr"}},"right":"@nonpublic"}},{"match":{"op":"==","left":{"meta":{"key":"l4proto"}},"right":{"set":["tcp","udp"]}}},{"match":{"op":"==","left":{"payload":{"protocol":"th","field":"dport"}},"right":7844}},{"counter":{"packets":0,"bytes":0}},{"accept":null}]}},
{"rule":{"family":"inet","table":"homelab_egress","chain":"pod_egress","handle":24,"expr":[{"limit":{"rate":10,"burst":20,"per":"minute"}},{"log":{"prefix":"homelab-egress drop: "}}]}},
{"rule":{"family":"inet","table":"homelab_egress","chain":"pod_egress","handle":25,"expr":[{"counter":{"packets":0,"bytes":0}},{"drop":null}]}}]}
JSON
  )"
  # 변형(jq): r(체인; 자리)는 그 체인 몇 번째(0부터) 규칙의 expr, setr은 그것을 바꾼다. bands는 클러스터 대역 값을 바꾼다.
  # shellcheck disable=SC2016  # jq 변수다
  local defs='def ridx($c): [.nftables | to_entries[] | select(.value.rule.chain? == $c) | .key];
    def r($c; $i): .nftables[ridx($c)[$i]].rule.expr;
    def setr($c; $i; $v): .nftables[ridx($c)[$i]].rule.expr = $v;
    def bands($v): walk(if . == {set: [{prefix: {addr: "10.42.0.0", len: 15}}]} then $v else . end);'
  local -a cases=(
    "|fixture 그대로(nft가 합친 /15)|."
    "|클러스터 대역을 두 /16으로(합치기 전 꼴)|bands({set: [{prefix: {addr: \"10.43.0.0\", len: 16}}, {prefix: {addr: \"10.42.0.0\", len: 16}}]})"
    "|클러스터 대역을 range로|bands({set: [{range: [\"10.42.0.0\", \"10.43.255.255\"]}]})"
    "|counter가 없는 규칙(세기만 다름)|walk(if type == \"array\" then map(select(type != \"object\" or (has(\"counter\") | not))) else . end)"
    "표 flags가 [\"dormant\"]다|표를 dormant로 끔|(.nftables[] | select(.table) | .table.flags) = [\"dormant\"]"
    "표 flags가 \"dormant\"다|flags가 배열 아닌 글자|(.nftables[] | select(.table) | .table.flags) = \"dormant\""
    "pod_to_node: 3번째 규칙이 렌더의 verdict 없는 로그 규칙과 다르다|pod_to_node 로그 자리를 counter accept로|setr(\"pod_to_node\"; 2; [{counter: {packets: 0, bytes: 0}}, {accept: null}])"
    "pod_egress: 7번째 규칙이 렌더의 verdict 없는 로그 규칙과 다르다|pod_egress 로그 자리를 counter accept로|setr(\"pod_egress\"; 6; [{counter: {packets: 0, bytes: 0}}, {accept: null}])"
    "pod_egress: 7번째 규칙이 렌더의 verdict 없는 로그 규칙과 다르다|pod_egress 로그 뒤에 accept를 붙임|setr(\"pod_egress\"; 6; r(\"pod_egress\"; 6) + [{accept: null}])"
    "pod_egress: 7번째 규칙이 렌더의 verdict 없는 로그 규칙과 다르다|로그 rate를 바꿈|setr(\"pod_egress\"; 6; [{limit: {rate: 1000, burst: 20, per: \"second\"}}, {log: {prefix: \"homelab-egress drop: \"}}])"
    "pod_egress: 2번째 규칙이 렌더의 파드·서비스 대역 규칙과 다르다|클러스터 대역을 10.0.0.0/8로 넓힘|bands({prefix: {addr: \"10.0.0.0\", len: 8}})"
    "pod_egress: 2번째 규칙이 렌더의 파드·서비스 대역 규칙과 다르다|클러스터 대역을 /14로 넓힘(인접 확대)|bands({set: [{prefix: {addr: \"10.40.0.0\", len: 14}}]})"
    "pod_egress: 2번째 규칙이 렌더의 파드·서비스 대역 규칙과 다르다|클러스터 대역에 다른 대역을 더함|bands({set: [{prefix: {addr: \"10.42.0.0\", len: 15}}, {prefix: {addr: \"10.99.0.0\", len: 24}}]})"
    "pod_egress: 2번째 규칙이 렌더의 파드·서비스 대역 규칙과 다르다|클러스터 대역을 파드 대역만으로 좁힘|bands({set: [{prefix: {addr: \"10.42.0.0\", len: 16}}]})"
    "pod_to_node: 2번째 규칙이 렌더의 노드 6443·10250 규칙과 다르다|노드 허용에 22를 더함|setr(\"pod_to_node\"; 1; r(\"pod_to_node\"; 1) | (.[1].match.right.set += [22]))"
    "pod_egress: 4번째 규칙이 렌더의 업스트림 DNS 53 규칙과 다르다|업스트림 DNS에 8.8.8.8을 더함|setr(\"pod_egress\"; 3; r(\"pod_egress\"; 3) | (.[0].match.right.set += [\"8.8.8.8\"]))"
    "pod_egress: 5번째 규칙이 렌더의 공개 TCP 443 규칙과 다르다|공개 443에서 nonpublic 조건을 뺌|setr(\"pod_egress\"; 4; r(\"pod_egress\"; 4) | .[1:])"
    "base chain이 forward·input(filter, priority 0, policy accept) 둘이 아니다|forward priority를 바꿈|(.nftables[] | select(.chain.name? == \"forward\") | .chain.prio) = -300"
    "set nonpublic 원소가 렌더와 다르다|nonpublic에서 LAN 대역을 뺌|(.nftables[] | select(.set) | .set.elem) |= map(select(.prefix.addr != \"192.168.0.0\"))"
  )
  for row in "${cases[@]}"; do
    IFS='|' read -r want desc mut <<<"$row"
    out="$(jq -c "${defs} ${mut}" <<<"$base" | (
      # shellcheck source=../host/lib.sh
      . "$TMP/kj/host/lib.sh"
      load_cluster tkj
      egress_kernel_problems
    ) 2>&1)" || { fail "커널 판정 ${desc}: 실행 실패: ${out}"; continue; }
    if [ -z "$want" ]; then
      if [ -z "$out" ]; then pass "커널 판정 통과: ${desc}"; else fail "커널 판정 ${desc}: 통과여야 한다:"$'\n'"${out}"; fi
    elif grep -qF -- "$want" <<<"$out"; then
      pass "커널 판정 실패: ${desc}"
    else
      fail "커널 판정 ${desc}: '${want}'가 없다:"$'\n'"${out:-출력 없음}"
    fi
  done
}

# resolve_magicdns: 실제 MagicDNS 이름의 첫 라벨을 TAILNET_DEVICE_NAME(비면 NODE_NAME)과 대조한다.
# 옛 기기가 남아 -1이 붙은 재등록은 계속 잡고, 일부러 바꾼 이름은 값 파일로 받아들인다.
device_name_tests() {
  local suffix out row spec cluster label want_rc want_text desc rc
  # 실제 꼴의 tailnet 이름은 저장소에 적지 않는다(gitleaks). ci의 gitleaks 시험처럼 실행 때 조립한다.
  suffix="example.$(printf '%s.%s' ts net)"
  copy_host dev
  mkdir -p "$TMP/tsstub"
  cat >"$TMP/tsstub/tailscale" <<'STUB'
#!/usr/bin/env bash
jq -n --arg n "${STUB_TS_LABEL}.${STUB_TS_SUFFIX}." '{BackendState: "Running", Self: {DNSName: $n}}'
STUB
  chmod +x "$TMP/tsstub/tailscale"
  fake_env dev tdevempty TAILNET_DEVICE_NAME=
  fake_env dev tdevfqdn TAILNET_DEVICE_NAME=nuc-pro.example
  local -a cases=(
    "0|nuc-pro.${suffix}|prod: 기기 이름 nuc-pro = TAILNET_DEVICE_NAME|prod nuc-pro"
    "1|첫 라벨(nuc-pro-1)이 TAILNET_DEVICE_NAME(nuc-pro)과 다르다|prod: 옛 기기가 남아 -1이 붙음|prod nuc-pro-1"
    "1|첫 라벨(nuc-15-pro)이 TAILNET_DEVICE_NAME(nuc-pro)과 다르다|prod: 바꾸기 전 이름|prod nuc-15-pro"
    "0|nuc-15-pro.${suffix}|비면 NODE_NAME과 대조|tdevempty nuc-15-pro"
    "1|TAILNET_DEVICE_NAME이 DNS 라벨이 아니다|전체 이름을 넣으면 거부|tdevfqdn nuc-pro"
  )
  for row in "${cases[@]}"; do
    IFS='|' read -r want_rc want_text desc spec <<<"$row"
    read -r cluster label <<<"$spec"
    rc=0
    out="$({
      export PATH="$TMP/tsstub:$PATH" STUB_TS_LABEL="$label" STUB_TS_SUFFIX="$suffix"
      # shellcheck source=../host/lib.sh
      . "$TMP/dev/host/lib.sh"
      load_cluster "$cluster"
      resolve_magicdns
      printf '%s' "$NODE_MAGICDNS"
    } 2>&1)" || rc=$?
    if [ "$rc" = "$want_rc" ] && grep -qF -- "$want_text" <<<"$out"; then pass "기기 이름 ${desc}"; else fail "기기 이름 ${desc}: 종료 ${rc}: ${out}"; fi
  done
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
# /host는 host/ 사본, /stub·/vh.sh는 make_verify_kit의 도구다.
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
# kube-proxy·CNI portmap 흉내: kubernetes Service는 노드 IP:6443으로, hostPort는 파드로 PREROUTING에서 DNAT한다.
printf "%s\n" "table ip nat {" "  chain prerouting {" "    type nat hook prerouting priority dstnat; policy accept;" \
  "    ip daddr 10.43.0.1 tcp dport 443 dnat to $NODE_IP:6443" \
  "    fib daddr type local tcp dport 1053 dnat to 10.42.1.6:8080" "  }" "}" | nft -f -

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
serve - tcp 6443 10250 22 9100
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
  expect pass "LAN -> 파드 반환(established)" world tcp 10.42.0.5 8080
  expect pass "노드 자신(OUTPUT)" - tcp 203.0.113.10 22
  expect pass "파드 대역 밖 forward" other tcp 203.0.113.10 22
  # 파드 -> 노드 자신(INPUT)
  expect pass "노드 kube API" pod tcp "$NODE_IP" 6443
  expect pass "노드 kubelet" pod tcp "$NODE_IP" 10250
  expect pass "kube API Service(DNAT -> 노드 6443)" pod tcp 10.43.0.1 443
  expect pass "hostPort(DNAT -> 파드)" pod tcp "$NODE_IP" 1053
  expect drop "노드 sshd(LAN 주소)" pod tcp "$NODE_IP" 22
  expect drop "노드의 다른 포트" pod tcp "$NODE_IP" 9100
  expect drop "cni0 게이트웨이 sshd" pod tcp 10.42.0.1 22
  expect pass "LAN -> hostPort" world tcp "$NODE_IP" 1053
  expect pass "관리자 LAN SSH" world tcp "$NODE_IP" 22
  expect pass "노드 자신 -> cni0 주소(lo, 출발이 파드 대역)" - tcp 10.42.0.1 22
  expect pass "노드 -> 파드(probe)와 응답" - tcp 10.42.0.5 8080
}

echo "== 1. 규칙만"
matrix
NODE_HITS="$(nft list chain inet homelab_egress pod_egress | sed -n "s/.*dport { 6443, 10250 } counter packets \([0-9]*\) .*/\1/p")"
if [ "$NODE_HITS" = 0 ]; then echo "ok   노드 6443·10250 허용 줄 카운터 0: 파드 -> 노드 IP는 INPUT이라 이 체인에 오지 않는다"
else echo "FAIL 노드 6443·10250 허용 줄 카운터 ${NODE_HITS:-?}" >&2; FAILS=$((FAILS + 1)); fi

echo "== 1b. 노드의 tailnet 주소(world의 100.100.100.100을 노드로 옮겨 본다)"
# 주소를 변수로 둔다. gitleaks는 이 고정 주소 글자만 면제하고 /32가 붙은 꼴은 잡는다.
TSA=100.100.100.100
ns world ip addr del "$TSA/32" dev lo
ip link add ts0 type dummy; ip addr add "$TSA/32" dev ts0; ip link set ts0 up
ns world ip route add "$TSA/32" via "$NODE_IP"
expect drop "노드 tailnet 주소 sshd" pod tcp 100.100.100.100 22
expect pass "관리자 tailnet SSH" world tcp 100.100.100.100 22
expect pass "노드 자신 -> tailnet 주소" - tcp 100.100.100.100 22
ns world ip route del "$TSA/32"; ip link del ts0; ns world ip addr add "$TSA/32" dev lo

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

echo "== 4. verify.sh 판정(실제 커널 표). 0만 통과다"
vexpect() { # vexpect <기대 종료 코드> <설명> <host 사본> [<출력에 있어야 할 글자>]
  local rc=0
  PATH="/stub:$PATH" bash /vh.sh "$3" /tmp/vw >/tmp/vh.out 2>&1 || rc=$?
  if [ "$rc" = "$1" ] && { [ -z "${4:-}" ] || grep -qF -- "$4" /tmp/vh.out; }; then echo "ok   verify $rc  $2"
  else echo "FAIL verify $rc(기대 $1)  $2" >&2; sed "s/^/       /" /tmp/vh.out >&2; FAILS=$((FAILS + 1)); fi
}
handle() { nft -a list chain inet homelab_egress "$1" | awk -v re="$2" "\$0 ~ re { print \$NF }"; }
vexpect 0 "규칙이 지금 렌더대로" /host
nft delete rule inet homelab_egress pod_egress handle "$(handle pod_egress "th dport 53")"
vexpect 1 "DNS 허용 규칙을 지움" /host "pod_egress: 규칙 수 7, 렌더 8"; nft -f "$R"
nft delete rule inet homelab_egress pod_to_node handle "$(handle pod_to_node " drop # handle")"
vexpect 1 "pod_to_node의 drop을 지움" /host "pod_to_node: 규칙 수 3, 렌더 4"; nft -f "$R"
nft insert rule inet homelab_egress pod_to_node tcp dport 22 accept
vexpect 1 "pod_to_node 앞에 22 허용을 끼움" /host "pod_to_node: 규칙 수 5"; nft -f "$R"
# 규칙 수·끝 drop·해시가 그대로인 변경(#919 리뷰). 먼저 실제로 열리는지 보여 판정이 잡아야 하는 상태임을 확인한다.
nft add table inet homelab_egress "{ flags dormant; }"
expect pass "dormant: 표가 꺼져 공개 22가 열림" pod tcp 203.0.113.10 22
vexpect 1 "표를 dormant로 끔(규칙은 그대로)" /host "표 flags가 [\"dormant\"]다"
nft add table inet homelab_egress
expect drop "dormant를 풂: 공개 22 다시 막힘" pod tcp 203.0.113.10 22
vexpect 0 "dormant를 풂(flags 없이 add table)" /host
nft replace rule inet homelab_egress pod_to_node handle "$(handle pod_to_node "log prefix")" counter accept
expect pass "pod_to_node 로그 자리를 accept로: 노드 sshd가 열림" pod tcp "$NODE_IP" 22
vexpect 1 "pod_to_node 로그 자리를 counter accept로 바꿈" /host "pod_to_node: 3번째 규칙이 렌더의 verdict 없는 로그 규칙과 다르다"; nft -f "$R"
nft replace rule inet homelab_egress pod_egress handle "$(handle pod_egress "log prefix")" counter accept
expect pass "pod_egress 로그 자리를 accept로: 공개 80이 열림" pod tcp 203.0.113.10 80
vexpect 1 "pod_egress 로그 자리를 counter accept로 바꿈" /host "pod_egress: 7번째 규칙이 렌더의 verdict 없는 로그 규칙과 다르다"; nft -f "$R"
nft replace rule inet homelab_egress pod_egress handle "$(handle pod_egress "ip daddr [{] 10[.]")" ip daddr 10.0.0.0/8 counter accept
expect pass "클러스터 대역을 10/8로 넓힘: 10.0.0.5:443이 열림" pod tcp 10.0.0.5 443
vexpect 1 "클러스터 대역을 10.0.0.0/8로 넓힘" /host "pod_egress: 2번째 규칙이 렌더의 파드·서비스 대역 규칙과 다르다"; nft -f "$R"
nft replace rule inet homelab_egress pod_egress handle "$(handle pod_egress "ip daddr [{] 10[.]")" ip daddr "{ 10.42.0.0/16, 10.43.0.0/16, 10.99.0.0/24 }" counter accept
vexpect 1 "클러스터 대역에 다른 대역을 더함" /host "pod_egress: 2번째 규칙이 렌더의 파드·서비스 대역 규칙과 다르다"; nft -f "$R"
nft delete element inet homelab_egress nonpublic "{ 192.168.0.0/16 }"
vexpect 1 "nonpublic에서 LAN 대역을 뺌" /host "set nonpublic"; nft -f "$R"
nft delete table inet homelab_egress
vexpect 1 "표를 지움(flush ruleset 등)" /host "커널에 table inet homelab_egress가 없다"; nft -f "$R"
cp -R /host /tmp/h2; echo "# Git에서 바뀐 줄" >>/tmp/h2/egress/egress.nft
vexpect 1 "Git·파일은 새것, 커널은 옛것(reload 미실행)" /tmp/h2 "표 해시가 지금 렌더와 다르다"
vexpect 0 "다시 원래 렌더" /host

echo "== 5. 끄기(--egress-off의 nft 부분) 뒤에는 막히지 않는다"
nft delete table inet homelab_egress
expect pass "공개 22(끈 뒤)" pod tcp 203.0.113.10 22

[ "$FAILS" -eq 0 ] || { echo "netns: ${FAILS}개 실패" >&2; exit 1; }
echo "netns 통과"
'

netns_test() {
  local out
  command -v podman >/dev/null 2>&1 || { fail "podman이 없다"; return; }
  copy_host base
  make_verify_kit
  out="$(render base prod 2>&1)" || { fail "prod 렌더 실패: ${out}"; return; }
  printf '%s\n' "$out" >"$TMP/prod.nft"
  # --network none: 컨테이너 netns에는 lo만 있고 밖으로 나가는 길이 없다. 시험은 그 안에서 만든 netns끼리다.
  # NET_ADMIN·SYS_ADMIN은 rootless의 user namespace 안 권한이라 호스트의 nft·링크에는 닿지 않는다.
  if podman run --rm -i --network none --cap-add NET_ADMIN,SYS_ADMIN --sysctl net.ipv4.ip_forward=1 \
    -v "$TMP/prod.nft:/rules.nft:ro,Z" -v "$TMP/base/host:/host:ro,Z" -v "$TMP/stub:/stub:ro,Z" -v "$TMP/vh.sh:/vh.sh:ro,Z" \
    "$IMAGE" bash -c "$NETNS_SCRIPT"; then
    pass "netns 시험(운영 렌더)"
  else
    fail "netns 시험"
  fi
}

case "${1:-}" in
  "")
    render_tests
    verify_tests
    kernel_json_tests
    device_name_tests
    upstream_tests
    ;;
  --netns) netns_test ;;
  *) echo "사용: bash tools/host-egress.test.sh [--netns]" >&2; exit 2 ;;
esac

# 0건 통과는 실패다(B.8 E7).
[ "$CASES" -gt 0 ] || { echo "FAIL 시험이 0건이다" >&2; exit 1; }
[ "$FAILS" -eq 0 ] || { echo "host-egress: ${FAILS}/${CASES} 실패" >&2; exit 1; }
echo "host-egress: ${CASES}건 통과"
