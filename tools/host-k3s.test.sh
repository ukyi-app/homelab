#!/usr/bin/env bash
# host/install.sh --k3s와 --host-config 일부의 시험. ci가 부른다. root·k3s 없이 돈다.
#   check_install_time_keys: node-name·node-ip는 설치 때 값으로 고정하고(다르면 멈춤), tls-san은 차이만 출력한다.
#   k3s_install 경로: 같은 버전에서 tls-san만 바뀌면 설치 스크립트를 부르지 않고 config만 바꿔 재시작한다.
#   그 밖의 값이 바뀌면 설치 스크립트를 강제 재시작으로 부른다. 값이 바뀌면 이전 config를 백업한다.
#   config_pairs: 빈 값 키를 버리지 않고, exact는 따옴표·순서를 지킨다(재시작 판단이 이것을 쓴다).
#   재시작 뒤 확인: 이미 설치된 k3s가 다시 뜨면(config 값 변경, 버전만 변경, 설치 스크립트가 스스로 재시작) 경로와
#   상관없이 DNS·Service를 본다. 처음 설치는 보지 않는다. NET_CHECK_MAX가 조회·DNS·TCP·재시도 전체의 상한이다.
#   SAN 대기: tls-san을 바꾼 재시작 뒤 서빙 인증서에 새 SAN이 나올 때까지 SAN_WAIT_MAX까지 기다린다.
#   podCIDR 대기: 처음 설치를 포함해 노드에 podCIDR가 배정될 때까지 PODCIDR_WAIT_MAX까지 기다린다.
#   verify.sh check_san: 렌더 tls-san이 인증서에 줄 전체로 모두 있어야 ok다.
#   verify.sh의 kubectl: k3s 멀티콜이 비root로 config.yaml을 읽다 내는 WARN이 출력에 섞이지 않는다.
#   --host-config sysctl: 60-inotify.conf 값(8192), apply_services가 그 파일만 sysctl --load로 바로 걸고 실패하면 멈춤,
#   verify.sh check_inotify가 설치된 파일과 커널 값(한도라 이상이면 통과)을 따로 본다.
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
# 실제 k3s_install을 가짜 명령으로 돌린다. 경로는 모두 TMP 아래로 돌린다. 실행마다 STUB_STATE에
# k3s 버전(version), k3s.service 시작 횟수(started, systemctl show가 시작 시각 대신 낸다), 인증서 SAN을 둔다.
#   curl: 설치 스크립트 대신 가짜를 내려 준다. 가짜는 로그에 "installer force=<값>"을 남기고, 진짜처럼
#         바이너리를 깔고(version을 핀으로) 강제거나 바이너리가 바뀌었으면 재시작한다(k3s install.sh:1150-1153).
#         STUB_UNIT_CHANGE면 같은 버전에서도 재시작한다(유닛·env 파일만 바뀐 경우).
#   install: -o·-g를 빼고 진짜 install을 부른다(root가 아니어도 돌게)
#   systemctl·dig·tailscale·k3s·openssl: 로그를 남기거나 정해 둔 값을 낸다
STUB="$TMP/stub"
mkdir -p "$STUB"
cat >"$STUB/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
# 설치 스크립트는 env -i로 돈다. 쓸 경로와 값은 내려 줄 때 박는다.
cat >"$out" <<SH
#!/bin/sh
echo "installer force=\$INSTALL_K3S_FORCE_RESTART" >>"$STUB_LOG"
old="\$(cat "$STUB_STATE/version")"
cp "$STUB_DIR/k3s" "$STUB_BIN"
echo "\$INSTALL_K3S_VERSION" >"$STUB_STATE/version"
if [ "\$INSTALL_K3S_FORCE_RESTART" = true ] || [ "\$old" != "\$INSTALL_K3S_VERSION" ] || [ -n "${STUB_UNIT_CHANGE:-}" ]; then
  echo "installer restart" >>"$STUB_LOG"
  echo \$((\$(cat "$STUB_STATE/started") + 1)) >"$STUB_STATE/started"
