#!/usr/bin/env bash
# r7-meta(알림의 알림) + r4 grafana 축 발화 e2e — 픽스처 주입 replay(meta-observability 04).
#
# 방식이 형제(bulkssd·drift)와 다른 지점: 이 룰들은 vmalert 자신이 만드는 메트릭(ALERTS·
# ALERTS_FOR_STATE)과 alertmanager 게이지를 읽는다. 실룰을 함께 replay해 vmalert가 ALERTS를
# 생산하게 하면 ① rulesDelay 파생기(record: 이름만 봄)가 이 체인을 못 봐 PLAIN 1s가 나오고
# 거짓 RED가 재현되며(traps 「vmalert replay rulesDelay」) ② core.yaml 20룰 × delay × 레그로
# 벽시계가 곱해진다. 그래서 **합성 픽스처를 주입**한다 — 체인이 아예 없어 1s가 정확하다(spec).
#
# ⚠️ 혼입 방어(조사 리스크 2): 픽스처도 ALERTS라 판정 헬퍼(vme_firing — ALERTS를 셈)와 한
#   TSDB에 섞인다. 픽스처 alertname은 전부 Synthetic* 로 고정하고, 판정 집합(메타 3종)과의
#   서로소를 preflight가 기계로 강제한다 — 겹치면 주입 샘플을 발화로 세는 vacuous green.
# ⚠️ 침묵 레그의 vacuity(리뷰 H2): 생성기가 시리즈를 아예 안 만들어도 침묵은 green이다 —
#   침묵 레그마다 룰의 **좌변 자체**를 프로브해 "픽스처가 실재하고 값이 임계 미만"을 fault로
#   강제한다(형제 bulkssd의 L4 대조군과 같은 역할).
# ⚠️ 파생 대입은 전부 `|| true` 뒤 [ -n ] 검사(리뷰 M2): set -e + pipefail에서 grep 무매치가
#   대입문을 즉사시키면 fail-closed 루프가 도달 불가 죽은 코드가 되고 exit 1(leg FAIL)로
#   오분류된다 — 파생 실패는 exit 2(CONTRACT)여야 한다.
# 종료 규약: 2=HARNESS FAULT/CONTRACT · 1=leg FAIL · 0=OK (lib 소유).
set -euo pipefail
cd "$(dirname "$0")/../.."
. tests/gates/lib/vmalert-e2e.sh

STACK="platform/victoria-stack/prod"
RULES_CM_META="$STACK/rules/r7-meta.yaml"
RULES_CM_R4="$STACK/rules/r4-storage-backup.yaml"

fault()    { vme_fault "$@"; }
contract() { vme_contract "$@"; }

# ── 1) 시나리오 기동(메타) — 스택 파라미터·작업공간·룰 추출은 lib 소유 ─────────────────────────────
vme_scenario "meta-e2e-net-$$" "$STACK" "$RULES_CM_META" "r7.yaml"
TMP="$VME_TMP"
META_RULES="$VME_RULES"

# r4 룰 추출(grafana 레그) — vme_ 접두는 lib 전용(리뷰 L1)이라 하네스-로컬 이름을 쓴다.
# ⚠️ stderr를 `2>/dev/null`로 버리지 않는다 — yq 미설치·파싱 오류·키 부재 **세 갈래**가 「룰 추출 실패」
#    한 문구로 붕괴한다. lib(vme_scenario)의 룰 추출은 이미 stderr를 변수로 받아 fault 문구에 동봉하는데
#    이 로컬 재구현만 그러지 않았다(ADR-0005 「살릴 것 둘」). `-e`는 유지한다 — null 거절은 이미 fail-closed다.
extract_rules() {
  local yq_err=""
  yq_err="$( { yq -e '.data["'"$2"'"]' "$1" > "$3"; } 2>&1 )" || fault "룰 추출 실패: $1[$2]${yq_err:+. yq stderr: ${yq_err}}"
  [ -s "$3" ] || fault "룰 추출 결과가 비었다: $1[$2]"
}
extract_rules "$RULES_CM_R4" "r4.yaml" "$TMP/r4.yaml"

