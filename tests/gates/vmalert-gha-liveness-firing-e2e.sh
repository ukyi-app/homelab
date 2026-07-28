#!/usr/bin/env bash
# GHA liveness 알림 **발화** e2e (티켓 10) — hermetic replay로 "실제로 발화하는가"를 증명한다.
#
# 왜 필요한가: `-dryRun`은 expr **파싱**만 본다. 문법이 멀쩡한데 라이브에서 발화가 0인 룰이 이 레포에
# 이미 두 번 있었다(ImageDigestDrift·FilesBulkSSDLow — 둘 다 push 주기 > 룩백으로 시리즈에 구멍이 나
# `for:` pending이 매 주기 리셋됐다). push 메트릭을 읽는 알림에는 이 계열 게이트가 규율이고,
# GHA liveness 3종만 그게 없었다(PR #389가 "알려진 경계"로 적어 둔 갭).
#
# ★ 이 하네스의 **고유 레그는 L7**이다: 임계값이 룰에 하드코딩된 게 아니라 **exporter가 push한 예산
#   메트릭에서 온다**는 설계를 증명한다. 같은 시각에 예산만 다른 두 워크플로를 두고, 예산을 넘은 쪽만
#   발화하는지 본다. 이게 없으면 "예산을 메트릭으로 싣는다"는 설계 주장이 무측정으로 남는다.
#
# 종료 규약(공유 하네스): 2 = HARNESS FAULT/CONTRACT(전제 붕괴·vacuity) · 1 = leg FAIL · 0 = OK
# ⚠️ 이 하네스는 docker가 필요하다 — `tests/.ci-exclude`가 아니라 **ci.yaml gate 스텝**이 직접 부른다
#    (bats 수집 대상이 아니므로 run-bats가 아니라 명시 스텝이어야 죽은 커버리지가 안 된다).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK="$ROOT/platform/victoria-stack/prod"
RULES_CM="$STACK/rules/r6-ci-staleness.yaml"
EXPORTER="$STACK/gha-liveness-exporter.yaml"

# shellcheck source=tests/gates/lib/vmalert-e2e.sh
. "$ROOT/tests/gates/lib/vmalert-e2e.sh"

STALE_ALERT=GHAWorkflowStale
HB_ALERT=GHALivenessExporterStale
SCRAPE_ALERT=GHALivenessScrapeIncomplete

TS_METRIC=gha_workflow_last_success_timestamp
BUDGET_METRIC=gha_workflow_max_age_seconds
# 아래 셋은 시리즈 생성(python)과 진단 산문이 가리키는 **이름의 SSOT**다. 셸에서 직접 읽지는 않지만
# 여기 없으면 이름이 두 곳에 흩어져 갈린다(형제 하네스와 같은 규율).
# shellcheck disable=SC2034
HB=gha_liveness_last_success_timestamp
# shellcheck disable=SC2034
CFG_METRIC=gha_liveness_configured
# shellcheck disable=SC2034
SCRAPED_METRIC=gha_liveness_scraped

# 시나리오 상수 — 진단 산문과 시리즈 생성이 **같은 변수**를 읽는다(따로 적으면 둘이 갈린다).
WF_OVER=over.yaml       # 예산 초과 → 발화해야
WF_UNDER=under.yaml     # 같은 나이인데 예산이 커서 → 침묵해야 (L7의 핵심 대조)
AGE_S=7200              # 두 워크플로 공통 '마지막 성공 이후 경과'(2h)
BUDGET_SMALL=3600       # over: 1h 예산 → 초과
BUDGET_LARGE=21600      # under: 6h 예산 → 여유
N_CFG=2
N_SCRAPED_PARTIAL=1
N_ZERO=0

# ── 1) 배포 매니페스트에서 파라미터 파생(하드코딩 0) ───────────────────────────────────────────────
vme_derive_stack_params "$STACK"

# exporter 크론 주기 = push 주기. 룰의 rollup 윈도 하한이 여기서 나온다.
CRON_MIN="$(grep -oE '^  schedule: "\*/([0-9]+) ' "$EXPORTER" | grep -oE '[0-9]+' || true)"
[ -n "$CRON_MIN" ] || vme_fault "exporter 크론 주기 추출 실패($EXPORTER)"
PUSH_S=$(( CRON_MIN * 60 ))

vme_workspace "r6gha-e2e-net-$$"

