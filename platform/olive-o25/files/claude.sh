#!/bin/bash
# shellcheck shell=bash
# claude 변형의 제어 쪽 단계(claude-ui). steps.sh가 source한다. 실행기 프로세스(제어 컨테이너 PID 1) 안에서 돈다.
# 중계(hc keys·read)로만 본체 자리 Claude Code를 만진다. 보내는 것은 고정 키 이름뿐이고 글자·Enter는 보내지 않는다
# (자격이 없어도 모델 호출이나 로그인 진행이 될 수 있는 입력을 피한다. hc send는 Enter를 붙이므로 쓰지 않는다).
# 여기서는 판정 대신 화면 사실 줄(claude-ui …)을 낸다. 프로그램이 살아 있었는지·끝났는지·실행 파일·화면 크기는 본체 PID 1이
# 자기 로그에 낸 o25c 줄이 근거이고, 둘을 묶는 판정은 밖의 tools/olive-o25/claude-judge.py가 한다(run.sh claude-judge).
# 판정을 화면 문구에 걸지 않는다: 화면은 "비어 있지 않음"과 "키 전후로 바뀜"(해시)만 쓴다.

# 화면 한 장(스크롤 기록 없이 지금 격자). 표식이 있으면 셸 안에서 가린 뒤에만 파일에 남긴다.
ui_read() { hcq read body --lines 0 2>/dev/null </dev/null; }
ui_hash() { printf '%s' "$1" | python3 "$O25_PY" sha; }
ui_nonblank() { printf '%s\n' "$1" | grep -c '[^[:space:]]'; }
# 줄의 최대 바이트 수(busybox awk의 length는 바이트를 센다. 상자 글자는 3바이트라 열 수가 아니다).
ui_maxw() { printf '%s\n' "$1" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'; }
# CLOCK_REALTIME ns. 본체 PID 1의 o25c 줄(time.time_ns)과 같은 단위여야 한다. 이 이미지의 date는 %N을 모른다(초만 낸다).
ui_now() {
  local t=${EPOCHREALTIME/[.,]/}
  printf '%s000\n' "$t"
}

# ui_fact <이름> <보낸 시각> <키 종료 코드> <읽은 시각> <읽기 종료 코드> <화면>
ui_fact() {
  printf 'claude-ui %s t_ns=%s rc=%s t_read_ns=%s read_rc=%s h=%s nonblank=%s maxw=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$(ui_hash "$6")" "$(ui_nonblank "$6")" "$(ui_maxw "$6")"
}

# ui_show <이름> <화면>: 사람이 읽을 화면. 표식은 가리고 제어 문자는 지운다.
ui_show() {
  local s=$2
  [ -n "$O25_MARK" ] && s=${s//"$O25_MARK"/<표식>}
  echo "== 화면 $1"
  printf '%s\n' "$s" | clean | grep '[^[:space:]]' | head -n 50 | sed 's/^/  | /'
}

UI_HIT=no
UI_UNREAD=0
# ui_mark <화면> <읽기 종료 코드>
ui_mark() {
  if [ "$2" != 0 ]; then
    UI_UNREAD=$((UI_UNREAD + 1))
    return
  fi
  case "$1" in *"$O25_MARK"*) UI_HIT=yes ;; esac
}

step_claude_ui() {
  local s t rc rr t_k t_r
  local k=2.claude.화면-표식-없음
  if [ -z "$(relay_pids)" ]; then
    verdict_c "$k" "판단 필요" not-checked "중계(relay-serve)가 떠 있지 않다"
    fact "claude-ui 중계 없음. 다른 사실 줄을 내지 않는다"
    return
  fi
  if [ -z "$O25_MARK" ]; then
    verdict_c "$k" "판단 필요" not-checked "이 세대의 자격이 아직 나가지 않았다(대조할 값이 없다)"
    return
  fi
  rec hcq get body
  UI_HIT=no UI_UNREAD=0
  # 1. 첫 화면: 비어 있지 않은 화면이 나올 때까지 최대 60초.
  t=$(ui_now)
  for _ in $(seq 30); do
    s=$(ui_read)
    rr=$?
    [ "$rr" = 0 ] && [ "$(ui_nonblank "$s")" -ge 3 ] && break
    sleep 2
  done
  ui_mark "$s" "$rr"
  ui_fact first "$t" 0 "$(ui_now)" "$rr" "$s"
  ui_show first "$s"
  # 2. 손대지 않고 4초 뒤 같은 화면인가(애니메이션이 있으면 키 전후 비교를 믿지 못한다).
  sleep 4
  t=$(ui_now)
  s=$(ui_read)
  rr=$?
  ui_mark "$s" "$rr"
  ui_fact idle "$t" 0 "$(ui_now)" "$rr" "$s"
  # 3. 입력: 아래 화살표 하나. 선택 메뉴라면 선택이 옮겨 간다.
  t_k=$(ui_now)
  hcq keys body down >/dev/null 2>&1 </dev/null
  rc=$?
  sleep 3
  t_r=$(ui_now)
  s=$(ui_read)
  rr=$?
  ui_mark "$s" "$rr"
  ui_fact down "$t_k" "$rc" "$t_r" "$rr" "$s"
  ui_show down "$s"
  # 4. Ctrl-C 한 번: 중계에 들어가는 키 바이트다(신호를 보내지 않는다). 반응(안내 한 줄)은 1초 안팎으로 사라지므로 곧바로 읽는다.
  t_k=$(ui_now)
  hcq keys body ctrl+c >/dev/null 2>&1 </dev/null
  rc=$?
  sleep 0.3
  t_r=$(ui_now)
  s=$(ui_read)
  rr=$?
  ui_mark "$s" "$rr"
  ui_fact ctrlc "$t_k" "$rc" "$t_r" "$rr" "$s"
  ui_show ctrlc "$s"
  # 5. 끝내기: 문서의 "두 번째 Ctrl-C는 끝낸다"(interactive-mode, Ctrl+C). 앞 안내가 사라질 만큼 기다린 뒤 두 번을 따로 보낸다
  #    (한 번의 keys에 둘을 넣으면 한 쓰기로 붙어 프로그램이 한 입력으로 읽는다).
  sleep 3
  t_k=$(ui_now)
  hcq keys body ctrl+c >/dev/null 2>&1 </dev/null
  rc=$?
  sleep 0.2
  hcq keys body ctrl+c >/dev/null 2>&1 </dev/null
  rc=$((rc | $?))
  sleep 15
  t_r=$(ui_now)
  s=$(ui_read)
  rr=$?
  # 프로그램이 끝나 터미널이 닫혔으면 읽기가 실패할 수 있다. 끝내기 화면은 표식 검사에서 읽기 실패를 세지 않는다.
  [ "$rr" = 0 ] && ui_mark "$s" 0
  ui_fact exit "$t_k" "$rc" "$t_r" "$rr" "$s"
  ui_show exit "$s"
  rec hcq get body
  if [ "$UI_HIT" = yes ]; then
    verdict_c "$k" "안 됨" screen-hit "hc가 보여 준 본체 화면에 값이 있다(누출)"
  elif [ "$UI_UNREAD" != 0 ]; then
    verdict_c "$k" "판단 필요" screen-unread "화면을 ${UI_UNREAD}번 읽지 못했다"
  else
    verdict_c "$k" "됨" screen-clean "이 단계에서 읽은 화면 다섯 장에 값이 없다"
  fi
  fact "판정은 run.sh claude-judge(본체 로그의 o25c 줄과 이 결과를 묶는다). 끝내기 뒤 프로그램은 다시 띄우지 않는다(새 판은 전체 재시작)"
}
