#!/bin/bash
# 본체 컨테이너 안에서 도는 고정 프로그램. 본체가 전체 재시작을 버티려고 남기는 것들을 흉내 낸다.
#   plant <꼬리표>    아래 넷과 첩자 하나를 띄운다. 본체 자리 셸에 이 줄을 보내면(hc send) 본체 프로세스 나무에서 돈다.
#   sleeper·stubborn  그 자식들. 꼬리표가 명령줄에 남아야 bctl.sh가 찾는다(그래서 exec sleep을 쓰지 않는다).
mode=${1:-}
tag=${2:-x}

idle() {
  while :; do
    sleep 3 &
    wait "$!"
  done
}

case "$mode" in
  plant)
    setsid bash /opt/o25/plant.sh sleeper "$tag-setsid" </dev/null >/dev/null 2>&1 &
    nohup bash /opt/o25/plant.sh sleeper "$tag-nohup" </dev/null >/dev/null 2>&1 &
    # 두 번 떼어 낸 후손(데몬 방식). 작은따옴표 안의 $1은 안쪽 bash가 푼다.
    # shellcheck disable=SC2016
    (setsid bash -c 'bash /opt/o25/plant.sh sleeper "$1" </dev/null >/dev/null 2>&1 &' _ "$tag-daemon")
    setsid bash /opt/o25/plant.sh stubborn "$tag-stubborn" </dev/null >/dev/null 2>&1 &
    # 첩자: 다음 세대의 자격 소켓·중계 소켓에 붙어 보고, 살아 있다는 표시를 /b/spy에 남긴다(files/o25.py spy).
    setsid python3 /opt/o25/o25.py spy "$tag-spy" </dev/null >/dev/null 2>&1 &
    sleep 1
    echo "planted $tag: setsid nohup daemon stubborn spy"
    ;;
  sleeper)
    trap 'exit 0' TERM HUP INT
    idle
    ;;
  stubborn)
    trap '' TERM HUP INT
    idle
    ;;
  *)
    echo "plant.sh: 모르는 이름" >&2
    exit 2
    ;;
esac
