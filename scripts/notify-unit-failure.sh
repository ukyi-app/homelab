#!/usr/bin/env bash
# systemd 유닛 실패의 **즉시 신호** — `OnFailure=unit-failure-notify@%n.service`가 부른다.
# 직접 실행하지 않는다(인자 = 실패한 유닛 이름, systemd가 `%i`로 채운다).
#
# 병: 호스트 oneshot이 실패해도 **울 채널이 0개**였다. `OnFailure=`가 레포 유닛에 하나도 없었고
# node-exporter에 systemd 콜렉터도 없다(라이브 /metrics 2670줄 중 `node_systemd*` 0줄). 남는 신호는
# 신선도 알림뿐인데 **신선도는 원리적으로 주기보다 빨리 울 수 없다** — 배수를 조여도 하한이 1주기다.
# 즉 "1회 실패"를 즉시 관측하는 축이 통째로 없었다.
#
# ★ 왜 push가 아니라 **textfile collector**인가(이 선택이 이 파일의 형태를 전부 결정한다):
#   · node-exporter가 이미 `/`를 `/host/root`에 readOnly로 마운트한다 → **새 마운트도 새 권한도 없다.**
#   · 신호가 push가 아니라 **스크레이프**가 된다 ⇒ 모드 C(push 주기 > instant 룩백)·rollup 윈도·
#     push 생산자 레지스트리·exposition 페이로드 계약이 **전부 무관**해진다. 파일이 있는 한
#     node-exporter가 매 스크레이프마다 같은 시계열을 다시 낸다 — 구멍이 없으니 rollup도 필요 없다.
#   · 무엇보다 **자기 트리거와 함께 죽지 않는다.** vmsingle로 push하려면 kubectl port-forward가
#     필요한데, `backup-files-data.sh`가 `command -v kubectl` 부재를 exit 2로 다루듯 **kubectl/k3s
#     불가가 이 유닛이 실패하는 가장 개연성 높은 원인**이다. 그 경우 통지 경로도 같이 죽어 페이지가
#     0이 된다. 파일 쓰기는 그 상관 고장에서 살아남는다.
#   · 덤으로 `node_textfile_scrape_error`가 무결성 신호로 딸려 온다.
#
# ⚠️ **원자적 쓰기가 계약이다.** textfile collector는 매 스크레이프마다 디렉토리를 읽으므로, 부분
#    기록된 파일을 읽으면 파싱 실패로 `node_textfile_scrape_error 1`이 된다. 같은 파일시스템 안에서
#    임시 파일에 쓰고 `mv`(rename(2) = 원자적)로 갈아끼운다. 업스트림 문서가 명시하는 규약이다.
# ⚠️ 파일은 **지워지지 않는다.** 유닛이 나중에 성공해도 값(실패 시각)은 그대로 남고, 알림이
#    `time() - 값 < 임계`로 판정하므로 시간이 지나면 스스로 해소된다. 파일이 남는 것은 의도다 —
#    지우는 주체를 두면 그 주체의 실패가 새로운 무성 경로가 된다.
set -euo pipefail

UNIT="${1:-}"
[ -n "$UNIT" ] || { echo "notify-unit-failure: 유닛 이름 인자가 없다(systemd가 %i로 채운다)" >&2; exit 2; }
# systemd `%i`는 인스턴스 이름이고 `%n`으로 채우면 `foo.service` 형태다. 라벨 값으로 그대로 쓴다.
# 라벨 인젝션 차단 — exposition 포맷에서 `"`·`\`·개행이 값을 깨뜨린다.
case "$UNIT" in
  *[!A-Za-z0-9._@-]*) echo "notify-unit-failure: 유닛 이름에 허용되지 않는 문자가 있다: $UNIT" >&2; exit 2 ;;
esac

DIR="${NODE_EXPORTER_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
mkdir -p "$DIR"
OUT="$DIR/unit-failure-${UNIT}.prom"
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

{
  echo "# HELP systemd_unit_last_failure_timestamp systemd 유닛이 마지막으로 실패한 시각(unix epoch)."
  echo "# TYPE systemd_unit_last_failure_timestamp gauge"
  echo "systemd_unit_last_failure_timestamp{unit=\"${UNIT}\"} $(date -u +%s)"
} > "$TMP"

# ⚠️ 0644 — node-exporter는 uid 65534(nobody)로 돌므로 root가 쓴 파일을 **읽을 수 있어야** 한다.
#    mktemp의 기본 0600을 그대로 두면 스크레이프가 조용히 실패한다.
chmod 0644 "$TMP"
mv -f "$TMP" "$OUT"
trap - EXIT
echo "notify-unit-failure: ${UNIT} 실패를 기록했다 → ${OUT}"
