#!/usr/bin/env bash
# vmalert **발화** e2e 하네스 공용 프리미티브 — hermetic(vmsingle + vmalert 컨테이너) replay 실행기.
#
# 왜 lib인가: 이 계열 게이트("룰이 파싱된다"가 아니라 "실제로 발화한다")는 알림마다 산술·시나리오가
# 다르지만 **골격은 동일**하다 — vmsingle 기동 → 합성 시계열 import → vmalert replay(⚠️ max_lookback
# 주입) → ALERTS 질의. 그 골격만 여기 모은다. 알림별 산술/레그/픽스처는 각 하네스에 남는다.
#
# ⚠️ 이 lib은 발화 e2e **6종 전부**의 replay 경로 SSOT다 — 인라인 사본은 0이다(마지막 사본이던
#    tests/gates/vmalert-drift-firing-e2e.sh도 흡수됐다). 그 "사본 0"은 문서가 아니라
#    tests/gates/test_vmalert-e2e-replay-timing.bats가 적극 단언한다. 고치면 소비자 전량이
#    영향권이니 재실행해 확인할 것.
#
# 사용: source 후 caller가 `set -euo pipefail`을 소유한다(lib은 셸 옵션을 건드리지 않는다).

VME_CONTAINERS=""   # 정리 대상 컨테이너 목록(공백 구분)
VME_NET=""          # docker 네트워크명
VME_BASE=""         # 최근 기동한 vmsingle의 http base URL
VME_QUERY_ARGS=()   # vme_query_args가 조립하는 curl 인자
VME_W=""            # vme_assert_rollup_ok의 출력: rollup 윈도(예 2h — 부재+skip 정책이면 빈 값)
VME_W_S=0           # vme_assert_rollup_ok의 출력: 같은 윈도(초 — 부재 시 0)
VME_RULES=""        # vme_scenario의 출력: 배포 ConfigMap에서 추출한 룰 파일 경로

# 30s|5m|2h|3d(단위 없으면 초) → 초.
# ⚠️ **fail-closed**: 빈 값·비수치는 즉시 FAULT다. 예전엔 인식 못 한 입력을 **그대로 되돌려줬는데**, 그게
#    두 갈래로 조용히 물었다 — ⓐ yq는 부재 키에 `null`을 준다 → `$(( X % Y ))`가 `null`을 **변수명**으로
#    읽어 `set -u`에서 "null: unbound variable" 잡음 크래시(깔끔한 CONTRACT가 아니다) ⓑ 빈 문자열은 산술에서
#    **0으로 평가**돼 부등식이 조용히 참이 된다(= 상한을 하나도 강제 못 한 채 green — fail-open).
vme_to_s() {
  local v="${1:-}" num unit=""
  case "$v" in
    *[smhd]) unit="${v: -1}"; num="${v%?}" ;;
    *) num="$v" ;;
  esac
  case "$num" in
    '' | *[!0-9]*)
      vme_fault "vme_to_s: duration '$v'을(를) 초로 변환할 수 없다(빈 값/비수치 — yq의 'null' 포함). 호출부의 파생이 실패했다는 뜻이니 그 지점에 fail-closed 가드를 걸어라." ;;
  esac
  case "$unit" in
    m) printf '%s' "$(( num * 60 ))" ;;
    h) printf '%s' "$(( num * 3600 ))" ;;
    d) printf '%s' "$(( num * 86400 ))" ;;
    *) printf '%s' "$num" ;;   # s 또는 단위 없음
  esac
}

vme_iso() { # epoch → RFC3339(UTC) — vmalert --replay.timeFrom/timeTo 입력 형식
  python3 -c 'import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"
}

vme_net_up() { # $1=network name
  VME_NET="$1"
  docker network create "$VME_NET" >/dev/null
}

vme_cleanup() { # trap EXIT에서 호출
  local c
  for c in $VME_CONTAINERS; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  [ -n "$VME_NET" ] && docker network rm "$VME_NET" >/dev/null 2>&1 || true
}

