#!/usr/bin/env bash
# 올리브 계획 O02: 노드(NUC)에서 본 파드 cgroup. sudo 없이 노드를 읽기만 한다(D-39의 노드 확인과 같은 방법).
#
#   node-cgroup.sh live <파드 UID> [역할 목록] [단계 결과 파일]
#       파드가 떠 있을 때: 기대 역할이 떠 있고, 시험 프로세스가 모두 그 파드 cgroup 안인지, 상한이 무엇인지
#       역할 목록: core,holder,prog,det,py 중에서 쉼표로(기본 core,holder,prog). 하나라도 없으면 "판단 필요"다
#       단계 결과 파일: run.sh step이 남긴 파일. 그 안의 "사실 역할표" 줄(역할:파드 안 pid:시작시각)을 노드에서 본 값과 대조한다
#   node-cgroup.sh gone <파드 UID>
#       파드를 지운 뒤: 그 UID의 cgroup이 비었거나 사라졌는지, 시험 프로세스가 노드에 남았는지
#       같은 UID를 live로 본 기록이 있어야 판정한다(UID를 잘못 적어도 "비었다"로 보이기 때문이다)
#
# 파드 UID는 run.sh status가 찍는다. 지우기 전에 적어 둔다. 출력은 O02_LOG_DIR(기본 ~/olive-verify/O02/run)에도 남긴다.
# 판정 줄의 "됨"은 안전한 쪽 성질이 성립한다는 뜻이다.
#
# 파드 안 프로세스의 명령줄은 믿지 않는 입력이다. 줄바꿈을 공백으로 바꿔 한 줄로 만들고(가짜 판정 줄을 끼워 넣지 못하게),
# 모든 출력을 sanitize.py에 통과시킨 뒤에 찍는다. 이 파일에서 정제를 거치지 않는 출력 경로를 만들지 않는다.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOG_DIR=${O02_LOG_DIR:-$HOME/olive-verify/O02/run}
# 판정 논리를 합성 /proc·cgroup 나무로 돌려 볼 때만 바꾼다. 실제 확인에서는 두지 않는다.
# 바꾼 채로 낸 판정은 실제 노드의 증거가 아니다. 환경에 값이 남은 채 실제 확인을 돌려도 섞이지 않게 판정 줄마다 표시하고,
# 기록 파일 이름도 달리해 gone이 합성 실행의 live 기록을 근거로 삼지 못하게 한다.
PROC=${O02_PROC_ROOT:-/proc}
CG=${O02_CG_ROOT:-/sys/fs/cgroup}
synth=""
if [ "$PROC" != /proc ] || [ "$CG" != /sys/fs/cgroup ]; then synth="synth-"; fi

mode=${1:-}
uid=${2:-}
want=${3:-core,holder,prog}
table_file=${4:-}
role_re='(core|holder|prog|det|py)'
if [[ ! $mode =~ ^(live|gone)$ || ! $uid =~ ^[0-9a-f-]{36}$ || ! $want =~ ^$role_re(,$role_re)*$ ]] || { [ -n "$table_file" ] && [ ! -r "$table_file" ]; }; then
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
# systemd cgroup 드라이버는 UID의 - 를 _ 로 바꿔 쓴다. cgroupfs 드라이버는 그대로 쓴다.
uid_us=${uid//-/_}

verdict() { printf '결과 %s %s — %s%s\n' "$1" "$2" "$3" "${synth:+ [합성 경로로 낸 판정: 실제 노드의 증거가 아니다]}"; }
show() { # <파일>: 값을 한 줄로
  if [ -r "$1" ]; then tr '\n' ' ' <"$1"; else printf '(못 읽음)'; fi
}
# 명령줄을 한 줄로: NUL·줄바꿈·CR·탭을 공백으로.
# 2>/dev/null을 < 앞에 둔다. 뒤에 두면 그새 끝난 프로세스의 파일을 못 연 셸 오류가 출력에 찍힌다.
cmd_line() { tr '\0\n\r\t' '    ' 2>/dev/null <"$1" | cut -c1-90; }

# classify <cmdline 파일>: 그 프로세스의 역할을 낸다. 글자가 어딘가에 들었는지가 아니라 argv의 자리로 가른다.
#   core, holder  hc가 띄운 것(argv[0]이 /opt/hc/ 아래, 인자에 serve·hold)
#   prog, det, py 터미널 안 고정 프로그램(prog.sh, 그중 세션을 분리한 후손 det-*, o02.py)
#   init, executor, ctl, probe, client, other  시험 전부터 있거나 검사·호출 쪽. 포함 관계의 증거로 세지 않는다
#   none          시험과 무관
classify() {
  local -a a=()
  local i all a0
  { mapfile -d '' -t a <"$1"; } 2>/dev/null || {
    echo none
    return
  }
  a0=${a[0]:-}
  case "$a0" in
    /opt/hc/*)
      for ((i = 1; i < ${#a[@]}; i++)); do
        case "${a[i]}" in
          --) break ;;
          serve)
            echo core
            return
            ;;
          hold)
            echo holder
            return
            ;;
        esac
      done
      echo client
      return
      ;;
  esac
  case "${a0##*/}" in
    bash | sh | python3)
      case "${a[1]:-}" in
        /opt/o02/init.sh) echo init ;;
        /opt/o02/executor.sh) echo executor ;;
        /opt/o02/ctl.sh) echo ctl ;;
        /opt/o02/probe.sh) echo probe ;;
        /opt/o02/prog.sh)
          case "${a[3]:-}" in det-*) echo det ;; *) echo prog ;; esac
          ;;
        /opt/o02/o02.py) echo py ;;
        *) all=${a[*]} ;;
      esac
      ;;
    *) all=${a[*]} ;;
  esac
  if [ -n "${all+x}" ]; then
    case "$all" in
      *"/opt/o02/"* | *"/opt/hc/"*) echo other ;;
      *) echo none ;;
    esac
  fi
}

