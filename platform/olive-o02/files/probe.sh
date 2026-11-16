#!/bin/bash
# 닿는지 재는 탐침(티켓 할 일 5). 역할마다 같은 것을 본다: hc의 client 소켓, holder 소켓, 상태·설정 경로, /proc의 다른 길.
# 쓰는 법: probe.sh <역할> [결과 파일]
#   model            hc 터미널 안의 프로그램(core가 준 환경 그대로)
#   tool             hc 터미널 안, 환경을 비운 프로그램(경로를 모르는 도구 역할)
#   sibling-nomount  같은 파드의 다른 컨테이너, 세션 폴더 없음
#   sibling-ro       같은 파드의 다른 컨테이너, 세션 폴더 읽기 전용
#   peer             같은 ns의 다른 파드
# 읽고 연결만 해 본다. 파일을 쓰거나 지우지 않고, hc로는 목록(ls)만 부른다.
# "됨"은 가려졌다는 뜻이고 "안 됨"은 닿았다는 뜻이다.
role=${1:-unknown}
out=${2:-}
PY=/opt/o02/o02.py
RT=/s/rt/herdr-core
STATE=/s/st/herdr-core/o02
CONF=/s/cf/herdr-core

clean() { LC_ALL=C tr '\000-\010\013-\037\177' '?'; }
verdict() { printf '결과 5.%s.%s %s — %s\n' "$role" "$1" "$2" "$3"; }
try_connect() { python3 "$PY" connect "$1" 2>&1 | head -n 1; }

