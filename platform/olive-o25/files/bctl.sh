#!/bin/bash
# 본체 컨테이너(uid 10002)에서 보는 단계. 쓰는 법: bctl.sh status | hide | after-restart | after-body-term | shm | cred
# status·hide·after-restart·after-body-term·shm은 관리자가 kubectl exec -c body로 부른다(tools/olive-o25/run.sh body <단계>).
# cred는 본체 PID 1의 자식(o25.py body-job body-cred)이 부른다. exec로 들어온 셸에서 부르면 그 셸 자신이 검사 대상으로 남고,
# 이 노드에서는 원래 계통이 exec 계통의 환경을 읽지 못해 판단 필요가 된다.
# 본체 컨테이너 안을 읽기만 한다(shm은 고정 글 한 파일을 쓴다). 자격 값은 찍지 않고 sha 앞 16자만 찍는다.
# exec로 들어온 셸은 본체 PID 1의 자손이 아니지만, 같은 uid·같은 PID 네임스페이스·같은 cgroup이다. AppArmor 라벨은 다르다(…//&unconfined).
PY=/opt/o25/o25.py
clean() { LC_ALL=C tr '\000-\010\013-\037\177' '?'; }
verdict() { printf '결과 %s %s — %s\n' "$1" "$2" "$3"; }
# verdict_c: 요청 통로로 로그에 나가는 판정(코드는 o25.py CODES 안의 것만).
verdict_c() { printf '결과 %s %s — %s (이유 %s)\n' "$1" "$2" "$4" "$3"; }
fact() { printf '사실 %s\n' "$*"; }
# pstart <pid>: /proc/<pid>/stat의 시작 시각(tick). 못 읽거나 좀비면 빈 값.
pstart() {
  local stat f
  { read -r stat <"/proc/$1/stat"; } 2>/dev/null || return 0
  read -ra f <<<"${stat##*) }"
  [ "${f[0]:-Z}" = Z ] || printf '%s' "${f[19]}"
}
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
    fact "AppArmor 라벨(본체 exec 계통, 이 셸) $(clean 2>&1 </proc/self/attr/current) / 본체 PID 1 $(clean 2>&1 </proc/1/attr/current)"
    echo "== 본체 PID 1 상태(/b/state)"
    clean </b/state 2>&1
    echo "== 본체 컨테이너가 뜬 세대 차례(/b/boots, 끝 5줄. 같은 세대가 두 번이면 본체만 다시 뜬 것)"
    tail -n 5 /b/boots 2>&1 | clean | sed 's/^/  /'
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
  after-body-term)
    # 본체만 다시 뜬 뒤(같은 세대): 새 본체 PID 1이 자격 없이 기다리는가. 본체가 쓰는 /b/state·/b/boots를 읽으므로 보조 증거다.
    # 주된 증거는 제어 쪽 장부(step body-after의 4.body-only.추가-제공-전달-0)와 API(run.sh body-only-check)다.
    k=4.body-only.무자격-대기
    n_boot=$(awk -v g="$GEN" '$1 == g' /b/boots 2>/dev/null | wc -l)
    last=$(tail -n 1 /b/boots 2>/dev/null | cut -d' ' -f1)
    ph=$(state phase) cr=$(state cred) pg=$(state program) sg=$(state gen)
    echo "== 세대 $GEN: 본체가 이 세대로 뜬 횟수 $n_boot, 마지막 부팅 세대 ${last:-없음}"
    echo "  phase=$ph cred=$cr program=$pg gen=$sg relay=$(state relay)" | clean
    if [ "$cr" != none ] || [ "$pg" != none ]; then
      verdict "$k" "안 됨" "다시 뜬 본체가 자격이나 프로그램을 가졌다(cred=$cr program=$pg)"
    elif [ "$n_boot" -ge 2 ] && [ "$last" = "$GEN" ] && [ "$sg" = "$GEN" ] && [ "$ph" = wait-cred ]; then
      verdict "$k" "됨" "같은 세대 $GEN로 ${n_boot}번째 뜬 본체 PID 1이 자격 없이 기다린다(phase=wait-cred, cred=none, program=none. 본체 쪽 기록, 보조 증거)"
    else
      verdict "$k" "판단 필요" "본체만 다시 뜬 모양이 아니다(같은 세대 부팅 ${n_boot}회, phase=$ph)"
    fi
    ;;
  shm)
    # 두 컨테이너가 같은 /dev/shm을 보는가(티켓 할 일 8). 비밀이 아닌 고정 글만 쓴다. 판정이 아니라 사실이다.
    mine=/dev/shm/o25-shm-body-$GEN peer=/dev/shm/o25-shm-control-$GEN
    if [ -e "$mine" ]; then w=이미-있음; elif { printf 'o25 shm body gen=%s\n' "$GEN" >"$mine"; } 2>/dev/null; then w=ok; else w=실패; fi
    if [ -e "$peer" ]; then
      if [ "$(head -c 64 "$peer" 2>/dev/null)" = "o25 shm control gen=$GEN" ]; then seen=보임-내용-일치; else seen=보임-내용-다름; fi
    else
      seen=안-보임
    fi
    echo "== /dev/shm 마운트(mountinfo의 형식·옵션)와 폴더"
    awk '$5 == "/dev/shm" { print "  " $9, $6, $10, $11 }' /proc/self/mountinfo | clean
    stat -c '%A %u:%g %n' /dev/shm /dev/shm/* 2>&1 | head -n 8 | clean | sed 's/^/  /'
    fact "shm 본체-쓰기=$w 제어-파일=$seen"
    ;;
  cred)
    k1=6.본체-프로세스에-있음 k2=6.본체-쪽-파일-argv-없음
    # /b/state는 본체가 쓸 수 있다. 정해진 모양이 아니면 값을 쓰지도 찍지도 않는다(줄 구분 문자로 가짜 줄을 숨길 수 있다).
    prog=$(state program | sed -n 's/^pid=//p')
    want=$(state cred)
    [[ $prog =~ ^[0-9]{1,10}$ ]] || prog=""
    [[ $want =~ ^sha=[0-9a-f]{16}$ ]] || want="bad-form"
    echo "본체 PID 1이 받은 자격: $want, 본체 자리 프로그램 pid ${prog:-?}"
    case "$want" in sha=*) fact "body-sha ${want#sha=}" ;; esac
    fact "AppArmor 라벨(이 검사 셸) $(clean 2>&1 </proc/self/attr/current)"
    s0=$([ -n "$prog" ] && pstart "$prog")
    if [ -z "$s0" ]; then
      verdict_c "$k1" "판단 필요" program-unknown "본체 자리 프로그램을 찾지 못했다"
      verdict_c "$k2" "판단 필요" not-checked "본체 자리 프로그램이 없어 검사하지 않았다"
      exit 0
    fi
    # 환경을 여는 데 실패한 것(권한·라벨)과 값이 없거나 다른 것을 나눈다. 여는 데 실패하면 판단 필요다.
    # 리다이렉션이 실패하면 tr은 돌지 않고 치환의 종료 상태가 0이 아니다.
    if ! envtxt=$(tr '\0' '\n' 2>/dev/null <"/proc/$prog/environ"); then
      verdict_c "$k1" "판단 필요" env-open-failed "본체 자리 프로그램(pid $prog)의 환경을 열지 못했다"
      verdict_c "$k2" "판단 필요" not-checked "값을 얻지 못해 검사하지 않았다"
      exit 0
    fi
    got=$(printf '%s\n' "$envtxt" | sed -n 's/^O25_FAKE_CRED=//p' | head -n 1)
    unset envtxt
    if [ -z "$got" ]; then
      v1=("안 됨" absent "본체 자리 프로그램 환경을 읽었는데 자격이 없다")
    elif [ "sha=$(printf '%s' "$got" | python3 -I "$PY" sha)" != "$want" ]; then
      v1=("안 됨" sha-mismatch "본체 자리 프로그램 환경의 자격 sha가 PID 1이 받은 것($want)과 다르다")
    else
      v1=("됨" present "본체 자리 프로그램 환경에 자격이 있고 sha가 PID 1이 받은 것과 같다($want). 제어 쪽 장부의 cred-sha와 대조한다")
    fi
    if [ -z "$got" ]; then
      verdict_c "$k1" "${v1[0]}" "${v1[1]}" "${v1[2]}"
      verdict_c "$k2" "판단 필요" not-checked "값을 얻지 못해 검사하지 않았다"
      exit 0
    fi
    # 값은 검사기의 표준 입력으로만 넘긴다(인자로 주면 검사 프로세스의 argv가 노출 경로가 된다).
    scan=$(printf '%s' "$got" | python3 -I "$PY" scan /b /relay 2>&1)
    rc=$?
    unset got
    printf '%s\n' "$scan" | grep -v '^summary ' | clean | head -n 30 | sed 's/^/  /'
    printf '%s\n' "$scan" | grep '^summary ' | clean | sed 's/^/  /'
    sum=$(printf '%s\n' "$scan" | sed -n 's/^summary files=[0-9]* procs=\([0-9]*\) gone=[0-9]* unreadable=\([0-9]*\) self=[0-9]*$/\1 \2/p')
    # 본체 자리 프로그램과 그 자손의 환경에 있는 것은 예상이다(자격을 그 환경으로 준다). PID 1·argv·파일은 안 된다.
    bad=$(printf '%s\n' "$scan" | grep -E '^(file |argv |environ [0-9]+ executor$)' | tr '\n' ' ')
    if [ "$(pstart "$prog")" != "$s0" ]; then
      verdict_c "$k1" "판단 필요" program-changed "검사 사이에 본체 자리 프로그램(pid $prog)이 바뀌었거나 끝났다"
      verdict_c "$k2" "판단 필요" program-changed "검사 사이에 본체 자리 프로그램이 바뀌었거나 끝났다"
      exit 0
    fi
    verdict_c "$k1" "${v1[0]}" "${v1[1]}" "${v1[2]}"
    if [ "$rc" -ne 0 ] || [ -z "$sum" ]; then
      verdict_c "$k2" "판단 필요" scan-failed "검사기가 끝까지 돌지 않았다(exit $rc)"
    elif [ -n "$bad" ]; then
      verdict_c "$k2" "안 됨" hit "값이 있는 곳: $bad"
    elif [ "${sum#* }" != 0 ]; then
      verdict_c "$k2" "판단 필요" unreadable "읽지 못한 파일·프로세스 ${sum#* }개"
    else
      verdict_c "$k2" "됨" clean "PID 1의 argv·환경, 모든 프로세스의 argv, /b·/relay 파일에 값이 없다(본체 자리 프로그램과 자손의 환경에만: $(printf '%s\n' "$scan" | grep -c '^environ ')곳)"
    fi
    ;;
  *)
    echo "bctl.sh: status | hide | after-restart | after-body-term | shm | cred" >&2
    exit 2
    ;;
esac
