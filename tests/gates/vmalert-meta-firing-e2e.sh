#!/usr/bin/env bash
# r7-meta(알림의 알림) 발화 e2e — 픽스처 주입 replay(meta-observability 04).
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
# ⚠️ GrafanaPluginBudgetLow(r4 — 02)의 레그도 여기서 돈다: bulkssd 하네스는 rollup 버그 재현
#   전용 정밀 구조(생성기·시간창이 그 룰 전용)라 침습이 크고, 이 하네스의 주입 방식이 정확히
#   그 레그의 형태다(합성 grafana_data_dir_size_bytes → r4 replay).
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

# r4 룰도 추출한다(grafana 레그) — 두 번째 vme_scenario는 작업공간을 덮으므로 추출물만 복사.
vme_extract_rules() { yq -e '.data["'"$2"'"]' "$1" > "$3"; [ -s "$3" ] || fault "룰 추출 실패: $1[$2]"; }
vme_extract_rules "$RULES_CM_R4" "r4.yaml" "$TMP/r4.yaml"

# fail-closed: 겨냥 룰 실존(리네임 시 무성 무측정 방지 — jobfailed 관례)
for want in 'alert: AlertRuleFlapping' 'alert: AlertPipelineWriteStale' 'alert: AlertSuppressionProlonged'; do
  grep -q "$want" "$META_RULES" || fault "배포 룰에 '$want' 부재 — 하네스가 아무것도 측정하지 않는다"
done
grep -q 'alert: GrafanaPluginBudgetLow' "$TMP/r4.yaml" || fault "r4에 GrafanaPluginBudgetLow 부재"

# ── 2) 룰 파생 상수(하드코딩 금지 — jobfailed 관례) ────────────────────────────────────────────────
FLAP_EXPR="$(vme_alert_expr "$META_RULES" AlertRuleFlapping)"
FLAP_W="$(printf '%s' "$FLAP_EXPR" | grep -oE '\[[0-9]+[smhd]\]' | head -1 | tr -d '[]')"
FLAP_N="$(printf '%s' "$FLAP_EXPR" | grep -oE '>= *[0-9]+' | grep -oE '[0-9]+')"
FLAP_FOR_S="$(vme_to_s "$(vme_alert_for "$META_RULES" AlertRuleFlapping)")"
STALE_T="$(vme_alert_expr "$META_RULES" AlertPipelineWriteStale | grep -oE '> *[0-9]+' | grep -oE '[0-9]+')"
STALE_FOR_S="$(vme_to_s "$(vme_alert_for "$META_RULES" AlertPipelineWriteStale)")"
SUP_W="$(vme_alert_expr "$META_RULES" AlertSuppressionProlonged | grep -oE '\[[0-9]+[smhd]\]' | head -1 | tr -d '[]')"
SUP_FOR_S="$(vme_to_s "$(vme_alert_for "$META_RULES" AlertSuppressionProlonged)")"
GRAF_EXPR="$(vme_alert_expr "$TMP/r4.yaml" GrafanaPluginBudgetLow)"
GRAF_DENOM="$(printf '%s' "$GRAF_EXPR" | grep -oE '/ *[0-9]+' | grep -oE '[0-9]+')"
GRAF_RATIO="$(printf '%s' "$GRAF_EXPR" | grep -oE '> *0\.[0-9]+' | grep -oE '0\.[0-9]+')"
GRAF_FOR_S="$(vme_to_s "$(vme_alert_for "$TMP/r4.yaml" GrafanaPluginBudgetLow)")"
for v in FLAP_W FLAP_N FLAP_FOR_S STALE_T STALE_FOR_S SUP_W SUP_FOR_S GRAF_DENOM GRAF_RATIO GRAF_FOR_S; do
  [ -n "${!v}" ] || fault "룰 상수 파생 실패: $v"
done
FLAP_W_S="$(vme_to_s "$FLAP_W")"
SUP_W_S="$(vme_to_s "$SUP_W")"

