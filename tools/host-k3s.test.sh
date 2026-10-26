#!/usr/bin/env bash
# host/install.sh --k3s 시험. ci가 부른다. root·k3s 없이 돈다.
#   check_install_time_keys: node-name·node-ip는 설치 때 값으로 고정하고(다르면 멈춤), tls-san은 차이만 출력한다.
#   k3s_install 경로: 같은 버전에서 tls-san만 바뀌면 설치 스크립트를 부르지 않고 config만 바꿔 재시작한다.
#   그 밖의 값이 바뀌면 설치 스크립트를 강제 재시작으로 부른다. 값이 바뀌면 이전 config를 백업한다.
#   config_pairs: 빈 값 키를 버리지 않고, exact는 따옴표·순서를 지킨다(재시작 판단이 이것을 쓴다).
#   check_cluster_net: NET_CHECK_MAX가 Service 조회·DNS·TCP·재시도 전체의 상한이다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0
CASES=0
pass() { CASES=$((CASES + 1)); printf 'ok   %s\n' "$*"; }
fail() { CASES=$((CASES + 1)); FAILS=$((FAILS + 1)); printf 'FAIL %s\n' "$*" >&2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 실제 꼴의 tailnet 이름은 저장소에 적지 않는다(gitleaks). ci의 gitleaks 시험처럼 실행 때 조립한다.
SUFFIX="example.$(printf '%s.%s' ts net)"

# cfg <node-name> <node-ip> <tls-san...>: k3s config.yaml 꼴
cfg() {
  local name="$1" ip="$2" s
  shift 2
  printf 'node-name: %s\nnode-ip: %s\ntls-san:\n' "$name" "$ip"
  for s in "$@"; do printf '  - %s\n' "$s"; done
  printf 'secrets-encryption: true\n'
}

# run <기존 config 파일|-> <새 config>: install.sh를 source해 check_install_time_keys만 부른다. 출력은 stdout+stderr.
run() {
  (
    # shellcheck source=../host/install.sh
    . "$ROOT/host/install.sh"
    if [ "$1" = - ]; then K3S_CONFIG="$TMP/none.yaml"; else K3S_CONFIG="$1"; fi
    check_install_time_keys "$2"
  ) 2>&1
}

old_san=(nuc-15-pro 192.168.117.15 "nuc-15-pro.${SUFFIX}")
cfg nuc-15-pro 192.168.117.15 "${old_san[@]}" >"$TMP/old.yaml"

# check <설명> <기대 종료 코드> <기존> <새 config> [<있어야 할 글자>...] [!<없어야 할 글자>...]
check() {
  local desc="$1" want_rc="$2" old="$3" new="$4" out rc=0 t bad=""
  shift 4
  out="$(run "$old" "$new")" || rc=$?
  [ "$rc" = "$want_rc" ] || bad+=" 종료 ${rc}(기대 ${want_rc})"
  for t in "$@"; do
    case "$t" in
      '!'*) if grep -qF -- "${t#!}" <<<"$out"; then bad+=" '${t#!}'가 있다"; fi ;;
      *) grep -qF -- "$t" <<<"$out" || bad+=" '${t}'가 없다" ;;
    esac
  done
  if [ -z "$bad" ]; then pass "$desc"; else fail "${desc}:${bad}"$'\n'"${out}"; fi
}

check "기존 config 없음(첫 설치)" 0 - "$(cfg nuc-15-pro 192.168.117.15 "${old_san[@]}")" '!tls-san이 바뀐다'
check "모두 같음: 출력 없음" 0 "$TMP/old.yaml" "$(cat "$TMP/old.yaml")" '!tls-san이 바뀐다'
check "tls-san 순서만 다름: 차이 아님" 0 "$TMP/old.yaml" \
  "$(cfg nuc-15-pro 192.168.117.15 "nuc-15-pro.${SUFFIX}" 192.168.117.15 nuc-15-pro)" '!tls-san이 바뀐다'
