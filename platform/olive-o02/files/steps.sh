#!/bin/bash
# shellcheck shell=bash
# 단계 함수. executor.sh가 source해서 실행기 프로세스 안에서 돈다. 이름은 step_<단계>(- 는 _).
# 출력 규칙: "결과 <키> <됨|안 됨|판단 필요> — 근거"는 안전한 쪽 성질의 판정이고, "사실 ..."은 판정 없는 관찰이다.
# 한 단계가 앞 단계의 상태를 가정하지 않게, 필요한 core와 터미널은 단계가 스스로 띄운다.
# 판정 규칙: "됨"은 준비·조작이 성공했고 양성 증거(프로그램이 떴다, 기대한 표식을 받았다, 끝내기 전에 pid가 있었다)를 본 뒤에만 낸다.
# set -e를 쓰지 않으므로 앞 명령의 실패가 그대로 지나간다. "없다", "안 보인다"는 시험이 돌지 못해도 나오는 값이라, 그것만으로는 "판단 필요"다.
# shellcheck source=lib.sh
. /opt/o02/lib.sh

fact() { printf '사실 %s\n' "$*"; }

# undecided <근거> <키...>: 준비나 조작이 실패해 볼 수 없었던 판정을 "판단 필요"로 끝낸다.
undecided() {
  local why=$1 k
  shift
  for k in "$@"; do verdict "$k" "판단 필요" "$why"; done
}

wait_file() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt "${2:-30}" ]; do
    sleep 1
    i=$((i + 1))
  done
  [ -e "$1" ]
}

ppid_of() { ps_dump | awk -v p="$1" '$1 == p { print $2 }'; }
cmd_of() { tr '\0' ' ' 2>/dev/null <"/proc/$1/cmdline" | cut -c1-80 | clean; }
one_line() { tr '\n' ' '; }

# run_bg <이름> <프로그램...>: hc 터미널에서 프로그램을 띄운다. hc가 실패하면 그 종료 코드를 돌려준다.
run_bg() {
  local name=$1
  shift
  rec hcq run --bg --name "$name" -- "$@"
}

# 프로그램 s1이 실제로 떠 있을 때만 0.
ensure_s1() {
  [ -n "$(prog_pids s1)" ] && return 0
  run_bg s1 bash "$O02_PROG" sleeper s1
  wait_role prog:s1 10
}

# show_tree <판정 키> <기대 역할...>: 프로세스 표, core·holder pid, 소켓, 컨테이너 cgroup 안인지.
# "역할표" 줄은 노드의 node-cgroup.sh에 넘겨 같은 프로세스가 파드 cgroup 안인지 대조하는 데 쓴다.
show_tree() {
  local key=$1 roles="core holder" r
  shift
  for r in "$@"; do
    case " $roles " in
      *" $r "*) ;;
      *) roles="$roles $r" ;;
    esac
  done
  echo "-- 시험이 띄운 프로세스. PID 1은 init.sh, 실행기는 pid $$"
  ps_ours
  echo "-- core pid: $(core_pids | one_line) / holder pid: $(holder_pids | one_line)"
  echo "-- 소켓 폴더"
  ls_dir "$O02_ROOT/rt/herdr-core"
  # shellcheck disable=SC2086
  fact "역할표 $(role_table $roles)"
  if cgroup_inside "$@"; then
    verdict "$key" "됨" "기대 역할($*)이 모두 떠 있고, 컨테이너 안에서 본 cgroup.procs에 시험 프로세스가 모두 있다(노드에서 본 값으로 다시 확인한다)"
  else
    verdict "$key" "판단 필요" "기대 역할($*)이 없거나 컨테이너 안에서 확인하지 못했다(위 줄). 노드에서 본 값이 기준이다"
  fi
}

# run_envdump <꼬리표> [client 환경에 넣을 표식]: 프로그램이 돌아 env-<꼬리표>.txt를 남겼을 때만 0.
run_envdump() {
  local rc
  rm -f "$O02_OUT/env-$1.txt"
  if [ -n "${2:-}" ]; then
    rec env O02_FAKE_CRED="$2" timeout 20 "$HC" run --bg --name "env-$1" -- bash "$O02_PROG" envdump "$1"
  else
    run_bg "env-$1" bash "$O02_PROG" envdump "$1"
  fi
  rc=$?
  if [ "$rc" -ne 0 ] || ! wait_file "$O02_OUT/env-$1.txt" 15; then
    echo "env-$1.txt가 없다(hc run exit $rc, 프로그램이 돌지 못했다)"
    return 1
  fi
  sleep 1
  clean <"$O02_OUT/env-$1.txt"
}
# 출력 파일이 없으면 빈 값이다. 빈 값은 "표식을 받지 않았다"가 아니라 "보지 못했다"다.
got_cred() { sed -n 's/^O02_FAKE_CRED=//p' "$O02_OUT/env-$1.txt" 2>/dev/null | head -n 1; }
got_override() { sed -n 's/^O02_FAKE_OVERRIDE=//p' "$O02_OUT/env-$1.txt" 2>/dev/null | head -n 1; }

