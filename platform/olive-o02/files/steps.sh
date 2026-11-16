#!/bin/bash
# shellcheck shell=bash
# 단계 함수. executor.sh가 source해서 실행기 프로세스 안에서 돈다. 이름은 step_<단계>(- 는 _).
# 출력 규칙: "결과 <키> <됨|안 됨|판단 필요> — 근거"는 안전한 쪽 성질의 판정이고, "사실 ..."은 판정 없는 관찰이다.
# 한 단계가 앞 단계의 상태를 가정하지 않게, 필요한 core와 터미널은 단계가 스스로 띄운다.
# shellcheck source=lib.sh
. /opt/o02/lib.sh

fact() { printf '사실 %s\n' "$*"; }

wait_file() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt "${2:-30}" ]; do
    sleep 1
    i=$((i + 1))
  done
  [ -e "$1" ]
}

ppid_of() { ps_dump | awk -v p="$1" '$1 == p { print $2 }'; }
cmd_of() { tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | cut -c1-80 | clean; }

ensure_s1() {
  if [ -z "$(prog_pids s1)" ]; then
    rec hcq run --bg --name s1 -- bash "$O02_PROG" sleeper s1
    sleep 2
  fi
}

# show_tree <판정 키>: 프로세스 표, core·holder pid, 소켓, 컨테이너 cgroup 안인지.
show_tree() {
  echo "-- 시험이 띄운 프로세스. PID 1은 init.sh, 실행기는 pid $$"
  ps_ours
  echo "-- core pid: $(core_pids | tr '\n' ' ') / holder pid: $(holder_pids | tr '\n' ' ')"
  echo "-- 소켓 폴더"
  ls_dir "$O02_ROOT/rt/herdr-core"
  if cgroup_inside; then
    verdict "$1" "됨" "컨테이너 안에서 본 cgroup.procs에 시험 프로세스가 모두 있다(노드에서 본 값으로 다시 확인한다)"
  else
    verdict "$1" "판단 필요" "컨테이너 안에서 확인하지 못했다. 노드에서 본 값이 기준이다"
  fi
}

run_envdump() { # <꼬리표> [client 환경에 넣을 표식]
  rm -f "$O02_OUT/env-$1.txt"
  if [ -n "${2:-}" ]; then
    rec env O02_FAKE_CRED="$2" timeout 20 "$HC" run --bg --name "env-$1" -- bash "$O02_PROG" envdump "$1"
  else
    rec hcq run --bg --name "env-$1" -- bash "$O02_PROG" envdump "$1"
  fi
  wait_file "$O02_OUT/env-$1.txt" 15
  sleep 1
  clean <"$O02_OUT/env-$1.txt" 2>/dev/null || echo "env-$1.txt가 없다(프로그램이 돌지 못했다)"
}
got_cred() { sed -n 's/^O02_FAKE_CRED=//p' "$O02_OUT/env-$1.txt" 2>/dev/null | head -n 1; }
got_override() { sed -n 's/^O02_FAKE_OVERRIDE=//p' "$O02_OUT/env-$1.txt" 2>/dev/null | head -n 1; }

# ---- 할 일 1·2: 파드 조건과 고정 버전

