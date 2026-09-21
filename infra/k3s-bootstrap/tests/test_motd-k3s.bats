#!/usr/bin/env bats
# 집계기와 실제 MOTD 호출 경계를 합성 Kubernetes 응답으로 검증한다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$ROOT/infra/k3s-bootstrap/motd/k3s-status.py"
  SNAPSHOT="$BATS_TEST_TMPDIR/snapshot.json"
  cat > "$SNAPSHOT" <<'JSON'
{"kind":"List","items":[
 {"kind":"Node","metadata":{"name":"node"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
 {"kind":"Pod","metadata":{"name":"web","namespace":"edge"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},
 {"kind":"Pod","metadata":{"name":"old","namespace":"edge","creationTimestamp":"2020-01-01T00:00:00Z","ownerReferences":[{"kind":"Job","name":"run","uid":"job-1","controller":true}]},"status":{"phase":"Failed","containerStatuses":[{"state":{"terminated":{"finishedAt":"2020-01-01T00:01:00Z"}}}]}},
 {"kind":"Job","metadata":{"name":"run","namespace":"edge","uid":"job-1","ownerReferences":[{"kind":"CronJob","name":"cron","uid":"cron-1","controller":true}]},"status":{"conditions":[{"type":"Failed","status":"True","lastTransitionTime":"2020-01-01T00:01:01Z"}]}},
 {"kind":"CronJob","metadata":{"name":"cron","namespace":"edge","uid":"cron-1"},"status":{"lastSuccessfulTime":"2020-01-01T00:10:00Z"}},
 {"kind":"Pod","metadata":{"name":"done","namespace":"edge"},"status":{"phase":"Succeeded"}}
]}
JSON
  mkdir "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/k3s" <<'SH'
#!/bin/sh
cat "$SNAPSHOT"
exit "${KUBE_EXIT:-0}"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/k3s"
  export SNAPSHOT
  export K3S_BIN="$BATS_TEST_TMPDIR/bin/k3s"
}

change_snapshot() {
  jq "$1" "$SNAPSHOT" > "$SNAPSHOT.new"
  mv "$SNAPSHOT.new" "$SNAPSHOT"
}

@test "MOTD separates ready pods and recovered CronJob failures" {
  run python3 "$HELPER"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 1 0 1" ]
}

@test "MOTD keeps unresolved and standalone failures bad" {
  change_snapshot '.items[4].status.lastSuccessfulTime = "2019-12-31T00:00:00Z"'
  run python3 "$HELPER"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 1 1 0" ]
  change_snapshot 'del(.items[2].metadata.ownerReferences) | .items[4].status.lastSuccessfulTime = "2020-01-01T00:10:00Z"'
  run python3 "$HELPER"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 1 1 0" ]
}

@test "MOTD does not recover a failure with success from a recreated CronJob" {
  change_snapshot '.items[4].metadata.uid = "different-cron"'
  run python3 "$HELPER"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 1 1 0" ]
}

@test "MOTD requires the original Job UID when finding the owning CronJob" {
  change_snapshot '.items[3].metadata.uid = "different-job"'
  run python3 "$HELPER"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 1 1 0" ]
}

@test "MOTD rejects success before termination and future success as recovery" {
  change_snapshot '.items[4].status.lastSuccessfulTime = "2020-01-01T00:00:30Z"'
  run python3 "$HELPER"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 1 1 0" ]
  change_snapshot '.items[4].status.lastSuccessfulTime = "2999-01-01T00:00:00Z"'
  run python3 "$HELPER"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 1 1 0" ]
}

@test "MOTD needs a failure timestamp rather than treating pod creation as failure" {
  change_snapshot 'del(.items[2].status.containerStatuses, .items[3].status.conditions)'
  run python3 "$HELPER"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 1 1 0" ]
}

@test "MOTD counts Running NotReady and Pending pods as current issues" {
  change_snapshot '.items[1].status.conditions[0].status = "False"'
  run python3 "$HELPER"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 0 1 1" ]
  change_snapshot '.items[1].status.phase = "Pending"'
  run python3 "$HELPER"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1 0 1 1" ]
}

@test "MOTD preserves a NotReady node and a terminating pod in its summary" {
  change_snapshot '.items[0].status.conditions[0].status = "False" | .items[1].metadata.deletionTimestamp = "2020-01-01T00:10:00Z"'
  run python3 "$HELPER"
  [ "$status" -eq 0 ]
  [ "$output" = "0 1 0 1 1" ]
}

@test "MOTD rejects partial API reads even when stdout is valid JSON" {
  export KUBE_EXIT=1
  run python3 "$HELPER"
  [ "$status" -eq 1 ]
  [ "$output" = "unreachable" ]
}

@test "MOTD rejects malformed responses and an empty node list" {
  printf 'not json' > "$SNAPSHOT"
  run python3 "$HELPER"
  [ "$status" -eq 1 ]
  [ "$output" = "unreachable" ]
  printf '{"kind":"List","items":[]}' > "$SNAPSHOT"
  run python3 "$HELPER"
  [ "$status" -eq 1 ]
  [ "$output" = "unreachable" ]
}

@test "the actual MOTD renders recovered history separately and fails closed" {
  export MOTD_K3S_HELPER="$HELPER"
  export K3S_KUBECONFIG="$SNAPSHOT"
  export CPU_STATE="$BATS_TEST_TMPDIR/cpu"
  export CAT_FILE="$BATS_TEST_TMPDIR/no-cat"
  run bash "$ROOT/infra/k3s-bootstrap/motd/00-ukyi"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F 'node 1/1 · 1 ready · 0 bad'
  printf '%s\n' "$output" | grep -F '1 recovered'
  export KUBE_EXIT=1
  run bash "$ROOT/infra/k3s-bootstrap/motd/00-ukyi"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -F 'unreachable'
  printf '%s\n' "$output" | grep -F 'unknown'
}
