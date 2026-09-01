#!/usr/bin/env bash
# KubeJobFailed **발화** e2e — "실패 Job 오브젝트가 남아 있다"가 아니라 "정기 작업이 지금 고장이다"를
# 알리는지 증명한다.
#
# 병: `kube_job_failed`는 Job **오브젝트가 존재하는 한** 계속 1이다 — 시간 개념이 없다. 오브젝트 수명은
# `failedJobsHistoryLimit`이 지배하는데 그 회수는 **뒤이은 실패가 더 쌓여야만** 일어난다. 즉 정상 운영
# (이후 전부 성공)일수록 실패 Job이 영원히 남는다. 라이브: 1회 실패 뒤 430회 성공했는데 KubeJobFailed가
# **3일 넘게 연속 firing**했다. `for: 15m`은 "실패가 15분 지속됐다"가 아니라 "실패 Job 오브젝트가 15분
# 존재했다"만 증명한다.
#
# ★ 고유 레그는 **L2(전이)** — 한 시계열 안에서 발화 → 복구 → 해소를 실제로 겪게 하고 경계 전후를 따로
#   판정한다(L2a 발화 / L2b 침묵). 상태 스냅샷만으론 부족하다: 복구 시각을 창 **밖 미래**에 두고 모든
#   샘플에 실으면 첫 평가부터 억제가 걸려 통과하지만, 증명된 것은 "KSM이 낼 수 없는 타임라인에서 억제식이
#   참이더라"이고 전이는 한 번도 실행되지 않는다. 그 재발은 §3b preflight가 전제 붕괴로 끊는다.
#   L1=라이브 재현(창 이전 실패 + 계속 성공) · L3=미해소는 안 삼킴 · L4=CronJob 소유에만 억제 ·
#   L5=조인 키가 job 단위 · L7~L12=CronJobFlapping 상보성.
#
# ⚠️ **"이 레그가 X를 잠근다"는 뮤테이션으로만 성립한다.** 초판의 L4는 픽스처가 억제식 우변 메트릭을
#    아예 내지 않아 `owner_kind` 필터를 지워도 전건 green이었다(주석은 잠근다고 광고했다). 조인 키를
#    뭉개도 마찬가지였다. 그래서 픽스처를 "억제 재료를 **전부 갖춘 채 한 변수만** 다르게" 두도록 고쳤다.
#    실측 이빨: 억제 절 제거→L1·L2b red / `owner_kind` 제거→L4 red / `on (namespace)`로 뭉갬→L5b red /
#    창 밖 미래 TS→preflight CONTRACT(exit 2). 네 경우 모두 **나머지 레그는 green**이다.
#
# 종료 규약(공유 하네스): 2 = HARNESS FAULT/CONTRACT(전제 붕괴·vacuity) · 1 = leg FAIL · 0 = OK
# ⚠️ 이 하네스는 docker가 필요하다 — ci.yaml gate 스텝이 리터럴 경로로 직접 부른다(형제와 같은 규율).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="$ROOT/tests/gates/vmalert-jobfailed-gen.py"
ASSERT="$ROOT/tests/gates/vmalert-jobfailed-assert.py"
for _p in "$GEN" "$ASSERT"; do [ -x "$_p" ] || { echo "FAULT: 생성기/검사기 부재 $_p" >&2; exit 2; }; done
STACK="$ROOT/platform/victoria-stack/prod"
RULES_CM="$STACK/rules/core.yaml"

# shellcheck source=tests/gates/lib/vmalert-e2e.sh
. "$ROOT/tests/gates/lib/vmalert-e2e.sh"

ALERT=KubeJobFailed
FLAP_ALERT=CronJobFlapping

# 시나리오 상수 — 진단 산문과 시리즈 생성이 **같은 변수**를 읽는다(따로 적으면 둘이 갈린다).
NS=edge                 # 시스템 ns 블랙리스트에 걸리지 않는 워크로드 ns
CRONJOB2=recon-sibling  # L5: **같은 ns의 두 번째** CronJob(조인 키가 job 단위임을 잠근다)
JOB_CRON2=recon-sibling-29751321
CRONJOB=recon           # 소유 CronJob 이름
JOB_CRON=recon-29751320 # CronJob 소유 Job(라이브 명명 규약과 같은 모양)
JOB_SOLO=oneoff-import  # CronJob 소유가 아닌 단발 Job
STALE_AGE_S=259200      # L1: 실패 Job이 replay 창 **시작보다 이만큼 전**에 시작했다(라이브 adguard = 3일)
STALE_LEAD_S=3600       # 실패 Job 시작 **이전**이 마지막 성공(미해소 시나리오)