step_preflight() {
  local t missing="" got others
  echo "== 도구"
  for t in bash python3 setsid nohup timeout curl awk tr od find unshare; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  echo "없는 도구:${missing:- 없음}"
  got=$("$HC" --version 2>&1 | clean)
  if [ "$got" = "hc $O02_HC_VERSION" ]; then
    verdict "2.고정-버전" "됨" "$got"
  else
    verdict "2.고정-버전" "안 됨" "기대 hc $O02_HC_VERSION, 실제 $got"
  fi

  echo "== 신원과 권한(할 일 1)"
  rec id
  rec grep -E '^(Cap(Inh|Prm|Eff|Bnd|Amb)|NoNewPrivs|Seccomp):' /proc/self/status
  echo "AppArmor: $(clean </proc/self/attr/current 2>/dev/null)"
  if [ "$(id -u)" != 0 ] && grep -q '^CapEff:[[:space:]]*0000000000000000$' /proc/self/status && grep -q '^NoNewPrivs:[[:space:]]*1$' /proc/self/status; then
    verdict "1.비root-권한없음" "됨" "uid $(id -u), CapEff 0, NoNewPrivs 1"
  else
    verdict "1.비root-권한없음" "안 됨" "위 값을 본다"
  fi
  if touch /o02-rootfs-probe 2>/dev/null; then
    rm -f /o02-rootfs-probe
    verdict "1.읽기전용-root" "안 됨" "/ 에 파일을 만들 수 있다"
  else
    verdict "1.읽기전용-root" "됨" "/ 에 쓰지 못한다"
  fi
  if [ -e /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
    verdict "1.SA-토큰-없음" "안 됨" "토큰 파일이 있다"
  else
    verdict "1.SA-토큰-없음" "됨" "토큰 파일이 없다"
  fi
  # KUBERNETES_* 는 enableServiceLinks와 상관없이 kubelet이 넣는다.
  others=$(env | grep -c '_SERVICE_HOST=' || true)
  echo "환경의 *_SERVICE_HOST 변수 ${others}개(KUBERNETES_SERVICE_HOST 하나는 늘 있다)"
  if unshare -Ur true 2>/dev/null; then fact "권한 없는 user 네임스페이스를 만들 수 있다"; else fact "권한 없는 user 네임스페이스를 만들 수 없다(이 파드 설정으로는 bwrap 방식 가림을 못 쓴다)"; fi

  echo "== 컨테이너 안에서 본 cgroup 상한"
  for t in memory.max cpu.max pids.max memory.oom.group; do
    printf '%s: %s\n' "$t" "$(cat "/sys/fs/cgroup/$t" 2>&1 | clean)"
  done
  echo "== pty"
  rec python3 -c 'import os, pty; m, s = pty.openpty(); print("pty ok", os.ttyname(s))'
  echo "== 세션 폴더"
  ls_dir "$O02_ROOT"
  echo "== 프로세스"
  ps_dump
}

# ---- 할 일 3: 포함 관계

step_core_direct() {
  local m
  reset_state
  m=$(new_marker A)
  save_marker A "$m"
  echo "== 실행기(pid $$)가 core를 직접 띄운다"
  start_core "$m"
  rec hcq server status
  rec hcq run --bg --name s1 -- bash "$O02_PROG" sleeper s1
  sleep 2
  rec hcq ls
  show_tree "3.direct.컨테이너-cgroup-안"
  fact "직접 실행: core pid $(core_pids | tr '\n' ' ')의 부모 $(ppid_of "$(core_pids | head -n 1)"), holder pid $(holder_pids | tr '\n' ' ')의 부모 $(ppid_of "$(holder_pids | head -n 1)")"
}

step_core_auto() {
  local m
  reset_state
  m=$(new_marker A)
  save_marker A "$m"
  echo "== core 없이 client를 부른다(hc ls). client가 core를 띄운다"
  rec env O02_FAKE_CRED="$m" timeout 30 "$HC" ls
  wait_core 75 || echo "core가 뜨지 않았다"
  rec hcq run --bg --name s1 -- bash "$O02_PROG" sleeper s1
  sleep 2
  rec hcq ls
  show_tree "3.auto.컨테이너-cgroup-안"
  fact "자동 기동: core pid $(core_pids | tr '\n' ' ')의 부모 $(ppid_of "$(core_pids | head -n 1)"), holder pid $(holder_pids | tr '\n' ' ')의 부모 $(ppid_of "$(holder_pids | head -n 1)")"
}

# core에 신호를 보내고, client를 부르지 않은 채 holder가 core를 다시 띄우는지 본다.
core_signal() { # <TERM|KILL> <키>
  local sig=$1 key=$2 old new="" i=0 parent
  ensure_core
  ensure_s1
  old=$(core_pids | head -n 1)
  if [ -z "$old" ]; then
    echo "core pid를 찾지 못했다(명령줄 모양이 다를 수 있다). 프로세스 표:"
    ps_ours
    verdict "$key" "판단 필요" "core pid를 찾지 못해 신호를 보내지 않았다"
    return
  fi
  echo "== core(pid $old)에 SIG$sig"
  kill "-$sig" "$old"
  echo "== 30초 동안 client를 부르지 않고 지켜본다"
  while [ "$i" -lt 30 ]; do
    sleep 1
    i=$((i + 1))
    new=$(core_pids | grep -vx "$old" | head -n 1)
    [ -n "$new" ] && break
  done
  if [ -n "$new" ]; then
    parent=$(ppid_of "$new")
    fact "SIG$sig 뒤 ${i}초에 새 core(pid $new)가 client 호출 없이 떴다. 부모 pid $parent: $(cmd_of "$parent")"
  else
    fact "SIG$sig 뒤 30초 동안 새 core가 뜨지 않았다"
  fi
  if [ -n "$(prog_pids s1)" ]; then fact "SIG$sig 뒤 프로그램 s1은 살아 있다"; else fact "SIG$sig 뒤 프로그램 s1이 끝났다"; fi
  ps_ours
  echo "== client를 부른다(hc ls). core가 없으면 client가 띄운다"
  rec hcq ls
  show_tree "$key"
}

step_core_term() { core_signal TERM "4.core-TERM.뒤에도-컨테이너-cgroup-안"; }
step_core_kill() { core_signal KILL "4.core-KILL.뒤에도-컨테이너-cgroup-안"; }

step_holder_kill() {
  local hs h after
  ensure_core
  ensure_s1
  hs=$(holder_pids)
  if [ -z "$hs" ]; then
    echo "holder pid를 찾지 못했다. 프로세스 표:"
    ps_ours
    verdict "4.holder-KILL.후손-0개" "판단 필요" "holder pid를 찾지 못했다"
    return
  fi
  echo "== holder에 SIGKILL: $hs"
  for h in $hs; do kill -KILL "$h"; done
  sleep 4
  ps_ours
  after=$(prog_pids s1 | tr '\n' ' ')
  rec hcq ls --all
  if [ -n "$after" ]; then
    verdict "4.holder-KILL.후손-0개" "안 됨" "holder가 죽은 뒤 프로그램 s1(pid $after)이 남았다. 부모 pid $(ppid_of "${after%% *}"). hc 기록(위 ls --all)과 견준다"
  else
    verdict "4.holder-KILL.후손-0개" "됨" "holder가 죽자 프로그램 s1도 끝났다"
  fi
  show_tree "4.holder-KILL.뒤에도-컨테이너-cgroup-안"
}

step_outlive() {
  local d o
  ensure_core
  rec hcq run --bg --name par -- bash "$O02_PROG" parent o1
  sleep 5
  rec hcq ls
  ps_ours
  echo "== 부모 터미널을 끝낸다(hc kill par)"
  rec hcq kill par
  sleep 5
  rec hcq ls --all
  ps_ours
  d=$(prog_pids c-default-o1 | tr '\n' ' ')
  o=$(prog_pids c-outlive-o1 | tr '\n' ' ')
  fact "부모를 끝낸 뒤: 기본 자식 ${d:-없음}, --outlive-parent 자식 ${o:-없음}"
  if [ -z "$d" ]; then
    verdict "4.outlive.기본-자식은-부모와-끝남" "됨" "기본 자식 터미널의 프로그램이 남지 않았다"
  else
    verdict "4.outlive.기본-자식은-부모와-끝남" "안 됨" "기본 자식의 프로그램(pid $d)이 남았다"
  fi
  if [ -n "$o" ]; then
    fact "--outlive-parent 자식(pid $o)은 부모가 끝난 뒤에도 돈다. 실행기가 세션을 끝낼 때 따로 끝내야 한다"
  fi
  show_tree "4.outlive.뒤에도-컨테이너-cgroup-안"
}

# 세션을 분리한 후손. 남은 후손은 지우지 않는다. 이 단계 뒤에 파드를 지우고 노드에서 cgroup이 비는지 본다.
step_detach() {
  local left
  ensure_core
  rec hcq run --bg --name det -- bash "$O02_PROG" detacher d1
  sleep 4
  ps_ours
  echo "== 터미널을 끝낸다(hc kill det)"
  rec hcq kill det
  sleep 6
  echo "== hc의 기록"
  rec hcq ls --all
  echo "== 실제 프로세스"
  ps_ours
  left=$(pids_like '/opt/o02/prog\.sh [a-z]+ det-' | tr '\n' ' ')
  if [ -n "$left" ]; then
    verdict "4.detach.hc-종료-뒤-후손-0개" "안 됨" "hc가 터미널을 끝냈다고 한 뒤에도 후손이 남았다: pid $left(위 표의 det-* 줄). hc 0.1.19부터 분리한 프로그램은 터미널이 닫혀도 남는다(변경 기록)"
  else
    verdict "4.detach.hc-종료-뒤-후손-0개" "됨" "분리한 후손까지 모두 끝났다"
  fi
  show_tree "4.detach.남은-후손도-컨테이너-cgroup-안"
  echo "남은 후손을 지우지 않았다. 이어서 파드를 지우고 노드에서 그 파드 UID의 cgroup이 비는지 본다(TERM을 무시하는 det-stubborn 포함)."
}

# ---- 할 일 3: 파드 limits가 holder의 자식에도 걸리는지

step_limit_cpu() {
  local before after
  ensure_core
  echo "cpu.max: $(cat /sys/fs/cgroup/cpu.max 2>&1 | clean)"
  before=$(awk '$1 == "nr_throttled" { print $2 }' /sys/fs/cgroup/cpu.stat 2>/dev/null)
  rec hcq run --bg --name burn -- python3 "$O02_PY" burn 8
  sleep 11
  after=$(awk '$1 == "nr_throttled" { print $2 }' /sys/fs/cgroup/cpu.stat 2>/dev/null)
  echo "nr_throttled ${before:-?} -> ${after:-?}"
  if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ]; then
    verdict "3.limits.cpu" "됨" "hc 터미널 안 프로그램이 CPU를 쓰자 컨테이너 cgroup의 nr_throttled가 늘었다($before -> $after)"
  else
    verdict "3.limits.cpu" "판단 필요" "nr_throttled가 늘지 않았다. cpu.max와 노드에서 본 값을 본다"
  fi
}

