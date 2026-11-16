#!/bin/bash
# shellcheck shell=bash
# 제어 쪽 공통 값과 도우미. control.sh, ctl.sh, steps.sh가 source한다.
# set -e·-u를 쓰지 않는다. 단계 함수가 실행기 프로세스(제어 컨테이너 PID 1) 안에서 돌아, 한 줄의 실패가 실행기를 끝내면 안 된다.
# shellcheck disable=SC2034

# 실행기가 받는 단계 이름 전부. 이 목록에 없는 이름은 거절한다.
# 자격 검사(cred)는 여기 없다. ctl.sh로 부르면 기다리는 exec 셸이 검사 대상으로 남아 읽지 못한다. 요청 통로로만 받는다
# (o25.py submit cred → control.sh serve_req).
O25_STEPS="preflight boot relay hide-control relay-kill false-exit plant restart ctl-crash after-restart shm body-term body-after summary claude-ui"
# 본체 자리 변형(차트 body.variant, 환경변수 O25_BODY_VARIANT). 중계로 셸 명령을 보내는 단계는 셸 변형에서만,
# claude-ui는 claude 변형에서만 돈다. Claude 입력란에 셸 명령이 들어가지 않게 실행기가 거절한다(run.sh도 앞에서 막는다).
O25_VARIANT=${O25_BODY_VARIANT:-shell}
O25_SHELL_STEPS="relay false-exit plant body-term"
O25_CLAUDE_STEPS="claude-ui"
# step_fn <단계>: 실행할 함수 이름. 변형에 맞지 않으면 step_refused(거절 글만 남기고 아무것도 보내지 않는다).
step_fn() {
  case "$O25_VARIANT $1" in
    "claude relay" | "claude false-exit" | "claude plant" | "claude body-term") echo step_refused ;;
    "shell claude-ui") echo step_refused ;;
    "shell "* | "claude "*) echo "step_${1//-/_}" ;;
    *) echo step_refused ;;
  esac
}
step_refused() {
  echo "거절: 이 단계는 본체 자리 변형 '$O25_VARIANT'에서 돌지 않는다(셸 단계: $O25_SHELL_STEPS / claude 단계: $O25_CLAUDE_STEPS)"
  fact "step-refused variant=$O25_VARIANT"
}
# 자격 검사 요청이 꼭 내야 하는 판정 키(o25.py JOB_KEYS["cred"]와 같다).
O25_CRED_KEYS="6.hc-상태-없음 6.제어-argv-environ-없음 6.제어-로그-장부-없음 6.중계-폴더-없음 6.hc-화면-없음"

# 전체 재시작을 부르는 고정 종료 코드. 차트의 restartPolicyRules(templates/session.yaml)와 같은 값이어야 한다(O25_RESTART_CODE로 받는다).
O25_RC=${O25_RESTART_CODE:-86}
# 실행기만 혼자 죽는 시험(ctl-crash)의 종료 코드. 규칙에 없는 값이라 컨테이너 restartPolicy(Always)로 제어 컨테이너만 다시 뜬다.
O25_RC_CRASH=3

O25_OUT=/c/out
O25_CTL=/c/ctl
O25_LEDGER=/c/ledger
O25_PY=/opt/o25/o25.py
HC=/opt/hc/hc
BODY_UID=10002

# 지금 세대. init 컨테이너 gen이 정한다(files/gen.sh).
O25_GEN=$(cat /c/boot/current 2>/dev/null)
O25_G=/c/g/$O25_GEN
O25_RELAY=/relay/$O25_GEN
O25_SOCK=$O25_G/rt/herdr-core/o25.sock
# 이번 세대의 가짜 자격. 실행기(control.sh deliver_cred)만 채운다. 내보내지 않아 자식 환경·/proc environ에 실리지 않는다.
O25_MARK=""

hc_env() {
  export XDG_STATE_HOME=$O25_G/st XDG_CONFIG_HOME=$O25_G/cf XDG_RUNTIME_DIR=$O25_G/rt
  export HC_SESSION=o25 TMPDIR=$O25_G/tmp HOME=$O25_G/h SHELL=/bin/bash
}