# ── 1) 배포 매니페스트에서 파라미터 파생(하드코딩 0) ───────────────────────────────────────────────
# 파라미터 파생·작업공간·룰 추출의 조립 순서는 lib(vme_scenario)이 소유한다 — 아래 한 호출이 기동이다.

vme_scenario "corejob-e2e-net-$$" "$STACK" "$RULES_CM" "core.yaml"

# fail-closed: 하네스가 겨냥하는 룰이 실제로 존재하는지(리네임 시 무성 무측정 방지)
for a in "$ALERT" "$FLAP_ALERT"; do
  grep -q "alert: $a" "$VME_RULES" \
    || vme_fault "배포 룰에 'alert: $a' 부재 — 하네스가 아무것도 측정하지 않는다"
done

EXPR="$(vme_alert_expr "$VME_RULES" "$ALERT")"
[ -n "$EXPR" ] || vme_fault "$ALERT: 배포 룰에서 expr 추출 실패"
FOR_S="$(vme_to_s "$(vme_alert_for "$VME_RULES" "$ALERT")")"
[ "$FOR_S" -gt 0 ] || vme_fault "$ALERT: for: 부재 또는 0 — 지속성 계약이 없다"

# ── flapping 룰의 창·임계는 **룰에서 파생**한다(하드코딩 금지 — 룰을 바꾸면 픽스처가 따라온다) ──
FLAP_EXPR="$(vme_alert_expr "$VME_RULES" "$FLAP_ALERT")"
[ -n "$FLAP_EXPR" ] || vme_fault "$FLAP_ALERT: 배포 룰에서 expr 추출 실패"
FLAP_FOR_S="$(vme_to_s "$(vme_alert_for "$VME_RULES" "$FLAP_ALERT")")"
[ "$FLAP_FOR_S" -gt 0 ] || vme_fault "$FLAP_ALERT: for: 부재 또는 0"
# 최근성 창 — `(time() - …) < <초>` 형태에서 뽑는다.
FLAP_WINDOW_S="$(grep -oE '\)\s*<\s*[0-9]+' <<<"$FLAP_EXPR" | grep -oE '[0-9]+$' | head -1)"
[ -n "$FLAP_WINDOW_S" ] || vme_fault "$FLAP_ALERT: 최근성 창 상수를 추출하지 못했다(expr 형태 변경?)"
# 발화 임계 — 말미 `>= N`.
FLAP_THRESHOLD="$(grep -oE '>=\s*[0-9]+' <<<"$FLAP_EXPR" | grep -oE '[0-9]+$' | tail -1)"
[ -n "$FLAP_THRESHOLD" ] || vme_fault "$FLAP_ALERT: 발화 임계를 추출하지 못했다(expr 형태 변경?)"
[ "$FLAP_THRESHOLD" -ge 2 ] \
  || vme_contract "$FLAP_ALERT 임계가 ${FLAP_THRESHOLD} — 1 이하면 단발 실패가 발화해 KubeJobFailed와 역할이 겹친다"

