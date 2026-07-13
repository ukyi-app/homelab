#!/usr/bin/env bash
# vmalert **발화** e2e (digest-exporter 하트비트) — `DigestExporterStale`이 "파싱된다"가 아니라
# "실제로 발화한다"(그리고 정상·부트스트랩에는 **침묵한다**)를 증명한다.
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
#   preflight  부트스트랩 불변식 4 + 룰 산술 3 (위반 = exit 2 — 룰 판정이 아니라 전제 붕괴다)
#   L1 stale 하트비트(끊김)        → DigestExporterStale **발화**        (stale-샘플 가지)
#   L2 정상 하트비트               → **firing==0 AND pending==0** + 대조 알림 FilesBackupStale firing>0
#   L3 결함 픽스처(맨 참조) + 정상 → **firing==0 AND pending>0**        (하네스의 이빨 — 거짓 GREEN 최종 보증)
#   L5 하트비트 샘플 **전무**      → DigestExporterStale **발화**        (`or absent(...)` 가지의 유일한 증명)
#   L7 부트스트랩(첫 샘플이 강제 상한 840s에 정확히 도착) → **pending>0**(비-vacuity) **AND firing==0**
#      ↳ 최초 배포의 거짓 페이지가 **구조적으로 불가능**함을 증명한다. 누가 for:를 줄이거나·크론을 늘리거나·
#        activeDeadlineSeconds를 키우면 여기서(또는 preflight ①에서) 죽는다.
#   (L4·L6 = 수집 카운트 알림 — 후속 이슈 I-2 소관. 번호는 그 계약과 맞춰 비워 둔다.)
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
CONTROL=FilesBackupStale   # 같은 r4 그룹의 absent 가드 알림 — 음성 레그의 vacuity 대조군

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
for want in "alert: $ALERT" "alert: $CONTROL"; do
  grep -q "$want" "$VME_TMP/r4-deployed.yaml" || vme_fault "배포 룰에 '$want' 부재 — 하네스가 아무것도 측정하지 않는다"
done
grep -q "alert: $ALERT" "$VME_TMP/r4-buggy.yaml" || vme_fault "결함 픽스처에 'alert: $ALERT' 부재 — L3가 무측정"

EXPR="$(vme_alert_expr "$VME_TMP/r4-deployed.yaml" "$ALERT")"
[ -n "$EXPR" ] || vme_fault "배포 룰에서 $ALERT expr 추출 실패"
FOR="$(yq '.groups[].rules[] | select(.alert=="'"$ALERT"'") | .for' "$VME_TMP/r4-deployed.yaml" | head -1)"
FOR_S="$(vme_to_s "$FOR")"
CTRL_FOR="$(yq '.groups[].rules[] | select(.alert=="'"$CONTROL"'") | .for' "$VME_TMP/r4-deployed.yaml" | head -1)"
CTRL_FOR_S="$(vme_to_s "$CTRL_FOR")"
# staleness 임계 T — expr의 `> N`에서 파생(하드코딩 금지).
T_S="$(grep -oE '>[[:space:]]*[0-9]+' <<<"$EXPR" | head -1 | grep -oE '[0-9]+' || true)"
[ -n "$T_S" ] || vme_fault "$ALERT expr에서 staleness 임계(> N)를 파생하지 못했다"
HB=digest_exporter_last_success_timestamp
W="$(vme_rollup_windows "$EXPR" "$HB")"

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

# ⑥ rollup 윈도 하한: W ≥ push 주기. **상한은 없다**(타임스탬프-값 하트비트 — 위 헤더 주석 참조).
#    rollup 부재 = 모드 C 그 자체다 → 검사만 건너뛰고 L1/L5가 RED로 잡게 둔다(자기 RED 경로를 지우지 않는다).
if [ -z "$W" ]; then
  echo "[preflight] rollup: ABSENT on ${HB} → W 불변식 검사 skip (이게 버그다 — L1/L5가 RED로 잡는다)"
  W_S=0
else
  case "$W" in *' '*) vme_fault "${HB}에 rollup 윈도가 복수($W) — 유효 윈도 판정 불가" ;; esac
  W_S="$(vme_to_s "$W")"
  [ "$W_S" -ge "$DEB_CRON_PERIOD_S" ] || vme_fault "윈도 불변식 위반 (W ≥ push): W=${W}(${W_S}s) < push 주기(${DEB_CRON_PERIOD_S}s) — 주기 사이 구멍이 남아 for: pending이 리셋된다(모드 C)."
  echo "[preflight] W=$W(${W_S}s) ≥ push(${DEB_CRON_PERIOD_S}s) OK — 상한 없음(타임스탬프-값 하트비트: 윈도는 탐색 지평일 뿐)"
fi

