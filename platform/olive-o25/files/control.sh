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
#
# 계획된 전체 재시작(첫 세대의 규칙 확인, 시험 단계 restart·ctl-crash)과 기동 실패를 가른다. 전체 재시작은 종료 기록을 지워
# kubelet의 재시작 지연(CrashLoopBackOff)이 걸리지 않는다. 그래서 기동 실패는 세대를 넘어 남는 횟수(/c/fail-count)로 세고,
# 실패마다 스스로 기다린 뒤 끝나며, 한도에 닿으면 자격을 주지 않고 멈춘 채로 남는다(hold). 장부·횟수 기록에 실패해도 hold다.
# shellcheck source=lib.sh
. /opt/o25/lib.sh
# shellcheck source=steps.sh
. /opt/o25/steps.sh

trap 'exit 0' TERM INT
umask 077
cd /c || exit 1
exec 3>&1

O25_FAIL=/c/fail-count
O25_FAIL_LIMIT=${O25_FAIL_LIMIT:-3}

# exit_restart <이유>: 장부에 남기고 전체 재시작 종료 코드로 끝난다. 로그(표준 출력)에는 세대와 이유만 적는다.
exit_restart() {
  ledger "exit-request gen=$O25_GEN reason=$1"
  echo "o25 gate: gen=$O25_GEN $1, exit $O25_RC"
  exit "$O25_RC"
}

# hold <이유>: 자격을 주지 않고, 끝나지도 않는다(끝나면 전체 재시작이 되풀이된다). 관리자가 로그·gate로 보고 파드를 끈다.
hold() {
  ledger "hold gen=$O25_GEN reason=$1"
  echo "o25 hold: gen=$O25_GEN $1 (자격 없음, 다시 시작을 요청하지 않는다)"
  while :; do
    sleep 60 &
    wait "$!"
  done
}

# fail_restart <이유>: 기동 실패. 세대를 넘어 남는 횟수를 올리고, 한도면 hold, 아니면 5·10·20…(최대 60)초 기다린 뒤 전체 재시작.
fail_restart() {
  local n
  n=$(head -c 16 "$O25_FAIL" 2>/dev/null | tr -cd '0-9')
  n=$((${n:-0} + 1))
  if ! printf '%s\n' "$n" >"$O25_FAIL.tmp" 2>/dev/null || ! mv -f "$O25_FAIL.tmp" "$O25_FAIL" 2>/dev/null; then
    hold "fail-count-write reason=$1"
  fi
  ledger "start-fail gen=$O25_GEN n=$n reason=$1" || hold "ledger-write reason=$1"
  if [ "$n" -ge "$O25_FAIL_LIMIT" ]; then
    hold "start-failures n=$n limit=$O25_FAIL_LIMIT reason=$1"
  fi
  local wait_s=$((5 << (n - 1)))
  [ "$wait_s" -gt 60 ] && wait_s=60
  echo "o25 gate: gen=$O25_GEN 기동 실패 $n회($1), ${wait_s}초 뒤 끝난다"
  sleep "$wait_s" &
  wait "$!"
  exit_restart "$1"
}

gate() {
  local relay_gen
  if [ -z "$O25_GEN" ] || [ ! -d "/c/boot/$O25_GEN" ]; then
    fail_restart no-generation
  fi
  relay_gen=$(cut -d' ' -f1 /relay/current 2>/dev/null)
  if [ "$relay_gen" != "$O25_GEN" ]; then
    fail_restart relay-generation-mismatch
  fi
  if ! mv "/c/boot/$O25_GEN/permit" "/c/boot/$O25_GEN/used" 2>/dev/null; then
    if [ ! -e "/c/boot/$O25_GEN/used" ]; then fail_restart no-permit; fi
    # 실행기만 혼자 다시 떴다. ctl-crash 단계가 시킨 것이면 계획된 재시작이다.
    # 규칙이 아직 확인되지 않은 파드(규칙 누락 변형)는 이 종료가 컨테이너 하나의 재시작이라 kubelet의 지연이 걸린다.
    # 규칙이 확인된 파드에서 시키지 않은 단독 재시작(제어 쪽 OOM 등)은 전체 재시작을 되풀이하므로 기동 실패로 센다.
    if grep -q " crash-request gen=$O25_GEN " "$O25_LEDGER" 2>/dev/null || ! grep -q ' rule-verified ' "$O25_LEDGER" 2>/dev/null; then
      exit_restart used-permit
    fi
    fail_restart used-permit-unplanned
  fi
  ledger "permit-used gen=$O25_GEN" || hold ledger-write-permit
  # 앞 세대에서 전체 재시작을 요청한 기록이 있고 지금 새 세대에 와 있다 = 규칙이 동작했다.
  if ! grep -E ' exit-request gen=[0-9a-f]+ ' "$O25_LEDGER" | grep -vq " gen=$O25_GEN "; then
    # 규칙 확인은 파드마다 한 번이다. 앞 세대의 요청이 장부에 없는데 확인을 이미 요청한 적이 있으면 장부가 이상한 것이다.
    if grep -q ' reason=canary$' "$O25_LEDGER" 2>/dev/null; then fail_restart canary-repeat; fi
    exit_restart canary
  fi
  ledger "rule-verified gen=$O25_GEN" || hold ledger-write-rule
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
  # 잠금 기록(cred-offered)을 못 남기면 내놓지 않는다. 기록 없이 내놓으면 같은 세대의 두 번째 제공을 막지 못한다.
  if ! ledger "cred-offered gen=$O25_GEN sha=$(printf '%s' "$O25_MARK" | python3 "$O25_PY" sha) "; then
    O25_MARK=""
    return 1
  fi
  printf '%s' "$O25_MARK" | python3 "$O25_PY" cred-serve "$O25_RELAY/cred.sock" "$O25_LEDGER" &
  return 0
}

