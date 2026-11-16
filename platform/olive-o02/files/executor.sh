#!/bin/bash
# 실행기 역할의 고정 프로그램. 세션 컨테이너에서 hc를 쥐는 것은 이 프로세스뿐이다.
# 제어 FIFO로 단계 이름 한 줄을 받아, 아래 목록에 있는 이름일 때만 그 단계 함수를 돈다. 명령·인자·경로를 밖에서 받지 않는다.
# 단계 함수는 하위 셸이 아니라 이 프로세스 안에서 돈다. 그래야 "실행기가 직접 띄운 core"가 실행기의 자식이 된다.
# shellcheck source=lib.sh
. /opt/o02/lib.sh
# shellcheck source=steps.sh
. /opt/o02/steps.sh

umask 077
mkdir -p "$O02_OUT" "$O02_CTL" "$O02_ROOT/w" "$O02_ROOT/st" "$O02_ROOT/cf" "$O02_ROOT/rt" "$O02_ROOT/tmp" "$O02_ROOT/h"
# hc는 부른 쪽의 작업 폴더에서 프로그램을 띄운다. 이미지의 기본 작업 폴더(/root)는 uid 10001이 들어가지 못해 실행이 실패한다.
# 단계가 지우지 않는 폴더를 쓴다.
cd "$O02_ROOT/w" || exit 1
hc_env
[ -p "$O02_CTL/in" ] || mkfifo -m 600 "$O02_CTL/in"
printf '%s\n' "$O02_STEPS" | tr ' ' '\n' >"$O02_CTL/steps"
printf '%s\n' "$$" >"$O02_CTL/executor.pid"

# 앞 실행기가 단계 도중에 죽었으면(컨테이너가 다시 뜬 경우 포함) 그 단계의 결과에 적고 끝난 것으로 표시한다.
if [ -s "$O02_CTL/busy" ]; then
  prev=$(head -n 1 "$O02_CTL/busy" | tr -cd 'a-z0-9-')
  if [ -n "$prev" ]; then
    {
      echo "중단: 이 단계 도중에 실행기가 끝났고 새 실행기($$)가 떴다. 컨테이너가 다시 떴을 수 있다(kubectl get pod의 재시작 횟수와 마지막 종료 이유를 본다)."
      verdict "$prev" "판단 필요" "단계가 끝까지 돌지 못했다"
    } >>"$O02_OUT/$prev.txt"
    : >"$O02_OUT/$prev.done"
  fi
  rm -f "$O02_CTL/busy"
fi

while :; do
  step=""
  if ! read -r step <"$O02_CTL/in"; then
    sleep 1
    continue
  fi
  # 이름 글자부터 본다. 공백이 든 줄은 목록의 이웃한 두 이름과 맞아 버린다.
  case "$step" in
    '' | *[!a-z0-9-]*) step="" ;;
  esac
  case " $O02_STEPS " in
    *" $step "*) ;;
    *) step="" ;;
  esac
  if [ -z "$step" ]; then
    printf '%s 거절: 목록에 없는 단계\n' "$(date -u +%FT%TZ)" >>"$O02_CTL/refused.log"
    continue
  fi
  rm -f "$O02_OUT/$step.done"
  printf '%s\n' "$step" >"$O02_CTL/busy"
  {
    printf '단계 %s\n시작 %s 실행기 pid %s\n' "$step" "$(date -u +%FT%TZ)" "$$"
    "step_${step//-/_}"
    printf '끝 %s\n' "$(date -u +%FT%TZ)"
  } >"$O02_OUT/$step.txt" 2>&1
  rm -f "$O02_CTL/busy"
  : >"$O02_OUT/$step.done"
done