check "tls-san MagicDNS 교체: 통과, 차이·남는 이름 안내, tailnet 이름 가림" 0 "$TMP/old.yaml" \
  "$(cfg nuc-15-pro 192.168.117.15 nuc-15-pro 192.168.117.15 "nuc-pro.${SUFFIX}")" \
  'tls-san이 바뀐다' '+ nuc-pro.<tailnet>.ts.net' '- nuc-15-pro.<tailnet>.ts.net' '뺀 이름은 인증서에 남는다' "!${SUFFIX}"
check "tls-san 더하기만: 통과, 남는 이름 안내 없음" 0 "$TMP/old.yaml" \
  "$(cfg nuc-15-pro 192.168.117.15 "${old_san[@]}" extra-name)" '+ extra-name' '!뺀 이름은'
check "node-name이 다름: 멈춤" 1 "$TMP/old.yaml" \
  "$(cfg nuc-pro 192.168.117.15 "${old_san[@]}")" 'node-name/node-ip가 다르다'
check "node-ip가 다름: 멈춤" 1 "$TMP/old.yaml" \
  "$(cfg nuc-15-pro 192.168.117.16 "${old_san[@]}")" 'node-name/node-ip가 다르다'
check "node-ip와 tls-san이 함께 다름: 멈춤(tls-san 출력 전)" 1 "$TMP/old.yaml" \
  "$(cfg nuc-15-pro 192.168.117.16 nuc-15-pro 192.168.117.16)" 'node-name/node-ip가 다르다' '!tls-san이 바뀐다'

# ------------------------------------------------------------------ config_pairs
# pairs <설명> <모드(sorted|exact)> <config> <기대 출력>
pairs() {
  local got mode=""
  [ "$2" = sorted ] || mode="$2"
  # shellcheck source=../host/lib.sh
  got="$(. "$ROOT/host/lib.sh" && printf '%s\n' "$3" | config_pairs ${mode:+"$mode"})"
  if [ "$got" = "$4" ]; then pass "config_pairs ${1}"; else fail "config_pairs ${1}:"$'\n'"${got}"$'\n'"(기대)"$'\n'"${4}"; fi
}
T=$'\t'
pairs '빈 따옴표 값: 키를 남긴다' sorted 'cluster-domain: ""' "--cluster-domain${T}"
pairs '항목 없는 키: 빈 값' sorted $'cluster-domain:\nnode-name: a' "--cluster-domain${T}"$'\n'"--node-name${T}a"
pairs '목록(사이 주석·빈 줄)' sorted $'tls-san:\n  # c\n\n  - b\n  - a  # c' "--tls-san${T}a"$'\n'"--tls-san${T}b"
pairs '따옴표 안의 #은 값이다' sorted 'a: "x # y"  # c' "--a${T}x # y"
pairs '스칼라 뒤 목록 항목은 BAD' sorted $'a: 1\n  - x' "--a${T}1"$'\n'"BAD${T}  - x"
pairs '닫히지 않은 따옴표·뒤 글자는 BAD' sorted $'a: "x\nb: "y" z' "BAD${T}a: \"x"$'\n'"BAD${T}b: \"y\" z"
pairs 'exact: 따옴표와 파일 순서를 지킨다' exact $'m: "0600"\nk:\n  - "b"\n  - a\ne: ""' \
  "--m${T}\"0600\""$'\n'"--k${T}\"b\""$'\n'"--k${T}a"$'\n'"--e${T}\"\""