# 마지막에 돌린다. memory.oom.group이 1이면 컨테이너의 모든 프로세스가 함께 죽고 컨테이너가 다시 뜬다.
step_limit_mem() {
  local max group cap before after="" i=0
  ensure_core
  max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
  group=$(cat /sys/fs/cgroup/memory.oom.group 2>/dev/null)
  echo "memory.max=$max memory.oom.group=${group:-?}"
  case "$max" in
    '' | *[!0-9]*)
      verdict "3.limits.memory" "안 됨" "컨테이너 cgroup의 memory.max가 숫자가 아니다($max). 프로그램을 돌리지 않았다"
      return
      ;;
  esac
  cap=$((max / 1048576 + 128))
  before=$(awk '$1 == "oom_kill" { print $2 }' /sys/fs/cgroup/memory.events 2>/dev/null)
  echo "oom_kill(전) ${before:-?}. hc 터미널 안에서 ${cap}MiB까지 잡는 프로그램을 돌린다"
  echo "이 줄 뒤로 결과가 끊기면 컨테이너가 통째로 OOM kill된 것이다(memory.oom.group=1). 그것도 상한이 걸린 증거다."
  echo "그때는 kubectl get pod의 재시작 횟수·마지막 종료 이유와 노드에서 본 파드 cgroup의 memory.events로 확인한다."
  rm -f "$O02_OUT/hog-cap-reached"
  rec hcq run --bg --name hog -- python3 "$O02_PY" hog "$cap"
  while [ "$i" -lt 90 ]; do
    sleep 1
    i=$((i + 1))
    after=$(awk '$1 == "oom_kill" { print $2 }' /sys/fs/cgroup/memory.events 2>/dev/null)
    [ "${after:-0}" -gt "${before:-0}" ] && break
    [ -e "$O02_OUT/hog-cap-reached" ] && break
  done
  echo "oom_kill(후) ${after:-?}, ${i}초"
  if [ -e "$O02_OUT/hog-cap-reached" ]; then
    verdict "3.limits.memory" "안 됨" "상한($max)을 넘겨 ${cap}MiB까지 잡았는데 죽지 않았다"
  elif [ "${after:-0}" -gt "${before:-0}" ]; then
    verdict "3.limits.memory" "됨" "holder의 자식이 상한에서 OOM kill됐다(oom_kill ${before:-?} -> $after)"
  else
    verdict "3.limits.memory" "판단 필요" "90초 안에 OOM kill도, 상한 넘김도 보지 못했다"
  fi
  ps_ours
}