# ── 2) 배포 ConfigMap에서 룰 바이트 그대로 추출 ────────────────────────────────────────────────────
# ⚠️ 룰을 여기에 재작성하면 "배포된 것"이 아니라 "내가 적은 것"을 검증하게 된다.
# ⚠️ 추출은 **yq**로 한다 — 형제 하네스와 같은 도구다. python PyYAML을 쓰면 러너·로컬 어디서든
#    설치 보장이 없어 하네스가 환경에 따라 조용히 못 도는 자리가 된다(실측으로 겪었다).
yq '.data["r6.yaml"]' "$RULES_CM" > "$VME_TMP/r6-deployed.yaml"
[ -s "$VME_TMP/r6-deployed.yaml" ] || vme_fault "룰 추출 실패: $RULES_CM"

# fail-closed: 하네스가 겨냥하는 룰이 실제로 존재하는지(리네임 시 무성 무측정 방지)
for a in "$STALE_ALERT" "$HB_ALERT" "$SCRAPE_ALERT"; do
  grep -q "alert: $a" "$VME_TMP/r6-deployed.yaml" \
    || vme_fault "배포 룰에 'alert: $a' 부재 — 하네스가 아무것도 측정하지 않는다"
done

for a in "$STALE_ALERT" "$HB_ALERT" "$SCRAPE_ALERT"; do
  e="$(vme_alert_expr "$VME_TMP/r6-deployed.yaml" "$a")"
  [ -n "$e" ] || vme_fault "$a: 배포 룰에서 expr 추출 실패"
  f="$(vme_alert_for "$VME_TMP/r6-deployed.yaml" "$a")"
  [ -n "$f" ] || vme_fault "$a: for: 부재(무매치 또는 키 없음)"
done
STALE_EXPR="$(vme_alert_expr "$VME_TMP/r6-deployed.yaml" "$STALE_ALERT")"
STALE_FOR_S="$(vme_to_s "$(vme_alert_for "$VME_TMP/r6-deployed.yaml" "$STALE_ALERT")")"
HB_FOR_S="$(vme_to_s "$(vme_alert_for "$VME_TMP/r6-deployed.yaml" "$HB_ALERT")")"
SCRAPE_FOR_S="$(vme_to_s "$(vme_alert_for "$VME_TMP/r6-deployed.yaml" "$SCRAPE_ALERT")")"
HB_EXPR="$(vme_alert_expr "$VME_TMP/r6-deployed.yaml" "$HB_ALERT")"
HB_THRESHOLD_S="$(grep -oE '>[[:space:]]*[0-9]+' <<<"$HB_EXPR" | head -1 | grep -oE '[0-9]+' || true)"
[ -n "$HB_THRESHOLD_S" ] || vme_fault "$HB_ALERT: 임계 상수 추출 실패"

# ── 2b) preflight: 전제를 **기계가** 강제한다(위반 = 룰 판정이 아니라 전제 붕괴 → exit 2) ──────────
# rollup 3검사: 맨 참조 금지 · 다중 윈도 금지 · W ≥ push 주기.
# 정책 `fault`인 이유: 맨 참조가 되면 이 알림엔 그걸 잡아낼 자기 RED 레그가 없다(값이 타임스탬프라
# 구멍이 나도 '오래됨'으로 읽혀 오히려 발화한다) → 여기서 못 막으면 무측정이 된다.
vme_assert_rollup_ok "$STALE_EXPR" "$TS_METRIC" "$PUSH_S" "$STALE_ALERT" fault
W_S="$VME_W_S"
vme_assert_rollup_ok "$STALE_EXPR" "$BUDGET_METRIC" "$PUSH_S" "$STALE_ALERT" fault

# 시나리오 나이가 예산 사이에 있어야 L7이 의미를 갖는다(둘 다 초과/둘 다 여유면 대조가 성립하지 않는다).
[ "$AGE_S" -gt "$BUDGET_SMALL" ] || vme_contract "시나리오 무의미: AGE(${AGE_S}s) <= BUDGET_SMALL(${BUDGET_SMALL}s)"
[ "$AGE_S" -lt "$BUDGET_LARGE" ] || vme_contract "시나리오 무의미: AGE(${AGE_S}s) >= BUDGET_LARGE(${BUDGET_LARGE}s)"
echo "[preflight] 예산 대조 OK: BUDGET_SMALL(${BUDGET_SMALL}s) < AGE(${AGE_S}s) < BUDGET_LARGE(${BUDGET_LARGE}s)"

