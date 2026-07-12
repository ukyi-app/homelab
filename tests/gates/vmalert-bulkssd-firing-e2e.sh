#!/usr/bin/env bash
# vmalert **발화** e2e (bulk SSD 용량) — `FilesBulkSSDLow`가 "파싱된다"가 아니라 "실제로 발화한다"를 증명한다.
#
# 버그: r4의 FilesBulkSSDLow가 `(files_data_bulk_avail_bytes / files_data_bulk_size_bytes) < 0.10`으로
# **하루 1회(04:30, 호스트 launchd)** push되는 메트릭을 **rollup 없이 맨 참조**한다. vmalert instant 질의
# 룩백은 5m이라 하루 1440분 중 **5분만** 시야에 들어온다 → 30초 간격 평가로 최대 11회 연속 참 →
# `for: 30m`(≈61회 연속 필요)에 **구조적으로 도달 불가**. 외장 bulk SSD가 꽉 차도 영원히 울리지 않는다.
# (라이브 실측: 마지막 push 후 10.8h 시점에 알림 expr → 빈 결과 / `last_over_time(...[3d])` 비율 → 0.9991.)
#
# 형제 게이트와의 관계:
#   vmalert-rules-validate.sh(-dryRun)  = expr **파싱**만 → 이 버그를 통과시킨다.
#   vmalert-drift-firing-e2e.sh         = 같은 클래스(ImageDigestDrift, 10분 push)의 회귀 가드.
#   이 게이트                            = **일 1회 push**라 갭이 훨씬 극단적인 두 번째 사례.
#
# 설계(형제 드리프트 하네스와 동일 골격 — 공용 프리미티브는 tests/gates/lib/vmalert-e2e.sh):
#  - 룰은 **배포 ConfigMap에서 매 실행 바이트 그대로 추출**(픽스처 복제 금지 → 드리프트 0). for:는 불변.
#  - 버전/평가주기/룩백/du push 주기는 **매니페스트에서 파생**(하드코딩 0). 유일한 명시 상수는 호스트
#    launchd push 주기(86400s) — launchd plist는 owner-local이라 레포에 없다(scripts/backup-files-data.sh
#    헤더: "launchd 배선(일1회, RPO=24h)은 owner-local"). 아래 HOST_PUSH_S 주석 참조.
#  - datasource URL에 `?max_lookback=<queryStep>`(라이브 instant 룩백)을 주입한다 — vmalert replay는
#    /api/v1/query_range를 쓰고 VM의 range 룩백은 **휴리스틱**이라, 보간이 일어나면 버그 룰조차 발화해
#    거짓 GREEN이 된다(형제 드리프트 하네스의 10분 push에서 실증). 그 상한을 고정하는 방어 핀이다.
#    ⚠️ **정직한 실측**: 이 하네스(일 1회 push)에선 핀 유무가 판정을 바꾸지 않는다 — VM은 24h 구멍을 애초에
#    보간하지 않고, replay가 실제로 재현하는 가시 창은 라이브(5m)보다 **더 좁다**(관측: 2 평가 ≈ step).
#    방향이 안전하다(좁을수록 발화가 어려움 → 거짓 GREEN 불가, 거짓 RED는 rollup이 룩백 무관이라 불가).
#    보간 방지의 **최종 보증은 L3**(결함 픽스처가 발화하면 FAIL)이지 이 핀이 아니다.
#  - 클러스터 접근 0(hermetic). 외부 호출은 이미지 pull뿐.
#
# 판정 레그:
#   preflight  push 주기 / 룩백 / for: 산술 단언 + rollup 윈도 불변식 (위반 = HARNESS FAULT exit 2)
#   L1 (RED 락) 배포 룰 + 여유율 5%   → FilesBulkSSDLow **발화해야** 함   (버그 상태에선 실패 = RED)
#   L2 (오발화 금지) 배포 룰 + 여유율 99% → FilesBulkSSDLow 시리즈 **없어야** 함
#   L3 (하네스 이빨) 결함 픽스처 + 5%   → **발화 부재 + pending 존재**    (버그를 실제로 감지함을 매 실행 증명)
#   L4 (하네스 생존) 같은 replay의 형제 BulkStorageLow(rollup 착용, 15%) → **발화 존재**
#      ↳ 같은 물리 매체·같은 결핍인데 rollup을 입은 쪽만 울린다 — 이 버그의 가장 선명한 대조다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK="$ROOT/platform/victoria-stack/prod"
RULES_CM="$STACK/rules/r4-storage-backup.yaml"
FIXTURES="$ROOT/tests/gates/fixtures"
GEN="$ROOT/tests/gates/vmalert-bulkssd-gen.py"
START_EPOCH="$(date +%s)"

