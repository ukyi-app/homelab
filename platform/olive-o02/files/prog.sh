#!/bin/bash
# hc 터미널 안에서 도는 고정 프로그램. 인자는 정해진 이름과 꼬리표뿐이다.
# 꼬리표가 명령줄에 남아야 한다. 노드에서 /proc/<pid>/cmdline의 /opt/o02/로 시험 프로세스를 찾는다. 그래서 exec sleep을 쓰지 않는다.
mode=${1:-}
tag=${2:-x}

idle() {
  while :; do
    sleep 3 &
    wait "$!"
  done
}

case "$mode" in
  sleeper)
    trap 'exit 0' TERM HUP INT
    idle
    ;;
  stubborn)
    # TERM·HUP·INT를 무시한다. 터미널 종료와 파드 종료에서 남는지 본다.
    trap '' TERM HUP INT
    idle
    ;;
  envdump)
    # 받은 환경의 표식을 화면이 아니라 파일에 적는다. 화면에 찍으면 hc가 저장하는 화면에 표식이 남아,
    # hc 자신이 남긴 것(환경 저장, env override, argv)과 구분할 수 없다.
    {
      printf 'O02_FAKE_CRED=%s\n' "${O02_FAKE_CRED-<unset>}"
      printf 'O02_FAKE_OVERRIDE=%s\n' "${O02_FAKE_OVERRIDE-<unset>}"
      printf 'HC·XDG·O02 변수 이름: %s\n' "$(env | cut -d= -f1 | grep -E '^(HC_|XDG_|O02_)' | sort | tr '\n' ' ')"
    } >"/s/out/env-$tag.txt"
    echo "envdump $tag done"
    ;;
  parent)
    # 자식 터미널 둘을 연다: 기본(부모와 함께 끝남)과 --outlive-parent.
    /opt/hc/hc run --bg --name "c-default-$tag" -- bash /opt/o02/prog.sh sleeper "c-default-$tag"
    /opt/hc/hc run --bg --outlive-parent --name "c-outlive-$tag" -- bash /opt/o02/prog.sh sleeper "c-outlive-$tag"
    trap 'exit 0' TERM HUP INT
    idle
    ;;
  detacher)
    # 세션을 분리한 후손 넷과 분리하지 않은 자식 하나(대조군)를 띄운다.
    setsid bash /opt/o02/prog.sh sleeper "det-setsid-$tag" </dev/null >/dev/null 2>&1 &
    nohup bash /opt/o02/prog.sh sleeper "det-nohup-$tag" </dev/null >/dev/null 2>&1 &
    # 두 번 떼어 낸 후손(데몬 방식). 작은따옴표 안의 $1은 안쪽 bash가 푼다.
    # shellcheck disable=SC2016
    (setsid bash -c 'bash /opt/o02/prog.sh sleeper "$1" </dev/null >/dev/null 2>&1 &' _ "det-daemon-$tag")
    setsid bash /opt/o02/prog.sh stubborn "det-stubborn-$tag" </dev/null >/dev/null 2>&1 &
    bash /opt/o02/prog.sh sleeper "det-child-$tag" &
    trap 'exit 0' TERM HUP INT
    idle
    ;;
  *)
    echo "prog.sh: 모르는 이름" >&2
    exit 2
    ;;
esac
