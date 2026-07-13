#!/usr/bin/env bash
# vmalert **발화** e2e(컨테이너, 배포 버전) — 룰이 "파싱된다"가 아니라 "실제로 발화한다"를 증명한다.
# 형제 게이트 vmalert-rules-validate.sh(-dryRun)는 expr **파싱**만 본다 → 문법은 멀쩡한데 라이브에서
# 영원히 발화하지 못하는 룰(ImageDigestDrift: push 메트릭 rollup 누락 → record 구멍 → for: 리셋,
# 라이브 60일 발화 0)을 통과시킨다. 이 게이트가 그 갭을 닫는다.
#
# 설계:
#  - 룰은 **배포 ConfigMap에서 매 실행 바이트 그대로 추출**(픽스처 복제 금지 → 드리프트 0). for:는 불변.
#  - 버전/주기/룩백은 전부 **매니페스트에서 파생**(하드코딩 0): vmalert·vmsingle 이미지 태그,
#    --evaluationInterval, --datasource.queryStep(미지정=vmalert 기본 5m), digest-exporter 크론.
#  - vmsingle에 합성 시계열을 백필하고 vmalert **replay**로 시간을 앞으로 감아 ALERTS를 remoteWrite시킨다.
#  - ⚠️ naive replay는 **거짓 GREEN**이다: replay는 /api/v1/query_range를 쓰고 VM이 10분 간격 push를
#    연속 보간해버려 버그 룰조차 발화한다(실증됨). 반드시 datasource URL에 ?max_lookback=<queryStep>을
#    붙여 **라이브 instant 질의 룩백**을 복원해야 증상이 재현된다.
#  - 클러스터 접근 0(hermetic). 외부 호출은 이미지 pull뿐. docker는 러너 기본(형제 e2e 선례).
#
# 판정 레그:
#   preflight  룰/크론에서 W·push·for 파싱 → `push ≤ W < for` + `for: 20m` 강제 (위반 = HARNESS FAULT exit 2)
#   L1 지속 드리프트   → ImageDigestDrift **발화해야** 함        (RED 락: 버그 상태에선 실패)
#   L2 드리프트 없음   → ImageDigestDrift 시리즈 **없어야** 함   (오발화 금지)
#   L3 phantom-drift   → bump 수렴 후 **발화 금지**              (rollup 윈도 과대 → 구 digest 부활 오발화 차단)
#   L4 결함 픽스처     → 발화 **부재**                            (하네스 이빨 ①: 버그를 실제로 감지함)
#   L5 가짜픽스 픽스처 → 발화 **부재**                            (하네스 이빨 ②: 가짜 픽스 불통과)
#   L6 ArgoCDOutOfSync → 발화 **존재**                            (하네스 생존: 발화 못 하는 하네스가 아님)
#   L7 우변 텔레메트리 완전 소실(KSM 사망) → 발화 **부재**       (좌변 rollup만 붙이면 생기는 **두 번째
#                                                                 페이징 조건**(거짓 사유) 차단 — 우변 존재 가드 강제)
#   L8 과대 윈도 픽스처(W=30m) + bump → phantom **발화 관측**    (하네스 이빨 ③: L3가 상한에서 실제로 문다)
#   L9 attestation 재빌드(spec=최신 인덱스, image_id=구 인덱스) → 발화 **부재** (라이브 오탐 재현)
#
# 부분 실행: `DRIFT_E2E_LEGS="L9"` 또는 인자(`bash … L1,L2`). 미지정 = 전 레그(기존 동작 동일).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK="$ROOT/platform/victoria-stack/prod"
RULES_CM="$STACK/rules/r6-ci-staleness.yaml"
FIXTURES="$ROOT/tests/gates/fixtures"
GEN="$ROOT/tests/gates/vmalert-drift-gen.py"
START_EPOCH="$(date +%s)"

# ── 1) 배포 매니페스트에서 파라미터 파생(하드코딩 금지 — 형제 vmalert-rules-validate.sh 관례) ────────
VA_VER="$(grep -oE 'victoriametrics/vmalert:v[0-9.]+' "$STACK/vmalert.yaml" | head -1 | cut -d: -f2)"
VM_VER="$(grep -oE 'victoriametrics/victoria-metrics:v[0-9.]+' "$STACK/vmsingle.yaml" | head -1 | cut -d: -f2)"
[ -n "$VA_VER" ] && [ -n "$VM_VER" ] || { echo "이미지 버전 추출 실패(vmalert/vmsingle)"; exit 1; }

# ⚠️ `set -e`: 미지정 플래그는 grep이 1로 끝난다 → 대입이 스크립트를 죽인다. `|| true`로 기본값 분기 보존.
EVAL="$(grep -oE -- '--evaluationInterval=[0-9a-z]+' "$STACK/vmalert.yaml" | head -1 | cut -d= -f2 || true)"
[ -n "$EVAL" ] || EVAL=1m # vmalert 기본
# vmalert instant 질의의 룩백 = -datasource.queryStep (미지정 시 vmalert 기본 5m). 이게 버그의 핵심 상수다.
LOOKBACK="$(grep -oE -- '--datasource\.queryStep=[0-9a-z]+' "$STACK/vmalert.yaml" | head -1 | cut -d= -f2 || true)"
[ -n "$LOOKBACK" ] || LOOKBACK=5m # vmalert 기본
# push 주기 = digest-exporter CronJob 크론의 분 필드(*/N).
CRON="$(yq 'select(.kind=="CronJob") | .spec.schedule' "$STACK/digest-exporter.yaml" | head -1)"
PUSH_MIN="$(printf '%s' "$CRON" | cut -d' ' -f1 | grep -oE '[0-9]+$' || true)"
case "$CRON" in '*/'*) : ;; *) echo "digest-exporter 크론이 */N 형식이 아님: $CRON"; exit 1 ;; esac
[ -n "$PUSH_MIN" ] || { echo "push 주기 추출 실패: $CRON"; exit 1; }

