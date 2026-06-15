#!/usr/bin/env bats
# Alertmanager telegram 메시지 contract 구조 게이트 (in-place v0.27).
# amtool(아래 게이트)은 message Go-template을 컴파일하지 않는다 — glyph/branch/escape 구조는
# 이 테스트만이 지킨다. v0.27 유지·단일 receiver·단일 chat_id·send_resolved 고정도 함께 검증.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2에서 [[ ]] 실패는 침묵 통과(검증된 버그).
# ⚠️ @test 이름은 영어만 — 한글이면 bats 파싱이 깨진다(검증된 버그, AGENTS.md).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  AM="$ROOT/platform/victoria-stack/alertmanager.yaml"
  # ⚠️ AM 파일은 멀티-도큐먼트(ConfigMap+Deployment+Service) — select로 ConfigMap만 좁힌다.
  # (안 하면 Deployment/Service에 .data가 null 도큐먼트로 섞여 카운트/추출이 깨진다.)
  MSG="$(yq 'select(.kind=="ConfigMap" and .metadata.name=="alertmanager-config") | .data["alertmanager.yml"]' "$AM" \
        | yq '.receivers[] | select(.name == "telegram") | .telegram_configs[0].message')"
}

@test "image stays pinned to v0.27.0 (no v0.28 upgrade)" {
  run grep -c 'image: prom/alertmanager:v0.27.0' "$AM"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "exactly one telegram receiver and one chat_id placeholder remain" {
  recv="$(yq 'select(.kind=="ConfigMap" and .metadata.name=="alertmanager-config") | .data["alertmanager.yml"]' "$AM" | yq '[.receivers[] | select(.name=="telegram")] | length')"
  [ "$recv" = "1" ]
  run grep -c 'chat_id: __CHAT_ID__' "$AM"
  [ "$output" = "1" ]
}

@test "telegram config keeps parse_mode HTML and send_resolved true" {
  echo "$MSG" >/dev/null   # MSG must be non-empty
  [ -n "$MSG" ]
  run yq 'select(.kind=="ConfigMap" and .metadata.name=="alertmanager-config") | .data["alertmanager.yml"]' "$AM"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'parse_mode: HTML'
  printf '%s' "$output" | grep -q 'send_resolved: true'
}

@test "message uses an allowed glyph from the lexicon" {
  # allowed: 🔴(발생/실패) 🔵(해소) ⚠️(경고) ✅(성공) ⚪(취소/건너뜀)
  run bash -c "printf '%s' \"$MSG\" | grep -Eo '🔴|🔵|⚠️|✅|⚪' | head -1"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "message branches on .Status for firing and resolved" {
  # impl은 resolved를 분기 키로 쓰고 firing은 else(발생) — .Status 분기 + 두 한글 상태가 모두 존재해야.
  printf '%s' "$MSG" | grep -q 'eq .Status "resolved"'
  printf '%s' "$MSG" | grep -q '발생'
  printf '%s' "$MSG" | grep -q '해소'
}

@test "Korean bold title is sourced from CommonLabels.alertname" {
  printf '%s' "$MSG" | grep -q '<b>'
  printf '%s' "$MSG" | grep -q '.CommonLabels.alertname'
}

@test "no manual escaping (AM auto-escapes; manual reReplaceAll or safeHtml would double-escape)" {
  # ⚠️ AM telegram은 동적 값({{ . }})을 parse_mode=HTML 컨텍스트로 자동 HTML-escape한다(render-e2e로 실측:
  #    <main> → &lt;main&gt; 한 번). 수동 reReplaceAll escape는 &amp;lt;처럼 이중 escape를 유발하므로 금지.
  #    safeHtml(escape 우회 — 'already safe' 마킹)도 금지. 실제 escape 정확성은 alertmanager-render-e2e.sh가 증명.
  # set-e 안전 negate(직접 파이프) — MSG는 큰따옴표를 포함해 bash -c 보간이 구문을 깨뜨린다.
  ! printf '%s' "$MSG" | grep -q 'reReplaceAll'
  ! printf '%s' "$MSG" | grep -qE '\|[[:space:]]*safeHtml|safeHtml[[:space:]]+\.'
}

@test "message ranges over .Alerts annotations" {
  printf '%s' "$MSG" | grep -q 'range .Alerts'
}

@test "AM pod is annotated for vmagent scrape on the metrics port" {
  # vmagent pod-annotations job: keep on prometheus.io/scrape==true, port from prometheus.io/port
  ann="$(yq 'select(.kind=="Deployment" and .metadata.name=="alertmanager") | .spec.template.metadata.annotations' "$AM")"
  printf '%s' "$ann" | grep -q 'prometheus.io/scrape: "true"'
  printf '%s' "$ann" | grep -q 'prometheus.io/port: "9093"'
}

@test "core rules alert on telegram notification failures and document Watchdog boundary" {
  CORE="$ROOT/platform/victoria-stack/rules/core.yaml"
  body="$(yq '.data["core.yaml"]' "$CORE")"
  printf '%s' "$body" | grep -q 'alert: AlertmanagerTelegramFailing'
  printf '%s' "$body" | grep -q 'alertmanager_notifications_failed_total{integration="telegram"}'
  printf '%s' "$body" | grep -q 'increase('
  # Watchdog 커버리지 경계가 문서화돼 있어야 한다 (rule 주석 또는 description)
  grep -q '자기 자신의 전송 실패는 감지하지 못한다' "$CORE"
}

@test "amtool check-config (v0.27 image) accepts the AM config (CI-safe, no KSOPS)" {
  command -v docker >/dev/null || skip "docker required for amtool gate"
  docker info >/dev/null 2>&1 || skip "docker daemon not available"
  command -v yq >/dev/null || skip "yq required"
  tmp="$(mktemp -d)"
  # 평문 ConfigMap에서 alertmanager.yml 직접 추출 — kustomize build(KSOPS exec generator) 미경유.
  # base kustomization은 secret-generator.yaml(ksops exec, prod/alerting.enc.yaml)을 포함하므로
  # kustomize build는 CI에 없는 ksops 바이너리+age 키를 요구해 환경 사유로 실패한다(교차검증 Finding 1).
  # alertmanager.yaml은 멀티-도큐먼트(ConfigMap+Deployment+Service) — ConfigMap만 선택.
  yq 'select(.kind=="ConfigMap" and .metadata.name=="alertmanager-config") | .data["alertmanager.yml"]' \
      "$ROOT/platform/victoria-stack/alertmanager.yaml" > "$tmp/raw.yml"
  [ -s "$tmp/raw.yml" ]
  # init sed 모사: placeholder → 더미 int64 chat_id (amtool은 chat_id를 정수로 파싱).
  sed 's/__CHAT_ID__/-1001234567890/' "$tmp/raw.yml" > "$tmp/alertmanager.yml"
  # 컨테이너의 amtool은 nobody(65534)로 실행 — mktemp -d(700)/파일을 못 읽어 permission denied
  # (CI ubuntu docker에서 발생; OrbStack은 관대). world-readable로 연다.
  chmod 755 "$tmp"; chmod 644 "$tmp/alertmanager.yml"
  run docker run --rm -v "$tmp:/cfg" --entrypoint amtool \
      prom/alertmanager:v0.27.0 check-config /cfg/alertmanager.yml
  [ "$status" -eq 0 ] || { echo "amtool exit=$status output: $output"; false; }
  printf '%s' "$output" | grep -q 'SUCCESS'
}
