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
GEN="$ROOT/tests/gates/vmalert-gha-liveness-gen.py"
[ -x "$GEN" ] || { echo "FAULT: 생성기 부재 $GEN" >&2; exit 2; }
STACK="$ROOT/platform/victoria-stack/prod"
RULES_CM="$STACK/rules/r6-ci-staleness.yaml"
EXPORTER="$STACK/gha-liveness-exporter.yaml"
FIXTURES="$ROOT/tests/gates/fixtures"

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
# regress 시나리오(L8/L9) — 공급원이 낡은 스냅샷을 줘 push된 타임스탬프가 **역행**하는 상태.
# ⚠️ 역행은 `WF_UNDER`에만 심는다. `WF_OVER`(예산 3600s)에 심으면 `max_over_time` 하에서
#    `time() - max = N_BACK×push = 3600s`가 예산과 **정확히 같아져** 판정이 경계에 앉는다 — 레그가
#    부동소수·격자 정렬에 흔들린다. WF_OVER는 이 시나리오에서 정상으로 두고 함께 침묵을 요구한다.
N_BACK=2                # 연속 역행 폴 수. 1이면 지속이 `for:`와 같아 픽스처가 pending에서 멈춘다(실측)
BACK_S=1855080          # 역행 폭 515.3h — 2026-08-19 라이브 실측 최대치(bump-poll)

# ── 1) 배포 매니페스트에서 파라미터 파생(하드코딩 0) ───────────────────────────────────────────────
# 파라미터 파생·작업공간·룰 추출의 조립 순서는 lib(vme_scenario)이 소유한다 — 아래 한 호출이 기동이다.

# exporter 크론 주기 = push 주기. 룰의 rollup 윈도 하한이 여기서 나온다.
CRON_MIN="$(grep -oE '^  schedule: "\*/([0-9]+) ' "$EXPORTER" | grep -oE '[0-9]+' || true)"
[ -n "$CRON_MIN" ] || vme_fault "exporter 크론 주기 추출 실패($EXPORTER)"
PUSH_S=$(( CRON_MIN * 60 ))

vme_scenario "r6gha-e2e-net-$$" "$STACK" "$RULES_CM" "r6.yaml"

# fail-closed: 하네스가 겨냥하는 룰이 실제로 존재하는지(리네임 시 무성 무측정 방지)
for a in "$STALE_ALERT" "$HB_ALERT" "$SCRAPE_ALERT"; do
  grep -q "alert: $a" "$VME_RULES" \
    || vme_fault "배포 룰에 'alert: $a' 부재 — 하네스가 아무것도 측정하지 않는다"
done

for a in "$STALE_ALERT" "$HB_ALERT" "$SCRAPE_ALERT"; do
  e="$(vme_alert_expr "$VME_RULES" "$a")"
  [ -n "$e" ] || vme_fault "$a: 배포 룰에서 expr 추출 실패"
  f="$(vme_alert_for "$VME_RULES" "$a")"
  [ -n "$f" ] || vme_fault "$a: for: 부재(무매치 또는 키 없음)"
done
STALE_EXPR="$(vme_alert_expr "$VME_RULES" "$STALE_ALERT")"
STALE_FOR_S="$(vme_to_s "$(vme_alert_for "$VME_RULES" "$STALE_ALERT")")"
HB_FOR_S="$(vme_to_s "$(vme_alert_for "$VME_RULES" "$HB_ALERT")")"
SCRAPE_FOR_S="$(vme_to_s "$(vme_alert_for "$VME_RULES" "$SCRAPE_ALERT")")"
HB_EXPR="$(vme_alert_expr "$VME_RULES" "$HB_ALERT")"
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

# ── 2c) preflight: regress 시나리오(L8/L9)의 산술 ──────────────────────────────────────────────────
# `max_over_time`은 **면역이 아니라 유계 흡수**다 — 창 안에 역행하지 **않은** 샘플이 최소 1개 남아야
# 흡수한다. 그래서 침묵 조건은 두 항의 **논리곱**이고, 둘 중 어느 하나만 걸어도 시나리오가 거짓말한다.
[ $(( N_BACK * PUSH_S )) -le "$W_S" ] \
  || vme_contract "시나리오 무의미: N_BACK×push=$(( N_BACK * PUSH_S ))s > W(${W_S}s) — 창 안에 역행하지 않은 샘플이 남지 않아 max_over_time도 **정당하게** 발화한다(룰의 잘못이 아닌데 L8이 RED가 된다)"