# ── 3) preflight: 픽스처↔판정 서로소(혼입 방어) + 제외 셀렉터 정합 ────────────────────────────────
SYN_FLAP="SyntheticFlappy"; SYN_WD="Watchdog"   # Watchdog 픽스처는 WriteStale의 정당 입력이다
META_SET="AlertRuleFlapping AlertPipelineWriteStale AlertSuppressionProlonged GrafanaPluginBudgetLow"
for m in $META_SET; do
  [ "$m" != "$SYN_FLAP" ] || contract "픽스처 alertname($SYN_FLAP)이 판정 집합과 겹친다 — 주입 샘플을 발화로 세는 vacuous green"
done
# 픽스처 alertname이 flapping 제외 목록에 걸리면 발화 레그가 원리적으로 못 운다(반대 방향 vacuity).
printf '%s' "$FLAP_EXPR" | grep -oE 'alertname!~"[^"]*"' | grep -q "$SYN_FLAP" \
  && contract "픽스처 alertname($SYN_FLAP)이 flapping 제외 셀렉터에 있다 — 발화 레그가 원리적으로 침묵"
# 제외 목록에 메타 자신들이 있는지(자기참조 루프 방어가 살아 있는지 — 03 게이트와 이중 증인)
for m in Watchdog AlertRuleFlapping AlertPipelineWriteStale AlertSuppressionProlonged; do
  printf '%s' "$FLAP_EXPR" | grep -oE 'alertname!~"[^"]*"' | grep -q "$m" \
    || contract "flapping 제외 셀렉터에 $m 부재 — 자기참조/상시 firing 루프"
done

# ── 4) 시간창 — eval 그리드 정렬(결정성) ──────────────────────────────────────────────────────────
EVAL_S="$VME_EVAL_S"
NOW="$(date +%s)"
T0=$(( NOW / EVAL_S * EVAL_S ))
RP_TO=$(( T0 - 600 ))
RP_FROM=$(( RP_TO - 3600 ))       # 1h replay — 최장 for:(30m)의 2배
BF_STEP=300                        # 백필 샘플 간격 5m — min_over_time[24h] 창에 공백 없음
[ $(( RP_TO - RP_FROM )) -gt "$FLAP_FOR_S" ] || fault "replay 길이 ≤ flapping for: — 발화 시간이 없다"
[ $(( RP_TO - RP_FROM )) -gt "$GRAF_FOR_S" ] || fault "replay 길이 ≤ grafana for: — 발화 시간이 없다"
echo "[params] eval=${EVAL_S}s flap=${FLAP_N}회/${FLAP_W}·for=${FLAP_FOR_S}s stale=${STALE_T}s·for=${STALE_FOR_S}s sup=${SUP_W}·for=${SUP_FOR_S}s graf=${GRAF_RATIO}×${GRAF_DENOM}·for=${GRAF_FOR_S}s"
echo "[window] replay $(vme_iso "$RP_FROM") .. $(vme_iso "$RP_TO") (60m) · backfill step ${BF_STEP}s"

# ── 5) 픽스처 생성기 — 시나리오별 합성 시계열(JSONL /api/v1/import) ────────────────────────────────
GEN="$TMP/gen-meta.py"
cat > "$GEN" <<'PY'
import json, sys
scenario, rp_from, rp_to, step = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
flap_w, flap_n = int(sys.argv[5]), int(sys.argv[6])
stale_t = int(sys.argv[7]); sup_w = int(sys.argv[8]); graf_denom = int(sys.argv[9])
out = []
def series(metric, labels, pairs):  # pairs: [(ts_s, value)]
    m = {"__name__": metric}; m.update(labels)
    out.append({"metric": m, "values": [v for _, v in pairs], "timestamps": [t * 1000 for t, _ in pairs]})