# ---- 할 일 5: 소켓 가림(세션 컨테이너 안의 두 역할. 다른 컨테이너·파드는 밖에서 probe.sh를 직접 부른다)

step_hide() {
  local role
  ensure_core
  ensure_s1
  for role in model tool; do
    rm -f "$O02_OUT/probe-$role.txt" "$O02_OUT/probe-$role.txt.done"
    if [ "$role" = model ]; then
      echo "== 모델 역할: hc 터미널 안의 프로그램(core가 준 환경 그대로)"
      rec hcq run --bg --name probe-model -- bash /opt/o02/probe.sh model "$O02_OUT/probe-model.txt"
    else
      echo "== 도구 역할: hc 터미널 안, 환경을 비운 프로그램"
      rec hcq run --bg --name probe-tool -- env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash /opt/o02/probe.sh tool "$O02_OUT/probe-tool.txt"
    fi
    if wait_file "$O02_OUT/probe-$role.txt.done" 90; then
      clean <"$O02_OUT/probe-$role.txt"
    else
      echo "탐침이 90초 안에 끝나지 않았다. 지금까지:"
      clean <"$O02_OUT/probe-$role.txt" 2>/dev/null
      verdict "5.$role" "판단 필요" "탐침이 끝나지 않았다"
    fi
  done
}

