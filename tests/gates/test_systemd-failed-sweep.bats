#!/usr/bin/env bats
# 호스트 systemd **전역** 실패 스윕의 계약 — 생산자(스크립트)·실행자(유닛)·소비자(알림)를 한 파일에서 문다.
#
# 왜 필요한가: 이 축의 실패는 **red가 아니라 침묵**으로 나타난다. 스윕이 죽어도 textfile collector는
# 남아 있는 파일을 영원히 재발행하므로 `systemd_sweep_units_failed 0`이 계속 나온다 — 관측이 아니라
# 잔상이다. 그래서 이 파일이 무는 것은 "값이 맞나"가 아니라 **"0건과 미실행이 구별되나"**다.
#
# hermetic — 스텁 systemctl을 쓰고 라이브 호스트를 건드리지 않는다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2에서 [[ ]] 실패는 침묵 통과한다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  SWEEP="$ROOT/scripts/sweep-systemd-failures.sh"
  UNIT_DIR="$ROOT/infra/k3s-bootstrap/host-config/etc/systemd/system"
  SVC="$UNIT_DIR/systemd-failed-sweep.service"
  TIMER="$UNIT_DIR/systemd-failed-sweep.timer"
  R4="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  # 설정 본문은 configMapGenerator가 굽는 파일이 SSOT다(매니페스트에 인라인 ConfigMap 없음).
  AMCFG="$ROOT/platform/victoria-stack/prod/alertmanager-config/alertmanager.yml"
  TMP="$(mktemp -d)"
  OUT="$TMP/out"; BIN="$TMP/bin"; mkdir -p "$OUT" "$BIN"
}
teardown() { rm -rf "$TMP"; }

# $1 = 총 유닛 수, $2 = .service 수, $3.. = 추가로 뱉을 raw 줄
_stub() {
  local total="$1" svc="$2"; shift 2
  {
    printf '#!/bin/sh\n'
    printf 'echo "list-units" >> "%s/calls"\n' "$TMP"
    printf 'i=0; while [ $i -lt %s ]; do echo "s$i.service loaded active running d"; i=$((i+1)); done\n' "$svc"
    printf 'i=0; while [ $i -lt %s ]; do echo "m$i.mount loaded active mounted d"; i=$((i+1)); done\n' "$(( total - svc ))"
    local line
    for line in "$@"; do printf 'echo %s\n' "'$line'"; done
  } > "$BIN/systemctl"
  chmod +x "$BIN/systemctl"
}

_run_sweep() {
  run env SYSTEMD_SWEEP_SYSTEMCTL="$BIN/systemctl" NODE_EXPORTER_TEXTFILE_DIR="$OUT" bash "$SWEEP"
}

_prom() { cat "$OUT/systemd-failed-sweep.prom"; }

@test "a healthy sweep writes the heartbeat and an explicit zero, both" {
  # ★ 0건을 **명시적으로** 쓰는 것이 계약이다. 안 쓰면 "failed 없음"과 "스윕이 그 패밀리를 못 만듦"이
  #   같은 부재로 보인다. 하트비트는 그와 별개로 "언제 관측했나"를 값 안에 싣는다.
  _stub 100 60
  _run_sweep
  [ "$status" -eq 0 ]
  run grep -c '^systemd_sweep_units_failed 0$' "$OUT/systemd-failed-sweep.prom"
  [ "$output" -eq 1 ]
  run grep -cE '^systemd_sweep_last_success_timestamp [0-9]+$' "$OUT/systemd-failed-sweep.prom"
  [ "$output" -eq 1 ]
}

@test "the enumeration happens exactly once (numerator and denominator share one truth)" {
  # 🔴 `list-units`(분모)와 `list-units --state=failed`(분자)를 따로 부르면 바닥값이 분모에만 걸려,
  #   분자만 붕괴했을 때 units_failed 0 + 신선한 하트비트 + 정상 파싱으로 세 알림이 전부 무음이 된다.
  _stub 100 60
  _run_sweep
  [ "$status" -eq 0 ]
  run bash -c "grep -c . '$TMP/calls'"
  [ "$output" -eq 1 ]
}

