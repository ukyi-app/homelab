#!/bin/bash
# 본체 컨테이너(uid 10002)에서 보는 단계. 관리자가 kubectl exec -c body로 부른다(tools/olive-o25/run.sh body <단계>).
# 쓰는 법: bctl.sh status | hide | after-restart | cred
# 본체 컨테이너 안을 읽기만 한다. 자격 값은 찍지 않고 sha 앞 16자만 찍는다.
# 이 셸은 본체 PID 1의 자손이 아니라 exec로 들어온 프로세스지만, 같은 uid·같은 PID 네임스페이스·같은 cgroup이다.
PY=/opt/o25/o25.py
clean() { LC_ALL=C tr '\000-\010\013-\037\177' '?'; }
verdict() { printf '결과 %s %s — %s\n' "$1" "$2" "$3"; }
fact() { printf '사실 %s\n' "$*"; }
read -r GEN GEN_INIT_NS </relay/current 2>/dev/null
state() { sed -n "s/^$1=//p" /b/state 2>/dev/null | head -n 1; }

# 본체 컨테이너의 프로세스 표(PID PPID SID UID 명령줄).
ps_body() {
  local d stat rest st ppid sid uid
  for d in /proc/[0-9]*; do
    { read -r stat <"$d/stat"; } 2>/dev/null || continue
    rest=${stat##*) }
    read -r st ppid _ sid _ <<<"$rest"
    [ "$st" = Z ] && continue
    uid=$(awk '/^Uid:/ {print $2; exit}' 2>/dev/null <"$d/status")
    printf '%-6s %-6s %-6s %-6s %s\n' "${d#/proc/}" "$ppid" "$sid" "$uid" "$(tr '\0' ' ' 2>/dev/null <"$d/cmdline" | cut -c1-100 | clean)"
  done
}
# planted_alive: 심은 프로세스(plant.sh sleeper·stubborn, o25.py spy)의 "pid 꼬리표" 목록.
planted_alive() {
  local d c
  for d in /proc/[0-9]*; do
    c=$(tr '\0' ' ' 2>/dev/null <"$d/cmdline")
    # argv 끝의 NUL이 공백이 되어 남는다. 지우지 않으면 마지막 낱말(꼬리표)이 빈 값으로 잘린다.
    c=${c% }
    case "$c" in
      "bash /opt/o25/plant.sh sleeper "* | "bash /opt/o25/plant.sh stubborn "* | "python3 /opt/o25/o25.py spy "*)
        printf '%s %s\n' "${d#/proc/}" "${c##* }"
        ;;
    esac
  done
}

