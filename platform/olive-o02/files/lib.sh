#!/bin/bash
# shellcheck shell=bash
# 공통 값과 도우미. executor.sh와 ctl.sh가 source한다.
# set -e·-u를 쓰지 않는다. 단계 함수가 실행기 프로세스 안에서 돌아, 한 줄의 실패가 실행기를 끝내면 안 된다.
# 여기서 정한 값은 source한 쪽이 쓴다.
# shellcheck disable=SC2034

# 실행기가 받는 단계 이름 전부. 이 목록에 없는 이름은 실행기가 거절한다.
O02_STEPS="preflight core-direct core-auto core-term core-kill holder-kill outlive hide cred-new-core cred-old-core cred-override residue view-noinput view-ctrl view-nocore limit-cpu limit-mem detach summary"

O02_ROOT=/s
O02_OUT=$O02_ROOT/out
O02_CTL=$O02_ROOT/ctl
O02_PY=/opt/o02/o02.py
O02_PROG=/opt/o02/prog.sh
HC=/opt/hc/hc
# hc의 상태·설정·소켓을 세션 폴더 하나에 모은다. 경로가 짧아야 한다(Unix 소켓 경로 한도, holder 소켓이 가장 길다).
O02_STATE=$O02_ROOT/st/herdr-core/o02
O02_SOCK=$O02_ROOT/rt/herdr-core/o02.sock

hc_env() {
  export XDG_STATE_HOME=$O02_ROOT/st XDG_CONFIG_HOME=$O02_ROOT/cf XDG_RUNTIME_DIR=$O02_ROOT/rt
  export HC_SESSION=o02 TMPDIR=$O02_ROOT/tmp HOME=$O02_ROOT/h SHELL=/bin/bash
}

# 제어 문자를 ?로 바꾼다(탭·줄바꿈 제외). 한글은 그대로 둔다. 결과 파일에 원시 화면 바이트가 섞이지 않게 한다.
clean() { LC_ALL=C tr '\000-\010\013-\037\177' '?'; }

# hc를 시간 상한을 두고 부른다. 멈춘 호출 하나가 단계를 붙잡지 않게 한다.
hcq() { timeout "${HC_T:-20}" "$HC" "$@"; }

# rec <명령...>: 명령, 출력(앞 60줄), 종료 코드를 결과에 남긴다.
rec() {
  local rc
  printf '$ %s\n' "$*"
  "$@" 2>&1 </dev/null | clean | head -n "${REC_LINES:-60}"
  rc=${PIPESTATUS[0]}
  printf '  -> exit %s\n' "$rc"
  return "$rc"
}

# verdict <항목 키> <됨|안 됨|판단 필요> <근거>. "됨"은 안전한 쪽 성질이 성립한다는 뜻이다.
verdict() { printf '결과 %s %s — %s\n' "$1" "$2" "$3"; }

# /proc에서 직접 읽는 프로세스 표. busybox ps에는 SID가 없다. ST가 Z면 거두지 않은 좀비다(살아 있는 프로세스가 아니다).
ps_dump() {
  local d pid stat comm rest st ppid pgid sid uid cmd
  printf '%-7s %-7s %-7s %-7s %-2s %-6s %s\n' PID PPID PGID SID ST UID CMD
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    stat=$(cat "$d/stat" 2>/dev/null) || continue
    [ -n "$stat" ] || continue
    comm=${stat#*\(}
    comm=${comm%\)*}
    rest=${stat##*\) }
    read -r st ppid pgid sid _ <<<"$rest"
    uid=$(awk '/^Uid:/ {print $2; exit}' "$d/status" 2>/dev/null)
    cmd=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null)
    printf '%-7s %-7s %-7s %-7s %-2s %-6s %s\n' "$pid" "$ppid" "$pgid" "$sid" "$st" "${uid:-?}" "${cmd:-[$comm]}"
  done
}

# 시험이 띄운 것만 추린 표(hc, 고정 프로그램).
ps_ours() { ps_dump | awk 'NR == 1 || /\/opt\/hc\/|\/opt\/o02\/(prog\.sh|o02\.py)/'; }

# pids_like <정규식>: 명령줄이 맞는 살아 있는 프로세스의 pid.
pids_like() {
  ps_dump | awk -v re="$1" 'NR > 1 && $5 != "Z" { cmd = ""; for (i = 7; i <= NF; i++) cmd = cmd " " $i; if (cmd ~ re) print $1 }'
}
# hc 0.1.21은 core를 "<실행 파일> serve", holder를 "<실행 파일> hold"로 띄운다(소스 client.rs, platform/systemd.rs).
# 인자 모양이 다르면 아래 둘이 비어 나온다. 그때는 ps_ours 표를 사람이 본다.
core_pids() { pids_like '/opt/hc/[a-z-]+ (.* )?serve( |$)'; }
holder_pids() { pids_like '/opt/hc/[a-z-]+ (.* )?hold( |$)'; }
prog_pids() { pids_like "/opt/o02/prog\\.sh [a-z]+ $1"; }

