#!/usr/bin/env bash
# 열거 붕괴 → vacuous green 차단 커널 — **셸 adapter**. 가드들이 공유하는 **기계**만 여기 둔다.
# TypeScript adapter는 `tools/lib/scan-floor.ts`다. 규약(마커 형태·방출 순서·억제·SKIP 배타)은
# 하나이고 구현만 갈린다 — 근거와 경계는 CONTRIBUTING '가드 스캔 신호' 절.
#
# 병(라이브 재현): `done < <(enumerator)` **프로세스 치환은 열거자 실패를 `set -euo pipefail`로
# 전파하지 않는다.** 워커가 죽으면 소비자가 0건을 검사하고 성공 메시지를 낸다 —
# 실패하는 `bun` 셰임으로 `check-app-netpol`이 `OK (0 app-owned NetworkPolicy 검사, 위반 0)` + rc=0.
# `check-image-pins`만 바닥값이 있어 이 경로에서 죽었다. 비대칭이 곧 갭이었다.
#
#   scan_enumerate <라벨> <명령...>   열거를 **변수로** 받아 rc를 캡처한다(치환이 삼키던 자리).
#                                     성공: stdout에 결과 · 실패: 진단 + 비-0.
#   scan_floor <라벨> <실제> <하한>    건수 바닥값. 미만이면 진단 + 비-0. 통과하면 SCAN 신호를 낸다.
#   scan_signal <라벨> <실제>          `SCAN: <라벨>: <n>` 마커만 낸다(바닥값 없는 카운트 자리용).
#
# **SCAN 신호가 이 커널의 두 번째 산출물이다.** 바닥값은 "0건인데 초록"을 막고, 신호는 "몇 건을
# 실제로 검사했는가"를 **기계가 읽을 수 있게** 만든다. 후자가 필요한 이유: 가드가 CI에서 돈다는
# 사실(티켓 06의 권위 경로 회계)과 **그 호출이 가드의 실제 도메인에 닿았다는 사실**은 다른데,
# 텍스트로는 갈리지 않는다(실측 반례 2건 — 루트 인자가 실 레포를 가리키거나, 한 파일에 픽스처
# 호출과 실 트리 호출이 섞여 있다). 실행 관측만이 그걸 가른다.
#
# 형태는 01의 `SKIP: <가드>: <이유>`와 **같은 채널·같은 모양**이다(stdout, `<마커>: <가드>: <값>`) —
# 정적으로 찾을 수 있고 사람이 읽어도 뜻이 같다. 두 마커는 의미가 배타적이다:
#   SKIP: 도메인이 정당하게 없어 **평가하지 않았다**(exit 4)
#   SCAN: 도메인을 **n건 평가했다**(정상 경로)
# ⚠️ 그래서 한 실행이 둘을 같이 내면 안 된다. `SKIP:`을 문자열로 포함하지도 않으므로
#    check-skip-signalling의 짝 검사(`index(line,"SKIP:")`)에 걸리지 않는다.
# ⚠️ **커버리지는 완전하지 않다** — 가드 전부가 신호를 내지는 않는다.
#    소비자는 "SCAN 없음"을 "픽스처"나 "0건"으로 읽으면 안 된다 — **미지(unknown)** 다.
# ⚠️ 여기에 **건수를 적지 않는다.** 아무도 대조하지 않는 손 관리 수치는 반드시 드리프트한다 —
#    실측한 적이 있다: 주석은 "11종/27종", 실제는 13종/31종, CONTRIBUTING·PROGRESS엔 또 다른 수치.
#    현재값이 필요하면 세어라:
#      grep -lE '^[^#]*\b(scan_floor|scan_signal) ' scripts/*.sh
#      grep -lE '^[^/]*(scan(Floor|Signal)\(|scan: ")' tools/*.ts
# ⚠️ 바닥값 오버라이드 어휘는 `--floor <도메인>=<n>` 하나다 — TS는 guardMain(takeFloors), 셸은
#    아래 take_floors(kernel-followups 01~03에서 전 가드 이관 완료 — env·--min-* 어휘 소멸).
#    종료코드 예외 2건: check-credential-expiry 붕괴 2(소비자 rc 계약) · audit-orphan-pv 붕괴 3
#    (라이브 쿼리 실패 계열 어휘 보존) — 목록·근거는 CONTRIBUTING §종료코드 각주.
#    정합은 tests/gates/test_scan-floor.bats가 **정적 콜사이트 == 런타임 방출** 집합 대조로 강제하고,
#    TS 콜사이트가 커널을 우회해 마커를 직접 출력하는 것은 scripts/check-scan-producers.sh가 거부한다
#    (등식은 양쪽에서 함께 사라지는 우회를 못 잡는다 — 인식이 아니라 거부가 문을 닫는다).
# ⚠️ **라벨 = 바닥값이 걸린 열거 도메인 하나.** 한 실행이 두 도메인을 보면 접미사로 나눈다
#    (`check-skeleton:bats`/`:platform`). 도메인이 하나면 접미사를 붙이지 않는다.
#
# ⚠️ 바닥값 **수치는 소비자가 소유한다.** 열거자는 "글롭이 깨져 0건"과 "정당하게 0건"을 구별할
#    도메인 지식이 없다(`tools/lib/repo-walk.ts`가 scan-floor를 두지 않기로 한 결정과 같은 이유).
#    이 커널은 그 결정을 뒤집지 않는다 — 판정 기계만 공유하고 임계값은 콜사이트에 남긴다.
# ⚠️ **skip 규약(01)과 다른 채널이다.** 저긴 "검사할 도메인이 정당하게 없음"(exit 4 + `SKIP:` 마커)이고,
#    여긴 "열거를 못 했다"는 검증 실패(비-0)다. 마커를 내면 사람이 정반대 뜻으로 읽는다.
# ⚠️ 바닥값은 **래칫이 아니다** — 도메인이 줄지 않는 한 손댈 일이 없다(cf. check-bats-style의 BB_BASELINE은
#    0으로 수렴해야 하는 부채라 성격이 다르다).
# bash 3.2 호환(mapfile 금지 — 콜사이트는 `<<<` 히어스트링으로 순회). shellcheck clean.