# ── 호스트 포트 밴드 ──────────────────────────────────────────────────────────────
# 밴드·프로브·추첨의 **정의처는 `tests/gates/lib/host-port.sh`다**(#521의 처방이 이 lib 안에 갇혀 있어
# 형제 하네스 둘이 같은 함정 위에 리터럴 포트를 그대로 박은 채 남았던 것을 되돌린 결과다).
# 여기 남은 것은 그 프리미티브를 이 lib의 **종료 규약(HARNESS FAULT = exit 2)** 으로 감싸는 얇은
# 어댑터뿐이다 — host-port.sh는 exit하지 않고 비-0 rc만 내므로, 그 rc를 삼키면 vacuous green이 된다.
# ⚠️ `VME_PORT_*`는 계속 이 lib의 손잡이다(소비자·테스트가 이 이름으로 밴드를 흔든다). 어댑터가
#    호출 직전에 `HP_*`로 옮긴다 — 두 벌의 기본값을 따로 두면 조용히 갈리므로 기본값은 host-port.sh
#    한 곳에서만 온다.
# ⚠️ **이 lib을 다른 위치로 복사해 source하려면 `host-port.sh`도 같이 복사해야 한다** — 형제를
#    `BASH_SOURCE` 기준으로 찾기 때문이다(레포 루트를 추정하면 워크트리·복사본에서 조용히 엉뚱한
#    파일을 집는다). 부재는 **fail-closed**다: 조용히 넘어가면 밴드 검사도 프로브도 없는 채로
#    `_vme_pick_port`가 "command not found"를 내며 재시도 루프를 이상하게 태운다.
_VME_HP_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/host-port.sh"
[ -r "$_VME_HP_LIB" ] || {
  echo "vmalert-e2e: 형제 lib을 읽을 수 없다: ${_VME_HP_LIB} — 이 파일을 복사했다면 host-port.sh도 같은 디렉토리로 복사하라." >&2
  exit 2
}
# shellcheck source=tests/gates/lib/host-port.sh
. "$_VME_HP_LIB"

VME_PORT_LO="${VME_PORT_LO:-$HP_PORT_LO}"
VME_PORT_HI="${VME_PORT_HI:-$HP_PORT_HI}"
VME_NODEPORT_LO="${VME_NODEPORT_LO:-$HP_NODEPORT_LO}"
VME_NODEPORT_HI="${VME_NODEPORT_HI:-$HP_NODEPORT_HI}"
VME_PORT_RANGE_FILE="${VME_PORT_RANGE_FILE:-$HP_PORT_RANGE_FILE}"

_vme_hp_sync() {   # VME_* 손잡이 → HP_* 프리미티브 입력
  HP_PORT_LO="$VME_PORT_LO"; HP_PORT_HI="$VME_PORT_HI"
  HP_NODEPORT_LO="$VME_NODEPORT_LO"; HP_NODEPORT_HI="$VME_NODEPORT_HI"
  HP_PORT_RANGE_FILE="$VME_PORT_RANGE_FILE"
}

_vme_band_assert() { # 밴드가 두 예약 중 하나라도 건드리면 즉시 죽는다(판정 불가는 '통과'가 아니다)
  _vme_hp_sync
  hp_band_assert || vme_fault "포트 밴드 검사가 실패했다(직전 host-port stderr가 원인이다) — 판정 불가는 '통과'가 아니다."
}

_vme_port_free() { hp_port_free "$1"; }

# vmsingle은 컨테이너당 포트를 **하나만** 쓰므로 배제 인자를 넘기지 않는다(넘길 것이 없다).
# 한 하네스가 포트를 둘 이상 뽑아야 하면 `hp_pick_port <이미-뽑은-포트>`를 직접 부른다.
_vme_pick_port() {
  _vme_hp_sync
  hp_pick_port
}

# $3.. = vmsingle에 그대로 넘길 **추가 플래그**(선택). 하네스 고유 스토리지 의미(예: 드리프트 하네스의
# `--dedup.minScrapeInterval` — 합성 KSM 시계열을 scrape 그리드에 정렬)를 인라인 사본 없이 표현하기 위한
# 통로다. 넘기지 않으면 `"$@"`가 0개로 전개돼 기존 소비자의 명령줄은 **바이트 불변**이다.
VME_BIND_TRIES="${VME_BIND_TRIES:-3}"   # 첫 시도 + 재추첨 2회(판별에 필요한 최소치는 2다)

