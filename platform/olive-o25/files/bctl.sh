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
    echo "== 이 세대의 심기 영수증(/b/receipt/$GEN)"
    if [ -s "/b/receipt/$GEN" ]; then
      sed 's/^/  /' "/b/receipt/$GEN" | clean
      echo "  sha=$(python3 "$PY" sha <"/b/receipt/$GEN")"
    else
      echo "  없음"
    fi
    echo "== cgroup 상한(본체 컨테이너). 차트는 컨테이너별 pid 상한을 주지 못한다"
    for t in memory.max pids.max pids.current; do printf '  %s: %s\n' "$t" "$(clean </sys/fs/cgroup/$t 2>&1)"; done
    ;;
  hide)
    bash /opt/o25/probe.sh body 2>&1 | clean
    ;;
  after-restart)
    # 이번 재시작으로 끝났어야 할 세대 = 본체 컨테이너가 뜬 세대 차례(/b/boots)에서 지금 세대 바로 앞의 다른 세대.
    # 그 세대의 심기 영수증에 적힌 대상만 본다. 앞 회차의 기록은 이번 회차의 증거로 쓰지 않는다.
    # 파드 안에서는 옛 본체가 언제 끝났는지 알 수 없다. 첩자 표시는 "늦게까지 살아 있었다"를 잡는 보조 증거일 뿐이고,
    # 순서(옛 본체 소멸 → 새 init → 새 자격)의 최종 판정은 노드 줄(node-cgroup.sh judge)이다.
    prev=$(awk -v g="$GEN" '$1 != g { p = $1 } END { print p }' /b/boots 2>/dev/null)
    rc_file=/b/receipt/$prev
    echo "== 세대 $GEN (init_ns $GEN_INIT_NS), 본체 PID 1 시작 $(state pid1_started_ns), 바로 앞 본체 세대 ${prev:-없음}"
    keys="3.body.옛-본체-후손-0 3.보조.옛-첩자-새-init-뒤-표시-없음 4.보조.첩자-포착-없음"
    if [ -z "$prev" ] || [ ! -s "$rc_file" ]; then
      for k in $keys; do verdict "$k" "판단 필요" "바로 앞 세대(${prev:-없음})의 심기 영수증이 없다. 이번 회차의 관측 대상이 없다"; done
      exit 0
    fi
    echo "== 영수증 $rc_file (sha $(python3 "$PY" sha <"$rc_file"))"
    sed 's/^/  /' "$rc_file" | clean
    n_target=0 n_alive=0
    while read -r r p s; do
      p=${p#pid=} s=${s#start=}
      n_target=$((n_target + 1))
      now=""
      if { read -r stat <"/proc/$p/stat"; } 2>/dev/null; then
        read -ra f <<<"${stat##*) }"
        [ "${f[0]}" != Z ] && now=${f[19]}
      fi
      if [ "$now" = "$s" ]; then
        n_alive=$((n_alive + 1))
        echo "  살아 있음: $r pid $p 상태 ${f[0]}"
      fi
    done < <(grep '^role=' "$rc_file")
    tagged=$(planted_alive | awk -v t="p-$prev-" 'index($2, t) == 1')
    hb=/b/spy/p-$prev-spy.hb
    last=$(sed -n 's/.*now_ns=\([0-9]*\).*/\1/p' "$hb" 2>/dev/null)
    sleep 2
    last2=$(sed -n 's/.*now_ns=\([0-9]*\).*/\1/p' "$hb" 2>/dev/null)
    echo "  첩자 표시: 마지막 ${last:-없음}, 2초 뒤 ${last2:-없음}, 새 세대 init 시각 $GEN_INIT_NS"
    echo "== 꼬리표 p-$prev- 로 살아 있는 것: ${tagged:-없음}"
    if [ "$n_target" -ne 5 ] || [ -z "$last" ]; then
      verdict "3.body.옛-본체-후손-0" "판단 필요" "영수증 대상 ${n_target}개, 첩자 표시 ${last:-없음}"
    elif [ "$n_alive" -eq 0 ] && [ -z "$tagged" ] && [ "$last" = "$last2" ]; then
      verdict "3.body.옛-본체-후손-0" "됨" "영수증의 다섯 대상(pid·시작 시각)이 이 컨테이너에 없고 첩자 표시가 멈췄다(지금 시점의 사실. 언제 끝났는지는 노드 판정)"
    else
      verdict "3.body.옛-본체-후손-0" "안 됨" "영수증 대상 중 살아 있음 ${n_alive}개, 꼬리표로 찾은 것: ${tagged:-없음}, 첩자 표시 ${last}→${last2}"
    fi
    if [ -n "$last" ] && [ "$last" -ge "$GEN_INIT_NS" ]; then
      verdict "3.보조.옛-첩자-새-init-뒤-표시-없음" "안 됨" "옛 첩자가 새 세대 init 뒤에도 표시를 썼다(늦게까지 살아 있었다)"
    elif [ -n "$last" ]; then
      verdict "3.보조.옛-첩자-새-init-뒤-표시-없음" "됨" "마지막 표시가 새 init보다 $(((GEN_INIT_NS - last) / 1000000))ms 앞이다. 그 뒤 언제 끝났는지는 모른다(보조 증거. 순서 판정이 아니다)"
    else
      verdict "3.보조.옛-첩자-새-init-뒤-표시-없음" "판단 필요" "첩자 표시가 없다"
    fi
    caught=$(cat /b/spy/*.caught 2>/dev/null | clean)
    tries=$(cat /b/spy/*.caught.tries 2>/dev/null | wc -l)
    if [ -n "$caught" ]; then
      verdict "4.보조.첩자-포착-없음" "안 됨" "첩자가 다른 세대의 소켓·환경에서 받은 것: $(printf '%s' "$caught" | head -n 3 | tr '\n' ' ')"
    else
      verdict "4.보조.첩자-포착-없음" "됨" "첩자가 기록한 포착 0건(시도 기록 ${tries}줄). 받고 기록 전에 끝난 경우를 배제하지 못한다(보조 증거)"
    fi
    fact "순서의 최종 판정은 노드 줄 3.node.옛-본체-소멸이-새-init-앞, 4.node.옛-본체-소멸이-새-자격-앞이다"
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
    # 값은 검사기의 표준 입력으로만 넘긴다(인자로 주면 검사 프로세스의 argv가 노출 경로가 된다).
    scan=$(printf '%s' "$got" | python3 "$PY" scan /b /relay 2>&1)
    rc=$?
    printf '%s\n' "$scan" | clean | head -n 30 | sed 's/^/  /'
    sum=$(printf '%s\n' "$scan" | sed -n 's/^summary files=[0-9]* procs=\([0-9]*\) gone=[0-9]* unreadable=\([0-9]*\) self=[0-9]*$/\1 \2/p')
    # 본체 자리 프로그램과 그 자손의 환경에 있는 것은 예상이다(자격을 그 환경으로 준다). PID 1·argv·파일은 안 된다.
    bad=$(printf '%s\n' "$scan" | grep -E '^(file |argv |environ [0-9]+ executor$)' | tr '\n' ' ')
    if [ "$rc" -ne 0 ] || [ -z "$sum" ]; then
      verdict "6.본체-쪽-파일-argv-없음" "판단 필요" "검사기가 끝까지 돌지 않았다(exit $rc)"
    elif [ -n "$bad" ]; then
      verdict "6.본체-쪽-파일-argv-없음" "안 됨" "값이 있는 곳: $bad"
    elif [ "${sum#* }" != 0 ]; then
      verdict "6.본체-쪽-파일-argv-없음" "판단 필요" "읽지 못한 파일·프로세스 ${sum#* }개"
    else
      verdict "6.본체-쪽-파일-argv-없음" "됨" "PID 1의 argv·환경, 모든 프로세스의 argv, /b·/relay 파일에 값이 없다(본체 자리 프로그램과 자손의 환경에만: $(printf '%s\n' "$scan" | grep -c '^environ ')곳)"
    fi
    ;;
  *)
    echo "bctl.sh: status | hide | after-restart | cred" >&2
    exit 2
    ;;
esac