# shellcheck source=tests/gates/lib/vmalert-e2e.sh
. "$ROOT/tests/gates/lib/vmalert-e2e.sh"

fault()    { echo "HARNESS FAULT (preflight): $*" >&2; exit 2; }
contract() { echo "CONTRACT VIOLATION (preflight): $*" >&2; exit 2; }

# ── 1) 배포 매니페스트에서 파라미터 파생 ────────────────────────────────────────────────────────────
VA_VER="$(grep -oE 'victoriametrics/vmalert:v[0-9.]+' "$STACK/vmalert.yaml" | head -1 | cut -d: -f2)"
VM_VER="$(grep -oE 'victoriametrics/victoria-metrics:v[0-9.]+' "$STACK/vmsingle.yaml" | head -1 | cut -d: -f2)"
[ -n "$VA_VER" ] && [ -n "$VM_VER" ] || fault "이미지 버전 추출 실패(vmalert/vmsingle)"

# ⚠️ `set -e`: 미지정 플래그는 grep이 1로 끝난다 → 대입이 스크립트를 죽인다. `|| true`로 기본값 분기 보존.
EVAL="$(grep -oE -- '--evaluationInterval=[0-9a-z]+' "$STACK/vmalert.yaml" | head -1 | cut -d= -f2 || true)"
[ -n "$EVAL" ] || EVAL=1m # vmalert 기본
# vmalert instant 질의의 룩백 = -datasource.queryStep (미지정 시 vmalert 기본 5m). 이게 버그의 핵심 상수다.
LOOKBACK="$(grep -oE -- '--datasource\.queryStep=[0-9a-z]+' "$STACK/vmalert.yaml" | head -1 | cut -d= -f2 || true)"
[ -n "$LOOKBACK" ] || LOOKBACK=5m # vmalert 기본

EVAL_S="$(vme_to_s "$EVAL")"
LOOKBACK_S="$(vme_to_s "$LOOKBACK")"

# ★ 호스트 push 주기 — 이 하네스에서 **매니페스트 파생이 불가능한 유일한 상수**다.
#   files_data_bulk_*의 pusher는 in-cluster CronJob이 아니라 **호스트 launchd**(app.homelab.files-backup,
#   StartCalendarInterval Hour=4 Minute=30 → 하루 1회)이고, plist는 owner-local이라 레포에 없다
#   (scripts/backup-files-data.sh 헤더가 "일1회, RPO=24h"를 계약으로 명시). 라이브 TSDB에서도 연속 샘플
#   간격 8개가 전부 86400±5초로 실측됐다. → 명시 상수 + 아래 산술 단언으로 못박는다.
#   ⚠️ 백업 주기를 바꾸면(예: 6시간마다) 이 상수와 아래 단언을 함께 갱신하라.
HOST_PUSH_S=86400

# du exporter(storage_tier_* — L4 대조군)의 push 주기는 CronJob에서 파생한다.
DU_CRON="$(yq 'select(.kind=="CronJob") | .spec.schedule' "$STACK/pvc-du-exporter.yaml" | head -1)"
# "M H * * *"(일 1회)만 지원 — 다른 형태면 L4 산술이 무너지므로 조용히 넘기지 않는다.
case "$DU_CRON" in
  [0-9]*' '[0-9]*' * * *') DU_PUSH_S=86400 ;;
  *) fault "pvc-du-exporter 크론이 일 1회('M H * * *') 형식이 아님: '$DU_CRON' — L4 대조군의 push 격자 산술을 재설계하라." ;;
