#!/bin/bash
# 가림 탐침. 쓰는 법: probe.sh <body|control>
#   body     본체 컨테이너(uid 10002)에서. 제어 쪽 hc·허가·프로세스에 닿는지 본다. 판정의 대상이다.
#   control  제어 컨테이너(uid 10001)에서 같은 것을 본다. 대조군: 검사가 닿는 것을 잡을 수 있다는 증거다.
# 경로를 찾지 못해 "안 닿음"이 되지 않게, 정확한 경로를 세대 ID(/relay/current)에서 만들고 이름 목록(/proc/net/unix)에서 읽어 직접 connect한다.
# "됨"은 가려졌다(본체에서 닿지 않았다)는 뜻이다. 대조군의 줄은 "사실"로만 낸다.
# 도우미의 종료 코드와 첫 줄을 함께 본다. 기대한 errno(차단)일 때만 no, 성공이 확인되면 yes, 그 밖(exit 127·137, 빈 출력,
# traceback, 시간 초과)은 unknown이다. 검사를 못 한 것을 가려졌다로 읽지 않는다.
# 제어 쪽 파일을 쓰거나 지우지 않는다. 중계 폴더에 쓰기·바꿔치기 시도는 본체 역할에서만 한다(제어 역할이면 진짜 소켓을 건드린다).
role=${1:-}
case "$role" in body | control) ;; *)
  echo "probe.sh: body 또는 control" >&2
  exit 2
  ;;
esac
PY=/opt/o25/o25.py
clean() { LC_ALL=C tr '\000-\010\013-\037\177' '?'; }
# one <이름> [인자...]: "<종료 코드> <첫 줄>"을 낸다.
one() {
  local out rc
  # -I: 본체가 쓸 수 있는 사용자 site(.pth)·현재 폴더·PYTHON* 환경에서 코드를 읽지 않는다.
  out=$(python3 -I "$PY" "$@" 2>&1 </dev/null)
  rc=$?
  printf '%s %s' "$rc" "$(printf '%s\n' "$out" | head -n 1 | clean)"
}
# reach <one의 결과> <차단으로 읽을 errno...>: yes|no|unknown
reach() {
  local r=$1 e
  shift
  case "$r" in
    "0 connected" | "0 ok") echo yes && return ;;
  esac
  for e in "$@"; do
    case "$r" in
      "1 refused $e" | "1 $e") echo no && return ;;
    esac
  done
  echo unknown
}
# 차단으로 세는 errno는 경로가 없음·읽기 전용·듣는 쪽 없음뿐이다. EACCES·EPERM은 세지 않는다(판단 필요): 이 노드에서 exec로
# 들어온 탐침은 AppArmor 라벨이 겹쳐져(…//&unconfined) 원래 본체라면 닿았을 곳에서도 거부될 수 있다. 그 거부를 "가려졌다"로 읽지 않는다.
# 본체 PID 1 계통(o25.py body-job body-hide)에서 돈 탐침도 같은 목록을 쓴다.
SOCK_BLOCKED=(ENOENT ECONNREFUSED)
FS_BLOCKED=(EROFS)
# judge <키> <닿음 여부 yes|no|unknown> <근거>
judge() {
  local k="5.$role.$1"
  if [ "$role" = control ]; then
    printf '사실 %s 대조군 닿음=%s — %s\n' "$k" "$2" "$3"
    return
  fi
  case "$2" in
    no) printf '결과 %s 됨 — %s\n' "$k" "$3" ;;
    yes) printf '결과 %s 안 됨 — %s\n' "$k" "$3" ;;
    *) printf '결과 %s 판단 필요 — %s\n' "$k" "$3" ;;
  esac
}

read -r gen _ </relay/current 2>/dev/null
G=/c/g/$gen
printf '탐침 역할=%s uid=%s groups=%s 세대=%s\n' "$role" "$(id -u)" "$(id -G)" "${gen:-?}"
printf '사실 AppArmor 라벨(이 탐침) %s\n' "$(clean 2>&1 </proc/self/attr/current)"
if [ -z "$gen" ]; then
  echo "세대를 읽지 못했다(/relay/current)"
  exit 1
