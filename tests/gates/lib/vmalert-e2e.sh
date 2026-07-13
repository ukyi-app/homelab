#!/usr/bin/env bash
# vmalert **발화** e2e 하네스 공용 프리미티브 — hermetic(vmsingle + vmalert 컨테이너) replay 실행기.
#
# 왜 lib인가: 이 계열 게이트("룰이 파싱된다"가 아니라 "실제로 발화한다")는 알림마다 산술·시나리오가
# 다르지만 **골격은 동일**하다 — vmsingle 기동 → 합성 시계열 import → vmalert replay(⚠️ max_lookback
# 주입) → ALERTS 질의. 그 골격만 여기 모은다. 알림별 산술/레그/픽스처는 각 하네스에 남는다.
#
# ⚠️ 형제 tests/gates/vmalert-drift-firing-e2e.sh는 **인라인 사본을 유지한다**(이미 머지된 회귀 가드 —
#    행위 무변경 이관은 이 버그픽스의 범위 밖이다). 이 lib을 고칠 때 소비자는 재실행해 확인할 것.
#
# 사용: source 후 caller가 `set -euo pipefail`을 소유한다(lib은 셸 옵션을 건드리지 않는다).

VME_CONTAINERS=""   # 정리 대상 컨테이너 목록(공백 구분)
VME_NET=""          # docker 네트워크명
VME_BASE=""         # 최근 기동한 vmsingle의 http base URL
VME_QUERY_ARGS=()   # vme_query_args가 조립하는 curl 인자

vme_to_s() { # 30s|5m|2h|3d → 초
  case "$1" in
    *s) printf '%s' "${1%s}" ;;
    *m) printf '%s' "$(( ${1%m} * 60 ))" ;;
    *h) printf '%s' "$(( ${1%h} * 3600 ))" ;;
    *d) printf '%s' "$(( ${1%d} * 86400 ))" ;;
    *) printf '%s' "$1" ;;
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

vme_start_vmsingle() { # $1=container name $2=vmsingle version → VME_BASE 설정
  local name="$1" ver="$2" port ready
  VME_CONTAINERS="$VME_CONTAINERS $name"
  docker run -d --name "$name" --network "$VME_NET" -p 127.0.0.1:0:8428 \
    "victoriametrics/victoria-metrics:${ver}" \
    --storageDataPath=/storage --retentionPeriod=100y --httpListenAddr=:8428 >/dev/null
  port="$(docker port "$name" 8428/tcp | head -1 | sed 's/.*://')"
  VME_BASE="http://127.0.0.1:${port}"
  ready=0
  for _ in $(seq 60); do
    if curl -sf "$VME_BASE/health" >/dev/null 2>&1; then ready=1; break; fi
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
  local vm="$1" ver="$2" rules="$3" eval_iv="$4" lookback="$5" from="$6" to="$7" dir base
  dir="$(cd "$(dirname "$rules")" && pwd)"
  base="$(basename "$rules")"
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
    --replay.rulesDelay=4s \
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
# ⚠️ 형제 tests/gates/vmalert-bulkssd-firing-e2e.sh·vmalert-drift-firing-e2e.sh는 **인라인 사본을 유지한다**
#    (이미 머지된 보존 계약의 측정 도구 — 다른 기능 작업 중에 바꾸지 않는다: 백로그 F-5). 그쪽은 접두사 없는
#    동명 함수를 source **뒤에** 자체 정의하므로 그쪽 정의가 이긴다 → 아래 `vme_` 접두 추가는 무해하다.

# 종료 규약: 2 = HARNESS FAULT/CONTRACT(전제 붕괴·vacuity) · 1 = leg FAIL · 0 = OK
vme_fault()    { echo "HARNESS FAULT: $*" >&2; exit 2; }
vme_contract() { echo "CONTRACT VIOLATION: $*" >&2; exit 2; }

VME_FAILED=0
vme_fail() { echo "FAIL $*" >&2; VME_FAILED=$(( VME_FAILED + 1 )); }
vme_pass() { echo "PASS $*"; }

vme_alert_expr() { # $1=룰 yaml $2=alert 이름 → expr만(주석 제거 — 주석이 단언을 만족시키는 것 차단)
  yq '.groups[].rules[] | select(.alert=="'"$2"'") | .expr' "$1" | sed 's/#.*//'
}

vme_rollup_windows() { # $1=expr $2=메트릭명 → 그 메트릭에 걸린 rollup 윈도(공백 구분, 없으면 빈 문자열)
  { grep -oE "[a-z_]+_over_time[[:space:]]*\([[:space:]]*${2}[^]]*\]" <<<"$1" || true; } \
    | { grep -oE '\[[0-9]+[smhd]\]' || true; } | tr -d '[]' | sort -u | tr '\n' ' ' | sed 's/ *$//'
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