# judge_absent <키> <grep_marker 결과> <전제가 깨진 이유(없으면 빈 값)> <됨 근거> <안 됨 근거>
# 표식이 상태에 "없다"는 것은 표식이 실제로 hc에 들어갔고 볼 상태 파일이 있을 때만 증거다.
judge_absent() {
  local n
  n=$(state_file_count)
  if [ "$2" != "없음" ]; then
    verdict "$1" "안 됨" "$5"
  elif [ -n "$3" ]; then
    verdict "$1" "판단 필요" "$3"
  elif [ "$n" -eq 0 ]; then
    verdict "$1" "판단 필요" "hc 상태 파일을 하나도 찾지 못했다(볼 자리가 틀렸을 수 있다)"
  else
    verdict "$1" "됨" "$4(상태 파일 ${n}개를 봤다)"
  fi
}

# root_mount_state [mountinfo 파일]: / 에 붙은 마운트의 옵션에서 ro·rw를 읽는다. 못 읽으면 unknown.
# 같은 자리에 겹쳐 붙은 것이 있으면 마지막 줄이 지금 보이는 마운트다.
root_mount_state() {
  local info=${1:-/proc/self/mountinfo}
  if [ ! -r "$info" ]; then
    echo unknown
    return
  fi
  awk '$5 == "/" { o = $6 } END { n = split(o, a, ","); r = "unknown"; for (i = 1; i <= n; i++) if (a[i] == "ro" || a[i] == "rw") r = a[i]; print r }' "$info"
}

# rootfs_verdict <마운트 상태 ro|rw|unknown> <쓰기 시도 ok|EROFS|EACCES|...>: 판정 낱말을 낸다.
# 쓰기 실패만으로는 읽기 전용이 아니다. uid 10001은 root 소유의 / 에 원래 못 쓴다(EACCES). 읽기 전용 마운트면 권한 검사보다 먼저 EROFS가 난다.
rootfs_verdict() {
  if [ "$2" = ok ] || [ "$1" = rw ]; then
    echo "안 됨"
  elif [ "$1" = ro ] && [ "$2" = EROFS ]; then
    echo "됨"
  else
    echo "판단 필요"
  fi
}

# ---- 할 일 1·2: 파드 조건과 고정 버전

