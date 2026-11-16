#!/bin/bash
# 가림 탐침. 쓰는 법: probe.sh <body|control>
#   body     본체 컨테이너(uid 10002)에서. 제어 쪽 hc·허가·프로세스에 닿는지 본다. 판정의 대상이다.
#   control  제어 컨테이너(uid 10001)에서 같은 것을 본다. 대조군: 검사가 닿는 것을 잡을 수 있다는 증거다.
# 경로를 찾지 못해 "안 닿음"이 되지 않게, 정확한 경로를 세대 ID(/relay/current)에서 만들고 이름 목록(/proc/net/unix)에서 읽어 직접 connect한다.
# "됨"은 가려졌다(본체에서 닿지 않았다)는 뜻이다. 대조군의 줄은 "사실"로만 낸다.
# 제어 쪽 파일을 쓰거나 지우지 않는다. 중계 폴더에 쓰기·바꿔치기 시도는 본체 역할에서만 한다(제어 역할이면 진짜 소켓을 건드린다).
role=${1:-}
case "$role" in body | control) ;; *)
  echo "probe.sh: body 또는 control" >&2
  exit 2
  ;;
esac
PY=/opt/o25/o25.py
clean() { LC_ALL=C tr '\000-\010\013-\037\177' '?'; }
one() { python3 "$PY" "$@" 2>&1 | head -n 1 | clean; }
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
if [ -z "$gen" ]; then
  echo "세대를 읽지 못했다(/relay/current)"
  exit 1
fi

echo "== 1. hc 소켓에 직접 connect: 정확한 경로(세대에서 만든 client 경로 + /proc/net/unix에 보이는 hc 이름)"
names=$(awk 'NR > 1 && NF >= 8 && $8 ~ /herdr-core\/.*\.sock$/ { print $8 }' /proc/net/unix 2>/dev/null | sort -u)
n_names=$(printf '%s' "$names" | grep -c .)
echo "netns에 보이는 hc 소켓 이름 ${n_names}개(같은 파드는 netns를 나눠 써서 이름이 보인다. 0개면 core가 떠 있지 않다)"
reached=0 tried=0
for p in "$G/rt/herdr-core/o25.sock" $names; do
  r=$(one connect "$p")
  tried=$((tried + 1))
  printf '  %s -> %s\n' "$p" "$r"
  [ "$r" = connected ] && reached=$((reached + 1))
done
if [ "$reached" -gt 0 ]; then
  judge hc-socket yes "hc 소켓 $tried곳 중 $reached곳에 연결됐다"
elif [ "$n_names" -gt 0 ]; then
  judge hc-socket no "이름이 보이는 hc 소켓 ${n_names}개를 포함해 $tried곳 모두 연결이 안 됐다"
else
  judge hc-socket unknown "netns에 hc 소켓 이름이 없다(core가 떠 있었다는 증거가 없다)"
fi

echo "== 2. hc ls(제어 쪽과 같은 XDG 경로를 준다)"
out=$(XDG_STATE_HOME=$G/st XDG_CONFIG_HOME=$G/cf XDG_RUNTIME_DIR=$G/rt HC_SESSION=o25 HOME=$G/h timeout 10 /opt/hc/hc ls 2>&1 </dev/null)
rc=$?
out=$(printf '%s\n' "$out" | clean | head -n 8)
printf '%s\n' "$out" | sed 's/^/  /'
if printf '%s' "$out" | grep -qw body; then
  judge hc-ls yes "제어 쪽 터미널 body가 목록에 보였다"
elif [ "$n_names" -gt 0 ]; then
  judge hc-ls no "core가 떠 있는데(이름 ${n_names}개) 목록에 body가 없다(exit $rc)"
else
  judge hc-ls unknown "core가 떠 있었다는 증거가 없다"
fi

echo "== 3. hc 상태 읽기·설정 쓰기, 세대 허가 폴더"
st=$(cat "$G/st/herdr-core/o25/terminals.json" 2>&1 | head -c 200 | clean)
printf '  상태 읽기: %s\n' "$(printf '%s' "$st" | head -n 1)"
w=$(one trycreate "$G/cf/herdr-core/o25-probe-$role")
printf '  설정 쓰기: %s\n' "$w"
b=$(find /c/boot -maxdepth 1 2>&1 | head -n 3 | tr '\n' ' ' | clean)
printf '  허가 폴더(/c/boot): %s\n' "$b"
if [ "$role" = body ]; then
  if [ -d /c ]; then
    judge state yes "/c가 본체에 보인다"
  elif [ "$n_names" -gt 0 ]; then
    judge state no "/c가 본체 파일 시스템에 없다(상태 읽기·설정 쓰기·허가 폴더 모두 위 결과)"
  else
    judge state unknown "core가 떠 있었다는 증거가 없다"
  fi
else
  judge state "$([ -r "$G/st/herdr-core/o25/terminals.json" ] && echo yes || echo no)" "제어 쪽에서 상태 파일을 읽었는가"
fi