esac
DU_OFFSET_S=1800 # 05:00(du) − 04:30(launchd) = +30m. 두 pusher가 독립임을 재현(레그 판정엔 무영향).

# ── 2) 배포 ConfigMap에서 룰 바이트 그대로 추출 ─────────────────────────────────────────────────────
TMP="$(mktemp -d)"
cleanup() { vme_cleanup; rm -rf "$TMP"; }
trap cleanup EXIT
vme_net_up "r4bulk-e2e-net-$$"

yq '.data["r4.yaml"]' "$RULES_CM" > "$TMP/r4-deployed.yaml"
[ -s "$TMP/r4-deployed.yaml" ] || fault "룰 추출 실패: $RULES_CM"
cp "$FIXTURES/r4-bulkssd-buggy-expr.yaml" "$TMP/r4-buggy.yaml"

# fail-closed: 하네스가 겨냥하는 룰이 실제로 존재하는지(리네임 시 무성 무측정 방지)
for want in 'alert: FilesBulkSSDLow' 'alert: BulkStorageLow' 'alert: FilesBackupStale'; do
  grep -q "$want" "$TMP/r4-deployed.yaml" || fault "배포 룰에 '$want' 부재 — 하네스가 아무것도 측정하지 않는다"
done

alert_expr() { # $1=룰 yaml $2=alert 이름 → expr만(주석 제거 — 주석이 단언을 만족시키는 것 차단)
  yq '.groups[].rules[] | select(.alert=="'"$2"'") | .expr' "$1" | sed 's/#.*//'
}
rollup_windows() { # $1=expr $2=메트릭명 → 그 메트릭에 걸린 rollup 윈도(공백 구분, 없으면 빈 문자열)
  { grep -oE "[a-z_]+_over_time[[:space:]]*\([[:space:]]*${2}[^]]*\]" <<<"$1" || true; } \
    | { grep -oE '\[[0-9]+[smhd]\]' || true; } | tr -d '[]' | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

FOR="$(yq '.groups[].rules[] | select(.alert=="FilesBulkSSDLow") | .for' "$TMP/r4-deployed.yaml" | head -1)"
FOR_S="$(vme_to_s "$FOR")"
EXPR="$(alert_expr "$TMP/r4-deployed.yaml" FilesBulkSSDLow)"
[ -n "$EXPR" ] || fault "배포 룰에서 FilesBulkSSDLow expr 추출 실패"

# ── 2b) preflight: 버그의 전제와 픽스의 불변식을 **기계가** 강제한다 ────────────────────────────────
# 위반은 룰 판정이 아니라 **전제 붕괴**다 → FAIL(exit 1)이 아니라 HARNESS FAULT/CONTRACT(exit 2).

# ① `for: 30m` 고정 — 이 하네스에서 유일하게 의도적으로 하드코딩한 룰 상수다. 페이징 임계 자체가 보존
#    계약이고(낮추면 페이징이 빨라지는 행위 변경), 아래 "도달 불가" 산술의 입력이다. 특히 for:를 5m 미만으로
#    낮추는 것은 **버그를 우회하는 가짜 픽스**(룩백 안에서 hold가 끝나버림)라 여기서 못박아 막는다.
[ "$FOR" = "30m" ] || contract "FilesBulkSSDLow for:가 30m이 아니다(현재: $FOR). 페이징 임계는 보존 계약이며, for:를 룩백(${LOOKBACK}) 아래로 낮추는 것은 rollup 없이 증상만 가리는 가짜 픽스다 — 바꾸려면 이 게이트와 계약을 함께 재설계하라."

# ② 버그의 전제: 룩백 < push 주기 → **구멍이 존재**한다. (룩백 ≥ push면 구멍이 없어 버그 자체가 없다.)
[ "$LOOKBACK_S" -lt "$HOST_PUSH_S" ] || fault "룩백($LOOKBACK) ≥ 호스트 push 주기(${HOST_PUSH_S}s) — 구멍이 생기지 않는다(버그 전제 소멸). HOST_PUSH_S와 레그 산술을 재설계하라."

# ③ 도달 불가 산술(**라이브 기준** — 이게 버그의 증명이다): push 1회당 맨 참조가 참일 수 있는 최대 연속
#    평가 횟수 vs `for:`가 요구하는 횟수. 가시 구간 = [push, push + 룩백] → 연속 평가 = floor(룩백/eval) + 1,
#    필요 = floor(for/eval) + 1.  라이브 vmalert는 instant 질의(룩백 = -datasource.queryStep)를 쓴다.
#    ⚠️ replay(query_range)가 재현하는 가시 창은 이보다 **좁다**(VM range 룩백은 휴리스틱 — 실측 2 평가).
#    방향이 안전하므로(좁을수록 발화 불가) 그대로 둔다. 이 단언은 "라이브에서 도달 불가"를 못박는 것이고,
#    레그는 "rollup을 입어야만 발화한다"를 관측으로 못박는다 — 둘은 상보적이다.
VISIBLE_EVALS=$(( LOOKBACK_S / EVAL_S + 1 ))
NEEDED_EVALS=$(( FOR_S / EVAL_S + 1 ))
[ "$VISIBLE_EVALS" -lt "$NEEDED_EVALS" ] || fault "가시 평가($VISIBLE_EVALS회) ≥ for: 요구 평가($NEEDED_EVALS회) — 맨 참조로도 hold가 성립해 버그가 재현되지 않는다(룩백/eval/for 조합 변경). 레그 산술 재설계 필요."
[ $(( FOR_S % EVAL_S )) -eq 0 ] || fault "for:($FOR)가 evaluationInterval($EVAL)의 정수배가 아님 — 발화 경계가 비결정적"

# ④ rollup 불변식(픽스 후에만 적용). rollup 부재 = **이 버그 자체**다 → 여기서 죽으면 RED 경로를 스스로
#    지우게 되므로 검사만 건너뛴다(L1이 RED로 잡는다).
#    ⚠️ 이 알림은 ratio/threshold(값=수준)라 형제 드리프트 룰의 `W < for` 제약(상태 래치)이 적용되지 않는다.
#    대신 (a) 하한: W ≥ 2×push — push 1회 누락에도 판독이 살아 있어야 한다.
#         (b) 상한: W ≤ 7×push — 매체 교체/언마운트 후 stale한 낮은 값이 무한 페이징하지 않도록 유계.
#    이 두 경계는 **관측으로 닫히지 않는다**(둘 다 L1을 통과시킨다) → 산술 단언이 전담한다.
W_AVAIL="$(rollup_windows "$EXPR" files_data_bulk_avail_bytes)"
W_SIZE="$(rollup_windows "$EXPR" files_data_bulk_size_bytes)"
if [ -z "$W_AVAIL" ] && [ -z "$W_SIZE" ]; then
  echo "[preflight] rollup: ABSENT on files_data_bulk_* → W 불변식 검사 skip (이게 버그다 — L1이 RED로 잡는다)"
elif [ -z "$W_AVAIL" ] || [ -z "$W_SIZE" ]; then
  # 한쪽만 rollup = 나눗셈이 그대로 구멍난다(부분 픽스) → 이것도 L1이 RED로 잡는 정상 경로다(FAULT 아님).
  echo "[preflight] rollup: PARTIAL (avail='${W_AVAIL:-none}' size='${W_SIZE:-none}') → 나눗셈이 여전히 구멍난다 → L1이 RED로 잡는다"
else
  case "$W_AVAIL $W_SIZE" in *' '*' '*) fault "files_data_bulk_*에 rollup 윈도가 복수(avail='$W_AVAIL' size='$W_SIZE') — 유효 윈도 판정 불가" ;; esac
  [ "$W_AVAIL" = "$W_SIZE" ] || fault "avail/size의 rollup 윈도가 다르다(avail=$W_AVAIL size=$W_SIZE) — 비대칭 윈도는 한쪽만 만료돼 나눗셈이 빈 벡터가 되는 순간을 만든다."
  W_S="$(vme_to_s "$W_AVAIL")"
  [ "$W_S" -ge $(( 2 * HOST_PUSH_S )) ] || fault "윈도 불변식 위반 (W ≥ 2×push): W=$W_AVAIL < $(( 2 * HOST_PUSH_S ))s — push 1회 누락(백업 1일 스킵)만으로 판독이 사라져 알림이 다시 죽는다."
  [ "$W_S" -le $(( 7 * HOST_PUSH_S )) ] || fault "윈도 불변식 위반 (W ≤ 7×push): W=$W_AVAIL > $(( 7 * HOST_PUSH_S ))s — 매체 교체/언마운트 후 stale한 낮은 값이 일주일 넘게 페이징한다(유계 staleness 계약)."
  echo "[preflight] W=$W_AVAIL → 2×push($(( 2 * HOST_PUSH_S ))s) ≤ W ≤ 7×push($(( 7 * HOST_PUSH_S ))s) OK"