# ── 2b) preflight: 시나리오가 룰의 셀렉터를 실제로 통과하는지 기계가 확인 ──────────────────────────
# 픽스처가 룰의 블랙리스트에 걸리면 전 레그가 조용히 침묵해 **vacuous green**이 된다(L2/L3이 '발화 없음'
# 으로 통과하는 게 아니라 애초에 측정이 없었던 것). 그 상태를 판정이 아니라 전제 붕괴로 끊는다.
# ⚠️ **부분 문자열로 검사하지 마라** — 첫 구현이 `case $EXPR in *"$NS"*)`였는데 ns `edge`가
#    `pg-dump-hedge-r2`의 "h**edge**"에 걸려 거짓 CONTRACT를 냈다(가드가 자기 병에 걸린 자리다).
#    셀렉터의 정규식을 **추출해** 픽스처 값이 실제로 그 정규식에 매치되는지만 본다(앵커 필수 — PromQL의
#    `!~`는 완전 일치 의미론이다).
assert_not_excluded() { # $1=라벨명 $2=픽스처 값
  local re
  re="$(grep -oE "$1!~\"[^\"]*\"" <<<"$EXPR" | head -1 | sed "s/.*!~\"//; s/\"\$//")"
  [ -n "$re" ] || return 0   # 그 라벨에 블랙리스트가 없으면 검사할 것이 없다
  if printf '%s' "$2" | grep -qE "^($re)\$"; then
    vme_contract "픽스처 $1='$2'가 룰의 블랙리스트 '$re'에 매치된다 — 전 레그가 무측정(vacuous green)이 된다"
  fi
}
assert_not_excluded namespace "$NS"
assert_not_excluded job_name "$JOB_CRON"
assert_not_excluded job_name "$JOB_SOLO"
grep -q 'kube_job_failed' <<<"$EXPR" \
  || vme_fault "$ALERT expr이 kube_job_failed를 읽지 않는다 — 하네스의 픽스처 메트릭이 룰과 무관하다"

# KSM 메트릭은 **scrape**이지 push가 아니다 — 모드 C(push 주기 > 룩백) 구멍이 원리적으로 없으므로
# rollup 불변식 검사 대상이 아니다. 샘플 간격은 vmalert eval 간격과 같게 둔다(라이브 scrape보다 촘촘하면
# 발화가 샘플 밀도 덕에 성립하는 인공물이 생긴다).
SAMPLE_S="$VME_EVAL_S"
[ "$SAMPLE_S" -gt 0 ] || vme_fault "eval 간격 파생 실패(VME_EVAL=$VME_EVAL)"

# ── 3) 합성 시계열 ────────────────────────────────────────────────────────────────────────────────
# ★ 실패 간격은 임의 상수가 아니라 **감시 대상 중 최장 주기의 2배**다 — 교대 실패(성공↔실패)에서
#   연속한 두 실패는 2주기 떨어지기 때문이다. 초판은 창/6이라는 임의값(600s)을 써서 **가장 불리한
#   대상을 시험하지 않았고**, 그래서 창이 1h일 때 gha-liveness(주기 1800s → 간격 3600s)가 원리적으로
#   발화 불가였는데도 전건 green이었다(적대적 리뷰 R-1). 여기서 그 최악 케이스를 픽스처로 만든다.
#   ⚠️ 최장 주기 대상은 gha-liveness-exporter다(다른 대상은 600s). 그 가정이 깨지면(더 긴 주기의
#     대상이 생기면) 정적 게이트 test_cronjob-flapping.bats의 `2×주기+for` 부등식이 먼저 red를 낸다.
# lifecycle 레그(L12)는 **가장 짧은 주기** 대상을 쓴다 — 회수가 가장 빨리 일어나 pending을 가장
# 자주 리셋하는 최악 케이스다. 주기와 limit 둘 다 매니페스트에서 파생한다(하드코딩 0).
AG_MF="$ROOT/platform/adguard/prod/rewrite-reconciler.yaml"
LC_CRON_MIN="$(grep -oE '^  schedule: "\*/([0-9]+) ' "$AG_MF" | grep -oE '[0-9]+' || true)"
[ -n "$LC_CRON_MIN" ] || vme_fault "adguard 리컨실러 크론 주기 추출 실패 — lifecycle 레그를 파생할 수 없다"
LIFECYCLE_PERIOD_S=$(( LC_CRON_MIN * 60 ))
LIFECYCLE_FAILLIMIT="$(grep -oE '^  failedJobsHistoryLimit: [0-9]+' "$AG_MF" | grep -oE '[0-9]+' || true)"
[ -n "$LIFECYCLE_FAILLIMIT" ] || vme_fault "adguard 리컨실러 failedJobsHistoryLimit 추출 실패"