@test "failed units are emitted with unit and type labels" {
  _stub 100 60 'apt-daily.service loaded failed failed Daily apt' 'x.timer loaded failed failed T'
  _run_sweep
  [ "$status" -eq 0 ]
  run grep -c '^systemd_sweep_units_failed 2$' "$OUT/systemd-failed-sweep.prom"
  [ "$output" -eq 1 ]
  run grep -cF 'systemd_sweep_unit_failed{unit="apt-daily.service",type="service"} 1' "$OUT/systemd-failed-sweep.prom"
  [ "$output" -eq 1 ]
  run grep -cF 'systemd_sweep_unit_failed{unit="x.timer",type="timer"} 1' "$OUT/systemd-failed-sweep.prom"
  [ "$output" -eq 1 ]
}

@test "a systemd-escaped unit name is escaped for exposition, not rejected" {
  # ⚠️ 짝 스크립트(notify-unit-failure.sh)는 이상한 문자를 **거부**한다 — 인자가 하나뿐이라 그래도 된다.
  #   여기서 거부하면 `.device`/`.mount`(라이브에 `\x2d`를 담은 유닛이 실재한다)의 실패가 통째로
  #   무성이 된다. 그래서 거부가 아니라 이스케이프다.
  _stub 100 60 'dev-disk-by\x2ddesignator-esp.device loaded failed failed ESP'
  _run_sweep
  [ "$status" -eq 0 ]
  run grep -cF 'unit="dev-disk-by\\x2ddesignator-esp.device"' "$OUT/systemd-failed-sweep.prom"
  [ "$output" -eq 1 ]
}

@test "a collapsed enumeration writes NOTHING and exits non-zero" {
  # 🔴 이 파일의 핵심. 0건으로 위조되면 전역 축이 조용히 실명한다.
  _stub 10 8
  _run_sweep
  [ "$status" -ne 0 ]
  run bash -c "[ -f '$OUT/systemd-failed-sweep.prom' ]"
  [ "$status" -ne 0 ]
}

@test "a proportional collapse (total fine, .service gone) is caught by the second floor" {
  # ★ 총계는 kubelet 트랜지언트가 지배해(라이브 629 중 487) 비례 붕괴를 가린다. .service는 컨테이너
  #   런타임이 만들지 않아 호스트 서비스 수에 안정적으로 고정된다 — 그래서 두 번째 바닥값이 필요하다.
  _stub 100 5
  _run_sweep
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF '.service'
  run bash -c "[ -f '$OUT/systemd-failed-sweep.prom' ]"
  [ "$status" -ne 0 ]
}

@test "an unknown ACTIVE-column vocabulary fails closed (format drift must not read as zero)" {
  # ★ 단일 열거로 바꾸면서 새로 생긴 무성 경로다: 출력 포맷이 밀리면 $3=="failed"가 조용히 0건이 된다.
  {
    printf '#!/bin/sh\n'
    printf 'i=0; while [ $i -lt 60 ]; do echo "s$i.service loaded WEIRD running d"; i=$((i+1)); done\n'
  } > "$BIN/systemctl"; chmod +x "$BIN/systemctl"
  _run_sweep
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF '포맷'
  run bash -c "[ -f '$OUT/systemd-failed-sweep.prom' ]"
  [ "$status" -ne 0 ]
}

@test "the floors are source constants, not env-overridable" {
  # ⚠️ env로 낮출 수 있으면 fail-closed가 런타임에 해제된다.
  run grep -cE '^(SCAN_MIN|SERVICE_MIN)=[0-9]+$' "$SWEEP"
  [ "$output" -eq 2 ]
  # ⚠️ `-ne 0`은 grep rc=**2**($SWEEP 부재/읽기불가)도 통과로 읽는다 — "env 오버라이드 0건"과
  #   "검사 대상 0건"이 같은 초록이 되는 부정-카운트 함정. 매치 없음은 정확히 rc=1이다.
  #   (바로 위 `grep -cE ... -eq 2`가 같은 파일에 대한 양성 대조 역할을 한다.)
  run grep -qE '^(SCAN_MIN|SERVICE_MIN)="\$\{' "$SWEEP"
  [ "$status" -eq 1 ]
}