fi
SH
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
case "$1" in
  show) cat "$STUB_STATE/started" ;;
  restart) echo $(($(cat "$STUB_STATE/started") + 1)) >"$STUB_STATE/started" ;;
esac
EOF
# s_client는 아무것도 내지 않는다. x509가 지금 나가는 인증서의 SAN 줄을 낸다. 처음 STUB_SAN_STALE번은 재시작 전
# 인증서(sans.old), 그 뒤는 새 인증서(sans)다. 읽을 때마다 로그에 "san read <번째>"를 남긴다.
cat >"$STUB/openssl" <<'EOF'
#!/usr/bin/env bash
[ "$1" = x509 ] || exit 0
n=$(($(cat "$STUB_STATE/san_reads") + 1))
echo "$n" >"$STUB_STATE/san_reads"
echo "san read $n" >>"$STUB_LOG"
f=sans
if [ "$n" -le "${STUB_SAN_STALE:-0}" ]; then f=sans.old; fi
printf 'X509v3 Subject Alternative Name: \n    %s\n' "$(cat "$STUB_STATE/$f")"
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
  *" --version "*) echo "k3s version $(cat "$STUB_STATE/version") (stub)" ;;
  *" --raw=/readyz "*) echo ok ;;
  # STUB_K3S_HANG: /readyz 뒤 API가 멈춘 경우. 상한이 없으면 20초 뒤에야 끝나 시험이 시간으로 잡는다.
  *" svc kube-dns "*) [ -z "${STUB_K3S_HANG:-}" ] || exec sleep 20; printf '10.43.0.10' ;;
  *" svc kubernetes "*) printf '10.43.0.1' ;;
  # 노드 podCIDR. 처음 STUB_PODCIDR_LATE번은 배정 전이다(첫 번째는 노드 등록 전이라 NotFound, 그 뒤는 빈 값).
  # 읽을 때마다 로그에 "podcidr read <번째>"를 남긴다.
  *" get node "*)
    n=$(($(cat "$STUB_STATE/podcidr_reads") + 1))
    echo "$n" >"$STUB_STATE/podcidr_reads"
    echo "podcidr read $n" >>"$STUB_LOG"
    if [ "$n" -le "${STUB_PODCIDR_LATE:-0}" ]; then
      [ "$n" -gt 1 ] || { echo 'Error from server (NotFound): nodes "t-node" not found' >&2; exit 1; }
      exit 0
    fi
    printf '10.42.0.0/24'
    ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$STUB"/*
STUB_PATH="$STUB:$PATH"

# host/ 사본: preflight는 통과만 하고, 시험용 클러스터 값 파일을 둔다(tailnet 밖이라 MagicDNS 줄 없음).
cp -R "$ROOT/host" "$TMP/host"
printf '#!/bin/sh\nexit 0\n' >"$TMP/host/preflight.sh"
sed -e 's/^NODE_NAME=.*/NODE_NAME="t-node"/' -e 's/^NODE_IP=.*/NODE_IP="192.0.2.10"/' \
  -e 's/^NODE_IFACE=.*/NODE_IFACE="eth0"/' -e 's/^TAILNET_JOIN=.*/TAILNET_JOIN="false"/' \
  -e 's/^KUBE_CONTEXT=.*/KUBE_CONTEXT="t"/' -e 's/^TAILNET_DEVICE_NAME=.*/TAILNET_DEVICE_NAME=""/' \
  "$ROOT/host/clusters/prod.env" >"$TMP/host/clusters/t.env"
PIN="$(. "$ROOT/host/versions.env" && printf '%s' "$INSTALL_K3S_VERSION")"
RENDER="$(. "$TMP/host/lib.sh" && load_cluster t && render_k3s_config)"

# san_line <config>: 그 config의 tls-san으로 k3s가 내줄 서빙 인증서의 SAN 줄(openssl x509 -ext subjectAltName 꼴)
san_line() {
  local s san_text="DNS:kubernetes, DNS:kubernetes.default, DNS:localhost, IP Address:10.43.0.1, IP Address:127.0.0.1"
  # shellcheck source=../host/lib.sh
  while IFS= read -r s; do
    case "$s" in
      *[!0-9.]*) san_text+=", DNS:${s}" ;;
      ?*) san_text+=", IP Address:${s}" ;;
    esac
  done <<<"$(. "$TMP/host/lib.sh" && tls_sans <<<"$1")"
  printf '%s' "$san_text"
}