GHA_CRON_MIN="$(grep -oE '^  schedule: "\*/([0-9]+) ' "$STACK/gha-liveness-exporter.yaml" | grep -oE '[0-9]+' || true)"
[ -n "$GHA_CRON_MIN" ] || vme_fault "gha-liveness-exporter 크론 주기 추출 실패 — 최악 케이스 간격을 파생할 수 없다"
MAX_TARGET_PERIOD_S=$(( GHA_CRON_MIN * 60 ))
FLAP_SPREAD_S=$(( MAX_TARGET_PERIOD_S * 2 ))

# 창은 **전이 레그(L2)가 지배**한다: 복구 전에 for:를 채워 발화하고, 복구 후에도 해소를 관측할 구간이
# 남아야 한다. FOR_S×4 = [발화 구간 2×for] + [해소 관측 구간 2×for].
# ⚠️ flapping 레그의 요구가 더 크면 그쪽이 창을 지배한다 — 실패 간격(2×최장주기) 이후에도 겹침 구간이
#    for: 를 채울 만큼 남아야 한다. 이 max()가 없으면 R-1 최악 케이스 픽스처가 창에 안 들어간다.
SPAN_S=$(( FOR_S * 4 ))
FLAP_SPAN_NEED_S=$(( FLAP_SPREAD_S + FLAP_FOR_S * 2 ))
[ "$SPAN_S" -ge "$FLAP_SPAN_NEED_S" ] || SPAN_S="$FLAP_SPAN_NEED_S"
TO_EPOCH="$(date +%s)"
FROM_EPOCH=$(( TO_EPOCH - SPAN_S ))
# L2의 복구 시각 — 창 **안**이어야 한다. 이 오프셋 이전엔 미해소(발화), 이후엔 해소(침묵)다.
RECOVERY_OFFSET_S=$(( FOR_S * 2 ))
RECOVERY_AT=$(( FROM_EPOCH + RECOVERY_OFFSET_S ))
# 해소 관측 구간 — 복구 직후 eval 두 주기는 완충으로 뺀다(그 경계에서 발화가 끊긴다).
AFTER_GUARD_S=$(( VME_EVAL_S * 2 ))
AFTER_WIN_S=$(( TO_EPOCH - RECOVERY_AT - AFTER_GUARD_S ))

# ── 3b) preflight: 시나리오 산술이 레그를 의미 있게 만드는지 ───────────────────────────────────────
# ⚠️ 이 넷은 **셸 스칼라끼리의 검사**이고, 전부 FOR_S에서 파생돼 사실상 `FOR_S > eval` 한 문장이다.
#    시나리오 상수를 손댔을 때의 안전망일 뿐, **생성된 시계열은 보지 못한다** — R-2의 몸통은 파이썬
#    생성기 안(전 샘플에 창 밖 미래 상수 적재)에 있었으므로 이 블록으로는 원리적으로 못 막는다.
#    (자체 감사 S-3이 실증: last-success를 `to+3600` 상수로 되돌려도 여기는 침묵하고 전건 green이었다.)
#    실제 물리 불변식은 아래 `assert_no_future_timestamps`가 **생성된 JSONL을 읽어** 강제한다.
[ "$RECOVERY_OFFSET_S" -gt "$FOR_S" ] \
  || vme_contract "L2 무의미: 복구 오프셋(${RECOVERY_OFFSET_S}s) <= for:(${FOR_S}s) — 복구 전에 발화할 시간이 없다"
[ "$RECOVERY_AT" -lt "$TO_EPOCH" ] \
  || vme_contract "L2 무의미: 복구 시각이 replay 창 밖이다(RECOVERY_AT=${RECOVERY_AT} >= TO=${TO_EPOCH})"
[ "$AFTER_WIN_S" -gt 0 ] \
  || vme_contract "L2 무의미: 복구 후 관측 구간이 없다(AFTER_WIN=${AFTER_WIN_S}s) — 해소를 볼 수 없다"
[ "$STALE_AGE_S" -gt 0 ] \
  || vme_contract "L1 무의미: 실패 Job이 창 시작 이전이 아니다(STALE_AGE=${STALE_AGE_S}s)"

