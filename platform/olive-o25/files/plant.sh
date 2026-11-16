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

# find_role <꼬리표-역할>: 명령줄의 마지막 낱말이 정확히 그것인 살아 있는 프로세스의 "pid 시작시각"(시작시각은 /proc/<pid>/stat 22번째, 부팅 뒤 tick).
find_role() {
  local d stat f args
  for d in /proc/[0-9]*; do
    { read -r stat <"$d/stat"; } 2>/dev/null || continue
    read -ra f <<<"${stat##*) }"
    [ "${f[0]:-Z}" = Z ] && continue
    args=()
    { mapfile -d '' -t args <"$d/cmdline"; } 2>/dev/null || continue
    [ "${#args[@]}" -ge 2 ] || continue
    if [ "${args[-1]}" = "$1" ]; then printf '%s %s\n' "${d#/proc/}" "${f[19]}"; fi
  done
}
hb_field() { sed -n "s/.*$1=\([0-9]*\).*/\1/p" "$2" 2>/dev/null; }

case "$mode" in
  plant)
    # 영수증: 이 세대에 심은 다섯 역할이 실제로 떴고 첩자가 움직인다는 기록. 확인되지 않으면 영수증 줄을 찍지 않는다.
    # 실행기는 영수증 줄이 화면에 있을 때만 심기를 성공으로 적고, 소멸 판정은 이 영수증의 대상만 본다.
    gen=${tag#p-}
    read -r cur _ </relay/current 2>/dev/null
    if [ "$gen" != "${cur:-}" ]; then
      echo "plant-failed $tag: 지금 세대(${cur:-?})의 꼬리표가 아니다"
      exit 1
    fi
    if ! mkdir -p /b/receipt /b/spy || [ -e "/b/receipt/$gen" ]; then
      echo "plant-failed $tag: 영수증 폴더를 못 만들었거나 이 세대에 이미 심었다"
      exit 1
    fi
    setsid bash /opt/o25/plant.sh sleeper "$tag-setsid" </dev/null >/dev/null 2>&1 &
    nohup bash /opt/o25/plant.sh sleeper "$tag-nohup" </dev/null >/dev/null 2>&1 &
    # 두 번 떼어 낸 후손(데몬 방식). 작은따옴표 안의 $1은 안쪽 bash가 푼다.
    # shellcheck disable=SC2016
    (setsid bash -c 'bash /opt/o25/plant.sh sleeper "$1" </dev/null >/dev/null 2>&1 &' _ "$tag-daemon")
    setsid bash /opt/o25/plant.sh stubborn "$tag-stubborn" </dev/null >/dev/null 2>&1 &
    # 첩자: 다음 세대의 자격 소켓·중계 소켓에 붙어 보고, 살아 있다는 표시를 /b/spy에 남긴다(files/o25.py spy).
    setsid python3 /opt/o25/o25.py spy "$tag-spy" </dev/null >/dev/null 2>&1 &
    sleep 1
    rec=$(mktemp /b/receipt/.r.XXXXXX) || {
      echo "plant-failed $tag: 영수증 임시 파일"
      exit 1
    }
    printf 'pod=%s gen=%s\n' "${O25_POD_UID:-?}" "$gen" >"$rec"
    missing=""
    for role in setsid nohup daemon stubborn spy; do
      found=$(find_role "$tag-$role")
      # 정확히 하나여야 한다. 0개는 시작 실패, 2개 이상은 꼬리표가 겹친 것이다.
      if [ "$(printf '%s' "$found" | grep -c .)" != 1 ]; then
        missing="$missing $role"
        continue
      fi
      printf 'role=%s pid=%s start=%s\n' "$role" "${found% *}" "${found#* }" >>"$rec"
    done
    spy_pid=$(sed -n 's/^role=spy pid=\([0-9]*\) .*/\1/p' "$rec")
    hb=/b/spy/$tag-spy.hb
    t1=$(hb_field now_ns "$hb")
    # 첩자 한 바퀴는 0.2초지만 다른 세대에 듣는 소켓이 남아 있으면 바퀴마다 1초 받기 대기가 더해진다. 3초까지 기다린다.
    t2=$t1
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      sleep 0.2
      t2=$(hb_field now_ns "$hb")
      [ -n "$t1" ] && [ -n "$t2" ] && [ "$t2" -gt "$t1" ] && break
    done
    if [ -z "$missing" ] && [ -n "$t1" ] && [ -n "$t2" ] && [ "$t2" -gt "$t1" ] && [ "$(hb_field pid "$hb")" = "$spy_pid" ]; then
      printf 'spy_hb=%s..%s\n' "$t1" "$t2" >>"$rec"
      mv "$rec" "/b/receipt/$gen"
      echo "receipt $tag roles=5 sha=$(python3 /opt/o25/o25.py sha <"/b/receipt/$gen")"
    else
      rm -f "$rec"
      echo "plant-failed $tag: 없는 역할:${missing:- 없음}, 첩자 표시 ${t1:-없음}→${t2:-없음}"
      exit 1
    fi
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