# k3s_run <이름> <기존 config 모양> [k3s 버전] [dig 답]: k3s_install을 돌리고 TMP/<이름>/에 결과를 남긴다.
#   기존 config 모양: none(처음 설치), same, san(tls-san 하나 더), sanadd(tls-san 하나 덜, 렌더가 이름을 더한다),
#   other(kubelet-arg 다름), comment(주석만 더함),
#   empty(cluster-domain: "" 더함), emptysan(empty + san), null(값 없는 cluster-domain: 더함),
#   quote(write-kubeconfig-mode의 따옴표를 뺌. YAML 0600은 8진수 정수다)
#   T_NET_MAX(기본 5)·T_HANG·T_DIG_SLEEP으로 NET_CHECK_MAX와 가짜 k3s·dig의 지연을 정한다. 걸린 시간은 TMP/<이름>/ms.
#   T_SAN_MAX(기본 5)는 SAN_WAIT_MAX, T_SAN_STALE은 재시작 뒤 옛 인증서가 나가는 횟수, T_NOBIN이면 k3s 바이너리가
#   없다(config만 남은 첫 설치), T_UNIT_CHANGE면 가짜 설치 스크립트가 같은 버전에서도 재시작한다.
#   T_PODCIDR_MAX(기본 5)는 PODCIDR_WAIT_MAX, T_PODCIDR_LATE는 podCIDR가 배정되기 전에 읽히는 횟수다.
k3s_run() {
  local name="$1" shape="$2" d="$TMP/$1" t0
  mkdir -p "$d/etc" "$d/backup" "$d/tmpd" "$d/bin" "$d/state"
  case "$shape" in
    none) ;;
    same) printf '%s' "$RENDER" >"$d/etc/config.yaml" ;;
    san) sed '/^tls-san:$/a\  - old-name.example.invalid' <<<"$RENDER" >"$d/etc/config.yaml" ;;
    sanadd) sed '/^  - t-node$/d' <<<"$RENDER" >"$d/etc/config.yaml" ;;
    other) printf '%s' "${RENDER//memory=1Gi/memory=2Gi}" >"$d/etc/config.yaml" ;;
    comment) { printf '# 옛 주석\n'; printf '%s' "$RENDER"; } >"$d/etc/config.yaml" ;;
    empty) printf '%s\ncluster-domain: ""\n' "$RENDER" >"$d/etc/config.yaml" ;;
    emptysan) { sed '/^tls-san:$/a\  - old-name.example.invalid' <<<"$RENDER"; printf 'cluster-domain: ""\n'; } >"$d/etc/config.yaml" ;;
    null) printf '%s\ncluster-domain:\n' "$RENDER" >"$d/etc/config.yaml" ;;
    quote) sed -E 's/^(write-kubeconfig-mode: )"0600"/\10600/' <<<"$RENDER" >"$d/etc/config.yaml" ;;
  esac
  [ ! -e "$d/etc/config.yaml" ] || cp "$d/etc/config.yaml" "$d/old.yaml"
  # 처음 설치는 k3s.service가 없어 시작 시각이 0이다.
  if [ "$shape" = none ]; then echo 0; else echo 100; fi >"$d/state/started"
  if [ "$shape" = none ] || [ -n "${T_NOBIN:-}" ]; then
    : >"$d/state/version"
  else
    cp "$STUB/k3s" "$d/bin/k3s"
    printf '%s\n' "${3:-$PIN}" >"$d/state/version"
  fi
  echo 0 >"$d/state/san_reads"
  echo 0 >"$d/state/podcidr_reads"
  san_line "$RENDER" >"$d/state/sans"
  if [ -e "$d/old.yaml" ]; then san_line "$(cat "$d/old.yaml")"; else san_line "$RENDER"; fi >"$d/state/sans.old"
  : >"$d/log"
  t0="${EPOCHREALTIME//[!0-9]/}"
  (
    export PATH="$STUB_PATH" STUB_DIR="$STUB" STUB_LOG="$d/log" STUB_STATE="$d/state" STUB_BIN="$d/bin/k3s" \
      STUB_DIG_ANSWER="${4:-10.43.0.1}" STUB_K3S_HANG="${T_HANG:-}" STUB_DIG_SLEEP="${T_DIG_SLEEP:-}" \
      STUB_SAN_STALE="${T_SAN_STALE:-}" STUB_UNIT_CHANGE="${T_UNIT_CHANGE:-}" STUB_PODCIDR_LATE="${T_PODCIDR_LATE:-}"
    # shellcheck source=../host/install.sh
    . "$TMP/host/install.sh"
    load_cluster t
    K3S_ETC="$d/etc" K3S_CONFIG="$d/etc/config.yaml" K3S_SERVER_DIR="$d/server" K3S_MANIFESTS="$d/server/manifests"
    K3S_BIN="$d/bin/k3s" K3S_BACKUP_DIR="$d/backup/homelab" TMPD="$d/tmpd" NET_CHECK_MAX="${T_NET_MAX:-5}"
    SAN_WAIT_MAX="${T_SAN_MAX:-5}" PODCIDR_WAIT_MAX="${T_PODCIDR_MAX:-5}"
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
expect_run "tls-san만 다름: 설치 스크립트 없이 config만 바꾸고 재시작, 백업, DNS·Service 확인, SAN 확인" san \
  '!log:installer' 'log:systemctl restart k3s.service' 'log:tcp 10.43.0.1 443' '!log:rc=' \
  backup:1 config=render 'out:경로: tls-san만 바뀌었다' 'out:이전 config 백업:' 'out:되돌리기: sudo install -m 0600' \
  'log:san read 1' 'out:서빙 인증서에 tls-san 2개가 모두 있다'
k3s_run other other
expect_run "다른 값이 다름: 설치 스크립트를 강제 재시작으로, 백업, DNS·Service 확인, tls-san 그대로라 SAN 대기 없음" other \
  'log:installer force=true' '!log:systemctl restart' 'log:tcp 10.43.0.1 443' '!log:rc=' backup:1 config=render \
  '!log:san read'
k3s_run ver san v1.0.0+k3s1
expect_run "버전이 다르면 tls-san만 달라도 설치 스크립트, 재시작 뒤 확인" ver \
  'log:installer force=true' 'log:installer restart' '!log:systemctl restart' 'log:tcp 10.43.0.1 443' '!log:rc=' backup:1
k3s_run same same
expect_run "바뀐 것 없음: 설치 스크립트가 재시작하지 않는다, 확인·백업 없음, 배정된 podCIDR는 한 번만 읽는다" same \
  'log:installer force=false' '!log:installer restart' '!log:systemctl restart' '!log:tcp ' backup:0 \
  'log:podcidr read 1' '!log:podcidr read 2'
k3s_run comment comment
expect_run "주석만 다름: 재시작 안 함, 백업은 남김" comment \
  'log:installer force=false' '!log:installer restart' '!log:systemctl restart' '!log:tcp ' backup:1 config=render
k3s_run fresh none
expect_run "처음 설치: 설치 스크립트가 k3s를 띄워도 백업·DNS 확인 없음, podCIDR는 본다" fresh \
  'log:installer force=false' 'log:installer restart' '!log:tcp ' '!log:san read' '!log:rc=' backup:0 config=render \
  'log:podcidr read 1' 'out:노드 podCIDR 10.42.0.0/24'

# 처음 설치 직후 노드 podCIDR 배정 전에 끝나 verify가 FAIL했다(2026-10-28 VM). 배정될 때까지 기다린다.
T_PODCIDR_LATE=2 k3s_run cidrwait none
expect_run "처음 설치: 노드 등록 전(NotFound)·배정 전(빈 값)을 지나 세 번째에 podCIDR를 보고 끝난다" cidrwait \
  'log:podcidr read 3' '!log:podcidr read 4' '!log:rc=' 'out:노드 podCIDR 10.42.0.0/24' 'out:kubeconfig:'
T_PODCIDR_MAX=1 T_PODCIDR_LATE=99 k3s_run cidrtimeout none
expect_run "podCIDR가 PODCIDR_WAIT_MAX(1초) 안에 배정되지 않으면 멈추고 로그 위치를 알린다" cidrtimeout \
  'log:rc=1' 'out:podCIDR가 1초 안에 배정되지 않았다' 'out:journalctl -u k3s -g PodCIDR' \
  'out:이전 config 백업 없음(처음 설치)' '!out:kubeconfig:' maxms:3500
T_NET_MAX=1 k3s_run netfail san "" 10.43.0.99
expect_run "재시작 뒤 DNS 답이 틀리면 NET_CHECK_MAX(1초) 뒤 멈추고 되돌리기를 알린다" netfail \
  'log:rc=1' 'log:systemctl restart k3s.service' 'out:1초 안에 돌아오지 않았다' 'out:되돌리기: sudo install -m 0600' \
  backup:1 maxms:3000

# config 값은 같고 k3s가 다시 뜬 경우(codex 926-r1). 옛 판은 restart=false라 확인을 건너뛰었다.
k3s_run veronly same v1.0.0+k3s1
expect_run "버전만 다름: 설치 스크립트가 강제 없이 바이너리를 바꿔 재시작, DNS·Service 확인, 백업 없음" veronly \
  'log:installer force=false' 'log:installer restart' 'log:tcp 10.43.0.1 443' '!log:rc=' '!log:san read' backup:0 \
  "out:k3s 버전이 바뀐다: v1.0.0+k3s1 -> ${PIN}" 'out:재시작했다.'
T_UNIT_CHANGE=1 k3s_run unit same
expect_run "같은 버전인데 설치 스크립트가 스스로 재시작(유닛·env 변경): DNS·Service 확인" unit \
  'log:installer force=false' 'log:installer restart' 'log:tcp 10.43.0.1 443' '!log:rc=' backup:0
T_NET_MAX=1 k3s_run vernetfail same v1.0.0+k3s1 10.43.0.99
expect_run "버전만 바꾼 재시작 뒤 DNS가 틀리면 멈추고, 백업 없음·버전 되돌리기 절차를 알린다" vernetfail \
  'log:rc=1' 'out:1초 안에 돌아오지 않았다' 'out:config는 그대로라 백업이 없다' \
  'out:k3s를 v1.0.0+k3s1에서' 'out:docs.k3s.io/upgrades/roll-back' '!out:처음 설치' backup:0 maxms:3000
T_NOBIN=1 k3s_run nobin other
expect_run "config만 있고 바이너리 없음(첫 설치가 중간에 실패): 처음 설치처럼 확인 없음" nobin \
  'log:installer force=true' 'log:installer restart' '!log:tcp ' '!log:rc=' backup:1 config=render

# tls-san을 더한 재시작 직후 옛 인증서가 잠시 나간다(2026-10-27 운영 verify FAIL). 새 SAN이 나올 때까지 기다린다.
T_SAN_STALE=2 k3s_run sanwait sanadd
expect_run "tls-san 더함: 옛 인증서가 두 번 나와도 세 번째에 새 SAN을 보고 끝난다" sanwait \
  'log:systemctl restart k3s.service' 'log:tcp 10.43.0.1 443' 'log:san read 3' '!log:san read 4' '!log:rc=' \
  'out:+ t-node' 'out:서빙 인증서에 tls-san 2개가 모두 있다'
T_SAN_MAX=1 T_SAN_STALE=99 k3s_run santimeout sanadd
expect_run "새 SAN이 SAN_WAIT_MAX(1초) 안에 안 나오면 멈추고 로그·되돌리기를 알린다" santimeout \
  'log:rc=1' 'out:1초 안에 모두 나오지 않았다(없는 SAN: t-node)' 'out:journalctl -u k3s -g k3s-serving' \
  'out:되돌리기: sudo install -m 0600' backup:1 maxms:3500

# 빈 값·따옴표가 다른 기존 config(#921 리뷰). 옛 판은 이 줄을 버리거나 따옴표를 벗겨 같다고 보고 재시작하지 않았다.
k3s_run empty empty
expect_run "기존에 빈 값(cluster-domain: \"\") 키가 있음: 값이 바뀐 것, 설치 스크립트 강제 재시작" empty \
  'log:installer force=true' '!log:systemctl restart' 'log:tcp 10.43.0.1 443' '!log:rc=' backup:1 config=render
k3s_run emptysan emptysan
expect_run "빈 값 키 + tls-san 차이: tls-san만의 변경이 아니다, 설치 스크립트 경로에서도 SAN 확인" emptysan \
  'log:installer force=true' '!log:systemctl restart' '!out:경로: tls-san만' '!log:rc=' backup:1 config=render \
  'log:san read 1'
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

# ------------------------------------------------------------------ verify.sh check_san
# vsan <설명> <인증서 SAN 줄> <있어야 할 글자>: 가짜 openssl로 check_san만 부른다. 렌더 tls-san은 t-node, 192.0.2.10.
vsan() {
  local d="$TMP/vsan" out
  mkdir -p "$d"
  printf '%s' "$2" >"$d/sans"
  echo 0 >"$d/san_reads"
  # shellcheck disable=SC2016  # $1·$2는 안쪽 bash가 펼친다
  out="$(PATH="$STUB_PATH" STUB_LOG=/dev/null STUB_STATE="$d" \
    bash -c '. "$1/host/verify.sh" && load_cluster t && K3S_CFG="$2" && check_san' _ "$TMP" "$RENDER" 2>&1)"
  if grep -qF -- "$3" <<<"$out"; then pass "check_san ${1}"; else fail "check_san ${1}: '${3}'가 없다"$'\n'"${out}"; fi
}
vsan "모두 있음: ok" "$(san_line "$RENDER")" 'ok   serving cert SAN에 tls-san 2개가 모두 있다'
vsan "짧은 이름이 FQDN 안에만 있음: 부분 일치는 통과가 아니다" \
  'DNS:kubernetes, DNS:localhost, DNS:t-node.example.invalid, IP Address:192.0.2.10' 'FAIL serving cert에 없는 SAN: t-node.'
vsan "SAN을 3개 미만 읽음: 형식 문제로 가른다" 'DNS:t-node, IP Address:192.0.2.10' 'SAN을 2개만 읽었다'

# ------------------------------------------------------------------ verify.sh의 kubectl(k3s 멀티콜) 경고
# 노드의 kubectl은 k3s 심링크다. 멀티콜은 kubectl로 넘기기 전에 config 파일을 세 번 찾고, 비root는 0600 config를 못 읽어
# 호출마다 WARN을 낸다(2026-10-28 VM verify). 가짜 kubectl이 그 동작을 흉내 낸다: K3S_CONFIG_FILE이 없으면 기본
# 경로(노드에서는 root 0600)를 읽다 WARN, 읽을 수 있는 파일을 가리키면 조용하다.
VK="$TMP/vk"
mkdir -p "$VK/bin"
cat >"$VK/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
cfg="${K3S_CONFIG_FILE:-/etc/rancher/k3s/config.yaml}"
if [ "$cfg" = /etc/rancher/k3s/config.yaml ] || [ ! -r "$cfg" ]; then
  for _ in debug data-dir prefer-bundled-bin; do echo "level=warning msg=\"open ${cfg}: permission denied\"" >&2; done
fi
case " $* " in
  *" config get-contexts "*) echo t ;;
  *" get nodes "*) echo t-node ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$VK/bin/kubectl"
