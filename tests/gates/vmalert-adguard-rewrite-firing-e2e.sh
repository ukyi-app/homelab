#!/usr/bin/env bash
# AdGuard rewrite 리컨실러 알림 **발화** e2e — hermetic replay로 "실제로 발화하는가"를 증명한다.
#
# 왜 필요한가: `-dryRun`은 expr **파싱**만 본다. 문법이 멀쩡한데 라이브 발화가 0인 룰이 이 레포에 이미
# 두 번 있었다(ImageDigestDrift·FilesBulkSSDLow — 둘 다 push 주기 > 룩백으로 시리즈에 구멍이 나
# `for:` pending이 매 주기 리셋됐다). 그 뒤로 push 메트릭 알림에는 이 계열 게이트가 규율인데,
# **이 알림 2종만 빠져 있었다**(2026-07-29 실측: 다른 push 메트릭 3종은 전부 보유).
#
# ★ 무게: `AdguardRewriteReconcilerStale`은 **`*.home.ukyi.app` split-horizon이 죽는 것을 잡는 유일한
#   알림**이다. traefik-ts 디바이스 IP가 바뀌면(DR 재구축·프록시 재등록) 리컨실러가 rewrite를 수렴시키는데,
#   그 리컨실러가 조용히 멈추면 tailscale/LAN 양쪽에서 전 내부 호스트가 죽은 IP로 향한다.
#   그 침묵을 잡는 게 이 알림이고, 이 알림이 발화하는지는 아무도 확인한 적이 없었다.
#
# ★ 발견 경위(기록): 리컨실러 파드 하나가 Error 상태로 보여 조사했다. 원인은 **부트 타임 레이스**로
#   결함이 아니었다 — VM 재부팅(2026-07-26 15:25 UTC, 파드 42개 동시 기동) 중 CoreDNS가 15:25:04에
#   준비됐는데 CronJob이 15:25:01에 실행돼 `curl: (6) Could not resolve host`. 다음 주기에 자가복구했고
#   임계(1800s = 3주기)가 단발 실패를 의도적으로 흡수한다. **문제는 그 안전망이 미검증이었다는 것**이다.
#
# 종료 규약(공유 하네스): 2 = HARNESS FAULT/CONTRACT(전제 붕괴·vacuity) · 1 = leg FAIL · 0 = OK
# ⚠️ docker 필요 — bats 수집 대상이 아니라 **ci.yaml gate 스텝**이 직접 부른다(죽은 커버리지 방지).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK="$ROOT/platform/victoria-stack/prod"
RULES_CM="$STACK/rules/r4-storage-backup.yaml"
RECONCILER="$ROOT/platform/adguard/prod/rewrite-reconciler.yaml"

# shellcheck source=tests/gates/lib/vmalert-e2e.sh
. "$ROOT/tests/gates/lib/vmalert-e2e.sh"

STALE_ALERT=AdguardRewriteReconcilerStale
FIX_ALERT=AdguardRewriteDriftFixed
HB=adguard_rewrite_reconcile_timestamp
FIX_METRIC=adguard_rewrite_last_fix_timestamp

# ── 1) 배포 매니페스트에서 파라미터 파생(하드코딩 0) ───────────────────────────────────────────────
vme_derive_stack_params "$STACK"

# 리컨실러 크론 주기 = push 주기. 룰의 rollup 윈도 하한이 여기서 나온다.
CRON_MIN="$(grep -oE '^  schedule: "\*/([0-9]+) ' "$RECONCILER" | grep -oE '[0-9]+' || true)"
[ -n "$CRON_MIN" ] || vme_fault "리컨실러 크론 주기 추출 실패($RECONCILER) — push 주기를 모르면 rollup 하한을 판정할 수 없다"
PUSH_S=$(( CRON_MIN * 60 ))

vme_workspace "r4agrw-e2e-net-$$"

# ── 2) 배포 ConfigMap에서 룰 바이트 그대로 추출 ────────────────────────────────────────────────────
# ⚠️ 룰을 여기에 재작성하면 "배포된 것"이 아니라 "내가 적은 것"을 검증하게 된다.
# ⚠️ 추출은 **yq**로 한다(형제 하네스와 같은 도구). PyYAML은 설치 보장이 없어 하네스가 환경에 따라
#    조용히 못 도는 자리가 된다 — 실측으로 겪었다.
yq '.data["r4.yaml"]' "$RULES_CM" > "$VME_TMP/r4-deployed.yaml"
[ -s "$VME_TMP/r4-deployed.yaml" ] || vme_fault "룰 추출 실패: $RULES_CM"