step_preflight() {
  local t missing="" got others mstate wstate
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
  mstate=$(root_mount_state)
  wstate=$(python3 "$O02_PY" trycreate /o02-rootfs-probe 2>/dev/null | clean | head -n 1)
  echo "/ 마운트 옵션: $mstate, / 에 파일 만들기: ${wstate:-시도 못 함}"
  verdict "1.읽기전용-root" "$(rootfs_verdict "$mstate" "${wstate:-none}")" "mountinfo의 / 마운트가 $mstate, 파일 만들기 결과 ${wstate:-시도 못 함}(됨은 ro와 EROFS가 함께일 때만)"
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

# 노드 IP의 kube API(6443)·kubelet(10250) 경로. NetworkPolicy로 닫히지 않고 호스트 방화벽이 모든 파드에 여는 길이다
# (templates/networkpolicy.yaml 머리 주석). TCP 연결만 해 본다. 안전성 판정이 아니라 사실로 남긴다.
step_node_path() {
  echo "== 세션 컨테이너에서 노드 API 경로에 TCP 연결(보내는 것은 없다)"
  rec python3 "$O02_PY" nodepath session
}

# ---- 할 일 3: 포함 관계

step_core_direct() {
  local m key="3.direct.컨테이너-cgroup-안"
  reset_state
  m=$(new_marker A)
  save_marker A "$m"
  echo "== 실행기(pid $$)가 core를 직접 띄운다"
  if ! start_core "$m"; then
    undecided "core를 띄우지 못했다" "$key"
    return
  fi
  rec hcq server status
  ensure_s1 || echo "프로그램 s1이 뜨지 않았다"
  rec hcq ls
  show_tree "$key" core holder prog:s1
  fact "직접 실행: core pid $(core_pids | one_line)의 부모 $(ppid_of "$(core_pids | head -n 1)"), holder pid $(holder_pids | one_line)의 부모 $(ppid_of "$(holder_pids | head -n 1)")"
}

step_core_auto() {
  local m key="3.auto.컨테이너-cgroup-안"
  reset_state
  m=$(new_marker A)
  save_marker A "$m"
  echo "== core 없이 client를 부른다(hc ls). client가 core를 띄운다"
  rec env O02_FAKE_CRED="$m" timeout 30 "$HC" ls
  if ! wait_core 75; then
    undecided "client를 불렀는데 core가 뜨지 않았다" "$key"
    return
  fi
  ensure_s1 || echo "프로그램 s1이 뜨지 않았다"
  rec hcq ls
  show_tree "$key" core holder prog:s1
  fact "자동 기동: core pid $(core_pids | one_line)의 부모 $(ppid_of "$(core_pids | head -n 1)"), holder pid $(holder_pids | one_line)의 부모 $(ppid_of "$(holder_pids | head -n 1)")"
}

# core에 신호를 보내고, client를 부르지 않은 채 holder가 core를 다시 띄우는지 본다.
core_signal() { # <TERM|KILL> <키>
  local sig=$1 key=$2 old new="" i=0 parent
  if ! ensure_core || ! ensure_s1; then
    undecided "core나 프로그램 s1을 띄우지 못했다" "$key"
    return
  fi
  old=$(core_pids | head -n 1)
  if [ -z "$old" ]; then
    echo "core pid를 찾지 못했다(명령줄 모양이 다를 수 있다). 프로세스 표:"
    ps_ours
    verdict "$key" "판단 필요" "core pid를 찾지 못해 신호를 보내지 않았다"
    return
  fi
  echo "== core(pid $old)에 SIG$sig. 그 전 프로그램 s1 pid $(prog_pids s1 | one_line)"
  if ! kill "-$sig" "$old"; then
    undecided "core(pid $old)에 신호를 보내지 못했다" "$key"
    return
  fi
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
  if core_pids | grep -qx "$old"; then
    fact "SIG$sig 뒤에도 옛 core(pid $old)가 살아 있다"
    ps_ours
    undecided "core가 신호에 끝나지 않아 '신호 뒤'의 상태를 보지 못했다" "$key"
    return
  fi
  if [ -n "$(prog_pids s1)" ]; then fact "SIG$sig 뒤 프로그램 s1은 살아 있다"; else fact "SIG$sig 뒤 프로그램 s1이 끝났다(신호 전에는 살아 있었다)"; fi
  ps_ours
  echo "== client를 부른다(hc ls). core가 없으면 client가 띄운다"
  rec hcq ls
  show_tree "$key" core
}

step_core_term() { core_signal TERM "4.core-TERM.뒤에도-컨테이너-cgroup-안"; }
step_core_kill() { core_signal KILL "4.core-KILL.뒤에도-컨테이너-cgroup-안"; }

step_holder_kill() {
  local hs h before after still="" k1="4.holder-KILL.후손-0개" k2="4.holder-KILL.뒤에도-컨테이너-cgroup-안"
  if ! ensure_core || ! ensure_s1; then
    undecided "core나 프로그램 s1을 띄우지 못했다" "$k1" "$k2"
    return
  fi
  hs=$(holder_pids | one_line)
  before=$(prog_pids s1 | one_line)
  if [ -z "$hs" ] || [ -z "$before" ]; then
    echo "holder pid나 프로그램 s1의 pid를 찾지 못했다. 프로세스 표:"
    ps_ours
    undecided "holder pid(${hs:-없음})나 죽이기 전 프로그램 pid(${before:-없음})를 찾지 못했다" "$k1" "$k2"
    return
  fi
  echo "== holder에 SIGKILL: $hs(그 전 프로그램 s1 pid $before)"
  for h in $hs; do kill -KILL "$h"; done
  sleep 4
  ps_ours
  for h in $hs; do
    if holder_pids | grep -qx "$h"; then still="$still $h"; fi
  done
  after=$(prog_pids s1 | one_line)
  rec hcq ls --all
  if [ -n "$after" ]; then
    verdict "$k1" "안 됨" "holder가 죽은 뒤 프로그램 s1(pid $after)이 남았다. 부모 pid $(ppid_of "${after%% *}"). hc 기록(위 ls --all)과 견준다"
  elif [ -n "$still" ]; then
    verdict "$k1" "판단 필요" "KILL을 보냈는데 holder(pid$still)가 살아 있다. holder가 죽은 뒤를 보지 못했다"
  else
    verdict "$k1" "됨" "holder(pid $hs)가 죽자, 그 전에 살아 있던 프로그램 s1(pid $before)도 끝났다"
  fi
  # 남은 것의 포함 관계를 본다. 프로그램이 남았으면 그 프로그램이, 아니면 core가 볼 대상이다.
  if [ -n "$after" ]; then show_tree "$k2" prog:s1; else show_tree "$k2" core; fi
}

step_outlive() {
  local d o k1="4.outlive.기본-자식은-부모와-끝남" k2="4.outlive.뒤에도-컨테이너-cgroup-안"
  if ! ensure_core; then
    undecided "core를 띄우지 못했다" "$k1" "$k2"
    return
  fi
  if ! run_bg par bash "$O02_PROG" parent o1 || ! wait_role prog:o1 10 || ! wait_role prog:c-default-o1 10; then
    ps_ours
    undecided "부모 터미널이나 기본 자식이 뜨지 않았다(끝내기 전 pid를 보지 못했다)" "$k1" "$k2"
    return
  fi
  wait_role prog:c-outlive-o1 10 || fact "--outlive-parent 자식이 뜨지 않았다"
  rec hcq ls
  ps_ours
  fact "부모를 끝내기 전: 부모 $(prog_pids o1 | one_line), 기본 자식 $(prog_pids c-default-o1 | one_line), --outlive-parent 자식 $(prog_pids c-outlive-o1 | one_line)"
  echo "== 부모 터미널을 끝낸다(hc kill par)"
  if ! rec hcq kill par; then
    undecided "hc kill par가 실패했다" "$k1" "$k2"
    return
  fi
  sleep 5
  rec hcq ls --all
  ps_ours
  if [ -n "$(prog_pids o1)" ]; then
    undecided "hc kill 뒤에도 부모 프로그램이 살아 있다. 부모가 끝난 뒤를 보지 못했다" "$k1" "$k2"
    return
  fi
  d=$(prog_pids c-default-o1 | one_line)
  o=$(prog_pids c-outlive-o1 | one_line)
  fact "부모를 끝낸 뒤: 기본 자식 ${d:-없음}, --outlive-parent 자식 ${o:-없음}"
  if [ -z "$d" ]; then
    verdict "$k1" "됨" "부모가 끝나자, 그 전에 살아 있던 기본 자식 터미널의 프로그램도 끝났다"
  else
    verdict "$k1" "안 됨" "기본 자식의 프로그램(pid $d)이 남았다"
  fi
  if [ -n "$o" ]; then
    fact "--outlive-parent 자식(pid $o)은 부모가 끝난 뒤에도 돈다. 실행기가 세션을 끝낼 때 따로 끝내야 한다"
  fi
  show_tree "$k2" core prog:c-outlive-o1
}

# 세션을 분리한 후손. 남은 후손은 지우지 않는다. 이 단계 뒤에 파드를 지우고 노드에서 cgroup이 비는지 본다.
step_detach() {
  local left t lack="" k1="4.detach.hc-종료-뒤-후손-0개" k2="4.detach.남은-후손도-컨테이너-cgroup-안"
  if ! ensure_core; then
    undecided "core를 띄우지 못했다" "$k1" "$k2"
    return
  fi
  if ! run_bg det bash "$O02_PROG" detacher d1; then
    undecided "hc run이 실패해 후손을 띄우지 못했다" "$k1" "$k2"
    return
  fi
  wait_role prog:d1 10 || lack=" detacher"
  for t in det-setsid-d1 det-nohup-d1 det-daemon-d1 det-stubborn-d1 det-child-d1; do
    wait_role "prog:$t" 6 || lack="$lack $t"
  done
  ps_ours
  if [ -n "$lack" ]; then
    undecided "터미널을 끝내기 전에 떠 있어야 할 것이 없다:$lack. 후손이 처음부터 없으면 '0개'는 증거가 아니다" "$k1" "$k2"
    return
  fi
  fact "터미널을 끝내기 전 후손 pid: $(role_pids det | one_line)"
  echo "== 터미널을 끝낸다(hc kill det)"
  if ! rec hcq kill det; then
    undecided "hc kill det이 실패했다" "$k1" "$k2"
    return
  fi
  sleep 6
  echo "== hc의 기록"
  rec hcq ls --all
  echo "== 실제 프로세스"
  ps_ours
  if [ -n "$(prog_pids d1)" ]; then
    undecided "hc kill 뒤에도 터미널의 프로그램(detacher)이 살아 있다. 터미널이 끝난 뒤를 보지 못했다" "$k1" "$k2"
    return
  fi
  left=$(role_pids det | one_line)
  if [ -n "$left" ]; then
    verdict "$k1" "안 됨" "hc가 터미널을 끝냈다고 한 뒤에도 후손이 남았다: pid $left(위 표의 det-* 줄). hc 0.1.19부터 분리한 프로그램은 터미널이 닫혀도 남는다(변경 기록)"
  else
    verdict "$k1" "됨" "끝내기 전에 떠 있던 후손 다섯이 터미널 종료 뒤 모두 끝났다"
  fi
  show_tree "$k2" det
  echo "남은 후손을 지우지 않았다. 이어서 파드를 지우고 노드에서 그 파드 UID의 cgroup이 비는지 본다(TERM을 무시하는 det-stubborn 포함)."
}

# ---- 할 일 3: 파드 limits가 holder의 자식에도 걸리는지

step_limit_cpu() {
  local before after bp key="3.limits.cpu"
  if ! ensure_core; then
    undecided "core를 띄우지 못했다" "$key"
    return
  fi
  echo "cpu.max: $(cat /sys/fs/cgroup/cpu.max 2>&1 | clean)"
  before=$(awk '$1 == "nr_throttled" { print $2 }' /sys/fs/cgroup/cpu.stat 2>/dev/null)
  if ! run_bg burn python3 "$O02_PY" burn 8 || ! wait_role py:burn 5; then
    undecided "CPU를 쓰는 프로그램이 hc 터미널에서 돌지 못했다" "$key"
    return
  fi
  bp=$(role_pids py:burn | head -n 1)
  fact "CPU를 쓰는 프로그램 pid $bp, 부모 pid $(ppid_of "$bp"): $(cmd_of "$(ppid_of "$bp")")"
  sleep 11
  after=$(awk '$1 == "nr_throttled" { print $2 }' /sys/fs/cgroup/cpu.stat 2>/dev/null)
  echo "nr_throttled ${before:-?} -> ${after:-?}"
  if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ]; then
    verdict "$key" "됨" "hc 터미널 안 프로그램이 CPU를 쓰자 컨테이너 cgroup의 nr_throttled가 늘었다($before -> $after)"
  else
    verdict "$key" "판단 필요" "nr_throttled가 늘지 않았다. cpu.max와 노드에서 본 값을 본다"
  fi
}

