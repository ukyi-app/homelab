#!/usr/bin/env bats
# vmalert 룰 instance-라벨 안정성 가드 (PR #327 포스트모템 — 재부팅 IP churn 오탐 4회 재발).
# required 게이트인 `vmalert -dryRun`은 문법만 본다 → 두 모드(eval-time 의미)를 원리적으로 못 잡는다.
# 라이브 eval 게이트도 무력하다(정상상태 데이터엔 결함이 부재, 재부팅 과도구간에서만 발현) →
# 유일하게 CI에서 잡을 수 있는 형태는 expr 안티패턴의 정적 lint다. @test 이름은 영어(CJK 함정).
# CI-safe(소스 스캔, bun/TS 단일) → run-bats.sh gate 도메인에 자동 수집.

# scan-floor(30) 통과용 정상 룰 30건 + 선택적 프로브 룰 1건을 담은 룰 ConfigMap을 시드한다.
_seed() {
  local root="$1" name="${2:-}" expr="${3:-}" i
  mkdir -p "$root/platform/victoria-stack/prod/rules" "$root/policy"
  : > "$root/policy/alert-instance-stability-allowlist.txt"
  echo 'kube_pod_container_status_restarts_total   # 테스트 시드' \
    > "$root/policy/alert-instance-stability-denylist.txt"
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

_run_probe() {   # $1=alert명 $2=expr → run 결과를 호출자가 판정
  tmp="$(mktemp -d)"
  _seed "$tmp" "$1" "$2"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-alert-rules.ts" --repo-root "$tmp"
  echo "$output"
}

@test "alert-rule guard passes on the real repository rules" {
  run bun "${BATS_TEST_DIRNAME}/../tools/check-alert-rules.ts" --repo-root "${BATS_TEST_DIRNAME}/.."
  echo "$output"
  [ "$status" -eq 0 ]
}

# ── 모드 A: rollup이 상태-파생(비-리셋) 카운터를 감쌀 때 instance 제거를 강제 ──

@test "mode A flags a raw rollup over a state-derived counter (red-green)" {
  _run_probe PodCrashLoopingProbe 'increase(kube_pod_container_status_restarts_total[15m]) > 3'
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '모드 A'
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
  echo "$output" | grep -q '모드 B'
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

# ── 게이트 자체의 fail-closed 성질 ──

@test "alert-rule guard enforces a minimum scan count (extraction collapse = fail-loud)" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/platform/victoria-stack/prod/rules" "$tmp/policy"
  : > "$tmp/policy/alert-instance-stability-allowlist.txt"
  : > "$tmp/policy/alert-instance-stability-denylist.txt"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-alert-rules.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '스캔 룰'
}

@test "alert-rule guard honors an allowlist entry that carries a reason" {
  tmp="$(mktemp -d)"
  _seed "$tmp" PodCrashLoopingProbe 'increase(kube_pod_container_status_restarts_total[15m]) > 3'
  echo 'PodCrashLoopingProbe   # 테스트 면제' > "$tmp/policy/alert-instance-stability-allowlist.txt"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-alert-rules.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

@test "alert-rule guard rejects an allowlist entry with no reason comment" {
  tmp="$(mktemp -d)"
  _seed "$tmp" PodCrashLoopingProbe 'increase(kube_pod_container_status_restarts_total[15m]) > 3'
  echo 'PodCrashLoopingProbe' > "$tmp/policy/alert-instance-stability-allowlist.txt"
  run bun "${BATS_TEST_DIRNAME}/../tools/check-alert-rules.ts" --repo-root "$tmp"
  echo "$output"
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
  run bun "${BATS_TEST_DIRNAME}/../tools/check-alert-rules.ts" --repo-root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'PodCrashLooping'
  echo "$output" | grep -q 'PodOOMKilled'
  echo "$output" | grep -q 'WALVolumeFilling'
}
