#!/usr/bin/env bats
# 실제 저장소와 프로세스 수명에서 admission·quota를 관측한다.
bats_require_minimum_version 1.5.0
load helpers/aiops
setup() { aiops_setup; }
teardown() {
  # 실패한 red 단계에서도 이 테스트가 띄운 자식을 남기지 않는다.
  if [ -n "${child:-}" ] && [ "$child" != null ]; then kill -KILL -- "-$child" 2>/dev/null || :; fi
}

@test "twenty daily replay admissions survive restarts and reset at the KST day boundary" {
  seed_incident
  for attempt in $(seq 1 20); do
    run aiops replay --incident "$INCIDENT" --at 2026-09-12T14:59:59Z
    [ "$status" -eq 0 ]
  done
  run aiops replay --incident "$INCIDENT" --at 2026-09-12T14:59:59Z
  [ "$status" -ne 0 ]
  run aiops list
  [ "$status" -eq 0 ]
  jq -e '.budget.days["2026-09-12"] == 20 and .incidents[0].execution.status == "deferred"' <<< "$output"
  run aiops replay --incident "$INCIDENT" --at 2026-09-12T15:00:00Z
  [ "$status" -eq 0 ]
  run aiops list
  [ "$status" -eq 0 ]
  jq -e '.budget.days["2026-09-13"] == 1 and .budget.days["2026-09-12"] == 20' <<< "$output"
}

@test "a hanging engine occupies the lease until its whole process group is stopped" {
  seed_incident
  cat > "$BATS_TEST_TMPDIR/engine" <<'SH'
#!/bin/bash
trap '' TERM
sleep 60 &
wait
SH
  chmod +x "$BATS_TEST_TMPDIR/engine"
  bun tools/aiops.ts replay --state-dir "$AIOPS_STATE" --incident "$INCIDENT" --engine "$BATS_TEST_TMPDIR/engine" --timeout-ms 1500 > "$BATS_TEST_TMPDIR/first.out" 2>&1 &
  worker=$!
  for attempt in $(seq 1 60); do
    run aiops list
    if jq -e '.budget.active.process.pid > 0' <<< "$output" >/dev/null; then break; fi
    sleep 0.02
  done
  child="$(jq -r '.budget.active.process.pid' <<< "$output")"
  [ "$child" != null ]
  run aiops replay --incident "$INCIDENT"
  [ "$status" -ne 0 ]
  wait "$worker" || :
  run aiops show --incident "$INCIDENT"
  [ "$status" -eq 0 ]
  jq -e '.incident.execution.status == "timeout" and .incident.report.process.cleanup == "confirmed"' <<< "$output"
  run aiops replay --incident "$INCIDENT"
  [ "$status" -eq 0 ]
}

@test "a killed supervisor leaves its budget reserved until explicit recovery confirms child cleanup" {
  seed_incident
  cat > "$BATS_TEST_TMPDIR/engine" <<'SH'
#!/bin/bash
trap '' TERM
sleep 60 &
wait
SH
  chmod +x "$BATS_TEST_TMPDIR/engine"
  bun tools/aiops.ts replay --state-dir "$AIOPS_STATE" --incident "$INCIDENT" --engine "$BATS_TEST_TMPDIR/engine" > "$BATS_TEST_TMPDIR/crashed.out" 2>&1 &
  worker=$!
  for attempt in $(seq 1 60); do
    run aiops list
    if jq -e '.budget.active.process.pid > 0' <<< "$output" >/dev/null; then break; fi
    sleep 0.02
  done
  jq -e '.budget.active.process.pid > 0' <<< "$output"
  child="$(jq -r '.budget.active.process.pid' <<< "$output")"
  kill -KILL "$worker"
  wait "$worker" 2>/dev/null || :
  run aiops replay --incident "$INCIDENT"
  [ "$status" -ne 0 ]
  run aiops recover
  [ "$status" -eq 0 ]
  jq -e '.incident.execution.status == "interrupted"' <<< "$output"
  run aiops list
  [ "$status" -eq 0 ]
  jq -e '.budget.active == null and ([.budget.days[]] | add) == 1' <<< "$output"
  run aiops replay --incident "$INCIDENT"
  [ "$status" -eq 0 ]
}

@test "automatic replay prefers critical alerts but ages old warnings and excludes recovered work" {
  jq '.eventId="old" | .target="ns/old" | .observedAt="2026-09-11T00:00:00Z"' "$ALERT" > "$BATS_TEST_TMPDIR/old.json"
  run aiops ingest --input "$BATS_TEST_TMPDIR/old.json"
  [ "$status" -eq 0 ]
  old="$(jq -r '.incident.id' <<< "$output")"
  jq '.eventId="critical" | .target="ns/critical" | .severity="critical"' "$ALERT" > "$BATS_TEST_TMPDIR/critical.json"
  run aiops ingest --input "$BATS_TEST_TMPDIR/critical.json"
  [ "$status" -eq 0 ]
  critical="$(jq -r '.incident.id' <<< "$output")"
  seed_incident
  run aiops replay --at 2026-09-12T00:00:00Z
  [ "$status" -eq 0 ]
  [ "$(jq -r '.incident.id' <<< "$output")" = "$old" ]
  run aiops replay --at 2026-09-12T00:00:00Z
  [ "$status" -eq 0 ]
  [ "$(jq -r '.incident.id' <<< "$output")" = "$critical" ]
}
