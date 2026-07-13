#!/usr/bin/env bash
# vmalert **발화** e2e (digest-exporter) — 이 exporter를 감시하는 **알림 2건**이 "파싱된다"가 아니라
# "실제로 발화한다"(그리고 정상·부트스트랩·zero-app에는 **침묵한다**)를 증명한다. 두 알림은 **직교하는 축**이다:
#   · DigestExporterStale             — 하트비트 축(push 경로 생존). 전면 침묵(크론 미실행·push 사망)을 잡는다.
#   · DigestExporterScrapeIncomplete  — 수집 카운트 축(scraped < configured). push는 살아 있는데 GHCR 조회만
#     부분 실패하는 고장을 잡는다 — 하트비트는 정상이므로 Stale이 **원리적으로 못 잡는** 축이다.
# 두 축은 서로를 대체하지 못하며, 이 하네스는 **직교성 자체도 단언한다**(L4: 부분 수집 실패에 Stale은 침묵).
#
# 왜 이 게이트가 있나: digest-exporter는 ImageDigestDrift(r6)의 **먹이 공급선**이다. exporter가 조용히
# 죽으면(크론 미실행·push 실패·파드 기동 실패 — 전부 **초록 Job(exit 0)** 이라 KubeJobFailed가 원리적으로
# 못 잡는다) ghcr_latest_digest가 끊기고, 기록 룰의 [15m] 윈도가 만료된 뒤 ImageDigestDrift는 **조용히
# 실명**한다. 원래 버그(라이브 60일 발화 0)와 **같은 실패 양식의 2차 실명**이다. 그 감시견의 감시견이
# 구조적으로 발화 가능함은 **실제 평가로만** 증명된다 — required `vmalert -dryRun`은 파싱만 하고,
# 모드 C 린터는 하한 정적 검사만 한다(이 알림 클래스가 4번 뚫린 이유).
#
# 형제 게이트와의 관계:
#   vmalert-rules-validate.sh(-dryRun)  = expr **파싱**만 → 이 클래스를 통과시킨다.
#   vmalert-drift-firing-e2e.sh         = ImageDigestDrift(같은 10분 push 메트릭, **라벨-값 상태 게이지**).
#   vmalert-bulkssd-firing-e2e.sh       = FilesBulkSSDLow(일 1회 push, ratio 게이지) — 공용 lib의 원본 소비자.
#   이 게이트                            = **타임스탬프-값 하트비트** + **부트스트랩 상한**(신규 축).
#
# 설계(형제 하네스와 동일 골격 — 공용 프리미티브는 tests/gates/lib/vmalert-e2e.sh):
#  - 룰은 **배포 ConfigMap에서 매 실행 바이트 그대로 추출**(픽스처 복제 금지 → 드리프트 0).
#  - 버전/평가주기/룩백/push 주기/데드라인/타임아웃/앱 수는 **매니페스트에서 파생**(하드코딩 0).
#    지연 예산의 상수·파생·부등식은 **tests/gates/lib/digest-exporter-budget.sh가 SSOT**다 — 정적 게이트
#    (test_digest-exporter.bats)·스모크(skopeo-timeout-smoke.sh)와 **같은 코드**로 같은 부등식을 판정한다
#    (리터럴 복제 시 한쪽만 바뀌어 판정이 조용히 갈리는 것을 구조적으로 막는다).
#  - 클러스터 접근 0(hermetic). 외부 호출은 이미지 pull뿐.
#
# ⚠️ `?max_lookback` 핀(공용 lib이 위치인자로 강제 주입)은 **여기서 load-bearing이다**. 하트비트는
#    ghcr_latest_digest와 **동일 CronJob·동일 600s 주기**로 push되므로, 드리프트 하네스가 바로 그 10분
#    주기에서 실증한 range-질의 보간 조건과 같다(bulkssd의 "핀 무관" 실측은 **일 단위 구멍**에만 스코프된다).
#    **실측(핀 제거 1회, 2026-07-13)**: 핀을 빼면 L3의 결함 픽스처가 `firing=0 pending=0`이 된다 —
#    VM의 range-질의 룩백 휴리스틱이 10분 구멍을 **연속 보간**해 맨 참조가 항상 보이게 되고, 그 결과
#    "구멍이 실재한다"는 양성 증거(pending>0)가 사라진다(= 하네스가 거짓 GREEN 쪽으로 눈이 먼다).
#    핀이 있으면 pending>0으로 구멍이 관측된다. → 핀은 이 하네스에서 **제거 금지**.
#
# ⚠️ 드리프트 게이트의 `push ≤ W < for` preflight는 **복사 금지**다. 그 **상한**은 라벨-값 상태 게이지
#    전용이다(rollup 윈도가 구 상태를 되살리는 래치라 for:보다 작아야 phantom 오발화가 없다). 여기 값은
#    **타임스탬프**이고 판정도 값으로 하므로 윈도는 "마지막 하트비트를 어디까지 뒤질까"라는 탐색 지평일
#    뿐 — **상한이 없다**(넓혀도 판정 불변). 복사하면 누락 내성만 잃는다.
#    cf. docs/traps-detail.md 「rollup 윈도 상한 — 상태 게이지 vs 하트비트 비대칭」.
#
# 판정 레그(exit 규약: 2 = HARNESS FAULT/CONTRACT(전제 붕괴·vacuity) · 1 = leg FAIL · 0 = OK):
#   preflight  부트스트랩 불변식 4 + 룰 산술 3 + 카운트 룰 산술 2 (위반 = exit 2 — 룰 판정이 아니라 전제 붕괴다)
#   L1 stale 하트비트(끊김)        → DigestExporterStale **발화**        (stale-샘플 가지)
#   L2 정상 하트비트 + 같은 카운트 → **두 알림 모두 firing==0 AND pending==0** + 대조 알림 FilesBackupStale firing>0
#   L3 결함 픽스처(맨 참조) + 정상 → **firing==0 AND pending>0**        (하네스의 이빨 — 거짓 GREEN 최종 보증)
#   L4 scraped(1) < configured(2)  → DigestExporterScrapeIncomplete **발화** (하트비트는 정상 — Stale이
#      원리적으로 못 잡는 **직교 축**: push는 살아 있는데 GHCR 수집만 부분 실패)
#   L5 하트비트 샘플 **전무**      → DigestExporterStale **발화**        (`or absent(...)` 가지의 유일한 증명)
#   L6 카운트 0/0(zero-app)        → DigestExporterScrapeIncomplete **무발화** — owner 결정 ④(의도된 침묵)를
#      **락한다**: `<`를 `<=`로 바꾸거나 zero-app 가드(configured==0 발화)를 나중에 추가하면 여기서 죽는다.
#   L7 부트스트랩(첫 샘플이 강제 상한 840s에 정확히 도착) → **pending>0**(비-vacuity) **AND firing==0**
#      ↳ 최초 배포의 거짓 페이지가 **구조적으로 불가능**함을 증명한다. 누가 for:를 줄이거나·크론을 늘리거나·
#        activeDeadlineSeconds를 키우면 여기서(또는 preflight ①에서) 죽는다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK="$ROOT/platform/victoria-stack/prod"
RULES_CM="$STACK/rules/r4-storage-backup.yaml"
EXPORTER="$STACK/digest-exporter.yaml"
FIXTURES="$ROOT/tests/gates/fixtures"
GEN="$ROOT/tests/gates/vmalert-digest-stale-gen.py"
START_EPOCH="$(date +%s)"