# ── L7/L8 산술: 실패 N건이 flapping 룰의 최근성 창 안에서 for:를 채울 만큼 **겹쳐야** 한다 ────────
# 실패 Job들은 replay 창 시작(FROM) 이전부터 FROM 사이에 흩뿌린다 — 시작 시각이 샘플 시각보다
# 미래일 수 없기 때문이다(그 위반은 assert_no_future_timestamps가 잡는다). 가장 오래된 실패는
# FROM - FLAP_SPREAD_S에 있으므로, 그것이 창 밖으로 밀려나기 전까지의 겹침 구간은
#   overlap = FLAP_WINDOW_S - FLAP_SPREAD_S
# 이고 이게 for:보다 커야 발화를 관측할 수 있다.
#
FLAP_OVERLAP_S=$(( FLAP_WINDOW_S - FLAP_SPREAD_S ))
[ "$FLAP_OVERLAP_S" -gt "$FLAP_FOR_S" ] \
  || vme_contract "L7 무의미: 실패들이 창 안에 함께 머무는 구간(${FLAP_OVERLAP_S}s) <= for:(${FLAP_FOR_S}s) — 발화를 관측할 수 없다"
[ "$SPAN_S" -gt "$FLAP_FOR_S" ] \
  || vme_contract "L7 무의미: replay 창(${SPAN_S}s) <= flapping for:(${FLAP_FOR_S}s)"
echo "[preflight] 산술 OK: 창 ${SPAN_S}s · for ${FOR_S}s · 복구 +${RECOVERY_OFFSET_S}s(창 안) · 해소 관측 ${AFTER_WIN_S}s · L1 실패는 창 시작 -${STALE_AGE_S}s"
echo "[preflight] flapping OK: 창 ${FLAP_WINDOW_S}s · 임계 ${FLAP_THRESHOLD} · for ${FLAP_FOR_S}s · 실패 간격 ${FLAP_SPREAD_S}s · 겹침 ${FLAP_OVERLAP_S}s"

# ★★ 물리 불변식 — **생성된 시계열 자체**를 검사한다. 이게 R-2류의 진짜 방어선이다.
#    타임스탬프를 값으로 갖는 KSM 메트릭은 "아직 일어나지 않은 일"을 내보낼 수 없다. 즉 어떤 샘플에서도
#    `값 ≤ 그 샘플의 시각`이어야 한다. R-2는 정확히 이 규칙을 어겼다(값이 replay 종료보다 900s 뒤인데
#    첫 샘플부터 실려 억제가 소급 적용됐다). 산술 preflight로는 못 잡으므로 여기서 데이터를 직접 본다.
assert_no_future_timestamps() { # $1=jsonl
  python3 "$ASSERT" "$1" || return 1
}

gen() { # $1=출력파일 $2=시나리오(stale_resolved|transition|two_jobs|unresolved|standalone|healthy)
  python3 "$GEN" "$1" "$2" "$FROM_EPOCH" "$TO_EPOCH" "$SAMPLE_S" \
    "$NS" "$CRONJOB" "$JOB_CRON" "$JOB_SOLO" "$STALE_AGE_S" "$STALE_LEAD_S" "$RECOVERY_AT" \
    "$CRONJOB2" "$JOB_CRON2" "$FLAP_THRESHOLD" "$FLAP_SPREAD_S" \
    "$LIFECYCLE_PERIOD_S" "$LIFECYCLE_FAILLIMIT"
}

run_scenario() { # $1=시나리오 → vmsingle 기동 + import + replay
  local scen="$1"
  local vm="vm-corejob-$scen-$$"
  gen "$VME_TMP/$scen.jsonl" "$scen"
  assert_no_future_timestamps "$VME_TMP/$scen.jsonl" \
    || vme_contract "시나리오 '$scen'이 KSM이 낼 수 없는 타임라인을 만든다(위 목록) — 미래 타임스탬프는 첫 평가부터 소급 적용돼 전이를 건너뛴 vacuous green을 만든다(R-2)"
  vme_leg "$vm" "$VME_TMP/$scen.jsonl"
  vme_replay "$vm" "$VME_VA_VER" "$VME_RULES" "$VME_EVAL" "$VME_LOOKBACK" "$FROM_EPOCH" "$TO_EPOCH"
}