to_s() { # 30s|5m|2h → 초
  case "$1" in
    *s) printf '%s' "${1%s}" ;;
    *m) printf '%s' "$(( ${1%m} * 60 ))" ;;
    *h) printf '%s' "$(( ${1%h} * 3600 ))" ;;
    *) printf '%s' "$1" ;;
  esac
}
EVAL_S="$(to_s "$EVAL")"
LOOKBACK_S="$(to_s "$LOOKBACK")"
PUSH_S=$(( PUSH_MIN * 60 ))
SCRAPE_S=30 # KSM scrape 간격(replay step의 정수배 — 그리드 정렬)

# ── 2) 배포 ConfigMap에서 룰 바이트 그대로 추출(매 실행 재추출 → 픽스처 드리프트 0) ─────────────────
TMP="$(mktemp -d)"
NET="r6drift-e2e-net-$$"
CONTAINERS=""
cleanup() {
  for c in $CONTAINERS; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

yq '.data["r6.yaml"]' "$RULES_CM" > "$TMP/r6-deployed.yaml"
[ -s "$TMP/r6-deployed.yaml" ] || { echo "룰 추출 실패: $RULES_CM"; exit 1; }
cp "$FIXTURES/r6-buggy-expr.yaml" "$TMP/r6-buggy.yaml"
cp "$FIXTURES/r6-fakefix.yaml" "$TMP/r6-fakefix.yaml"
cp "$FIXTURES/r6-overwide-window.yaml" "$TMP/r6-overwide.yaml"

# fail-closed: 하네스가 겨냥하는 룰/레코드가 실제로 존재하는지(리네임 시 무성 무측정 방지)
for want in 'record: app:image_digest_drift' 'alert: ImageDigestDrift' 'alert: ArgoCDOutOfSync'; do
  grep -q "$want" "$TMP/r6-deployed.yaml" || { echo "배포 룰에 '$want' 부재 — 하네스가 아무것도 측정하지 않는다"; exit 1; }
done
FOR="$(yq '.groups[].rules[] | select(.alert=="ImageDigestDrift") | .for' "$TMP/r6-deployed.yaml" | head -1)"
FOR_S="$(to_s "$FOR")"

# ── 2b) preflight: 윈도/`for` 불변식을 **기계가** 강제한다 ──────────────────────────────────────────
# 왜 필요한가: 레그(L3)는 "발화가 없다"는 **음성 관측**뿐이라 경계에서 이빨이 없다. phantom 지속은
# 아래 산술상 `W − 룩백`이므로 L3의 탐지 임계는 `W > for + 룩백`(=25m)이다 → **W=20~25m은 `W < for`를
# 위반해도 L3를 통과한다**. 그 갭은 관측이 아니라 **산술 단언**으로만 닫힌다. `for:`도 마찬가지로 가변
# 룰에서 파생하기만 하면(예: 15m으로 낮춤) 아무도 못 잡는다 → 여기서 못박는다.
# 위반은 **룰 판정이 아니라 전제 붕괴**다 → FAIL(exit 1)이 아니라 **HARNESS FAULT/CONTRACT(exit 2)**.
fault()    { echo "HARNESS FAULT (preflight): $*" >&2; exit 2; }
contract() { echo "CONTRACT VIOLATION (preflight): $*" >&2; exit 2; }

record_expr() { # $1=룰 yaml → app:image_digest_drift의 expr만(주석 제거 — 주석이 단언을 만족시키는 것 차단)
  yq '.groups[].rules[] | select(.record=="app:image_digest_drift") | .expr' "$1" | sed 's/#.*//'
}
rollup_count() { # $1=expr → expr 안의 rollup 함수 호출 수 (⚠️ pipefail: grep 무매치 1 → `|| true` 필수)
  { grep -oE '[a-z_]+_over_time[[:space:]]*\(' <<<"$1" || true; } | wc -l | tr -d ' '
}
push_rollup_window() { # $1=expr → push 메트릭에 걸린 rollup 윈도(없으면 빈 문자열, 복수면 공백 구분)
  { grep -oE '[a-z_]+_over_time[[:space:]]*\([[:space:]]*ghcr_latest_digest[[:space:]]*\[[0-9]+[smh]\]' <<<"$1" || true; } \
    | { grep -oE '\[[0-9]+[smh]\]' || true; } | tr -d '[]' | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# ① `for: 20m` 고정 — 이 하네스에서 **유일하게 의도적으로 하드코딩한 상수**다(나머지는 전부 매니페스트 파생).
#    페이징 임계 자체가 보존 계약이고(낮추면 페이징이 빨라지는 행위 변경), 아래 phantom 산술의 입력이다.
[ "$FOR" = "20m" ] || contract "ImageDigestDrift for:가 20m이 아니다(현재: $FOR). 페이징 임계는 보존 계약이며 하네스 phantom 산술의 입력이다 — 바꾸려면 이 게이트와 계약을 함께 재설계하라."

REC_EXPR="$(record_expr "$TMP/r6-deployed.yaml")"
[ -n "$REC_EXPR" ] || fault "배포 룰에서 record app:image_digest_drift의 expr 추출 실패"
NROLL="$(rollup_count "$REC_EXPR")"
W="$(push_rollup_window "$REC_EXPR")"
case "$NROLL" in
  0)
    # ⚠️ rollup 부재 = **이 버그 자체**다. 여기서 FAULT로 죽으면 RED 경로를 스스로 지우게 된다 →
    #    W 불변식 검사만 건너뛰고 계속 진행한다. "rollup 미착용"은 L1이 RED로 잡는 정상 경로다.
    echo "[preflight] rollup: ABSENT on ghcr_latest_digest → W 불변식 검사 skip (이게 버그다 — L1이 RED로 잡는다)"
    ;;
  1)
    [ -n "$W" ] || fault "record expr에 rollup이 1개 있으나 push 메트릭(ghcr_latest_digest)에 걸려 있지 않다 — 우변 파드 셀렉터에 rollup을 붙이면 구 파드 digest가 되살아나 **진짜 드리프트를 억제**한다(보존 계약 #5: 우변 rollup 금지)."
    case "$W" in *' '*) fault "ghcr_latest_digest에 rollup 윈도가 복수($W) — 어느 것이 유효 윈도인지 판정 불가" ;; esac
    W_S="$(to_s "$W")"
    [ "$PUSH_S" -le "$W_S" ] || fault "윈도 불변식 위반 (push ≤ W): push=${PUSH_MIN}m > W=$W — rollup이 push 구멍을 덮지 못한다(버그가 그대로 남는다)."
    [ "$W_S" -lt "$FOR_S" ] || fault "윈도 불변식 위반 (W < for): W=$W ≥ for=$FOR — rollup은 상태 래치라 bump 후 구 digest가 W 동안 되살아난다. 잔존(≈ W−룩백)이 for:를 넘기면 **bump마다 phantom 오발화**한다(L8이 상한에서 실증). push ≤ W < for 를 지켜라."
    echo "[preflight] W=$W → push(${PUSH_MIN}m) ≤ W < for($FOR) OK"
    ;;
  *)
    fault "record expr에 rollup이 ${NROLL}개 — 좌변 push 메트릭 rollup **1개만** 허용한다. 우변(kube_pod_container_info) rollup은 구 파드 digest를 되살려 진짜 드리프트를 억제한다(보존 계약 #5)."
    ;;
