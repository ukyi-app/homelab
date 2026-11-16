#!/bin/bash
# 관리자가 kubectl exec로 부르는 창구. 하는 일은 단계 이름을 실행기의 FIFO에 쓰고, 끝나기를 기다려 결과를 찍는 것뿐이다.
# 쓰는 법: ctl.sh list | ctl.sh <단계> [기다릴 초] | ctl.sh show <단계>
# hc를 직접 부르지 않는다. hc는 실행기만 쥔다.
# shellcheck source=lib.sh
. /opt/o02/lib.sh

show() { python3 "$O02_PY" sanitize <"$O02_OUT/$1.txt"; }
known() { grep -qxF -- "$1" "$O02_CTL/steps" 2>/dev/null; }

step=${1:-list}
case "$step" in
  list)
    cat "$O02_CTL/steps"
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
esac
limit=${2:-240}

if ! known "$step"; then
  echo "모르는 단계다. ctl.sh list로 목록을 본다." >&2
  exit 2
fi
pid=$(cat "$O02_CTL/executor.pid" 2>/dev/null)
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "실행기가 떠 있지 않다." >&2
  exit 3
fi
if [ -s "$O02_CTL/busy" ]; then
  echo "다른 단계가 도는 중이다: $(head -n 1 "$O02_CTL/busy" | tr -cd 'a-z0-9-'). 한 번에 하나만 돌린다." >&2
  exit 4
fi

rm -f "$O02_OUT/$step.done"
# 실행기가 FIFO를 읽고 있지 않으면 쓰기가 멈추므로 시간 상한을 둔다. 작은따옴표 안의 $1·$2는 안쪽 bash가 푼다.
# shellcheck disable=SC2016
if ! timeout 5 bash -c 'printf "%s\n" "$1" >"$2"' _ "$step" "$O02_CTL/in"; then
  echo "실행기가 단계를 받지 않는다." >&2
  exit 3
fi

waited=0
while [ ! -e "$O02_OUT/$step.done" ]; do
  sleep 1
  waited=$((waited + 1))
  if [ "$waited" -ge "$limit" ]; then
    echo "시간 초과(${limit}초). 지금까지의 결과:" >&2
    show "$step"
    exit 5
  fi
done
show "$step"
