#!/usr/bin/env bash
# ContainerMemoryNearLimit **발화** e2e — "임계를 넘으면 운다"가 아니라 **"무엇이 임계를 넘은 것으로
# 세어지는가"**를 증명한다. 이 알림의 결함은 문법도 가시성도 아니라 **지표 선택의 의미**에 있었다.
#
# 버그(2026-08-31 라이브 확정, observability/glances): 분자가 container_memory_working_set_bytes였다.
# 커널 정의상 `working_set = memory.current − inactive_file`이라 **active_file(활성 clean page cache)이
# 분자에 그대로 실린다**. 회수 가능한 캐시가 활성으로 남아 있기만 하면 회수 불가 메모리가 전혀 늘지
# 않아도 지표가 임계를 넘는다. glances에서 anon은 20일간 76.61 → 76.68Mi로 불변인데 file cache가
# 0.01 → 40.94Mi(전량 clean, file_dirty=0)로 charge되자 working_set만 81.27 → 113.08Mi로 계단 상승해
# 128Mi limit의 88.3%가 되어 발화했다. 같은 시점 cgroup memory.events는 `max=0`·`oom_kill=0`으로
# **limit에 한 번도 닿은 적이 없음**을 증명한다 — "OOM 임박"이라는 주장 자체가 성립하지 않았다.
#
# ⚠️ 룰 주석이 이 함정을 **정반대로** 기록하고 있었다("working_set 기준 — page cache를 포함하는
#    max_usage는 … 금지"). max_usage만 피하면 캐시가 빠진다고 본 전제가 틀렸다. 그래서 이 게이트는
#    지표 이름을 grep하는 정적 lint가 아니라 **replay로 의미를 재는** 형태여야 한다.
#
# ⚠️ **분자에서 `container_memory_cache`를 빼면 안 된다**(r1 리뷰 F1). 그것은 cgroup v2의
#    `memory.stat:file`이고 tmpfs·shared memory를 **포함**한다. 이 호스트는 swap이 0이라
#    (`infra/k3s-bootstrap/host-config.sh`) shmem은 회수될 수 없는데도 통째로 빠진다 — 라이브
#    database/pg-1이 shmem 38Mi를 그렇게 잃어 7.6%가 3.9%로 보고됐다. 파일 LRU의 두 축
#    (`total_inactive_file`·`total_active_file`)만 빼야 shmem이 남는다. L2b가 그 회귀를 잡는다.
#
# 형제 게이트와의 관계:
#   vmalert-rules-validate.sh(-dryRun)  = expr **파싱**만 → 이 버그를 통과시킨다.
#   tests/test_alert_rules.bats(모드A/B/C) = instance 라벨·push 룩백 축의 정적 lint → 이 축은 안 본다.
#   이 게이트                            = 분자가 회수 가능한 캐시를 세는지를 **발화로** 판정한다.
#
# 설계(형제 하네스와 동일 골격 — 공용 프리미티브는 tests/gates/lib/vmalert-e2e.sh):
#  - 룰은 **배포 ConfigMap에서 매 실행 바이트 그대로 추출**(픽스처 복제 금지 → 드리프트 0). for:는 불변.
#  - 임계·for:·평가주기·룩백·이미지 버전은 전부 **매니페스트에서 파생**(하드코딩 0).
#  - 두 컨테이너를 **한 픽스처·한 replay**에 심는다 — 같은 창에서 한쪽은 침묵하고 다른 쪽은 우는 대조가
#    이 버그의 가장 선명한 증거다. 시나리오를 갈라 두 번 replay하면 그 대조가 사라진다.
#  - 판정 비율은 gen.py의 상수를 재선언하지 않고 **생성된 픽스처에서 되읽어** 계산한다(두 벌 드리프트 0).
#  - 이 알림의 입력은 전부 **scrape 메트릭**이라 push 구멍(모드 C) 축이 없다 → rollup 검사는 하지 않는다.
#  - 클러스터 접근 0(hermetic). 외부 호출은 이미지 pull뿐.
#
# 판정 레그:
#   preflight  임계/for: 파생 + 픽스처가 두 판정을 실제로 가르는지 산술 단언 (위반 = HARNESS FAULT exit 2)
#   L0 (vacuity) 같은 replay의 TargetDown(up==0) → **발화해야** 함 (vmalert가 실제로 돌았다는 양성 증거)
#   L1 (RED 락) 캐시-바운드(회수 불가 67%) → ContainerMemoryNearLimit **발화하면 안 됨** (버그 상태 = 실패)
#   L2 (참양성 보존) anon-바운드(회수 불가 95%) → **발화해야** 함 (처방이 알림을 죽이지 않았음)
#   L2b (shmem 참양성) shmem-바운드(shmem이 limit의 78%) → **발화해야** 함 ★ r1 리뷰 F1의 회귀 앵커
#   L3 (하네스 이빨) 동결 결함 expr + 같은 캐시-바운드 픽스처 → **발화해야** 함 (버그 감지 능력 매 실행 증명)
#
# 종료 규약(공유 하네스): 2 = HARNESS FAULT/CONTRACT(전제 붕괴·vacuity) · 1 = leg FAIL · 0 = OK
# ⚠️ docker 필요 — bats 수집 대상이 아니라 **ci.yaml gate 스텝**이 직접 부른다(죽은 커버리지 방지).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK="$ROOT/platform/victoria-stack/prod"
RULES_CM="$STACK/rules/core.yaml"
GEN="$ROOT/tests/gates/vmalert-memory-nearlimit-gen.py"
BUGGY="$ROOT/tests/gates/fixtures/core-memory-nearlimit-buggy-expr.yaml"