start_of() { # <pid 폴더>: /proc/<pid>/stat의 22번째 칸. 파드 안에서 읽어도 같은 값이다.
  local stat f
  { read -r stat <"$1/stat"; } 2>/dev/null || return
  read -ra f <<<"${stat##*) }"
  printf '%s' "${f[19]:-}"
}

main() {
  local pod_dir populated="" c f pid nspid d role cg k tok miss="" lack="" seen="" matched=0 unmatched="" can_see=yes live_seen=no
  local inside=0 other_pod=0 outside=0
  local -A count=() byproc=()

  pod_dir=$(find "$CG" -maxdepth 4 -type d \( -name "*pod${uid_us}*" -o -name "*pod${uid}*" \) 2>/dev/null | head -n 1)

  if [ -n "$pod_dir" ]; then
    echo "== 파드 cgroup: $pod_dir"
    for f in cgroup.events pids.current memory.max cpu.max memory.events; do
      printf '%s: %s\n' "$f" "$(show "$pod_dir/$f")"
    done
    populated=$(awk '$1 == "populated" { print $2 }' "$pod_dir/cgroup.events" 2>/dev/null)
    for c in "$pod_dir"/*/; do
      [ -d "$c" ] || continue
      echo "-- 하위 cgroup(컨테이너): $(basename "$c")"
      for f in cgroup.events pids.current pids.max memory.max cpu.max memory.oom.group memory.events; do
        printf '   %s: %s\n' "$f" "$(show "$c$f")"
      done
      if [ -r "${c}cgroup.procs" ]; then
        while read -r pid; do
          [[ $pid =~ ^[0-9]+$ ]] || continue
          nspid=$(awk '/^NSpid:/ { print $NF }' "$PROC/$pid/status" 2>/dev/null)
          printf '   pid %s (파드 안 pid %s, 시작 %s, 역할 %s) %s\n' "$pid" "${nspid:-?}" "$(start_of "$PROC/$pid")" "$(classify "$PROC/$pid/cmdline")" "$(cmd_line "$PROC/$pid/cmdline")"
        done <"${c}cgroup.procs"
      else
        echo "   cgroup.procs를 읽지 못했다"
      fi
    done
  else
    echo "== 파드 cgroup 폴더가 없다(UID $uid)"
  fi

  echo "== 노드의 모든 프로세스에서 시험 프로세스 찾기"
  # 다른 사용자의 프로세스가 보이지 않으면(hidepid 등) "0개"는 증거가 아니다. pid 1의 명령줄이 읽히는지로 가린다.
  # /proc의 파일은 크기가 0으로 보이므로 크기가 아니라 읽은 내용으로 본다.
  if [ -z "$(tr -d '\0' 2>/dev/null <"$PROC/1/cmdline")" ]; then
    can_see=no
    echo "pid 1의 명령줄을 읽지 못했다. 이 사용자는 다른 프로세스를 보지 못할 수 있다"
  fi
  for d in "$PROC"/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    role=$(classify "$d/cmdline")
    [ "$role" = none ] && continue
    cg=$(sed -n 's/^0:://p' "$d/cgroup" 2>/dev/null | tr -d '\n')
    case "$cg" in
      *"$uid_us"* | *"$uid"*)
        inside=$((inside + 1))
        count[$role]=$((${count[$role]:-0} + 1))
        nspid=$(awk '/^NSpid:/ { print $NF }' "$d/status" 2>/dev/null)
        byproc["${nspid:-?}:$(start_of "$d")"]=$role
        ;;
      *kubepods*)
        other_pod=$((other_pod + 1))
        printf '다른 파드의 cgroup: pid %s 역할 %s %s :: %s\n' "${d##*/}" "$role" "$cg" "$(cmd_line "$d/cmdline")"
        ;;
      *)
        outside=$((outside + 1))
        printf '파드 cgroup 밖: pid %s 역할 %s %s :: %s\n' "${d##*/}" "$role" "${cg:-(못 읽음)}" "$(cmd_line "$d/cmdline")"
        ;;
    esac
  done
  for k in core holder prog det py init executor ctl probe client other; do
    [ "${count[$k]:-0}" -gt 0 ] && seen="$seen $k=${count[$k]}"
  done
  echo "이 파드 cgroup 안 $inside개(역할별:${seen:- 없음}), 다른 파드 cgroup $other_pod개, 파드 cgroup 밖 $outside개"
  echo "(파드 cgroup 밖으로 나온 줄이 이 명령을 돌린 쪽의 편집기·검색 명령이면 시험 프로세스가 아니다. 명령줄로 가린다)"

  if [ "$mode" = live ]; then
    k="3.node.시험-프로세스-모두-파드-cgroup-안"
    for role in ${want//,/ }; do
      [ "${count[$role]:-0}" -gt 0 ] || lack="$lack $role"
    done
    if [ -n "$table_file" ]; then
      # 역할표는 파드가 낸 글이다. 모양이 맞는 낱말만 쓴다.
      for tok in $(grep -a '^사실 역할표 ' "$table_file" | tail -n 1 | cut -d' ' -f3-); do
        [[ $tok =~ ^$role_re:[0-9]+:[0-9]+$ ]] || continue
        if [ "${byproc[${tok#*:}]:-}" = "${tok%%:*}" ]; then matched=$((matched + 1)); else unmatched="$unmatched $tok"; fi
      done
      echo "역할표 대조: 일치 $matched개, 이 파드 cgroup 안에서 찾지 못한 것:${unmatched:- 없음}"
    fi
    if [ -z "$pod_dir" ]; then
      verdict "$k" "판단 필요" "파드 cgroup 폴더를 찾지 못했다. UID와 cgroup 배치를 본다"
    elif [ "$outside" -gt 0 ]; then
      verdict "$k" "안 됨" "파드 cgroup 밖에 ${outside}개가 있다(위 줄)"
    elif [ "$can_see" = no ]; then
      verdict "$k" "판단 필요" "다른 프로세스를 보지 못해 '밖에 0개'를 믿을 수 없다"
    elif [ -n "$lack" ]; then
      verdict "$k" "판단 필요" "기대 역할이 이 파드 cgroup 안에 없다:$lack(본 것:${seen:- 없음}). init·executor만으로는 포함 관계를 본 것이 아니다"
    elif [ -n "$table_file" ] && { [ "$matched" -eq 0 ] || [ -n "$unmatched" ]; }; then
      verdict "$k" "판단 필요" "단계가 적은 역할표의 프로세스를 이 파드 cgroup 안에서 다 찾지 못했다(일치 $matched개, 못 찾음:${unmatched:- 없음}). 단계 뒤에 프로세스가 바뀌었을 수 있다"
    else
      if [ -n "$table_file" ]; then miss="역할표 ${matched}개와 pid·시작시각이 일치"; else miss="역할표 대조는 하지 않았다"; fi
      verdict "$k" "됨" "기대 역할($want)이 모두 이 파드 cgroup 안에 있고(역할별:$seen), 밖에 0개다. $miss(다른 파드 ${other_pod}개는 대조 파드인지 위 줄로 본다)"
    fi
  else
    # 파드가 떠 있을 때 이 UID의 cgroup을 실제로 본 기록. 없으면 UID를 잘못 적은 것과 구분할 수 없다.
    if grep -qs '^== 파드 cgroup: ' "$LOG_DIR"/node-live-"$uid"-*.txt; then live_seen=yes; fi
    k="4.node.파드-종료-뒤-cgroup-비었음"
    if [ "$live_seen" = no ]; then
      verdict "$k" "판단 필요" "UID $uid 의 파드 cgroup을 live로 본 기록이 $LOG_DIR 에 없다. UID가 틀려도 '비었다'로 보인다"
    elif [ "$can_see" = no ]; then
      verdict "$k" "판단 필요" "다른 프로세스를 보지 못해 '0개'를 믿을 수 없다"
    elif [ "$inside" -eq 0 ] && { [ -z "$pod_dir" ] || [ "$populated" = 0 ]; }; then
      miss="사라졌고"
      [ -n "$pod_dir" ] && miss="populated=0이고"
      verdict "$k" "됨" "live로 봤던 UID $uid 의 cgroup이 $miss, 그 cgroup에 든 시험 프로세스가 0개다"
    else
      verdict "$k" "안 됨" "populated=${populated:-?}, 그 cgroup에 남은 시험 프로세스 ${inside}개"
    fi
    k="4.node.파드-종료-뒤-경계-밖-후손-0개"
    if [ "$outside" -gt 0 ]; then
      verdict "$k" "안 됨" "파드 cgroup 밖에 시험 프로세스로 보이는 것이 ${outside}개 있다(위 줄)"
    elif [ "$live_seen" = no ] || [ "$can_see" = no ]; then
      verdict "$k" "판단 필요" "live로 본 기록이 없거나 다른 프로세스를 보지 못한다. '밖에 0개'를 믿을 수 없다"
    else
      verdict "$k" "됨" "파드 cgroup 밖의 시험 프로세스 0개"
    fi
  fi
}

# python3가 없으면 아무것도 찍지 않고 실패한다(날것을 찍는 것보다 낫다).
mkdir -p "$LOG_DIR"
main 2>&1 | python3 -I "$HERE/sanitize.py" | tee "$LOG_DIR/${synth}node-$mode-$uid-$(date -u +%Y%m%dT%H%M%SZ).txt"