def grid(a, b, st): return list(range(a, b + 1, st))
# 공통: Watchdog ALERTS — 정상이면 replay 끝까지 신선(모든 시나리오에서 WriteStale 대조군 겸용).
wd_end = rp_to if scenario != "stale" else rp_from - stale_t - 300   # stale: 시작부터 임계+5m 낡음
series("ALERTS", {"alertname": "Watchdog", "alertstate": "firing", "severity": "none"},
       [(t, 1) for t in grid(rp_from - 2 * 3600, wd_end, step)])
if scenario == "flap":   # activeAt이 창 안에서 flap_n+2회 갱신 — 임계 초과
    start = rp_to - flap_w + 600
    n = flap_n + 2
    pairs = []
    for i in range(n):
        seg_a = start + i * (flap_w - 1200) // n
        seg_b = start + (i + 1) * (flap_w - 1200) // n - step
        pairs += [(t, seg_a) for t in grid(seg_a, min(seg_b, rp_to), step)]
    series("ALERTS_FOR_STATE", {"alertname": "SyntheticFlappy", "severity": "warning"}, pairs)
elif scenario == "flap-quiet":   # 2회 갱신 — 임계 미만(정상 해소·재발)
    mid = rp_to - flap_w // 2
    pairs = [(t, rp_to - flap_w) for t in grid(rp_to - flap_w + 600, mid, step)]
    pairs += [(t, mid) for t in grid(mid + step, rp_to, step)]
    series("ALERTS_FOR_STATE", {"alertname": "SyntheticFlappy", "severity": "warning"}, pairs)
elif scenario == "sup":          # suppressed ≥1이 창 전체 + replay 내내
    series("alertmanager_alerts", {"state": "suppressed", "namespace": "observability"},
           [(t, 1) for t in grid(rp_from - sup_w - 600, rp_to, step)])
elif scenario == "sup-quiet":    # 창 중간 4h 동안 0 — min이 0이라 침묵
    a = rp_from - sup_w - 600; hole_a = rp_to - sup_w // 2; hole_b = hole_a + 4 * 3600
    pairs = [(t, 0 if hole_a <= t <= hole_b else 1) for t in grid(a, rp_to, step)]
    series("alertmanager_alerts", {"state": "suppressed", "namespace": "observability"}, pairs)
elif scenario == "graf":         # 사용률 0.70 — 임계(0.66) 초과 (일 1회 push 재현: 하루 전+창 직전 2샘플)
    v = int(graf_denom * 0.70)
    series("grafana_data_dir_size_bytes", {}, [(rp_from - 86400, v), (rp_from - 600, v)])
elif scenario == "graf-quiet":   # 사용률 0.50 — 침묵
    v = int(graf_denom * 0.50)
    series("grafana_data_dir_size_bytes", {}, [(rp_from - 86400, v), (rp_from - 600, v)])
elif scenario == "stale":
    pass  # Watchdog 공통 시계열이 이미 낡음 — 추가 시리즈 없음
elif scenario == "quiet":
    pass  # 정상 Watchdog만 — 4룰 전부 침묵 기대
else:
    raise SystemExit(f"unknown scenario {scenario}")
for s_ in out: print(json.dumps(s_))
PY

run_leg() { # $1=label $2=scenario $3=rules-file
  local label="$1" scenario="$2" rules="$3" vm="meta-e2e-$1-$$"
  python3 "$GEN" "$scenario" "$RP_FROM" "$RP_TO" "$BF_STEP" "$FLAP_W_S" "$FLAP_N" "$STALE_T" "$SUP_W_S" "$GRAF_DENOM" > "$TMP/$label.jsonl"
  vme_leg "$vm" "$TMP/$label.jsonl"
  vme_replay "$vm" "$VME_VA_VER" "$rules" "$VME_EVAL" "$VME_LOOKBACK" "$RP_FROM" "$RP_TO"
}

# require_engaged 이식(drift 선례 — 체이닝이 아니라 **적재→질의 가시화** 레이스 대비. 재시도는
# 숨김이 아니라 판별 장치: 레이스면 성공, 결함이면 두 번 다 0 → FAULT).
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
F1="$(vme_firing AlertRuleFlapping)"
[ "$F1" -gt 0 ] && vme_pass "L1 AlertRuleFlapping fired on $((FLAP_N+2)) resets/${FLAP_W} (samples=$F1)" \
  || vme_fail "L1 AlertRuleFlapping silent despite $((FLAP_N+2)) activeAt resets in ${FLAP_W} (threshold ${FLAP_N})"