# shellcheck source=tests/gates/lib/vmalert-e2e.sh
. "$ROOT/tests/gates/lib/vmalert-e2e.sh"

ALERT=ContainerMemoryNearLimit
VACUITY_ALERT=TargetDown
CB=cachebound     # 캐시-바운드 컨테이너의 container 라벨
AB=anonbound      # anon-바운드 컨테이너의 container 라벨
SB=shmembound     # shmem-바운드 컨테이너의 container 라벨(r1 F1 회귀 앵커)

# 이 픽스처가 재는 계약값 — **명시 대조**한다(r1 리뷰 F2). 파생은 추출 실패를 잡기 위해 유지하되,
# 값이 움직이면 조용히 낡는 대신 시끄럽게 실패해야 한다: 의도적 변경이면 하네스도 함께 갱신하라는 신호다.
# (파생만 두면 임계 하향은 네 preflight 단언을 전부 통과하고 for: 연장은 창이 따라 늘어나 안 잡힌다.)
EXPECT_T=0.85
EXPECT_FOR=10m

fault()    { echo "HARNESS FAULT (preflight): $*" >&2; exit 2; }
contract() { echo "CONTRACT VIOLATION (preflight): $*" >&2; exit 2; }

[ -r "$GEN" ]   || fault "픽스처 생성기 부재: $GEN"
[ -r "$BUGGY" ] || fault "동결 결함 픽스처 부재: $BUGGY — L3(하네스 이빨) 없이는 L1이 vacuous하다"

# ── 1) 시나리오 기동 — 파라미터 파생·작업공간·배포 룰 추출의 조립 순서는 lib(vme_scenario)이 소유한다 ──
vme_scenario "coremem-e2e-net-$$" "$STACK" "$RULES_CM" "core.yaml"

for a in "$ALERT" "$VACUITY_ALERT"; do
  grep -q "alert: $a" "$VME_RULES" \
    || fault "배포 룰에 'alert: $a' 부재 — 하네스가 아무것도 측정하지 않는다"
done

EXPR="$(vme_alert_expr "$VME_RULES" "$ALERT")"
[ -n "$EXPR" ] || fault "$ALERT: expr 추출 실패"
FOR="$(vme_alert_for "$VME_RULES" "$ALERT")"
[ -n "$FOR" ] || fault "$ALERT: for: 부재(무매치 또는 키 없음) — 발화 경계를 판정할 수 없다"
FOR_S="$(vme_to_s "$FOR")"