# L1~L6은 전부 "flapping이 아닌" 상태다 — 그 레그들에서 CronJobFlapping이 울면 오탐이다.
# ⚠️ 계획서가 이 커버리지를 약속했는데 초판은 KubeJobFailed만 질의했다(적대적 리뷰 R-3).
#   특히 L5(같은 ns의 두 CronJob이 각 1건)는 `count by`에서 owner_name을 빼면 두 실패가 합쳐져
#   임계에 도달한다 — 그 그룹핑 키를 잠그는 유일한 픽스처다.
assert_no_flap() { # $1=레그 이름
  local n
  n="$(vme_firing "$FLAP_ALERT")"
  if [ "$n" -eq 0 ]; then vme_pass "$1 $FLAP_ALERT 침묵(flapping 상태가 아니다)"
  else vme_fail "$1 $FLAP_ALERT 오발화 ${n}회 — 이 상태는 반복 실패가 아니다(그룹핑 키/해소 조건 회귀)"; fi
}

firing_for_job() { # $1=job_name [$2=eval time] [$3=윈도(초)] → 그 Job에 대한 firing 샘플 수
  # 시점·윈도를 주면 **구간별** 발화를 본다(전이 레그의 before/after 판정). 미지정이면 창 전체.
  vme_promql "sum(count_over_time(ALERTS{alertname=\"$ALERT\",alertstate=\"firing\",job_name=\"$1\"}[${3:-7d}${3:+s}]))" "${2:-}"
}

# ── 4) 레그 ───────────────────────────────────────────────────────────────────────────────────────

echo "── L1: 창 이전에 실패해 그대로 남은 Job은, 소유 CronJob이 계속 성공하는 한 침묵한다(라이브 adguard) ──"
run_scenario stale_resolved
n="$(firing_for_job "$JOB_CRON")"
if [ "$n" -eq 0 ]; then vme_pass "L1 $ALERT 침묵(${STALE_AGE_S}s 묵은 실패 Job + CronJob 정상 가동 — 자가 복구된 상태)"
else vme_fail "L1 해소된 실패가 발화한다 — 실패 Job **오브젝트의 존재**를 재고 있다(라이브에서 3일 연속 firing한 그 결함)"; fi
assert_no_flap L1f

echo "── L2: 창 **안에서** 발화 → 복구 → 해소를 실제로 겪는다(전이 — 상태 스냅샷이 아니라 변화를 본다) ──"
# ★ 이 레그가 release-r1 R-2의 답이다. L1은 '이미 해소된 상태'의 스냅샷만 보므로, 억제가 **해소 시점에**
#   걸리는지는 증명하지 못한다(창 밖 미래값으로도 통과해 버린다). 여기서 같은 시계열 안에 두 상태를
#   모두 넣고 경계 전후를 따로 판정한다.
run_scenario transition
before="$(firing_for_job "$JOB_CRON" "$RECOVERY_AT" "$RECOVERY_OFFSET_S")"
after="$(firing_for_job "$JOB_CRON" "$TO_EPOCH" "$AFTER_WIN_S")"
if [ "$before" -gt 0 ]; then vme_pass "L2a $ALERT 발화(복구 이전 ${RECOVERY_OFFSET_S}s 구간 — 미해소 동안은 페이징한다)"
else vme_fail "L2a 복구 이전에도 무성 — 억제가 미해소 상태까지 삼킨다(전이의 앞쪽이 죽었다)"; fi
if [ "$after" -eq 0 ]; then vme_pass "L2b $ALERT 해소(복구 이후 ${AFTER_WIN_S}s 구간 — 성공 한 번으로 조용해진다)"
else vme_fail "L2b 복구 후에도 ${after}회 발화 — 후속 성공이 알림을 해소하지 못한다(이 픽스의 본체가 동작 안 함)"; fi
assert_no_flap L2f

echo "── L3: 마지막 성공이 그 실패 **이전**이면 발화한다(억제가 진짜 고장을 삼키지 않는다) ──"
run_scenario unresolved
n="$(firing_for_job "$JOB_CRON")"
if [ "$n" -gt 0 ]; then vme_pass "L3 $ALERT 발화(마지막 성공이 실패보다 ${STALE_LEAD_S}s 앞 — 미해소)"
else vme_fail "L3 미해소 실패가 무성 — 억제가 fail-open이다(L1을 통과시키려고 알림을 죽였다)"; fi
assert_no_flap L3f