vme_start_vmsingle() { # $1=container name $2=vmsingle version [$3.. = 추가 플래그] → VME_BASE 설정
  local name="$1" ver="$2" port ready got try err log body
  shift 2
  VME_CONTAINERS="$VME_CONTAINERS $name"
  # 밴드를 좁혀도 프로브~`docker run` 사이의 창은 남는다(TOCTOU). 그 잔여만 재시도가 흡수한다.
  try=1; log=""
  while :; do
    port="$(_vme_pick_port)" || exit 2
    # ⚠️ 실패한 `docker run -d`는 컨테이너를 **Created로 남긴다** → 같은 이름 재시도가 "name already
    #    in use"로 죽는다. podman 전용 `--replace`는 docker 양립성이 없으므로 명시적으로 지운다.
    docker rm -f "$name" >/dev/null 2>&1 || true
    if err="$(docker run -d --name "$name" --network "$VME_NET" -p "127.0.0.1:${port}:8428" \
        "victoriametrics/victoria-metrics:${ver}" \
        --storageDataPath=/storage --retentionPeriod=100y --httpListenAddr=:8428 "$@" 2>&1 >/dev/null)"; then
      break
    fi
    log="${log}
--- 시도 ${try} (port=${port}) ---
${err}"
    # ⚠️ 실패를 **메시지·종료코드로 판별하지 않는다** — 같은 podman도 pasta/rootlessport로 문자열이
    #    갈리고 CI dockerd는 또 다르다. venue 의존 판별자는 한 venue에서 조용히 무력해진다.
    #    판별자는 "서로 다른 포트로 다시 하면 되는가" 하나다.
    if [ "$try" -ge "$VME_BIND_TRIES" ]; then
      printf '%s\n' "$log" >&2
      vme_fault "vmsingle(${name}) 기동이 **서로 다른 포트** ${try}개에서 모두 실패했다 — 포트 경합만으로는 설명되지 않는다(위 런타임 stderr가 원인이다)."
    fi
    # ⚠️ 조용한 재시도 금지 — 발생 사실이 로그에 없으면 경합 빈도가 관측되지 않는다.
    echo "RETRY (bind ${try}/${VME_BIND_TRIES}): vmsingle(${name}) port=${port} 기동 실패 — 포트를 새로 뽑아 재시도한다. 런타임 stderr: ${err}" >&2
    try=$(( try + 1 ))
  done
  [ -z "$err" ] || printf '%s\n' "$err" >&2   # 성공 경로의 런타임 경고는 예전처럼 그대로 흘린다
  [ "$try" -eq 1 ] || echo "RETRY (bind): vmsingle(${name}) ${try}번째 시도에서 성공했다." >&2
  # 읽어온 포트를 **쓰지 않고 대조한다.** 예전엔 `docker port` 출력을 그대로 믿었는데, 이제는
  # 우리가 고른 값과 다르면 즉시 죽는다 — 경합으로 매핑이 어긋나면 아래 health 대기가 60×0.5s를
  # 통째로 태운 뒤에야 "not ready"로 죽어 원인이 안 보인다.
  got="$(docker port "$name" 8428/tcp 2>/dev/null | head -1 | sed 's/.*://')"
  [ "$got" = "$port" ] || {
    echo "포트 매핑 불일치: 요청 ${port} / 실제 '${got}' — 포트 경합이거나 런타임이 매핑을 바꿨다" >&2
    docker logs "$name" 2>&1 | tail -20 >&2
    exit 2
  }
  VME_BASE="http://127.0.0.1:${port}"
  ready=0
  for _ in $(seq 60); do
    # ⚠️ 2xx 여부가 아니라 **본문**을 본다. vmsingle의 /health는 `OK`를 준다. 본문이 비면 아직 안 뜬
    #    것이고, 본문이 있는데 `OK`가 아니면 이 호스트 포트가 **우리 컨테이너로 가지 않는다**는 뜻이다
    #    — 밴드가 잘못 옮겨져 NodePort와 겹치면 정확히 이 모양이 된다(실측 2026-08-20: `docker run`도
    #    `docker port` 대조도 통과하는데 curl만 Traefik의 `404 page not found`를 받았다).
    #    예전 코드는 그 상태를 60×0.5s 태운 뒤 "not ready"로 **오진**했다.
    body="$(curl -s --max-time 3 "$VME_BASE/health" 2>/dev/null || true)"
    case "$body" in
      OK*) ready=1; break ;;
      '') ;;
      *) vme_fault "${VME_BASE}/health가 vmsingle이 아닌 응답을 냈다 — 이 호스트 포트가 다른 서비스로 라우팅된다(NodePort DNAT 등). 본문: ${body}" ;;
    esac
    sleep 0.5
  done
  [ "$ready" = 1 ] || { echo "vmsingle($name) not ready" >&2; docker logs "$name" 2>&1 | tail -20 >&2; exit 2; }
}