cmd=${1:-status}
case "$cmd" in
  status)
    echo "== 세대 $GEN (init_ns $GEN_INIT_NS)"
    echo "== 본체 PID 1 상태(/b/state)"
    clean </b/state 2>&1
    echo "== 프로세스(PID PPID SID UID CMD)"
    ps_body
    echo "== 심은 것"
    planted_alive | sed 's/^/  /'
    echo "== 첩자 기록"
    for f in /b/spy/*.hb; do [ -e "$f" ] && printf '  %s: %s\n' "${f##*/}" "$(clean <"$f")"; done
    for f in /b/spy/*.caught; do [ -e "$f" ] && printf '  %s: %s줄\n' "${f##*/}" "$(wc -l <"$f")"; done
    ;;
  hide)
    bash /opt/o25/probe.sh body 2>&1 | clean
    ;;
  after-restart)
    echo "== 세대 $GEN (init_ns $GEN_INIT_NS), 본체 PID 1 시작 $(state pid1_started_ns)"
    alive=$(planted_alive)
    old_alive=$(printf '%s\n' "$alive" | awk -v g="$GEN" 'NF && $2 !~ ("^p-" g "-") { print }')
    n_hb_old=0 n_hb_late=0 n_hb_moving=0
    for f in /b/spy/*.hb; do
      [ -e "$f" ] || continue
      born=$(sed -n 's/.*born=\([0-9a-f]*\).*/\1/p' "$f")
      [ "$born" = "$GEN" ] && continue
      n_hb_old=$((n_hb_old + 1))
      last=$(sed -n 's/.*now_ns=\([0-9]*\).*/\1/p' "$f")
      echo "  첩자 ${f##*/}: 태어난 세대 $born, 마지막 표시 $last, 새 세대 init보다 $(((GEN_INIT_NS - last) / 1000000))ms 앞"
      [ "$last" -ge "$GEN_INIT_NS" ] && n_hb_late=$((n_hb_late + 1))
      before=$last
      sleep 2
      [ "$(sed -n 's/.*now_ns=\([0-9]*\).*/\1/p' "$f")" != "$before" ] && n_hb_moving=$((n_hb_moving + 1))
    done
    echo "== 옛 세대의 심은 것 중 살아 있는 것: ${old_alive:-없음}"
    if [ "$n_hb_old" -eq 0 ]; then
      verdict "3.옛-본체-후손-0" "판단 필요" "옛 세대에 심은 첩자의 기록이 없다(plant를 먼저 돌렸는가)"
    elif [ -z "$old_alive" ] && [ "$n_hb_moving" -eq 0 ]; then
      verdict "3.옛-본체-후손-0" "됨" "옛 세대에 심은 분리 후손·TERM 무시·첩자가 하나도 없고, 첩자 표시 ${n_hb_old}개가 멈췄다"
    else
      verdict "3.옛-본체-후손-0" "안 됨" "살아 있음: ${old_alive:-없음}, 아직 움직이는 첩자 표시 ${n_hb_moving}개"
    fi
    if [ "$n_hb_old" -gt 0 ] && [ "$n_hb_late" -eq 0 ]; then
      verdict "3.옛-본체가-새-init-전에-끝남" "됨" "옛 첩자의 마지막 표시가 모두 새 세대 init 시각보다 앞이다(0.2초 간격으로 쓰던 것)"
    elif [ "$n_hb_old" -gt 0 ]; then
      verdict "3.옛-본체가-새-init-전에-끝남" "안 됨" "새 세대 init 뒤에도 표시를 쓴 첩자 ${n_hb_late}개"
    else
      verdict "3.옛-본체가-새-init-전에-끝남" "판단 필요" "옛 첩자 기록이 없다"
    fi
    caught=$(cat /b/spy/*.caught 2>/dev/null | clean)
    tries=$(cat /b/spy/*.caught.tries 2>/dev/null | wc -l)
    if [ -n "$caught" ]; then
      verdict "4.옛-본체가-새-자격을-못-봄" "안 됨" "첩자가 다른 세대의 소켓·환경에서 받은 것: $(printf '%s' "$caught" | head -n 3 | tr '\n' ' ')"
    elif [ "$n_hb_old" -gt 0 ]; then
      verdict "4.옛-본체가-새-자격을-못-봄" "됨" "첩자가 다른 세대에서 받은 것 0건(시도 기록 ${tries}줄)"
    else
      verdict "4.옛-본체가-새-자격을-못-봄" "판단 필요" "첩자 기록이 없다"
    fi
    echo "== 옛 세대 본체 폴더(남는 것이 예상이다)"
    for d in /b/*/; do
      d=${d%/}
      case "${d##*/}" in spy) continue ;; esac
      printf '  %s 파일 %s개%s\n' "$d" "$(find "$d" -xdev -type f 2>/dev/null | wc -l)" "$([ "${d##*/}" = "$GEN" ] && echo ' (지금 세대)')"
    done
    fact "본체 HOME은 $(state program) 의 환경 HOME=/b/$GEN/home (세대마다 새 경로)"
    ;;
  cred)
    prog=$(state program | sed -n 's/^pid=//p')
    want=$(state cred)
    echo "본체 PID 1이 받은 자격: $want, 본체 자리 프로그램 pid ${prog:-?}"
    if [ -z "$prog" ] || [ ! -r "/proc/$prog/environ" ]; then
      verdict "6.본체-프로세스에-있음" "판단 필요" "본체 자리 프로그램을 찾지 못했다"
      exit 0
    fi
    got=$(tr '\0' '\n' <"/proc/$prog/environ" | sed -n 's/^O25_FAKE_CRED=//p' | head -n 1)
    if [ -n "$got" ] && [ "sha=$(printf '%s' "$got" | python3 "$PY" sha)" = "$want" ]; then
      verdict "6.본체-프로세스에-있음" "됨" "본체 자리 프로그램 환경에 자격이 있고 sha가 PID 1이 받은 것과 같다($want). 제어 쪽 장부의 sha와 대조한다"
    else
      verdict "6.본체-프로세스에-있음" "안 됨" "본체 자리 프로그램 환경에 자격이 없거나 sha가 다르다"
      exit 0
    fi
    in_pid1=no
    { tr '\0' '\n' </proc/1/environ | grep -qF -- "$got"; } 2>/dev/null && in_pid1=yes
    { tr '\0' '\n' </proc/1/cmdline | grep -qF -- "$got"; } 2>/dev/null && in_pid1=yes
    files=$(find /b /relay -xdev -type f -exec grep -lF -- "$got" {} + 2>/dev/null | clean)
    if [ "$in_pid1" = no ] && [ -z "$files" ]; then
      verdict "6.본체-쪽-파일-argv-없음" "됨" "PID 1의 argv·환경과 /b·/relay 파일에 값이 없다(본체 자리 프로그램의 환경에만)"
    else
      verdict "6.본체-쪽-파일-argv-없음" "안 됨" "PID 1=$in_pid1, 파일: ${files:-없음}"
    fi
    ;;
  *)
    echo "bctl.sh: status | hide | after-restart | cred" >&2
    exit 2
    ;;
esac