# 마지막에 돌린다. memory.oom.group이 1이면 컨테이너의 모든 프로세스가 함께 죽고 컨테이너가 다시 뜬다.
step_limit_mem() {
  local max group cap before after="" i=0 key="3.limits.memory"
  if ! ensure_core; then
    undecided "core를 띄우지 못했다" "$key"
    return
  fi
  max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
  group=$(cat /sys/fs/cgroup/memory.oom.group 2>/dev/null)
  echo "memory.max=$max memory.oom.group=${group:-?}"
  case "$max" in
    '' | *[!0-9]*)
      verdict "$key" "안 됨" "컨테이너 cgroup의 memory.max가 숫자가 아니다($max). 프로그램을 돌리지 않았다"
      return
      ;;
  esac
  cap=$((max / 1048576 + 128))
  before=$(awk '$1 == "oom_kill" { print $2 }' /sys/fs/cgroup/memory.events 2>/dev/null)
  case "$before" in
    '' | *[!0-9]*)
      undecided "memory.events의 oom_kill을 읽지 못했다. 늘었는지 견줄 기준이 없어 프로그램을 돌리지 않았다" "$key"
      return
      ;;
  esac
  echo "oom_kill(전) $before. hc 터미널 안에서 ${cap}MiB까지 잡는 프로그램을 돌린다"
  echo "이 줄 뒤로 결과가 끊기면 컨테이너가 통째로 OOM kill된 것이다(memory.oom.group=1). 그것도 상한이 걸린 증거다."
  echo "그때는 kubectl get pod의 재시작 횟수·마지막 종료 이유와 노드에서 본 파드 cgroup의 memory.events로 확인한다."
  rm -f "$O02_OUT/hog-cap-reached"
  if ! run_bg hog python3 "$O02_PY" hog "$cap" || ! wait_role py:hog 5; then
    undecided "메모리를 잡는 프로그램이 hc 터미널에서 돌지 못했다" "$key"
    return
  fi
  while [ "$i" -lt 90 ]; do
    sleep 1
    i=$((i + 1))
    after=$(awk '$1 == "oom_kill" { print $2 }' /sys/fs/cgroup/memory.events 2>/dev/null)
    [ "${after:-0}" -gt "$before" ] && break
    [ -e "$O02_OUT/hog-cap-reached" ] && break
  done
  echo "oom_kill(후) ${after:-?}, ${i}초"
  if [ -e "$O02_OUT/hog-cap-reached" ]; then
    verdict "$key" "안 됨" "상한($max)을 넘겨 ${cap}MiB까지 잡았는데 죽지 않았다"
  elif [ "${after:-0}" -gt "$before" ]; then
    verdict "$key" "됨" "holder의 자식이 상한에서 OOM kill됐다(oom_kill $before -> $after)"
  else
    verdict "$key" "판단 필요" "90초 안에 OOM kill도, 상한 넘김도 보지 못했다"
  fi
  ps_ours
}