vme_import() { # $1=jsonl 파일(/api/v1/import 포맷)
  curl -sf -X POST "$VME_BASE/api/v1/import" --data-binary "@$1"
  vme_flush
}

vme_flush() {
  curl -sf -X POST "$VME_BASE/internal/force_flush" >/dev/null
}

# ── replay 지연 파생 ────────────────────────────────────────────────────────────────────────────
# `--replay.rulesDelay`는 룰마다 한 번씩 자므로 이 계열 게이트의 **벽시계 그 자체**다. sleep이 필요한
# 이유는 딱 하나 — 체이닝 레이스: alert 룰이 record 룰의 remoteWrite 결과를 query_range 1회로 읽는데
# 샘플이 아직 적재 전이면 결과가 통째로 비어 ALERTS=0(버그가 아닌데 RED)이 된다.
# ⇒ **체인 없는 룰 파일에선 그 대기가 순수 낭비**라 파일에서 파생한다.
# ⚠️ 체인 있는 파일에서 이 값을 낮추지 마라. "비율(rulesDelay ÷ flushInterval)만 지키면 된다"는 가설은
#    실측으로 기각됐다 — 구속 조건은 비율이 아니라 **절대 지연 예산**이다. 돌아오는 것은 조용한 오답이
#    아니라 **간헐적 거짓 RED**이고 그건 게이트를 신뢰 불가로 만든다.
#    전문·실측치는 docs/traps-detail.md 「vmalert replay rulesDelay」가 SSOT.
VME_DELAY_CHAINED=4s   # 체인 있음 — 실측으로 안전이 확인된 값(낮추지 말 것)
VME_DELAY_PLAIN=1s     # 체인 없음 — vmalert 기본값

# $1=룰 파일 → 4s(체인 있음) | 1s(체인 없음). **fail-closed**: 파싱이 실패하면 보수값(4s)이다.
# 판정: 어떤 `record:` 이름이 **다른 룰의 expr에 등장**하면 체인이다.
vme_rules_delay() {
  local rules="${1:-}" rec exprs
  [ -s "$rules" ] || { printf '%s' "$VME_DELAY_CHAINED"; return 0; }
  rec="$(yq '.groups[].rules[] | select(has("record")) | .record' "$rules" 2>/dev/null | grep -v '^null$' || true)"
  # record 룰이 하나도 없으면 체인은 성립할 수 없다(가장 흔한 경우 — r4 계열).
  [ -n "$rec" ] || { printf '%s' "$VME_DELAY_PLAIN"; return 0; }
  exprs="$(yq '.groups[].rules[].expr' "$rules" 2>/dev/null || true)"
  # expr 추출이 실패했는데 record는 있다 → 체인 여부를 판정 못 한다 → 보수값.
  [ -n "$exprs" ] || { printf '%s' "$VME_DELAY_CHAINED"; return 0; }
  local r
  for r in $rec; do
    case "$exprs" in *"$r"*) printf '%s' "$VME_DELAY_CHAINED"; return 0 ;; esac
  done
  printf '%s' "$VME_DELAY_PLAIN"
}