[ $(( (N_BACK + 1) * PUSH_S )) -le "$BUDGET_LARGE" ] \
  || vme_contract "시나리오 무의미: (N_BACK+1)×push=$(( (N_BACK + 1) * PUSH_S ))s > BUDGET_LARGE(${BUDGET_LARGE}s) — 흡수 후 남는 나이가 이미 예산을 넘어 L8이 룰과 무관하게 RED가 된다"
# 역행 폭이 예산을 넘지 않으면 픽스 이전 expr조차 발화하지 않는다 → L9가 무측정(공허한 이빨).
[ "$BACK_S" -gt "$BUDGET_LARGE" ] \
  || vme_contract "시나리오 무의미: BACK_S(${BACK_S}s) <= BUDGET_LARGE(${BUDGET_LARGE}s) — 역행이 예산을 못 넘어 결함 픽스처도 침묵한다(L9가 아무것도 증명하지 못한다)"
# 역행 지속(N_BACK×push)이 `for:`를 못 채우면 픽스처가 pending에서 멈춘다 → 역시 L9 무측정.
[ $(( N_BACK * PUSH_S )) -ge "$STALE_FOR_S" ] \
  || vme_contract "시나리오 무의미: 역행 지속 $(( N_BACK * PUSH_S ))s < for:(${STALE_FOR_S}s) — 결함 픽스처가 pending에 머물러 firing이 0이다"
echo "[preflight] regress 산술 OK: N_BACK=${N_BACK}폴 · 지속 $(( N_BACK * PUSH_S ))s (≥ for: ${STALE_FOR_S}s) · W=${W_S}s 안 흡수 여유 $(( W_S / PUSH_S ))폴 · 역행폭 ${BACK_S}s > 예산 ${BUDGET_LARGE}s"

