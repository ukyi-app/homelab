#!/bin/bash
# shellcheck shell=bash
# 제어 쪽 단계 함수. control.sh가 source해서 실행기 프로세스(제어 컨테이너 PID 1) 안에서 돈다. 이름은 step_<단계>(- 는 _).
# 출력 규칙: "결과 <키> <됨|안 됨|판단 필요> — 근거"는 안전한 쪽 성질의 판정이고, "사실 ..."은 판정 없는 관찰이다.
# "됨"은 조작이 성공했고 양성 증거를 본 뒤에만 낸다. 볼 대상이 있었다는 증거가 없으면 "판단 필요"다.
# 본체 컨테이너 안에서 봐야 하는 것(남은 프로세스, 첩자, 본체가 받은 자격)은 bctl.sh가 본다(run.sh body <단계>).
# shellcheck source=lib.sh
. /opt/o25/lib.sh

# send_body <글>: 본체 자리 셸에 한 줄을 보낸다. 중계를 지나 본체 pty에 들어간다.
send_body() { hcq send body "$1" >/dev/null 2>&1; }
# read_body [줄 수]: hc가 저장한 본체 터미널 화면. 정제해서 낸다.
read_body() { hcq read body --lines "${1:-40}" 2>&1 </dev/null | clean; }
relay_log() { clean <"$O25_OUT/relay-$O25_GEN.log" 2>/dev/null; }

step_preflight() {
  local got mstate wstate
  got=$("$HC" --version 2>&1 | clean)
  if [ "$got" = "hc ${O25_HC_VERSION:-?}" ]; then verdict "0.고정-버전" "됨" "$got"; else verdict "0.고정-버전" "안 됨" "기대 hc ${O25_HC_VERSION:-?}, 실제 $got"; fi
  rec id
  rec grep -E '^(Groups|CapEff|CapBnd|NoNewPrivs|Seccomp):' /proc/self/status
  if [ "$(id -u)" = 10001 ] && grep -q '^CapEff:[[:space:]]*0000000000000000$' /proc/self/status && grep -q '^NoNewPrivs:[[:space:]]*1$' /proc/self/status; then
    verdict "0.비root-권한없음" "됨" "uid 10001, CapEff 0, NoNewPrivs 1"
  else
    verdict "0.비root-권한없음" "안 됨" "위 값을 본다"
  fi
  if id -G | tr ' ' '\n' | grep -qx "$BODY_UID"; then
    verdict "0.본체-그룹-없음" "안 됨" "제어 쪽이 본체 gid $BODY_UID에 들어 있다"
  else
    verdict "0.본체-그룹-없음" "됨" "그룹 $(id -G): 본체 gid $BODY_UID가 없다(fsGroup·supplementalGroups 없음)"
  fi
  mstate=$(awk '$5 == "/" { o = $6 } END { n = split(o, a, ","); r = "unknown"; for (i = 1; i <= n; i++) if (a[i] == "ro" || a[i] == "rw") r = a[i]; print r }' /proc/self/mountinfo)
  wstate=$(python3 "$O25_PY" trycreate /o25-rootfs-probe 2>/dev/null | clean)
  if [ "$mstate" = ro ] && [ "$wstate" = EROFS ]; then verdict "0.읽기전용-root" "됨" "mountinfo ro, 만들기 EROFS"; else verdict "0.읽기전용-root" "판단 필요" "mountinfo $mstate, 만들기 $wstate"; fi
  if [ -e /var/run/secrets/kubernetes.io/serviceaccount/token ]; then verdict "0.SA-토큰-없음" "안 됨" "토큰 파일이 있다"; else verdict "0.SA-토큰-없음" "됨" "토큰 파일이 없다"; fi
  echo "== 폴더 권한(그룹·기타 쓰기가 없어야 한다. /relay/<세대>는 755)"
  find /c -mindepth 1 -maxdepth 3 -type d \( -perm -g+w -o -perm -o+w \) 2>/dev/null | head -n 5 | clean | sed 's/^/  그룹·기타 쓰기: /'
  fact "볼륨 뿌리 /c·/relay는 kubelet이 만든 0777이다. /c는 제어 쪽과 init에만 붙고, /relay는 본체에 읽기 전용이다"
  find /c /c/boot /c/g "$O25_G" "$O25_G/rt" /relay "$O25_RELAY" -maxdepth 0 -exec ls -ld {} + 2>&1 | awk '{ print "  " $1, $3, $4, $NF }' | clean
  if [ -z "$(find /c -mindepth 1 -maxdepth 3 -type d \( -perm -g+w -o -perm -o+w \) 2>/dev/null)" ] && [ -d "$O25_G/rt" ]; then
    verdict "0.제어-폴더-그룹쓰기-없음" "됨" "/c 아래 3단계까지 그룹·기타 쓰기 폴더 0개"
  else
    verdict "0.제어-폴더-그룹쓰기-없음" "안 됨" "위 목록을 본다"
  fi
  echo "== cgroup 상한(제어 컨테이너)"
  for t in memory.max cpu.max pids.max; do printf '  %s: %s\n' "$t" "$(clean </sys/fs/cgroup/$t 2>&1)"; done
}