# ── 3) 합성 시계열 ────────────────────────────────────────────────────────────────────────────────
# replay 창: for:가 성립하려면 창이 충분히 길어야 한다. 세 알림의 for: 중 최대 + 여유.
MAX_FOR_S="$STALE_FOR_S"
[ "$HB_FOR_S" -gt "$MAX_FOR_S" ] && MAX_FOR_S="$HB_FOR_S"
[ "$SCRAPE_FOR_S" -gt "$MAX_FOR_S" ] && MAX_FOR_S="$SCRAPE_FOR_S"
SPAN_S=$(( MAX_FOR_S * 3 + W_S ))
TO_EPOCH="$(date +%s)"
FROM_EPOCH=$(( TO_EPOCH - SPAN_S ))

gen() { # $1=출력파일 $2=시나리오(stale|healthy|hbstale|hbabsent|partial|zero)
  python3 - "$1" "$2" "$FROM_EPOCH" "$TO_EPOCH" "$PUSH_S" "$AGE_S" \
    "$WF_OVER" "$WF_UNDER" "$BUDGET_SMALL" "$BUDGET_LARGE" "$N_CFG" "$N_SCRAPED_PARTIAL" "$N_ZERO" <<'PY'
import json, sys
out, scen, frm, to, push, age, wf_o, wf_u, b_small, b_large, n_cfg, n_part, n_zero = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]),
    int(sys.argv[6]), sys.argv[7], sys.argv[8], int(sys.argv[9]), int(sys.argv[10]),
    int(sys.argv[11]), int(sys.argv[12]), int(sys.argv[13]))

ts = list(range(frm, to + 1, push))          # push 주기마다 한 샘플(라이브와 같은 간격)
lines = []
def series(metric, labels, values):
    m = {"__name__": metric}; m.update(labels)
    lines.append(json.dumps({"metric": m,
                             "values": values,
                             "timestamps": [t * 1000 for t in ts]}))

# 워크플로 타임스탬프: 각 샘플 시점 기준 age 초 전에 마지막 성공.
# healthy면 방금 성공(age=0)으로 둔다.
eff_age = 0 if scen == "healthy" else age
series("gha_workflow_last_success_timestamp", {"workflow": wf_o}, [t - eff_age for t in ts])
series("gha_workflow_last_success_timestamp", {"workflow": wf_u}, [t - eff_age for t in ts])
series("gha_workflow_max_age_seconds", {"workflow": wf_o}, [b_small] * len(ts))
series("gha_workflow_max_age_seconds", {"workflow": wf_u}, [b_large] * len(ts))

# 하트비트: hbstale이면 창 초반에서 멈춘 값(= 오래된 타임스탬프가 계속 보인다),
# hbabsent면 시리즈 자체를 내보내지 않는다(absent 가지 검증).
if scen != "hbabsent":
    if scen == "hbstale":
        frozen = frm  # 창 시작 시각에 마지막 성공 → 창 끝에서 SPAN_S만큼 낡음
        series("gha_liveness_last_success_timestamp", {}, [frozen] * len(ts))
    else:
        series("gha_liveness_last_success_timestamp", {}, list(ts))

# 수집 카운트
if scen == "zero":
    cfg, scraped = n_zero, n_zero
elif scen == "partial":
    cfg, scraped = n_cfg, n_part
else:
    cfg, scraped = n_cfg, n_cfg
series("gha_liveness_configured", {}, [cfg] * len(ts))
series("gha_liveness_scraped", {}, [scraped] * len(ts))

open(out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
}

run_scenario() { # $1=시나리오 → vmsingle 기동 + import + replay
  local scen="$1"
  local vm="vm-gha-$scen-$$"
  vme_start_vmsingle "$vm" "$VME_VM_VER"
  gen "$VME_TMP/$scen.jsonl" "$scen"
  vme_import "$VME_TMP/$scen.jsonl"
  vme_replay "$vm" "$VME_VA_VER" "$VME_TMP/r6-deployed.yaml" "$VME_EVAL" "$VME_LOOKBACK" "$FROM_EPOCH" "$TO_EPOCH"
}

# ── 4) 레그 ───────────────────────────────────────────────────────────────────────────────────────