for a in "$STALE_ALERT" "$FIX_ALERT"; do
  grep -q "alert: $a" "$VME_TMP/r4-deployed.yaml" \
    || vme_fault "배포 룰에 'alert: $a' 부재 — 하네스가 아무것도 측정하지 않는다"
done

STALE_EXPR="$(vme_alert_expr "$VME_TMP/r4-deployed.yaml" "$STALE_ALERT")"
[ -n "$STALE_EXPR" ] || vme_fault "$STALE_ALERT: expr 추출 실패"
STALE_FOR="$(vme_alert_for "$VME_TMP/r4-deployed.yaml" "$STALE_ALERT")"
[ -n "$STALE_FOR" ] || vme_fault "$STALE_ALERT: for: 부재(무매치 또는 키 없음) — 발화 경계를 판정할 수 없다"
STALE_FOR_S="$(vme_to_s "$STALE_FOR")"
FIX_EXPR="$(vme_alert_expr "$VME_TMP/r4-deployed.yaml" "$FIX_ALERT")"
[ -n "$FIX_EXPR" ] || vme_fault "$FIX_ALERT: expr 추출 실패"

# 임계 상수는 **룰에서 파생**한다(하드코딩하면 룰이 바뀔 때 하네스가 조용히 낡는다).
T_S="$(grep -oE '>[[:space:]]*[0-9]+' <<<"$STALE_EXPR" | head -1 | grep -oE '[0-9]+' || true)"
[ -n "$T_S" ] || vme_fault "$STALE_ALERT: 임계 상수 추출 실패"
FIX_T_S="$(grep -oE '<[[:space:]]*[0-9]+' <<<"$FIX_EXPR" | head -1 | grep -oE '[0-9]+' || true)"
[ -n "$FIX_T_S" ] || vme_fault "$FIX_ALERT: 임계 상수 추출 실패"

# ── 2b) preflight: 전제를 **기계가** 강제한다(위반 = 룰 판정이 아니라 전제 붕괴 → exit 2) ──────────
# rollup 3검사(맨 참조 금지 · 다중 윈도 금지 · W ≥ push 주기).
# ⚠️ 정책이 `fault`인 이유: 값이 **타임스탬프**라 맨 참조로 구멍이 나도 '오래됨'으로 읽혀 **오히려 발화**한다
#    → 자기 RED 레그로는 그 결함을 잡을 수 없다. 여기서 못 막으면 무측정이 된다.
# ⚠️ 하트비트에는 rollup 윈도 **상한이 없다**(상태 게이지와의 비대칭 — 구 상태를 되살리는 래치가 아니라
#    '마지막 시각'이라 오래된 값이 되살아나도 판정이 뒤집히지 않는다). 그래서 W < for 검사는 하지 않는다.
vme_assert_rollup_ok "$STALE_EXPR" "$HB" "$PUSH_S" "$STALE_ALERT" fault
W_S="$VME_W_S"
vme_assert_rollup_ok "$FIX_EXPR" "$FIX_METRIC" "$PUSH_S" "$FIX_ALERT" fault

# 임계가 push 주기의 2배보다 커야 **단발 유실이 페이징하지 않는다**. 이게 깨지면 크론 한 번 밀릴 때마다
# 울려 신뢰를 잃고, 결국 알림이 꺼진다(이 레포가 알림을 잃는 실제 경로다).
[ "$T_S" -gt $(( PUSH_S * 2 )) ] || vme_contract \
  "$STALE_ALERT 임계(${T_S}s) ≤ 2×push(${PUSH_S}s) — 단발 크론 유실에 페이징한다. 임계를 올리거나 주기를 줄여라."
# ★ **상한도 필요하다 — 이게 없으면 이 하네스가 자기충족적이다.** 임계를 룰에서 파생하고 그 값으로
#   replay 창까지 키우므로, 임계를 999999s로 부풀려도 L1이 그대로 통과한다(mutation으로 실측했다).
#   즉 "룰이 자기 임계를 넘으면 발화한다"는 증명되지만 **"그 임계가 제정신인가"는 증명되지 않는다**.
#   리컨실러가 멈춰 있어도 되는 시간의 상한을 여기서 못박는다 — 그만큼 *.home이 죽은 IP를 가리켜도 무성이다.
[ "$T_S" -le $(( PUSH_S * 6 )) ] || vme_contract \
  "$STALE_ALERT 임계(${T_S}s) > 6×push(${PUSH_S}s) — 리컨실러가 그만큼 멈춰 있어도 무성이라는 뜻이다. \
*.home split-horizon이 죽은 IP를 가리키는 창이 너무 길다. 임계를 낮추거나 이 상한을 근거와 함께 재설계하라."
echo "[preflight] 2×push(${PUSH_S}s) < 임계 ${T_S}s ≤ 6×push ✓ | for:=${STALE_FOR}(${STALE_FOR_S}s) | rollup W=${W_S}s ≥ push ✓"