step_boot() {
  local n verified
  echo "== 세대 기록(/c/boot/history: 세대 init시각 UTC)"
  clean </c/boot/history
  n=$(wc -l </c/boot/history)
  echo "== 장부(/c/ledger, 값 없이 세대·사건만)"
  tail -n 40 "$O25_LEDGER" | clean
  echo "== 세대별 허가 상태"
  for d in /c/boot/*/; do
    d=${d%/}
    printf '  %s permit=%s used=%s\n' "${d##*/}" "$([ -e "$d/permit" ] && echo 있음 || echo 없음)" "$([ -e "$d/used" ] && echo 있음 || echo 없음)"
  done
  fact "부팅 세대 ${n}개, 지금 세대 $O25_GEN"
  verified=$(grep -c " rule-verified gen=$O25_GEN" "$O25_LEDGER")
  if [ "$verified" -ge 1 ] && [ "$n" -ge 2 ]; then
    verdict "3.규칙-스스로-확인" "됨" "앞 세대의 전체 재시작 요청 뒤 init이 다시 돌아 새 세대 $O25_GEN이 왔다(부팅 세대 ${n}개)"
  else
    verdict "3.규칙-스스로-확인" "판단 필요" "이 세대에 rule-verified 기록이 없다"
  fi
  if [ "$(cred_count "$O25_GEN")" = 1 ]; then
    verdict "4.이번-세대-자격-1회" "됨" "세대 $O25_GEN의 자격 전달이 장부에 한 번"
  else
    verdict "4.이번-세대-자격-1회" "판단 필요" "세대 $O25_GEN의 자격 전달 $(cred_count "$O25_GEN")회(본체가 아직 받지 않았을 수 있다)"
  fi
  fact "세대별 자격 전달: $(grep ' cred-delivered ' "$O25_LEDGER" | sed 's/.*gen=\([0-9a-f]*\).*/\1/' | sort | uniq -c | one_line)"
}

# ---- (중계) hc가 그 터미널을 read·send하는가

step_relay() {
  local tag got
  if [ -z "$(relay_pids)" ]; then
    undecided "중계(relay-serve)가 떠 있지 않다" "2.send-입력-들어감" "2.read-출력-보임" "2.상대-uid-본체"
    return
  fi
  rec hcq ls
  echo "== 중계 기록"
  relay_log
  if grep -q "accepted peer uid=$BODY_UID " "$O25_OUT/relay-$O25_GEN.log" 2>/dev/null; then
    verdict "2.상대-uid-본체" "됨" "중계가 SO_PEERCRED uid $BODY_UID인 연결만 받았다"
  else
    verdict "2.상대-uid-본체" "판단 필요" "중계 기록에 받은 연결이 없다"
  fi
  tag="R$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  # 표식을 두 조각으로 보낸다. 셸이 받은 줄을 되찍는 것(에코)과 실제로 실행한 출력을 가른다.
  send_body "echo $tag-\$((6*7)); id; tty; stty size; echo gen=\$O25_GEN"
  sleep 3
  got=$(read_body 30)
  echo "== hc read body"
  printf '%s\n' "$got" | tail -n 12
  if printf '%s' "$got" | grep -q "$tag-42"; then
    verdict "2.send-입력-들어감" "됨" "보낸 줄이 본체 셸에서 실행됐다($tag-42가 화면에 있다)"
    verdict "2.read-출력-보임" "됨" "본체 자리 프로그램의 출력이 hc read에 보였다"
  else
    undecided "실행 결과($tag-42)가 화면에 없다" "2.send-입력-들어감" "2.read-출력-보임"
  fi
  if printf '%s' "$got" | grep -q "uid=$BODY_UID"; then fact "본체 셸 uid $BODY_UID(제어 쪽 hc 터미널 안이 아니라 본체 컨테이너에서 돈다)"; fi
  fact "화면 크기는 고정: 본체 pty 50×200(중계는 크기 변경을 나르지 않는다). 위 stty size 줄을 본다"
}