fi

# ⑤ L4 대조군이 실제로 발화할 수 있는지 — BulkStorageLow의 rollup이 du push 주기를 덮지 못하면 대조가
#    무의미해진다(양쪽 다 침묵 → "하네스가 아무것도 못 울린다"와 구분 불가).
W_CTL="$(rollup_windows "$(alert_expr "$TMP/r4-deployed.yaml" BulkStorageLow)" 'storage_tier_avail_bytes\{tier="bulk"\}')"
[ -n "$W_CTL" ] || fault "BulkStorageLow가 storage_tier_avail_bytes{tier=\"bulk\"}에 rollup을 걸고 있지 않다 — L4 대조군이 발화하지 못해 '이 알림만 못 운다'는 대조가 성립하지 않는다."
case "$W_CTL" in *' '*) fault "BulkStorageLow의 rollup 윈도가 복수($W_CTL) — 유효 윈도 판정 불가" ;; esac
W_CTL_S="$(vme_to_s "$W_CTL")"
[ "$W_CTL_S" -ge "$DU_PUSH_S" ] || fault "BulkStorageLow의 W($W_CTL) < du push 주기(${DU_PUSH_S}s) — 대조군도 구멍나 L4가 이빨을 잃는다."

# ── 3) 시간창 — 라이브 가시성을 그대로 재현한다 ─────────────────────────────────────────────────────
# 격자(모든 오프셋은 eval(30s)의 정수배 → 평가 그리드 정렬 = 결정성):
#     ... ─── push(D-1) ─────────── 23h 무가시 ─── [ RP_FROM ──1h── push(T_LAST) ──1h── RP_TO ]
#   · replay(2h) 안에 호스트 push가 **정확히 1회** 들어간다 → 맨 참조는 그 순간부터 룩백(5m) 동안만 참
#     → 최대 11회 연속 평가 → for: 30m(61회) 도달 불가 → **firing 0 / pending >0**(버그 재현).
#   · replay 시작 시점의 직전 push 나이 = 86400 − 3600 = 82800s(23h) ≫ 룩백 → 시작부터 "가시 창 밖".
#   · rollup(≥2d)을 입은 룰은 [3d] 안에 지난 push들이 있으므로 **전 구간 연속** → RP_FROM+30m에 발화.
#   ⚠️ 그래서 백필은 반드시 **여러 날치**여야 한다(1일치만 심으면 rollup 룰도 replay 시작 시점에 데이터가
#     없어 발화 시각이 밀린다). DAYS=5 → [3d] 윈도를 항상 채운다.
DAYS=5
NOW="$(date +%s)"
T0=$(( NOW / EVAL_S * EVAL_S ))   # eval 그리드 정렬
RP_TO=$(( T0 - 600 ))             # 현재로부터 10분 여유(끝단 경계 회피)
T_LAST=$(( RP_TO - 3600 ))        # replay 창 **안**의 호스트 push(가시 5분을 재현)
RP_FROM=$(( T_LAST - 3600 ))      # push보다 1h 앞 — 직전 push(23h 전)는 이미 무가시
DATA_START=$(( T_LAST - (DAYS - 1) * HOST_PUSH_S ))
REPLAY_MIN=$(( (RP_TO - RP_FROM) / 60 ))