vme_replay() { # $1=vmsingle 컨테이너명 $2=vmalert 버전 $3=룰파일(호스트) $4=eval $5=lookback $6=from(epoch) $7=to(epoch)
  # ⚠️ ?max_lookback=<queryStep> — **룩백 핀**. vmalert replay는 instant 질의가 아니라 /api/v1/query_range를
  #    쓰는데, VM의 range 질의 룩백(staleness)은 **플래그가 아니라 휴리스틱**이다(데이터 간격·질의 창에 따라
  #    자동 결정 — 라이브 vmalert의 instant 룩백 `-datasource.queryStep`과 무관). 그 휴리스틱이 push 구멍을
  #    **연속 보간**하면 버그 룰조차 발화해 **거짓 GREEN**이 된다(형제 드리프트 하네스: 10분 push에서 실증).
  #    여기서 라이브 룩백을 명시 주입해 그 상한을 **고정**한다 — VM 버전이 바뀌어 휴리스틱이 공격적이 돼도
  #    하네스가 조용히 보간으로 넘어가지 않는다.
  #    ⚠️ 단, 이 핀이 **모든 소비자에서 load-bearing인 것은 아니다**(vmalert-bulkssd: 일 1회 push에선 VM이
  #    애초에 24h 구멍을 보간하지 않아 핀 유무가 판정 동일 — 실측). 보간 방지의 **최종 보증은 각 하네스의
  #    "결함 픽스처가 발화하면 FAIL" 레그**이지 이 핀이 아니다. 핀은 방어선이지 증명이 아니다.
  #
  # rulesDelay는 **룰 파일에서 파생**한다(위 vme_rules_delay 참고 — 체인 없으면 그 대기는 순수 낭비다).
  # flushInterval은 500ms 그대로 둔다: 실측상 이걸 줄여도 레이스는 안 사라졌고(구속 조건이 비율이 아니라
  # 절대 지연이다), 지금 값은 이미 rulesDelay보다 훨씬 작아 제약이 아니다.
  local vm="$1" ver="$2" rules="$3" eval_iv="$4" lookback="$5" from="$6" to="$7" dir base delay
  dir="$(cd "$(dirname "$rules")" && pwd)"
  base="$(basename "$rules")"
  delay="$(vme_rules_delay "$rules")"
  docker run --rm --network "$VME_NET" -v "$dir:/rules:ro" \
    "victoriametrics/vmalert:${ver}" \
    --rule="/rules/$base" \
    --datasource.url="http://${vm}:8428/?max_lookback=${lookback}" \
    --remoteWrite.url="http://${vm}:8428" \
    --remoteWrite.flushInterval=500ms \
    --notifier.blackhole \
    --evaluationInterval="$eval_iv" \
    --replay.timeFrom="$(vme_iso "$from")" \
    --replay.timeTo="$(vme_iso "$to")" \
    --replay.disableProgressBar \
    --replay.rulesDelay="$delay" \
    --loggerLevel=WARN >/dev/null
  # remoteWrite flush를 눌러 판정 전에 ALERTS가 확실히 질의 가능해지도록.
  vme_flush
  sleep 2
  vme_flush
}

# ⚠️ `set -e`(caller 소유): `[ -n "$x" ] && arr+=(…)`를 **맨 문장**으로 쓰면 조건 거짓일 때 리스트가 1로
#    끝나 스크립트가 죽는다(bash 고전 함정). 아래 두 헬퍼는 반드시 if/then으로 쓴다.
vme_query_args() { # $1=query [$2=eval time(epoch)] [$3=max_lookback] → VME_QUERY_ARGS 설정
  VME_QUERY_ARGS=(-sfG "$VME_BASE/api/v1/query" --data-urlencode "query=$1")
  if [ -n "${2:-}" ]; then VME_QUERY_ARGS+=(--data-urlencode "time=$2"); fi
  if [ -n "${3:-}" ]; then VME_QUERY_ARGS+=(--data-urlencode "max_lookback=$3"); fi
}

vme_promql() { # $1=query [$2=eval time(epoch)] [$3=max_lookback] → 스칼라(결과 없으면 0)
  vme_query_args "$@"
  curl "${VME_QUERY_ARGS[@]}" \
    | python3 -c 'import json,sys;r=json.load(sys.stdin)["data"]["result"];print(int(float(r[0]["value"][1])) if r else 0)'
}

