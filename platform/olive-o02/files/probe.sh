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
# "안 보인다"는 볼 대상이 있을 때만 가려졌다는 증거다. hc 터미널 안의 역할(model, tool)은 core가 반드시 떠 있으므로
# 소켓·상태 폴더를 찾지 못하면 경로가 틀린 것이라 "판단 필요"다. 같은 파드의 다른 컨테이너는 /proc/net/unix에
# hc 소켓 이름이 있어야(core가 떠 있어야) "됨"이다. 다른 파드(peer)에서는 core가 떠 있는지 알 수 없다:
# peer의 "됨"은 바로 앞에 세션 컨테이너에서 hide 단계를 돌려 core를 띄워 둔 경우에만 뜻이 있다.
role=${1:-unknown}
out=${2:-}
PY=/opt/o02/o02.py
RT=/s/rt/herdr-core
STATE=/s/st/herdr-core/o02
CONF=/s/cf/herdr-core

clean() { LC_ALL=C tr '\000-\010\013-\037\177' '?'; }
verdict() { printf '결과 5.%s.%s %s — %s\n' "$role" "$1" "$2" "$3"; }
try_connect() { python3 "$PY" connect "$1" 2>&1 | head -n 1; }

# hidden_state <hc 터미널 안인가 yes|no> <역할> <보인 소켓 수> <연결된 수> <netns 목록의 hc 소켓 이름 수>
# reached: 닿았다. hidden: 볼 대상이 있었는데 닿지 않았다. unknown: 볼 대상이 있었다는 증거가 없다.
hidden_state() {
  if [ "$4" -gt 0 ]; then
    echo reached
  elif [ "$3" -gt 0 ]; then
    echo hidden
  elif [ "$1" = yes ]; then
    echo unknown
  elif [ "$2" = peer ] || [ "$5" -gt 0 ]; then
    echo hidden
  else
    echo unknown
  fi
}
# 다른 파드에서는 세션 파드의 core가 떠 있는지 볼 길이 없다. 그 전제를 근거 글에 남긴다.
peer_note() {
  if [ "$role" = peer ]; then printf '%s' "(다른 파드라 core가 떠 있는지는 여기서 알 수 없다. 바로 앞에 hide 단계를 돌렸을 때만 뜻이 있다)"; fi
}

