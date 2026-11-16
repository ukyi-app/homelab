#!/usr/bin/env bash
# 올리브 계획 O25: 노드(NUC)에서 본 세션 파드 cgroup. sudo 없이 노드를 읽기만 한다(O02의 tools/olive-o02/node-cgroup.sh와 같은 방법).
#
#   node-cgroup.sh live <파드 UID>
#       두 컨테이너의 프로세스가 모두 이 파드 cgroup 안인지, 어느 컨테이너 cgroup에 어느 uid로 있는지, 밖에 시험 프로세스가 없는지
#       기대 역할: core, holder, relay(제어 쪽) + bodyinit(본체 PID 1). 하나라도 없으면 "판단 필요"다
#   node-cgroup.sh watch <파드 UID> <세대 ID> [최대 초]
#       재시작 요청 "전에" 띄운다(따로 터미널에서, 끝날 때까지 둔다). 그 세대에 심은 다섯 역할과 본체 PID 1을 pid·시작 시각·
#       컨테이너 cgroup으로 고정하고(3.node.준비-대상-고정), "armed"를 찍은 뒤 모두 사라질 때까지 5ms 간격으로 본다
#   node-cgroup.sh judge <파드 UID> <세대 ID> <새 init ns> <새 자격 제공 ns>
#       watch 기록과 제어 쪽 after-restart의 "노드 판정 입력" 줄을 견준다. 순서의 최종 판정이다
#       입력은 같은 회차의 after-restart 줄을 그대로 쓴다. 종료 코드 0은 통과가 아니다. 필수 "결과" 줄이 모두 됨이어야 한다
#   node-cgroup.sh after <파드 UID> <옛 세대 ID>
#       전체 재시작 뒤: 옛 세대에 심은 것(plant.sh의 p-<세대>-*, 첩자)이 노드 어디에도 없는지, 본체 PID 1이 새로 떴는지
#       그 세대의 watch 고정 기록이 있어야 한다(없는 세대 인자로 "0개"가 통과하지 않게)
#
# 파드 UID는 run.sh status가 찍는다. 전체 재시작(RestartAllContainers)은 파드 UID를 바꾸지 않는다. 출력은 O25_LOG_DIR에도 남긴다.
# Podman 리허설에서는 파드 UID 자리에 Podman 파드 ID(64자)를 준다.
# 파드 안 프로세스의 명령줄은 믿지 않는 입력이다. 한 줄로 만들고 모든 출력을 sanitize.py에 통과시킨 뒤에 찍는다.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOG_DIR=${O25_LOG_DIR:-$HOME/olive-verify/O25/run}
PROC=/proc
CG=/sys/fs/cgroup

mode=${1:-}
uid=${2:-}
gen=${3:-}
usage() {
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}
[[ $mode =~ ^(live|after|watch|judge)$ && $uid =~ ^([0-9a-f-]{36}|[0-9a-f]{64})$ ]] || usage
[ "$mode" = live ] || [[ $gen =~ ^[0-9a-f]{12}$ ]] || usage
mkdir -p "$LOG_DIR"
watch_rec="$LOG_DIR/node-watch-$uid-$gen.json"
case "$mode" in
  watch)
    limit=${4:-180}
    [[ $limit =~ ^[0-9]+$ ]] || usage
    # 기록 파일은 세대마다 하나다. 앞 회차의 기록을 이번 회차의 증거로 쓰지 않게 이미 있으면 거절한다.
    if [ -e "$watch_rec" ]; then
      echo "이미 이 세대의 watch 기록이 있다: $watch_rec" >&2
      exit 3
    fi
    python3 -I "$HERE/node-watch.py" watch "$uid" "$gen" "$watch_rec" "$limit" 2>&1 | python3 -I "$HERE/sanitize.py" | tee "$LOG_DIR/node-watch-$uid-$gen.txt"
    # 종료 코드는 관측기가 끝까지 돌았는지만 말한다. 판정은 "결과" 줄로 본다(0이어도 판단 필요·안 됨일 수 있다).
    exit "${PIPESTATUS[0]}"
    ;;
  judge)
    [[ ${4:-} =~ ^([0-9]{19}|-)$ && ${5:-} =~ ^([0-9]{19}|-)$ ]] || usage
    # 기록 안의 파드·세대가 인자와 다르면 judge가 판단 필요를 낸다(파일 이름만 맞춘 다른 회차의 기록).
    python3 -I "$HERE/node-watch.py" judge "$watch_rec" "$uid" "$gen" "$4" "$5" 2>&1 | python3 -I "$HERE/sanitize.py" | tee "$LOG_DIR/node-judge-$uid-$gen-$(date -u +%Y%m%dT%H%M%SZ).txt"
    exit "${PIPESTATUS[0]}"
    ;;