probe() {
  local p r reach_client=0 reach_holder=0 n_client=0 n_holder=0 names

  printf '탐침 역할=%s uid=%s gid=%s pid=%s ppid=%s\n' "$role" "$(id -u)" "$(id -g)" "$$" "$PPID"
  names=$(env | cut -d= -f1 | grep -E '^(HC_|XDG_|O02_)' | sort | tr '\n' ' ')
  printf '환경의 HC_·XDG_·O02_ 변수 이름: %s\n' "${names:-없음}"

  echo "== 1. 네트워크 네임스페이스의 Unix 소켓 이름(/proc/net/unix). 같은 파드의 컨테이너는 이 목록을 함께 본다"
  awk 'NR > 1 && NF >= 8 { print $8 }' /proc/net/unix 2>/dev/null | sort -u | head -n 40 | clean
  if awk 'NR > 1 && NF >= 8 && $8 ~ /^@/ { found = 1 } END { exit !found }' /proc/net/unix 2>/dev/null; then
    echo "abstract 소켓(@)이 있다. 파일 권한 없이 같은 파드의 모든 컨테이너가 연결할 수 있다:"
    for p in $(awk 'NR > 1 && NF >= 8 && $8 ~ /^@/ { print $8 }' /proc/net/unix | sort -u | head -n 10); do
      printf '  %s -> %s\n' "$(printf '%s' "$p" | clean)" "$(try_connect "$p")"
    done
    verdict abstract-socket "판단 필요" "abstract 소켓이 있다. hc의 것인지 위 이름으로 본다"
  else
    verdict abstract-socket "됨" "abstract 소켓 0개"
  fi

  echo "== 2. 경로를 아는 경우: 소켓에 연결"
  for p in "$RT"/*.sock "$STATE"/*.sock; do
    [ -e "$p" ] || continue
    r=$(try_connect "$p")
    printf '  %s -> %s\n' "$p" "$r"
    case "$p" in
      *.holder.*)
        n_holder=$((n_holder + 1))
        [ "$r" = ok ] && reach_holder=$((reach_holder + 1))
        ;;
      *)
        n_client=$((n_client + 1))
        [ "$r" = ok ] && reach_client=$((reach_client + 1))
        ;;
    esac
  done
  if [ "$n_client" -eq 0 ] && [ "$n_holder" -eq 0 ]; then
    if [ -d "$RT" ]; then echo "  소켓 폴더는 보이는데 소켓 파일이 보이지 않는다"; else echo "  소켓 폴더가 보이지 않는다: $RT"; fi
  fi
  if [ "$reach_client" -gt 0 ]; then
    verdict client-socket "안 됨" "client 소켓 ${n_client}개 중 ${reach_client}개에 연결됐다"
  else
    verdict client-socket "됨" "보인 client 소켓 ${n_client}개, 연결 0개"
  fi
  if [ "$reach_holder" -gt 0 ]; then
    verdict holder-socket "안 됨" "holder 소켓 ${n_holder}개 중 ${reach_holder}개에 연결됐다"
  else
    verdict holder-socket "됨" "보인 holder 소켓 ${n_holder}개, 연결 0개"
  fi

  echo "== 3. hc로 제어(목록만 부른다). client 소켓에 연결된 경우에만 한다. 연결이 안 되는데 부르면 hc가 새 core를 띄운다"
  if [ "$reach_client" -gt 0 ] && [ -x /opt/hc/hc ]; then
    for p in "$RT"/*.sock; do
      case "$p" in *.holder.*) continue ;; esac
      [ -e "$p" ] || continue
      HC_SOCKET=$p timeout 10 /opt/hc/hc ls 2>&1 | clean | head -n 12
      if [ "${PIPESTATUS[0]}" -eq 0 ]; then
        verdict hc-control "안 됨" "hc ls가 답했다. 이 역할이 터미널을 열고 입력하고 파일을 읽고 쓸 수 있다"
      else
        verdict hc-control "판단 필요" "소켓 연결은 됐는데 hc ls가 실패했다"
      fi
      break
    done
  else
    verdict hc-control "됨" "client 소켓에 연결되지 않아 부르지 않았다"
  fi

  echo "== 4. 상태·설정 경로"
  for p in "$STATE/terminals.json" "$STATE/core.json" "$STATE/restart-env.json" "$STATE/core.log" "$CONF/config.toml"; do
    if [ -r "$p" ]; then
      printf '  읽힘 %s (%s바이트)\n' "$p" "$(wc -c <"$p" 2>/dev/null)"
    else
      printf '  안 읽힘 %s\n' "$p"
    fi
  done
  for p in "$STATE" "$CONF" /s/cf /s/st; do
    if [ -w "$p" ]; then printf '  쓸 수 있음 %s\n' "$p"; else printf '  쓸 수 없음 %s\n' "$p"; fi
  done
  if [ -r "$STATE/terminals.json" ] || [ -w "$CONF" ] || [ -w /s/cf ]; then
    verdict state-config "안 됨" "상태를 읽거나 설정 자리에 쓸 수 있다(위 목록)"
  else
    verdict state-config "됨" "상태를 읽지 못하고 설정 자리에 쓰지 못한다"
  fi

  echo "== 5. /proc으로 돌아가는 길: 다른 프로세스의 environ·fd·root"
  local seen=0 env_readable=0 cred_visible=0 root_reach=0 sock_fds=0
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$$" ] && continue
    seen=$((seen + 1))
    if [ -r "$p/environ" ] && tr '\0' '\n' <"$p/environ" >/dev/null 2>&1; then
      env_readable=$((env_readable + 1))
      if tr '\0' '\n' <"$p/environ" 2>/dev/null | grep -q '^O02_FAKE_CRED='; then
        cred_visible=$((cred_visible + 1))
        printf '  가짜 자격 표식이 읽힘: pid %s (%s)\n' "${p#/proc/}" "$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null | cut -c1-60 | clean)"
      fi
    fi
    if ls "$p/root/s/rt/herdr-core" >/dev/null 2>&1; then root_reach=$((root_reach + 1)); fi
    # busybox find에는 -lname이 없을 수 있어 ls로 센다.
    # shellcheck disable=SC2010
    r=$(ls -l "$p/fd" 2>/dev/null | grep -c 'socket:')
    sock_fds=$((sock_fds + r))
  done
  echo "  보이는 다른 프로세스 $seen개, environ 읽힘 $env_readable개, 가짜 자격 표식 보임 $cred_visible개, root 별칭으로 소켓 폴더 보임 $root_reach개, 읽히는 소켓 fd $sock_fds개"
  if [ "$cred_visible" -gt 0 ]; then
    verdict proc-environ "안 됨" "다른 프로세스 ${cred_visible}개의 환경에서 가짜 자격 표식을 읽었다"
  else
    verdict proc-environ "됨" "가짜 자격 표식이 든 환경을 읽지 못했다(보이는 프로세스 ${seen}개)"
  fi
  if [ "$root_reach" -gt 0 ]; then
    verdict proc-alias "안 됨" "/proc/<pid>/root 별칭으로 소켓 폴더가 보인다(${root_reach}개)"
  else
    verdict proc-alias "됨" "/proc 별칭으로 소켓 폴더가 보이지 않는다"
  fi

  echo "== 6. 네임스페이스로 가릴 수 있는가(참고). 이 파드에서 권한 없는 user·mount 네임스페이스가 되는지"
  if unshare -Ur true 2>/dev/null; then echo "  unshare -Ur: 됨"; else echo "  unshare -Ur: 안 됨(bwrap 같은 방식의 가림은 이 파드 설정으로는 못 쓴다)"; fi
}

if [ -n "$out" ]; then
  probe >"$out" 2>&1
  : >"$out.done"
  echo "probe $role done"
else
  probe 2>&1
fi