# ---- 할 일 6: 자격과 상태 잔존

step_cred_new_core() {
  local a b got
  reset_state
  a=$(new_marker A)
  b=$(new_marker B)
  save_marker A "$a"
  save_marker B "$b"
  echo "== 세션 A: 표식 A를 core의 환경에만 넣어 띄운다"
  start_core "$a"
  run_envdump a1
  echo "== 세션 A를 끝낸다(터미널, core, holder까지). 상태 폴더는 지우지 않는다"
  full_stop
  ps_ours
  echo "== 세션 A가 끝난 뒤 hc 자리에 표식 A가 든 파일"
  grep_marker "$a"
  echo "== 세션 B: 새 core에 표식 B"
  start_core "$b"
  run_envdump b1
  got=$(got_cred b1)
  if [ "$got" = "$b" ]; then
    verdict "6.새-core는-이번-자격만" "됨" "새 core의 프로그램이 B를 받았다(A 아님)"
  else
    verdict "6.새-core는-이번-자격만" "안 됨" "새 core의 프로그램이 받은 값: ${got:-없음}(기대 B)"
  fi
  echo "== 세션 B가 떠 있는 지금 hc 자리에 표식 A가 든 파일"
  got=$(grep_marker "$a")
  echo "$got"
  if [ "$got" = "없음" ]; then
    verdict "6.앞-세션-자격이-상태에-안-남음" "됨" "상태를 지우지 않았는데도 표식 A가 든 파일이 없다"
  else
    verdict "6.앞-세션-자격이-상태에-안-남음" "안 됨" "표식 A가 위 파일에 남았다. 세션을 바꿀 때 상태 폴더도 새로 써야 한다"
  fi
  echo "== 표식 B가 든 파일(떠 있는 core의 환경이 디스크에 적히는가)"
  grep_marker "$b"
}

# cred-new-core 뒤에 돌린다(표식 B로 뜬 core가 있어야 한다).
step_cred_old_core() {
  local b c got
  b=$(cat "$O02_CTL/marker.B" 2>/dev/null)
  if [ -z "$b" ] || ! core_up; then
    verdict "6.기존-core" "판단 필요" "표식 B로 뜬 core가 없다. cred-new-core를 먼저 돌린다"
    return
  fi
  c=$(new_marker C)
  save_marker C "$c"
  echo "== 기존 core(B)에, 표식 C를 든 client가 프로그램을 띄운다"
  run_envdump c1 "$c"
  got=$(got_cred c1)
  if [ "$got" = "$b" ]; then
    fact "기존 core: client가 C를 들고 불러도 프로그램은 core의 B를 받는다(같은 core에서 자격을 바꿀 수 없다)"
  else
    fact "기존 core: client가 C를 들고 부르자 프로그램이 받은 값은 ${got:-없음}"
  fi
  echo "== hc server restart(환경 유지) 뒤"
  rec hcq server restart
  wait_core 75
  run_envdump c2
  fact "server restart 뒤 프로그램이 받은 값: $(got_cred c2)"
  echo "표식 B가 든 파일:"
  grep_marker "$b"
  echo "== 표식 C를 든 client가 hc server restart --fresh를 부른 뒤"
  rec env O02_FAKE_CRED="$c" timeout 30 "$HC" server restart --fresh
  wait_core 75
  run_envdump c3
  got=$(got_cred c3)
  if [ "$got" = "$c" ]; then
    verdict "6.client가-core-환경을-못-바꿈" "안 됨" "restart --fresh를 부른 client의 C가 새 터미널에 들어갔다. core 소켓에 닿는 쪽이 core의 환경을 바꿀 수 있다"
  else
    verdict "6.client가-core-환경을-못-바꿈" "됨" "restart --fresh 뒤에도 프로그램이 받은 값은 ${got:-없음}"
  fi
  echo "표식 B·C가 든 파일:"
  grep_marker "$b"
  grep_marker "$c"
}