# 임계는 **룰에서 파생**한다(하드코딩하면 룰이 바뀔 때 하네스가 조용히 낡는다).
T="$(grep -oE '>[[:space:]]*0\.[0-9]+' <<<"$EXPR" | head -1 | grep -oE '0\.[0-9]+' || true)"
[ -n "$T" ] || fault "$ALERT: 임계 상수 추출 실패 — expr에서 '> 0.NN' 형태를 찾지 못했다"

# 계약 대조 — 파생한 임계로 픽스처까지 판정하므로 값이 자유로우면 하네스가 자기충족적이다.
# (임계를 부풀리면 L1이 그대로 통과한다 — 형제 adguard 하네스가 mutation으로 실증한 함정. 상·하한만
#  두는 판은 하향을 놓쳤고, for:는 창이 따라 늘어나 아예 재지지 않았다 — r1 리뷰 F2.)
awk -v t="$T" -v e="$EXPECT_T" 'BEGIN{exit !(t == e)}' \
  || contract "$ALERT 임계가 $T 다 — 이 하네스는 $EXPECT_T 를 전제로 픽스처를 구성했다. 임계를 의도적으로 옮겼다면 픽스처와 이 상수를 함께 갱신하라(그러지 않으면 L1/L2가 조용히 딴 것을 잰다)."
[ "$FOR" = "$EXPECT_FOR" ] \
  || contract "$ALERT for: 가 $FOR 다 — 이 하네스는 $EXPECT_FOR 을 전제로 replay 창을 잡았다. 선행 경보의 리드타임은 이 알림의 계약이니 의도적 변경이면 이 상수도 함께 갱신하라."

# ── 2) preflight: 픽스처가 두 판정을 실제로 가르는지 **기계가** 강제한다 ─────────────────────────────
# replay 창: for:를 넘겨야 발화가 관측된다. for의 3배 + 룩백 여유.
SPAN_S=$(( FOR_S * 3 + VME_LOOKBACK_S ))
TO_EPOCH="$(date +%s)"
FROM_EPOCH=$(( TO_EPOCH - SPAN_S ))
# 픽스처 간격은 평가주기와 같게 둔다 — 룩백보다 촘촘해야 매 평가에서 시리즈가 보인다(scrape 메트릭이라
# push 구멍 축은 없지만, 격자가 룩백보다 성기면 그 자체로 인공적인 구멍이 된다).
STEP_S="$VME_EVAL_S"
[ "$STEP_S" -lt "$VME_LOOKBACK_S" ] \
  || fault "픽스처 격자(${STEP_S}s) ≥ 룩백(${VME_LOOKBACK_S}s) — 하네스가 만든 구멍을 룰 결함으로 오독한다"
[ "$SPAN_S" -gt $(( FOR_S + VME_LOOKBACK_S )) ] \
  || fault "replay 창(${SPAN_S}s)이 for:(${FOR_S}s)+룩백을 못 넘는다 — 모든 레그가 vacuous"

FIXTURE="$VME_TMP/memory.jsonl"
python3 "$GEN" "$FIXTURE" "$FROM_EPOCH" "$TO_EPOCH" "$STEP_S" \
  || fault "시계열 생성 실패 — 창/격자 산술이 픽스처를 무의미하게 만들었다"