# shellcheck source=tests/gates/lib/vmalert-e2e.sh
. "$ROOT/tests/gates/lib/vmalert-e2e.sh"
# shellcheck source=tests/gates/lib/digest-exporter-budget.sh
. "$ROOT/tests/gates/lib/digest-exporter-budget.sh"

ALERT=DigestExporterStale
SCRAPE_ALERT=DigestExporterScrapeIncomplete   # 수집 카운트 축(US2) — 하트비트와 직교
CONTROL=FilesBackupStale   # 같은 r4 그룹의 absent 가드 알림 — 음성 레그의 vacuity 대조군
# ⚠️ 아래 셋은 **메트릭 이름**이다(값이 아니다) — run.sh의 동명 셸 변수 CONFIGURED/SCRAPED는 **카운트 값**을
#    담는다. 같은 이름이 두 층에서 다른 것을 뜻하면 읽는 쪽이 반드시 헷갈리므로 여기선 `_METRIC` 접미로 못박는다.
HB=digest_exporter_last_success_timestamp
CFG_METRIC=digest_exporter_apps_configured
SCRAPED_METRIC=digest_exporter_apps_scraped

# ── 카운트 쌍의 SSOT — gen.py 시나리오·셸 sanity·진단 산문이 **같은 변수**를 읽는다 ────────────────
# 예전엔 2/2·2/1·0/0이 gen.py 하드코딩·셸 단언·메시지 산문에 **3중 리터럴**로 흩어져 있었다 → 한쪽만 바꾸면
# sanity가 조용히 통과하며 시나리오와 판정이 갈린다. 이제 카운트의 유일한 출처는 여기이고 gen.py는 argv로 받는다
# (gen.py는 받은 쌍이 시나리오 의미와 맞는지 — healthy=동수·incomplete=격차·zeroapp=0/0 — 다시 fail-closed 검사한다).
N_CFG=2               # 설정된 앱 수(healthy/incomplete 공통)
N_SCRAPED_OK=2        # 전건 수집 성공 → 두 알림 모두 침묵(L2)
N_SCRAPED_PARTIAL=1   # 부분 수집 실패 → SCRAPE_ALERT 발화(L4)
N_ZERO=0              # zero-app(마지막 앱 teardown) → `0 < 0`이 거짓이라 침묵(L6 — owner 결정 ④)

# ── 1) 배포 매니페스트에서 파라미터 파생(하드코딩 0) ───────────────────────────────────────────────
vme_derive_stack_params "$STACK"

# producer(digest-exporter) 계약 — 부트스트랩 상한의 입력. **파생 실패 = 즉시 CONTRACT**(fail-closed):
# 빈 값을 그대로 산술에 넣으면 부등식이 참으로 평가돼 상한을 하나도 강제하지 못한 채 게이트가 통과한다.
deb_load "$EXPORTER" || vme_contract "digest-exporter 예산 파생 실패(위 stderr 참조) — 지연 상한의 입력을 모른 채로는 부트스트랩 부등식이 무의미하다."

# ── 2) 배포 ConfigMap에서 룰 바이트 그대로 추출 ────────────────────────────────────────────────────
vme_workspace "r4dgst-e2e-net-$$"

yq '.data["r4.yaml"]' "$RULES_CM" > "$VME_TMP/r4-deployed.yaml"
[ -s "$VME_TMP/r4-deployed.yaml" ] || vme_fault "룰 추출 실패: $RULES_CM"
cp "$FIXTURES/r4-digest-stale-buggy-expr.yaml" "$VME_TMP/r4-buggy.yaml"

# fail-closed: 하네스가 겨냥하는 룰이 실제로 존재하는지(리네임 시 무성 무측정 방지)
for want in "alert: $ALERT" "alert: $SCRAPE_ALERT" "alert: $CONTROL"; do
  grep -q "$want" "$VME_TMP/r4-deployed.yaml" || vme_fault "배포 룰에 '$want' 부재 — 하네스가 아무것도 측정하지 않는다"
done
grep -q "alert: $ALERT" "$VME_TMP/r4-buggy.yaml" || vme_fault "결함 픽스처에 'alert: $ALERT' 부재 — L3가 무측정"

# ⚠️ expr·for: 파생은 **전부 fail-closed**다(빈 값 = 즉시 FAULT). 룰에서 `for:`가 사라지면 yq가 `null`을
#    주는데, 가드가 없으면 그 `null`이 산술까지 흘러가 "null: unbound variable" 잡음 크래시로 죽는다
#    (깔끔한 CONTRACT가 아니라 하네스 버그처럼 보인다). 파생 실패는 룰 판정이 아니라 **전제 붕괴**다.
EXPR="$(vme_alert_expr "$VME_TMP/r4-deployed.yaml" "$ALERT")"
[ -n "$EXPR" ] || vme_fault "배포 룰에서 $ALERT expr 추출 실패"
FOR="$(vme_alert_for "$VME_TMP/r4-deployed.yaml" "$ALERT")"
[ -n "$FOR" ] || vme_fault "배포 룰에서 ${ALERT}의 for: 추출 실패(부재/null) — for:가 없으면 절이 즉시 발화하므로 부트스트랩 상한(①)도 발화 경계(⑤)도 판정할 수 없다."
FOR_S="$(vme_to_s "$FOR")"
CTRL_FOR="$(vme_alert_for "$VME_TMP/r4-deployed.yaml" "$CONTROL")"
[ -n "$CTRL_FOR" ] || vme_fault "배포 룰에서 대조 알림 ${CONTROL}의 for: 추출 실패(부재/null) — replay 길이를 그 for:에서 파생하므로 음성 레그의 vacuity 차단이 무너진다."
CTRL_FOR_S="$(vme_to_s "$CTRL_FOR")"
# staleness 임계 T — expr의 `> N`에서 파생(하드코딩 금지).
T_S="$(grep -oE '>[[:space:]]*[0-9]+' <<<"$EXPR" | head -1 | grep -oE '[0-9]+' || true)"
[ -n "$T_S" ] || vme_fault "$ALERT expr에서 staleness 임계(> N)를 파생하지 못했다"