# serve_req <요청 줄>: 자격 검사 요청(o25.py submit cred가 쓴 고정 필드 한 줄). 실행기 PID 1 안에서 차례로 돈다(한 번에 하나).
#   1. accept: 모양·작업·세대·처음 보는 요청 ID인지. 아니면 로그에 거절 줄만 남긴다.
#   2. gate: 제출자가 그 PID·시작 시각으로 보였고, 인수 표시 뒤 실제로 사라졌는지. 확인하지 못하면 검사하지 않고 판단 필요.
#      고정 대기 시간·이름·PPID·kill -0 실패는 소멸의 증거로 쓰지 않는다.
#   3. step_cred(표식은 이 셸 변수에만 있다) → 결과 파일 → publish가 정해진 모양의 줄만 원래 표준 출력(컨테이너 로그)으로.
# 결과 파일 /c/out/req-<요청 ID>.txt는 근거 글 전체다. 로그의 판정 줄은 그 줄의 sha만 싣는다(ctl.sh show-req로 대조).
serve_req() {
  local acc st job req pid start f g code k
  acc=$(printf '%s\n' "$1" | python3 "$O25_PY" accept "$O25_GEN" "$O25_CTL/reqs" 2>/dev/null)
  if [[ $acc =~ ^reject\ ([a-z-]{1,16})\ ([0-9a-f]{12}|-)$ ]]; then
    logline "o25r ${O25_POD_UID:-?} $O25_GEN ${BASH_REMATCH[2]} reject code=${BASH_REMATCH[1]}"
    return
  fi
  read -r st job req pid start <<<"$acc"
  if [ "$st" != ok ] || [ "$job" != cred ] || ! [[ $req =~ ^[0-9a-f]{12}$ && $pid =~ ^[0-9]+$ && $start =~ ^[0-9]+$ ]]; then
    logline "o25r ${O25_POD_UID:-?} $O25_GEN - reject code=accept-failed"
    return
  fi
  f=$O25_OUT/req-$req.txt
  printf 'req-%s\n' "$req" >"$O25_CTL/busy"
  {
    printf '요청 %s 작업 %s 세대 %s 실행기 pid %s 제출자 pid %s 시작 %s\n' "$req" "$job" "$O25_GEN" "$$" "$pid" "$start"
    g=$(python3 "$O25_PY" gate "$O25_CTL/ack" "$req" "$pid" "$start" 2>&1)
    code=$?
    printf '%s\n' "$g" | clean
    if [ "$code" -eq 0 ]; then
      step_cred
    else
      code=$(printf '%s\n' "$g" | sed -n 's/^gate state=undecided code=\(submitter-[a-z]*\) .*/\1/p')
      for k in $O25_CRED_KEYS; do verdict_c "$k" "판단 필요" "${code:-submitter-unread}" "제출자가 사라진 것을 확인하지 못해 검사하지 않았다"; done
    fi
  } >"$f" 2>&1
  python3 "$O25_PY" publish cred "${O25_POD_UID:-?}" "$O25_GEN" "$req" <"$f" >&3 2>/dev/null
  rm -f "$O25_CTL/busy"
}

gate
mkdir -p "$O25_OUT" "$O25_CTL" "$O25_CTL/ack"
start_session || fail_restart session-fail
[ -p "$O25_CTL/in" ] || mkfifo -m 600 "$O25_CTL/in"
printf '%s\n' "$O25_STEPS" | tr ' ' '\n' >"$O25_CTL/steps"
printf '%s\n' "$$" >"$O25_CTL/executor.pid"
ledger "ready gen=$O25_GEN"
rm -f "$O25_FAIL"
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
  if [[ $step == "req1 "* ]]; then
    serve_req "$step"
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
