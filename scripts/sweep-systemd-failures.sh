#!/usr/bin/env bash
# 호스트 systemd **전역** 실패 스윕 — `systemd-failed-sweep.timer`가 5분마다 부른다. 인자는 없다.
#
# 병: 실패 채널이 `OnFailure=`가 달린 유닛에만 있었다. 라이브 실측(2026-08-20): 로드된 `.service`
# 64건 중 `OnFailure=` 보유는 vendor 2건뿐이고(`systemd-fsck-root`·`dracut-shutdown`, 둘 다 부팅
# 경로 전용) 이 레포가 배선한 것은 `files-data-backup.service` 하나다. node-exporter에 systemd
# 콜렉터도 없다. 즉 `apt-daily`·`fstrim`·`logrotate`·`unattended-upgrades`가 실패해도 아무도 모른다.
#
# ★ **이벤트가 아니라 상태를 읽는다.** 짝 축(`OnFailure=` → notify-unit-failure.sh)은 실패 *순간*을
#   지연 0·critical로 잡되 그 줄이 달린 유닛만 본다. 여기는 전역을 보되 주기만큼 늦고, 한 주기 안에
#   자기해소된 실패는 원리적으로 못 본다. 둘은 대체가 아니라 직교다.
#
# 🔴 **`Restart=always` 서비스는 이 축에 원리적으로 안 잡힌다.** 라이브 실측 `k3s.service`:
#    Restart=always · RestartUSec=5s · StartLimitIntervalUSec=10s · StartLimitBurst=5 →
#    10초 창에 시도가 최대 3회라 rate limit에 **도달하지 못해** `failed`에 진입하지 않는다
#    (계속 `activating (auto-restart)`를 돈다). 그 축은 TargetDown/Watchdog/off-node deadman의
#    소관이고, systemd 축의 원리적 사각지대다. 이 스크립트의 커버 대상은 `Restart=no` 유닛이다.
#
# ★ 왜 push가 아니라 textfile collector인가: 짝 스크립트 `notify-unit-failure.sh` 머리말이 근거를
#   담는다(새 마운트·권한 0 / 신호가 스크레이프가 되어 모드 C·rollup 윈도·push 레지스트리가 무관 /
#   `node_textfile_scrape_error`가 딸려 옴).
#   ⚠️ 단, **"자기 트리거와 함께 죽지 않는다"는 저쪽 논거를 여기로 복사하지 마라 — 여기선 거짓이다.**
#      저쪽은 `(time()-ts) < 7200`이라 정전 복귀 후에도 소급 발화한다. 여기는 메모리 없는 상태
#      게이지라, 정전 중 파일에 쓴 시리즈를 복귀 후 첫 스윕(≤5분)이 덮어 지운다. 쓰기의 생존이
#      아무것도 사지 못한다. 여기서 textfile을 쓰는 이유는 위 세 줄뿐이다.
#
# 🔴 **"failed 0건"과 "스윕 미실행"의 구별이 이 스크립트의 계약이다.** textfile collector는 파일이
#    남아 있는 한 같은 값을 영원히 재발행한다 — **시리즈의 존재가 생존을 증명하지 않는다.**
#      (1) 성공할 때마다 `systemd_sweep_last_success_timestamp`를 갱신한다(신선도를 값 안에 싣는다).
#      (2) failed 0건이어도 `systemd_sweep_units_failed 0`을 **명시적으로** 쓴다.
#      (3) 열거가 붕괴하면 **아무것도 쓰지 않고 비-0으로 죽는다**(아래 3중 바닥값).
#
# 🔴 **열거는 정확히 한 번이다.** `list-units`(분모)와 `list-units --state=failed`(분자)를 따로 부르면
#    바닥값이 분모에만 걸려, 분자만 붕괴했을 때 `units_failed 0` + 신선한 하트비트 + 정상 파싱으로
#    **세 알림이 전부 무음**이 된다. `--plain --no-legend`의 3번째 컬럼이 ACTIVE이고 failed 유닛은
#    무필터 목록에 **이미 들어 있다**(2026-08-20 실측: transient 실패 유닛이 `$3=failed`로 나온다).
#    분자와 분모를 한 진실에서 뽑으면 바닥값 하나가 둘을 덮는다.
#
# ⚠️ stderr를 파싱 스트림에 섞지 않는다(`2>&1` 금지) — 에러 문구의 첫 단어가 유닛명이 되거나
#    분모를 부풀려 붕괴를 가린다.
# bash 3.2 호환(mapfile/declare -A/중간 [[ ]] 미사용) · shellcheck clean · LC_ALL=C sort.
set -euo pipefail