# 수집 카운트 알림(US2) — 같은 파일에서 파생(하드코딩 0).
SCRAPE_EXPR="$(vme_alert_expr "$VME_TMP/r4-deployed.yaml" "$SCRAPE_ALERT")"
[ -n "$SCRAPE_EXPR" ] || vme_fault "배포 룰에서 $SCRAPE_ALERT expr 추출 실패"
SCRAPE_FOR="$(vme_alert_for "$VME_TMP/r4-deployed.yaml" "$SCRAPE_ALERT")"
[ -n "$SCRAPE_FOR" ] || vme_fault "배포 룰에서 ${SCRAPE_ALERT}의 for: 추출 실패(부재/null) — for:가 없으면 단발 GHCR 블립에도 즉시 페이징하고, L4/L6의 발화 경계 산술(⑨)이 성립하지 않는다."
SCRAPE_FOR_S="$(vme_to_s "$SCRAPE_FOR")"

# ── 2b) preflight: 전제와 불변식을 **기계가** 강제한다(위반 = 룰 판정이 아니라 전제 붕괴 → exit 2) ──
# (② activeDeadlineSeconds 존재·정수 / push 주기 파생은 deb_load가 이미 fail-closed로 강제했다.)

# ③ concurrencyPolicy == Replace (레거시 무제한 Job이 상한을 빠져나가는 경로가 닫혀 있는가)
[ "$DEB_CONCURRENCY_POLICY" = "Replace" ] || vme_contract "digest-exporter concurrencyPolicy='$DEB_CONCURRENCY_POLICY'(기대: Replace) — activeDeadlineSeconds는 jobTemplate에만 붙고 k8s는 **이미 실행 중인 Job에 소급 적용하지 않는다**. Forbid이면 랜딩 순간 살아 있던 무제한 레거시 Job이 새(제한된) Job을 계속 스킵해 지연 상한이 통째로 무너진다."

# ★ 강제된 최악 첫 하트비트 상한(부트스트랩 계약의 핵심) — L7이 첫 샘플을 **정확히 여기에** 놓는다.
BOUND_S="$(deb_first_heartbeat_bound)"

# ① 부트스트랩 부등식: for: 가 강제 상한보다 커야 첫 하트비트가 pending을 리셋한다(엄격 부등식)
[ "$FOR_S" -gt "$BOUND_S" ] || vme_contract "부트스트랩 부등식 위반: for:(${FOR}=${FOR_S}s) ≤ 강제 상한(${BOUND_S}s = cron ${DEB_CRON_PERIOD_S}s + 파드예산 ${DEB_POD_START_BUDGET_S}s + activeDeadlineSeconds ${DEB_ACTIVE_DEADLINE_S}s) — 최초 배포 시 이력이 없어 absent(...)가 즉시 pending에 들어가는데 첫 하트비트가 for: 안에 도착한다는 보장이 없다 → **롤아웃이 원인인 거짓 페이지**. for:를 키우거나 cron/activeDeadlineSeconds를 줄여라(단 ④를 함께 만족해야 한다)."

# ④ 인-데드라인 엄격 부등식(정적 게이트 test_digest-exporter.bats와 **같은 lib 함수**로 판정):
#    Job이 push 전에 죽으면 GHCR 장애가 '$ALERT'로 **오귀속**된다(하트비트가 아예 안 나가므로).
BUDGET="$(deb_in_deadline_budget)"
N_MAX="$(deb_n_max)"
[ "$BUDGET" -lt "$DEB_ACTIVE_DEADLINE_S" ] || vme_contract "인-데드라인 예산 초과: POD_START(${DEB_POD_START_BUDGET_S}) + N_apps(${DEB_APPS_N})×SKOPEO_TIMEOUT(${DEB_SKOPEO_TIMEOUT_S}) + CURL_MAX_TIME(${DEB_CURL_MAX_TIME_S}) + EXEC_SLACK(${DEB_EXEC_SLACK_S}) = ${BUDGET} ≥ activeDeadlineSeconds(${DEB_ACTIVE_DEADLINE_S}) — 순차 스크레이프가 데드라인을 넘겨 Job이 push 전에 죽는다 → 하트비트 미발행 → GHCR 장애가 '$ALERT'로 오귀속된다(US2 붕괴). activeDeadlineSeconds를 올리되 ①을 함께 재확인하라 — 두 부등식을 **동시에** 만족해야 한다."

# ⑤ for:가 eval의 정수배(발화 경계가 결정적이어야 레그 판정이 안정적)
[ $(( FOR_S % VME_EVAL_S )) -eq 0 ] || vme_fault "for:(${FOR})가 evaluationInterval(${VME_EVAL})의 정수배가 아님 — 발화 경계가 비결정적"

# ⑥⑧ rollup 3검사(맨 참조·다중 윈도·W ≥ push)는 **공용 vme_assert_rollup_ok**가 판정한다 — 두 알림에 대해
#     같은 검사를 산문만 바꿔 두 번 쓰면 한쪽만 고쳐졌을 때 조용히 갈린다. 알림별로 다른 것은 **absent 정책뿐**:
#
#  ⑥ 하트비트(skip): rollup 부재 = 모드 C **그 자체**다 → 검사를 건너뛰고 L1/L5가 RED로 잡게 둔다
#     (자기 RED 경로를 preflight FAULT로 덮어쓰지 않는다). 하한만 있고 **상한은 없다** — 타임스탬프-값
#     하트비트라 윈도는 "마지막 push를 어디까지 뒤질까"라는 탐색 지평일 뿐이다(헤더 주석 참조).
vme_assert_rollup_ok "$EXPR" "$HB" "$DEB_CRON_PERIOD_S" "$ALERT" skip
W="$VME_W"
W_S="$VME_W_S"

