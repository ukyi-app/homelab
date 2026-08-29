#!/usr/bin/env bash
# 컨테이너화 AM v0.33 렌더 e2e — message Go-template이 실제로 컴파일·렌더되어 계약(parse_mode=HTML,
# 글리프, <b>한국어 제목</b>, &lt; escape, → 링크)을 만족함을 사전(pre-merge) 증명한다.
# amtool은 inline message Go-template을 컴파일하지 않으므로(검증됨) 이 스크립트가 유일한 컴파일·렌더 증거다.
#
# 포터블 설계: host→AM은 `-p 127.0.0.1:<픽>:9093` 포워딩. AM→mock(host python)은
# host.docker.internal:<픽> + `--add-host host-gateway`(Linux 매핑).
# ⚠️ **이 하네스는 이제 리눅스 전용이다.** 포트 배정이 `/proc/sys/net/ipv4/ip_local_port_range`를
#    fail-closed로 요구하므로(tests/gates/lib/host-port.sh) macOS에서는 첫 배정에서 죽는다. 그것이
#    옳은 판정이다 — 이 레포의 venue는 NUC(amd64 베어메탈)와 `ubuntu-24.04-arm` 러너 둘뿐이고,
#    files 백업 실행자도 2026-08-19에 리눅스로 재작성됐다. 옛 OrbStack 수용 코드(readiness 후
#    안정화 sleep + inject 재시도)는 **레이스 흡수로서 여전히 유효**하므로 남긴다 — 다만 그 근거는
#    "macOS 포워딩"이 아니라 "기동 직후 첫 POST의 일반적 레이스"다.
#
# ⚠️ 호스트 포트 둘(AM publish · telegram mock)은 **리터럴이 아니라 배정받는다**(`lib/host-port.sh`).
#    예전엔 9093·8089를 박았는데, 그 둘이 점유돼 있을 때의 실패 모양이 서로 다르고 **둘 다 오진**이었다:
#      · mock(8089): 호출자가 `&`로 띄워 `set -euo pipefail`이 종료코드를 안 본다 → EADDRINUSE로 즉사해도
#        하네스는 진행하고 30초 뒤 "no telegram capture within timeout"으로 죽는다(진단이 템플릿을 가리킨다).
#      · AM(9093): readiness 30초를 태운 뒤 "AM not ready"(원인이 로그 어디에도 없다).
#    ⇒ 포트는 배정받고, mock은 readiness 줄을 기다리고, AM 기동은 재추첨으로 재시도한다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=tests/gates/lib/host-port.sh
. "$ROOT/tests/gates/lib/host-port.sh"

# 컨테이너 이미지는 **배포 매니페스트에서 digest까지 파생한다**(형제 skopeo-timeout-smoke와 같은 계약).
# 리터럴로 박으면 매니페스트가 올라갈 때 이 하네스만 남아, "message Go-template이 실제로 컴파일·렌더된다"는
# 유일한 증거가 **배포되지 않는 버전에 대해** 성립한다.
# ⚠️ 태그가 아니라 **digest**여야 한다. 태그는 mutable이라 상류가 재푸시하면 배포된 이미지가 아닌 다른
#    이미지를 검증하게 된다 — 이 레포는 그 시나리오를 이미 겪었다(2026-08-18 quay.io가 릴리스 태그를
#    재푸시해 핀 digest가 GC됐다. ci.yaml의 image-pin-liveness 스텝 주석이 SSOT).
#    ⚠️ "digest는 amd64 단일 매니페스트라 arm64 러너에서 pull이 안 된다"는 **거짓이다**(2026-08-21 실측:
#       핀 digest는 `manifest.list.v2+json`이고 amd64·arm64·arm/v7·ppc64le·s390x를 담는다).
# ⚠️ `[ -n … ]` 검사가 도달 가능하려면 `|| AM_IMAGE=""`가 **필요하다** — `set -o pipefail` 아래에서
#    grep 0건은 파이프라인 rc=1이라 `set -e`가 **할당 단계에서** 스크립트를 죽인다. 그러면 아래 진단은
#    영원히 실행되지 않고 CI가 메시지 0줄에 rc=1로 죽는다(이 하네스가 없애려는 그 모양이다).
AM_MANIFEST="$ROOT/platform/victoria-stack/prod/alertmanager.yaml"
AM_IMAGE="$(grep -oE 'prom/alertmanager:v[0-9.]+@sha256:[0-9a-f]{64}' "$AM_MANIFEST" | head -1)" || AM_IMAGE=""
[ -n "$AM_IMAGE" ] || {
  echo "AM 이미지 digest 파생 실패($AM_MANIFEST) — 매니페스트가 digest 핀이 아니거나 표기가 바뀌었다. 태그만으로 대신하지 마라(mutable 태그는 배포되지 않은 이미지를 검증하게 만든다)." >&2
  exit 1
}