# 테스트 seam — 프로덕션 유닛은 이 env를 주지 않는다.
SYSTEMCTL="${SYSTEMD_SWEEP_SYSTEMCTL:-systemctl}"
DIR="${NODE_EXPORTER_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"

# ── 바닥값 3종. 전부 **소스 상수**다 — env로 낮출 수 있으면 fail-closed가 런타임에 해제된다.
# [1] 총 로드 유닛. 라이브 629(실측 2026-08-20).
SCAN_MIN=50
# [2] `.service` 유닛. 라이브 64. 🔴 **[1]이 못 잡는 비례 붕괴를 여기서 잡는다** — 총계 629의 내역은
#     mount 225 · device 116 · scope 94 · slice 52로 **487건이 kubelet/k3s 트랜지언트**라 사실상 파드
#     수의 대리 지표다(k3s 재시작만으로 수백 단위 정상 변동). `.service`는 컨테이너 런타임이 만들지
#     않아(컨테이너는 `.scope`) 호스트 서비스 수에 안정적으로 고정된다.
SERVICE_MIN=20
# [3] ACTIVE 컬럼 어휘. 단일 열거로 바꾸면서 **새로 생긴** 무성 경로를 닫는다: 출력 포맷이 밀리면
#     `$3=="failed"`가 조용히 0건이 된다. 전건 일치를 요구해 포맷 드리프트를 fail-loud로 만든다.
#     systemd가 상태를 추가하면 여기서 요란하게 죽고 한 줄 갱신으로 끝난다 — 조용한 0건보다 낫다.

[ "$#" -eq 0 ] || { echo "sweep-systemd-failures: 인자를 받지 않는다(받은 인자: $*)" >&2; exit 2; }

ERRF="$(mktemp)"
TMP=""
cleanup() { rm -f "$ERRF"; [ -z "$TMP" ] || rm -f "$TMP"; }
trap cleanup EXIT

# 🔴 열거는 여기 한 번뿐이다. 이 줄이 두 개가 되는 순간 분자·분모가 서로 다른 진실이 된다.
if ! RAW="$("$SYSTEMCTL" list-units --plain --no-legend --no-pager 2>"$ERRF")"; then
  echo "sweep-systemd-failures: systemctl list-units 실패 — $(tr '\n' ' ' < "$ERRF" | cut -c1-200)" >&2
  exit 3
fi

COUNTS="$(printf '%s\n' "$RAW" | awk '
  NF == 0 { next }
  { total++ }
  $3 ~ /^(active|reloading|inactive|failed|activating|deactivating|maintenance|refreshing)$/ { vocab++ }
  $1 ~ /\.service$/ { svc++ }
  END { printf "%d %d %d\n", total + 0, vocab + 0, svc + 0 }
')"
# shellcheck disable=SC2086  # 세 정수로의 분해가 의도다
set -- $COUNTS
SCANNED="$1"; VOCAB="$2"; SERVICES="$3"

if [ "$SCANNED" -lt "$SCAN_MIN" ]; then
  echo "sweep-systemd-failures: 로드 유닛이 ${SCANNED}건뿐이다(최소 ${SCAN_MIN}) — 열거 붕괴다. 파일을 쓰지 않는다(0건으로 위조되면 전역 축이 조용히 실명한다)" >&2
  exit 3
fi
if [ "$VOCAB" -ne "$SCANNED" ]; then
  echo "sweep-systemd-failures: ACTIVE 컬럼이 알려진 상태가 아닌 줄이 $(( SCANNED - VOCAB ))건이다(총 ${SCANNED}건) — list-units 출력 포맷이 바뀌었다. \$3 == \"failed\" 판정을 믿을 수 없으므로 쓰지 않는다" >&2
  exit 3