# client 소켓의 경로. 기대한 자리에 없으면 소켓 폴더와 상태 폴더에서 holder 것이 아닌 소켓을 찾는다.
find_sock() {
  local p
  for p in "$O02_SOCK" "$O02_ROOT"/rt/herdr-core/*.sock "$O02_STATE"/*.sock; do
    case "$p" in *.holder.*) continue ;; esac
    if [ -S "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

# core가 받는지를 hc client 없이 본다. hc client는 core가 없으면 띄우므로 확인에 쓰면 결과를 바꾼다.
core_up() {
  local s
  s=$(find_sock) || return 1
  python3 "$O02_PY" connect "$s" >/dev/null 2>&1
}

wait_core() {
  local i=0
  while [ "$i" -lt "${1:-75}" ]; do
    core_up && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

new_marker() {
  printf 'o02fake-%s-%s' "$1" "$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}
save_marker() { printf '%s\n' "$2" >"$O02_CTL/marker.$1"; }

# start_core <가짜 자격 표식>: 실행기가 core를 자기 자식으로 직접 띄운다. 표식은 core의 환경에만 넣는다(실행기 환경에는 없다).
# serve가 곧 끝나면(직접 실행이 안 되면) client 자동 기동으로 대신하고 그 사실을 적는다.
start_core() {
  local cpid
  O02_FAKE_CRED=$1 "$HC" serve >>"$O02_OUT/serve.log" 2>&1 </dev/null &
  cpid=$!
  if wait_core 75; then
    if kill -0 "$cpid" 2>/dev/null; then
      echo "core 기동: 직접 실행(serve), pid $cpid, 부모는 실행기 $$"
    else
      echo "core 기동: serve(pid $cpid)는 끝났는데 소켓은 받는다(스스로 분리했을 수 있다). 프로세스 표에서 core의 부모를 본다"
    fi
    return 0
  fi
  echo "직접 실행한 serve(pid $cpid)가 소켓을 열지 못했다. client 자동 기동으로 대신한다. serve.log 끝:"
  tail -n 5 "$O02_OUT/serve.log" 2>/dev/null | clean
  O02_FAKE_CRED=$1 timeout 30 "$HC" server start 2>&1 </dev/null | clean
  wait_core 75 && echo "core 기동: client 자동 기동(server start)"
}

ensure_core() {
  core_up && return 0
  local m
  m=$(new_marker X)
  save_marker X "$m"
  start_core "$m"
}

# 세션을 끝낸다: core 정지 뒤, 시험이 띄운 hc와 고정 프로그램을 모두 KILL한다. 상태 파일은 그대로 둔다.
full_stop() {
  local p
  if core_up; then HC_T=10 hcq server stop >/dev/null 2>&1; fi
  sleep 1
  for p in $(pids_like '/opt/hc/|/opt/o02/(prog\.sh|o02\.py)'); do
    kill -KILL "$p" 2>/dev/null
  done
  sleep 1
}

# 세션 폴더의 hc 자리를 비운다(시험 결과 out/과 제어 ctl/은 남긴다).
reset_state() {
  full_stop
  rm -rf "${O02_ROOT:?}/st" "${O02_ROOT:?}/cf" "${O02_ROOT:?}/rt" "${O02_ROOT:?}/tmp" "${O02_ROOT:?}/h"
  mkdir -m 700 "$O02_ROOT/st" "$O02_ROOT/cf" "$O02_ROOT/rt" "$O02_ROOT/tmp" "$O02_ROOT/h"
}

# ls_dir <폴더>: 바로 아래 항목의 권한·소유자·크기·이름.
ls_dir() {
  find "$1" -maxdepth 1 -exec ls -ld {} + 2>&1 | awk '{ print $1, $3, $4, $5, $NF }' | clean
}

# hc가 쓰는 자리에 남은 파일과 소켓.
list_files() {
  find "$O02_ROOT/st" "$O02_ROOT/cf" "$O02_ROOT/rt" "$O02_ROOT/tmp" "$O02_ROOT/h" -xdev \( -type f -o -type s \) -exec ls -ld {} + 2>/dev/null |
    awk '{ print $1, $5, $NF }' | clean
}

# grep_marker <표식>: hc가 쓰는 자리에서 표식이 든 파일. 없으면 "없음".
grep_marker() {
  local hit
  hit=$(grep -rl -- "$1" "$O02_ROOT/st" "$O02_ROOT/cf" "$O02_ROOT/rt" "$O02_ROOT/tmp" "$O02_ROOT/h" 2>/dev/null)
  if [ -n "$hit" ]; then printf '%s\n' "$hit" | clean; else echo "없음"; fi
}

# 컨테이너 안에서 본 cgroup: 시험 프로세스가 모두 이 컨테이너 cgroup에 있는지. 노드에서 본 값이 기준이고 이것은 보조다.
cgroup_inside() {
  local p n=0 missing=0 sub
  for p in $(pids_like '/opt/hc/|/opt/o02/(prog\.sh|o02\.py)'); do
    n=$((n + 1))
    if ! grep -qx "$p" /sys/fs/cgroup/cgroup.procs 2>/dev/null; then
      missing=$((missing + 1))
      echo "컨테이너 cgroup.procs에 없음: pid $p"
    fi
  done
  sub=$(find /sys/fs/cgroup -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  echo "시험 프로세스 $n개, 컨테이너 cgroup 밖 $missing개, 하위 cgroup $sub개"
  [ "$n" -gt 0 ] && [ "$missing" -eq 0 ]
}