# ⚠️ **순서가 곧 진단의 정확성이다.** 배포 룰의 좌변부터 본다 — 아래 픽스처 대조를 먼저 걸면, 픽스가
#    되돌아갔을 때 "픽스처가 고쳐졌다"는 **엉뚱한 파일**을 지목한다(거짓 진단 = 게이트 신뢰 붕괴).
TS_ROLLUP_FN="$(grep -oE "[a-z_]+_over_time[[:space:]]*\([[:space:]]*${TS_METRIC}\[" <<<"$STALE_EXPR" \
  | head -1 | grep -oE '^[a-z_]+_over_time' || true)"
[ -n "$TS_ROLLUP_FN" ] || vme_fault "$STALE_ALERT: 좌변 rollup 함수 추출 실패 — expr 파싱이 깨졌다"
[ "$TS_ROLLUP_FN" = "max_over_time" ] \
  || vme_fault "$STALE_ALERT 좌변이 '$TS_ROLLUP_FN'이다 — **배포 룰이 되돌아갔다**($RULES_CM). 단조량인 $TS_METRIC 은 max_over_time이어야 공급원의 역행 샘플을 흡수한다. L8/L9는 이 전제 위에서만 의미가 있다"

# 결함 픽스처는 배포 룰과 **좌변 rollup 함수 하나만** 달라야 한다 — 다른 곳이 함께 드리프트하면
# L9의 발화를 "역행 때문"으로 귀속할 수 없다(픽스처가 다른 이유로 발화하는 것을 이빨로 착각한다).
cp "$FIXTURES/r6-gha-lastovertime.yaml" "$VME_TMP/r6-gha-lastovertime.yaml"
grep -q "alert: $STALE_ALERT" "$VME_TMP/r6-gha-lastovertime.yaml" \
  || vme_fault "결함 픽스처에 'alert: $STALE_ALERT' 부재 — L9가 무측정"
FIX_EXPR="$(vme_alert_expr "$VME_TMP/r6-gha-lastovertime.yaml" "$STALE_ALERT")"
[ -n "$FIX_EXPR" ] || vme_fault "결함 픽스처에서 expr 추출 실패"
# 배포=max / 픽스처=last 라는 **바로 그 한 토큰**의 차이인지 확인한다. 양쪽을 정규화해 비교한다.
norm() { tr -s '[:space:]' ' ' <<<"$1" | sed 's/^ *//; s/ *$//'; }
# ⚠️ 여기 도달했다면 배포 룰은 이미 max_over_time으로 확인됐다 → 동일하다는 것은 **픽스처가 '고쳐졌다'**는
#    뜻이고 귀속이 모호하지 않다. 이빨 없는 픽스처는 제품 고장(leg FAIL)이 아니라 **하네스 결함**이다.
[ "$(norm "$FIX_EXPR")" != "$(norm "$STALE_EXPR")" ] \
  || vme_fault "결함 픽스처가 배포 룰과 동일하다 — 누군가 픽스처를 '고쳤다'($FIXTURES/r6-gha-lastovertime.yaml). L9는 L8의 복사본이 되어 이빨이 없다"
[ "$(norm "${FIX_EXPR//last_over_time(${TS_METRIC}/max_over_time(${TS_METRIC}}")" = "$(norm "$STALE_EXPR")" ] \
  || vme_fault "결함 픽스처가 배포 룰과 **좌변 rollup 함수 말고도** 다르다 — 픽스처가 '고쳐졌'거나 배포 룰이 다른 축에서 바뀌었다. 어느 쪽이든 L9의 발화를 역행에 귀속할 수 없다"
echo "[preflight] 결함 픽스처 OK: 배포 룰(max_over_time)과 좌변 rollup 함수 하나만 다르다"

# ── 3) 합성 시계열 ────────────────────────────────────────────────────────────────────────────────
# replay 창: for:가 성립하려면 창이 충분히 길어야 한다. 세 알림의 for: 중 최대 + 여유.
MAX_FOR_S="$STALE_FOR_S"
[ "$HB_FOR_S" -gt "$MAX_FOR_S" ] && MAX_FOR_S="$HB_FOR_S"
[ "$SCRAPE_FOR_S" -gt "$MAX_FOR_S" ] && MAX_FOR_S="$SCRAPE_FOR_S"
SPAN_S=$(( MAX_FOR_S * 3 + W_S ))
TO_EPOCH="$(date +%s)"
FROM_EPOCH=$(( TO_EPOCH - SPAN_S ))

gen() { # $1=출력파일 $2=시나리오(stale|healthy|hbstale|hbabsent|partial|zero|regress)
  python3 "$GEN" "$1" "$2" "$FROM_EPOCH" "$TO_EPOCH" "$PUSH_S" "$AGE_S" \
    "$WF_OVER" "$WF_UNDER" "$BUDGET_SMALL" "$BUDGET_LARGE" "$N_CFG" "$N_SCRAPED_PARTIAL" "$N_ZERO" \
    "$N_BACK" "$BACK_S"
}

run_scenario() { # $1=시나리오 [$2=룰 파일(기본: 배포 룰) $3=vm 이름 접미사]
  local scen="$1"
  local rules="${2:-$VME_RULES}"
  local vm="vm-gha-$scen${3:-}-$$"
  gen "$VME_TMP/$scen.jsonl" "$scen"
  vme_leg "$vm" "$VME_TMP/$scen.jsonl"
  vme_replay "$vm" "$VME_VA_VER" "$rules" "$VME_EVAL" "$VME_LOOKBACK" "$FROM_EPOCH" "$TO_EPOCH"
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

echo "── L8: 공급원이 낡은 스냅샷을 줘 값이 역행해도 침묵한다(단조 rollup의 유계 흡수) ──"
run_scenario regress
n="$(vme_firing "$STALE_ALERT")"
if [ "$n" -eq 0 ]; then vme_pass "L8 $STALE_ALERT 침묵(역행 ${N_BACK}폴 · 폭 ${BACK_S}s — max_over_time이 창 안 신선 샘플로 흡수)"
else vme_fail "L8 역행 샘플에 발화했다 — 좌변이 last_over_time으로 되돌아갔거나 흡수 여유(W/push)가 깎였다"; fi

echo "── L9: **하네스의 이빨** — 같은 시계열을 픽스 이전 expr에 먹이면 발화해야 한다 ──"
# 이게 없으면 L8은 "룰이 옳다"가 아니라 "이 시계열은 아무것도 발화시키지 않는다"의 재진술일 수 있다.
run_scenario regress "$VME_TMP/r6-gha-lastovertime.yaml" "-fix"
n="$(vme_firing "$STALE_ALERT")"
if [ "$n" -gt 0 ]; then vme_pass "L9 결함 픽스처(last_over_time) 발화 — 시계열이 실제로 버그를 재현한다(L8이 공허하지 않다)"
else vme_fail "L9 결함 픽스처가 침묵했다 — regress 시계열이 버그를 재현하지 못한다(L8은 아무것도 증명하지 않는다)"; fi

[ "$VME_FAILED" -eq 0 ] || { echo "vmalert-gha-liveness-firing-e2e: ${VME_FAILED}개 레그 실패" >&2; exit 1; }
echo "vmalert-gha-liveness-firing-e2e OK (L1~L9 전건 통과)"