esac

# ② L8 픽스처 산술 자가검증: 과대 윈도 픽스처가 실제로 phantom을 **넘기는지**(W − 룩백 > for) 확인.
#    파라미터가 드리프트해 L8이 이빨을 잃으면 조용히 통과시키지 말고 여기서 크게 실패시킨다.
W_OW="$(push_rollup_window "$(record_expr "$TMP/r6-overwide.yaml")")"
[ -n "$W_OW" ] || fault "fixtures/r6-overwide-window.yaml에서 rollup 윈도 추출 실패 — L8이 아무것도 증명하지 못한다"
W_OW_S="$(to_s "$W_OW")"

# ── 3) 시간창(now 기준 상대, push/scrape 간격의 정수배로 정렬 → 결정성) ─────────────────────────────
# 파드는 exporter보다 **먼저** 새 digest로 전환된다(라이브 순서: 머지 → ArgoCD sync(수분) → exporter는
# 다음 크론 폴링에서야 새 digest를 push). POD_LEAD를 크게 잡을수록 phantom 창이 길어진다 → **worst order**를
# 쓴다: 파드가 마지막 구-digest push **직후**(= 1 scrape 뒤) 전환 → exporter는 꼬박 한 주기를 기다린다.
POD_LEAD=$(( PUSH_S - SCRAPE_S ))
#
# ★ phantom 지속 시간의 산술(L3/L8의 근거 — 상수가 아니라 유도값이다):
#     구 digest 마지막 push  = BUMP − PUSH_S              (BUMP 시각의 push부터 새 digest)
#     구 파드 마지막 샘플    = POD_SWITCH − SCRAPE_S      = BUMP − PUSH_S           (POD_LEAD = PUSH_S − SCRAPE_S)
#     phantom 시작 = 구 파드 마지막 샘플 + 룩백  = BUMP − PUSH_S + LOOKBACK_S   (우변에서 구 digest가 사라지는 시점)
#     phantom 끝   = 구 digest 마지막 push + W    = BUMP − PUSH_S + W           (좌변 rollup 래치가 만료되는 시점)
#     **phantom 지속 = W − 룩백**
#   → 발화 조건: `W − 룩백 > for`  ⇔  `W > for + 룩백` (= 20m + 5m = 25m)
#   → 배포 W=15m: phantom 10m < for 20m → **무발화**(L3가 매 실행 확인하는 음성 관측)
#   → 픽스처 W=30m: phantom 25m > for 20m → **발화**(L8이 매 실행 확인하는 양성 관측 = L3 메커니즘의 이빨)
#   ⚠️ 따라서 L3의 탐지 임계는 `for + 룩백`(25m)이지 `for`(20m)가 아니다 — **W=20~25m은 `W < for`를 어겨도
#      L3를 통과한다**(관측으로는 닫히지 않는 갭). 그 경계는 위 preflight의 `push ≤ W < for` **산술 단언**이
#      전담한다. L3(음성)·L8(양성)·preflight(산술)는 상보적이며 셋 다 있어야 불변식이 강제된다.
#
# 픽스처 산술 preflight — 파생 파라미터가 바뀌어 레그가 무의미해지면 조용히 통과시키지 말고 즉시 실패.
[ "$LOOKBACK_S" -lt "$PUSH_S" ] || { echo "룩백($LOOKBACK) ≥ push 주기(${PUSH_MIN}m) — 구멍이 생기지 않는다(버그 전제 소멸). 레그 산술 재설계 필요"; exit 1; }
[ "$POD_LEAD" -gt "$LOOKBACK_S" ] || { echo "POD_LEAD(${POD_LEAD}s) ≤ 룩백($LOOKBACK) — L3 phantom 레그가 이빨을 잃는다. 픽스처 산술 재설계 필요"; exit 1; }
[ "$PUSH_S" -lt "$FOR_S" ] || { echo "push 주기(${PUSH_MIN}m) ≥ for:($FOR) — 어떤 rollup 윈도도 안전대가 없다. 룰 재설계 필요"; exit 1; }
[ $(( FOR_S % EVAL_S )) -eq 0 ] || { echo "for:($FOR)가 evaluationInterval($EVAL)의 정수배가 아님 — 발화 경계가 비결정적"; exit 1; }
# L8 픽스처가 실제로 상한을 넘는지(phantom = W − 룩백 > for) — 아니면 L8은 양성을 못 뽑고 이빨을 잃는다.
[ $(( W_OW_S - LOOKBACK_S )) -gt "$FOR_S" ] || fault "L8 픽스처(W=$W_OW)의 phantom 지속(W−룩백 = $(( W_OW_S - LOOKBACK_S ))s)이 for($FOR = ${FOR_S}s) 이하 — 과대 윈도 픽스처가 phantom을 넘기지 못한다 = L8이 아무것도 증명하지 못한다. 픽스처 윈도를 for+룩백 초과로 키워라."