step_cred_override() {
  local d e hit
  ensure_core
  d=$(new_marker D)
  e=$(new_marker E)
  save_marker D "$d"
  save_marker E "$e"
  echo "== API(terminal.run)의 env override로 표식 D를 넘긴다"
  rm -f "$O02_OUT/env-d1.txt"
  rec python3 "$O02_PY" apirun "$(find_sock || echo "$O02_SOCK")" env-d1 "$d" d1
  wait_file "$O02_OUT/env-d1.txt" 15
  sleep 1
  clean <"$O02_OUT/env-d1.txt" 2>/dev/null
  fact "env override로 프로그램이 받은 값: $(got_override d1)"
  echo "== argv에 표식 E를 넣어 띄운다"
  rec hcq run --bg --name argv-e1 -- bash "$O02_PROG" sleeper "$e"
  sleep 2
  echo "== 표식 D(env override)가 든 파일"
  hit=$(grep_marker "$d")
  echo "$hit"
  if [ "$hit" = "없음" ]; then
    verdict "6.env-override가-상태에-안-남음" "됨" "표식 D가 든 파일이 없다"
  else
    verdict "6.env-override가-상태에-안-남음" "안 됨" "env override가 위 파일에 남는다. 자격을 env override로 넘기면 안 된다(supervisor.md 2.2의 4)"
  fi
  echo "== 표식 E(argv)가 든 파일"
  hit=$(grep_marker "$e")
  echo "$hit"
  if [ "$hit" = "없음" ]; then
    verdict "6.argv가-상태에-안-남음" "됨" "표식 E가 든 파일이 없다"
  else
    verdict "6.argv가-상태에-안-남음" "안 됨" "argv가 위 파일에 남는다. 자격을 argv로 넘기면 안 된다"
  fi
}

# 종료·삭제·core 재시작·정지 뒤 남는 자리의 목록(O18에 넘긴다). cred-* 단계 뒤에 돌린다.
step_residue() {
  local f m name
  marker_report() {
    for f in "$O02_CTL"/marker.*; do
      [ -e "$f" ] || continue
      m=$(cat "$f")
      printf '표식 %s: %s\n' "${f##*.}" "$(grep_marker "$m" | tr '\n' ' ')"
    done
  }
  ensure_core
  echo "== 지금 hc 자리의 파일과 소켓"
  list_files
  echo "== 표식이 든 파일(터미널을 끝내기 전)"
  marker_report
  echo "== 시험이 연 터미널을 끝내고(kill) 지운다(rm)"
  for name in s1 par c-default-o1 c-outlive-o1 det env-a1 env-b1 env-c1 env-c2 env-c3 env-d1 argv-e1 in1 em1 burn hog probe-model probe-tool; do
    hcq kill "$name" >/dev/null 2>&1
    hcq rm "$name" >/dev/null 2>&1
  done
  sleep 2
  rec hcq ls --all
  echo "== 표식이 든 파일(kill·rm 뒤)"
  marker_report
  echo "== core 재시작 뒤"
  rec hcq server restart
  wait_core 75
  marker_report
  echo "== core 정지 뒤(프로세스까지 모두 끝낸다)"
  full_stop
  ps_ours
  marker_report
  echo "== 남은 파일과 소켓(정지 뒤)"
  list_files
  fact "위 목록이 hc 상태가 남는 자리다. 컨테이너 로그에 남는 것은 밖에서 kubectl logs로 본다(절차 문서)"
}

# ---- 할 일 7: 보기

