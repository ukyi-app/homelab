#!/usr/bin/env bats
# vmalert 룰 expr 정적 lint 가드 — 세 모드 전부 "문법은 유효한데 eval-time에 죽는" 결함을 겨냥한다.
#   모드 A/B: instance-라벨 불안정 (PR #327 포스트모템 — 재부팅 IP churn 오탐 4회 재발).
#   모드 C:   push 주기 > vmalert instant 룩백(5m) 메트릭의 맨 참조 (PR #339/#341 — 죽은 알림 2건,
#             라이브 60일 발화 0). 동결 결함 픽스처 2개가 회귀 앵커다.
# required 게이트인 `vmalert -dryRun`은 문법만 본다 → 세 모드(eval-time 의미)를 원리적으로 못 잡는다.
# 라이브 eval 게이트도 무력하다(A/B는 재부팅 과도구간에서만 발현, C는 "아무 신호도 없음"이 증상) →
# 유일하게 CI에서 잡을 수 있는 형태는 expr 안티패턴의 정적 lint다. @test 이름은 영어(CJK 함정).
# CI-safe(소스 스캔, bun/TS 단일) → run-bats.sh gate 도메인에 자동 수집.

# scan-floor(30) 통과용 정상 룰 30건 + 선택적 프로브 룰 1건을 담은 룰 ConfigMap을 시드한다.
# **생산자·레지스트리도 함께 시드**한다 — 린터는 레지스트리의 생산자 파일이 실재하고, 그 파일이 선언된
# 메트릭을 실제로 push하며, cron 스케줄 파일이 존재할 것을 강제한다(fail-open 4구멍 중 F-3·F-4).
# 프로덕션 레지스트리를 약화시키지 않으려고 테스트는 **--registry로 픽스처를 주입**해 격리한다.
_seed() {
  local root="$1" name="${2:-}" expr="${3:-}" i
  mkdir -p "$root/platform/victoria-stack/prod/rules" "$root/platform/fake/prod" "$root/scripts" "$root/policy"
  : > "$root/policy/alert-instance-stability-allowlist.txt"
  echo 'kube_pod_container_status_restarts_total   # 테스트 시드' \
    > "$root/policy/alert-instance-stability-denylist.txt"

  # 생산자 픽스처 ①: 10분 크론 CronJob이 ghcr_latest_digest를 push(실 digest-exporter와 동형).
  cat > "$root/platform/fake/prod/digest-exporter.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata: { name: fake-digest-exporter-script }
data:
  run.sh: |
    #!/bin/sh
    OUT="${OUT}ghcr_latest_digest{app=\"$APP\",digest=\"$DIGEST\"} 1\n"
    printf "%b" "$OUT" | curl -fsS --data-binary @- 'http://vmsingle:8428/api/v1/import/prometheus'
---
apiVersion: batch/v1
kind: CronJob
metadata: { name: fake-digest-exporter }
spec:
  schedule: "*/10 * * * *"
  jobTemplate: { spec: { template: { spec: { containers: [] } } } }
YAML
  # 생산자 픽스처 ②: 레포 밖(launchd) 일 1회 — files_* 3종을 push(실 backup-files-data.sh와 동형).
  cat > "$root/scripts/fake-files-backup.sh" <<'SH'
#!/usr/bin/env bash
printf 'files_backup_last_success_timestamp %s\nfiles_data_bulk_avail_bytes %s\nfiles_data_bulk_size_bytes %s\n' \
  "$(date -u +%s)" "${avail:-0}" "${size:-0}" \
  | curl -fsS --data-binary @- "${url}/api/v1/import/prometheus"
SH
  cat > "$root/registry.json" <<'JSON'
[
  { "metric": "ghcr_latest_digest", "producer": "platform/fake/prod/digest-exporter.yaml",
    "schedule": { "kind": "cron", "file": "platform/fake/prod/digest-exporter.yaml" } },
  { "metric": "files_backup_last_success_timestamp", "producer": "scripts/fake-files-backup.sh",
    "schedule": { "kind": "external", "periodSec": 86400, "why": "테스트 픽스처 — 호스트 launchd 일 1회" } },
  { "metric": "files_data_bulk_avail_bytes", "producer": "scripts/fake-files-backup.sh",
    "schedule": { "kind": "external", "periodSec": 86400, "why": "테스트 픽스처 — 호스트 launchd 일 1회" } },
  { "metric": "files_data_bulk_size_bytes", "producer": "scripts/fake-files-backup.sh",
    "schedule": { "kind": "external", "periodSec": 86400, "why": "테스트 픽스처 — 호스트 launchd 일 1회" } }
]
JSON

  {
    echo "apiVersion: v1"
    echo "kind: ConfigMap"
    echo "metadata: { name: vmalert-rules-probe }"
    echo "data:"
    echo "  probe.yaml: |"
    echo "    groups:"
    echo "      - name: probe"
    echo "        rules:"
    for i in $(seq 1 30); do
      echo "          - alert: ok$i"
      echo "            expr: up == 0"
    done
    if [ -n "$name" ]; then
      echo "          - alert: $name"
      echo "            expr: '$expr'"
    fi
  } > "$root/platform/victoria-stack/prod/rules/probe.yaml"
}