TMP="$(mktemp -d)"
CONTAINER=am-render-e2e
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# mock 포트를 먼저 뽑는다 — 이 값은 AM config(api_url)에 굳어야 하므로 컨테이너 기동보다 앞이다.
# AM publish 포트는 `hp_run_published`가 뽑는다(재추첨이 그 안에서 일어나므로 배정 주체가 하나다).
# 배제는 그 호출에 넘긴다 — 프로브는 소켓을 즉시 닫아 아무것도 붙들지 않으므로, 배제가 없으면 AM이
# mock과 같은 포트를 받아 둘 중 하나가 EADDRINUSE로 죽는다.
MOCK_PORT="$(hp_pick_port)" || { echo "telegram mock 포트 배정 실패(위 stderr)"; exit 1; }

# 1) CI-safe config 추출(KSOPS 미경유) + 더미 chat_id + api_url→mock + group_wait 축소
yq 'select(.kind=="ConfigMap" and .metadata.name=="alertmanager-config") | .data["alertmanager.yml"]' \
   platform/victoria-stack/prod/alertmanager.yaml > "$TMP/am.yml"
sed 's/__CHAT_ID__/-1001234567890/' "$TMP/am.yml" > "$TMP/am.rendered.yml"
mv "$TMP/am.rendered.yml" "$TMP/am.yml"
yq -i "(.receivers[]|select(.name==\"telegram\").telegram_configs[].api_url)=\"http://host.docker.internal:${MOCK_PORT}\"" "$TMP/am.yml"
yq -i '.route.group_wait="0s" | .route.group_interval="1s" | .route.repeat_interval="1m"' "$TMP/am.yml"
printf '%s' 'dummy-bot-token' > "$TMP/TELEGRAM_BOT_TOKEN"
# AM 컨테이너는 nobody(65534)로 config/token을 읽는다 — mktemp -d(700)를 못 읽어 CI에서 permission denied
# (OrbStack은 관대). world-readable로 연다.
chmod 755 "$TMP"; chmod 644 "$TMP/am.yml" "$TMP/TELEGRAM_BOT_TOKEN"

# 2) mock telegram: POST body 캡처(form/json 디코드)
# ⚠️ **readiness 줄을 반드시 기다린다.** background job의 종료코드는 `set -e`가 보지 않으므로, 이 대기가
#    없으면 바인드 실패가 30초 뒤 "no telegram capture within timeout"으로 둔갑한다(형제 skopeo 스모크가
#    sink에 대해 하는 것과 같은 처방).
python3 tests/gates/mock-telegram.py "$TMP/capture.txt" "$MOCK_PORT" 2>"$TMP/mock.log" & MOCK_PID=$!
mock_ready=0
for _ in $(seq 40); do
  if grep -q 'listening' "$TMP/mock.log" 2>/dev/null; then mock_ready=1; break; fi
  kill -0 "$MOCK_PID" 2>/dev/null || break   # 이미 죽었으면 더 기다릴 이유가 없다
  sleep 0.25
done
[ "$mock_ready" = 1 ] || {
  echo "telegram mock이 기동하지 못했다(port=${MOCK_PORT}) — 아래가 그 stderr다:" >&2
  cat "$TMP/mock.log" >&2
  exit 1
}

# 3) AM 컨테이너(token 파일 마운트, host.docker.internal 매핑, publish는 루프백 한정).
# ⚠️ 기동 6불변식(`docker rm -f` 선행 · `--rm` 금지 · 실패를 메시지·종료코드로 비판별 · 서로 다른
#    포트로 재추첨 재시도 · 요청↔실제 매핑 대조 · 실패 시 `docker logs … tail -20`)은 이 하네스가
#    아니라 `hp_run_published`(tests/gates/lib/host-port.sh)가 소유한다. 예전엔 그 여섯이 여기와
#    `lib/vmalert-e2e.sh`의 `vme_start_vmsingle`에 **두 벌로** 살았고, 이 사본은 주석으로 3회
#    "형제 vme_start_vmsingle과 같은 처방·같은 판별자"라고 자백했다 — 그 자백이 곧 처방이 소비자
#    사유물로 갇혔다는 증거였다. `-p 127.0.0.1:` 접두(게이트가 LAN에 포트를 열지 않는다)도 그 안이다.
# ⇒ 여기 남는 것은 AM 고유의 명령줄과 **rc → 이 하네스의 종료 규약(exit 1)** 번역뿐이다.
#    readiness(`/-/ready` 본문 판정)는 하네스-로컬 정책이라 아래에 그대로 남는다.
AM_PORT="$(hp_run_published "$CONTAINER" 9093 "$MOCK_PORT" \
    --add-host=host.docker.internal:host-gateway \
    -v "$TMP/am.yml:/etc/alertmanager/alertmanager.yml:ro" \
    -v "$TMP/TELEGRAM_BOT_TOKEN:/etc/alertmanager/secrets/TELEGRAM_BOT_TOKEN:ro" \
    "$AM_IMAGE" \
      --config.file=/etc/alertmanager/alertmanager.yml \
      --cluster.listen-address=)" || {
  echo "AM 기동 실패 — 위 host-port stderr가 원인이다(포트 경합이면 재추첨 로그가, 설정 회귀면 컨테이너 로그가 그 위에 있다)." >&2
  exit 1
}
BASE="http://127.0.0.1:${AM_PORT}"