probe() {
  local p r reach_client=0 reach_holder=0 n_client=0 n_holder=0 names listed=0 inside=no client_state

  # hc 터미널 안에서 도는 역할인가. 그렇다면 core·holder·상태 폴더가 반드시 있다.
  case "$role" in model | tool) inside=yes ;; esac

  printf '탐침 역할=%s uid=%s gid=%s pid=%s ppid=%s\n' "$role" "$(id -u)" "$(id -g)" "$$" "$PPID"
  names=$(env | cut -d= -f1 | grep -E '^(HC_|XDG_|O02_)' | sort | tr '\n' ' ')
  printf '환경의 HC_·XDG_·O02_ 변수 이름: %s\n' "${names:-없음}"

  echo "== 1. 네트워크 네임스페이스의 Unix 소켓 이름(/proc/net/unix). 같은 파드의 컨테이너는 이 목록을 함께 본다"
  awk 'NR > 1 && NF >= 8 { print $8 }' /proc/net/unix 2>/dev/null | sort -u | head -n 40 | clean
  listed=$(awk 'NR > 1 && NF >= 8 && $8 ~ /herdr-core\/.*\.sock/ { n++ } END { print n + 0 }' /proc/net/unix 2>/dev/null)
  listed=${listed:-0}
  echo "이 목록의 hc 소켓 이름 ${listed}개(0개면 이 네임스페이스에 떠 있는 core가 없다)"
  if [ ! -r /proc/net/unix ]; then
    verdict abstract-socket "판단 필요" "/proc/net/unix를 읽지 못했다"
  elif awk 'NR > 1 && NF >= 8 && $8 ~ /^@/ { found = 1 } END { exit !found }' /proc/net/unix 2>/dev/null; then
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
  client_state=$(hidden_state "$inside" "$role" "$n_client" "$reach_client" "$listed")
  case "$client_state" in
    reached) verdict client-socket "안 됨" "client 소켓 ${n_client}개 중 ${reach_client}개에 연결됐다" ;;
    hidden) verdict client-socket "됨" "보인 client 소켓 ${n_client}개, 연결 0개$(peer_note)" ;;
    *) verdict client-socket "판단 필요" "client 소켓을 보지 못했는데 볼 대상(떠 있는 core)이 있었다는 증거가 없다(보인 ${n_client}개, 목록의 hc 소켓 이름 ${listed}개)" ;;
  esac
  case "$(hidden_state "$inside" "$role" "$n_holder" "$reach_holder" "$listed")" in
    reached) verdict holder-socket "안 됨" "holder 소켓 ${n_holder}개 중 ${reach_holder}개에 연결됐다" ;;
    hidden) verdict holder-socket "됨" "보인 holder 소켓 ${n_holder}개, 연결 0개$(peer_note)" ;;
    *) verdict holder-socket "판단 필요" "holder 소켓을 보지 못했는데 볼 대상(떠 있는 holder)이 있었다는 증거가 없다(보인 ${n_holder}개, 목록의 hc 소켓 이름 ${listed}개)" ;;
  esac

  echo "== 3. hc로 제어(목록만 부른다). client 소켓에 연결된 경우에만 한다. 연결이 안 되는데 부르면 hc가 새 core를 띄운다"
  if [ "$client_state" = unknown ]; then
    verdict hc-control "판단 필요" "client 소켓 판정이 '판단 필요'라 제어가 막혔는지도 알 수 없다"
  elif [ "$reach_client" -gt 0 ] && [ ! -x /opt/hc/hc ]; then
    verdict hc-control "판단 필요" "소켓 연결은 됐는데 이 컨테이너에 hc가 없어 불러 보지 못했다"
  elif [ "$reach_client" -gt 0 ]; then
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
  elif [ "$inside" = yes ] && [ ! -d "$STATE" ]; then
    verdict state-config "판단 필요" "hc 터미널 안인데 상태 폴더($STATE)가 보이지 않는다. 경로가 다를 수 있다"
  elif [ "$inside" = no ] && [ "$role" != peer ] && [ "$listed" -eq 0 ]; then
    verdict state-config "판단 필요" "이 파드에 떠 있는 core가 없다(목록의 hc 소켓 이름 0개). 상태 파일이 있었다는 증거가 없다"
  else
    verdict state-config "됨" "상태를 읽지 못하고 설정 자리에 쓰지 못한다$(peer_note)"
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
  elif [ "$inside" = yes ] && [ "$env_readable" -gt 0 ]; then
    # 같은 컨테이너의 core는 환경에 표식을 들고 있다. 환경이 읽히는데 표식이 없으면 core를 못 본 것이다.
    verdict proc-environ "판단 필요" "환경이 읽히는 프로세스 ${env_readable}개에 표식이 없다. 표식을 든 core의 환경을 봤다는 증거가 없다"
  elif [ "$inside" = yes ] && [ "$seen" -eq 0 ]; then
    verdict proc-environ "판단 필요" "다른 프로세스가 하나도 보이지 않는다. /proc을 읽지 못했을 수 있다"
  else
    verdict proc-environ "됨" "가짜 자격 표식이 든 환경을 읽지 못했다(보이는 프로세스 ${seen}개, 환경이 읽힌 것 ${env_readable}개)"
  fi
  if [ "$root_reach" -gt 0 ]; then
    verdict proc-alias "안 됨" "/proc/<pid>/root 별칭으로 소켓 폴더가 보인다(${root_reach}개)"
  elif [ "$inside" = yes ] && [ "$seen" -eq 0 ]; then
    verdict proc-alias "판단 필요" "다른 프로세스가 하나도 보이지 않는다. /proc을 읽지 못했을 수 있다"
  else
    verdict proc-alias "됨" "/proc 별칭으로 소켓 폴더가 보이지 않는다(보이는 프로세스 ${seen}개)"
  fi

  echo "== 6. 네임스페이스로 가릴 수 있는가(참고). 이 파드에서 권한 없는 user·mount 네임스페이스가 되는지"
  if unshare -Ur true 2>/dev/null; then echo "  unshare -Ur: 됨"; else echo "  unshare -Ur: 안 됨(bwrap 같은 방식의 가림은 이 파드 설정으로는 못 쓴다)"; fi

  echo "== 7. 노드 API 경로(가림과 별개). NetworkPolicy로 닫히지 않는 길이 이 역할에서 닿는지. 판정이 아니라 사실이다"
  python3 "$PY" nodepath "$role" 2>&1 | head -n 6
}

# 직접 부른 출력은 kubectl exec를 거쳐 관리자 단말로 간다. UTF-8 제어·서식 문자까지 지운 뒤 내보낸다.
if [ -n "$out" ]; then
  probe >"$out" 2>&1
  : >"$out.done"
  echo "probe $role done"
else
  probe 2>&1 | python3 "$PY" sanitize
fi