: >"$VK/kubeconfig"
# shellcheck disable=SC2016  # $1은 안쪽 bash가 펼친다
out="$(env -u K3S_CONFIG_FILE PATH="$VK/bin:$STUB_PATH" KUBECONFIG="$VK/kubeconfig" \
  bash -c '. "$1/host/verify.sh" && assert_host_tree_clean() { :; } && main --cluster t --identity' _ "$TMP" 2>&1)" || true
# 대조: 가짜 kubectl은 변수 없이 부르면 WARN을 낸다(이 시험이 WARN을 잡을 수 있다)
ctl="$(env -u K3S_CONFIG_FILE "$VK/bin/kubectl" config get-contexts 2>&1)"
if grep -qF 'permission denied' <<<"$ctl" && grep -qF 'ok   정체성: context t, 노드 t-node' <<<"$out" \
  && ! grep -qF 'permission denied' <<<"$out"; then
  pass "verify가 부르는 kubectl에 K3S_CONFIG_FILE을 줘 k3s config 읽기 WARN이 없다"
else
  fail "verify kubectl WARN:"$'\n'"${out}"
fi

# ------------------------------------------------------------------ --host-config sysctl(inotify 한도)
# 2026-10-27 운영 NUC에서 기본 128 때문에 libvirt dnsmasq가 inotify를 못 만들었다. 값은 사용자 결정이다.
INO="$TMP/host/etc/sysctl.d/60-inotify.conf"
got="$(grep -vE '^[[:space:]]*(#|$)' "$INO" || true)"
if [ "$got" = "fs.inotify.max_user_instances = 8192" ]; then
  pass "60-inotify.conf: 설정 줄은 fs.inotify.max_user_instances = 8192 하나"