esac
# systemd cgroup 드라이버는 UID의 - 를 _ 로 바꿔 쓴다.
uid_us=${uid//-/_}

verdict() { printf '결과 %s %s — %s\n' "$1" "$2" "$3"; }
# 2>/dev/null을 < 앞에 둔다. 뒤에 두면 그새 끝난 프로세스의 파일을 못 연 셸 오류가 찍힌다.
cmd_line() { tr '\0\n\r\t' '    ' 2>/dev/null <"$1" | cut -c1-90; }

# classify <cmdline 파일>: argv의 자리로 역할을 가른다.
classify() {
  local -a a=()
  local a0
  { mapfile -d '' -t a <"$1"; } 2>/dev/null || {
    echo none
    return
  }
  # 커널 스레드는 argv가 비어 있다. set -u에서 ${a[0]}을 바로 쓰면 이 함수가 아무것도 내지 않고 끝난다.
  [ "${#a[@]}" -gt 0 ] || {
    echo none
    return
  }
  a0=${a[0]}
  case "$a0" in
    /opt/hc/*)
      case " ${a[*]:1} " in
        *" serve "*) echo core ;;
        *" hold "*) echo holder ;;
        *) echo client ;;
      esac
      return
      ;;
  esac
  case "${a0##*/} ${a[1]:-} ${a[2]:-}" in
    "python3 /opt/o25/o25.py relay-serve") echo relay ;;
    "python3 /opt/o25/o25.py cred-serve") echo credsrv ;;
    "python3 /opt/o25/o25.py body-init") echo bodyinit ;;
    "python3 /opt/o25/o25.py spy") echo "spy:${a[3]:-}" ;;
    "bash /opt/o25/plant.sh sleeper" | "bash /opt/o25/plant.sh stubborn") echo "plant:${a[3]:-}" ;;
    "bash /opt/o25/control.sh"*) echo control ;;
    *)
      case "${a[*]}" in
        *"/opt/o25/"* | *"/opt/hc/"*) echo other ;;
        *) echo none ;;
      esac
      ;;
  esac
}

uid_of() { awk '/^Uid:/ { print $2; exit }' 2>/dev/null <"$1/status"; }
start_of() {
  local stat f
  { read -r stat <"$1/stat"; } 2>/dev/null || return
  read -ra f <<<"${stat##*) }"
  printf '%s' "${f[19]:-}"
}