# ---- 할 일 5: 소켓 가림(세션 컨테이너 안의 두 역할. 다른 컨테이너·파드는 밖에서 probe.sh를 직접 부른다)

step_hide() {
  local role rc
  if ! ensure_core || ! ensure_s1; then
    undecided "core나 프로그램 s1을 띄우지 못했다" "5.model" "5.tool"
    return
  fi
  for role in model tool; do
    rm -f "$O02_OUT/probe-$role.txt" "$O02_OUT/probe-$role.txt.done"
    if [ "$role" = model ]; then
      echo "== 모델 역할: hc 터미널 안의 프로그램(core가 준 환경 그대로)"
      run_bg probe-model bash /opt/o02/probe.sh model "$O02_OUT/probe-model.txt"
      rc=$?
    else
      echo "== 도구 역할: hc 터미널 안, 환경을 비운 프로그램"
      run_bg probe-tool env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash /opt/o02/probe.sh tool "$O02_OUT/probe-tool.txt"
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      undecided "탐침을 hc 터미널에서 띄우지 못했다(hc run exit $rc)" "5.$role"
    elif wait_file "$O02_OUT/probe-$role.txt.done" 90; then
      clean <"$O02_OUT/probe-$role.txt"
    else
      echo "탐침이 90초 안에 끝나지 않았다. 지금까지:"
      clean 2>/dev/null <"$O02_OUT/probe-$role.txt"
      verdict "5.$role" "판단 필요" "탐침이 끝나지 않았다"
    fi
  done
}