# ⑦ 구멍의 전제: 룩백 < push 주기. (룩백 ≥ push면 구멍이 없어 모드 C 자체가 성립 안 하고 L3가 무의미해진다.)
[ "$VME_LOOKBACK_S" -lt "$DEB_CRON_PERIOD_S" ] || vme_fault "룩백(${VME_LOOKBACK}=${VME_LOOKBACK_S}s) ≥ push 주기(${DEB_CRON_PERIOD_S}s) — 구멍이 생기지 않는다(모드 C 전제 소멸). L3 결함 픽스처가 이빨을 잃으므로 레그 산술을 재설계하라."

#  ⑧ 카운트 2종(fault): 이쪽은 맨 참조를 잡아낼 **자기 RED 레그가 없다**(L4는 rollup이 있는 상태를 전제한다)
#     → 맨 참조는 즉시 FAULT다. 두 시리즈 **모두** 만족해야 한다 — 한쪽만 rollup을 잃어도 그 변이 주기 후반에
#     빈 벡터가 되어 비교가 통째로 사라진다(= 조용한 무발화 — 이 알림 클래스의 원죄).
for cm in "$CFG_METRIC" "$SCRAPED_METRIC"; do
  vme_assert_rollup_ok "$SCRAPE_EXPR" "$cm" "$DEB_CRON_PERIOD_S" "$SCRAPE_ALERT" fault
done

# ⑨ 카운트 알림의 for:가 eval의 정수배(발화 경계가 결정적이어야 L4/L6 판정이 안정적)
[ $(( SCRAPE_FOR_S % VME_EVAL_S )) -eq 0 ] || vme_fault "${SCRAPE_ALERT}의 for:(${SCRAPE_FOR})가 evaluationInterval(${VME_EVAL})의 정수배가 아님 — 발화 경계가 비결정적"

# ⑩ 카운트 알림은 **bare끼리의 1:1 매치**다 → on()/ignoring()이 붙으면 모드 B 대상이 되고(양변 사전 집계 강제)
#    라벨셋이 갈려 매치가 사라질 수 있다. 계약을 여기서 못박는다.
case "$SCRAPE_EXPR" in
  *' on('* | *' on ('* | *ignoring*) vme_contract "$SCRAPE_ALERT expr에 on()/ignoring()이 있다 — 두 시리즈는 bare(라벨 0)라 벡터 매칭이 이미 1:1이다. 조인 수식어는 불필요할 뿐 아니라 모드 B(raw 피연산자 422)를 불러온다." ;;
esac

# ── 3) 시간창 — eval 격자에 정렬(결정성) ───────────────────────────────────────────────────────────
# RP_LEN: 모든 레그를 동시에 만족하는 최소 길이 + 여유
#   · L1/L5: > for:                        (픽스된 룰이 발화할 시간)
#   · L2/L6: > 대조 알림 for:(${CTRL_FOR})      (FilesBackupStale이 발화해 vacuity를 배제)
#   · L4   : > 카운트 알림 for:(${SCRAPE_FOR})  (부분 고장이 발화 경계를 넘길 시간)
#   · L7   : > 강제 상한 + for:             (첫 하트비트 도착 후 발화 경계를 **넘겨** replay)
NEED_L7=$(( BOUND_S + FOR_S ))
RP_LEN="$CTRL_FOR_S"
[ "$NEED_L7" -gt "$RP_LEN" ] && RP_LEN="$NEED_L7"
[ "$SCRAPE_FOR_S" -gt "$RP_LEN" ] && RP_LEN="$SCRAPE_FOR_S"
RP_LEN=$(( RP_LEN + 600 ))
RP_LEN=$(( (RP_LEN + VME_EVAL_S - 1) / VME_EVAL_S * VME_EVAL_S ))   # eval 격자 올림

NOW="$(date +%s)"
T0=$(( NOW / VME_EVAL_S * VME_EVAL_S ))
RP_TO=$(( T0 - 600 ))            # 현재로부터 10분 여유(끝단 경계 회피)
RP_FROM=$(( RP_TO - RP_LEN ))
# stale 시나리오: 마지막 하트비트를 replay 시작보다 (임계 + 2 eval) 앞에 둔다 → 시작부터 나이 > T,
# 단 rollup 윈도 [W] 안에는 끝까지 남아 있어야 **stale-샘플 가지**를 탄다(absent 가지가 아니다 — L5와 구분).
STALE_LAST=$(( RP_FROM - T_S - 2 * VME_EVAL_S ))
BACKFILL_N=12

[ $(( RP_FROM - STALE_LAST )) -gt "$T_S" ] || vme_fault "stale 격자 오류: replay 시작의 하트비트 나이가 임계(${T_S}s) 이하 — L1이 발화할 수 없다"
if [ "$W_S" -gt 0 ]; then
  [ $(( RP_TO - STALE_LAST )) -lt "$W_S" ] || vme_fault "stale 격자 오류: replay 끝에서 마지막 하트비트가 rollup 윈도(${W}) 밖으로 만료된다 — L1이 stale-샘플 가지가 아니라 **absent 가지**를 타 L5와 중복된다(가지 구분 소실). RP_LEN 또는 W를 재확인하라."
fi
[ "$RP_LEN" -gt "$NEED_L7" ] || vme_fault "replay 길이(${RP_LEN}s) ≤ 강제 상한+for:(${NEED_L7}s) — L7이 발화 경계를 넘기지 못해 firing==0이 vacuous해진다"

echo "[params] vmalert=$VME_VA_VER vmsingle=$VME_VM_VER eval=$VME_EVAL lookback=$VME_LOOKBACK(queryStep) push=${DEB_CRON_PERIOD_S}s for=$FOR(${FOR_S}s) T=${T_S}s W=${W:-none} | ${SCRAPE_ALERT} for=$SCRAPE_FOR(${SCRAPE_FOR_S}s)"
echo "[bound]  강제 최악 첫 하트비트 = cron(${DEB_CRON_PERIOD_S}) + 파드예산(${DEB_POD_START_BUDGET_S}) + activeDeadlineSeconds(${DEB_ACTIVE_DEADLINE_S}) = ${BOUND_S}s < for:(${FOR_S}s) ✓  [concurrencyPolicy=$DEB_CONCURRENCY_POLICY]"
echo "[budget] 인-데드라인 = ${DEB_POD_START_BUDGET_S} + N(${DEB_APPS_N})×${DEB_SKOPEO_TIMEOUT_S} + ${DEB_CURL_MAX_TIME_S} + ${DEB_EXEC_SLACK_S} = ${BUDGET}s < ADS(${DEB_ACTIVE_DEADLINE_S}s) ✓  (N_MAX=${N_MAX} — 8번째 앱은 CI red)"
echo "[window] replay $(vme_iso "$RP_FROM") .. $(vme_iso "$RP_TO") (${RP_LEN}s) | stale_last=$(vme_iso "$STALE_LAST")"