# ⑦ 구멍의 전제: 룩백 < push 주기. (룩백 ≥ push면 구멍이 없어 모드 C 자체가 성립 안 하고 L3가 무의미해진다.)
[ "$VME_LOOKBACK_S" -lt "$DEB_CRON_PERIOD_S" ] || vme_fault "룩백(${VME_LOOKBACK}=${VME_LOOKBACK_S}s) ≥ push 주기(${DEB_CRON_PERIOD_S}s) — 구멍이 생기지 않는다(모드 C 전제 소멸). L3 결함 픽스처가 이빨을 잃으므로 레그 산술을 재설계하라."

# ── 3) 시간창 — eval 격자에 정렬(결정성) ───────────────────────────────────────────────────────────
# RP_LEN: 모든 레그를 동시에 만족하는 최소 길이 + 여유
#   · L1/L5: > for:                    (픽스된 룰이 발화할 시간)
#   · L2   : > 대조 알림 for:(${CTRL_FOR})  (FilesBackupStale이 발화해 vacuity를 배제)
#   · L7   : > 강제 상한 + for:         (첫 하트비트 도착 후 발화 경계를 **넘겨** replay)
NEED_L7=$(( BOUND_S + FOR_S ))
RP_LEN="$CTRL_FOR_S"
[ "$NEED_L7" -gt "$RP_LEN" ] && RP_LEN="$NEED_L7"
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

echo "[params] vmalert=$VME_VA_VER vmsingle=$VME_VM_VER eval=$VME_EVAL lookback=$VME_LOOKBACK(queryStep) push=${DEB_CRON_PERIOD_S}s for=$FOR(${FOR_S}s) T=${T_S}s W=${W:-none}"
echo "[bound]  강제 최악 첫 하트비트 = cron(${DEB_CRON_PERIOD_S}) + 파드예산(${DEB_POD_START_BUDGET_S}) + activeDeadlineSeconds(${DEB_ACTIVE_DEADLINE_S}) = ${BOUND_S}s < for:(${FOR_S}s) ✓  [concurrencyPolicy=$DEB_CONCURRENCY_POLICY]"
echo "[budget] 인-데드라인 = ${DEB_POD_START_BUDGET_S} + N(${DEB_APPS_N})×${DEB_SKOPEO_TIMEOUT_S} + ${DEB_CURL_MAX_TIME_S} + ${DEB_EXEC_SLACK_S} = ${BUDGET}s < ADS(${DEB_ACTIVE_DEADLINE_S}s) ✓  (N_MAX=${N_MAX} — 8번째 앱은 CI red)"
echo "[window] replay $(vme_iso "$RP_FROM") .. $(vme_iso "$RP_TO") (${RP_LEN}s) | stale_last=$(vme_iso "$STALE_LAST")"