# ------------------------------------------------------------------ k3s_install 경로
# 실제 k3s_install을 가짜 명령으로 돌린다. 경로는 모두 TMP 아래로 돌린다.
#   curl: 설치 스크립트 대신, 불리면 로그에 "installer force=<값>"을 남기는 스크립트를 내려 준다
#   install: -o·-g를 빼고 진짜 install을 부른다(root가 아니어도 돌게)
#   systemctl·dig·tailscale·k3s: 로그를 남기거나 정해 둔 값을 낸다
STUB="$TMP/stub"
mkdir -p "$STUB"
cat >"$STUB/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
printf '#!/bin/sh\necho "installer force=$INSTALL_K3S_FORCE_RESTART" >>%s\n' "$STUB_LOG" >"$out"
EOF
cat >"$STUB/install" <<'EOF'
#!/usr/bin/env bash
args=()
while [ "$#" -gt 0 ]; do case "$1" in -o | -g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
PATH="${PATH#*:}" exec install "${args[@]}"
EOF
cat >"$STUB/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_LOG"
EOF
cat >"$STUB/dig" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_DIG_SLEEP:-}" ]; then sleep "$STUB_DIG_SLEEP"; exit 9; fi
echo "${STUB_DIG_ANSWER:-10.43.0.1}"
EOF
cat >"$STUB/tailscale" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"$STUB/k3s" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" --version "*) echo "k3s version ${STUB_K3S_VERSION} (stub)" ;;
  *" --raw=/readyz "*) echo ok ;;
  # STUB_K3S_HANG: /readyz 뒤 API가 멈춘 경우. 상한이 없으면 20초 뒤에야 끝나 시험이 시간으로 잡는다.
  *" svc kube-dns "*) [ -z "${STUB_K3S_HANG:-}" ] || exec sleep 20; printf '10.43.0.10' ;;
  *" svc kubernetes "*) printf '10.43.0.1' ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$STUB"/*

# host/ 사본: preflight는 통과만 하고, 시험용 클러스터 값 파일을 둔다(tailnet 밖이라 MagicDNS 줄 없음).
cp -R "$ROOT/host" "$TMP/host"
printf '#!/bin/sh\nexit 0\n' >"$TMP/host/preflight.sh"
sed -e 's/^NODE_NAME=.*/NODE_NAME="t-node"/' -e 's/^NODE_IP=.*/NODE_IP="192.0.2.10"/' \
  -e 's/^NODE_IFACE=.*/NODE_IFACE="eth0"/' -e 's/^TAILNET_JOIN=.*/TAILNET_JOIN="false"/' \
  -e 's/^KUBE_CONTEXT=.*/KUBE_CONTEXT="t"/' -e 's/^TAILNET_DEVICE_NAME=.*/TAILNET_DEVICE_NAME=""/' \
  "$ROOT/host/clusters/prod.env" >"$TMP/host/clusters/t.env"
PIN="$(. "$ROOT/host/versions.env" && printf '%s' "$INSTALL_K3S_VERSION")"
RENDER="$(. "$TMP/host/lib.sh" && load_cluster t && render_k3s_config)"