vme_series_count() { # $1=query [$2=eval time(epoch)] [$3=max_lookback] → 결과 시리즈 개수(0=빈 벡터).
  # 값이 아니라 **존재**를 볼 때. time/max_lookback을 주면 임의 시점의 **가시성**을 직접 프로브할 수 있다
  # (= 라이브 vmalert instant 질의가 그 시점에 무엇을 보는가).
  vme_query_args "$@"
  curl "${VME_QUERY_ARGS[@]}" \
    | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["data"]["result"]))'
}

# ALERTS 질의(replay 전 구간을 count_over_time으로 훑는다 — 발화가 **언제라도** 있었는가).
vme_firing()  { vme_promql "sum(count_over_time(ALERTS{alertname=\"$1\",alertstate=\"firing\"}[${2:-7d}]))"; }
vme_pending() { vme_promql "sum(count_over_time(ALERTS{alertname=\"$1\",alertstate=\"pending\"}[${2:-7d}]))"; }
vme_alert_series() { vme_promql "count(count_over_time(ALERTS{alertname=\"$1\"}[${2:-7d}]))"; }

# ── 하네스-무관 공통 골격 ───────────────────────────────────────────────────────────────────────────
# 아래는 알림별 산술과 무관한 하네스 골격이다(종료 규약·룰 추출·매니페스트 파생·판정 집계·작업공간).
# ⚠️ 형제 bulkssd·drift 하네스는 접두사 없는 `fault`/`contract`/`fail`/`pass`를 source **뒤에** 자체
#    정의한다 — 진단 라벨("(preflight)")과 판정 집계는 **하네스-로컬 정책**이라 남긴 것이고, 동명이므로
#    그쪽 정의가 이긴다. 프리미티브(질의·docker·매니페스트 파생·작업공간)는 전부 여기로 흡수됐다.

# 종료 규약: 2 = HARNESS FAULT/CONTRACT(전제 붕괴·vacuity) · 1 = leg FAIL · 0 = OK
vme_fault()    { echo "HARNESS FAULT: $*" >&2; exit 2; }
vme_contract() { echo "CONTRACT VIOLATION: $*" >&2; exit 2; }

VME_FAILED=0
vme_fail() { echo "FAIL $*" >&2; VME_FAILED=$(( VME_FAILED + 1 )); }
vme_pass() { echo "PASS $*"; }

vme_alert_expr() { # $1=룰 yaml $2=alert 이름 → expr만(주석 제거 — 주석이 단언을 만족시키는 것 차단)
  yq '.groups[].rules[] | select(.alert=="'"$2"'") | .expr' "$1" | sed 's/#.*//'
}

vme_alert_for() { # $1=룰 yaml $2=alert 이름 → for:(예 15m). **무매치·키 부재 = 빈 문자열**
  # ⚠️ yq는 부재 키에 리터럴 `null`을 준다 → 그대로 vme_to_s에 넘기면 산술에서 잡음 크래시가 난다.
  #    여기서 빈 문자열로 정규화하고, **호출부가 `[ -n … ] || vme_fault`로 fail-closed 가드**를 건다
  #    (형제 vme_alert_expr와 동형 — 무매치를 빈 값으로 내고 판정은 호출부가 한다).
  local v
  v="$(yq '.groups[].rules[] | select(.alert=="'"$2"'") | .for' "$1" | head -1)"
  case "$v" in null) v="" ;; esac
  printf '%s' "$v"
}