# 4) readiness 대기
# ⚠️ 2xx 여부가 아니라 **본문**을 본다. AM의 `/-/ready`는 `OK`를 준다(실측 v0.33.0). 본문이 비면 아직
#    안 뜬 것이고, 본문이 있는데 `OK`가 아니면 이 호스트 포트가 **우리 컨테이너로 가지 않는다**는 뜻이다.
#    밴드가 NodePort와 겹치면 정확히 이 모양이 된다 — `docker run`도 `docker port` 대조도 통과하는데
#    curl만 남의 서비스(Traefik의 `404 page not found`)를 받는다. 그 상태를 30초 태운 뒤 "not ready"로
#    죽는 것이 예전의 오진이었다(형제 `vme_start_vmsingle`과 같은 판별자).
ready=0
for _ in $(seq 60); do
  rbody="$(curl -s --max-time 3 "$BASE/-/ready" 2>/dev/null || true)"
  case "$rbody" in
    OK*) ready=1; break ;;
    '') ;;
    *)
      echo "${BASE}/-/ready가 Alertmanager가 아닌 응답을 냈다 — 이 호스트 포트가 다른 서비스로 라우팅된다(NodePort DNAT 등). 본문: ${rbody}" >&2
      exit 1 ;;
  esac
  sleep 0.5
done
[ "$ready" = "1" ] || { echo "AM not ready"; docker logs "$CONTAINER" 2>&1 | tail -20; exit 1; }
sleep 2   # readiness 직후 첫 POST reset 레이스 흡수

inject() { # $1=fixture — 기동 직후 레이스 대비 재시도(best-effort)
  for _ in 1 2 3 4 5 6 7 8; do
    curl -fsS -X POST "$BASE/api/v2/alerts" -H 'content-type: application/json' --data-binary @"$1" && return 0
    sleep 1
  done
  echo "inject failed after retries: $1"; docker logs "$CONTAINER" 2>&1 | tail -20; return 1
}
wait_capture() { # capture.txt가 채워질 때까지(최대 30s)
  for _ in $(seq 60); do [ -s "$TMP/capture.txt" ] && return 0; sleep 0.5; done
  echo "no telegram capture within timeout"; docker logs "$CONTAINER" 2>&1 | tail -20; return 1
}

# 5) firing 주입 + 계약 단언
: > "$TMP/capture.txt"
inject tests/gates/fixtures/alerts-firing.json
wait_capture
body="$(cat "$TMP/capture.txt")"
grep -q 'parse_mode=HTML'        <<<"$body"
grep -q '<b>파드 OOM 종료</b>'      <<<"$body"   # ⚠️ 제목 자체가 한국어여야(매핑된 제목)
# 일반화: bold 제목 안에 non-ASCII(한글). [가-힣] 범위는 CI 로케일(C)에서 invalid collation —
# LC_ALL=C + 비-ASCII 바이트 클래스([^ -~])로 견고하게(literal 한글 grep은 로케일 무관).
LC_ALL=C grep -qE '<b>[^<]*[^ -~][^<]*</b>' <<<"$body"
grep -q '🔴'                       <<<"$body"   # critical 글리프
grep -q '&lt;main&gt;'            <<<"$body"   # escaping 한 번(자동) — raw <main> 금지, 이중 &amp;lt; 금지
# 부정 단언: set -e에서 `! grep`은 errexit를 우회해 unwanted 패턴이 있어도 통과한다(검증된 함정) —
# 명시적 `grep && exit 1`로 실제로 실패시킨다.
grep -q '<main>'   <<<"$body" && { echo "FAIL: raw <main> 태그 잔존(escape 안 됨)" >&2; exit 1; }
grep -q '&amp;lt;' <<<"$body" && { echo "FAIL: 이중 escape(&amp;lt;) 발생" >&2; exit 1; }
grep -q '메모리'                   <<<"$body"   # 한국어 본문
grep -q '→ https://home.example/runbook/oom' <<<"$body"  # 링크

# 6) 미매핑 alertname → summary가 한국어 제목으로 렌더되는지
: > "$TMP/capture.txt"
inject tests/gates/fixtures/alerts-unmapped.json
wait_capture
body2="$(cat "$TMP/capture.txt")"
grep -q '<b>텔레그램 스모크 테스트</b>' <<<"$body2"   # 미매핑 → summary가 제목으로
grep -q '⚠️'                          <<<"$body2"   # warning 글리프

# 7) resolved 경로(send_resolved:true) — 🔵 해소로 렌더되는지
: > "$TMP/capture.txt"
inject tests/gates/fixtures/alerts-resolved.json
wait_capture
body3="$(cat "$TMP/capture.txt")"
grep -q '🔵' <<<"$body3"
grep -q '해소' <<<"$body3"

echo "render-e2e OK"