step_view_noinput() {
  ensure_core
  rm -f "$O02_OUT/inputlog.jsonl"
  echo baseline >"$O02_OUT/phase"
  rec hcq run --bg --name in1 -- python3 "$O02_PY" inputlog "$O02_OUT/inputlog.jsonl" "$O02_OUT/phase"
  sleep 5
  echo "== 읽기 경로 1: hc read"
  echo read >"$O02_OUT/phase"
  REC_LINES=5 rec hcq read in1
  sleep 2
  echo "== 읽기 경로 2: hc attach --observe(관리자 단말 흉내가 키·붙여넣기·포커스·크기 변경·질의 답을 넣는다)"
  echo observe >"$O02_OUT/phase"
  rec python3 "$O02_PY" view observe in1 "$O02_OUT/observe-in1.bin" 9
  sleep 1
  echo quiet >"$O02_OUT/phase"
  sleep 3
  echo "== 대조군: hc attach(보기 전용 아님)에 같은 입력"
  echo control >"$O02_OUT/phase"
  rec python3 "$O02_PY" view control in1 "$O02_OUT/control-in1.bin" 9
  sleep 1
  echo after >"$O02_OUT/phase"
  sleep 2
  echo "== 프로그램이 받은 입력(구간별)"
  rec python3 "$O02_PY" viewcheck "$O02_OUT/inputlog.jsonl"
  hcq kill in1 >/dev/null 2>&1
}

step_view_ctrl() {
  ensure_core
  rec hcq run --bg --name em1 -- python3 "$O02_PY" emit
  sleep 3
  timeout 20 "$HC" read em1 >"$O02_OUT/read-em1.bin" 2>&1 </dev/null
  timeout 20 "$HC" read --json em1 >"$O02_OUT/readjson-em1.bin" 2>&1 </dev/null
  rec python3 "$O02_PY" view observe em1 "$O02_OUT/observe-em1.bin" 5
  echo "== 읽기 경로별 제어 문자(원시 바이트는 찍지 않고 센다)"
  rec python3 "$O02_PY" ctrlcount "7.read" "$O02_OUT/read-em1.bin"
  rec python3 "$O02_PY" ctrlcount "7.read-json" "$O02_OUT/readjson-em1.bin"
  rec python3 "$O02_PY" ctrlcount "7.observe" "$O02_OUT/observe-em1.bin"
  fact "관리자 쪽 정제는 아직 없다(homelab olive watch는 O09·O10이 만든다). 여기서는 정제 표본(o02.py sanitize_text)을 거치면 0개가 되는지만 봤다"
  hcq kill em1 >/dev/null 2>&1
}

# core가 없을 때 읽기 경로가 core를 띄우는지. 경로마다 core를 내린 뒤 하나씩 본다.
step_view_nocore() {
  local label spawned
  check() { # <이름> <명령...>
    label=$1
    shift
    full_stop
    if core_up || [ -n "$(core_pids)" ]; then
      verdict "7.nocore.$label" "판단 필요" "시작할 때 core를 내리지 못했다"
      return
    fi
    printf '$ %s\n' "$*"
    "$@" >/dev/null 2>&1 </dev/null
    sleep 3
    spawned=no
    if core_up || [ -n "$(core_pids)" ]; then spawned=yes; fi
    if [ "$spawned" = yes ]; then
      verdict "7.nocore.$label" "안 됨" "core가 없을 때 이 경로가 core를 띄웠다(pid $(core_pids | tr '\n' ' '))"
    else
      verdict "7.nocore.$label" "됨" "core를 띄우지 않았다"
    fi
  }
  check "server-status" timeout 10 "$HC" server status
  check "ls" timeout 10 "$HC" ls
  check "read" timeout 10 "$HC" read in1
  check "events" timeout 6 "$HC" events
  check "attach-observe" python3 "$O02_PY" view observe in1 "$O02_OUT/nocore.bin" 4
  check "소켓-직접-확인" python3 "$O02_PY" connect "$O02_SOCK"
  full_stop
}

step_summary() {
  local s
  for s in $O02_STEPS; do
    [ "$s" = summary ] && continue
    [ -e "$O02_OUT/$s.txt" ] || continue
    printf -- '-- %s\n' "$s"
    grep -E '^(결과|사실) ' "$O02_OUT/$s.txt" | clean
  done
}
