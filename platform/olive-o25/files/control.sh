#!/bin/bash
# 제어 컨테이너의 PID 1. 실행기 자리다: 시작 문지기 → hc core·중계·자격 전달 → 단계 이름만 받는 루프.
#
# 시작 문지기(반박 검토 §2.3의 절차 3):
#   1. init(gen.sh)이 이번 부팅에 만든 일회용 허가를 rename 한 번으로 쓴다. 이미 쓴 허가가 보이면 실행기만 혼자 다시 뜬 것이다.
#      옛 본체가 살아 있을 수 있으므로 자격을 주지 않고 전체 재시작 종료 코드로 끝난다.
#   2. 이 파드에서 "전체 재시작을 요청했더니 init이 다시 돌아 새 세대가 왔다"를 한 번도 본 적이 없으면, 규칙이 파드에 실렸는지
#      모른다(기능 게이트가 꺼지면 API 서버가 restartPolicyRules를 떨어뜨린다). 그래서 첫 세대에서는 일부러 전체 재시작을 요청한다.
#      규칙이 없으면 실행기만 다시 떠 1에서 막히고 같은 종료를 되풀이한다(CrashLoopBackOff). 자격은 한 번도 나가지 않는다.
#   3. 둘 다 통과하면 새 세대의 hc core, 중계, 자격 전달을 차례로 띄운다. 자격은 세대마다 한 번만 준다.
# 실행기는 밖에서 명령·인자·경로를 받지 않는다. 제어 FIFO로 단계 이름 한 줄만 받는다.
# shellcheck source=lib.sh
. /opt/o25/lib.sh
# shellcheck source=steps.sh
. /opt/o25/steps.sh

trap 'exit 0' TERM INT
umask 077
cd /c || exit 1

# exit_restart <이유>: 장부에 남기고 전체 재시작 종료 코드로 끝난다. 로그(표준 출력)에는 세대와 이유만 적는다.
exit_restart() {
  ledger "exit-request gen=$O25_GEN reason=$1"
  echo "o25 gate: gen=$O25_GEN $1, exit $O25_RC"
  exit "$O25_RC"
}

gate() {
  local relay_gen
  if [ -z "$O25_GEN" ] || [ ! -d "/c/boot/$O25_GEN" ]; then
    exit_restart no-generation
  fi
  relay_gen=$(cut -d' ' -f1 /relay/current 2>/dev/null)
  if [ "$relay_gen" != "$O25_GEN" ]; then
    exit_restart relay-generation-mismatch
  fi
  if ! mv "/c/boot/$O25_GEN/permit" "/c/boot/$O25_GEN/used" 2>/dev/null; then
    if [ -e "/c/boot/$O25_GEN/used" ]; then exit_restart used-permit; fi
    exit_restart no-permit
  fi
  ledger "permit-used gen=$O25_GEN"
  # 앞 세대에서 전체 재시작을 요청한 기록이 있고 지금 새 세대에 와 있다 = 규칙이 동작했다.
  if ! grep -E ' exit-request gen=[0-9a-f]+ ' "$O25_LEDGER" | grep -vq " gen=$O25_GEN "; then
    exit_restart canary
  fi
  ledger "rule-verified gen=$O25_GEN"
}

start_session() {
  local cpid
  hc_env
  # core에는 자격을 주지 않는다. 자격은 본체에게만 간다(cred-serve). core 환경에 표식이 없어야 cred 단계의 검사가 뜻이 있다.
  "$HC" serve >>"$O25_OUT/serve-$O25_GEN.log" 2>&1 </dev/null &
  cpid=$!
  if ! wait_core 75; then
    ledger "session-fail gen=$O25_GEN reason=core"
    echo "o25: core가 뜨지 않았다(gen=$O25_GEN)"
    return 1
  fi
  ledger "core gen=$O25_GEN pid=$cpid"
  if ! hcq run --bg --name body -- python3 "$O25_PY" relay-serve "$O25_RELAY/r.sock" "$O25_OUT/relay-$O25_GEN.log" >>"$O25_OUT/serve-$O25_GEN.log" 2>&1 </dev/null; then
    ledger "session-fail gen=$O25_GEN reason=relay"
    return 1
  fi
  wait_file "$O25_RELAY/r.sock" 15 || ledger "session-warn gen=$O25_GEN reason=relay-socket-late"
  deliver_cred
}

# deliver_cred: 이번 세대의 가짜 자격을 한 번만 내놓는다. 값은 이 셸 변수(내보내지 않음)와 cred-serve의 표준 입력에만 있다.
deliver_cred() {
  if grep -q " cred-offered gen=$O25_GEN " "$O25_LEDGER" 2>/dev/null; then
    ledger "cred-refused gen=$O25_GEN reason=already-offered"
    return 1
  fi
  O25_MARK="o25fake-$O25_GEN-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  ledger "cred-offered gen=$O25_GEN sha=$(printf '%s' "$O25_MARK" | python3 "$O25_PY" sha) "
  printf '%s' "$O25_MARK" | python3 "$O25_PY" cred-serve "$O25_RELAY/cred.sock" "$O25_LEDGER" &
  return 0
}

gate
mkdir -p "$O25_OUT" "$O25_CTL"
start_session || exit_restart session-fail
[ -p "$O25_CTL/in" ] || mkfifo -m 600 "$O25_CTL/in"
printf '%s\n' "$O25_STEPS" | tr ' ' '\n' >"$O25_CTL/steps"
printf '%s\n' "$$" >"$O25_CTL/executor.pid"
ledger "ready gen=$O25_GEN"
echo "o25: ready gen=$O25_GEN"

# 앞 실행기가 단계 도중에 끝났으면(전체 재시작·ctl-crash 포함) 그 단계의 결과에 적고 끝난 것으로 표시한다.
if [ -s "$O25_CTL/busy" ]; then
  prev=$(head -n 1 "$O25_CTL/busy" | tr -cd 'a-z0-9-')
  if [ -n "$prev" ]; then
    echo "중단: 이 단계 도중에 실행기가 끝났고 새 세대 $O25_GEN의 실행기가 떴다(after-restart 단계로 이어서 본다)" >>"$O25_OUT/$prev.txt"
    : >"$O25_OUT/$prev.done"
  fi
  rm -f "$O25_CTL/busy"
fi

while :; do
  step=""
  if ! read -r step <"$O25_CTL/in"; then
    sleep 1
    continue
  fi
  case "$step" in
    '' | *[!a-z0-9-]*) step="" ;;
  esac
  case " $O25_STEPS " in
    *" $step "*) ;;
    *) step="" ;;
  esac
  if [ -z "$step" ]; then
    printf '%s 거절: 목록에 없는 단계\n' "$(date -u +%FT%TZ)" >>"$O25_CTL/refused.log"
    continue
  fi
  rm -f "$O25_OUT/$step.done"
  printf '%s\n' "$step" >"$O25_CTL/busy"
  {
    printf '단계 %s\n시작 %s 세대 %s 실행기 pid %s\n' "$step" "$(date -u +%FT%TZ)" "$O25_GEN" "$$"
    "step_${step//-/_}"
    printf '끝 %s\n' "$(date -u +%FT%TZ)"
  } >"$O25_OUT/$step.txt" 2>&1
  rm -f "$O25_CTL/busy"
  : >"$O25_OUT/$step.done"
done