step_hide_control() {
  echo "== 대조군: 제어 컨테이너에서 같은 탐침(검사가 닿는 것을 잡는다는 증거)"
  bash /opt/o25/probe.sh control 2>&1 | clean
}

# ---- (중계 끊기·거짓 종료) 옛 본체가 살아 있는 동안 새 자격 0회

# try_new_session <키>: 단순한 감독이라면 "세션이 끝났으니 새로 시작"할 순간에 같은 세대에서 자격을 다시 내놓으려 한다. 거절돼야 한다.
try_new_session() {
  local before after
  before=$(cred_count)
  if deliver_cred; then
    verdict "$1" "안 됨" "같은 세대에서 자격을 다시 내놓았다"
    return
  fi
  sleep 2
  after=$(cred_count)
  if [ "$after" = "$before" ] && grep -q " cred-refused gen=$O25_GEN " "$O25_LEDGER"; then
    verdict "$1" "됨" "같은 세대의 두 번째 자격 전달을 거절했다(전달 $before→$after회, 새 자격은 새 세대에서만)"
  else
    verdict "$1" "판단 필요" "전달 $before→$after회"
  fi
}

step_relay_kill() {
  local rp
  rp=$(relay_pids | one_line)
  if [ -z "$rp" ]; then
    undecided "중계가 이미 없다(앞에서 끊었으면 restart로 새 세대를 만든 뒤 돌린다)" "2.hc-kill-중계-끝남" "4.중계-끊긴-뒤-새-자격-0"
    return
  fi
  echo "중계 pid $rp"
  rec hcq kill body
  sleep 3
  relay_log | tail -n 3
  if [ -z "$(relay_pids)" ]; then
    verdict "2.hc-kill-중계-끝남" "됨" "hc kill 뒤 중계(pid $rp)가 없다"
  else
    verdict "2.hc-kill-중계-끝남" "안 됨" "중계가 남았다: $(relay_pids | one_line)"
  fi
  fact "본체 쪽이 어떻게 됐는지는 run.sh body status로 본다(예상: 본체 자리 프로그램은 살아 있고 relay=closed. 중계를 죽여도 세션은 끝나지 않는다)"
  try_new_session "4.중계-끊긴-뒤-새-자격-0"
}

step_false_exit() {
  local got
  if [ -z "$(relay_pids)" ]; then
    undecided "중계가 없다" "4.거짓-종료-뒤-새-자격-0"
    return
  fi
  # 본체가 "끝났다"고 화면에 쓰고 살아 있다. 실행기는 이 바이트를 종료 영수증으로 쓰지 않는다.
  send_body "printf '\\n[o25] session ended, exit 0\\n'; echo still-alive-\$\$"
  sleep 2
  got=$(read_body 10)
  printf '%s\n' "$got" | tail -n 4
  printf '%s' "$got" | grep -q 'still-alive-' && fact "본체가 종료를 알리는 글을 쓰고도 셸이 살아 있다"
  try_new_session "4.거짓-종료-뒤-새-자격-0"
}

# ---- (전체 재시작) 심기 → 재시작 → 확인

step_plant() {
  local got
  if [ -z "$(relay_pids)" ]; then
    undecided "중계가 없어 본체에 심을 수 없다" "3.심기"
    return
  fi
  send_body "bash /opt/o25/plant.sh plant p-$O25_GEN"
  sleep 4
  got=$(read_body 10)
  printf '%s\n' "$got" | tail -n 3
  ledger "planted gen=$O25_GEN"
  if printf '%s' "$got" | grep -q "planted p-$O25_GEN"; then
    verdict "3.심기" "됨" "본체 셸이 분리 후손 넷과 첩자 하나를 띄웠다(run.sh body status로 다시 본다)"
  else
    verdict "3.심기" "판단 필요" "planted 줄이 화면에 없다"
  fi
}

step_restart() {
  echo "전체 재시작 요청: 세대 $O25_GEN, 종료 코드 $O25_RC. 이 단계의 끝 줄은 나오지 않는다(kubectl exec가 끊긴다). 이어서 after-restart를 돌린다."
  ledger "restart-request gen=$O25_GEN"
  exit_restart step-restart
}