_lint() {   # $1=root — 픽스처 레지스트리를 주입해 린터 실행
  run bun "${BATS_TEST_DIRNAME}/../tools/check-alert-rules.ts" --repo-root "$1" --registry "$1/registry.json"
  echo "$output"
}

_run_probe() {   # $1=alert명 $2=expr → run 결과를 호출자가 판정
  tmp="$(mktemp -d)"
  _seed "$tmp" "$1" "$2"
  _lint "$tmp"
}

# 동결 결함 픽스처(tests/gates/fixtures/*.yaml — 실제 역사적 버그의 expr 스냅샷)를 **무수정**으로
# 룰 ConfigMap에 감싸 시드한다. 픽스처는 raw `groups:` 문서라 그대로는 린터 대상(ConfigMap)이 아니다 →
# 블록 스칼라로 들여쓰기만 해서 감싼다(파일 자체는 손대지 않는다 — 하네스의 음성 기준선이므로).
_seed_frozen_fixture() {   # $1=root $2=픽스처 경로
  {
    echo "apiVersion: v1"
    echo "kind: ConfigMap"
    echo "metadata: { name: vmalert-rules-frozen-fixture }"
    echo "data:"
    echo "  fixture.yaml: |"
    sed 's/^/    /' "$2"
  } > "$1/platform/victoria-stack/prod/rules/zz-frozen-fixture.yaml"
}

@test "alert-rule guard passes on the real repository rules" {
  run bun "${BATS_TEST_DIRNAME}/../tools/check-alert-rules.ts" --repo-root "${BATS_TEST_DIRNAME}/.."
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '모드 A/B/C 위반 0'   # 세 모드 전부 실행됐다는 증거(모드 침묵 스킵 차단)
}

# ── 모드 A: rollup이 상태-파생(비-리셋) 카운터를 감쌀 때 instance 제거를 강제 ──