# k3s_run <이름> <기존 config 모양> [k3s 버전] [dig 답]: k3s_install을 돌리고 TMP/<이름>/에 결과를 남긴다.
#   기존 config 모양: none(처음 설치), same, san(tls-san 하나 더), other(kubelet-arg 다름), comment(주석만 더함),
#   empty(cluster-domain: "" 더함), emptysan(empty + san), null(값 없는 cluster-domain: 더함),
#   quote(write-kubeconfig-mode의 따옴표를 뺌. YAML 0600은 8진수 정수다)
#   T_NET_MAX(기본 5)·T_HANG·T_DIG_SLEEP으로 NET_CHECK_MAX와 가짜 k3s·dig의 지연을 정한다. 걸린 시간은 TMP/<이름>/ms.
k3s_run() {
  local name="$1" shape="$2" d="$TMP/$1" t0
  mkdir -p "$d/etc" "$d/backup" "$d/tmpd"
  case "$shape" in
    none) ;;
    same) printf '%s' "$RENDER" >"$d/etc/config.yaml" ;;
    san) sed '/^tls-san:$/a\  - old-name.example.invalid' <<<"$RENDER" >"$d/etc/config.yaml" ;;
    other) printf '%s' "${RENDER//memory=1Gi/memory=2Gi}" >"$d/etc/config.yaml" ;;
    comment) { printf '# 옛 주석\n'; printf '%s' "$RENDER"; } >"$d/etc/config.yaml" ;;
    empty) printf '%s\ncluster-domain: ""\n' "$RENDER" >"$d/etc/config.yaml" ;;
    emptysan) { sed '/^tls-san:$/a\  - old-name.example.invalid' <<<"$RENDER"; printf 'cluster-domain: ""\n'; } >"$d/etc/config.yaml" ;;
    null) printf '%s\ncluster-domain:\n' "$RENDER" >"$d/etc/config.yaml" ;;
    quote) sed -E 's/^(write-kubeconfig-mode: )"0600"/\10600/' <<<"$RENDER" >"$d/etc/config.yaml" ;;
  esac
  [ ! -e "$d/etc/config.yaml" ] || cp "$d/etc/config.yaml" "$d/old.yaml"
  : >"$d/log"
  t0="${EPOCHREALTIME//[!0-9]/}"
  (
    export PATH="$STUB:$PATH" STUB_LOG="$d/log" STUB_K3S_VERSION="${3:-$PIN}" STUB_DIG_ANSWER="${4:-10.43.0.1}" \
      STUB_K3S_HANG="${T_HANG:-}" STUB_DIG_SLEEP="${T_DIG_SLEEP:-}"
    # shellcheck source=../host/install.sh
    . "$TMP/host/install.sh"
    load_cluster t
    K3S_ETC="$d/etc" K3S_CONFIG="$d/etc/config.yaml" K3S_SERVER_DIR="$d/server" K3S_MANIFESTS="$d/server/manifests"
    K3S_BIN="$STUB/k3s" K3S_BACKUP_DIR="$d/backup/homelab" TMPD="$d/tmpd" NET_CHECK_MAX="${T_NET_MAX:-5}"
    tcp_open() { echo "tcp $*" >>"$STUB_LOG"; }
    write_user_kubeconfig() { KUBECONFIG_OUT="$d/kubeconfig"; }
    k3s_install
  ) >"$TMP/$name/out" 2>&1 || echo "rc=$?" >>"$TMP/$name/log"
  echo $(((${EPOCHREALTIME//[!0-9]/} - t0) / 1000)) >"$TMP/$name/ms"
}

# expect_run <설명> <이름> <조건...>: 조건은 log:<글자>, !log:<글자>, out:<글자>, !out:<글자>, backup:<개수>,
#   config=render, maxms:<밀리초>(k3s_install 전체가 이 안에 끝남)
expect_run() {
  local desc="$1" d="$TMP/$2" c bad="" n f
  shift 2
  for c in "$@"; do
    case "$c" in
      log:*) grep -qF -- "${c#log:}" "$d/log" || bad+=" 로그에 '${c#log:}'가 없다" ;;
      '!log:'*) if grep -qF -- "${c#!log:}" "$d/log"; then bad+=" 로그에 '${c#!log:}'가 있다"; fi ;;
      out:*) grep -qF -- "${c#out:}" "$d/out" || bad+=" 출력에 '${c#out:}'가 없다" ;;
      '!out:'*) if grep -qF -- "${c#!out:}" "$d/out"; then bad+=" 출력에 '${c#!out:}'가 있다"; fi ;;
      maxms:*) [ "$(cat "$d/ms")" -le "${c#maxms:}" ] || bad+=" $(cat "$d/ms")ms 걸림(상한 ${c#maxms:}ms)" ;;
      backup:*)
        n="$(find "$d/backup" -name 'k3s-config.*.yaml' 2>/dev/null | grep -c . || true)"
        [ "$n" = "${c#backup:}" ] || bad+=" 백업 ${n}개(기대 ${c#backup:})"
        if [ "$n" = 1 ]; then
          f="$(find "$d/backup" -name 'k3s-config.*.yaml')"
          cmp -s "$f" "$d/old.yaml" || bad+=" 백업이 이전 config와 다르다"
          [ "$(stat -c %a "$f")" = 600 ] || bad+=" 백업 권한 $(stat -c %a "$f")"
        fi
        ;;
      config=render) [ "$(cat "$d/etc/config.yaml")" = "$RENDER" ] || bad+=" config가 렌더와 다르다" ;;
    esac
  done
  if [ -z "$bad" ]; then pass "$desc"; else fail "${desc}:${bad}"$'\n'"$(cat "$d/log" "$d/out")"; fi
}

k3s_run san san
expect_run "tls-san만 다름: 설치 스크립트 없이 config만 바꾸고 재시작, 백업, DNS·Service 확인" san \
  '!log:installer' 'log:systemctl restart k3s.service' 'log:tcp 10.43.0.1 443' '!log:rc=' \
  backup:1 config=render 'out:경로: tls-san만 바뀌었다' 'out:이전 config 백업:' 'out:되돌리기: sudo install -m 0600'
