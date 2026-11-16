#!/bin/bash
# init 컨테이너 gen: 파드가 (다시) 뜰 때마다 새 부팅 세대와 일회용 시작 허가를 만든다.
# 일반 init 컨테이너라 전체 재시작(RestartAllContainers) 때마다 모든 본 컨테이너가 끝난 뒤 다시 돈다. 실행기만 혼자 다시 뜨면 돌지 않는다.
# 그래서 "허가가 새것이다" = "이 init이 다시 돌았다" = "본 컨테이너가 모두 새로 떴다"로 읽는다.
# 허가는 제어 컨테이너에만 붙는 /c/boot에 둔다. 본체에는 세대 ID와 init 시각만 /relay/current로 보인다(비밀이 아니다).
# emptyDir은 재시작 뒤에도 남는다. 옛 세대의 파일을 지우지 않고 세대마다 새 경로를 쓴다.
set -euo pipefail
umask 077

gen=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
# 이미지의 date(busybox)는 %N을 모른다. bash의 마이크로초 시각을 ns로 맞춘다(o25.py의 time.time_ns()와 같은 단위).
init_ns=${EPOCHREALTIME/./}000
mkdir -p /c/boot /c/g /c/out /c/ctl
[ -e "/c/boot/$gen" ] && {
  echo "세대 ID가 겹친다: $gen" >&2
  exit 1
}
mkdir -m 700 "/c/boot/$gen"
printf 'gen=%s init_ns=%s\n' "$gen" "$init_ns" >"/c/boot/$gen/permit"
mkdir -m 700 "/c/g/$gen" "/c/g/$gen/st" "/c/g/$gen/cf" "/c/g/$gen/rt" "/c/g/$gen/tmp" "/c/g/$gen/h"
# 중계 폴더는 본체가 읽고 연결만 한다(본체에는 읽기 전용 마운트). 소켓은 제어 쪽이 나중에 만든다.
mkdir -m 755 "/relay/$gen"
printf '%s %s\n' "$gen" "$init_ns" >/relay/current.tmp
chmod 644 /relay/current.tmp
mv -f /relay/current.tmp /relay/current
printf '%s\n' "$gen" >/c/boot/current.tmp
mv -f /c/boot/current.tmp /c/boot/current
printf '%s %s %s\n' "$gen" "$init_ns" "$(date -u +%FT%TZ)" >>/c/boot/history
printf '%s gen-init gen=%s\n' "$init_ns" "$gen" >>/c/ledger
echo "gen $gen init_ns $init_ns boots $(wc -l </c/boot/history)"