echo "== 4. /proc: uid 10001(제어 쪽) 프로세스, 그 환경·별칭, 신호"
ctl_pids=""
for d in /proc/[0-9]*; do
  u=$(awk '/^Uid:/ {print $2; exit}' 2>/dev/null <"$d/status")
  [ "$u" = 10001 ] && ctl_pids="$ctl_pids ${d#/proc/}"
done
echo "  보이는 uid 10001 프로세스:${ctl_pids:- 없음}"
env_hit=0 sig_hit=0
for p in $ctl_pids; do
  [ "$p" = "$$" ] && continue
  { tr '\0' '\n' <"/proc/$p/environ" | grep -q '^XDG_RUNTIME_DIR='; } 2>/dev/null && env_hit=$((env_hit + 1))
  kill -0 "$p" 2>/dev/null && sig_hit=$((sig_hit + 1))
done
if [ "$role" = body ]; then
  if [ -n "$ctl_pids" ]; then
    judge proc yes "uid 10001 프로세스가 보인다(환경 읽힘 $env_hit, 신호 가능 $sig_hit)"
  elif [ -r /proc/1/status ] && [ "$(awk '/^Uid:/ {print $2; exit}' /proc/1/status)" = 10002 ]; then
    judge proc no "보이는 프로세스는 본체 uid뿐이고 PID 1도 본체 쪽이다(PID 네임스페이스를 나누지 않았다)"
  else
    judge proc unknown "PID 1을 읽지 못했다"
  fi
else
  judge proc "$([ "$env_hit" -gt 0 ] && echo yes || echo no)" "제어 쪽 프로세스 환경을 읽음 $env_hit, 신호 가능 $sig_hit"
fi
fact_proc_root=$(readlink /proc/1/root 2>&1 | clean)
echo "  /proc/1/root -> $fact_proc_root, /proc/1/cmdline: $(tr '\0' ' ' 2>/dev/null </proc/1/cmdline | cut -c1-80 | clean)"

echo "== 5. 공유 netns: abstract 소켓과 TCP 듣는 곳(파드의 컨테이너가 함께 본다)"
abs=$(awk 'NR > 1 && NF >= 8 && $8 ~ /^@/ { print $8 }' /proc/net/unix 2>/dev/null | sort -u | head -n 10)
tcp=$(awk 'NR > 1 && $4 == "0A" { print $2 }' /proc/net/tcp /proc/net/tcp6 2>/dev/null | sort -u | head -n 10)
n_open=0
for a in $abs; do
  r=$(one connect "$a")
  printf '  abstract %s -> %s\n' "$(printf '%s' "$a" | clean)" "$r"
  [ "$r" = connected ] && n_open=$((n_open + 1))
done
for t in $tcp; do
  port=$((16#${t##*:}))
  r=$(one tcp 127.0.0.1 "$port")
  printf '  tcp :%s -> %s\n' "$port" "$r"
  [ "$r" = connected ] && n_open=$((n_open + 1))
done
echo "  abstract $(printf '%s' "$abs" | grep -c .)개, TCP LISTEN $(printf '%s' "$tcp" | grep -c .)개, 연결됨 $n_open"
if [ "$n_open" -gt 0 ]; then
  judge netns yes "공유 netns에서 $n_open곳에 연결됐다(어느 프로세스의 것인지 위 이름으로 본다)"
else
  judge netns no "공유 netns에 연결되는 abstract·TCP 수신점이 없다(hc core는 열지 않는다. 앞으로 제어 쪽에 서버를 더하면 다시 본다)"
fi

if [ "$role" = body ]; then
  echo "== 6. 중계 폴더: 쓰기·소켓 바꿔치기·심볼릭 링크(본체에는 읽기 전용 마운트)"
  find /relay "/relay/$gen" -maxdepth 1 -exec ls -ld {} + 2>&1 | awk '{ print "  " $1, $3, $4, $NF }' | clean
  w1=$(one trycreate "/relay/$gen/forge")
  w2=$(python3 -c 'import os,sys; os.symlink("/b", sys.argv[1]); print("ok")' "/relay/$gen/r.sock.link" 2>&1 | tail -n 1 | clean)
  w3=$(python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); print("ok")' "/relay/$gen/r.sock" 2>&1 | tail -n 1 | clean)
  w4=$(python3 -c 'import os,sys; os.rename(sys.argv[1], sys.argv[1] + ".x"); print("ok")' /relay/current 2>&1 | tail -n 1 | clean)
  printf '  파일 만들기: %s\n  심볼릭 링크: %s\n  같은 이름에 소켓 bind: %s\n  /relay/current 바꾸기: %s\n' "$w1" "$w2" "$w3" "$w4"
  if [ "$w1" = ok ] || [ "$w2" = ok ] || [ "$w3" = ok ] || [ "$w4" = ok ]; then
    judge relay-dir yes "중계 폴더에 하나 이상 쓰였다"
  elif [ -d "/relay/$gen" ]; then
    judge relay-dir no "네 시도 모두 실패했다(EROFS 또는 권한)"
  else
    judge relay-dir unknown "이번 세대의 중계 폴더가 없다"
  fi
fi