step_ctl_crash() {
  echo "실행기만 끝냄: 세대 $O25_GEN, 종료 코드 $O25_RC_CRASH(규칙 밖). 제어 컨테이너만 다시 떠 허가가 이미 쓰인 것을 보고 전체 재시작을 요청해야 한다."
  ledger "crash-request gen=$O25_GEN code=$O25_RC_CRASH"
  echo "o25: crash-request gen=$O25_GEN"
  exit "$O25_RC_CRASH"
}

step_after_restart() {
  local req prev req_ns init_ns del_ns n_prev_after refused
  req=$(grep -E ' (restart|crash)-request gen=' "$O25_LEDGER" | tail -n 1)
  if [ -z "$req" ]; then
    undecided "장부에 재시작 요청이 없다(restart 또는 ctl-crash를 먼저 돌린다)" "3.새-세대" "3.init-이-요청-뒤" "4.옛-세대-추가-자격-0" "4.새-자격은-새-세대-init-뒤"
    return
  fi
  req_ns=${req%% *}
  prev=$(printf '%s' "$req" | sed 's/.* gen=\([0-9a-f]*\).*/\1/')
  init_ns=$(awk -v g="$O25_GEN" '$1 == g { print $2 }' /c/boot/history)
  echo "요청: $(printf '%s' "$req" | clean)"
  echo "== 요청 뒤 장부"
  awk -v t="$req_ns" '$1 >= t' "$O25_LEDGER" | clean
  if [ "$prev" != "$O25_GEN" ] && [ -n "$init_ns" ]; then
    verdict "3.새-세대" "됨" "요청한 세대 $prev → 지금 세대 $O25_GEN"
  else
    verdict "3.새-세대" "안 됨" "지금 세대가 요청한 세대와 같다($O25_GEN)"
  fi
  if [ -n "$init_ns" ] && [ "$init_ns" -gt "$req_ns" ]; then
    verdict "3.init-이-요청-뒤" "됨" "새 세대의 init 시각이 요청보다 $(((init_ns - req_ns) / 1000000))ms 뒤"
  else
    verdict "3.init-이-요청-뒤" "판단 필요" "init 시각($init_ns)과 요청 시각($req_ns)"
  fi
  refused=$(awk -v t="$req_ns" -v g="$prev" '$1 >= t && $2 == "exit-request" && $3 == "gen=" g' "$O25_LEDGER" | wc -l)
  fact "요청 세대 $prev에서 요청 뒤 시작 문지기가 전체 재시작을 요청한 횟수 $refused(ctl-crash면 1 이상이 예상: 실행기만 다시 떠 쓴 허가를 봤다)"
  n_prev_after=$(awk -v t="$req_ns" -v g="$prev" '$1 >= t && $2 == "cred-delivered" && $3 == "gen=" g' "$O25_LEDGER" | wc -l)
  if [ "$n_prev_after" -eq 0 ]; then
    verdict "4.옛-세대-추가-자격-0" "됨" "요청 뒤 세대 $prev로 나간 자격 0회"
  else
    verdict "4.옛-세대-추가-자격-0" "안 됨" "요청 뒤 세대 $prev로 자격 ${n_prev_after}회"
  fi
  del_ns=$(awk -v g="$O25_GEN" '$2 == "cred-delivered" && $3 == "gen=" g { print $1; exit }' "$O25_LEDGER")
  if [ -n "$del_ns" ] && [ -n "$init_ns" ] && [ "$del_ns" -gt "$init_ns" ]; then
    verdict "4.새-자격은-새-세대-init-뒤" "됨" "새 세대 자격이 init보다 $(((del_ns - init_ns) / 1000000))ms 뒤에 나갔다(옛 본체가 그 전에 끝났는지는 run.sh body after-restart의 첩자 기록으로 본다)"
  else
    verdict "4.새-자격은-새-세대-init-뒤" "판단 필요" "새 세대 자격 전달 기록이 없다(본체가 아직 받지 않았을 수 있다)"
  fi
  echo "== 옛 세대 파일(남는 것이 예상이다. 새 세대는 새 경로를 쓴다)"
  for d in /c/g/*/; do
    d=${d%/}
    printf '  %s 파일 %s개%s\n' "$d" "$(find "$d" -xdev -type f 2>/dev/null | wc -l)" "$([ "${d##*/}" = "$O25_GEN" ] && echo ' (지금 세대)')"
  done
  find /relay -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's/^/  중계 폴더 /' | clean
  fact "hc 상태 경로: 지금 세대 $O25_G (옛 세대 경로는 읽지 않는다)"
}