# ---- 할 일 6: 자격과 상태 잔존

step_cred_new_core() {
  local a b got gota why="" k1="6.새-core는-이번-자격만" k2="6.앞-세션-자격이-상태에-안-남음"
  reset_state
  a=$(new_marker A)
  b=$(new_marker B)
  save_marker A "$a"
  save_marker B "$b"
  echo "== 세션 A: 표식 A를 core의 환경에만 넣어 띄운다"
  if ! start_core "$a"; then
    undecided "세션 A의 core를 띄우지 못했다" "$k1" "$k2"
    return
  fi
  run_envdump a1
  gota=$(got_cred a1)
  if [ "$gota" != "$a" ]; then
    why="세션 A의 프로그램이 표식 A를 받지 못했다(받은 값: ${gota:-출력 없음}). A가 hc에 들어갔다는 증거가 없다"
    echo "$why"
  fi
  echo "== 세션 A를 끝낸다(터미널, core, holder까지). 상태 폴더는 지우지 않는다"
  full_stop
  ps_ours
  if core_up || [ -n "$(core_pids)" ]; then
    undecided "세션 A의 core를 내리지 못했다" "$k1" "$k2"
    return
  fi
  echo "== 세션 A가 끝난 뒤 hc 자리에 표식 A가 든 파일"
  grep_marker "$a"
  echo "== 세션 B: 새 core에 표식 B"
  if ! start_core "$b"; then
    undecided "세션 B의 core를 띄우지 못했다" "$k1" "$k2"
    return
  fi
  run_envdump b1
  got=$(got_cred b1)
  if [ "$got" = "$b" ]; then
    verdict "$k1" "됨" "새 core의 프로그램이 B를 받았다(A 아님)"
  elif [ "$got" = "$a" ]; then
    verdict "$k1" "안 됨" "새 core의 프로그램이 앞 세션의 A를 받았다"
  else
    verdict "$k1" "판단 필요" "새 core의 프로그램이 받은 값: ${got:-출력 없음}. B도 A도 아니라 판정할 수 없다"
  fi
  echo "== 세션 B가 떠 있는 지금 hc 자리에 표식 A가 든 파일"
  got=$(grep_marker "$a")
  echo "$got"
  judge_absent "$k2" "$got" "$why" "A를 받은 세션을 끝낸 뒤, 상태를 지우지 않았는데도 표식 A가 든 파일이 없다" "표식 A가 위 파일에 남았다. 세션을 바꿀 때 상태 폴더도 새로 써야 한다"
  echo "== 표식 B가 든 파일(떠 있는 core의 환경이 디스크에 적히는가)"
  grep_marker "$b"
}