vme_rollup_windows() { # $1=expr $2=메트릭명 → 그 메트릭에 걸린 rollup 윈도(공백 구분, 없으면 빈 문자열)
  { grep -oE "[a-z_]+_over_time[[:space:]]*\([[:space:]]*${2}[^]]*\]" <<<"$1" || true; } \
    | { grep -oE '\[[0-9]+[smhd]\]' || true; } | tr -d '[]' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# push 메트릭의 rollup 3검사(**모드 C 방어**의 SSOT) — 알림마다 산문만 다르게 복제되던 것을 한 곳으로 접는다.
#   ① 맨 참조 금지: push 주기 > vmalert instant 룩백이면 주기 후반마다 시리즈가 사라져 expr이 빈 벡터가 되고
#      for: pending이 매 주기 리셋된다(= 조용한 무발화 — 이 알림 클래스가 4번 뚫린 그 양식).
#   ② 다중 윈도 금지: 같은 메트릭에 서로 다른 [W]가 붙으면 "유효 윈도"가 정의되지 않아 아래 산술이 무의미.
#   ③ W ≥ push 주기: 윈도가 주기보다 짧으면 구멍이 그대로 남는다(①과 같은 결말).
# 출력: VME_W(윈도 문자열) / VME_W_S(초). $5=absent 정책 —
#   fault: 맨 참조를 즉시 FAULT(그 알림엔 맨 참조를 잡아낼 자기 RED 레그가 없다 → 여기서 못 막으면 무측정).
#   skip : 검사만 건너뛴다(맨 참조 **자체가 버그**이고 발화 레그가 RED로 잡는 경우 — 자기 RED 경로를 지우지 않는다).
vme_assert_rollup_ok() { # $1=expr $2=메트릭명 $3=push 주기(초) $4=alert명 $5=fault|skip
  local expr="$1" metric="$2" push_s="$3" alert="$4" policy="$5" w
  w="$(vme_rollup_windows "$expr" "$metric")"
  if [ -z "$w" ]; then
    case "$policy" in
      skip)
        echo "[preflight] rollup: ABSENT on ${metric} → W 불변식 검사 skip (이게 버그다 — 발화 레그가 RED로 잡는다)"
        VME_W=""
        VME_W_S=0
        return 0
        ;;
      fault)
        vme_fault "$alert: ${metric}에 rollup 부재(맨 참조) — push 주기(${push_s}s) > 룩백(${VME_LOOKBACK_S}s)이라 매 주기 후반에 시리즈가 사라져 expr이 빈 벡터가 된다(조용한 무발화). last_over_time(${metric}[≥${push_s}s])로 감싸라."
        ;;
      *) vme_fault "vme_assert_rollup_ok: 알 수 없는 absent 정책 '$policy'(fault|skip)" ;;
    esac
  fi
  case "$w" in *' '*) vme_fault "$alert: ${metric}에 rollup 윈도가 복수($w) — 유효 윈도 판정 불가" ;; esac
  # shellcheck disable=SC2034  # 소비자(하네스)가 읽는 출력 변수다
  VME_W="$w"
  VME_W_S="$(vme_to_s "$w")"
  [ "$VME_W_S" -ge "$push_s" ] || vme_fault "$alert: ${metric} 윈도 불변식 위반 (W ≥ push): W=${w}(${VME_W_S}s) < push 주기(${push_s}s) — 주기 사이 구멍이 남아 for: pending이 매 주기 리셋된다(모드 C)."
  echo "[preflight] rollup OK: ${alert} / ${metric} W=${w}(${VME_W_S}s) ≥ push(${push_s}s)"
}

# 배포 매니페스트에서 vmalert/vmsingle 파라미터 파생(하드코딩 0) → VME_VA_VER/VM_VER/EVAL/LOOKBACK(+_S)
# ⚠️ `set -e`: 미지정 플래그는 grep이 1로 끝난다 → 대입이 스크립트를 죽인다. `|| true`로 기본값 분기 보존.
vme_derive_stack_params() { # $1=platform/victoria-stack/prod 디렉토리
  local stack="$1"
  VME_VA_VER="$(grep -oE 'victoriametrics/vmalert:v[0-9.]+' "$stack/vmalert.yaml" | head -1 | cut -d: -f2)"
  VME_VM_VER="$(grep -oE 'victoriametrics/victoria-metrics:v[0-9.]+' "$stack/vmsingle.yaml" | head -1 | cut -d: -f2)"
  [ -n "$VME_VA_VER" ] && [ -n "$VME_VM_VER" ] || vme_fault "이미지 버전 추출 실패(vmalert/vmsingle)"
  VME_EVAL="$(grep -oE -- '--evaluationInterval=[0-9a-z]+' "$stack/vmalert.yaml" | head -1 | cut -d= -f2 || true)"
  [ -n "$VME_EVAL" ] || VME_EVAL=1m   # vmalert 기본
  # vmalert instant 질의의 룩백 = -datasource.queryStep(미지정 시 vmalert 기본 5m). 구멍의 원인 상수다.
  VME_LOOKBACK="$(grep -oE -- '--datasource\.queryStep=[0-9a-z]+' "$stack/vmalert.yaml" | head -1 | cut -d= -f2 || true)"
  [ -n "$VME_LOOKBACK" ] || VME_LOOKBACK=5m   # vmalert 기본
  # shellcheck disable=SC2034  # 소비자(하네스)가 읽는 출력 변수다
  VME_EVAL_S="$(vme_to_s "$VME_EVAL")"
  # shellcheck disable=SC2034  # 소비자(하네스)가 읽는 출력 변수다
  VME_LOOKBACK_S="$(vme_to_s "$VME_LOOKBACK")"
}