# shellcheck shell=bash

scan_enumerate() {
  label="$1"; shift
  _scan_out=""; _scan_rc=0
  _scan_out="$("$@")" || _scan_rc=$?
  if [ "$_scan_rc" -ne 0 ]; then
    echo "FAIL: ${label}: 열거 실패(rc=${_scan_rc}) — 검사 불가. 프로세스 치환이었다면 여기서 조용히 0건이 됐다." >&2
    return 1
  fi
  printf '%s' "$_scan_out"
}

# `SCAN: <라벨>: <n>` — 실행 관측용 균일 신호. **stdout**(01의 SKIP 마커와 같은 채널).
# 바닥값이 없는 카운트 자리(예: check-image-pins 레인1 — 합계 바닥값이 따로 있다)도 이걸 직접 부른다.
scan_signal() {
  echo "SCAN: $1: $2"
}

# 4번째 인자 `quiet`는 **마커만 삼킨다 — 판정은 그대로다.** 억제는 출력 채널의 성질이지 판정의
# 성질이 아니다(TS adapter가 이미 확정한 의미론 — tools/lib/scan-floor.ts).
# 왜 필요한가: 도메인이 여럿인 가드가 도메인마다 즉시 방출하면, 뒤 도메인이 붕괴한 실행이 앞
# 도메인의 "N건 검사했다"를 그대로 낸다 — 붕괴한 실행의 어떤 건수도 "검사했다"로 읽히면 안 된다.
# 소비자는 통과 도메인의 마커를 **판정을 다 한 뒤** scan_signal로 일괄 방출한다(TS guardMain과 동형).
scan_floor() {
  label="$1"; got="$2"; min="$3"; quiet="${4:-}"
  if [ "$got" -lt "$min" ]; then
    echo "FAIL: ${label}: 스캔 ${got}건 < ${min} — 열거 붕괴 의심(0건 검사 후 초록이 되는 자리)." >&2
    return 1
  fi
  # 바닥값을 통과한 실행만 신호를 낸다 — 실패 경로는 이미 stderr로 시끄럽고, 그때의 건수는
  # "검사했다"가 아니라 "붕괴했다"는 뜻이라 같은 마커로 내면 소비자가 정반대로 읽는다.
  [ "$quiet" = quiet ] || scan_signal "$label" "$got"
  return 0
}

