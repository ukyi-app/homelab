#!/usr/bin/env bats
# Alertmanager telegram 메시지 contract 구조 게이트 (in-place v0.33).
# amtool(아래 게이트)은 message Go-template을 컴파일하지 않는다 — glyph/branch/escape 구조는
# 이 테스트만이 지킨다. v0.33 유지·단일 receiver·단일 chat_id·send_resolved 고정도 함께 검증.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2에서 [[ ]] 실패는 침묵 통과(검증된 버그).
# ⚠️ @test 이름은 영어만 — 한글이면 bats 파싱이 깨진다(검증된 버그, AGENTS.md).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  AM="$ROOT/platform/victoria-stack/prod/alertmanager.yaml"          # Deployment + Service
  AMCFG="$ROOT/platform/victoria-stack/prod/alertmanager-config/alertmanager.yml"  # 설정 본문(SSOT)
  # ⚠️ **파일 직독이지 ConfigMap 추출이 아니다.** 설정은 kustomize `configMapGenerator`가 굽는다
  #    (해시 접미 → 자동 rollout). 옛 관용구
  #    `yq 'select(.kind=="ConfigMap" …) | .data["alertmanager.yml"]' "$AM"`는 이 전환 뒤 **rc 0으로
  #    빈 문서**를 낸다 — 그래서 모든 소비 자리에 `[ -s ]`/부재-금지 앵커를 둔다. 앵커가 없으면
  #    "추출 실패 → 빈 것에 대한 참"으로 접히는 vacuous green이 이 전환의 유일한 실질 위험이다.
  [ -s "$AMCFG" ]
  MSG="$(yq '.receivers[] | select(.name == "telegram") | .telegram_configs[0].message' "$AMCFG")"
  [ -n "$MSG" ]
}