else
  fail "60-inotify.conf 설정 줄이 다르다:"$'\n'"${got}"
fi
if grep -qxF -- "${INO}"$'\t'"/etc/sysctl.d/60-inotify.conf" <<<"$(. "$TMP/host/lib.sh" && load_cluster t && etc_targets)"; then
  pass "etc_targets가 60-inotify.conf를 /etc/sysctl.d/로 복사한다"
else
  fail "etc_targets에 /etc/sysctl.d/60-inotify.conf가 없다"
fi

cat >"$STUB/sysctl" <<'EOF'
#!/usr/bin/env bash
echo "sysctl $*" >>"$STUB_LOG"
if [ -n "${STUB_SYSCTL_FAIL:-}" ]; then echo 'sysctl: permission denied on key "fs.inotify.max_user_instances"' >&2; exit 1; fi
echo "fs.inotify.max_user_instances = 8192"
EOF
cat >"$STUB/systemd-tmpfiles" <<'EOF'
#!/usr/bin/env bash
echo "systemd-tmpfiles $*" >>"$STUB_LOG"
EOF
chmod +x "$STUB/sysctl" "$STUB/systemd-tmpfiles"

# svc_run <이름> [sysctl 실패]: install.sh의 apply_services([6/7])를 host/etc 전체 대상으로 가짜 명령에 돌린다.
# 따로 띄운 bash로 돈다. ( ... ) || 안에서는 set -e가 꺼져 실패한 sysctl 뒤로도 계속 가므로 실제 실행과 달라진다.
svc_run() {
  local d="$TMP/$1"
  mkdir -p "$d/state"
  echo 0 >"$d/state/started"
  : >"$d/log"
  # shellcheck disable=SC2016  # $1은 안쪽 bash가 펼친다
  PATH="$STUB_PATH" STUB_LOG="$d/log" STUB_STATE="$d/state" STUB_SYSCTL_FAIL="${2:-}" \
    bash -c '. "$1/host/install.sh"; load_cluster t; TARGETS="$(etc_targets)"; apply_services' _ "$TMP" \
    >"$d/out" 2>&1 || echo "rc=$?" >>"$d/log"
}
svc_run svc
expect_run "서비스 반영: sysctl.d 파일만 sysctl --load로 바로 걸고 건 값을 출력한다(재부팅 없이)" svc \
  'log:sysctl --load=/etc/sysctl.d/60-inotify.conf' 'out:    fs.inotify.max_user_instances = 8192' \
  'log:systemd-tmpfiles --create /etc/tmpfiles.d/10-k3s-node.conf' 'log:systemctl restart systemd-journald' \
  '!log:--system' '!log:systemd-sysctl' '!log:rc='