@test "the unit runs the script from scripts/ and never inlines a metric write" {
  # 함정 원장 「systemd 유닛 파일은 push 생산자 열거 밖이다」 — 유닛에 인라인하면 생산자 회계가
  # 그 메트릭을 영영 못 본다(repo-walk의 include에 .service가 없다).
  run bash -c "grep -c '^ExecStart=/home/ukyi/workspace/homelab/scripts/sweep-systemd-failures.sh\$' '$SVC'"
  [ "$output" -eq 1 ]
  # ⚠️ 줄 머리(`^`)로 한정한다 — 이 유닛의 주석이 **바로 그 함정을 설명하면서** 금지 문자열을
  #   인용한다. 한정하지 않으면 근거를 적은 것이 red가 되어, 다음 사람이 근거를 지우게 만든다
  #   (test_sealed-secrets-restore.bats의 RETURN 트랩 가드가 같은 이유로 같은 한정을 건다).
  # rc 2($SVC 부재)를 통과로 읽지 않는다 — 유닛 파일이 사라져도 초록이 되면 안 된다.
  run grep -qE '^ExecStart=.*(curl|/bin/sh -c)' "$SVC"
  [ "$status" -eq 1 ]
}

@test "the sweep unit has its own OnFailure channel (it cannot record its own failure)" {
  # 스윕이 실패하면 파일을 쓰지 않는 것이 계약이므로 자기 실패를 자기가 기록할 수 없다.
  run bash -c "grep -c '^OnFailure=unit-failure-notify@%n.service\$' '$SVC'"
  [ "$output" -eq 1 ]
  # 짝 템플릿에는 OnFailure가 없어야 한다(있으면 실패 루프). 같은 이유로 줄 머리만 본다 —
  # 그 파일의 주석이 "이 유닛에 OnFailure=를 달지 마라"라고 그 문자열을 인용하고 있다.
  run bash -c "grep -c '^OnFailure=' '$UNIT_DIR/unit-failure-notify@.service' || true"
  [ "$output" -eq 0 ]
}

@test "the timer cadence arithmetic stays under the staleness threshold" {
  # ★ 최악 성공↔성공 = OnCalendar(300) + AccuracySec + RandomizedDelaySec + TimeoutStartSec.
  #   그 합이 SystemdSweepStale 임계보다 작아야 정상 운영에서 안 운다.
  oncal="$(grep -oE '^OnCalendar=\*:0/[0-9]+' "$TIMER" | grep -oE '[0-9]+$')"
  acc="$(grep -oE '^AccuracySec=[0-9]+' "$TIMER" | grep -oE '[0-9]+$')"
  rnd="$(grep -oE '^RandomizedDelaySec=[0-9]+' "$TIMER" | grep -oE '[0-9]+$')"
  tmo="$(grep -oE '^TimeoutStartSec=[0-9]+' "$SVC" | grep -oE '[0-9]+$')"
  [ -n "$oncal" ]; [ -n "$acc" ]; [ -n "$rnd" ]; [ -n "$tmo" ]
  worst=$(( oncal * 60 + acc + rnd + tmo ))
  thr="$(grep -oE 'systemd_sweep_last_success_timestamp\[2h\]\)\)\) > [0-9]+' "$R4" | grep -oE '[0-9]+$' | head -1)"
  [ -n "$thr" ]
  [ "$worst" -lt "$thr" ]
}

