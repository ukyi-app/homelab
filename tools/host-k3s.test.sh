#!/usr/bin/env bash
# host/install.sh check_install_time_keys 시험. ci가 부른다. root·k3s 없이 돈다.
# node-name·node-ip는 설치 때 값으로 고정하고(다르면 멈춤), tls-san은 차이만 출력하고 통과한다.
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

# 0건 통과는 실패다(B.8 E7).
[ "$CASES" -gt 0 ] || { echo "FAIL 시험이 0건이다" >&2; exit 1; }
[ "$FAILS" -eq 0 ] || { echo "host-k3s: ${FAILS}/${CASES} 실패" >&2; exit 1; }
echo "host-k3s: ${CASES}건 통과"