svc_run svcfail 1
expect_run "sysctl이 실패하면 서비스를 다시 시작하기 전에 멈춘다" svcfail 'log:rc=1' '!log:systemctl ' 'out:permission denied'

# vino <설명> <Git 파일> <설치된 파일|-> <커널 값|-> <있어야 할 글자|!없어야 할 글자...>: verify.sh check_inotify만 부른다.
vino() {
  local desc="$1" d="$TMP/vino" out t bad=""
  rm -rf "$d"
  mkdir -p "$d"
  [ "$3" = - ] || cp "$3" "$d/dest"
  [ "$4" = - ] || printf '%s\n' "$4" >"$d/proc"
  # shellcheck disable=SC2016  # $1~$4는 안쪽 bash가 펼친다
  out="$(bash -c '. "$1/host/verify.sh" && load_cluster t && INOTIFY_SRC="$2" INOTIFY_DEST="$3" INOTIFY_PROC="$4" && check_inotify' \
    _ "$TMP" "$2" "$d/dest" "$d/proc" 2>&1)" || true
  shift 4
  for t in "$@"; do
    case "$t" in
      '!'*) if grep -qF -- "${t#!}" <<<"$out"; then bad+=" '${t#!}'가 있다"; fi ;;
      *) grep -qF -- "$t" <<<"$out" || bad+=" '${t}'가 없다" ;;
    esac
  done
  if [ -z "$bad" ]; then pass "check_inotify ${desc}"; else fail "check_inotify ${desc}:${bad}"$'\n'"${out}"; fi
}
sed 's/= 8192$/= 128/' "$INO" >"$TMP/ino-128.conf"
{ cat "$INO"; echo "fs.inotify.max_user_instances = 16384"; } >"$TMP/ino-dup.conf"
vino "파일이 Git과 같고 커널 8192: ok" "$INO" "$INO" 8192 'Git과 같다' 'ok   fs.inotify.max_user_instances 8192(8192 이상)' '!FAIL'
vino "커널 값이 더 크면 한도라 ok" "$INO" "$INO" 65536 'ok   fs.inotify.max_user_instances 65536(8192 이상)' '!FAIL'
vino "커널 128(기본): FAIL, host-config 안내" "$INO" "$INO" 128 \
  'FAIL fs.inotify.max_user_instances가 128이다(기대 8192 이상)' '--host-config'