echo "── L1/L7: 예산 초과 워크플로만 발화한다(임계값이 룰이 아니라 push된 예산에서 온다) ──"
run_scenario stale
n_over="$(vme_promql "sum(count_over_time(ALERTS{alertname=\"$STALE_ALERT\",alertstate=\"firing\",workflow=\"$WF_OVER\"}[7d]))")"
n_under="$(vme_promql "sum(count_over_time(ALERTS{alertname=\"$STALE_ALERT\",alertstate=\"firing\",workflow=\"$WF_UNDER\"}[7d]))")"
if [ "$n_over" -gt 0 ]; then vme_pass "L1 $STALE_ALERT 발화(workflow=$WF_OVER, 예산 ${BUDGET_SMALL}s < 나이 ${AGE_S}s)"
else vme_fail "L1 $STALE_ALERT 무발화 — 예산 초과인데 조용하다(죽은 알림)"; fi
if [ "$n_under" -eq 0 ]; then vme_pass "L7 $STALE_ALERT 침묵(workflow=$WF_UNDER, 예산 ${BUDGET_LARGE}s > 나이 ${AGE_S}s) — 예산 메트릭이 실제로 소비된다"
else vme_fail "L7 예산이 큰 워크플로도 발화했다 — 임계값이 push된 예산에서 오지 않는다(룰 하드코딩 회귀)"; fi

echo "── L2: 정상 상태에서 세 알림 모두 침묵(vacuity 차단 — 위 발화가 '항상 발화'가 아님) ──"
run_scenario healthy
for a in "$STALE_ALERT" "$HB_ALERT" "$SCRAPE_ALERT"; do
  n="$(vme_firing "$a")"
  if [ "$n" -eq 0 ]; then vme_pass "L2 $a 침묵(정상)"
  else vme_fail "L2 $a 가 정상 상태에서 발화했다(오탐 — 위 레그가 무의미해진다)"; fi
done

echo "── L3: 하트비트가 낡으면 exporter stale 발화(감시견의 감시견) ──"
run_scenario hbstale
n="$(vme_firing "$HB_ALERT")"
if [ "$n" -gt 0 ]; then vme_pass "L3 $HB_ALERT 발화(하트비트 ${SPAN_S}s 정지 > 임계 ${HB_THRESHOLD_S}s)"
else vme_fail "L3 $HB_ALERT 무발화 — exporter가 죽어도 조용하다"; fi

echo "── L4: 하트비트 시리즈 자체가 없으면 absent 가지로 발화 ──"
run_scenario hbabsent
n="$(vme_firing "$HB_ALERT")"
if [ "$n" -gt 0 ]; then vme_pass "L4 $HB_ALERT 발화(absent 가지 — 최초 배포 실패·시리즈 소멸)"
else vme_fail "L4 absent 가지가 발화하지 않는다 — 시리즈가 통째로 없을 때 무성"; fi

echo "── L5: 부분 수집 실패는 하트비트와 **직교하는 축**으로 잡힌다 ──"
run_scenario partial
n="$(vme_firing "$SCRAPE_ALERT")"
if [ "$n" -gt 0 ]; then vme_pass "L5 $SCRAPE_ALERT 발화(scraped=$N_SCRAPED_PARTIAL < configured=$N_CFG)"
else vme_fail "L5 부분 고장이 무성 — push는 살아 있는데 일부 워크플로가 감시에서 빠진다"; fi
n="$(vme_firing "$HB_ALERT")"
if [ "$n" -eq 0 ]; then vme_pass "L5 $HB_ALERT 는 침묵(하트비트는 살아 있다 — 두 축이 독립)"
else vme_fail "L5 부분 고장에 하트비트 알림도 발화 — 같은 고장에 두 번 페이징"; fi

echo "── L6: zero-watch 침묵은 **의도된 공백**이다(0 < 0은 거짓) ──"
run_scenario zero
n="$(vme_firing "$SCRAPE_ALERT")"
if [ "$n" -eq 0 ]; then vme_pass "L6 $SCRAPE_ALERT 침묵(configured=0 — 감시 대상이 0이면 그게 정답)"
else vme_fail "L6 zero-watch에서 발화 — \`<\`를 \`<=\`로 바꿨거나 가드를 덧붙였다"; fi

[ "$VME_FAILED" -eq 0 ] || { echo "vmalert-gha-liveness-firing-e2e: ${VME_FAILED}개 레그 실패" >&2; exit 1; }
echo "vmalert-gha-liveness-firing-e2e OK (L1~L7 전건 통과)"