echo "── L4: CronJob 소유가 **아닌** Job은 억제 재료가 다 있어도 발화한다(owner_kind 좁힘을 잠근다) ──"
run_scenario standalone
n="$(firing_for_job "$JOB_SOLO")"
if [ "$n" -gt 0 ]; then vme_pass "L4 $ALERT 발화(owner_name은 CronJob과 같지만 owner_kind=Workflow — 필터가 억제를 막는다)"
else vme_fail "L4 비-CronJob 소유 Job이 무성 — 억제가 owner_kind 밖으로 새어 기존 백스톱을 지웠다"; fi
assert_no_flap L4f

echo "── L5: 같은 ns의 두 CronJob — 해소된 쪽만 침묵하고 미해소 쪽은 발화한다(조인 키가 job 단위) ──"
# ★ 억제가 `on (namespace)`로 뭉개지면 앞 CronJob의 최신 성공이 뒤 CronJob의 실패까지 삼킨다.
#   라이브 형태다: observability ns 하나에 CronJob 3개가 공존한다.
run_scenario two_jobs
n_res="$(firing_for_job "$JOB_CRON")"
n_unres="$(firing_for_job "$JOB_CRON2")"
if [ "$n_res" -eq 0 ]; then vme_pass "L5a 해소된 Job 침묵($JOB_CRON — 소유 CronJob이 계속 성공)"
else vme_fail "L5a 해소된 Job이 발화 — 억제가 job 단위로 걸리지 않는다"; fi
if [ "$n_unres" -gt 0 ]; then vme_pass "L5b 미해소 Job 발화($JOB_CRON2 — 같은 ns의 형제 성공에 삼켜지지 않는다)"
else vme_fail "L5b 같은 ns의 다른 CronJob 성공이 이 실패를 삼켰다 — 조인 키가 ns 단위로 뭉개졌다(fail-open)"; fi
assert_no_flap L5f

echo "── L6: 실패가 없으면 침묵(vacuity 차단 — 위 발화가 '항상 발화'가 아님) ──"
run_scenario healthy
n="$(vme_firing "$ALERT")"
if [ "$n" -eq 0 ]; then vme_pass "L6 $ALERT 침묵(실패 Job 없음)"
else vme_fail "L6 실패가 없는데 발화했다 — 위 레그가 무의미해진다"; fi
assert_no_flap L6f

