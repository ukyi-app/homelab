#!/bin/bash
# 세션 컨테이너의 PID 1. 하는 일은 둘이다: 실행기를 자식으로 띄우고, 부모를 잃은 프로세스를 거둔다.
# bash는 SIGCHLD를 받을 때 모르는 자식도 waitpid로 거둔다. 그래도 프로세스 표의 ST가 Z인 줄은 좀비로 따로 읽는다.
# TERM을 받으면 바로 끝난다. PID 1이 끝나면 커널이 이 PID 공간의 나머지를 모두 KILL한다.
trap 'exit 0' TERM INT

bash /opt/o02/executor.sh &
executor=$!

while :; do
  sleep 2 &
  wait "$!"
  # 실행기가 죽으면 다시 띄운다. 단계 도중이었으면 실행기가 뜨면서 그 사실을 결과에 적는다.
  if ! kill -0 "$executor" 2>/dev/null; then
    bash /opt/o02/executor.sh &
    executor=$!
  fi
done