fi
if [ "$SERVICES" -lt "$SERVICE_MIN" ]; then
  echo "sweep-systemd-failures: .service 유닛이 ${SERVICES}건뿐이다(최소 ${SERVICE_MIN}) — 총계는 ${SCANNED}건이지만 안정 부분집합이 붕괴했다(총계는 kubelet 트랜지언트가 지배해 비례 붕괴를 가린다)" >&2
  exit 3
fi

# 분자 — **위와 같은 RAW**에서 뽑는다. type은 알림 쪽 필터의 유일한 레버다(라벨-값 allowlist를
# 생산자에 넣지 않는 이유: allowlist는 썩고, 썩은 allowlist가 진짜 실패를 삼킨다).
FAILED_ROWS="$(printf '%s\n' "$RAW" \
  | awk '$3 == "failed" { t = $1; sub(/.*\./, "", t); print $1 "\t" t }' | LC_ALL=C sort)"
FAILED="$(printf '%s\n' "$FAILED_ROWS" | awk 'NF { n++ } END { print n + 0 }')"

NOW="$(date -u +%s)"
mkdir -p "$DIR"
OUT="${DIR}/systemd-failed-sweep.prom"
# ⚠️ 원자적 쓰기(짝 스크립트와 동일 계약). tmp 이름이 `.prom.XXXXXX`라 콜렉터 글롭(`*.prom`) 밖이다.
TMP="$(mktemp "${OUT}.XXXXXX")"

{
  echo "# HELP systemd_sweep_last_success_timestamp 전역 systemd 실패 스윕이 마지막으로 성공한 시각(unix epoch)."
  echo "# TYPE systemd_sweep_last_success_timestamp gauge"
  echo "systemd_sweep_last_success_timestamp ${NOW}"
  echo "# HELP systemd_sweep_units_scanned 열거한 로드 유닛 총수(분모 ① — 대부분 kubelet 트랜지언트다)."
  echo "# TYPE systemd_sweep_units_scanned gauge"
  echo "systemd_sweep_units_scanned ${SCANNED}"
  echo "# HELP systemd_sweep_services_scanned 열거한 .service 유닛 수(분모 ② — 비례 붕괴를 잡는 안정 부분집합)."
  echo "# TYPE systemd_sweep_services_scanned gauge"
  echo "systemd_sweep_services_scanned ${SERVICES}"
  echo "# HELP systemd_sweep_units_failed 지금 failed 상태인 유닛 수(0건도 명시적으로 쓴다)."
  echo "# TYPE systemd_sweep_units_failed gauge"
  echo "systemd_sweep_units_failed ${FAILED}"
  # ⚠️ 0건이면 이 패밀리를 통째로 생략한다 — 샘플 없는 `# TYPE`만 남기면 파서 동작에 의존하게 된다.
  #    '0건'은 위 `systemd_sweep_units_failed 0`이 단독으로 진술한다.
  if [ "$FAILED" -gt 0 ]; then
    echo "# HELP systemd_sweep_unit_failed 해당 유닛이 지금 failed 상태다(값은 항상 1)."
    echo "# TYPE systemd_sweep_unit_failed gauge"
    printf '%s\n' "$FAILED_ROWS" | while IFS="$(printf '\t')" read -r u t; do
      [ -n "$u" ] || continue
      # exposition 라벨 값 이스케이프. 유닛명은 임의가 아니다 — `.device`/`.mount`는 `\x2d` 같은
      # systemd 이스케이프를 담는다(라이브: `dev-disk-by\x2ddesignator-esp.device`).
      # 짝 스크립트처럼 '거부'하면 그런 유닛의 실패가 통째로 무성이 되므로 여기서는 이스케이프한다.
      esc="$(printf '%s' "$u" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
      printf 'systemd_sweep_unit_failed{unit="%s",type="%s"} 1\n' "$esc" "$t"
    done
  fi
} > "$TMP"

# ⚠️ 0644 — node-exporter는 uid 65534(nobody)다. mktemp 기본 0600이면 조용히 못 읽는다.
chmod 0644 "$TMP"
mv -f "$TMP" "$OUT"
TMP=""
echo "sweep-systemd-failures: 유닛 ${SCANNED}건(.service ${SERVICES}건) 중 failed ${FAILED}건 → ${OUT}"