# ── 4) 레그 실행기 ─────────────────────────────────────────────────────────────────────────────────
run_leg() { # $1=label $2=rules-file $3=scenario $4=기대 하트비트 샘플 수(-1 = 검사 생략) $5=configured $6=scraped
  # ⚠️ $5/$6은 **카운트 값**이다 — 하네스가 SSOT이고 gen.py는 argv로 받는다(리터럴 3중 사본 금지).
  #    카운트를 심지 않는 시나리오(stale/absent/bootstrap)도 인자는 받는다(gen.py가 무시한다).
  local label="$1" rules="$2" scenario="$3" want_hb="$4" cfg="$5" scr="$6" vm="r4dgst-e2e-$1-$$"
  vme_start_vmsingle "$vm" "$VME_VM_VER"
  python3 "$GEN" "$scenario" "$RP_FROM" "$RP_TO" "$DEB_CRON_PERIOD_S" "$BOUND_S" "$STALE_LAST" "$BACKFILL_N" \
    "$cfg" "$scr" > "$VME_TMP/$label.jsonl"
  vme_import "$VME_TMP/$label.jsonl"

  # 백필 sanity: 임포트가 조용히 비면 모든 레그가 거짓 통과한다(fail-closed).
  local got
  got="$(vme_promql "sum(count_over_time(${HB}[30d]))")"
  if [ "$want_hb" -ge 0 ] && [ "$got" -ne "$want_hb" ]; then
    vme_fault "백필 sanity($label): ${HB} 샘플이 ${got}개 — 기대 ${want_hb}개(생성기/시간창 오류)"
  fi

  # ★ 가시성 프로브(stale 격자에서만) — "10분 push 구멍이 실재한다"를 레그 판정 **이전에** 증명한다.
  #   하네스가 구멍을 보간하고 있으면(= 거짓 GREEN 위험) 여기서 먼저 죽는다.
  if [ "$scenario" = "stale" ]; then
    local probe_t=$(( STALE_LAST + DEB_CRON_PERIOD_S ))   # 마지막 push 후 1주기 = 룩백 밖
    [ "$(vme_series_count "$HB" "$probe_t" "$VME_LOOKBACK")" -eq 0 ] \
      || vme_fault "가시성 프로브($label): 마지막 push 후 ${DEB_CRON_PERIOD_S}s(룩백 ${VME_LOOKBACK} 밖)인데 맨 참조가 여전히 보인다 — VM이 push 구멍을 보간하고 있다(?max_lookback 핀 미적용 = 거짓 GREEN 위험)."
    [ "$(vme_series_count "last_over_time(${HB}[${W}])" "$probe_t" "$VME_LOOKBACK")" -eq 1 ] \
      || vme_fault "가시성 프로브($label): 같은 시점에 last_over_time[${W}]도 안 보인다 — 백필/시간창이 잘못됐다(데이터가 TSDB에 없다)."
  fi

  vme_replay "$vm" "$VME_VA_VER" "$rules" "$VME_EVAL" "$VME_LOOKBACK" "$RP_FROM" "$RP_TO"
}
drop_leg() { docker rm -f "r4dgst-e2e-$1-$$" >/dev/null 2>&1 || true; }

# ── 레그 판정기 ────────────────────────────────────────────────────────────────────────────────────
# 7개 레그가 `if [F/P] … vme_pass … elif … vme_fail … else vme_fail` 뼈대를 복제하고 있었다(L2는 두 알림에
# 대해 **같은 3분기 블록이 두 개**). 뼈대는 셋뿐이므로 여기서 한 번만 쓰고, 각 레그의 **고유 진단 산문은
# 인자로 넘긴다**(진단 문구를 잃으면 이 하네스의 가치가 절반이다).
#   ⚠️ 판정만 한다 — 레그별 sanity/vacuity 가드(vme_fault)는 각 레그가 호출 전에 직접 건다.
verdict_fires() { # $1=firing $2=pending $3=PASS 산문 $4=FAIL 산문 — 기대: **발화**
  if [ "$1" -gt 0 ]; then vme_pass "$3"; else vme_fail "$4"; fi
}
verdict_silent() { # $1=firing $2=pending $3=PASS $4=FAIL(발화함) [$5=FAIL(pending — 생략 시 $4)] — 기대: **완전 침묵**
  # pending>0을 발화와 **구분해** 진단한다: 그건 expr이 매 주기 flap한다는 뜻(= rollup 상실 = 모드 C)이라
  # 지금은 안 울려도 **실 고장 때 못 우는** 서로 다른 병이다.
  if [ "$1" -eq 0 ] && [ "$2" -eq 0 ]; then vme_pass "$3"
  elif [ "$1" -gt 0 ]; then vme_fail "$4"
  else vme_fail "${5:-$4}"
  fi
}
verdict_engages_never_fires() { # $1=firing $2=pending $3=PASS $4=FAIL(발화함) $5=FAIL(vacuous: pending==0)
  # 기대: **engage하되 발화 못 함**(firing==0 AND pending>0). pending==0은 통과가 아니라 **vacuity**다 —
  # 룰이 애초에 관여하지 않았다는 뜻이라 "안 울렸다"가 아무것도 증명하지 못한다(L3=하네스의 이빨, L7=부트스트랩).
  if [ "$1" -gt 0 ]; then vme_fail "$4"
  elif [ "$2" -eq 0 ]; then vme_fail "$5"
  else vme_pass "$3"
  fi
}

# ── L1(stale-샘플 가지): 하트비트가 끊긴 지 임계 초과 → 발화해야 함 ────────────────────────────────
run_leg l1-stale "$VME_TMP/r4-deployed.yaml" stale $(( BACKFILL_N + 1 )) "$N_CFG" "$N_SCRAPED_OK"
F1="$(vme_firing "$ALERT")"; P1="$(vme_pending "$ALERT")"
echo "  [L1] deployed rule + heartbeat stopped $(( RP_FROM - STALE_LAST ))s before replay → $ALERT firing=$F1 pending=$P1"
verdict_fires "$F1" "$P1" \
  "L1 $ALERT fired after the heartbeat went silent past the ${T_S}s threshold (firing samples=$F1)" \
  "L1 $ALERT did NOT fire even though the digest-exporter heartbeat stopped $(( RP_FROM - STALE_LAST ))s before the replay window and stayed silent for ${RP_LEN}s (threshold ${T_S}s, for: ${FOR}) — firing=0, pending=$P1. The exporter can die silently and ImageDigestDrift goes blind with nobody paged. Check that the expr wraps ${HB} in last_over_time(...[≥${DEB_CRON_PERIOD_S}s]) — a bare reference loses the series between 10-minute pushes and resets the for: hold every cycle."