# 판정 비율은 **생성된 픽스처에서 되읽는다** — gen.py의 상수를 여기 재선언하면 두 벌이 조용히 갈린다.
# 물리 정합성(cache·working_set ≤ usage, 커널 항등식)도 여기서 함께 강제한다.
# 세 축을 낸다: working_set(옛 판) · usage−cache(r1 판, F1 결함) · usage−inactive−active(현행 판).
# 가운데 축은 배포 룰이 더는 쓰지 않지만 **L2b의 전제**를 재는 데 필요하다 — shmem 형상이 그 판에서
# 침묵한다는 것이 F1 회귀 앵커의 핵심이고, 그 사실을 기계가 확인해야 L2b가 무언가를 재는 것이 된다.
ratios() { # $1=container 라벨 → "ws_ratio nonrecl_cache_ratio nonrecl_lru_ratio"
  python3 - "$FIXTURE" "$1" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
v = {}
for line in open(path):
    o = json.loads(line)
    m = o["metric"]
    if m.get("container") == want:
        v[m["__name__"]] = float(o["values"][0])
need = ["container_memory_working_set_bytes", "container_memory_usage_bytes",
        "container_memory_cache", "container_memory_total_inactive_file_bytes",
        "container_memory_total_active_file_bytes", "kube_pod_container_resource_limits"]
missing = [n for n in need if n not in v]
if missing:
    sys.exit("픽스처에 %s의 메트릭 누락: %s" % (want, ",".join(missing)))
ws, us, ca, inact, act, li = (v[n] for n in need)
if not (ws <= us and ca <= us and li > 0):
    sys.exit("픽스처 %s 물리 정합성 위반: ws=%d us=%d ca=%d li=%d" % (want, ws, us, ca, li))
# 커널 항등식 — 픽스처가 이것을 어기면 shmem 축의 산술이 통째로 무의미해진다.
if ws != us - inact:
    sys.exit("픽스처 %s: working_set(%d) != usage−inactive_file(%d)" % (want, ws, us - inact))
if ca < inact + act:
    sys.exit("픽스처 %s: cache(%d) < inactive+active(%d) — 항등식 위반" % (want, ca, inact + act))
print("%.6f %.6f %.6f" % (ws / li, (us - ca) / li, (us - inact - act) / li))
PY
}

read -r CB_WS CB_NRC CB_NR <<<"$(ratios "$CB")" || fault "캐시-바운드 픽스처 비율 산출 실패"
read -r AB_WS AB_NRC AB_NR <<<"$(ratios "$AB")" || fault "anon-바운드 픽스처 비율 산출 실패"
read -r SB_WS SB_NRC SB_NR <<<"$(ratios "$SB")" || fault "shmem-바운드 픽스처 비율 산출 실패"

# ★ 이 네 단언이 없으면 하네스는 아무것도 재지 않는다 — 픽스처가 두 판정을 **실제로 가르는** 형상일
#   때만 L1/L2가 의미를 갖는다. 특히 CB_WS > T 는 "이 픽스처가 결함 expr에서 발화한다"의 전제이고,
#   CB_NR ≤ T 는 "고친 expr에서는 침묵한다"의 전제다. 둘 중 하나만 깨져도 L1은 vacuous하다.
awk -v a="$CB_WS" -v t="$T" 'BEGIN{exit !(a > t)}' \
  || contract "캐시-바운드 픽스처의 working_set 비율($CB_WS) ≤ 임계($T) — 결함 expr조차 발화하지 않는 형상이라 L1/L3가 vacuous하다"
awk -v a="$CB_NR" -v t="$T" 'BEGIN{exit !(a <= t)}' \
  || contract "캐시-바운드 픽스처의 회수 불가 비율($CB_NR) > 임계($T) — 이 형상은 진짜 OOM 임박이라 L1이 틀린 것을 요구한다"
awk -v a="$AB_WS" -v t="$T" 'BEGIN{exit !(a > t)}' \
  || contract "anon-바운드 픽스처의 working_set 비율($AB_WS) ≤ 임계($T) — L2가 어느 expr에서도 발화하지 않는다"
awk -v a="$AB_NR" -v t="$T" 'BEGIN{exit !(a > t)}' \
  || contract "anon-바운드 픽스처의 회수 불가 비율($AB_NR) ≤ 임계($T) — 처방 후 참양성이 사라져도 L2가 못 잡는다"
# ★ shmem 축(r1 F1) — 이 둘이 함께 성립해야 L2b가 회귀 앵커가 된다. SB_NR > T 는 "올바른 분자에서는
#   운다"이고, **SB_NRC ≤ T 는 "cache를 빼는 분자에서는 침묵한다"** — 후자가 없으면 L2b는 어느 분자에서나
#   통과해 F1 회귀를 전혀 못 잡는다.
awk -v a="$SB_NR" -v t="$T" 'BEGIN{exit !(a > t)}' \
  || contract "shmem-바운드 픽스처의 회수 불가 비율($SB_NR) ≤ 임계($T) — 올바른 분자에서도 안 울리는 형상이라 L2b가 vacuous하다"