vme_workspace() { # $1=docker 네트워크명 → VME_TMP 생성 + EXIT trap(컨테이너·네트워크·tmp 정리) + 네트워크 기동
  VME_TMP="$(mktemp -d)"
  trap 'vme_cleanup; rm -rf "${VME_TMP:-}"' EXIT
  vme_net_up "$1"
}

# ── 시나리오 interface(d5) — 조립의 암묵 순서를 lib 내부로 접는다 ────────────────────────────────
# 마찰의 근원은 전역 VME_*가 아니라 **암묵 순서**였다(체이닝 레이스 2건 전부 순서 사고). 하네스가
# derive → workspace → 룰 추출을 직접 나열하면 그 순서가 호출자 문서가 되고, 한 곳이 어긋나면
# "VME_TMP: unbound" 같은 잡음 크래시나 빈 룰 vacuous green으로 돌아온다 — 그래서 여기가 소유한다.
# 전역 VME_* 출력 변수 계약은 그대로다(+ VME_RULES: 추출된 배포 룰 파일 경로).
#
# 설계 문구의 4단계(workspace → derive → start → import) 중 start·import는 **레그마다 반복**이라
# (실측 5/5 하네스 — 시나리오 라벨별 새 vmsingle) 톱레벨 1회 조립은 vme_scenario가, 레그 미니-조립
# (start → import)은 vme_leg가 나눠 소유한다 — 순서 소유라는 목적은 같고 함수 경계만 실측 구조를 따른다.
vme_scenario() { # $1=net $2=stack 디렉토리 $3=룰 ConfigMap(yaml) $4=.data 키(예 r4.yaml) → VME_RULES 설정
  local net="$1" stack="$2" cm="$3" key="$4"
  vme_derive_stack_params "$stack"
  vme_workspace "$net"
  VME_RULES="$VME_TMP/deployed-rules.yaml"
  # 룰은 배포 ConfigMap에서 **바이트 그대로** 추출한다(재작성하면 "배포된 것"이 아니라 "내가 적은 것"을
  # 검증하게 된다). 추출은 **yq**로 한다 — PyYAML은 설치 보장이 없어 하네스가 환경에 따라 조용히 못
  # 도는 자리가 된다(실측으로 겪었다). yq는 부재 키에 리터럴 `null`을 주므로 [ -s ]만으로는
  # fail-closed가 안 된다 — 전체 비교로 함께 거르고, stderr는 fault에 동봉한다(yq 미설치/파싱 오류/
  # 키 부재 세 갈래가 한 줄로 붕괴하지 않게 — 이 lib의 "런타임 stderr verbatim" 문화).
  local yq_err=""
  yq_err="$( { yq ".data[\"$key\"]" "$cm" > "$VME_RULES"; } 2>&1 )" || : > "$VME_RULES"
  if [ ! -s "$VME_RULES" ] || [ "$(tr -d '[:space:]' < "$VME_RULES")" = "null" ]; then
    vme_fault "룰 추출 실패: $cm (.data[\"$key\"]) — 빈 룰로 진행하면 하네스가 아무것도 측정하지 않는다${yq_err:+. yq stderr: ${yq_err}}"
  fi
}

vme_leg() { # $1=vmsingle 컨테이너명 $2=fixture(jsonl) [$3..=vmsingle 추가 플래그] — 레그 기동의 순서 소유
  # start가 import보다 앞이어야 한다(VME_BASE는 start의 출력이다) — 그 의존을 호출자가 알 필요가 없다.
  local vm="$1" fixture="$2"
  shift 2
  vme_start_vmsingle "$vm" "$VME_VM_VER" "$@"
  vme_import "$fixture"
}