drop_leg l1-stale

# ── L2(음성 대조): 정상 하트비트 + 같은(비-0) 카운트 → **두 알림 모두** 침묵. + 대조 알림으로 vacuity 차단 ──
run_leg l2-healthy "$VME_TMP/r4-deployed.yaml" healthy $(( BACKFILL_N + RP_LEN / DEB_CRON_PERIOD_S + 1 )) "$N_CFG" "$N_SCRAPED_OK"
F2="$(vme_firing "$ALERT")"; P2="$(vme_pending "$ALERT")"; C2="$(vme_firing "$CONTROL")"
SF2="$(vme_firing "$SCRAPE_ALERT")"; SP2="$(vme_pending "$SCRAPE_ALERT")"
echo "  [L2] deployed rules + healthy heartbeat every ${DEB_CRON_PERIOD_S}s + counts ${N_SCRAPED_OK}/${N_CFG} → $ALERT firing=$F2 pending=$P2 · $SCRAPE_ALERT firing=$SF2 pending=$SP2 (control $CONTROL firing=$C2)"
# 이 레그의 판정은 "발화 부재"(음성)다 → vmalert가 애초에 아무것도 안 썼어도 통과해버릴 수 있다.
# 같은 replay에서 대조 알림(생성기가 의도적으로 심지 않는 메트릭의 absent 가드)이 발화했는지로 그것을 막는다.
[ "$C2" -gt 0 ] || vme_fault "L2: control alert $CONTROL did not fire in the healthy replay — vmalert wrote nothing, so '$ALERT absent' proves nothing (vacuous pass)."
verdict_silent "$F2" "$P2" \
  "L2 no false page while the exporter heartbeats normally every ${DEB_CRON_PERIOD_S}s (firing=0, pending=0 — the rule never even engages)" \
  "L2 $ALERT FIRED (firing=$F2) while the exporter was heartbeating normally every ${DEB_CRON_PERIOD_S}s — false positive. A healthy exporter must never page; the max heartbeat age here is ${DEB_CRON_PERIOD_S}s, well under the ${T_S}s threshold." \
  "L2 $ALERT entered pending (pending=$P2) with a healthy heartbeat — the expr flaps (it goes true between pushes), which means the rollup is missing or its window is shorter than the ${DEB_CRON_PERIOD_S}s push period. It would reset the for: hold every cycle and thus never fire when the exporter really dies."
# 카운트 알림도 같은 replay에서 침묵해야 한다(scraped == configured). pending>0이면 rollup을 잃어
# 주기 후반마다 한쪽 변이 사라지며 비교가 뒤집힌다는 뜻 → 실 고장 때 for:를 못 채운다(= 죽은 알림).
verdict_silent "$SF2" "$SP2" \
  "L2 no false page from ${SCRAPE_ALERT} when every configured app is scraped (counts ${N_SCRAPED_OK}/${N_CFG} → firing=0, pending=0)" \
  "L2 $SCRAPE_ALERT FIRED (firing=$SF2) while scraped == configured == ${N_CFG} — false positive. The comparison must be strict (<): equal counts mean every configured app was scraped successfully, which is the healthy state." \
  "L2 $SCRAPE_ALERT entered pending (pending=$SP2) with equal counts (${N_SCRAPED_OK}/${N_CFG}) — the expr flaps between pushes. Both ${CFG_METRIC} and ${SCRAPED_METRIC} must be wrapped in last_over_time([≥${DEB_CRON_PERIOD_S}s]); if only one is, the other vanishes ${VME_LOOKBACK} after each push and the comparison goes empty/true intermittently. A flapping rule never accumulates the ${SCRAPE_FOR} hold, so a real partial GHCR outage would never page."
drop_leg l2-healthy

# ── L3(하네스의 이빨): 결함 픽스처(맨 참조) + 정상 하트비트 → 발화 금지, 단 pending은 존재해야 함 ──
# ★ 이 레그가 **거짓 GREEN에 대한 최종 보증**이다(datasource 룩백 핀이 아니라).
#   pending>0 = 10분 push 구멍이 **실재한다**는 양성 증거(맨 참조가 주기 후반에 사라져 absent가 켜진다).
#   pending==0이면 하네스가 구멍을 보간하고 있다는 뜻 → 배포 룰이 안 고쳐졌는데도 L1/L5가 통과할 수 있다.
#   firing==0 = 맨 참조는 for:를 절대 못 넘긴다(구멍이 매 주기 pending을 리셋한다).
run_leg l3-buggy "$VME_TMP/r4-buggy.yaml" healthy $(( BACKFILL_N + RP_LEN / DEB_CRON_PERIOD_S + 1 )) "$N_CFG" "$N_SCRAPED_OK"
F3="$(vme_firing "$ALERT")"; P3="$(vme_pending "$ALERT")"
echo "  [L3] fixtures/r4-digest-stale-buggy-expr.yaml (bare reference) + healthy heartbeat → firing=$F3 pending=$P3"
verdict_engages_never_fires "$F3" "$P3" \
  "L3 harness has teeth — the frozen bare-reference expr engages every cycle (pending=$P3: the series vanishes ${VME_LOOKBACK} after each ${DEB_CRON_PERIOD_S}s push) but can never hold for: ${FOR} (firing=0)" \
  "L3 the frozen bare-reference expr FIRED (firing=$F3) on a HEALTHY heartbeat — the harness's grid or the fixture is wrong: a bare reference must flap (true only while the series is invisible) and thus never reach for: ${FOR}. Until this leg is green again, L1/L5's verdicts are meaningless." \
  "L3 the frozen bare-reference expr produced NO alert state at all (pending=0) — the ${DEB_CRON_PERIOD_S}s push holes are being BRIDGED (false GREEN): with a ${VME_LOOKBACK} lookback the bare series must disappear between pushes and trip absent(). Something is interpolating — check the ?max_lookback pin on the datasource URL (tests/gates/lib/vmalert-e2e.sh), VM's range-query staleness heuristic on vmsingle ${VME_VM_VER}, and the backfill grid (heartbeats must be ${DEB_CRON_PERIOD_S}s apart). While this leg is broken, a deployed rule that lost its rollup would still pass L1/L5."