vino "파일 없이 커널만 8192(sysctl -w): 재부팅하면 돌아가므로 FAIL" "$INO" - 8192 \
  'FAIL' '재부팅하면 커널 값이 돌아간다' 'ok   fs.inotify.max_user_instances 8192'
vino "설치된 파일이 Git과 다름: FAIL" "$INO" "$TMP/ino-128.conf" 8192 '없거나 Git과 다르다'
vino "커널 값을 못 읽음: FAIL" "$INO" "$INO" - 'FAIL fs.inotify.max_user_instances가 없음이다'
# 'ok' 두 글자만 보면 FAIL 문구 속 mktemp 폴더 이름(예: tmp.1jVbokhWuJ)에 걸려 가끔 실패한다. ok() 접두어로 본다.
vino "Git 파일에 키가 둘: 기대 값 없이 비교하지 않는다" "$TMP/ino-dup.conf" "$TMP/ino-dup.conf" 8192 \
  '값 하나를 읽지 못했다' '!ok   '
# 출력을 다 받은 뒤 grep에 넘긴다. 파이프로 이으면 grep -q가 먼저 끝날 때 pipefail이 실패로 읽는다.
# shellcheck disable=SC2016
if grep -qw check_inotify <<<"$(bash -c '. "$1/host/verify.sh" && declare -f main' _ "$TMP")"; then
  pass "verify main이 check_inotify를 부른다"
else
  fail "verify main에 check_inotify가 없다"
fi

# 0건 통과는 실패다(B.8 E7).
[ "$CASES" -gt 0 ] || { echo "FAIL 시험이 0건이다" >&2; exit 1; }
[ "$FAILS" -eq 0 ] || { echo "host-k3s: ${FAILS}/${CASES} 실패" >&2; exit 1; }
echo "host-k3s: ${CASES}건 통과"