@test "the state gauge outlives the heartbeat alert (no gap between them)" {
  # 🔴 부등식이 이 축의 안전 계약이다. SystemdHostUnitFailed의 `and on()` 신선도 게이트가
  #   SystemdSweepStale의 발화 시점보다 **뒤**여야, 상태 게이지가 꺼지기 전에 하트비트가 먼저 켜진다.
  #   뒤집히면 스윕이 죽은 뒤 아무도 울지 않는 창이 생긴다.
  gate="$(grep -oE '\[2h\]\)\)\) < [0-9]+' "$R4" | grep -oE '[0-9]+$' | head -1)"
  thr="$(grep -oE 'systemd_sweep_last_success_timestamp\[2h\]\)\)\) > [0-9]+' "$R4" | grep -oE '[0-9]+$' | head -1)"
  [ -n "$gate" ]; [ -n "$thr" ]
  inner="$(yq -r '.data | to_entries | .[0].value' "$R4")"
  forsec="$(printf '%s' "$inner" | yq -r '.groups[].rules[] | select(.alert=="SystemdSweepStale") | .for')"
  [ "$forsec" = "5m" ]
  fires=$(( thr + 300 ))
  [ "$gate" -gt "$fires" ]
}

@test "both sweep alerts use last_over_time (mode D: in-cluster + impossible)" {
  # max_over_time은 값의 전진 점프를 [2h] 래치해 스윕이 살아나도 알림이 안 꺼진다.
  inner="$(yq -r '.data | to_entries | .[0].value' "$R4")"
  for a in SystemdHostUnitFailed SystemdSweepStale; do
    e="$(printf '%s' "$inner" | yq -r ".groups[].rules[] | select(.alert==\"$a\") | .expr")"
    run grep -qF 'last_over_time(systemd_sweep_last_success_timestamp[2h])' <<<"$e"
    [ "$status" -eq 0 ]
    run grep -qF 'max_over_time(systemd_sweep_last_success_timestamp' <<<"$e"
    [ "$status" -ne 0 ]
  done
}

@test "the heartbeat alert keeps its absent() guard (a periodic gauge's absence is drift)" {
  # ★ 위 SystemdUnitFailed와 정반대 결정이다 — 이벤트 메트릭의 '부재=정상' 논거를 여기 복사하면
  #   타이머 미enable이 통째로 무음이 된다.
  inner="$(yq -r '.data | to_entries | .[0].value' "$R4")"
  e="$(printf '%s' "$inner" | yq -r '.groups[].rules[] | select(.alert=="SystemdSweepStale") | .expr')"
  run grep -qF 'absent(last_over_time(systemd_sweep_last_success_timestamp[2h]))' <<<"$e"
  [ "$status" -eq 0 ]
}

@test "a unit-scoped inhibit keeps the critical axis from double-paging the sweep warning" {
  # ⚠️ 파일 직독 — 추출 실패가 빈 문서로 접히면 아래 grep 4건이 전부 "빈 것에 대한 참"이 된다.
  [ -s "$AMCFG" ]
  am="$(cat "$AMCFG")"
  printf '%s' "$am" | grep -qF -- "equal: ['unit']"
  printf '%s' "$am" | grep -qF 'alertname = SystemdUnitFailed'
  printf '%s' "$am" | grep -qF 'alertname = SystemdHostUnitFailed'
  # 라벨 없는 알림끼리 빈 문자열로 매칭되는 것을 막는 한정이 있어야 한다.
  printf '%s' "$am" | grep -qF 'unit =~ ".+"'
}

@test "host-config declares both sweep units and its floor covers them" {
  [ -f "$SVC" ]
  [ -f "$TIMER" ]
  n="$( (cd "$ROOT/infra/k3s-bootstrap/host-config" && find . -type f \( -name '*.conf' -o -name '*.service' -o -name '*.timer' \)) | grep -c . )"
  floor="$(grep -oE '^TREE_MIN=[0-9]+' "$ROOT/infra/k3s-bootstrap/host-config.sh" | grep -oE '[0-9]+$')"
  [ -n "$floor" ]
  # 바닥값이 실제 트리보다 크면 --check가 항상 죽고, 훨씬 작으면 파일이 사라져도 통과한다.
  [ "$floor" -le "$n" ]
  [ "$floor" -ge "$(( n - 1 ))" ]
}