fi

echo "== 1. hc 소켓에 직접 connect: 정확한 경로(세대에서 만든 client 경로 + /proc/net/unix에 보이는 hc 이름)"
names=$(awk 'NR > 1 && NF >= 8 && $8 ~ /herdr-core\/.*\.sock$/ { print $8 }' /proc/net/unix 2>/dev/null | sort -u)
n_names=$(printf '%s' "$names" | grep -c .)
echo "netns에 보이는 hc 소켓 이름 ${n_names}개(같은 파드는 netns를 나눠 써서 이름이 보인다. 0개면 core가 떠 있지 않다)"
reached=0 tried=0 unk=0
for p in "$G/rt/herdr-core/o25.sock" $names; do
  r=$(one connect "$p")
  tried=$((tried + 1))
  printf '  %s -> %s\n' "$p" "$r"
  case "$(reach "$r" "${SOCK_BLOCKED[@]}")" in
    yes) reached=$((reached + 1)) ;;
    unknown) unk=$((unk + 1)) ;;
  esac
done
if [ "$reached" -gt 0 ]; then
  judge hc-socket yes "hc 소켓 $tried곳 중 $reached곳에 연결됐다"
elif [ "$unk" -gt 0 ]; then
  judge hc-socket unknown "$tried곳 중 ${unk}곳은 검사 결과가 차단 오류가 아니다(도우미 실패·시간 초과)"
elif [ "$n_names" -gt 0 ]; then
  judge hc-socket no "이름이 보이는 hc 소켓 ${n_names}개를 포함해 $tried곳 모두 차단 오류로 연결이 안 됐다"
else
  judge hc-socket unknown "netns에 hc 소켓 이름이 없다(core가 떠 있었다는 증거가 없다)"
fi

echo "== 2. hc ls(제어 쪽과 같은 XDG 경로를 준다)"
# busybox timeout은 감시 프로세스를 남기고, 그 프로세스의 환경은 같은 uid에서도 읽히지 않아(EACCES) 뒤의 자격 검사가
# 판단 필요가 된다. 셸에서 직접 10초 상한을 건다(넘으면 KILL, 종료 코드 137).
out=$(
  XDG_STATE_HOME=$G/st XDG_CONFIG_HOME=$G/cf XDG_RUNTIME_DIR=$G/rt HC_SESSION=o25 HOME=$G/h /opt/hc/hc ls 2>&1 </dev/null &
  p=$!
  for _ in $(seq 50); do
    kill -0 "$p" 2>/dev/null || break
    sleep 0.2
  done
  kill -KILL "$p" 2>/dev/null
  wait "$p"
)
rc=$?
out=$(printf '%s\n' "$out" | clean | head -n 8)
printf '%s\n' "$out" | sed 's/^/  /'
echo "  -> exit $rc"
if printf '%s' "$out" | grep -qw body; then
  judge hc-ls yes "제어 쪽 터미널 body가 목록에 보였다"