# cred-new-core 뒤에 돌린다(표식 B로 뜬 core가 있어야 한다).
step_cred_old_core() {
  local b c got rc oldcore newcore k="6.client가-core-환경을-못-바꿈"
  b=$(cat "$O02_CTL/marker.B" 2>/dev/null)
  if [ -z "$b" ] || ! core_up; then
    undecided "표식 B로 뜬 core가 없다. cred-new-core를 먼저 돌린다" "6.기존-core" "$k"
    return
  fi
  echo "== 지금 core의 프로그램이 표식 B를 받는지 먼저 본다"
  run_envdump c0
  got=$(got_cred c0)
  if [ "$got" != "$b" ]; then
    undecided "지금 core의 프로그램이 B를 받지 않는다(받은 값: ${got:-출력 없음}). cred-new-core 바로 뒤에 돌린다" "6.기존-core" "$k"
    return
  fi
  c=$(new_marker C)
  save_marker C "$c"
  echo "== 기존 core(B)에, 표식 C를 든 client가 프로그램을 띄운다"
  run_envdump c1 "$c"
  got=$(got_cred c1)
  if [ -z "$got" ]; then
    fact "기존 core: C를 든 client가 띄운 프로그램의 출력이 없다. 받은 값을 보지 못했다"
  elif [ "$got" = "$b" ]; then
    fact "기존 core: client가 C를 들고 불러도 프로그램은 core의 B를 받는다(같은 core에서 자격을 바꿀 수 없다)"
  else
    fact "기존 core: client가 C를 들고 부르자 프로그램이 받은 값은 $got"
  fi
  echo "== hc server restart(환경 유지) 뒤"
  rec hcq server restart
  rc=$?
  wait_core 75 || echo "server restart 뒤 core가 받지 않는다"
  run_envdump c2
  got=$(got_cred c2)
  fact "server restart(exit $rc) 뒤 프로그램이 받은 값: ${got:-출력 없음(보지 못했다)}"
  echo "표식 B가 든 파일:"
  grep_marker "$b"
  echo "== 표식 C를 든 client가 hc server restart --fresh를 부른 뒤"
  oldcore=$(core_pids | one_line)
  rec env O02_FAKE_CRED="$c" timeout 30 "$HC" server restart --fresh
  rc=$?
  if [ "$rc" -ne 0 ]; then
    undecided "restart --fresh가 실패했다(exit $rc). 환경을 바꾸려는 조작이 되지 않았으니 '못 바꿈'의 증거가 아니다" "$k"
  elif ! wait_core 75; then
    undecided "restart --fresh 뒤 core가 받지 않는다" "$k"
  else
    newcore=$(core_pids | one_line)
    run_envdump c3
    got=$(got_cred c3)
    if [ "$got" = "$c" ]; then
      verdict "$k" "안 됨" "restart --fresh를 부른 client의 C가 새 터미널에 들어갔다. core 소켓에 닿는 쪽이 core의 환경을 바꿀 수 있다"
    elif [ -z "$got" ]; then
      verdict "$k" "판단 필요" "restart --fresh 뒤 프로그램의 출력 파일이 없다. 받은 값을 보지 못했다"
    elif [ -z "$newcore" ] || [ "$newcore" = "$oldcore" ]; then
      verdict "$k" "판단 필요" "core pid가 그대로다(전 ${oldcore:-없음}, 후 ${newcore:-없음}). core가 다시 떴다는 증거가 없다"
    else
      verdict "$k" "됨" "restart --fresh로 core가 다시 떴고(pid $oldcore-> $newcore) 그 뒤 프로그램이 받은 값은 $got(C 아님)"
    fi
  fi
  echo "표식 B·C가 든 파일:"
  grep_marker "$b"
  grep_marker "$c"
}

step_cred_override() {
  local d e hit rc erc gotd why k1="6.env-override가-상태에-안-남음" k2="6.argv가-상태에-안-남음"
  if ! ensure_core; then
    undecided "core를 띄우지 못했다" "$k1" "$k2"
    return
  fi
  d=$(new_marker D)
  e=$(new_marker E)
  save_marker D "$d"
  save_marker E "$e"
  echo "== API(terminal.run)의 env override로 표식 D를 넘긴다"
  rm -f "$O02_OUT/env-d1.txt"
  rec python3 "$O02_PY" apirun "$(find_sock || echo "$O02_SOCK")" env-d1 "$d" d1
  rc=$?
  wait_file "$O02_OUT/env-d1.txt" 15
  sleep 1
  clean 2>/dev/null <"$O02_OUT/env-d1.txt"
  gotd=$(got_override d1)
  fact "env override로 프로그램이 받은 값: ${gotd:-출력 없음(보지 못했다)}, API 호출 exit $rc"
  echo "== argv에 표식 E를 넣어 띄운다"
  run_bg argv-e1 bash "$O02_PROG" sleeper "$e"
  erc=$?
  wait_role "prog:$e" 5 || erc=1
  echo "== 표식 D(env override)가 든 파일"
  hit=$(grep_marker "$d")
  echo "$hit"
  why=""
  if [ "$rc" -ne 0 ]; then
    why="API 호출이 실패했다(exit $rc). D가 hc에 전달되지 않았다"
  elif [ "$gotd" != "$d" ]; then
    why="프로그램이 D를 받지 못했다(받은 값: ${gotd:-출력 없음}). override가 전달됐다는 증거가 없다"
  fi
  judge_absent "$k1" "$hit" "$why" "D가 API로 전달돼 프로그램이 받았고, 표식 D가 든 파일이 없다" "env override가 위 파일에 남는다. 자격을 env override로 넘기면 안 된다(supervisor.md 2.2의 4)"
  echo "== 표식 E(argv)가 든 파일"
  hit=$(grep_marker "$e")
  echo "$hit"
  why=""
  if [ "$erc" -ne 0 ]; then why="argv에 E를 넣은 프로그램이 뜨지 않았다. E가 hc에 전달됐다는 증거가 없다"; fi
  judge_absent "$k2" "$hit" "$why" "E를 argv에 넣은 프로그램이 떠 있고, 표식 E가 든 파일이 없다" "argv가 위 파일에 남는다. 자격을 argv로 넘기면 안 된다"
}