# 줄 수를 센다(빈 문자열=0). `grep -c .`는 0건일 때 rc=1이라 set -e 콜사이트에서 함정이 된다.
scan_count() {
  if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | grep -c . || true; fi
}

# ── take_floors — 바닥값 오버라이드 어휘 `--floor <도메인>=<n>`의 셸 adapter ─────────────────────
# (kernel-followups 01 — TS guardMain의 takeFloors/floorOf 동형. 구 콜사이트별 env·--min-* 어휘를
# 이 하나로 접는다: env는 호출부에 보이지 않는 채로 바닥값을 끄므로 거부 가드로도 못 막는다.)
#
# 사용 규약(콜사이트):
#   take_floors "<허용 라벨들(공백 구분)>" "$@" || exit $?
#   set -- "${REST_ARGV[@]+"${REST_ARGV[@]}"}"     # ⚠️ 빈 배열 + set -u 함정의 관용구 그대로 쓸 것
#   … min="$(floor_of <라벨> <기본값>)" …
# 허용 라벨은 **선언 선행**이다 — TS는 실행 커널(guardMain ⓪)이 파싱 뒤 전건 매칭을 검증하지만,
# 셸엔 실행 커널이 없어 파싱 시점 검증(잊을 수 없는 자리)이 그 등가물이다. 키는 라벨 전체 또는
# 마지막 콜론 뒤 접미사 — 정규화해 저장하므로 floor_of는 전체 라벨로만 조회한다.
# ⚠️ 선언은 콜사이트 손 문자열이라 TS(마커 리터럴과 동일 대상)만큼 강하지 않다 — 선언 오타는
#    바닥값을 조용히 끈다. 그래서 커버리지 증인(test_scan-floor.bats)이 **선언 라벨 ⊆ 방출 라벨**을
#    정적으로 대조한다(선언에 넣는 라벨은 반드시 scan_floor/scan_signal 콜사이트 라벨이어야 한다).
# 같은 키 반복은 **마지막 승**이다(TS Map.set 동형 — 접미사·전체 라벨 혼용도 정규화 후 같은 키라
# 마지막 값이 이긴다). 값의 선행 0은 십진으로 정규화한다(8진 해석이 요청보다 낮은 바닥값이 되는
# 방향을 막는다 — TS Number()와 동형).
# 오류(빈 선언·형식·값·미매칭·모호)는 진단 + return 2 — set -e 콜사이트에서 그대로 사용법 종료가
# 된다(판정 lib은 exit을 소유하지 않는다 — detect_run과 같은 규율. guard_skip의 exit 4는 방출
# 헬퍼의 원자성 계약이라 예외다).
take_floors() {
  _tf_allowed="$1"; shift
  REST_ARGV=(); _FLOOR_KEYS=(); _FLOOR_VALS=()
  if [ -z "$_tf_allowed" ]; then
    echo "take_floors: 허용 라벨이 비었다 — 도메인 0개인 가드는 오버라이드가 전부 미매칭이 된다(fail-closed, TS guardMain의 빈 domains 거부와 동형)" >&2
    return 2
  fi
  while [ $# -gt 0 ]; do
    if [ "$1" != "--floor" ]; then REST_ARGV+=("$1"); shift; continue; fi
    _tf_spec="${2-}"
    _tf_key="${_tf_spec%%=*}"; _tf_val="${_tf_spec#*=}"
    if [ -z "$_tf_spec" ] || [ "$_tf_key" = "$_tf_spec" ] || [ -z "$_tf_key" ]; then
      echo "--floor 형식은 <도메인>=<n>이다(받은 값: '${_tf_spec}')" >&2; return 2
    fi
    case "$_tf_val" in
      ''|*[!0-9]*) echo "--floor ${_tf_key}는 음이 아닌 정수여야 한다(받은 값: '${_tf_val}')" >&2; return 2 ;;
    esac
    _tf_val=$((10#$_tf_val))
    # 선언 순회 — IFS·글롭을 고정한다: 콜사이트가 IFS를 바꿔 두면(형제 가드의 `IFS=,` 류) 매칭이
    # 조용히 무너져 fail-open이고, 글롭 문자가 든 선언은 파일명으로 확장된다(리뷰 실측 재현).
    _tf_oifs="$IFS"; IFS=' '
    _tf_noglob=0; case $- in *f*) _tf_noglob=1 ;; esac
    set -f
    _tf_hit=""; _tf_hits=0; _tf_hitlist=""
    for _tf_lbl in $_tf_allowed; do
      if [ "$_tf_lbl" = "$_tf_key" ] || [ "${_tf_lbl##*:}" = "$_tf_key" ]; then
        _tf_hit="$_tf_lbl"; _tf_hits=$((_tf_hits + 1))
        _tf_hitlist="${_tf_hitlist}${_tf_hitlist:+ · }${_tf_lbl}"
      fi
    done
    [ "$_tf_noglob" -eq 1 ] || set +f
    IFS="$_tf_oifs"
    if [ "$_tf_hits" -eq 0 ]; then
      _tf_render="$(printf '%s' "$_tf_allowed" | sed 's/ / · /g')"
      echo "--floor 도메인 '${_tf_key}'가 이 가드의 선언 도메인에 없다(허용: ${_tf_render}) — 오타 키는 조용히 꺼진 바닥값이 된다(fail-closed)" >&2
      return 2
    fi
    if [ "$_tf_hits" -gt 1 ]; then
      echo "--floor 도메인 '${_tf_key}'가 ${_tf_hits}개 도메인에 걸린다(${_tf_hitlist}) — 전체 라벨로 지정하라" >&2
      return 2
    fi
    # 같은 키 재등장은 덮어쓴다(마지막 승 — TS Map.set 동형).
    _tf_j=0; _tf_found=0
    while [ "$_tf_j" -lt "${#_FLOOR_KEYS[@]}" ]; do
      if [ "${_FLOOR_KEYS[$_tf_j]}" = "$_tf_hit" ]; then _FLOOR_VALS[_tf_j]="$_tf_val"; _tf_found=1; fi
      _tf_j=$((_tf_j + 1))
    done
    if [ "$_tf_found" -eq 0 ]; then _FLOOR_KEYS+=("$_tf_hit"); _FLOOR_VALS+=("$_tf_val"); fi
    shift 2
  done
  return 0
}

# ⚠️ source 시점 초기화 — take_floors를 부르지 않은 콜사이트의 floor_of/floor_set이 raw unbound
#    진단(또는 커맨드 치환 안에서의 조용한 rc 소실)으로 갈리지 않고, 항상 "오버라이드 없음"이라는
#    일관된 의미로 수렴한다(그때 argv의 --floor 자체는 콜사이트 argv 루프가 unknown arg로 거부한다).
REST_ARGV=(); _FLOOR_KEYS=(); _FLOOR_VALS=()

# 유효 min 해소 — 오버라이드가 있으면 그 값, 없으면 콜사이트 기본값(수치는 소비자 소유).
floor_of() {
  _fo_i=0
  while [ "$_fo_i" -lt "${#_FLOOR_KEYS[@]}" ]; do
    if [ "${_FLOOR_KEYS[$_fo_i]}" = "$1" ]; then echo "${_FLOOR_VALS[$_fo_i]}"; return 0; fi
    _fo_i=$((_fo_i + 1))
  done
  echo "$2"
}

# 명시 여부 판정 — "픽스처가 명시하면 적용" 류 의미론(check-image-pins의 구 MIN_SCAN_APPS_SET)이
# 콜사이트 손 플래그 없이 커널로 접힌다. rc 0=명시됨 / 1=기본값.
floor_set() {
  _fs_i=0
  while [ "$_fs_i" -lt "${#_FLOOR_KEYS[@]}" ]; do
    if [ "${_FLOOR_KEYS[$_fs_i]}" = "$1" ]; then return 0; fi
    _fs_i=$((_fs_i + 1))
  done
  return 1
}