drop_leg l3-buggy

# ── L4(수집 카운트 축): 하트비트는 정상인데 scraped < configured → 카운트 알림이 발화해야 함 ────────
# ★ 이 레그가 US2의 유일한 발화 증명이다. 하트비트가 **정상**인 것이 핵심 — push 경로는 살아 있고 GHCR
#   수집만 부분 실패한 이 고장은 DigestExporterStale이 **원리적으로 못 잡는다**(직교 축). 지금 코드는
#   `[ -z "$DIGEST" ] && continue`로 그 앱을 조용히 스킵할 뿐이라, 이 알림이 없으면 드리프트 감시에서
#   앱이 소리 없이 빠진다.
run_leg l4-incomplete "$VME_TMP/r4-deployed.yaml" incomplete $(( BACKFILL_N + RP_LEN / DEB_CRON_PERIOD_S + 1 )) "$N_CFG" "$N_SCRAPED_PARTIAL"
CFG4="$(vme_promql "last_over_time(${CFG_METRIC}[30d])")"; SCR4="$(vme_promql "last_over_time(${SCRAPED_METRIC}[30d])")"
F4="$(vme_firing "$SCRAPE_ALERT")"; P4="$(vme_pending "$SCRAPE_ALERT")"; HF4="$(vme_firing "$ALERT")"
echo "  [L4] deployed rule + healthy heartbeat + counts scraped=$SCR4 < configured=$CFG4 → $SCRAPE_ALERT firing=$F4 pending=$P4 ($ALERT firing=$HF4)"
# 입력 sanity: 백필이 실제로 격차를 심었는가(안 심었으면 '발화 없음'도 '발화'도 무의미하다).
{ [ "$CFG4" -eq "$N_CFG" ] && [ "$SCR4" -eq "$N_SCRAPED_PARTIAL" ]; } || vme_fault "L4 백필 sanity: counts가 ${N_SCRAPED_PARTIAL}/${N_CFG}이 아니라 ${SCR4}/${CFG4} — 생성기(incomplete 시나리오)가 격차를 심지 못했다."
# ★ **축 직교성 단언**(주장이 아니라 계약이다): 하트비트가 정상인 부분 수집 실패에 $ALERT는 **침묵해야** 한다.
#   여기가 무너지면 GHCR 부분 장애가 "push 사망"으로 **오귀속**돼 두 알림이 같은 고장에 겹쳐 울리고, 역으로
#   $ALERT의 의미론("push 경로 생존")이 깨진다(run.sh가 skopeo 전건 실패에도 하트비트를 내보내는 이유가 이것이다).
[ "$HF4" -eq 0 ] || vme_fail "L4 $ALERT ALSO fired (firing=$HF4) on a partial GHCR outage while the heartbeat was healthy the whole replay — the two axes are NOT orthogonal any more. A scrape failure is being misattributed to a dead push path: either the expr now keys off scrape success instead of ${HB}, or run.sh stopped emitting the heartbeat when skopeo fails. Both alerts would page for one fault, and a real push death would be indistinguishable from a GHCR outage."
verdict_fires "$F4" "$P4" \
  "L4 $SCRAPE_ALERT fired on a partial GHCR outage — the push path was alive the whole time (heartbeat healthy, $ALERT firing=$HF4) but only ${SCR4} of ${CFG4} configured apps was scraped (firing samples=$F4)" \
  "L4 $SCRAPE_ALERT did NOT fire although only ${SCR4} of ${CFG4} configured apps were scraped for the entire ${RP_LEN}s replay (firing=0, pending=$P4, for: ${SCRAPE_FOR}). A GHCR outage or an expired ghcr-read token silently drops apps from digest drift monitoring and nobody is paged — the exact silence this alert exists to remove. Check that BOTH ${SCRAPED_METRIC} and ${CFG_METRIC} are wrapped in last_over_time(...[≥${DEB_CRON_PERIOD_S}s]) (a bare reference loses the series between 10-minute pushes and resets the for: hold every cycle) and that the comparison is 'scraped < configured'."
drop_leg l4-incomplete

# ── L5(absent 가지): 하트비트 샘플 전무 → 발화해야 함 ──────────────────────────────────────────────
# L1(stale 샘플)과 **다른 코드 경로**다 — `or absent(last_over_time(...))` 가지의 유일한 증명.
# 이 가지가 없으면 "한 번도 push된 적 없음"(exporter가 애초에 못 뜸 / [W] 만료)이 **빈 벡터 = 침묵**이 된다.
run_leg l5-absent "$VME_TMP/r4-deployed.yaml" absent 0 "$N_CFG" "$N_SCRAPED_OK"
F5="$(vme_firing "$ALERT")"; P5="$(vme_pending "$ALERT")"
echo "  [L5] deployed rule + NO heartbeat samples at all → $ALERT firing=$F5 pending=$P5"
verdict_fires "$F5" "$P5" \
  "L5 $ALERT fired with zero heartbeat samples in the TSDB (firing=$F5) — the 'or absent(last_over_time(...))' arm is live" \
  "L5 $ALERT did NOT fire even though ${HB} has NO samples at all (firing=0, pending=$P5) — an exporter that never pushed once (pod never started, or the series aged out of [${W}]) is silence, not a page. The expr needs an 'or absent(last_over_time(${HB}[${W}]))' arm; a bare absent() does NOT work here (it is itself subject to the ${VME_LOOKBACK} lookback hole)."
drop_leg l5-absent