# 종료·삭제·core 재시작·정지 뒤 남는 자리의 목록(O18에 넘긴다). cred-* 단계 뒤에 돌린다.
step_residue() {
  local f m name
  marker_report() {
    for f in "$O02_CTL"/marker.*; do
      [ -e "$f" ] || continue
      m=$(cat "$f")
      printf '표식 %s: %s\n' "${f##*.}" "$(grep_marker "$m" | one_line)"
    done
  }
  ensure_core || echo "core를 띄우지 못했다. 아래 목록은 core 없이 남은 것만 보여 준다"
  echo "== 지금 hc 자리의 파일과 소켓"
  list_files
  echo "== 표식이 든 파일(터미널을 끝내기 전)"
  marker_report
  echo "== 시험이 연 터미널을 끝내고(kill) 지운다(rm)"
  for name in s1 par c-default-o1 c-outlive-o1 det env-a1 env-b1 env-c0 env-c1 env-c2 env-c3 env-d1 argv-e1 in1 em1 burn hog probe-model probe-tool; do
    hcq kill "$name" >/dev/null 2>&1
    hcq rm "$name" >/dev/null 2>&1
  done
  sleep 2
  rec hcq ls --all
  echo "== 표식이 든 파일(kill·rm 뒤)"
  marker_report
  echo "== core 재시작 뒤"
  rec hcq server restart
  wait_core 75 || echo "재시작 뒤 core가 받지 않는다"
  marker_report
  echo "== core 정지 뒤(프로세스까지 모두 끝낸다)"
  full_stop
  ps_ours
  marker_report
  echo "== 남은 파일과 소켓(정지 뒤)"
  list_files
  fact "위 목록이 hc 상태가 남는 자리다(상태 파일 $(state_file_count)개). 컨테이너 로그에 남는 것은 밖에서 kubectl logs로 본다(절차 문서)"
}

# ---- 할 일 7: 보기

step_view_noinput() {
  local rrc
  if ! ensure_core; then
    undecided "core를 띄우지 못했다" "7.read-무입력" "7.observe-무입력" "7.대조군-입력이-닿음"
    return
  fi
  rm -f "$O02_OUT/inputlog.jsonl" "$O02_OUT/observe-in1.bin" "$O02_OUT/control-in1.bin"
  echo baseline >"$O02_OUT/phase"
  if ! run_bg in1 python3 "$O02_PY" inputlog "$O02_OUT/inputlog.jsonl" "$O02_OUT/phase" || ! wait_file "$O02_OUT/inputlog.jsonl" 10; then
    undecided "입력을 기록하는 프로그램이 hc 터미널에서 돌지 못했다" "7.read-무입력" "7.observe-무입력" "7.대조군-입력이-닿음"
    return
  fi
  sleep 5
  echo "== 읽기 경로 1: hc read"
  echo read >"$O02_OUT/phase"
  REC_LINES=5 rec hcq read in1
  rrc=$?
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
  rec python3 "$O02_PY" viewcheck "$O02_OUT/inputlog.jsonl" "$rrc" "$O02_OUT/observe-in1.bin" "$O02_OUT/control-in1.bin"
  hcq kill in1 >/dev/null 2>&1
}

step_view_ctrl() {
  local k
  if ! ensure_core || ! run_bg em1 python3 "$O02_PY" emit || ! wait_role py:emit 5; then
    for k in 7.read 7.read-json 7.observe; do
      undecided "제어 문자 표본을 내는 프로그램이 hc 터미널에서 돌지 못했다" "$k.원시-제어문자-없음" "$k.정제-뒤-0개"
    done
    return
  fi
  sleep 3
  rm -f "$O02_OUT/read-em1.bin" "$O02_OUT/readjson-em1.bin" "$O02_OUT/observe-em1.bin"
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
  local label spawned rc
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
    rc=$?
    sleep 3
    spawned=no
    if core_up || [ -n "$(core_pids)" ]; then spawned=yes; fi
    if [ "$spawned" = yes ]; then
      verdict "7.nocore.$label" "안 됨" "core가 없을 때 이 경로가 core를 띄웠다(pid $(core_pids | one_line))"
    elif [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
      verdict "7.nocore.$label" "판단 필요" "명령이 실행되지 못했다(exit $rc). 이 경로를 부른 것이 아니다"
    else
      verdict "7.nocore.$label" "됨" "이 경로를 불렀고(exit $rc) core를 띄우지 않았다"
    fi
  }
  if [ ! -x "$HC" ] || [ ! -r "$O02_PY" ]; then
    for label in server-status ls read events attach-observe 소켓-직접-확인; do
      undecided "hc나 o02.py가 없어 읽기 경로를 부르지 못했다" "7.nocore.$label"
    done
    return
  fi
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