elif [ "$n_names" -gt 0 ] && [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'Read-only file system'; then
  judge hc-ls no "core가 떠 있는데(이름 ${n_names}개) hc ls가 쓰기 차단 오류로 끝났다(exit $rc)"
else
  judge hc-ls unknown "hc ls가 기대한 차단 오류로 끝나지 않았다(exit $rc, 위 출력)"
fi

echo "== 3. hc 상태 읽기·설정 쓰기, 세대 허가 폴더"
st=$(cat "$G/st/herdr-core/o25/terminals.json" 2>&1 | head -c 200 | clean)
printf '  상태 읽기: %s\n' "$(printf '%s' "$st" | head -n 1)"
w=$(one tryop create "$G/cf/herdr-core/o25-probe-$role")
printf '  설정 쓰기: %s\n' "$w"
b=$(find /c/boot -maxdepth 1 2>&1 | head -n 3 | tr '\n' ' ' | clean)
printf '  허가 폴더(/c/boot): %s\n' "$b"
if [ "$role" = body ]; then
  if [ -d /c ]; then
    judge state yes "/c가 본체에 보인다"
  elif [ "$n_names" -gt 0 ] && [ "$(reach "$w" ENOENT)" = no ]; then
    judge state no "/c가 본체 파일 시스템에 없다(설정 쓰기 ENOENT, 상태 읽기·허가 폴더는 위 결과)"
  else
    judge state unknown "core가 떠 있었다는 증거가 없거나 설정 쓰기 결과가 ENOENT가 아니다($w)"
  fi
else
  judge state "$([ -r "$G/st/herdr-core/o25/terminals.json" ] && echo yes || echo no)" "제어 쪽에서 상태 파일을 읽었는가"
fi

echo "== 4. /proc: uid 10001(제어 쪽) 프로세스, 그 환경·별칭, 신호"
ctl_pids="" n_stat=0
for d in /proc/[0-9]*; do
  u=$(awk '/^Uid:/ {print $2; exit}' 2>/dev/null <"$d/status")
  [ -n "$u" ] && n_stat=$((n_stat + 1))
  [ "$u" = 10001 ] && ctl_pids="$ctl_pids ${d#/proc/}"
done
echo "  보이는 uid 10001 프로세스:${ctl_pids:- 없음} (status를 읽은 프로세스 ${n_stat}개)"
env_hit=0 sig_hit=0
for p in $ctl_pids; do
  [ "$p" = "$$" ] && continue
  { tr '\0' '\n' <"/proc/$p/environ" | grep -q '^XDG_RUNTIME_DIR='; } 2>/dev/null && env_hit=$((env_hit + 1))
  kill -0 "$p" 2>/dev/null && sig_hit=$((sig_hit + 1))
done
if [ "$role" = body ]; then
  if [ -n "$ctl_pids" ]; then
    judge proc yes "uid 10001 프로세스가 보인다(환경 읽힘 $env_hit, 신호 가능 $sig_hit)"
  elif [ "$n_stat" -gt 1 ] && [ -r /proc/1/status ] && [ "$(awk '/^Uid:/ {print $2; exit}' /proc/1/status)" = 10002 ]; then
    judge proc no "보이는 프로세스 ${n_stat}개는 본체 uid뿐이고 PID 1도 본체 쪽이다(PID 네임스페이스를 나누지 않았다)"
  else
    judge proc unknown "PID 1이나 프로세스 status를 읽지 못했다"
  fi
else
  judge proc "$([ "$env_hit" -gt 0 ] && echo yes || echo no)" "제어 쪽 프로세스 환경을 읽음 $env_hit, 신호 가능 $sig_hit"
fi
fact_proc_root=$(readlink /proc/1/root 2>&1 | clean)
echo "  /proc/1/root -> $fact_proc_root, /proc/1/cmdline: $(tr '\0' ' ' 2>/dev/null </proc/1/cmdline | cut -c1-80 | clean)"

echo "== 5. 공유 netns: abstract 소켓과 TCP 듣는 곳(파드의 컨테이너가 함께 본다). 모두 본다(개수를 자르지 않는다)"
# 목록을 못 만든 것(awk·sort 실패, 읽기 오류)과 정상적으로 읽은 빈 목록은 둘 다 빈 문자열이다. 종료 상태로 가른다.
abs=$(
  set -o pipefail
  awk 'NR > 1 && NF >= 8 && $8 ~ /^@/ { print $8 }' /proc/net/unix 2>/dev/null | sort -u
)
abs_rc=$?
n_open=0 n_unk=0
if [ "$abs_rc" -ne 0 ]; then
  n_unk=$((n_unk + 1))
  echo "  abstract 소켓 목록을 만들지 못했다(exit $abs_rc)"
fi
for a in $abs; do
  r=$(one connect "$a")
  printf '  abstract %s -> %s\n' "$(printf '%s' "$a" | clean)" "$r"
  case "$(reach "$r" "${SOCK_BLOCKED[@]}")" in
    yes) n_open=$((n_open + 1)) ;;
    unknown) n_unk=$((n_unk + 1)) ;;
  esac