# fail-closed: 겨냥 룰 실존(리네임 시 무성 무측정 방지 — jobfailed 관례)
for want in 'alert: AlertRuleFlapping' 'alert: AlertPipelineWriteStale' 'alert: AlertSuppressionProlonged'; do
  grep -q "$want" "$META_RULES" || fault "배포 룰에 '$want' 부재 — 하네스가 아무것도 측정하지 않는다"
done
grep -q 'alert: GrafanaPluginBudgetLow' "$TMP/r4.yaml" || fault "r4에 GrafanaPluginBudgetLow 부재"
grep -q 'alert: GrafanaDuFingerprintLost' "$TMP/r4.yaml" || fault "r4에 GrafanaDuFingerprintLost 부재"

# ── 2) 룰 파생 상수(하드코딩 금지 — 전 대입 || true + fail-closed 루프) ────────────────────────────
FLAP_EXPR="$(vme_alert_expr "$META_RULES" AlertRuleFlapping || true)"
FLAP_W="$(printf '%s' "$FLAP_EXPR" | grep -oE '\[[0-9]+[smhd]\]' | head -1 | tr -d '[]' || true)"
FLAP_N="$(printf '%s' "$FLAP_EXPR" | grep -oE '>= *[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
FLAP_FOR="$(vme_alert_for "$META_RULES" AlertRuleFlapping || true)"
STALE_T="$(vme_alert_expr "$META_RULES" AlertPipelineWriteStale | grep -oE '> *[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
SUP_EXPR="$(vme_alert_expr "$META_RULES" AlertSuppressionProlonged || true)"
SUP_W="$(printf '%s' "$SUP_EXPR" | grep -oE '\[[0-9]+[smhd]\]' | head -1 | tr -d '[]' || true)"
SUP_MIN_SAMPLES="$(printf '%s' "$SUP_EXPR" | grep -oE '>= *[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
GRAF_EXPR="$(vme_alert_expr "$TMP/r4.yaml" GrafanaPluginBudgetLow || true)"
GRAF_DENOM="$(printf '%s' "$GRAF_EXPR" | grep -oE '/ *[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
GRAF_RATIO="$(printf '%s' "$GRAF_EXPR" | grep -oE '> *0\.[0-9]+' | grep -oE '0\.[0-9]+' | head -1 || true)"
FOR_MAX_S=0
for a in AlertRuleFlapping AlertPipelineWriteStale AlertSuppressionProlonged; do
  f="$(vme_alert_for "$META_RULES" "$a" || true)"; [ -n "$f" ] || fault "for: 파생 실패: $a"
  fs="$(vme_to_s "$f")"; [ "$fs" -gt "$FOR_MAX_S" ] && FOR_MAX_S=$fs
done
for a in GrafanaPluginBudgetLow GrafanaDuFingerprintLost; do
  f="$(vme_alert_for "$TMP/r4.yaml" "$a" || true)"; [ -n "$f" ] || fault "for: 파생 실패: $a"
  fs="$(vme_to_s "$f")"; [ "$fs" -gt "$FOR_MAX_S" ] && FOR_MAX_S=$fs
done
for v in FLAP_W FLAP_N FLAP_FOR STALE_T SUP_W SUP_MIN_SAMPLES GRAF_DENOM GRAF_RATIO; do
  [ -n "${!v}" ] || fault "룰 상수 파생 실패: $v — 룰이 재작성됐다면 파생 정규식을 함께 고쳐라(CONTRACT)"
done
FLAP_W_S="$(vme_to_s "$FLAP_W")"
SUP_W_S="$(vme_to_s "$SUP_W")"

# ── 3) preflight: 픽스처↔판정 서로소(혼입 방어) + 제외 셀렉터 정합 ────────────────────────────────
SYN_FLAP="SyntheticFlappy"
for m in AlertRuleFlapping AlertPipelineWriteStale AlertSuppressionProlonged GrafanaPluginBudgetLow GrafanaDuFingerprintLost; do
  [ "$m" != "$SYN_FLAP" ] || contract "픽스처 alertname($SYN_FLAP)이 판정 집합과 겹친다 — vacuous green"