k3s_run other other
expect_run "다른 값이 다름: 설치 스크립트를 강제 재시작으로, 백업, DNS·Service 확인" other \
  'log:installer force=true' '!log:systemctl restart' 'log:tcp 10.43.0.1 443' '!log:rc=' backup:1 config=render
k3s_run ver san v1.0.0+k3s1
expect_run "버전이 다르면 tls-san만 달라도 설치 스크립트" ver 'log:installer force=true' '!log:systemctl restart' backup:1
k3s_run same same
expect_run "바뀐 것 없음: 설치 스크립트(재시작 안 함), 백업 없음" same \
  'log:installer force=false' '!log:systemctl restart' '!log:tcp ' backup:0
k3s_run comment comment
expect_run "주석만 다름: 재시작 안 함, 백업은 남김" comment \
  'log:installer force=false' '!log:systemctl restart' '!log:tcp ' backup:1 config=render
k3s_run fresh none
expect_run "처음 설치: 설치 스크립트, 백업·DNS 확인 없음" fresh \
  'log:installer force=false' '!log:tcp ' backup:0 config=render
T_NET_MAX=1 k3s_run netfail san "" 10.43.0.99
expect_run "재시작 뒤 DNS 답이 틀리면 NET_CHECK_MAX(1초) 뒤 멈추고 되돌리기를 알린다" netfail \
  'log:rc=1' 'log:systemctl restart k3s.service' 'out:1초 안에 돌아오지 않았다' 'out:되돌리기: sudo install -m 0600' \
  backup:1 maxms:3000

# 빈 값·따옴표가 다른 기존 config(#921 리뷰). 옛 판은 이 줄을 버리거나 따옴표를 벗겨 같다고 보고 재시작하지 않았다.
k3s_run empty empty
expect_run "기존에 빈 값(cluster-domain: \"\") 키가 있음: 값이 바뀐 것, 설치 스크립트 강제 재시작" empty \
  'log:installer force=true' '!log:systemctl restart' 'log:tcp 10.43.0.1 443' '!log:rc=' backup:1 config=render
k3s_run emptysan emptysan
expect_run "빈 값 키 + tls-san 차이: tls-san만의 변경이 아니다" emptysan \
  'log:installer force=true' '!log:systemctl restart' '!out:경로: tls-san만' '!log:rc=' backup:1 config=render
k3s_run null null
expect_run "기존에 값 없는 키(cluster-domain:)가 있음: 설치 스크립트 강제 재시작" null \
  'log:installer force=true' '!log:rc=' backup:1 config=render
k3s_run quote quote
expect_run "write-kubeconfig-mode 따옴표만 다름(0600은 8진수 정수): 설치 스크립트 강제 재시작" quote \
  'log:installer force=true' '!log:rc=' backup:1 config=render

# NET_CHECK_MAX가 전체 상한이다(#921 리뷰). 옛 판은 Service 조회가 멈추면 끝나지 않았고, 느린 dig 시간을 세지 않았다.
T_NET_MAX=1 T_HANG=1 k3s_run hang san
expect_run "재시작 뒤 Service 조회가 멈춤: 1초 상한에서 멈추고 되돌리기를 알린다" hang \
  'log:rc=1' 'out:kube-dns Service를 1초 안에 읽지 못했다' 'out:되돌리기: sudo install -m 0600' '!log:tcp ' maxms:3000
T_NET_MAX=2 T_DIG_SLEEP=1 k3s_run slowdig san
expect_run "dig가 1초씩 걸려 실패: 2초 상한 안에 멈춘다" slowdig \
  'log:rc=1' 'out:2초 안에 돌아오지 않았다' 'out:되돌리기: sudo install -m 0600' maxms:3500

# 0건 통과는 실패다(B.8 E7).
[ "$CASES" -gt 0 ] || { echo "FAIL 시험이 0건이다" >&2; exit 1; }
[ "$FAILS" -eq 0 ] || { echo "host-k3s: ${FAILS}/${CASES} 실패" >&2; exit 1; }
echo "host-k3s: ${CASES}건 통과"