done
tcp_out=$(python3 -I "$PY" tcpscan 2>&1 </dev/null)
tcp_rc=$?
printf '%s\n' "$tcp_out" | clean | sed 's/^/  /'
sum=$(printf '%s\n' "$tcp_out" | sed -n 's/^summary listen=\([0-9]*\) connected=\([0-9]*\) blocked=\([0-9]*\) unknown=\([0-9]*\)$/\1 \2 \3 \4/p')
if [ "$tcp_rc" -ne 0 ] || [ -z "$sum" ]; then
  n_unk=$((n_unk + 1))
  echo "  TCP 탐침이 끝까지 돌지 않았다(exit $tcp_rc)"
else
  read -r t_listen t_conn _ t_unk <<<"$sum"
  n_open=$((n_open + t_conn))
  n_unk=$((n_unk + t_unk))
fi
echo "  abstract $(printf '%s' "$abs" | grep -c .)개, TCP LISTEN ${t_listen:-?}개, 연결됨 $n_open, 검사 불능 $n_unk"
if [ "$n_open" -gt 0 ]; then
  judge netns yes "공유 netns에서 $n_open곳에 연결됐다(어느 프로세스의 것인지 위 이름으로 본다)"
elif [ "$n_unk" -gt 0 ]; then
  judge netns unknown "검사 불능 ${n_unk}건(거절이 아닌 결과: 시간 초과·도우미 실패, 또는 목록 작성 실패). 다 보지 못해 '없다'로 읽지 않는다"
else
  judge netns no "공유 netns의 abstract·TCP 수신점이 모두 그 실제 주소에서 거절됐거나 없다(hc core는 열지 않는다. 앞으로 제어 쪽에 서버를 더하면 다시 본다)"
fi

if [ "$role" = body ]; then
  echo "== 6. 중계 폴더: 쓰기·소켓 바꿔치기·심볼릭 링크(본체에는 읽기 전용 마운트)"
  find /relay "/relay/$gen" -maxdepth 1 -exec ls -ld {} + 2>&1 | awk '{ print "  " $1, $3, $4, $NF }' | clean
  w1=$(one tryop create "/relay/$gen/forge")
  w2=$(one tryop symlink "/relay/$gen/r.sock.link")
  w3=$(one tryop bind "/relay/$gen/r.sock")
  w4=$(one tryop rename /relay/current)
  printf '  파일 만들기: %s\n  심볼릭 링크: %s\n  같은 이름에 소켓 bind: %s\n  /relay/current 바꾸기: %s\n' "$w1" "$w2" "$w3" "$w4"
  n_yes=0 n_no=0
  for w in "$w1" "$w2" "$w3" "$w4"; do
    case "$(reach "$w" "${FS_BLOCKED[@]}" EADDRINUSE)" in
      yes) n_yes=$((n_yes + 1)) ;;
      no) n_no=$((n_no + 1)) ;;
    esac
  done
  if [ "$n_yes" -gt 0 ]; then
    judge relay-dir yes "중계 폴더에 ${n_yes}가지 조작이 됐다"
  elif [ "$n_no" -eq 4 ] && [ -d "/relay/$gen" ]; then
    judge relay-dir no "네 시도 모두 기대한 차단 오류(EROFS·EADDRINUSE)로 실패했다"
  else
    judge relay-dir unknown "네 시도 중 차단 오류로 확인된 것 ${n_no}개(나머지는 도우미 실패·다른 오류)"
  fi
fi
