#!/usr/bin/env bash
# 컨테이너화 AM v0.27 렌더 e2e — message Go-template이 실제로 컴파일·렌더되어 계약(parse_mode=HTML,
# 글리프, <b>한국어 제목</b>, &lt; escape, → 링크)을 만족함을 사전(pre-merge) 증명한다.
# amtool은 inline message Go-template을 컴파일하지 않으므로(검증됨) 이 스크립트가 유일한 컴파일·렌더 증거다.
#
# 포터블 설계: host→AM은 -p 9093 포워딩 + 127.0.0.1(CI ubuntu 표준). OrbStack은 readiness 직후 포워딩이
# 잠깐 불안정해 첫 POST가 reset될 수 있어 readiness 후 안정화 sleep + inject 재시도로 흡수한다.
# (컨테이너 IP는 OrbStack VM 내부망이라 macOS에서 직접 라우팅 안 됨 — AGENTS.md.) AM→mock(host python)은
# host.docker.internal:8089 + --add-host host-gateway(Linux 매핑; macOS/OrbStack은 기본 제공).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d)"
cleanup() {
  docker rm -f am-render-e2e >/dev/null 2>&1 || true
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# 1) CI-safe config 추출(KSOPS 미경유) + 더미 chat_id + api_url→mock + group_wait 축소
yq 'select(.kind=="ConfigMap" and .metadata.name=="alertmanager-config") | .data["alertmanager.yml"]' \
   platform/victoria-stack/alertmanager.yaml > "$TMP/am.yml"
sed 's/__CHAT_ID__/-1001234567890/' "$TMP/am.yml" > "$TMP/am.rendered.yml"
mv "$TMP/am.rendered.yml" "$TMP/am.yml"
yq -i '(.receivers[]|select(.name=="telegram").telegram_configs[].api_url)="http://host.docker.internal:8089"' "$TMP/am.yml"
yq -i '.route.group_wait="0s" | .route.group_interval="1s" | .route.repeat_interval="1m"' "$TMP/am.yml"
printf '%s' 'dummy-bot-token' > "$TMP/TELEGRAM_BOT_TOKEN"
# AM 컨테이너는 nobody(65534)로 config/token을 읽는다 — mktemp -d(700)를 못 읽어 CI에서 permission denied
# (OrbStack은 관대). world-readable로 연다.
chmod 755 "$TMP"; chmod 644 "$TMP/am.yml" "$TMP/TELEGRAM_BOT_TOKEN"

# 2) mock telegram: POST body 캡처(form/json 디코드)
python3 tests/gates/mock-telegram.py "$TMP/capture.txt" 8089 & MOCK_PID=$!

# 3) AM 컨테이너(token 파일 마운트, host.docker.internal 매핑, 9093 publish).
docker run -d --rm --name am-render-e2e \
  --add-host=host.docker.internal:host-gateway \
  -p 9093:9093 \
  -v "$TMP/am.yml:/etc/alertmanager/alertmanager.yml:ro" \
  -v "$TMP/TELEGRAM_BOT_TOKEN:/etc/alertmanager/secrets/TELEGRAM_BOT_TOKEN:ro" \
  prom/alertmanager:v0.27.0 \
    --config.file=/etc/alertmanager/alertmanager.yml \
    --cluster.listen-address= >/dev/null
BASE="http://127.0.0.1:9093"

# 4) readiness 대기
ready=0
for _ in $(seq 60); do
  if curl -fsS "$BASE/-/ready" >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.5
done
[ "$ready" = "1" ] || { echo "AM not ready"; docker logs am-render-e2e 2>&1 | tail -20; exit 1; }
sleep 2   # OrbStack 포워딩 안정화(readiness 직후 첫 POST reset 레이스 흡수)

inject() { # $1=fixture — 포워딩 레이스 대비 재시도(best-effort)
  for _ in 1 2 3 4 5 6 7 8; do
    curl -fsS -X POST "$BASE/api/v2/alerts" -H 'content-type: application/json' --data-binary @"$1" && return 0
    sleep 1
  done
  echo "inject failed after retries: $1"; docker logs am-render-e2e 2>&1 | tail -20; return 1
}
wait_capture() { # capture.txt가 채워질 때까지(최대 30s)
  for _ in $(seq 60); do [ -s "$TMP/capture.txt" ] && return 0; sleep 0.5; done
  echo "no telegram capture within timeout"; docker logs am-render-e2e 2>&1 | tail -20; return 1
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