echo "── L7: 교대 flapping — $FLAP_ALERT 발화 · $ALERT 는 침묵(억제가 삼키는 영역을 다른 축이 잡는다) ──"
# ★ S-6의 본체. 실패↔성공 교대에서 각 실패는 다음 성공에 억제되므로 $ALERT는 원리적으로 침묵한다.
#   그 침묵이 "정상"이 아니라 "사각지대"임을 같은 픽스처 안에서 증명한다 — 한쪽만 보면 둘 중 어느
#   룰이 일하는지 알 수 없고, $ALERT의 침묵을 오탐 해소로 오독하게 된다.
run_scenario flapping
n_flap="$(vme_firing "$FLAP_ALERT")"
n_job="$(vme_promql "sum(count_over_time(ALERTS{alertname=\"$ALERT\",alertstate=\"firing\",namespace=\"$NS\"}[7d]))")"
if [ "$n_flap" -gt 0 ]; then vme_pass "L7a $FLAP_ALERT 발화(창 내 실패 2회 — 교대 flapping)"
else vme_fail "L7a $FLAP_ALERT 무성 — 만성 flapping이 여전히 어떤 알림에도 안 잡힌다(S-6 미해결)"; fi
if [ "$n_job" -eq 0 ]; then vme_pass "L7b $ALERT 는 침묵(억제가 정상 동작 — 두 룰의 역할 분리)"
else vme_fail "L7b $ALERT 가 교대 상태에서 발화 — 억제가 안 걸렸다(#401 회귀)"; fi

echo "── L8: 창 내 실패 1회는 $FLAP_ALERT 침묵(임계가 실제로 2인지 — 단발은 이 룰 소관이 아니다) ──"
run_scenario single_failure
n="$(vme_firing "$FLAP_ALERT")"
if [ "$n" -eq 0 ]; then vme_pass "L8 $FLAP_ALERT 침묵(창 내 실패 1회 — 사고이지 패턴이 아니다)"
else vme_fail "L8 단발 실패에 $FLAP_ALERT 발화 — 임계가 2가 아니다(#401이 고친 단발 노이즈로 회귀)"; fi

echo "── L9: 창 **밖**의 오래된 실패는 세지 않는다(최근성 필터를 잠근다) ──"
run_scenario stale_failures
n="$(vme_firing "$FLAP_ALERT")"
if [ "$n" -eq 0 ]; then vme_pass "L9 $FLAP_ALERT 침묵(${FLAP_THRESHOLD}건이 전부 창 ${FLAP_WINDOW_S}s 밖 — 과거는 현재가 아니다)"
else vme_fail "L9 창 밖 오래된 실패가 발화 — 최근성 필터가 없다(#401이 고친 '과거를 현재로 알리는' 병의 재발)"; fi

echo "── L12: 교대 flapping의 **전체 수명주기**(회수 포함) — 그래도 발화해야 한다 ──"
# ★ 정적 스냅샷(L7)이 못 보는 것: 새 실패가 도착하면 컨트롤러가 가장 오래된 실패를 회수하고, 그 새
#   실패는 아직 미해소라 세어지지 않는다 → count가 임계 아래로 떨어져 pending이 리셋된다. limit이
#   임계+1이어야 그 순간에도 해소분이 임계만큼 남는다. 이 레그가 그 여유를 실측한다.
run_scenario lifecycle_flap
n="$(vme_firing "$FLAP_ALERT")"
if [ "$n" -gt 0 ]; then vme_pass "L12 $FLAP_ALERT 발화(주기 ${LIFECYCLE_PERIOD_S}s · limit ${LIFECYCLE_FAILLIMIT} — 회수가 있어도 for:를 채운다)"
else vme_fail "L12 수명주기 재생에서 무성 — 회수가 pending을 리셋한다(limit이 임계+1 미만이면 이 상태다)"; fi

echo "── L11: 같은 ns의 두 CronJob이 각각 해소된 실패 1건 — 합쳐 세면 안 된다(그룹핑 키를 잠근다) ──"
run_scenario two_cronjobs_resolved
n="$(vme_firing "$FLAP_ALERT")"
if [ "$n" -eq 0 ]; then vme_pass "L11 $FLAP_ALERT 침묵(CronJob마다 1건씩 — 임계 ${FLAP_THRESHOLD} 미만)"
else vme_fail "L11 무관한 두 CronJob의 실패가 합쳐져 발화 — count by에서 owner_name이 빠졌다(fail-open)"; fi

echo "── L10: 연속 **미해소** 실패는 KubeJobFailed만 발화한다(두 룰의 상보성 — 중복 통지 금지) ──"
run_scenario consecutive_unresolved
n_job="$(vme_promql "sum(count_over_time(ALERTS{alertname=\"$ALERT\",alertstate=\"firing\",namespace=\"$NS\"}[7d]))")"
n_flap="$(vme_firing "$FLAP_ALERT")"
if [ "$n_job" -gt 0 ]; then vme_pass "L10a $ALERT 발화(미해소 ${FLAP_THRESHOLD}건 — 지금 고장이다)"
else vme_fail "L10a 미해소 연속 실패가 무성 — KubeJobFailed가 죽었다"; fi
if [ "$n_flap" -eq 0 ]; then vme_pass "L10b $FLAP_ALERT 침묵(복구된 실행이 0건 — '자주 깨진다'가 아니라 '지금 고장'이다)"
else vme_fail "L10b 미해소 상태에 $FLAP_ALERT 도 발화 — 해소 조건이 없어 두 알림이 중복 통지된다(R-2 회귀)"; fi

[ "$VME_FAILED" -eq 0 ] || { echo "vmalert-jobfailed-firing-e2e: ${VME_FAILED}개 레그 실패" >&2; exit 1; }
echo "vmalert-jobfailed-firing-e2e OK (L1~L6(+오발화 확인)/L7~L12 전건 통과)"