@test "image stays pinned to v0.33.0 (render-e2e verified; no blind upgrade)" {
  run grep -c 'image: prom/alertmanager:v0.33.0' "$AM"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "exactly one telegram receiver and one chat_id placeholder remain" {
  recv="$(yq '[.receivers[] | select(.name=="telegram")] | length' "$AMCFG")"
  [ "$recv" = "1" ]
  # placeholder는 설정 본문에 있다(initContainer가 sed로 치환) — 매니페스트가 아니라 AMCFG를 센다.
  run grep -c 'chat_id: __CHAT_ID__' "$AMCFG"
  [ "$output" = "1" ]
}

@test "route.routes is a closed pair: Watchdog fast-path and critical fast-repeat" {
  # round7 finding 1·3 — 두 서브라우트 모두 값 단언이 없었다. 어느 쪽을 통째로 지워도 최상위
  # 기본 receiver(telegram)가 흡수해 게이트 전건이 초록이었다(73/73·63/63 실측). length 등식으로
  # 폐집합을 잠그고 각 라우트의 필드를 등식으로 잰다.
  n="$(yq '.route.routes | length' "$AMCFG")"
  [ "$n" = "2" ]
  # Watchdog → deadmanswitch(오프노드 dead-man 백스톱 — healthchecks.io ping), 즉시 반복 + 폴백 금지.
  m="$(yq '.route.routes[0].matchers[0]' "$AMCFG")"; [ "$m" = "alertname = Watchdog" ]
  r="$(yq '.route.routes[0].receiver' "$AMCFG")"; [ "$r" = "deadmanswitch" ]
  c="$(yq '.route.routes[0].continue' "$AMCFG")"; [ "$c" = "false" ]
  gw="$(yq '.route.routes[0].group_wait' "$AMCFG")"; [ "$gw" = "0s" ]
  gi="$(yq '.route.routes[0].group_interval' "$AMCFG")"; [ "$gi" = "1m" ]
  rp="$(yq '.route.routes[0].repeat_interval' "$AMCFG")"; [ "$rp" = "1m" ]
  # severity=critical → telegram 1h 재통지(최상위 기본 4h보다 4배 빠름). 인덱스가 아니라 matchers로
  # select — Watchdog 라우트가 앞으로 재배열돼도 라우트 순서에 결합되지 않는다(위 receiver-length
  # 테스트와 같은 select 관용구).
  cr="$(yq '.route.routes[] | select(.matchers[0]=="severity = critical") | .receiver' "$AMCFG")"
  [ "$cr" = "telegram" ]
  cri="$(yq '.route.routes[] | select(.matchers[0]=="severity = critical") | .repeat_interval' "$AMCFG")"
  [ "$cri" = "1h" ]
}

@test "telegram config keeps parse_mode HTML and send_resolved true" {
  echo "$MSG" >/dev/null   # MSG must be non-empty
  [ -n "$MSG" ]
  # ⚠️ `run cat`의 status 0은 앵커가 못 된다(빈 파일도 0). 크기 앵커를 명시로 둔다.
  [ -s "$AMCFG" ]
  run cat "$AMCFG"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'parse_mode: HTML'
  printf '%s' "$output" | grep -q 'send_resolved: true'
}

@test "message uses an allowed glyph from the lexicon" {
  # allowed: 🔴(발생/실패) 🔵(해소) ⚠️(경고) ✅(성공) ⚪(취소/건너뜀)
  # ⚠️ **bash -c 보간 금지** — MSG는 큰따옴표를 담는다(실측 31개). 보간하면 그 따옴표가 인용 상태를
  #    토글해 뒤쪽이 비인용 영역에 놓이고, 명령이 재구성돼 grep이 엉뚱한 것을 센다.
  #    실측 2026-08-20: MSG 끝에 `"; id; echo "`를 담은 줄을 더하자 이 방식이 rc=1 + grep 결과가
  #    아니라 **MSG 원문 일부**를 뱉었다(here-string은 정상). 그 red는 "글리프가 없다"로 **오독**된다.
  #    지금 안전한 것은 우연이다 — 제목 분기(`{{ if eq $name "…" }}`)를 하나 더할 때마다 큰따옴표가
  #    두 개씩 늘어난다. 형제 @test(아래 "no manual escaping")가 같은 이유로 이미 here-string을 쓴다.
  run grep -Eo '🔴|🔵|⚠️|✅|⚪' <<<"$MSG"
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
  # 중간 negate는 bats가 침묵 통과 → run+status로 강제(check-bats-style.sh). MSG는 큰따옴표를
  # 포함하므로 bash -c 보간 대신 here-string(<<<)으로 원문 그대로 grep에 전달한다.
  # ⚠️ 템플릿 머리의 {{- /* … */ -}} 주석이 이 함정을 '산문'으로 문서화한다(reReplaceAll 언급) —
  #    가드는 사용처만 잡아야 하므로 Go-template 주석 블록을 벗겨낸 뒤 검사한다(구 죽은 가드가 숨겼던 오탐).
  # ⚠️ **한 줄 주석을 먼저 지운다(2단 strip).** sed 주소 범위는 시작 줄에서 끝나지 않는다 — 한 줄짜리
  #    `{{- /* … */ -}}`는 그 줄에서 범위를 열고 다음 종료 매치(없으면 EOF)까지 지운다. 실측 2026-09-03:
  #    message에 한 줄 주석 + 그 뒤 `reReplaceAll`을 더하면 1단 sed의 stripped가 3115→2697B로 붕괴해
  #    아래 두 부재 단언이 **빈 것에 대한 참**이 되고 12/12 green이었다(2단에서는 reReplaceAll 1건 → red).
  #    1단이 한 줄 주석을 그 자리에서 지워 범위가 안 열리고, 2단이 머리의 다중행 블록만 벗긴다.
  stripped="$(sed 's|{{- *//*\*.*\*/ *-}}||g' <<<"$MSG" | sed '/{{- *\/\*/,/\*\/ *-}}/d')"
  # 앵커 양성 대조 — strip이 과도해지면(미종결 `{{- /*` 등) 부재 단언이 공허해지기 전에 여기서 red.
  # 크기 하한(`[ ${#stripped} -ge 1000 ]`)은 판별력이 없다 — 붕괴 후에도 2697B가 남는다(실측).
  printf '%s' "$stripped" | grep -q 'range .Alerts'
  run grep -q 'reReplaceAll' <<<"$stripped"
  [ "$status" -ne 0 ]
  run grep -qE '\|[[:space:]]*safeHtml|safeHtml[[:space:]]+\.' <<<"$stripped"
  [ "$status" -ne 0 ]
}

@test "message ranges over .Alerts annotations" {
  printf '%s' "$MSG" | grep -q 'range .Alerts'
}

@test "the AM config is generated with a content hash, not an inline ConfigMap (auto-rollout)" {
  # ★ 이 레인이 무는 것은 "설정이 맞나"가 아니라 **"설정 변경이 실행 중 파드에 도달하나"**다.
  #   착지 전에는 평문 ConfigMap이라 도달 보장이 수동 `rollout restart` 하나뿐이었고, 그 스텝을
  #   빠뜨려 라이브 파드가 2026-08-27 렌더본을 무기한 쓰고 있었다(2026-09-03 실측).
  #   해시 접미 generator가 그 도달을 구조로 만든다 — 아래 다섯 조건 중 하나만 깨져도 되돌아간다.
  KUST="$ROOT/platform/victoria-stack/prod/kustomization.yaml"
  # ① 매니페스트에 인라인 ConfigMap이 되살아나면 red(두 SSOT가 공존하는 순간 도달이 다시 갈린다).
  run yq 'select(.kind=="ConfigMap")' "$AM"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # ② generator가 그 파일을 이름 `alertmanager-config`로 굽는다.
  n="$(yq '[.configMapGenerator[] | select(.name=="alertmanager-config")] | length' "$KUST")"
  [ "$n" = "1" ]
  f="$(yq '.configMapGenerator[] | select(.name=="alertmanager-config") | .files[0]' "$KUST")"
  [ "$f" = "alertmanager-config/alertmanager.yml" ]
  [ -s "$ROOT/platform/victoria-stack/prod/$f" ]
  # ③ 해시 접미가 이 전환의 전부다 — 끄면 옛 함정(무기한 옛 렌더본)으로 그대로 복귀한다.
  #    ⚠️ `yq -e`를 쓰면 값이 false일 때도 exit 1이라 키 부재와 구별 못 한다(함정 원장) — 평문 비교.
  hash_off="$(yq '.configMapGenerator[] | select(.name=="alertmanager-config") | .options.disableNameSuffixHash' "$KUST")"
  [ "$hash_off" = "null" ]
  # 형제 철자도 같은 효과다 — kustomize는 최상위 generatorOptions와 per-generator options 둘 다로
  # 해시를 끈다(2026-09-05 실측: 최상위 블록만 추가해도 위 두 등식은 그대로 통과했다). `//`는 쓰지
  # 않는다 — yq v4.53.3에서 키 부재는 이미 문자열 `null`을 내고, `//`는 lhs가 false일 때도 대체값을
  # 돌려줘 리터럴 false를 null로 뭉갠다(`yq -e` 금지와 같은 함정 계열).
  top_off="$(yq '.generatorOptions.disableNameSuffixHash' "$KUST")"
  [ "$top_off" = "null" ]
  # ④ Deployment volume 참조 == generator 이름. 어긋나면 kustomize nameReference가 다시 쓰지 못해
  #    파드가 **존재하지 않는 ConfigMap**을 마운트한다(렌더는 통과, 라이브는 Pending).
  v="$(yq 'select(.kind=="Deployment" and .metadata.name=="alertmanager") | .spec.template.spec.volumes[] | select(.name=="config-in") | .configMap.name' "$AM")"
  [ "$v" = "alertmanager-config" ]
  # ⑤ ConfigMap 키 = 파일 basename == initContainer가 읽는 경로.
  printf '%s' "$f" | grep -q '/alertmanager\.yml$'
  a="$(yq 'select(.kind=="Deployment" and .metadata.name=="alertmanager") | .spec.template.spec.initContainers[] | select(.name=="render-config") | .args[0]' "$AM")"
  printf '%s' "$a" | grep -q '/config-in/alertmanager\.yml'
}

@test "AM pod is annotated for vmagent scrape on the metrics port" {
  # vmagent pod-annotations job: keep on prometheus.io/scrape==true, port from prometheus.io/port
  ann="$(yq 'select(.kind=="Deployment" and .metadata.name=="alertmanager") | .spec.template.metadata.annotations' "$AM")"
  printf '%s' "$ann" | grep -q 'prometheus.io/scrape: "true"'
  printf '%s' "$ann" | grep -q 'prometheus.io/port: "9093"'
}

@test "core rules alert on telegram notification failures and document Watchdog boundary" {
  CORE="$ROOT/platform/victoria-stack/prod/rules/core.yaml"
  body="$(yq '.data["core.yaml"]' "$CORE")"
  printf '%s' "$body" | grep -q 'alert: AlertmanagerTelegramFailing'
  printf '%s' "$body" | grep -q 'alertmanager_notifications_failed_total{integration="telegram"}'
  printf '%s' "$body" | grep -q 'increase('
  # Watchdog 커버리지 경계가 문서화돼 있어야 한다 (rule 주석 또는 description)
  grep -q '자기 자신의 전송 실패는 감지하지 못한다' "$CORE"
}

@test "amtool check-config (v0.33 image) accepts the AM config (CI-safe, no KSOPS)" {
  command -v docker >/dev/null || skip "docker required for amtool gate"
  docker info >/dev/null 2>&1 || skip "docker daemon not available"
  command -v yq >/dev/null || skip "yq required"
  tmp="$(mktemp -d)"
  # 설정 본문 파일을 **직접** 읽는다 — kustomize build(KSOPS exec generator) 미경유.
  # base kustomization은 secret-generator.yaml(ksops exec, prod/alerting.enc.yaml)을 포함하므로
  # kustomize build는 CI에 없는 ksops 바이너리+age 키를 요구해 환경 사유로 실패한다(교차검증 Finding 1).
  # configMapGenerator 전환 뒤에는 그 파일이 곧 ConfigMap 값이라 추출 단계 자체가 없어졌다.
  cp "$AMCFG" "$tmp/raw.yml"
  [ -s "$tmp/raw.yml" ]
  # init sed 모사: placeholder → 더미 int64 chat_id (amtool은 chat_id를 정수로 파싱).
  sed 's/__CHAT_ID__/-1001234567890/' "$tmp/raw.yml" > "$tmp/alertmanager.yml"
  # 컨테이너의 amtool은 nobody(65534)로 실행 — mktemp -d(700)/파일을 못 읽어 permission denied
  # (CI ubuntu docker에서 발생; OrbStack은 관대). world-readable로 연다.
  chmod 755 "$tmp"; chmod 644 "$tmp/alertmanager.yml"
  run docker run --rm -v "$tmp:/cfg" --entrypoint amtool \
      prom/alertmanager:v0.33.0 check-config /cfg/alertmanager.yml
  [ "$status" -eq 0 ] || { echo "amtool exit=$status output: $output"; false; }
  printf '%s' "$output" | grep -q 'SUCCESS'
}

@test "inhibit_rules is a closed set of three rules (critical/warning, disk, unit axes only)" {
  # round7 finding 2 — 기존 3규칙에 대한 @test는 전부 존재(membership) 단언뿐이라, 전칭급 4번째
  # 규칙(예: source/target 둘 다 alertname =~ ".+", equal:[namespace])을 몰래 얹어도 기존 3개
  # grep -qF 단언이 그대로 참이라 게이트가 못 잡았다(63/63 실측). length 등식이 그 폐집합을 잠근다.
  n="$(yq '.inhibit_rules | length' "$AMCFG")"
  [ "$n" = "3" ]
}

@test "disk-scoped inhibit rule lets a critical suppress the same-disk warning" {
  [ -s "$AMCFG" ]
  am="$(cat "$AMCFG")"
  printf '%s' "$am" | grep -qF -- "equal: ['disk']"   # alertname이 다른 Bulk warning/critical을 disk로 묶어 억제
  printf '%s' "$am" | grep -q 'disk =~'             # disk 라벨 보유 알림만 한정(비-디스크 과억제 방지)
}

@test "receivers is a closed set of two: telegram and deadmanswitch (no rogue webhook)" {
  # [7라운드 c71-2] 티켓 67 「다음 라운드 입력」 — receivers 배열 전체 길이에 등식이 없었다. 3번째
  # receiver(어떤 라우트도 참조하지 않는 rogue webhook 등)를 몰래 추가해도 :28 "exactly one telegram
  # receiver" @test는 name=="telegram"만 select해 세므로 형제 원소 추가에 반응하지 않는다(무증인).
  # :36 route.routes 폐집합 등식과 동형으로 receivers 배열 자체를 length로 잠근다.
  n="$(yq '.receivers | length' "$AMCFG")"
  [ "$n" = "2" ]
  names="$(yq '.receivers[].name' "$AMCFG")"
  printf '%s' "$names" | grep -qFx 'telegram'
  printf '%s' "$names" | grep -qFx 'deadmanswitch'
}

@test "deadmanswitch receiver's webhook url matches the relay Service host:port (no silent drift)" {
  # [7라운드 c71-2] 티켓 67 「다음 라운드 입력」 — deadmanswitch-relay.yaml의 Service(9095)가 실
  # 수신처인데 AM 쪽 webhook_configs[0].url은 그 host:port를 리터럴로 박고 있어 둘을 잇는 등식이
  # 0건이었다(test_relay.bats는 relay 쪽만, 이 파일은 AM 쪽만 본다). Service 매니페스트를 SSOT로
  # 읽어 url을 대조 — 포트·서비스명이 어긋나면 healthchecks.io ping이 조용히 끊긴다(dead-man switch
  # 무력화, 관측 가능한 신호 없음).
  RELAY="$ROOT/platform/victoria-stack/prod/deadmanswitch-relay.yaml"
  [ -s "$RELAY" ]
  svc_name="$(yq 'select(.kind=="Service" and .metadata.name=="deadmanswitch-relay") | .metadata.name' "$RELAY")"
  [ "$svc_name" = "deadmanswitch-relay" ]
  svc_port="$(yq 'select(.kind=="Service" and .metadata.name=="deadmanswitch-relay") | .spec.ports[0].port' "$RELAY")"
  [ "$svc_port" = "9095" ]
  url="$(yq '.receivers[] | select(.name=="deadmanswitch") | .webhook_configs[0].url' "$AMCFG")"
  [ "$url" = "http://${svc_name}:${svc_port}/ping" ]
}