# ── L6(zero-app): 카운트 0/0 → 카운트 알림 **무발화**(owner 결정 ④ — 의도된 공백) ──────────────────
# 마지막 앱을 teardown하면 APPS가 빈 문자열이 되어 configured=0·scraped=0이 push된다. `0 < 0`은 거짓이라
# 침묵한다 — 앱이 0개면 감시할 대상 자체가 없으므로 이것이 **정답**이다(가드를 넣지 않기로 확정).
# ★ 이 레그가 그 결정을 **락한다**: `<`를 `<=`로 바꾸거나 zero-app 가드(configured==0 발화)를 나중에
#   추가하면 여기서 죽는다. 음성 레그이므로 vacuity 차단을 이중으로 건다 —
#   ①카운트 시리즈가 **실제로 존재**한다(0 값으로 발행됨 — 미발행이면 빈 벡터라 우연히 조용할 뿐이다)
#   ②대조 알림이 같은 replay에서 발화한다(vmalert가 실제로 룰을 평가하고 ALERTS를 썼다).
run_leg l6-zeroapp "$VME_TMP/r4-deployed.yaml" zeroapp $(( BACKFILL_N + RP_LEN / DEB_CRON_PERIOD_S + 1 )) "$N_ZERO" "$N_ZERO"
PRESENT6="$(vme_series_count "last_over_time(${CFG_METRIC}[30d])")"
CFG6="$(vme_promql "last_over_time(${CFG_METRIC}[30d])")"; SCR6="$(vme_promql "last_over_time(${SCRAPED_METRIC}[30d])")"
F6="$(vme_firing "$SCRAPE_ALERT")"; P6="$(vme_pending "$SCRAPE_ALERT")"; C6="$(vme_firing "$CONTROL")"
echo "  [L6] deployed rule + counts configured=$CFG6 scraped=$SCR6 (series present=$PRESENT6) → $SCRAPE_ALERT firing=$F6 pending=$P6 (control $CONTROL firing=$C6)"
[ "$PRESENT6" -eq 1 ] || vme_fault "L6 백필 sanity: ${CFG_METRIC} 시리즈가 TSDB에 없다(present=$PRESENT6) — 값 0이 **발행된** 상태를 재현해야 침묵이 의미를 갖는다. 시리즈가 아예 없으면 expr이 빈 벡터라 어떤 룰이든 조용하므로 이 레그는 vacuous하다."
{ [ "$CFG6" -eq "$N_ZERO" ] && [ "$SCR6" -eq "$N_ZERO" ]; } || vme_fault "L6 백필 sanity: counts가 ${N_ZERO}/${N_ZERO}이 아니라 ${CFG6}/${SCR6} — 생성기(zeroapp 시나리오) 오류."
[ "$C6" -gt 0 ] || vme_fault "L6: control alert $CONTROL did not fire in the zero-app replay — vmalert wrote nothing, so '$SCRAPE_ALERT absent' proves nothing (vacuous pass)."
verdict_silent "$F6" "$P6" \
  "L6 zero-app stays silent as decided — counts ${N_ZERO}/${N_ZERO} are published yet the strict comparison (${N_ZERO} < ${N_ZERO} = false) never engages (firing=0, pending=0), while the control alert proves the replay was live" \
  "L6 $SCRAPE_ALERT engaged on a zero-app exporter (firing=$F6, pending=$P6) although counts are ${N_ZERO}/${N_ZERO} — with no apps configured there is nothing to scrape, so this is a false page by design decision ④. Someone widened the comparison to '<=' or added a 'configured == 0' guard; the deliberate gap is documented in the rule comment in ${RULES_CM}."
drop_leg l6-zeroapp

# ── L7(부트스트랩): 평가 시작 시 하트비트 없음 → 첫 샘플이 **강제 상한**에 정확히 도착 → 무발화 ────
# 최초 배포의 최악 시나리오다: 이력이 없어 absent(...)가 즉시 pending에 들어간다. for:가 강제 상한보다
# 크므로 첫 하트비트가 반드시 pending을 리셋한다 → **롤아웃이 원인인 거짓 페이지가 구조적으로 불가능**.
# 단언 3개: ①pending>0(레그가 vacuous하지 않다 — 룰이 실제로 engage했다) ②발화 경계를 넘겨 replay ③firing==0.
run_leg l7-bootstrap "$VME_TMP/r4-deployed.yaml" bootstrap $(( (RP_LEN - BOUND_S) / DEB_CRON_PERIOD_S + 1 )) "$N_CFG" "$N_SCRAPED_OK"
F7="$(vme_firing "$ALERT")"; P7="$(vme_pending "$ALERT")"
echo "  [L7] deployed rule + first heartbeat arriving exactly at the enforced bound (${BOUND_S}s), replay runs ${RP_LEN}s (> bound+for:=${NEED_L7}s) → firing=$F7 pending=$P7"
verdict_engages_never_fires "$F7" "$P7" \
  "L7 first deploy cannot false-page — the rule engaged on the empty history (pending=$P7) but the first heartbeat landed at the enforced bound ${BOUND_S}s < for: ${FOR}(${FOR_S}s) and reset the hold before it could fire (firing=0), with the replay running ${RP_LEN}s past that point" \
  "L7 $ALERT FIRED on a fresh deploy (firing=$F7) — the rollout itself pages. The first heartbeat arrives at the ENFORCED worst-case bound ${BOUND_S}s (cron ${DEB_CRON_PERIOD_S}s + pod budget ${DEB_POD_START_BUDGET_S}s + activeDeadlineSeconds ${DEB_ACTIVE_DEADLINE_S}s) but for: is only ${FOR}(${FOR_S}s), so absent(...) holds long enough to fire. Raise for: above ${BOUND_S}s, or lower the cron period / activeDeadlineSeconds (then re-check the in-deadline budget ④)." \
  "L7 is VACUOUS — the rule never even entered pending (pending=0) although no heartbeat existed for the first ${BOUND_S}s of the replay. The 'no false page on first deploy' claim proves nothing if the rule isn't engaging; check the absent() arm and the backfill grid."
drop_leg l7-bootstrap

echo "[elapsed] $(( $(date +%s) - START_EPOCH ))s"
if [ "$VME_FAILED" -gt 0 ]; then
  echo "vmalert-digest-stale-firing-e2e: ${VME_FAILED} leg(s) FAILED" >&2
  exit 1
fi
# ⚠️ `${ALERT}`로 감쌀 것 — `$ALERT가`처럼 한글이 바로 붙으면 bash가 멀티바이트를 **변수명에 포함**시켜
#    `set -u`에서 "unbound variable"로 죽는다(실측: 전 레그 PASS 후 마지막 줄에서 발생).
echo "vmalert-digest-stale-firing-e2e OK (preflight + L1/L2/L3/L4/L5/L6/L7 통과 — ${ALERT}가 하트비트 침묵(stale·전무)에 발화하고, ${SCRAPE_ALERT}가 부분 수집 실패에 발화하며, 정상(하트비트+동일 카운트)·zero-app에는 둘 다 침묵하고, 맨 참조 결함 expr은 여전히 못 울며, 최초 배포는 거짓 페이지를 내지 않는다)"