run_leg l2-flapq flap-quiet "$META_RULES"
F2="$(vme_firing AlertRuleFlapping)"; S2="$(vme_alert_series SyntheticFlappy)"
[ "$F2" -eq 0 ] && vme_pass "L2 AlertRuleFlapping silent on 1 reset (normal resolve/refire)" \
  || vme_fail "L2 AlertRuleFlapping fired on a single reset — threshold semantics broken (firing=$F2)"

run_leg l3-stale stale "$META_RULES"
require_engaged L3 AlertPipelineWriteStale "meta-e2e-l3-stale-$$" "$META_RULES"
F3="$(vme_firing AlertPipelineWriteStale)"
[ "$F3" -gt 0 ] && vme_pass "L3 AlertPipelineWriteStale fired on Watchdog sample ${STALE_T}s+ old" \
  || vme_fail "L3 AlertPipelineWriteStale silent despite Watchdog last sample predating replay by >${STALE_T}s — the vacuity this rule exists to avoid"

run_leg l4-quiet quiet "$META_RULES"
F4a="$(vme_firing AlertRuleFlapping)"; F4b="$(vme_firing AlertPipelineWriteStale)"; F4c="$(vme_firing AlertSuppressionProlonged)"
[ "$F4a" -eq 0 ] && [ "$F4b" -eq 0 ] && [ "$F4c" -eq 0 ] \
  && vme_pass "L4 all meta alerts silent on a healthy pipeline (fresh Watchdog, no flap, no suppression)" \
  || vme_fail "L4 false positive on healthy pipeline: flap=$F4a stale=$F4b sup=$F4c"

run_leg l5-sup sup "$META_RULES"
require_engaged L5 AlertSuppressionProlonged "meta-e2e-l5-sup-$$" "$META_RULES"
F5="$(vme_firing AlertSuppressionProlonged)"
[ "$F5" -gt 0 ] && vme_pass "L5 AlertSuppressionProlonged fired on ${SUP_W} of continuous suppression" \
  || vme_fail "L5 AlertSuppressionProlonged silent despite suppressed>=1 across the whole ${SUP_W} window"

run_leg l6-supq sup-quiet "$META_RULES"
F6="$(vme_firing AlertSuppressionProlonged)"
[ "$F6" -eq 0 ] && vme_pass "L6 AlertSuppressionProlonged silent when suppression breaks mid-window" \
  || vme_fail "L6 AlertSuppressionProlonged fired despite a 4h gap of zero suppression (min_over_time broken)"

run_leg l7-graf graf "$TMP/r4.yaml"
require_engaged L7 GrafanaPluginBudgetLow "meta-e2e-l7-graf-$$" "$TMP/r4.yaml"
F7="$(vme_firing GrafanaPluginBudgetLow)"
[ "$F7" -gt 0 ] && vme_pass "L7 GrafanaPluginBudgetLow fired at 70% of the declared budget (threshold ${GRAF_RATIO})" \
  || vme_fail "L7 GrafanaPluginBudgetLow silent at 70% usage (threshold ${GRAF_RATIO}) — last_over_time/denominator wiring broken"

run_leg l8-grafq graf-quiet "$TMP/r4.yaml"
F8="$(vme_firing GrafanaPluginBudgetLow)"
[ "$F8" -eq 0 ] && vme_pass "L8 GrafanaPluginBudgetLow silent at 50% usage" \
  || vme_fail "L8 GrafanaPluginBudgetLow fired at 50% usage — threshold semantics broken"

echo "vmalert-meta-firing-e2e: $(( 8 - VME_FAILED ))/8 legs green"
[ "$VME_FAILED" -eq 0 ] || exit 1