# 시간창 산술 preflight — 파생 파라미터가 바뀌어 레그가 무의미해지면 조용히 통과시키지 말고 즉시 실패.
[ $(( T_LAST - RP_FROM )) -gt "$LOOKBACK_S" ] || fault "replay 시작이 직전 push의 룩백 안에 있다 — '가시 창 밖' 전제가 깨진다"
[ $(( RP_TO - RP_FROM )) -gt "$FOR_S" ] || fault "replay 길이($(( RP_TO - RP_FROM ))s) ≤ for:(${FOR_S}s) — 픽스된 룰조차 발화할 시간이 없다(L1이 영구 RED)"
[ $(( T_LAST - RP_FROM )) -gt "$FOR_S" ] || fault "push 이전 구간이 for: 보다 짧다 — rollup 룰의 발화가 push 가시 구간과 뒤섞여 대조가 흐려진다"
[ $(( RP_FROM - (T_LAST - HOST_PUSH_S) )) -gt "$LOOKBACK_S" ] || fault "직전 push가 replay 시작의 룩백 안 — 맨 참조가 시작부터 보인다(전제 붕괴)"

echo "[params] vmalert=$VA_VER vmsingle=$VM_VER eval=$EVAL lookback=$LOOKBACK(queryStep) host_push=${HOST_PUSH_S}s(launchd, 명시 상수) du_push=${DU_PUSH_S}s(cron '$DU_CRON') for=$FOR"
echo "[arith]  [라이브] 맨 참조 가시 평가=${VISIBLE_EVALS}회(룩백 ${LOOKBACK_S}s / eval ${EVAL_S}s) vs for: 요구=${NEEDED_EVALS}회 → 도달 불가 (replay 재현 창은 이보다 좁다 — 안전 방향)"
echo "[window] backfill $(vme_iso "$DATA_START") .. $(vme_iso "$T_LAST") (${DAYS}일, 일 1회) | replay $(vme_iso "$RP_FROM") .. $(vme_iso "$RP_TO") (${REPLAY_MIN}m, push 1회 포함)"

