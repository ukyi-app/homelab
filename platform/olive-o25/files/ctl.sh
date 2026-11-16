#!/bin/bash
# 관리자가 kubectl exec로 제어 컨테이너에서 부르는 창구. 단계 이름을 실행기의 FIFO에 쓰고, 끝나기를 기다려 결과를 찍는다.
# 쓰는 법: ctl.sh list | ctl.sh <단계> [기다릴 초] | ctl.sh show <단계> | ctl.sh gate
# hc를 직접 부르지 않는다. hc는 실행기만 쥔다.
# gate는 실행기가 단계를 받지 않을 때 세대·허가·장부를 읽기만 한다. 제어 컨테이너가 떠 있어야 exec가 된다.
# 규칙 누락 변형의 CrashLoopBackOff처럼 컨테이너가 멈춰 있으면 gate도 못 부른다. 그때는 control 로그(문지기 줄)를 본다.
# shellcheck source=lib.sh
. /opt/o25/lib.sh

show() { python3 "$O25_PY" sanitize <"$O25_OUT/$1.txt"; }
known() { grep -qxF -- "$1" "$O25_CTL/steps" 2>/dev/null; }

step=${1:-list}
case "$step" in
  list)
    cat "$O25_CTL/steps"
    exit 0
    ;;
  show)
    if ! known "${2:-}"; then
      echo "모르는 단계: ${2:-}" >&2
      exit 2
    fi
    show "$2"
    exit 0
    ;;
  gate)
    {
      echo "== 세대 기록"
      cat /c/boot/history
      echo "== 장부 끝"
      tail -n 30 "$O25_LEDGER"
    } 2>&1 | python3 "$O25_PY" sanitize
    exit 0
    ;;
esac
limit=${2:-240}

if ! known "$step"; then
  echo "모르는 단계다. ctl.sh list로 목록을 본다." >&2
  exit 2
fi
pid=$(cat "$O25_CTL/executor.pid" 2>/dev/null)
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "실행기가 떠 있지 않다." >&2
  exit 3
fi
if [ -s "$O25_CTL/busy" ]; then
  echo "다른 단계가 도는 중이다: $(head -n 1 "$O25_CTL/busy" | tr -cd 'a-z0-9-'). 한 번에 하나만 돌린다." >&2
  exit 4
fi

rm -f "$O25_OUT/$step.done"
# 실행기가 FIFO를 읽고 있지 않으면 쓰기가 멈추므로 시간 상한을 둔다. 작은따옴표 안의 $1·$2는 안쪽 bash가 푼다.
# shellcheck disable=SC2016
if ! timeout 5 bash -c 'printf "%s\n" "$1" >"$2"' _ "$step" "$O25_CTL/in"; then
  echo "실행기가 단계를 받지 않는다." >&2
  exit 3
fi

waited=0
while [ ! -e "$O25_OUT/$step.done" ]; do
  sleep 1
  waited=$((waited + 1))
  # 전체 재시작·실행기 종료 단계는 끝 표시를 남기지 못한다. 실행기가 사라지면 지금까지의 결과를 찍고 끝난다.
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "실행기(pid $pid)가 끝났다. 지금까지의 결과:" >&2
    show "$step"
    exit 6
  fi
  if [ "$waited" -ge "$limit" ]; then
    echo "시간 초과(${limit}초). 지금까지의 결과:" >&2
    show "$step"
    exit 5
  fi
done
show "$step"