awk -v a="$SB_NRC" -v t="$T" 'BEGIN{exit !(a <= t)}' \
  || contract "shmem-바운드 픽스처가 usage−cache 분자에서도 임계를 넘는다($SB_NRC > $T) — 그러면 L2b가 F1 회귀(cache 통째 차감)를 못 잡는다. shmem 몫을 키워라."

echo "[preflight] 임계=$T | for:=${FOR}(${FOR_S}s) | eval=${VME_EVAL} | 룩백=${VME_LOOKBACK}"
echo "[preflight] cachebound  working_set=${CB_WS} > $T  ∧  회수불가=${CB_NR} ≤ $T  ✓ (두 판정이 갈린다)"
echo "[preflight] anonbound   working_set=${AB_WS} > $T  ∧  회수불가=${AB_NR} > $T  ✓ (양쪽 다 참양성)"
echo "[preflight] shmembound  회수불가(LRU축)=${SB_NR} > $T  ∧  usage−cache=${SB_NRC} ≤ $T  ✓ (F1 회귀 앵커)"
echo "[window] replay $(vme_iso "$FROM_EPOCH") .. $(vme_iso "$TO_EPOCH") (${SPAN_S}s) | 격자=${STEP_S}s"

# ── 3) 판정 헬퍼 — container 라벨로 좁힌다(집계가 by (namespace,pod,container)라 라벨이 보존된다) ──
firing_for()  { vme_promql "sum(count_over_time(ALERTS{alertname=\"$ALERT\",alertstate=\"firing\",container=\"$1\"}[${SPAN_S}s]))"; }
pending_for() { vme_promql "sum(count_over_time(ALERTS{alertname=\"$ALERT\",alertstate=\"pending\",container=\"$1\"}[${SPAN_S}s]))"; }

run_leg() { # $1=vmsingle 컨테이너명 $2=룰 파일
  docker rm -f "$1" >/dev/null 2>&1 || true
  vme_leg "$1" "$FIXTURE"
  # 백필 sanity — 임포트가 조용히 비면 모든 레그가 거짓 통과한다(fail-closed).
  [ "$(vme_promql "count(count_over_time(container_memory_usage_bytes[${SPAN_S}s]))")" -ge 2 ] \
    || fault "백필 sanity 실패($1): container_memory_usage_bytes 시리즈 < 2 — 임포트가 비었다"
  vme_replay "$1" "$VME_VA_VER" "$2" "$VME_EVAL" "$VME_LOOKBACK" "$FROM_EPOCH" "$TO_EPOCH"
}

# ── 레그 A: 배포 룰 ────────────────────────────────────────────────────────────────────────────────
run_leg "coremem-deployed-$$" "$VME_RULES"

echo "── L0: vacuity 대조 — 같은 replay에서 $VACUITY_ALERT 가 발화한다 ──"
n="$(vme_firing "$VACUITY_ALERT" "${SPAN_S}s")"
if [ "$n" -gt 0 ]; then
  vme_pass "L0 $VACUITY_ALERT 발화 — vmalert가 이 창에서 실제로 평가했다(아래 '발화 없음' 판정이 유의미)"
else
  fault "L0 $VACUITY_ALERT 무발화 — vmalert가 이 창에서 아무것도 쓰지 않았다. L1의 '발화 없음'은 룰 판정이 아니라 무측정이다."
fi

echo "── L1 (RED 락): 캐시-바운드는 침묵해야 한다 — 회수 불가 메모리가 limit의 ${CB_NR}뿐이다 ──"
n="$(firing_for "$CB")"; p="$(pending_for "$CB")"
if [ "$n" -eq 0 ] && [ "$p" -eq 0 ]; then
  vme_pass "L1 $ALERT($CB) 침묵 — 회수 가능한 clean page cache가 OOM 임박으로 세어지지 않는다(pending조차 없다)"