main() {
  local pod_dir d role cg u inside=0 outside=0 can_see=yes lack="" old_alive=0 bodyinit=0 k
  local -A count=()
  pod_dir=$(find "$CG" -maxdepth 7 -type d \( -name "*pod${uid_us}*" -o -name "*pod${uid}*" -o -name "*pod_${uid}*" \) 2>/dev/null | head -n 1)
  if [ -n "$pod_dir" ]; then
    echo "== 파드 cgroup: $pod_dir"
    # 차트는 컨테이너별 pid 상한을 주지 못한다. 파드 단위(kubelet podPidsLimit)와 그 위의 실제 값을 사실로 남긴다.
    printf -- '-- 파드 단위 pids.max=%s pids.current=%s, 위 단계 pids.max=%s\n' "$(cat 2>/dev/null <"$pod_dir/pids.max")" \
      "$(cat 2>/dev/null <"$pod_dir/pids.current")" "$(cat 2>/dev/null <"${pod_dir%/*}/pids.max")"
    for c in "$pod_dir"/*/; do
      [ -d "$c" ] || continue
      printf -- '-- 하위 cgroup %s: populated=%s pids=%s memory.max=%s\n' "$(basename "$c")" \
        "$(awk '$1 == "populated" { print $2 }' 2>/dev/null <"${c}cgroup.events")" "$(cat 2>/dev/null <"${c}pids.current")" "$(cat 2>/dev/null <"${c}memory.max")"
      while read -r pid; do
        [[ $pid =~ ^[0-9]+$ ]] || continue
        printf '   pid %s uid %s 시작 %s 역할 %s :: %s\n' "$pid" "$(uid_of "$PROC/$pid")" "$(start_of "$PROC/$pid")" "$(classify "$PROC/$pid/cmdline")" "$(cmd_line "$PROC/$pid/cmdline")"
      done 2>/dev/null <"${c}cgroup.procs"
    done
  else
    echo "== 파드 cgroup 폴더가 없다(UID $uid)"
  fi

  echo "== 노드의 모든 프로세스에서 시험 프로세스 찾기"
  if [ -z "$(tr -d '\0' 2>/dev/null <"$PROC/1/cmdline")" ]; then
    can_see=no
    echo "pid 1의 명령줄을 읽지 못했다. 다른 프로세스를 보지 못할 수 있다"
  fi
  for d in "$PROC"/[0-9]*; do
    role=$(classify "$d/cmdline")
    [ "$role" = none ] && continue
    cg=$(sed -n 's/^0:://p' 2>/dev/null <"$d/cgroup" | tr -d '\n')
    u=$(uid_of "$d")
    case "$role" in
      spy:p-"$gen"-* | plant:p-"$gen"-*)
        [ "$mode" = after ] && {
          old_alive=$((old_alive + 1))
          printf '옛 세대의 심은 것: pid %s uid %s 역할 %s cgroup %s\n' "${d##*/}" "$u" "$role" "$cg"
        }
        ;;
    esac
    [ "$role" = bodyinit ] && [[ $cg == *"$uid_us"* || $cg == *"$uid"* ]] && bodyinit=$((bodyinit + 1))
    case "$cg" in
      *"$uid_us"* | *"$uid"*)
        inside=$((inside + 1))
        count[${role%%:*}]=$((${count[${role%%:*}]:-0} + 1))
        ;;
      *)
        outside=$((outside + 1))
        printf '파드 cgroup 밖: pid %s uid %s 역할 %s %s :: %s\n' "${d##*/}" "$u" "$role" "${cg:-(못 읽음)}" "$(cmd_line "$d/cmdline")"
        ;;
    esac
  done
  printf '이 파드 cgroup 안 %s개(' "$inside"
  for k in "${!count[@]}"; do printf '%s=%s ' "$k" "${count[$k]}"; done
  printf '), 밖 %s개\n' "$outside"

  if [ "$mode" = live ]; then
    for k in core holder relay bodyinit; do [ "${count[$k]:-0}" -gt 0 ] || lack="$lack $k"; done
    k="1.node.두-컨테이너-모두-파드-cgroup-안"
    if [ -z "$pod_dir" ]; then
      verdict "$k" "판단 필요" "파드 cgroup 폴더를 찾지 못했다"
    elif [ "$outside" -gt 0 ]; then
      verdict "$k" "안 됨" "파드 cgroup 밖에 ${outside}개(위 줄. 이 명령을 돌린 쪽의 검색 명령이면 시험 프로세스가 아니다)"
    elif [ "$can_see" = no ] || [ -n "$lack" ]; then
      verdict "$k" "판단 필요" "다른 프로세스를 못 보거나 기대 역할이 없다:${lack:- 없음}"
    else
      verdict "$k" "됨" "제어 쪽(core·holder·relay)과 본체 PID 1이 모두 이 파드 cgroup 안이고 밖에 0개다. 하위 cgroup별 uid는 위 줄"
    fi
  else
    k="3.node.옛-세대-심은-것-0"
    if ! grep -q '"armed": true' "$watch_rec" 2>/dev/null; then
      verdict "$k" "판단 필요" "세대 $gen 의 watch 고정 기록이 없다(재시작 전에 watch로 그 세대의 대상을 고정해야 '0개'가 뜻이 있다)"
    elif [ "$can_see" = no ]; then
      verdict "$k" "판단 필요" "다른 프로세스를 보지 못해 '0개'를 믿을 수 없다"
    elif [ "$old_alive" -gt 0 ]; then
      verdict "$k" "안 됨" "옛 세대 $gen 에 심은 것 ${old_alive}개가 노드에 남았다"
    elif [ "$bodyinit" -ge 1 ]; then
      verdict "$k" "됨" "옛 세대 $gen 에 심은 분리 후손·첩자가 노드 어디에도 없고, 이 파드 cgroup에 본체 PID 1이 있다(새 컨테이너인지는 run.sh status의 startedAt으로 본다)"
    else
      verdict "$k" "판단 필요" "옛 세대 것은 0개지만 본체 PID 1도 보이지 않는다(파드가 떠 있는지 본다)"
    fi
  fi
}

mkdir -p "$LOG_DIR"
main 2>&1 | python3 -I "$HERE/sanitize.py" | tee "$LOG_DIR/node-$mode-$uid-$(date -u +%Y%m%dT%H%M%SZ).txt"