@test "mode A flags a raw rollup over a state-derived counter (red-green)" {
  _run_probe PodCrashLoopingProbe 'increase(kube_pod_container_status_restarts_total[15m]) > 3'
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[모드 A:'
}

@test "mode A accepts a subquery that strips instance before the rollup" {
  _run_probe PodCrashLoopingProbe 'increase(max by (namespace,pod,container,uid) (kube_pod_container_status_restarts_total)[15m:1m]) > 3'
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "mode A flags a by() list that still carries instance" {
  _run_probe PodCrashLoopingProbe 'increase(max by (namespace,pod,instance) (kube_pod_container_status_restarts_total)[15m:1m]) > 3'
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'instance가 남아'
}

@test "mode A accepts without(instance) as an instance-stripping aggregation" {
  _run_probe PodCrashLoopingProbe 'increase(max without (instance) (kube_pod_container_status_restarts_total)[15m:1m]) > 3'
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "mode A flags an aggregation with no subquery window" {
  _run_probe PodCrashLoopingProbe 'increase(max by (namespace,pod) (kube_pod_container_status_restarts_total)) > 3'
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '서브쿼리'
}

@test "mode A ignores process-local counters that reset on exporter restart" {
  # alertmanager_*/vmagent_*/vmalert_* 는 denylist 밖 — 재시작 시 0 리셋이라 phantom 증가분이 없다.
  _run_probe VmalertUnhealthyProbe 'increase(vmalert_alerts_send_errors_total[15m]) > 0'
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

# ── 모드 B: 산술 이항 + on()/ignoring() 조인의 피연산자에 사전 집계를 강제 ──

@test "mode B flags an arithmetic on() join over raw selectors (red-green)" {
  _run_probe WALVolumeFillingProbe '(cnpg_collector_pg_wal{value="size"} / on(namespace, pod) cnpg_collector_pg_wal{value="volume_size"}) > 0.70'
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[모드 B:'
}

@test "mode B accepts an arithmetic on() join whose operands are pre-aggregated" {
  _run_probe WALVolumeFillingProbe '(max by (namespace, pod) (cnpg_collector_pg_wal{value="size"}) / on(namespace, pod) max by (namespace, pod) (cnpg_collector_pg_wal{value="volume_size"})) > 0.70'
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "mode B does not flag set operators (and/or/unless never raise 422)" {
  _run_probe PodOOMKilledProbe 'up == 0 and on(namespace,pod) kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1'
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "mode B flags a one-sided raw selector in an ignoring() arithmetic join" {
  _run_probe RatioProbe '(max by (namespace) (a_metric) / ignoring(instance) b_metric) > 0.5'
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '우변'
}

# ── 모드 C: push 주기 > instant 룩백(300s)인 메트릭은 윈도 ≥ 주기인 rollup 필수 ──

@test "mode C flags the frozen r6 buggy fixture (real historical bug: ImageDigestDrift)" {
  # 회귀 앵커 ①: PR #339 이전에 실제로 배포돼 있던 r6 record expr(동결 픽스처, 자구 그대로).
  # push 메트릭 ghcr_latest_digest(10분 주기)를 rollup 없이 맨 참조 → 라이브 60일 발화 0.
  tmp="$(mktemp -d)"
  _seed "$tmp"
  _seed_frozen_fixture "$tmp" "${BATS_TEST_DIRNAME}/gates/fixtures/r6-buggy-expr.yaml"
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[모드 C:'
  echo "$output" | grep -q 'ghcr_latest_digest'
  # record 체인 dedup: 결함은 record 1건 — 그 record를 참조하는 alert(ImageDigestDrift)는 이중 계산 금지.
  [ "$(echo "$output" | grep -c '\[모드 C:')" -eq 1 ]
}

@test "mode C flags the frozen r4 bulkssd buggy fixture (real historical bug: FilesBulkSSDLow)" {
  # 회귀 앵커 ②: PR #341 이전의 r4 alert expr(동결 픽스처). files_data_bulk_*(하루 1회 push)를 맨 참조.
  tmp="$(mktemp -d)"
  _seed "$tmp"
  _seed_frozen_fixture "$tmp" "${BATS_TEST_DIRNAME}/gates/fixtures/r4-bulkssd-buggy-expr.yaml"
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[모드 C:'
  echo "$output" | grep -q 'files_data_bulk_avail_bytes'
}

@test "mode C accepts the shipped ImageDigestDrift fix (W=15m over a 10m push — under 2x, still valid)" {
  # 과잉 검출 방지 앵커: 하한은 W ≥ 주기(보편 참)다. 누락 내성(2×)을 강제하면 방금 머지한 픽스가
  # FAIL한다 — W=15m은 `for: 20m` 상한(W < for) 때문에 강제된 선택이다(윈도 상한은 e2e preflight 소관).
  _run_probe ImageDigestDriftProbe 'max by (app, digest) (last_over_time(ghcr_latest_digest[15m])) == 1'
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "mode C flags a rollup window narrower than the push period" {
  # files_data_bulk_avail_bytes = 86400s 주기 → [1h](3600s) 윈도는 하루의 대부분에서 시리즈가 비어 무발화.
  _run_probe FilesBulkSSDLowProbe 'last_over_time(files_data_bulk_avail_bytes[1h]) / last_over_time(files_data_bulk_size_bytes[3d]) < 0.10'
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[모드 C:'
  echo "$output" | grep -q '1h'
}

@test "mode C accepts a subquery window at least as wide as the push period" {
  _run_probe ImageDigestDriftProbe 'last_over_time(max by (app, digest) (ghcr_latest_digest)[15m:1m]) == 1'
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "mode C ignores scrape metrics (only push producers carry the lookback mismatch)" {
  # 스크레이프 메트릭(30s 간격)은 룩백 안에 항상 샘플이 있다 → rollup 강제 대상 아님.
  _run_probe ArgoCDOutOfSyncProbe 'argocd_app_info{sync_status="OutOfSync"} == 1 or absent(argocd_app_info)'
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

# ── S-1: rollup 윈도 귀속은 메트릭을 **실제로 감싸는** 서브쿼리여야 한다(형제 윈도로 우회/오검출 금지) ──

@test "mode C S-1 flags a decoy-window dead alert (sibling [1h:1m] but the wrapping window is [1m:10s])" {
  # 실제로 ghcr를 감싸는 윈도는 [1m:10s](60s < 600s → 죽음)인데, 형제 서브쿼리 [1h:1m]을 보고 통과했었다.
  _run_probe DecoyWindowProbe 'last_over_time(( max by (app) (last_over_time(kube_pod_container_info{namespace="prod"}[1h:1m])) and on (app) ghcr_latest_digest )[1m:10s]) > 0'
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[모드 C:'
  echo "$output" | grep -q '1m'
}

@test "mode C S-1 does not over-flag when the wrapping window is valid but a sibling is small" {
  # 실제로 ghcr를 감싸는 윈도는 정당한 [15m:1m], 형제(딴 메트릭)의 [1m:10s]은 무관 → 오검출 0.
  _run_probe ValidWrapProbe 'last_over_time(( max by (app) (last_over_time(kube_pod_container_info{namespace="prod"}[1m:10s])) and on (app) ghcr_latest_digest )[15m:1m]) > 0'
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

# ── 모드 C가 fail-open으로 뚫렸던 4구멍(적대 검증에서 실증) — 동결 회귀 프로브 ──

@test "mode C F-1 flags a push metric hidden in a __name__ equality selector" {
  # 리터럴 토큰 스캔은 `{__name__="m"}`을 못 본다(이름이 문자열 안) — 알림은 여전히 죽는다.
  _run_probe NameSelectorProbe '{__name__="ghcr_latest_digest"} == 1'
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[모드 C:'
  echo "$output" | grep -q 'ghcr_latest_digest'
}

@test "mode C F-1 flags a push metric hidden in the VictoriaMetrics shorthand selector" {
  _run_probe ShorthandSelectorProbe '{"ghcr_latest_digest"} == 1'
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[모드 C:'
}

@test "mode C F-1 flags a __name__ regex selector that can match a push metric (fail-closed)" {
  _run_probe NameRegexProbe '{__name__=~"ghcr_.*"} == 1'
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[모드 C:'
  echo "$output" | grep -q 'fail-closed'
}

@test "mode C F-1 still accepts a __name__ selector that IS wrapped in a rollup (no over-flagging)" {
  # 정규화가 과잉 검출로 번지지 않는지 — 정당하게 감싼 형태는 통과해야 한다.
  _run_probe WrappedNameSelectorProbe 'last_over_time({__name__="ghcr_latest_digest"}[15m]) == 1'
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "mode C F-2 rejects irate() as a rollup (needs 2 samples — window holds only 1 push)" {
  _run_probe IrateProbe 'irate(ghcr_latest_digest[10m]) > 0'
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[모드 C:'
  echo "$output" | grep -q 'irate'
}

@test "mode C F-2 rejects idelta() as a rollup (fake fix that still cannot fire)" {
  _run_probe IdeltaProbe 'idelta(files_data_bulk_avail_bytes[1d]) > 0'
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[모드 C:'
}

@test "mode C F-2 rejects a bare range selector with no rollup function" {
  _run_probe BareRangeProbe 'ghcr_latest_digest[15m]'
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[모드 C:'
  echo "$output" | grep -q '맨 참조'
}

@test "mode C F-3 flags a new metric added to an ALREADY REGISTERED producer (metric-level completeness)" {
  # 가장 흔한 우회 경로: 파일은 이미 등록돼 있으니 파일 단위 가드는 통과한다 → 메트릭 단위로 강제해야 한다.
  tmp="$(mktemp -d)"
  _seed "$tmp"
  printf 'OUT="${OUT}new_digest_exporter_metric{app=\\"x\\"} 1\\n"\n' \
    >> "$tmp/platform/fake/prod/digest-exporter.yaml"
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'new_digest_exporter_metric'
  echo "$output" | grep -q '레지스트리에 없음'
}

@test "mode C F-4 fails when a registry cron schedule file is missing (no silent constant fallback)" {
  # CronJob을 옮기거나 리네임하면 cron 교차검증과 생산자 발견을 동시에 우회할 수 있었다 → 부재 = FAIL.
  tmp="$(mktemp -d)"
  _seed "$tmp"
  # 생산자(=push 스크립트)는 남기고 cron 선언만 다른 경로로 돌린다(= CronJob을 옮긴 상황).
  sed 's#"file": "platform/fake/prod/digest-exporter.yaml"#"file": "platform/fake/prod/moved-cronjob.yaml"#' \
    "$tmp/registry.json" > "$tmp/registry.tmp" && mv "$tmp/registry.tmp" "$tmp/registry.json"
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'moved-cronjob.yaml'
}

# ── G-1: 생산자 발견이 단일 엔드포인트(`api/v1/import`)에 묶이면 다른 쓰기 경로가 발견을 통째로 우회한다 ──

@test "mode C G-1 flags a producer that pushes via Prometheus remote_write (/api/v1/write)" {
  tmp="$(mktemp -d)"
  _seed "$tmp"
  mkdir -p "$tmp/platform/newthing/prod"
  cat > "$tmp/platform/newthing/prod/rw-exporter.yaml" <<'YAML'
apiVersion: batch/v1
kind: CronJob
metadata: { name: rw-exporter }
spec:
  schedule: "*/10 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: push
              command: ["sh", "-c", "echo 'rw_pushed_metric 1' | curl -fsS -X POST --data-binary @- http://vmsingle:8428/api/v1/write"]
YAML
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'rw-exporter.yaml'
  echo "$output" | grep -q 'rw_pushed_metric'
}

@test "mode C G-1 flags a producer that pushes via the InfluxDB line protocol (/write)" {
  tmp="$(mktemp -d)"
  _seed "$tmp"
  cat > "$tmp/scripts/influx-pusher.sh" <<'SH'
#!/usr/bin/env bash
printf 'influx_pushed_metric 1\n' | curl -fsS --data-binary @- "http://vmsingle:8428/write"
SH
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'influx-pusher.sh'
}

@test "mode C G-1 flags a producer whose VM URL is synthesized from variables (no literal endpoint path)" {
  # 경로 조각이 파일에 안 보여도 호스트 + 쓰기 동사로 잡아야 한다.
  tmp="$(mktemp -d)"
  _seed "$tmp"
  cat > "$tmp/scripts/synth-url-pusher.sh" <<'SH'
#!/usr/bin/env bash
VM="http://vmsingle:8428"
EP="${VM}/${TARGET_PATH}"
printf 'synth_pushed_metric 1\n' | curl -fsS --data-binary @- "$EP"
SH
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'synth-url-pusher.sh'
  echo "$output" | grep -q 'URL 합성'
}

@test "mode C G-1 fails closed when a producer payload cannot be parsed statically" {
  # 등록된 생산자라도 무엇을 push하는지 정적으로 못 읽으면 모드 C가 그 메트릭을 영영 못 본다 → FAIL.
  tmp="$(mktemp -d)"
  _seed "$tmp"
  cat > "$tmp/scripts/fake-files-backup.sh" <<'SH'
#!/usr/bin/env bash
# 페이로드를 파일에서 읽어 그대로 전송 — 메트릭 이름을 정적으로 해석할 수 없다.
curl -fsS --data-binary @/var/tmp/payload.txt "http://vmsingle:8428/api/v1/import/prometheus"
SH
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '정적으로 해석할 수 없다'
}

@test "mode C G-1 does not mistake read-only vmsingle consumers for producers (no false positives)" {
  # homepage 위젯·grafana·게이트처럼 **질의만** 하는 소비자는 생산자가 아니다(쓰기 신호 부재).
  tmp="$(mktemp -d)"
  _seed "$tmp"
  mkdir -p "$tmp/platform/consumer/prod"
  cat > "$tmp/platform/consumer/prod/widget.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata: { name: widget }
data:
  services.yaml: |
    - Observability:
        - Metrics:
            widget:
              type: prometheus
              url: http://vmsingle:8428
              query: http://vmsingle:8428/api/v1/query?query=up
              export: http://vmsingle:8428/api/v1/export
YAML
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

# ── G-2: URL 신호 자체가 우회 가능(호스트·경로가 전부 변수/시크릿) → **페이로드 모양**이 세 번째 신호 ──

@test "mode C G-2 flags a producer whose VM URL comes entirely from a secret (payload shape is the signal)" {
  # URL 리터럴이 파일에 **전혀 없다** — 그래도 exposition 페이로드를 POST하면 그건 메트릭 push다.
  tmp="$(mktemp -d)"
  _seed "$tmp"
  cat > "$tmp/scripts/secret-url-pusher.sh" <<'SH'
#!/usr/bin/env bash
VM_URL="$(cat /etc/secret/vm-url)"
printf 'sneaky_metric{a="1"} 42\n' | curl -fsS --data-binary @- "$VM_URL"
SH
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'secret-url-pusher.sh'
  echo "$output" | grep -q 'sneaky_metric'
  echo "$output" | grep -q 'exposition'
}

@test "mode C G-2 does not flag non-exposition POSTs (AdGuard/telegram-style JSON API calls)" {
  # 오탐 경계: exposition이 아닌 POST는 그냥 다른 API 호출이다 → 후보가 아니다(조용히 통과).
  tmp="$(mktemp -d)"
  _seed "$tmp"
  cat > "$tmp/scripts/json-api-caller.sh" <<'SH'
#!/usr/bin/env bash
curl -fsS -X POST -H 'Content-Type: application/json' \
  -d "{\"target\":{\"domain\":\"${DOMAIN}\",\"answer\":\"${WANT}\"}}" \
  "${API}/control/rewrite/update"
curl -fsS -X POST --data-raw "chat_id=${CHAT}&text=${MSG}" "${TG}/sendMessage"
SH
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

# ── S-2: EXPO_LINE(heredoc 본문의 진짜-개행 exposition 라인) — heredoc push 메트릭을 놓치지 않는다 ──

@test "mode C S-2 flags a metric pushed via heredoc into an already-registered producer" {
  # 등록된 digest-exporter가 heredoc으로 정적 리터럴 메트릭을 추가 push하면 잡아야 한다(printf만 보던 추출기 우회).
  tmp="$(mktemp -d)"
  _seed "$tmp"
  cat >> "$tmp/platform/fake/prod/digest-exporter.yaml" <<'YAML'
    curl -fsS --data-binary @- 'http://vmsingle:8428/api/v1/import/prometheus' <<EOF
    ghcr_stale_tag_count 7
    EOF
YAML
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'ghcr_stale_tag_count'
  echo "$output" | grep -q '레지스트리에 없음'
}

@test "mode C S-2 does not extract metrics from an arbitrary-text heredoc (no false positives)" {
  # exposition이 아닌 heredoc(로그/산문·매니페스트)은 메트릭으로 오인하면 안 된다.
  tmp="$(mktemp -d)"
  _seed "$tmp"
  cat >> "$tmp/platform/fake/prod/digest-exporter.yaml" <<'YAML'
    cat <<MSG
    Deploying the digest exporter now.
    All apps have been reconciled successfully.
    replicas: 3
    MSG
YAML
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "mode C fails when a push producer is not in the registry (completeness guard)" {
  # 새 push exporter를 추가했는데 레지스트리에 메트릭을 등록하지 않으면 다음 사람이 같은 함정에 빠진다.
  tmp="$(mktemp -d)"
  _seed "$tmp"
  mkdir -p "$tmp/platform/newthing/prod"
  cat > "$tmp/platform/newthing/prod/new-exporter.yaml" <<'YAML'
apiVersion: batch/v1
kind: CronJob
metadata: { name: new-exporter }
spec:
  schedule: "*/30 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: push
              command: ["sh", "-c", "echo 'new_thing_metric 1' | curl -fsS --data-binary @- http://vmsingle:8428/api/v1/import/prometheus"]
YAML
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'new-exporter.yaml'
  echo "$output" | grep -q '레지스트리'
}

# ── 게이트 자체의 fail-closed 성질 ──

@test "alert-rule guard enforces a minimum scan count (extraction collapse = fail-loud)" {
  tmp="$(mktemp -d)"
  _seed "$tmp"
  rm -f "$tmp/platform/victoria-stack/prod/rules/probe.yaml"   # 룰 추출 붕괴 시뮬레이션
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '스캔 룰'
}

@test "alert-rule guard honors an allowlist entry that carries a reason" {
  tmp="$(mktemp -d)"
  _seed "$tmp" PodCrashLoopingProbe 'increase(kube_pod_container_status_restarts_total[15m]) > 3'
  echo 'PodCrashLoopingProbe   # 테스트 면제' > "$tmp/policy/alert-instance-stability-allowlist.txt"
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "alert-rule guard rejects an allowlist entry with no reason comment" {
  tmp="$(mktemp -d)"
  _seed "$tmp" PodCrashLoopingProbe 'increase(kube_pod_container_status_restarts_total[15m]) > 3'
  echo 'PodCrashLoopingProbe' > "$tmp/policy/alert-instance-stability-allowlist.txt"
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '사유 주석'
}

@test "alert-rule guard flags all three pre-fix exprs that shipped four reboot false positives" {
  # 회귀 앵커: PR #327 이전에 **실제로 배포돼 있던** 세 expr(32ac8ec 시점, 자구 그대로)을 한 룰 파일에
  # 넣으면 셋 다 잡아야 한다. git show로 과거 트리를 꺼내지 않는다 — actions/checkout이 fetch-depth:1
  # 얕은 클론이라 CI에서 해당 커밋이 없다(게이트가 조용히 죽는 false-green 회피).
  tmp="$(mktemp -d)"
  _seed "$tmp"
  # 30건 시드 뒤에 과거 expr 3건을 이어붙인다(들여쓰기는 _seed의 rules: 목록과 동일).
  cat >> "$tmp/platform/victoria-stack/prod/rules/probe.yaml" <<'YAML'
          - alert: PodOOMKilled
            expr: 'increase(kube_pod_container_status_restarts_total[15m]) > 0 and on(namespace,pod) kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1'
          - alert: PodCrashLooping
            expr: 'increase(kube_pod_container_status_restarts_total{namespace!~"kube-system|kube-public|kube-node-lease"}[15m]) > 3'
          - alert: WALVolumeFilling
            expr: '(cnpg_collector_pg_wal{value="size"} / on(namespace, pod) cnpg_collector_pg_wal{value="volume_size"}) > 0.70'
YAML
  _lint "$tmp"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'PodCrashLooping'
  echo "$output" | grep -q 'PodOOMKilled'
  echo "$output" | grep -q 'WALVolumeFilling'
}