elif [ "$n" -eq 0 ]; then
  vme_fail "L1 $ALERT($CB) 가 pending에 진입했다(pending=$p) — 발화는 면했지만 expr이 캐시를 여전히 분자에 세고 있다. 임계 근처 진동(라이브 vmagent: pending 1875샘플/30d)의 씨앗이다."
else
  vme_fail "L1 $ALERT($CB) 가 발화했다(firing=$n) — working_set(${CB_WS})이 임계 $T 를 넘겼기 때문이다. 그러나 회수 불가 메모리는 ${CB_NR}이고 그 캐시는 전량 clean이라 커널이 I/O 없이 즉시 회수한다(라이브 glances: memory.events max=0·oom_kill=0). 분자를 container_memory_usage_bytes − container_memory_cache로 바꿔라."
fi

echo "── L2 (참양성 보존): anon-바운드는 발화해야 한다 — 회수 불가 메모리가 ${AB_NR}이다 ──"
n="$(firing_for "$AB")"
if [ "$n" -gt 0 ]; then
  vme_pass "L2 $ALERT($AB) 발화 — 진짜 OOM 임박은 그대로 페이징한다(처방이 알림을 죽이지 않았다)"
else
  p="$(pending_for "$AB")"
  vme_fail "L2 $ALERT($AB) 무발화(firing=0, pending=$p) — 회수 불가 메모리가 limit의 ${AB_NR}인데 침묵한다. 이 알림의 존재 이유가 사라졌다. 분자가 회수 불가 메모리를 과소평가하는지(예: slab을 빼는 rss 기준) 확인하라."
fi

echo "── L2b (shmem 참양성): shmem-바운드는 발화해야 한다 — swap이 0이라 shmem ${SB_NR}은 회수 불가다 ──"
n="$(firing_for "$SB")"
if [ "$n" -gt 0 ]; then
  vme_pass "L2b $ALERT($SB) 발화 — tmpfs/shared memory가 회수 가능한 파일 캐시로 오분류되지 않는다"
else
  p="$(pending_for "$SB")"
  vme_fail "L2b $ALERT($SB) 무발화(firing=0, pending=$p) — 회수 불가 메모리가 limit의 ${SB_NR}인데 침묵한다. 분자가 container_memory_cache를 통째로 빼고 있는지 확인하라: 그것은 cgroup v2의 memory.stat:file이라 tmpfs·shared memory를 포함하고, 이 호스트는 swap이 0이라 그 몫은 회수될 수 없다(라이브 database/pg-1: shmem 38Mi가 그렇게 사라져 7.6%가 3.9%로 보고됐다). 파일 LRU 두 축(total_inactive_file·total_active_file)만 빼라."
fi

# ── 레그 B: 동결 결함 expr — 하네스가 이 버그를 실제로 감지하는지 매 실행 증명 ──────────────────────
echo "── L3 (하네스 이빨): 동결 결함 expr은 같은 캐시-바운드 픽스처에 발화해야 한다 ──"
cp "$BUGGY" "$VME_TMP/buggy-rules.yaml"
run_leg "coremem-buggy-$$" "$VME_TMP/buggy-rules.yaml"
n="$(firing_for "$CB")"
if [ "$n" -gt 0 ]; then
  vme_pass "L3 결함 expr이 $CB 에 발화 — 이 픽스처가 룰에 실제로 닿았다(L1의 '침묵'이 무측정이 아님을 보증)"
else
  p="$(pending_for "$CB")"
  fault "L3 결함 expr이 발화하지 않는다(firing=0, pending=$p) — 캐시-바운드 형상이 룰에 닿지 않았다는 뜻이고, 그러면 배포 룰이 안 고쳐졌어도 L1이 통과한다(거짓 GREEN). 픽스처 격자·창·라벨 매칭을 의심하라."
fi

[ "$VME_FAILED" -eq 0 ] || { echo "vmalert-memory-nearlimit-firing-e2e: ${VME_FAILED}개 레그 실패" >&2; exit 1; }
echo "vmalert-memory-nearlimit-firing-e2e OK (L0~L3 전건 통과)"
