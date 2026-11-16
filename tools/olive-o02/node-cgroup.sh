#!/usr/bin/env bash
# 올리브 계획 O02: 노드(NUC)에서 본 파드 cgroup. sudo 없이 읽기만 한다(D-39의 노드 확인과 같은 방법).
#
#   node-cgroup.sh live <파드 UID>   파드가 떠 있을 때: 시험 프로세스가 모두 그 파드 cgroup 안인지, 상한이 무엇인지
#   node-cgroup.sh gone <파드 UID>   파드를 지운 뒤: 그 UID의 cgroup이 비었거나 사라졌는지, 시험 프로세스가 노드에 남았는지
#
# 파드 UID는 run.sh status가 찍는다. 지우기 전에 적어 둔다.
# 시험 프로세스는 명령줄의 /opt/o02/ 와 /opt/hc/ 로 찾는다(파드 안 고정 프로그램과 hc의 경로).
# 판정 줄의 "됨"은 안전한 쪽 성질이 성립한다는 뜻이다.
set -uo pipefail

mode=${1:-}
uid=${2:-}
if [[ ! $mode =~ ^(live|gone)$ || ! $uid =~ ^[0-9a-f-]{36}$ ]]; then
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
# systemd cgroup 드라이버는 UID의 - 를 _ 로 바꿔 쓴다. cgroupfs 드라이버는 그대로 쓴다.
uid_us=${uid//-/_}

verdict() { printf '결과 %s %s — %s\n' "$1" "$2" "$3"; }
show() { # <파일>: 값을 한 줄로
  if [ -r "$1" ]; then tr '\n' ' ' <"$1"; else printf '(못 읽음)'; fi
}

pod_dir=$(find /sys/fs/cgroup -maxdepth 4 -type d \( -name "*pod${uid_us}*" -o -name "*pod${uid}*" \) 2>/dev/null | head -n 1)

populated=""
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
        [ -n "$pid" ] || continue
        nspid=$(awk '/^NSpid:/ { print $NF }' "/proc/$pid/status" 2>/dev/null)
        printf '   pid %s (파드 안 pid %s) %s\n' "$pid" "${nspid:-?}" "$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | cut -c1-90)"
      done <"${c}cgroup.procs"
    else
      echo "   cgroup.procs를 읽지 못했다"
    fi
  done
else
  echo "== 파드 cgroup 폴더가 없다(UID $uid)"
fi

echo "== 노드의 모든 프로세스에서 시험 프로세스 찾기"
inside=0
other_pod=0
outside=0
for d in /proc/[0-9]*; do
  cmd=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue
  case "$cmd" in
    *"/opt/o02/"* | *"/opt/hc/"*) ;;
    *) continue ;;
  esac
  cg=$(sed -n 's/^0:://p' "$d/cgroup" 2>/dev/null)
  case "$cg" in
    *"$uid_us"* | *"$uid"*)
      inside=$((inside + 1))
      ;;
    *kubepods*)
      other_pod=$((other_pod + 1))
      printf '다른 파드의 cgroup: pid %s %s :: %s\n' "${d#/proc/}" "$cg" "$(printf '%s' "$cmd" | cut -c1-90)"
      ;;
    *)
      outside=$((outside + 1))
      printf '파드 cgroup 밖: pid %s %s :: %s\n' "${d#/proc/}" "${cg:-(못 읽음)}" "$(printf '%s' "$cmd" | cut -c1-90)"
      ;;
  esac
done
echo "이 파드 cgroup 안 $inside개, 다른 파드 cgroup $other_pod개, 파드 cgroup 밖 $outside개"
echo "(파드 cgroup 밖으로 나온 줄이 이 명령을 돌린 쪽의 편집기·검색 명령이면 시험 프로세스가 아니다. 명령줄로 가린다)"

if [ "$mode" = live ]; then
  if [ -z "$pod_dir" ]; then
    verdict "3.node.시험-프로세스-모두-파드-cgroup-안" "판단 필요" "파드 cgroup 폴더를 찾지 못했다. UID와 cgroup 배치를 본다"
  elif [ "$inside" -gt 0 ] && [ "$outside" -eq 0 ]; then
    verdict "3.node.시험-프로세스-모두-파드-cgroup-안" "됨" "시험 프로세스 ${inside}개가 모두 이 파드 cgroup 안이다(다른 파드 ${other_pod}개는 대조 컨테이너·대조 파드인지 위 줄로 본다)"
  elif [ "$outside" -gt 0 ]; then
    verdict "3.node.시험-프로세스-모두-파드-cgroup-안" "안 됨" "파드 cgroup 밖에 ${outside}개가 있다(위 줄)"
  else
    verdict "3.node.시험-프로세스-모두-파드-cgroup-안" "판단 필요" "시험 프로세스를 하나도 찾지 못했다"
  fi
else
  if [ "$inside" -eq 0 ] && { [ -z "$pod_dir" ] || [ "$populated" = 0 ]; }; then
    state="사라졌고"
    [ -n "$pod_dir" ] && state="populated=0이고"
    verdict "4.node.파드-종료-뒤-cgroup-비었음" "됨" "UID $uid 의 cgroup이 $state, 그 cgroup에 든 시험 프로세스가 0개다"
  else
    verdict "4.node.파드-종료-뒤-cgroup-비었음" "안 됨" "populated=${populated:-?}, 그 cgroup에 남은 시험 프로세스 ${inside}개"
  fi
  if [ "$outside" -gt 0 ]; then
    verdict "4.node.파드-종료-뒤-경계-밖-후손-0개" "안 됨" "파드 cgroup 밖에 시험 프로세스로 보이는 것이 ${outside}개 있다(위 줄)"
  else
    verdict "4.node.파드-종료-뒤-경계-밖-후손-0개" "됨" "파드 cgroup 밖의 시험 프로세스 0개"
  fi
fi