# ── 4) 레그 실행기 ─────────────────────────────────────────────────────────────────────────────────
run_leg() { # $1=label $2=rules-file $3=scenario $4=기대 하트비트 샘플 수(-1 = 검사 생략)
  local label="$1" rules="$2" scenario="$3" want_hb="$4" vm="r4dgst-e2e-$1-$$"
  vme_start_vmsingle "$vm" "$VME_VM_VER"
  python3 "$GEN" "$scenario" "$RP_FROM" "$RP_TO" "$DEB_CRON_PERIOD_S" "$BOUND_S" "$STALE_LAST" "$BACKFILL_N" > "$VME_TMP/$label.jsonl"
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

# ── L1(stale-샘플 가지): 하트비트가 끊긴 지 임계 초과 → 발화해야 함 ────────────────────────────────
run_leg l1-stale "$VME_TMP/r4-deployed.yaml" stale $(( BACKFILL_N + 1 ))
F1="$(vme_firing "$ALERT")"; P1="$(vme_pending "$ALERT")"
echo "  [L1] deployed rule + heartbeat stopped $(( RP_FROM - STALE_LAST ))s before replay → $ALERT firing=$F1 pending=$P1"
if [ "$F1" -gt 0 ]; then
  vme_pass "L1 $ALERT fired after the heartbeat went silent past the ${T_S}s threshold (firing samples=$F1)"
else
  vme_fail "L1 $ALERT did NOT fire even though the digest-exporter heartbeat stopped $(( RP_FROM - STALE_LAST ))s before the replay window and stayed silent for ${RP_LEN}s (threshold ${T_S}s, for: ${FOR}) — firing=0, pending=$P1. The exporter can die silently and ImageDigestDrift goes blind with nobody paged. Check that the expr wraps ${HB} in last_over_time(...[≥${DEB_CRON_PERIOD_S}s]) — a bare reference loses the series between 10-minute pushes and resets the for: hold every cycle."
fi
drop_leg l1-stale

# ── L2(음성 대조): 정상 하트비트 → 침묵. + 대조 알림으로 vacuity 차단 ─────────────────────────────
run_leg l2-healthy "$VME_TMP/r4-deployed.yaml" healthy $(( BACKFILL_N + RP_LEN / DEB_CRON_PERIOD_S + 1 ))
F2="$(vme_firing "$ALERT")"; P2="$(vme_pending "$ALERT")"; C2="$(vme_firing "$CONTROL")"
echo "  [L2] deployed rule + healthy heartbeat every ${DEB_CRON_PERIOD_S}s → $ALERT firing=$F2 pending=$P2 (control $CONTROL firing=$C2)"
# 이 레그의 판정은 "발화 부재"(음성)다 → vmalert가 애초에 아무것도 안 썼어도 통과해버릴 수 있다.
# 같은 replay에서 대조 알림(생성기가 의도적으로 심지 않는 메트릭의 absent 가드)이 발화했는지로 그것을 막는다.
[ "$C2" -gt 0 ] || vme_fault "L2: control alert $CONTROL did not fire in the healthy replay — vmalert wrote nothing, so '$ALERT absent' proves nothing (vacuous pass)."
if [ "$F2" -eq 0 ] && [ "$P2" -eq 0 ]; then
  vme_pass "L2 no false page while the exporter heartbeats normally every ${DEB_CRON_PERIOD_S}s (firing=0, pending=0 — the rule never even engages)"
elif [ "$F2" -gt 0 ]; then
  vme_fail "L2 $ALERT FIRED (firing=$F2) while the exporter was heartbeating normally every ${DEB_CRON_PERIOD_S}s — false positive. A healthy exporter must never page; the max heartbeat age here is ${DEB_CRON_PERIOD_S}s, well under the ${T_S}s threshold."
else
  vme_fail "L2 $ALERT entered pending (pending=$P2) with a healthy heartbeat — the expr flaps (it goes true between pushes), which means the rollup is missing or its window is shorter than the ${DEB_CRON_PERIOD_S}s push period. It would reset the for: hold every cycle and thus never fire when the exporter really dies."
fi
drop_leg l2-healthy

# ── L3(하네스의 이빨): 결함 픽스처(맨 참조) + 정상 하트비트 → 발화 금지, 단 pending은 존재해야 함 ──
# ★ 이 레그가 **거짓 GREEN에 대한 최종 보증**이다(datasource 룩백 핀이 아니라).
#   pending>0 = 10분 push 구멍이 **실재한다**는 양성 증거(맨 참조가 주기 후반에 사라져 absent가 켜진다).
#   pending==0이면 하네스가 구멍을 보간하고 있다는 뜻 → 배포 룰이 안 고쳐졌는데도 L1/L5가 통과할 수 있다.
#   firing==0 = 맨 참조는 for:를 절대 못 넘긴다(구멍이 매 주기 pending을 리셋한다).
run_leg l3-buggy "$VME_TMP/r4-buggy.yaml" healthy $(( BACKFILL_N + RP_LEN / DEB_CRON_PERIOD_S + 1 ))
F3="$(vme_firing "$ALERT")"; P3="$(vme_pending "$ALERT")"
echo "  [L3] fixtures/r4-digest-stale-buggy-expr.yaml (bare reference) + healthy heartbeat → firing=$F3 pending=$P3"
if [ "$F3" -eq 0 ] && [ "$P3" -gt 0 ]; then
  vme_pass "L3 harness has teeth — the frozen bare-reference expr engages every cycle (pending=$P3: the series vanishes ${VME_LOOKBACK} after each ${DEB_CRON_PERIOD_S}s push) but can never hold for: ${FOR} (firing=0)"
elif [ "$F3" -gt 0 ]; then
  vme_fail "L3 the frozen bare-reference expr FIRED (firing=$F3) on a HEALTHY heartbeat — the harness's grid or the fixture is wrong: a bare reference must flap (true only while the series is invisible) and thus never reach for: ${FOR}. Until this leg is green again, L1/L5's verdicts are meaningless."
else
  vme_fail "L3 the frozen bare-reference expr produced NO alert state at all (pending=0) — the ${DEB_CRON_PERIOD_S}s push holes are being BRIDGED (false GREEN): with a ${VME_LOOKBACK} lookback the bare series must disappear between pushes and trip absent(). Something is interpolating — check the ?max_lookback pin on the datasource URL (tests/gates/lib/vmalert-e2e.sh), VM's range-query staleness heuristic on vmsingle ${VME_VM_VER}, and the backfill grid (heartbeats must be ${DEB_CRON_PERIOD_S}s apart). While this leg is broken, a deployed rule that lost its rollup would still pass L1/L5."
fi
drop_leg l3-buggy

# ── L5(absent 가지): 하트비트 샘플 전무 → 발화해야 함 ──────────────────────────────────────────────
# L1(stale 샘플)과 **다른 코드 경로**다 — `or absent(last_over_time(...))` 가지의 유일한 증명.
# 이 가지가 없으면 "한 번도 push된 적 없음"(exporter가 애초에 못 뜸 / [W] 만료)이 **빈 벡터 = 침묵**이 된다.
run_leg l5-absent "$VME_TMP/r4-deployed.yaml" absent 0
F5="$(vme_firing "$ALERT")"; P5="$(vme_pending "$ALERT")"
echo "  [L5] deployed rule + NO heartbeat samples at all → $ALERT firing=$F5 pending=$P5"
if [ "$F5" -gt 0 ]; then
  vme_pass "L5 $ALERT fired with zero heartbeat samples in the TSDB (firing=$F5) — the 'or absent(last_over_time(...))' arm is live"
else
  vme_fail "L5 $ALERT did NOT fire even though ${HB} has NO samples at all (firing=0, pending=$P5) — an exporter that never pushed once (pod never started, or the series aged out of [${W}]) is silence, not a page. The expr needs an 'or absent(last_over_time(${HB}[${W}]))' arm; a bare absent() does NOT work here (it is itself subject to the ${VME_LOOKBACK} lookback hole)."
fi
drop_leg l5-absent

# ── L7(부트스트랩): 평가 시작 시 하트비트 없음 → 첫 샘플이 **강제 상한**에 정확히 도착 → 무발화 ────
# 최초 배포의 최악 시나리오다: 이력이 없어 absent(...)가 즉시 pending에 들어간다. for:가 강제 상한보다
# 크므로 첫 하트비트가 반드시 pending을 리셋한다 → **롤아웃이 원인인 거짓 페이지가 구조적으로 불가능**.
# 단언 3개: ①pending>0(레그가 vacuous하지 않다 — 룰이 실제로 engage했다) ②발화 경계를 넘겨 replay ③firing==0.
run_leg l7-bootstrap "$VME_TMP/r4-deployed.yaml" bootstrap $(( (RP_LEN - BOUND_S) / DEB_CRON_PERIOD_S + 1 ))
F7="$(vme_firing "$ALERT")"; P7="$(vme_pending "$ALERT")"
echo "  [L7] deployed rule + first heartbeat arriving exactly at the enforced bound (${BOUND_S}s), replay runs ${RP_LEN}s (> bound+for:=${NEED_L7}s) → firing=$F7 pending=$P7"
if [ "$P7" -eq 0 ]; then
  vme_fail "L7 is VACUOUS — the rule never even entered pending (pending=0) although no heartbeat existed for the first ${BOUND_S}s of the replay. The 'no false page on first deploy' claim proves nothing if the rule isn't engaging; check the absent() arm and the backfill grid."
elif [ "$F7" -eq 0 ]; then
  vme_pass "L7 first deploy cannot false-page — the rule engaged on the empty history (pending=$P7) but the first heartbeat landed at the enforced bound ${BOUND_S}s < for: ${FOR}(${FOR_S}s) and reset the hold before it could fire (firing=0), with the replay running ${RP_LEN}s past that point"
else
  vme_fail "L7 $ALERT FIRED on a fresh deploy (firing=$F7) — the rollout itself pages. The first heartbeat arrives at the ENFORCED worst-case bound ${BOUND_S}s (cron ${DEB_CRON_PERIOD_S}s + pod budget ${DEB_POD_START_BUDGET_S}s + activeDeadlineSeconds ${DEB_ACTIVE_DEADLINE_S}s) but for: is only ${FOR}(${FOR_S}s), so absent(...) holds long enough to fire. Raise for: above ${BOUND_S}s, or lower the cron period / activeDeadlineSeconds (then re-check the in-deadline budget ④)."
fi
drop_leg l7-bootstrap

echo "[elapsed] $(( $(date +%s) - START_EPOCH ))s"
if [ "$VME_FAILED" -gt 0 ]; then
  echo "vmalert-digest-stale-firing-e2e: ${VME_FAILED} leg(s) FAILED" >&2
  exit 1
fi
# ⚠️ `${ALERT}`로 감쌀 것 — `$ALERT가`처럼 한글이 바로 붙으면 bash가 멀티바이트를 **변수명에 포함**시켜
#    `set -u`에서 "unbound variable"로 죽는다(실측: 전 레그 PASS 후 마지막 줄에서 발생).
echo "vmalert-digest-stale-firing-e2e OK (preflight + L1/L2/L3/L5/L7 통과 — ${ALERT}가 하트비트 침묵(stale·전무)에 발화하고, 정상 하트비트엔 침묵하며, 맨 참조 결함 expr은 여전히 못 울고, 최초 배포는 거짓 페이지를 내지 않는다)"