done
# herestring(c71-3) — grep -oE(다중행 writer 가능)를 grep -q에 직파이프하면 pipefail 아래 조기
# 종료 SIGPIPE(141)로 매치가 있어도 거짓 판정이 난다(scripts/check-sigpipe-writers.sh 분모 ②). 셀렉터
# 추출은 한 번만 하고(grep -oE는 -q 없이 EOF까지 읽어 그 자체는 안전) 이후 대조는 herestring으로 한다.
FLAP_EXCL="$(printf '%s' "$FLAP_EXPR" | grep -oE 'alertname!~"[^"]*"' || true)"
grep -q "$SYN_FLAP" <<<"$FLAP_EXCL" \
  && contract "픽스처 alertname($SYN_FLAP)이 flapping 제외 셀렉터에 있다 — 발화 레그가 원리적으로 침묵"
for m in Watchdog AlertRuleFlapping AlertPipelineWriteStale AlertSuppressionProlonged; do
  grep -q "$m" <<<"$FLAP_EXCL" \
    || contract "flapping 제외 셀렉터에 $m 부재 — 자기참조/상시 firing 루프"
done

# ── 4) 시간창 — eval 그리드 정렬(결정성). sup 계열만 30s 밀도(창 밀도 가드 ≥SUP_MIN_SAMPLES 충족) ──
EVAL_S="$VME_EVAL_S"
NOW="$(date +%s)"
T0=$(( NOW / EVAL_S * EVAL_S ))
RP_TO=$(( T0 - 600 ))
RP_FROM=$(( RP_TO - 3600 ))
BF_STEP=300
SUP_STEP=30
[ $(( RP_TO - RP_FROM )) -gt "$FOR_MAX_S" ] || fault "replay 길이 ≤ 최장 for:(${FOR_MAX_S}s) — 발화 시간이 없다"
echo "[params] eval=${EVAL_S}s flap=${FLAP_N}회/${FLAP_W}·for=${FLAP_FOR} stale=${STALE_T}s sup=${SUP_W}(≥${SUP_MIN_SAMPLES}샘플) graf=${GRAF_RATIO}×${GRAF_DENOM}"
echo "[window] replay $(vme_iso "$RP_FROM") .. $(vme_iso "$RP_TO") (60m) · backfill ${BF_STEP}s(sup ${SUP_STEP}s)"

# ── 5) 픽스처 생성기 — 시나리오별 합성 시계열(JSONL /api/v1/import) ────────────────────────────────
# 형제 하네스(bulkssd·drift)와 같은 관용구 — gen.py를 쓰는 하네스는 ROOT를 명시한다.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="$ROOT/tests/gates/vmalert-meta-gen.py"
[ -x "$GEN" ] || { echo "FAULT: 생성기 부재 $GEN" >&2; exit 2; }

run_leg() { # $1=label $2=scenario $3=rules-file
  local label="$1" scenario="$2" rules="$3" vm="meta-e2e-$1-$$"
  python3 "$GEN" "$scenario" "$RP_FROM" "$RP_TO" "$BF_STEP" "$SUP_STEP" "$FLAP_W_S" "$FLAP_N" "$STALE_T" "$SUP_W_S" "$GRAF_DENOM" > "$TMP/$label.jsonl"
  vme_leg "$vm" "$TMP/$label.jsonl"
  vme_replay "$vm" "$VME_VA_VER" "$rules" "$VME_EVAL" "$VME_LOOKBACK" "$RP_FROM" "$RP_TO"
}

# require_engaged 이식(drift 선례 — 적재 가시화 레이스 판별: 레이스면 재시도 성공, 결함이면 FAULT).
require_engaged() { # $1=레그 $2=alertname $3=vm $4=rules
  local leg="$1" alert="$2" vm="$3" rules="$4" s
  s="$(vme_alert_series "$alert")"
  [ "$s" -eq 0 ] || return 0
  echo "RETRY ($leg): ALERTS{$alert} 시리즈 0 — 적재 가시화 레이스 서명. replay 1회 재시도." >&2
  vme_replay "$vm" "$VME_VA_VER" "$rules" "$VME_EVAL" "$VME_LOOKBACK" "$RP_FROM" "$RP_TO"
  s="$(vme_alert_series "$alert")"
  [ "$s" -gt 0 ] || fault "($leg) 재시도 후에도 ALERTS{$alert} 0 — 레이스가 아니라 결함(이름 변경·룰 삭제·배선 확인)"
  echo "RETRY ($leg): 재시도에서 ${s}건 — 레이스였다." >&2
}

# ── 6) 레그 ────────────────────────────────────────────────────────────────────────────────────────
run_leg l1-flap flap "$META_RULES"
require_engaged L1 AlertRuleFlapping "meta-e2e-l1-flap-$$" "$META_RULES"
C1="$(vme_promql "max(changes(ALERTS_FOR_STATE{alertname=\"$SYN_FLAP\"}[$FLAP_W]))")"
F1="$(vme_firing AlertRuleFlapping)"
if [ "$F1" -gt 0 ]; then vme_pass "L1 AlertRuleFlapping fired on ${C1} activeAt changes/${FLAP_W} (threshold ${FLAP_N}, samples=$F1)"; else vme_fail "L1 AlertRuleFlapping silent despite ${C1} activeAt changes in ${FLAP_W} (threshold ${FLAP_N})"; fi

run_leg l2-flapq flap-quiet "$META_RULES"
# 침묵 vacuity 가드(리뷰 H2): 픽스처가 실재하고 값이 임계 미만임을 좌변으로 증명.
C2="$(vme_promql "max(changes(ALERTS_FOR_STATE{alertname=\"$SYN_FLAP\"}[$FLAP_W]))")"
[ "$C2" -ge 1 ] || fault "(L2) 픽스처 changes=0 — 레그가 판정 대상을 안 만들었다(vacuous silent)"
[ "$C2" -lt "$FLAP_N" ] || fault "(L2) 픽스처 changes=$C2 ≥ 임계 $FLAP_N — 침묵 기대가 성립하지 않는다"
F2="$(vme_firing AlertRuleFlapping)"
if [ "$F2" -eq 0 ]; then vme_pass "L2 AlertRuleFlapping silent on ${C2} changes (below threshold ${FLAP_N})"; else vme_fail "L2 AlertRuleFlapping fired on ${C2} changes — threshold semantics broken (firing=$F2)"; fi

run_leg l3-stale stale "$META_RULES"
require_engaged L3 AlertPipelineWriteStale "meta-e2e-l3-stale-$$" "$META_RULES"
F3="$(vme_firing AlertPipelineWriteStale)"
if [ "$F3" -gt 0 ]; then vme_pass "L3 AlertPipelineWriteStale fired on Watchdog sample ${STALE_T}s+ old"; else vme_fail "L3 AlertPipelineWriteStale silent despite Watchdog last sample predating replay by >${STALE_T}s"; fi

run_leg l4-quiet quiet "$META_RULES"
WD4="$(vme_series_count "ALERTS{alertname=\"Watchdog\"}" "$RP_TO" "$VME_LOOKBACK")"
[ "$WD4" -ge 1 ] || fault "(L4) Watchdog 픽스처가 replay 끝에서 안 보인다 — 침묵이 vacuous(백필 붕괴)"
F4a="$(vme_firing AlertRuleFlapping)"; F4b="$(vme_firing AlertPipelineWriteStale)"; F4c="$(vme_firing AlertSuppressionProlonged)"
if [ "$F4a" -eq 0 ] && [ "$F4b" -eq 0 ] && [ "$F4c" -eq 0 ]; then vme_pass "L4 all meta alerts silent on a healthy pipeline"; else vme_fail "L4 false positive on healthy pipeline: flap=$F4a stale=$F4b sup=$F4c"; fi

run_leg l5-sup sup "$META_RULES"
require_engaged L5 AlertSuppressionProlonged "meta-e2e-l5-sup-$$" "$META_RULES"
F5="$(vme_firing AlertSuppressionProlonged)"
if [ "$F5" -gt 0 ]; then vme_pass "L5 AlertSuppressionProlonged fired on ${SUP_W} of continuous suppression"; else vme_fail "L5 AlertSuppressionProlonged silent despite suppressed>=1 across the whole ${SUP_W} window"; fi

run_leg l6-supq sup-quiet "$META_RULES"
M6v="$(vme_promql "min(min_over_time(alertmanager_alerts{state=\"suppressed\"}[$SUP_W]))")"
S6="$(vme_series_count "last_over_time(alertmanager_alerts{state=\"suppressed\"}[$SUP_W])" "$RP_TO" "$VME_LOOKBACK")"
[ "$S6" -ge 1 ] || fault "(L6) suppressed 픽스처 시리즈가 없다 — 침묵이 vacuous"
[ "$M6v" -eq 0 ] || fault "(L6) 픽스처 min=$M6v ≠ 0 — 침묵 기대가 성립하지 않는다"
F6="$(vme_firing AlertSuppressionProlonged)"
if [ "$F6" -eq 0 ]; then vme_pass "L6 AlertSuppressionProlonged silent when suppression breaks mid-window (min=0)"; else vme_fail "L6 AlertSuppressionProlonged fired despite a 4h zero gap (min_over_time broken)"; fi

run_leg l6b-supshort sup-short "$META_RULES"
CS="$(vme_promql "max(count_over_time(alertmanager_alerts{state=\"suppressed\"}[$SUP_W]))")"
[ "$CS" -ge 1 ] || fault "(L6b) 짧은 suppressed 픽스처가 없다 — 침묵이 vacuous"
[ "$CS" -lt "$SUP_MIN_SAMPLES" ] || fault "(L6b) 픽스처 샘플 $CS ≥ 밀도 하한 $SUP_MIN_SAMPLES — 침묵 기대가 성립하지 않는다"
F6b="$(vme_firing AlertSuppressionProlonged)"
if [ "$F6b" -eq 0 ]; then vme_pass "L6b AlertSuppressionProlonged silent on a 40m-old series (density guard blocks the 24h claim)"; else vme_fail "L6b AlertSuppressionProlonged fired on a 40m-old series — pod-restart false positive (review M3)"; fi

run_leg l7-graf graf "$TMP/r4.yaml"
require_engaged L7 GrafanaPluginBudgetLow "meta-e2e-l7-graf-$$" "$TMP/r4.yaml"
F7="$(vme_firing GrafanaPluginBudgetLow)"
F7b="$(vme_firing GrafanaDuFingerprintLost)"
if [ "$F7" -gt 0 ] && [ "$F7b" -eq 0 ]; then vme_pass "L7 GrafanaPluginBudgetLow fired at 70% budget; FingerprintLost silent (matches=1)"; else vme_fail "L7 budget=$F7(want >0) fingerprint=$F7b(want 0) — wiring broken"; fi

run_leg l8-grafq graf-quiet "$TMP/r4.yaml"
G8="$(vme_promql "max(last_over_time(grafana_data_dir_size_bytes[3d]))" "$RP_TO" "$VME_LOOKBACK")"
[ "$G8" -ge 1 ] || fault "(L8) grafana 픽스처가 없다 — 침묵이 vacuous"
[ "$G8" -lt $(( GRAF_DENOM * 66 / 100 )) ] || fault "(L8) 픽스처 사용량 ${G8}이 임계 근처/이상 — 침묵 기대가 성립하지 않는다"
F8="$(vme_firing GrafanaPluginBudgetLow)"
if [ "$F8" -eq 0 ]; then vme_pass "L8 GrafanaPluginBudgetLow silent at 50% usage (fixture=${G8}B)"; else vme_fail "L8 GrafanaPluginBudgetLow fired at 50% usage — threshold semantics broken"; fi

run_leg l9-fplost fp-lost "$TMP/r4.yaml"
require_engaged L9 GrafanaDuFingerprintLost "meta-e2e-l9-fplost-$$" "$TMP/r4.yaml"
F9="$(vme_firing GrafanaDuFingerprintLost)"
if [ "$F9" -gt 0 ]; then vme_pass "L9 GrafanaDuFingerprintLost fired on matches=0 with a live heartbeat"; else vme_fail "L9 GrafanaDuFingerprintLost silent despite fingerprint 0 + exporter heartbeat — the silent-decay this rule exists to catch"; fi

echo "vmalert-meta-firing-e2e: $(( 10 - VME_FAILED ))/10 legs green"
[ "$VME_FAILED" -eq 0 ] || exit 1