# 제어 문자를 ?로 바꾼다(탭·줄바꿈 제외). 결과 파일에 원시 화면 바이트가 섞이지 않게 한다. UTF-8 C1·서식 문자는 밖의 sanitize.py가 지운다.
clean() { LC_ALL=C tr '\000-\010\013-\037\177' '?'; }
hcq() { timeout "${HC_T:-20}" "$HC" "$@"; }
rec() {
  local rc
  printf '$ %s\n' "$*"
  "$@" 2>&1 </dev/null | clean | head -n "${REC_LINES:-60}"
  rc=${PIPESTATUS[0]}
  printf '  -> exit %s\n' "$rc"
  return "$rc"
}
# verdict <키> <됨|안 됨|판단 필요> <근거>. "됨"은 안전한 쪽 성질이 성립한다는 뜻이다.
verdict() { printf '결과 %s %s — %s\n' "$1" "$2" "$3"; }
# verdict_c <키> <판정> <이유 코드> <근거>. 요청 통로로 로그에 나가는 판정. 코드는 o25.py CODES 안의 것만 쓴다(밖이면 그 줄이 버려진다).
verdict_c() { printf '결과 %s %s — %s (이유 %s)\n' "$1" "$2" "$4" "$3"; }
fact() { printf '사실 %s\n' "$*"; }
undecided() {
  local why=$1 k
  shift
  for k in "$@"; do verdict "$k" "판단 필요" "$why"; done
}
# 시각은 ns(o25.py의 time.time_ns()와 같은 단위). 이미지의 date(busybox)는 %N을 몰라 bash의 마이크로초 시각을 쓴다.
ledger() { printf '%s %s\n' "${EPOCHREALTIME/./}000" "$*" >>"$O25_LEDGER"; }
# 컨테이너 로그로 한 줄. control.sh가 시작 때 원래 표준 출력을 fd 3에 둔다(단계 블록은 표준 출력을 결과 파일로 돌린다).
# exec가 끊겨도(전체 재시작 단계) 그 실행의 로그에는 남는다. 다만 전체 재시작 뒤 앞 실행의 로그(--previous)는 못 읽을 수 있어
# 장부와 /c/out의 단계 파일이 기준이다.
logline() { printf '%s\n' "$*" >&3 2>/dev/null; }
# cred_count [세대]: 장부에 적힌 자격 전달 횟수. 세대를 주면 그 세대만.
cred_count() {
  if [ -n "${1:-}" ]; then grep -c " cred-delivered gen=$1 " "$O25_LEDGER" 2>/dev/null; else grep -c ' cred-delivered ' "$O25_LEDGER" 2>/dev/null; fi
}

# /proc에서 직접 읽는 프로세스 표. 2>/dev/null을 < 앞에 둔다(그새 끝난 프로세스의 파일을 못 연 셸 오류가 찍히지 않게).
ps_dump() {
  local d stat rest st ppid pgid sid uid cmd comm
  printf '%-7s %-7s %-7s %-7s %-2s %-6s %s\n' PID PPID PGID SID ST UID CMD
  for d in /proc/[0-9]*; do
    { read -r stat <"$d/stat"; } 2>/dev/null || continue
    comm=${stat#*\(}
    comm=${comm%\)*}
    rest=${stat##*\) }
    read -r st ppid pgid sid _ <<<"$rest"
    uid=$(awk '/^Uid:/ {print $2; exit}' 2>/dev/null <"$d/status")
    cmd=$(tr '\0' ' ' 2>/dev/null <"$d/cmdline" | cut -c1-110)
    printf '%-7s %-7s %-7s %-7s %-2s %-6s %s\n' "${d#/proc/}" "$ppid" "$pgid" "$sid" "$st" "${uid:-?}" "${cmd:-[$comm]}"
  done
}

# pids_like <정규식>: 명령줄이 맞는 살아 있는 프로세스. 명령줄 앞에 공백 하나를 붙여 견준다("^ "가 argv[0]의 시작이다).
# bash 내장만 쓴다. 정규식을 argv에 든 도우미를 띄우면 그 도우미가 자기 정규식에 맞는다.
pids_like() {
  local d stat f args cmd
  for d in /proc/[0-9]*; do
    { read -r stat <"$d/stat"; } 2>/dev/null || continue
    read -ra f <<<"${stat##*) }"
    [ "${f[0]:-Z}" = Z ] && continue
    args=()
    { mapfile -d '' -t args <"$d/cmdline"; } 2>/dev/null || continue
    [ "${#args[@]}" -gt 0 ] || continue
    cmd=${args[*]}
    if [[ " ${cmd//$'\n'/ }" =~ $1 ]]; then printf '%s\n' "${d#/proc/}"; fi
  done
}
core_pids() { pids_like '/opt/hc/[a-z-]+ (.* )?serve( |$)'; }
relay_pids() { pids_like '^ [^ ]*python3 /opt/o25/o25\.py relay-serve '; }
credsrv_pids() { pids_like '^ [^ ]*python3 /opt/o25/o25\.py cred-serve '; }
one_line() { tr '\n' ' '; }

core_up() { [ -S "$O25_SOCK" ] && python3 "$O25_PY" connect "$O25_SOCK" >/dev/null 2>&1; }
wait_core() {
  local i=0
  while [ "$i" -lt "${1:-75}" ]; do
    core_up && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}
wait_file() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt "${2:-30}" ]; do
    sleep 1
    i=$((i + 1))
  done
  [ -e "$1" ]
}