NOW="$(date +%s)"
T_END=$(( NOW / PUSH_S * PUSH_S ))   # push 그리드 정렬
DATA_START=$(( T_END - 3 * 3600 ))   # 백필 3h(룩백 워밍업 여유 포함)
RP_FROM=$(( T_END - 2 * 3600 ))      # replay 2h
RP_TO=$(( T_END - 300 ))             # 데이터 끝보다 앞 — 끝단 경계 회피
BUMP=$(( T_END - 3600 ))             # phantom: exporter가 새 digest를 처음 push(= replay 60분 지점)
POD_SWITCH=$(( BUMP - POD_LEAD ))    # 파드는 그보다 POD_LEAD 앞서 전환
DRIFT_MIN=$(( (RP_TO - RP_FROM) / 60 ))

iso() { python3 -c 'import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }

echo "[params] vmalert=$VA_VER vmsingle=$VM_VER eval=$EVAL lookback=$LOOKBACK(queryStep) push=${PUSH_MIN}m for=$FOR"
echo "[window] backfill $(iso "$DATA_START") .. $(iso "$T_END") | replay $(iso "$RP_FROM") .. $(iso "$RP_TO") (${DRIFT_MIN}m)"

# ── 3b) 레그 선택(부분 실행) ────────────────────────────────────────────────────────────────────────
# 기본(미지정) = **전 레그** → 기존 CI 스텝은 인자 없이 호출하므로 무회귀.
#   DRIFT_E2E_LEGS="L9"                      # 신규 레그만 (회귀 락)
#   DRIFT_E2E_LEGS="L1,L2,L3,L4,L5,L7,L8"    # 기존 레그만 (characterization)
#   bash tests/gates/vmalert-drift-firing-e2e.sh L9   # 인자도 동일(인자가 env보다 우선)
# preflight(§2b 산술 단언)는 선택과 무관하게 **항상** 돈다 — 전제 붕괴는 어떤 부분 실행에서도 침묵하면 안 된다.
# L6(하네스 생존)은 L1과 **같은 replay**에 얹혀 있다 → "L6" 지정은 L1을 뜻한다.
# 알 수 없는 이름은 fail-closed(exit 2) — 오타로 "레그 0개 실행 후 green"이 되는 vacuous 통과를 막는다.
ALL_LEGS="L1 L2 L3 L4 L5 L7 L8 L9"
LEGS_IN="${DRIFT_E2E_LEGS:-}"
[ "$#" -gt 0 ] && LEGS_IN="$*"
SELECTED=""
if [ -z "$LEGS_IN" ] || [ "$LEGS_IN" = "all" ]; then
  SELECTED="$ALL_LEGS"
else
  for raw in $(printf '%s' "$LEGS_IN" | tr ',' ' '); do
    case "$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')" in
      L1|L6) leg=L1 ;; # L6는 L1 replay에 동승
      L2) leg=L2 ;;
      L3) leg=L3 ;;
      L4) leg=L4 ;;
      L5) leg=L5 ;;
      L7) leg=L7 ;;
      L8) leg=L8 ;;
      L9|ATTESTATION|ATTESTATION-REBUILD) leg=L9 ;;
      *) echo "알 수 없는 레그: '$raw' (가능: $ALL_LEGS L6 attestation all)" >&2; exit 2 ;;
    esac
    case " $SELECTED " in *" $leg "*) : ;; *) SELECTED="$SELECTED $leg" ;; esac
  done