# ── 3) 합성 시계열 ────────────────────────────────────────────────────────────────────────────────
# replay 창: for:를 넘겨야 발화가 관측된다. 임계+for의 3배 + rollup 윈도.
SPAN_S=$(( (T_S + STALE_FOR_S) * 3 + W_S ))
TO_EPOCH="$(date +%s)"
FROM_EPOCH=$(( TO_EPOCH - SPAN_S ))
# stale 시나리오에서 하트비트가 멈추는 시점 — 창 끝에서 (임계 + for + 여유) 이전이어야 발화 경계를 넘긴다.
STOP_BEFORE_S=$(( T_S + STALE_FOR_S + PUSH_S * 2 ))
[ "$SPAN_S" -gt "$STOP_BEFORE_S" ] || vme_fault "replay 창(${SPAN_S}s)이 정지 시점(${STOP_BEFORE_S}s)보다 짧다 — L1이 vacuous"

gen() { # $1=출력파일 $2=시나리오(healthy|stale|absent|fixed)
  # ⚠️ gen 실패는 **레그 판정이 아니라 전제 붕괴**다 → exit 2(공유 규약). set -e로 1이 되면
  #    "룰이 틀렸다"로 오독된다.
  {
  python3 - "$1" "$2" "$FROM_EPOCH" "$TO_EPOCH" "$PUSH_S" "$STOP_BEFORE_S" "$FIX_T_S" "$HB" "$FIX_METRIC" <<'PY'
import json, sys
out, scen, frm, to, push, stop_before, fix_t, hb, fixm = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]),
    int(sys.argv[6]), int(sys.argv[7]), sys.argv[8], sys.argv[9])

ts = list(range(frm, to + 1, push))   # push 주기마다 한 샘플(라이브와 같은 간격)
lines = []
def series(metric, values, stamps):
    lines.append(json.dumps({"metric": {"__name__": metric},
                             "values": values,
                             "timestamps": [t * 1000 for t in stamps]}))

if scen == "healthy":
    # 매 주기 방금 성공 — 값 = 그 시점 자신.
    series(hb, list(ts), ts)
elif scen == "stale":
    # 창 끝 stop_before 이전까지만 push하고 멈춘다 → 이후 나이가 임계를 넘어간다.
    cut = [t for t in ts if t <= to - stop_before]
    if not cut:
        sys.exit("gen: stale 시나리오의 샘플이 0건 — 창/정지시점 산술 오류")
    series(hb, list(cut), cut)
elif scen == "absent":
    pass   # 시리즈 자체를 만들지 않는다 → absent() 가지 검증
elif scen == "fixed":
    # 하트비트는 정상이고, 최근에 fix가 있었다(창 끝 기준 임계 안).
    series(hb, list(ts), ts)
    recent = [t for t in ts if t >= to - fix_t // 2]
    if not recent:
        sys.exit("gen: fixed 시나리오의 최근 샘플이 0건")
    series(fixm, list(recent), recent)
else:
    sys.exit(f"gen: 알 수 없는 시나리오 {scen}")

# ⚠️ absent 시나리오는 시리즈가 0개다. 그래도 vmsingle에 **무언가**는 넣어야 replay가 대상 없이 돌지
#    않는다 — 백필 sanity가 잡을 수 있도록 대조용 상수 시리즈를 하나 둔다.
lines.append(json.dumps({"metric": {"__name__": "harness_alive"},
                         "values": [1] * len(ts),
                         "timestamps": [t * 1000 for t in ts]}))
open(out, "w").write("\n".join(lines) + "\n")
PY
  } || vme_fault "시계열 생성 실패(시나리오 $2) — 창/임계 산술이 시나리오를 무의미하게 만들었다"
}