# ── 4) 레그 실행기 ──────────────────────────────────────────────────────────────────────────────────
run_leg() { # $1=label $2=rules-file $3=scenario
  local label="$1" rules="$2" scenario="$3" vm="r4bulk-e2e-$1-$$"
  vme_start_vmsingle "$vm" "$VM_VER"
  python3 "$GEN" "$scenario" "$T_LAST" "$HOST_PUSH_S" "$DAYS" "$DU_PUSH_S" "$DU_OFFSET_S" > "$TMP/$label.jsonl"
  vme_import "$TMP/$label.jsonl"

  # 백필 sanity: 임포트가 조용히 비면 모든 레그가 거짓 통과한다(fail-closed).
  [ "$(vme_promql "sum(count_over_time(files_data_bulk_avail_bytes[7d]))")" -eq "$DAYS" ] \
    || fault "백필 sanity($label): files_data_bulk_avail_bytes 샘플이 ${DAYS}개가 아니다"
  [ "$(vme_promql "sum(count_over_time(storage_tier_avail_bytes{tier=\"bulk\"}[7d]))")" -eq "$DAYS" ] \
    || fault "백필 sanity($label): storage_tier_avail_bytes{tier=bulk} 샘플이 ${DAYS}개가 아니다"

  # ★ 가시성 프로브 — 라이브 실측(마지막 push 후 10.8h: 맨 참조 빈 결과 / rollup 0.9991)을 **하네스 안에서
  #   직접 재현**한다. replay 결과에 앞서 "구멍이 실재한다"를 증명하므로, 하네스가 저빈도 push를 보간하고
  #   있다면(=거짓 GREEN) 레그 판정 이전에 여기서 죽는다.
  local probe_t=$(( T_LAST + 3600 ))  # 마지막 push 후 1h = 룩백 밖
  [ "$(vme_series_count "files_data_bulk_avail_bytes" "$probe_t" "$LOOKBACK")" -eq 0 ] \
    || fault "가시성 프로브($label): 마지막 push 후 1h(룩백 $LOOKBACK 밖)인데 맨 참조가 여전히 보인다 — VM이 저빈도 push를 보간하고 있다(max_lookback 미적용 = 거짓 GREEN 위험)."
  [ "$(vme_series_count "last_over_time(files_data_bulk_avail_bytes[3d])" "$probe_t" "$LOOKBACK")" -eq 1 ] \
    || fault "가시성 프로브($label): 같은 시점에 last_over_time[3d]도 안 보인다 — 백필/시간창이 잘못됐다(데이터가 TSDB에 없다)."

  vme_replay "$vm" "$VA_VER" "$rules" "$EVAL" "$LOOKBACK" "$RP_FROM" "$RP_TO"
}

FAILED=0
fail() { echo "FAIL $*" >&2; FAILED=$(( FAILED + 1 )); }
pass() { echo "PASS $*"; }

# ── L1(RED 락) + L4(하네스 생존): 배포 룰 + 여유율 5% ───────────────────────────────────────────────
run_leg l1-low "$TMP/r4-deployed.yaml" low
F1="$(vme_firing FilesBulkSSDLow)"; P1="$(vme_pending FilesBulkSSDLow)"
F4="$(vme_firing BulkStorageLow)"
echo "  [L1] deployed rules + 5% free (threshold 10%) → FilesBulkSSDLow firing=$F1 pending=$P1"
if [ "$F1" -gt 0 ]; then
  pass "L1 FilesBulkSSDLow fired under ${REPLAY_MIN}m of 5%-free bulk SSD (firing samples=$F1)"
else
  fail "L1 FilesBulkSSDLow did not fire despite ${REPLAY_MIN} minutes of the bulk SSD sitting at 5% free (threshold 10%) — firing=0, pending=$P1 (it engages, then loses the series and resets). The rule reads the once-a-day (${HOST_PUSH_S}s) host push metric with NO rollup, so in production the series is only visible for the ${LOOKBACK} instant-query lookback after each push (${VISIBLE_EVALS} consecutive evals at ${EVAL}) while the for: ${FOR} hold needs ${NEEDED_EVALS} consecutive evals — structurally unreachable. Wrap both operands in a rollup that spans the push period (the sibling BulkStorageLow, which fired in this very same replay, wears last_over_time(...[${W_CTL}]))"
fi
echo "  [L4] deployed rules + same replay → sibling BulkStorageLow (rollup, 15%) firing=$F4"
if [ "$F4" -gt 0 ]; then
  pass "L4 harness is alive — the sibling BulkStorageLow (same physical medium, same 5% starvation, but wearing last_over_time(...[${W_CTL}])) DID fire in the very same replay (firing samples=$F4); the harness cannot fire only FilesBulkSSDLow"
else
  fail "L4 harness is DEAD — BulkStorageLow did not fire either, even though it rolls up a daily push over [${W_CTL}] and the bulk tier is at 5% free (threshold 15%); every other leg is meaningless"
fi
docker rm -f "r4bulk-e2e-l1-low-$$" >/dev/null 2>&1 || true

# ── L2(음성 대조): 배포 룰 + 여유율 99% → 오발화 금지 ──────────────────────────────────────────────
run_leg l2-healthy "$TMP/r4-deployed.yaml" healthy
S2="$(vme_alert_series FilesBulkSSDLow)"
B2="$(vme_firing BulkStorageLow)"
C2="$(vme_firing FilesBackupStale)"
echo "  [L2] deployed rules + 99% free → FilesBulkSSDLow series=$S2, BulkStorageLow firing=$B2 (control FilesBackupStale firing=$C2)"
# 이 레그의 판정은 "발화 부재"(음성)다 → vmalert가 애초에 아무것도 안 썼어도 통과해버릴 수 있다.
# 같은 그룹의 absent 가드 알림(FilesBackupStale — 생성기가 의도적으로 심지 않는 메트릭)이 같은 replay에서
# 발화했는지로 그 vacuous 통과를 막는다.
[ "$C2" -gt 0 ] || fault "L2: control alert FilesBackupStale did not fire in the healthy replay — vmalert wrote nothing, so 'FilesBulkSSDLow absent' proves nothing (vacuous pass)."
if [ "$S2" -eq 0 ] && [ "$B2" -eq 0 ]; then
  pass "L2 no false bulk-SSD page when the medium is 99% free (FilesBulkSSDLow series=0, BulkStorageLow firing=0)"
elif [ "$S2" -ne 0 ]; then
  fail "L2 FilesBulkSSDLow alert series appeared with the bulk SSD 99% free (series=$S2) — false positive; a fix must not page on a healthy medium (e.g. an absent()/or arm that trips whenever the push is merely stale)"
else
  fail "L2 sibling BulkStorageLow fired with the bulk SSD 99% free (firing=$B2) — the harness's own control is false-positive; the backfill or the tier labels are wrong"
fi
docker rm -f "r4bulk-e2e-l2-healthy-$$" >/dev/null 2>&1 || true

# ── L3(하네스 이빨): 결함 픽스처 + 5% → 발화 금지, 단 pending은 존재해야 함 ─────────────────────────
# ★ 이 레그가 **거짓 GREEN에 대한 최종 보증**이다(datasource 룩백 핀이 아니라). 하네스가 어떤 이유로든
#   저빈도 push 구멍을 보간하기 시작하면(VM staleness 휴리스틱 변화·룩백 핀 유실·백필 격자 오류) 동결된
#   맨 참조 expr이 **발화해버리고**, 그 순간 이 레그가 FAIL한다 → 룰이 안 고쳐졌는데 L1이 통과하는 사태를 막는다.
# pending>0 = "데이터가 룰에 실제로 닿았다"는 **양성** 증거 → 아무것도 안 먹인 vacuous 통과와 구분된다.
run_leg l3-buggy "$TMP/r4-buggy.yaml" low
F3="$(vme_firing FilesBulkSSDLow)"; P3="$(vme_pending FilesBulkSSDLow)"
echo "  [L3] fixtures/r4-bulkssd-buggy-expr.yaml + 5% free → firing=$F3 pending=$P3"
if [ "$F3" -eq 0 ] && [ "$P3" -gt 0 ]; then
  pass "L3 harness has teeth — the frozen bare-reference expr engages (pending=$P3) but stays stuck below for: ${FOR} forever (firing=0)"
elif [ "$F3" -gt 0 ]; then
  fail "L3 the frozen bare-reference expr FIRED (firing=$F3) — the harness is bridging the once-a-day push holes (false GREEN): a rule with NO rollup must never hold for: ${FOR}. Something is interpolating — check the ?max_lookback pin on the datasource URL (lib/vmalert-e2e.sh), VM's range-query staleness heuristic on this vmsingle version, and the backfill grid (samples must be ${HOST_PUSH_S}s apart). Until this leg is green again, L1's verdict is meaningless"
else
  fail "L3 the frozen buggy expr produced no alert state at all (pending=0) — the synthetic 5%-free push never reached the rule; the harness is measuring nothing"
fi
docker rm -f "r4bulk-e2e-l3-buggy-$$" >/dev/null 2>&1 || true

echo "[elapsed] $(( $(date +%s) - START_EPOCH ))s"
if [ "$FAILED" -gt 0 ]; then
  echo "vmalert-bulkssd-firing-e2e: ${FAILED} leg(s) FAILED" >&2
  exit 1
fi
echo "vmalert-bulkssd-firing-e2e OK (preflight + L1~L4 통과 — FilesBulkSSDLow가 실제 결핍에 발화하고, 정상 매체엔 침묵하며, 결함 expr은 여전히 못 운다)"