fi
SELECTED="$(printf '%s' "$SELECTED" | sed 's/^ *//')"
[ -n "$SELECTED" ] || { echo "선택된 레그 0개 — 아무것도 측정하지 않는다"; exit 2; }
want() { case " $SELECTED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
echo "[legs] $SELECTED"

docker network create "$NET" >/dev/null

# ── 4) 레그 실행기: vmsingle 기동 → 합성 백필 → vmalert replay → ALERTS 질의 ────────────────────────
BASE=""
replay() { # $1=label $2=rules-file $3=scenario [$4=pods_expected(yes|no) — ksmdown 레그는 no]
  local label="$1" rules="$2" scenario="$3" pods="${4:-yes}" vm port ready
  vm="r6drift-e2e-$label-$$"
  CONTAINERS="$CONTAINERS $vm"
  docker run -d --name "$vm" --network "$NET" -p 127.0.0.1:0:8428 \
    "victoriametrics/victoria-metrics:${VM_VER}" \
    --storageDataPath=/storage --retentionPeriod=100y --httpListenAddr=:8428 \
    --dedup.minScrapeInterval="${SCRAPE_S}s" >/dev/null
  port="$(docker port "$vm" 8428/tcp | head -1 | sed 's/.*://')"
  BASE="http://127.0.0.1:${port}"
  ready=0
  for _ in $(seq 60); do
    if curl -sf "$BASE/health" >/dev/null 2>&1; then ready=1; break; fi
    sleep 0.5
  done
  [ "$ready" = 1 ] || { echo "vmsingle($label) not ready"; docker logs "$vm" 2>&1 | tail -20; exit 1; }

  python3 "$GEN" "$scenario" "$DATA_START" "$T_END" "$PUSH_S" "$SCRAPE_S" "$BUMP" "$POD_SWITCH" > "$TMP/$label.jsonl"
  curl -sf -X POST "$BASE/api/v1/import" --data-binary "@$TMP/$label.jsonl"
  curl -sf -X POST "$BASE/internal/force_flush" >/dev/null
  # 백필 sanity: 임포트가 조용히 비었으면 모든 레그가 거짓 통과한다(fail-closed).
  [ "$(promql "count(count_over_time(ghcr_latest_digest[4h]))")" -ge 1 ] || { echo "백필 sanity 실패($label): ghcr_latest_digest 시리즈 0"; exit 1; }
  if [ "$pods" = yes ]; then
    [ "$(promql "count(count_over_time(kube_pod_container_info[4h]))")" -ge 1 ] || { echo "백필 sanity 실패($label): kube_pod_container_info 시리즈 0"; exit 1; }
  else
    # ksmdown: **부재 자체가 레그의 전제**다 → 부재를 적극 단언한다(파드가 섞여 들어오면 L7이 무의미해진다).
    [ "$(promql "count(count_over_time(kube_pod_container_info[4h]))")" -eq 0 ] || { echo "백필 sanity 실패($label): 우변 소실 시나리오인데 kube_pod_container_info 시리즈가 존재한다"; exit 1; }
  fi

  # ⚠️ ?max_lookback=<queryStep> — 이게 없으면 replay가 query_range 보간으로 구멍을 메워 거짓 GREEN이 된다.
  # ⚠️ 체이닝 레이스(비결정성의 유일한 원천): alert 룰은 record 룰이 remoteWrite한 시리즈를 **query_range
  #    1회**로 읽는다. record 샘플이 그 시점에 아직 flush 전이면 결과가 통째로 비어 ALERTS=0 → 버그가 아닌데도
  #    RED로 보이는 거짓 실패(실측함). vmalert 문서 요구대로 rulesDelay ≥ flushInterval을 **넉넉히**(8×) 준다.
  docker run --rm --network "$NET" -v "$TMP:/rules:ro" \
    "victoriametrics/vmalert:${VA_VER}" \
    --rule="/rules/$(basename "$rules")" \
    --datasource.url="http://${vm}:8428/?max_lookback=${LOOKBACK}" \
    --remoteWrite.url="http://${vm}:8428" \
    --remoteWrite.flushInterval=500ms \
    --notifier.blackhole \
    --evaluationInterval="$EVAL" \
    --replay.timeFrom="$(iso "$RP_FROM")" \
    --replay.timeTo="$(iso "$RP_TO")" \
    --replay.disableProgressBar \
    --replay.rulesDelay=4s \
    --loggerLevel=WARN >/dev/null

  # remoteWrite flush를 눌러 판정 전에 ALERTS가 확실히 질의 가능해지도록(rulesDelay + force_flush).
  curl -sf -X POST "$BASE/internal/force_flush" >/dev/null
  sleep 2
  curl -sf -X POST "$BASE/internal/force_flush" >/dev/null
  # 하네스 무결성: record 룰 결과가 datasource에 실제로 안착했는지. 0이면 룰 판정이 아니라 **하네스 고장**
  # (체이닝 레이스)이다 — 조용한 거짓 RED로 새지 않도록 여기서 크게 실패시킨다.
  RECORD_SAMPLES="$(promql "sum(count_over_time(app:image_digest_drift[4h]))")"
}

promql() { # $1=query → 스칼라(결과 없으면 0)
  curl -sfG "$BASE/api/v1/query" --data-urlencode "query=$1" \
    | python3 -c 'import json,sys;r=json.load(sys.stdin)["data"]["result"];print(int(float(r[0]["value"][1])) if r else 0)'
}
firing()  { promql "sum(count_over_time(ALERTS{alertname=\"$1\",alertstate=\"firing\"}[4h]))"; }
pending() { promql "sum(count_over_time(ALERTS{alertname=\"$1\",alertstate=\"pending\"}[4h]))"; }
series()  { promql "count(count_over_time(ALERTS{alertname=\"$1\"}[4h]))"; }

FAILED=0
RECORD_SAMPLES=0
fail() { echo "FAIL $*" >&2; FAILED=$(( FAILED + 1 )); }
pass() { echo "PASS $*"; }
# 지속 드리프트를 먹인 레그에서 record 룰 샘플이 0이면 그건 룰 판정이 아니라 하네스 고장이다
# (체이닝 레이스 = record가 flush되기 전에 alert 룰이 query_range 1회로 읽어 빈 결과 → 조용한 거짓 RED).
require_record() {
  [ "$RECORD_SAMPLES" -gt 0 ] || {
    echo "HARNESS FAULT ($1): app:image_digest_drift record produced 0 samples under sustained drift — 룰 판정 불가(record→alert 체이닝 레이스 또는 record 자체 사망). rulesDelay/flushInterval 확인." >&2
    exit 2
  }
}

# ── L1(RED 락) + L6(하네스 생존): 지속 드리프트 + 배포 룰 ───────────────────────────────────────────
if want L1; then
replay l1-drift "$TMP/r6-deployed.yaml" drift
require_record L1
F1="$(firing ImageDigestDrift)"; P1="$(pending ImageDigestDrift)"
F6="$(firing ArgoCDOutOfSync)"
echo "  [L1] deployed rules + sustained drift → record=$RECORD_SAMPLES firing=$F1 pending=$P1"
if [ "$F1" -gt 0 ]; then
  pass "L1 ImageDigestDrift fired under ${DRIFT_MIN}m of sustained drift (firing samples=$F1)"
else
  fail "L1 ImageDigestDrift did not fire despite ${DRIFT_MIN} minutes of sustained drift (firing=0, pending=$P1) — record rule reads the ${PUSH_MIN}m push metric without a rollup, so the series holes out past the ${LOOKBACK} instant-query lookback and the for: ${FOR} hold never accumulates"
fi
echo "  [L6] deployed rules + same run → ArgoCDOutOfSync firing=$F6"
if [ "$F6" -gt 0 ]; then
  pass "L6 harness is alive — ArgoCDOutOfSync(for:15m) fired in the same replay (firing samples=$F6)"
else
  fail "L6 harness is DEAD — ArgoCDOutOfSync did not fire either; every other leg is meaningless"
fi
docker rm -f "r6drift-e2e-l1-drift-$$" >/dev/null 2>&1 || true
fi

# ── L2(음성 대조): 드리프트 없음 ────────────────────────────────────────────────────────────────────
if want L2; then
replay l2-nodrift "$TMP/r6-deployed.yaml" nodrift
S2="$(series ImageDigestDrift)"
echo "  [L2] deployed rules + no drift → record=$RECORD_SAMPLES ALERTS series=$S2"
if [ "$S2" -eq 0 ]; then pass "L2 no false ImageDigestDrift when the running digest matches latest"
else fail "L2 ImageDigestDrift alert series appeared with zero drift (series=$S2) — false positive"; fi
docker rm -f "r6drift-e2e-l2-nodrift-$$" >/dev/null 2>&1 || true
fi

# ── L3(phantom-drift): bump 수렴 후 오발화 금지 ─────────────────────────────────────────────────────
if want L3; then
replay l3-phantom "$TMP/r6-deployed.yaml" phantom
F3="$(firing ImageDigestDrift)"; P3="$(pending ImageDigestDrift)"
echo "  [L3] deployed rules + coherent image bump → record=$RECORD_SAMPLES firing=$F3 pending=$P3"
if [ "$F3" -eq 0 ]; then pass "L3 no phantom page after a coherent image bump (pending=$P3, firing=0)"
else fail "L3 phantom drift paged after a coherent image bump (firing=$F3) — the rollup window resurrects the pre-bump digest for longer than for: ${FOR}; the window must be < for: (and ≥ the ${PUSH_MIN}m push period)"; fi
docker rm -f "r6drift-e2e-l3-phantom-$$" >/dev/null 2>&1 || true
fi

# ── L4(하네스 이빨 ①): 결함 expr 픽스처는 지속 드리프트에도 발화 못 함 ──────────────────────────────
if want L4; then
replay l4-buggy "$TMP/r6-buggy.yaml" drift
require_record L4
F4="$(firing ImageDigestDrift)"; P4="$(pending ImageDigestDrift)"
echo "  [L4] fixtures/r6-buggy-expr.yaml + sustained drift → record=$RECORD_SAMPLES firing=$F4 pending=$P4"
if [ "$F4" -eq 0 ] && [ "$P4" -gt 0 ]; then pass "L4 harness has teeth — the frozen buggy expr stays stuck in pending (pending=$P4, firing=0)"
elif [ "$F4" -gt 0 ]; then fail "L4 the frozen buggy expr FIRED (firing=$F4) — the harness is interpolating the push metric (false GREEN); check ?max_lookback on the datasource URL"
else fail "L4 the frozen buggy expr produced no alert state at all (pending=0) — the synthetic drift never reached the rule; harness is measuring nothing"; fi
docker rm -f "r6drift-e2e-l4-buggy-$$" >/dev/null 2>&1 || true
fi

# ── L5(하네스 이빨 ②): rollup 밖 `or absent()` 가짜 픽스도 통과 못 함 ───────────────────────────────
if want L5; then
replay l5-fakefix "$TMP/r6-fakefix.yaml" drift
require_record L5
F5="$(firing ImageDigestDrift)"; P5="$(pending ImageDigestDrift)"
echo "  [L5] fixtures/r6-fakefix.yaml + sustained drift → record=$RECORD_SAMPLES firing=$F5 pending=$P5"
if [ "$F5" -eq 0 ] && [ "$P5" -gt 0 ]; then pass "L5 harness rejects the fake fix — bare 'or absent()' outside the rollup still cannot hold for: ${FOR} (pending=$P5, firing=0)"
elif [ "$F5" -gt 0 ]; then fail "L5 the fake fix FIRED (firing=$F5) — the harness would green-light a rule that only papers over the hole with a different label set"
else fail "L5 the fake fix produced no alert state at all (pending=0) — harness is measuring nothing"; fi
docker rm -f "r6drift-e2e-l5-fakefix-$$" >/dev/null 2>&1 || true
fi

# ── L7(두 번째 페이징 조건 차단): 우변 텔레메트리 완전 소실(KSM 사망) → 발화 금지 ───────────────────
# 좌변에 rollup을 붙이면 시리즈가 **연속**이 된다. 그 상태에서 우변(kube_pod_container_info)이 통째로
# 사라지면 `unless on (app, digest)`가 아무것도 제거하지 못한다 → 전 앱이 for: 뒤에 발화한다. 그것도
# "실행 중인 이미지가 최신 GHCR digest와 불일치"라는 **거짓 사유**로(진실은 "KSM이 죽었다") — 오늘 없던
# 행위이자 원인 오귀속이다. 픽스는 반드시 **우변 존재 가드**("해당 app에 지금 파드 텔레메트리가 있을 때만
# 드리프트를 주장한다")를 동반해야 한다. KSM 사망 자체는 TargetDown이 페이징한다.
# baseline(현행 버그 룰)에서도 통과한다 — 좌변이 구멍나 오늘도 무발화이므로. 즉 이 레그는 RED가 아니라
# **보존 계약의 증인**이고, 가드 없는 rollup에서만 FAIL한다.
if want L7; then
replay l7-ksmdown "$TMP/r6-deployed.yaml" ksmdown no
F7="$(firing ImageDigestDrift)"; P7="$(pending ImageDigestDrift)"
F7CTL="$(firing ArgoCDOutOfSync)"
echo "  [L7] deployed rules + RHS telemetry loss (no kube_pod_container_info) → record=$RECORD_SAMPLES firing=$F7 pending=$P7 (control ArgoCDOutOfSync firing=$F7CTL)"
# 이 레그의 판정은 "발화 부재"(음성)다 → vmalert가 애초에 아무것도 쓰지 않았어도 통과해버릴 수 있다.
# 대조 알림(ArgoCDOutOfSync: absent 가드로 항상 발화)이 같은 실행에서 발화했는지로 그 vacuous 통과를 막는다.
[ "$F7CTL" -gt 0 ] || {
  echo "HARNESS FAULT (L7): control alert ArgoCDOutOfSync did not fire in the ksmdown replay — vmalert wrote nothing, so 'ImageDigestDrift absent' proves nothing (vacuous pass)." >&2
  exit 2
}
if [ "$F7" -eq 0 ]; then
  pass "L7 no page when the join RHS vanishes (KSM/scrape down) — the rule stays silent instead of blaming every app for an 'image mismatch' (firing=0, pending=$P7)"
else
  fail "L7 ImageDigestDrift FIRED for every app while kube_pod_container_info was entirely absent (firing=$F7) — a rolled-up left side with no RHS existence guard turns a KSM outage into a false 'running image != latest digest' page; add an 'and on (app) (<pod telemetry exists>)' guard (RHS selector itself must stay rollup-free)"
fi
docker rm -f "r6drift-e2e-l7-ksmdown-$$" >/dev/null 2>&1 || true
fi

# ── L8(하네스 이빨 ③): 과대 윈도 픽스처(W=30m) + bump → phantom 발화가 **실제로 관측**돼야 함 ───────
# L3는 "발화가 없다"는 음성 관측뿐이라 메커니즘이 죽어도(백필 오류·룩백 미주입 등) 조용히 통과할 수 있다.
# 같은 phantom 시나리오에서 상한을 넘긴 윈도로 **양성**을 뽑아, L3가 상한에서 실제 이빨을 갖고 있음을
# 매 실행 증명한다(수동 1회 관측을 회귀 게이트로 승격). 산술은 §3의 phantom 유도 참조: W−룩백 > for.
if want L8; then
replay l8-overwide "$TMP/r6-overwide.yaml" phantom
F8="$(firing ImageDigestDrift)"; P8="$(pending ImageDigestDrift)"
PH8=$(( W_OW_S - LOOKBACK_S ))
echo "  [L8] fixtures/r6-overwide-window.yaml (W=$W_OW) + coherent image bump → record=$RECORD_SAMPLES firing=$F8 pending=$P8 (expected phantom ≈ ${PH8}s > for ${FOR_S}s)"
if [ "$F8" -gt 0 ]; then
  pass "L8 harness has teeth on the upper bound — an over-wide rollup window (W=$W_OW) resurrects the pre-bump digest for ~${PH8}s > for: ${FOR} and phantom-pages (firing samples=$F8); this is exactly what L3 must keep out"
else
  fail "L8 the over-wide window fixture did NOT phantom-page (firing=$F8, pending=$P8) — L3's upper-bound teeth are gone: a rule with W ≥ for + lookback would now pass L3 silently. The phantom mechanism (rollup latch vs. instant-query lookback) is broken in this harness — check ?max_lookback, POD_LEAD(${POD_LEAD}s) and the backfill grid"
fi
docker rm -f "r6drift-e2e-l8-overwide-$$" >/dev/null 2>&1 || true
fi

# ── L9(attestation 재빌드): 배포 콘텐츠가 동일한데 인덱스 digest만 갈린 상태 → 발화 **금지** ────────
# 라이브 오탐의 실제 모양(page 앱 실측): buildx가 태그에 push하는 **인덱스**는 provenance/SBOM attestation
# 매니페스트를 포함하는데 그게 **비결정적**이라 소스 무변경 재빌드에도 인덱스 digest가 바뀐다. 반면 arm64
# 자식 매니페스트는 **바이트 동일**이라 containerd는 콘텐츠를 재사용하고 `image_id`로 **최초 저장 시점의
# (구) 인덱스 digest**를 계속 보고한다. 결과: exporter latest == 파드 spec 핀(신 인덱스) ≠ image_id(구 인덱스).
#   → 배포는 최신이고 **실제 드리프트는 0**인데, image_id만 조인하는 현행 룰은 영구 불일치로 오판 → 영구 firing.
# 이 레그가 그 오탐을 못박는다(현행 룰에서는 RED — 그게 이 락의 목적이다).
# ⚠️ 판정이 "발화 부재"(음성)라 vacuous 통과 위험이 있다 → ① 백필 sanity(양변 시리즈 존재, replay 내부에서
#    강제) ② 대조 알림 ArgoCDOutOfSync가 **같은 replay에서 발화**했는지로 이중 차단한다.
#    require_record는 쓰지 않는다 — 픽스 후 이 시나리오의 record 샘플은 **0이 정답**이다(드리프트 없음).
if want L9; then
replay l9-attestation "$TMP/r6-deployed.yaml" attestation
F9="$(firing ImageDigestDrift)"; P9="$(pending ImageDigestDrift)"
F9CTL="$(firing ArgoCDOutOfSync)"
echo "  [L9] deployed rules + attestation rebuild (pod spec pins latest index, containerd image_id still the old index) → record=$RECORD_SAMPLES firing=$F9 pending=$P9 (control ArgoCDOutOfSync firing=$F9CTL)"
[ "$F9CTL" -gt 0 ] || {
  echo "HARNESS FAULT (L9): control alert ArgoCDOutOfSync did not fire in the attestation replay — vmalert wrote nothing, so 'ImageDigestDrift absent' proves nothing (vacuous pass)." >&2
  exit 2
}
if [ "$F9" -eq 0 ]; then
  pass "L9 no page after an attestation-only rebuild — the deployed content is identical (arm64 child manifest byte-identical) so the rule stays silent (firing=0, pending=$P9)"
else
  fail "L9 ImageDigestDrift FIRED while the deployed content is identical (firing=$F9, pending=$P9) — the pod spec pins the same GHCR index digest the exporter reports as latest, but containerd keeps reporting the OLD index digest in image_id because the arm64 child manifest is byte-identical (buildx attestation manifests are non-deterministic, so a source-identical rebuild mints a new index digest). Joining GHCR's index digest against image_id alone turns this permanent mismatch into a permanent page — compare against the deployed pin (image_spec) instead"
fi
docker rm -f "r6drift-e2e-l9-attestation-$$" >/dev/null 2>&1 || true
fi

echo "[elapsed] $(( $(date +%s) - START_EPOCH ))s"
if [ "$FAILED" -gt 0 ]; then
  echo "vmalert-drift-firing-e2e: ${FAILED} leg(s) FAILED (legs=$SELECTED)" >&2
  exit 1
fi
echo "vmalert-drift-firing-e2e OK (preflight + 선택 레그 [$SELECTED] 통과 — ImageDigestDrift는 실제 드리프트에만 발화하고, 오발화/가짜픽스/KSM-장애-오귀속/과대윈도/attestation-재빌드는 차단)"