# ---- (자격 전달) 가짜 자격이 본체에만 있는가

step_cred() {
  local n_state hit_files hit_proc screen p
  if [ -z "$O25_MARK" ]; then
    undecided "이 실행기가 이번 세대의 자격을 내놓지 않았다(값을 모른다)" "6.hc-상태-없음" "6.제어-argv-environ-없음" "6.제어-로그-장부-없음" "6.중계-폴더-없음" "6.hc-화면-없음"
    return
  fi
  fact "이번 세대 자격 sha $(printf '%s' "$O25_MARK" | python3 "$O25_PY" sha), 전달 $(cred_count "$O25_GEN")회. 본체가 받은 sha는 run.sh body cred가 찍는다"
  n_state=$(find "$O25_G" -xdev -type f 2>/dev/null | wc -l)
  # 일반 파일만 본다. grep -r은 실행기 자신의 FIFO(/c/ctl/in)를 열고 쓰는 쪽이 올 때까지 멈춘다.
  hit_files=$(find /c /relay -xdev -type f -exec grep -lF -- "$O25_MARK" {} + 2>/dev/null | clean)
  echo "== /c와 /relay에서 값이 든 파일: ${hit_files:-없음} (hc 상태 파일 ${n_state}개 포함)"
  if [ "$(cred_count "$O25_GEN")" -lt 1 ]; then
    undecided "본체가 아직 자격을 받지 않았다" "6.hc-상태-없음" "6.제어-로그-장부-없음" "6.중계-폴더-없음"
  else
    if printf '%s' "$hit_files" | grep -q "^$O25_G/"; then verdict "6.hc-상태-없음" "안 됨" "hc 상태에 값이 있다"; elif [ "$n_state" -gt 0 ]; then verdict "6.hc-상태-없음" "됨" "hc 상태 파일 ${n_state}개에 값이 없다"; else verdict "6.hc-상태-없음" "판단 필요" "hc 상태 파일을 찾지 못했다"; fi
    if printf '%s' "$hit_files" | grep -qE '^/c/(out|ledger|ctl)'; then verdict "6.제어-로그-장부-없음" "안 됨" "제어 쪽 기록에 값이 있다"; else verdict "6.제어-로그-장부-없음" "됨" "/c/out·/c/ledger·/c/ctl에 값이 없다"; fi
    if printf '%s' "$hit_files" | grep -q '^/relay/'; then verdict "6.중계-폴더-없음" "안 됨" "중계 폴더에 값이 있다"; else verdict "6.중계-폴더-없음" "됨" "중계 폴더 파일에 값이 없다(소켓뿐)"; fi
  fi
  hit_proc=""
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$$" ] && continue
    if { tr '\0' '\n' <"$p/cmdline" | grep -qF -- "$O25_MARK"; } 2>/dev/null || { tr '\0' '\n' <"$p/environ" | grep -qF -- "$O25_MARK"; } 2>/dev/null; then
      hit_proc="$hit_proc ${p#/proc/}"
    fi
  done
  if [ -n "$hit_proc" ]; then
    verdict "6.제어-argv-environ-없음" "안 됨" "제어 쪽 프로세스의 argv·환경에 값:$hit_proc"
  else
    verdict "6.제어-argv-environ-없음" "됨" "제어 쪽 프로세스 $(find /proc -maxdepth 1 -name '[0-9]*' | wc -l)개의 argv·환경에 값이 없다(실행기 셸 변수는 내보내지 않는다)"
  fi
  screen=$(hcq read body --lines 400 2>/dev/null </dev/null)
  if [ -z "$screen" ]; then
    verdict "6.hc-화면-없음" "판단 필요" "본체 터미널 화면을 읽지 못했다(중계를 끊었으면 restart 뒤 다시 돌린다)"
  elif printf '%s' "$screen" | grep -qF -- "$O25_MARK"; then
    verdict "6.hc-화면-없음" "안 됨" "hc가 저장한 화면에 값이 있다"
  else
    verdict "6.hc-화면-없음" "됨" "hc 화면 $(printf '%s' "$screen" | wc -l)줄에 값이 없다(자격은 중계를 지나지 않는다. 본체가 스스로 찍으면 남는다)"
  fi
}

step_summary() {
  local s
  for s in $O25_STEPS; do
    [ "$s" = summary ] && continue
    [ -e "$O25_OUT/$s.txt" ] || continue
    printf -- '-- %s\n' "$s"
    grep -E '^(결과|사실) ' "$O25_OUT/$s.txt" | clean
  done
}