run_scenario() { # $1=시나리오
  scen="$1"
  vm="r4agrw-$scen-$$"
  docker rm -f "$vm" >/dev/null 2>&1 || true
  vme_start_vmsingle "$vm" "$VME_VM_VER"
  gen "$VME_TMP/$scen.jsonl" "$scen"
  vme_import "$VME_TMP/$scen.jsonl"
  # 백필 sanity — 임포트가 조용히 비면 모든 레그가 거짓 통과한다(fail-closed).
  [ "$(vme_promql "count(count_over_time(harness_alive[${SPAN_S}s]))")" -ge 1 ] \
    || vme_fault "백필 sanity 실패($scen): harness_alive 시리즈 0 — 임포트가 비었다"
  vme_replay "$vm" "$VME_VA_VER" "$VME_TMP/r4-deployed.yaml" "$VME_EVAL" "$VME_LOOKBACK" "$FROM_EPOCH" "$TO_EPOCH"
}

echo "[window] replay $(vme_iso "$FROM_EPOCH") .. $(vme_iso "$TO_EPOCH") (${SPAN_S}s) | push=${PUSH_S}s"

echo "── L1: 리컨실러가 멈추면 발화한다(RED 락 — 이 알림의 존재 이유) ──"
run_scenario stale
n="$(vme_firing "$STALE_ALERT")"
if [ "$n" -gt 0 ]; then
  vme_pass "L1 $STALE_ALERT 발화(하트비트가 창 끝 ${STOP_BEFORE_S}s 전에 멈춤 > 임계 ${T_S}s, for: ${STALE_FOR})"
else
  p="$(vme_pending "$STALE_ALERT")"
  vme_fail "L1 $STALE_ALERT 무발화(firing=0, pending=$p) — 리컨실러가 조용히 죽어도 아무도 모른다. *.home split-horizon이 죽은 IP로 향해도 무성이다. expr이 ${HB}를 last_over_time(...[≥${PUSH_S}s])로 감싸는지 확인하라(맨 참조는 push 구멍마다 for: pending을 리셋한다)."
fi

echo "── L2: 정상 상태에서는 침묵(vacuity 차단 — L1이 '항상 발화'가 아님을 증명) ──"
run_scenario healthy
n="$(vme_firing "$STALE_ALERT")"; p="$(vme_pending "$STALE_ALERT")"
if [ "$n" -eq 0 ] && [ "$p" -eq 0 ]; then
  vme_pass "L2 $STALE_ALERT 침묵(매 ${PUSH_S}s 정상 push — pending조차 없다 = rollup이 구멍을 덮는다)"
elif [ "$n" -eq 0 ]; then
  vme_fail "L2 $STALE_ALERT 가 pending에 진입했다(pending=$p) — 정상 push 사이에서 expr이 참이 된다. rollup 윈도(${W_S}s)가 push 주기(${PUSH_S}s)를 못 덮는다는 뜻이고, 실제 고장 때 for:를 못 채워 **죽은 알림**이 된다."
else
  vme_fail "L2 $STALE_ALERT 가 정상 상태에서 발화했다(firing=$n) — 오탐이라 L1이 무의미해진다"
fi

echo "── L3: 시리즈가 통째로 없으면 absent 가지로 발화 ──"
run_scenario absent
n="$(vme_firing "$STALE_ALERT")"
if [ "$n" -gt 0 ]; then
  vme_pass "L3 $STALE_ALERT 발화(absent 가지 — 리컨실러가 한 번도 안 돌았거나 시리즈 소멸)"
else
  vme_fail "L3 absent 가지가 발화하지 않는다 — 최초 배포 실패·CronJob 삭제가 영원히 무성이다"
fi

echo "── L4: 드리프트 수정 알림은 **직교하는 축**이다(정보성 — 하트비트와 독립) ──"
run_scenario fixed
n="$(vme_firing "$FIX_ALERT")"
if [ "$n" -gt 0 ]; then
  vme_pass "L4 $FIX_ALERT 발화(최근 ${FIX_T_S}s 내 fix 발생 — traefik-ts IP 변경이 실제로 수렴됐음을 알린다)"
else
  vme_fail "L4 $FIX_ALERT 무발화 — 리컨실러가 드리프트를 고쳐도 그 사실이 보고되지 않는다"
fi
n="$(vme_firing "$STALE_ALERT")"
if [ "$n" -eq 0 ]; then
  vme_pass "L4 $STALE_ALERT 는 침묵(하트비트는 살아 있다 — 두 축이 독립)"
else
  vme_fail "L4 fix가 있었는데 stale도 발화 — 같은 사건에 두 번 페이징한다"
fi

[ "$VME_FAILED" -eq 0 ] || { echo "vmalert-adguard-rewrite-firing-e2e: ${VME_FAILED}개 레그 실패" >&2; exit 1; }
echo "vmalert-adguard-rewrite-firing-e2e OK (L1~L4 전건 통과)"
