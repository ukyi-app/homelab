#!/usr/bin/env bats
# 사건 입력 → 영속 상태 → 모의 보고서를 별도 CLI 프로세스로 검증한다.
bats_require_minimum_version 1.5.0

setup() {
  cd "$BATS_TEST_DIRNAME/../.." || exit 1
  AIOPS_STATE="$BATS_TEST_TMPDIR/state"
  ALERT="$BATS_TEST_TMPDIR/alert.json"
  cat > "$ALERT" <<'JSON'
{"source":"alertmanager","eventId":"event-1","target":"monitoring/vmalert","observedAt":"2026-09-12T00:00:00Z","revision":"1111111111111111111111111111111111111111","severity":"warning","reason":"TargetDown","status":"firing"}
JSON
}

aiops() { bun tools/aiops.ts "$@" --state-dir "$AIOPS_STATE"; }

@test "saved alert survives separate processes and produces an explicitly simulated report" {
  run aiops ingest --input "$ALERT"
  [ "$status" -eq 0 ]
  incident="$(jq -r '.incident.id' <<< "$output")"
  [ "$incident" != null ]
  run aiops replay --incident "$incident"
  [ "$status" -eq 0 ]
  run aiops show --incident "$incident"
  [ "$status" -eq 0 ]
  jq -e '.incident.status == "firing" and .incident.execution.status == "needs-evidence" and .incident.publication.status == "not-requested" and .incident.report.simulated == true and .incident.report.patch == null' <<< "$output"
}

@test "repeat deliveries deduplicate while recovery and late firing preserve the newest observation" {
  run aiops ingest --input "$ALERT"
  [ "$status" -eq 0 ]
  incident="$(jq -r '.incident.id' <<< "$output")"
  run aiops ingest --input "$ALERT"
  [ "$status" -eq 0 ]
  jq -e '.incident.observationCount == 1' <<< "$output"
  jq '.eventId="event-2" | .observedAt="2026-09-12T00:05:00Z" | .status="resolved"' "$ALERT" > "$BATS_TEST_TMPDIR/recovered.json"
  run aiops ingest --input "$BATS_TEST_TMPDIR/recovered.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.incident.id' <<< "$output")" = "$incident" ]
  jq -e '.incident.status == "resolved" and .incident.execution.status == "cancelled"' <<< "$output"
  jq '.eventId="event-3" | .observedAt="2026-09-12T00:02:00Z"' "$ALERT" > "$BATS_TEST_TMPDIR/late.json"
  run aiops ingest --input "$BATS_TEST_TMPDIR/late.json"
  [ "$status" -eq 0 ]
  jq -e '.incident.status == "resolved" and .incident.observationCount == 3' <<< "$output"
  jq '.eventId="other-cause" | .reason="OOMKilled"' "$ALERT" > "$BATS_TEST_TMPDIR/other.json"
  run aiops ingest --input "$BATS_TEST_TMPDIR/other.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.incident.id' <<< "$output")" != "$incident" ]
}

@test "invalid input and unavailable storage never acknowledge a saved incident" {
  for change in '.source="unknown"' '.eventId=""' '.target=""' '.observedAt="yesterday"' '.revision="main"' '.severity="fatal"' '.reason=""' '.status="ok"' '.secret="do-not-echo"'; do
    jq "$change" "$ALERT" > "$BATS_TEST_TMPDIR/invalid.json"
    run --separate-stderr aiops ingest --input "$BATS_TEST_TMPDIR/invalid.json"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [ "${stderr#do-not-echo}" = "$stderr" ]
  done
  python3 -c 'print(" " * 262145)' > "$BATS_TEST_TMPDIR/large.json"
  run aiops ingest --input "$BATS_TEST_TMPDIR/large.json"
  [ "$status" -ne 0 ]
  echo unavailable > "$AIOPS_STATE"
  run --separate-stderr aiops ingest --input "$ALERT"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "empty history missing incident and resolved replay are distinct from a successful diagnosis" {
  run aiops list
  [ "$status" -eq 0 ]
  jq -e '.incidents == [] and .observationStatus == "no-observations"' <<< "$output"
  run aiops show --incident missing
  [ "$status" -ne 0 ]
  jq '.status="resolved"' "$ALERT" > "$BATS_TEST_TMPDIR/resolved.json"
  run aiops ingest --input "$BATS_TEST_TMPDIR/resolved.json"
  [ "$status" -eq 0 ]
  incident="$(jq -r '.incident.id' <<< "$output")"
  run aiops replay --incident "$incident"
  [ "$status" -ne 0 ]
  run aiops show --incident "$incident"
  [ "$status" -eq 0 ]
  jq -e '.incident.execution.status == "cancelled" and .incident.report == null' <<< "$output"
}

@test "AIOps service failures remain visible without recursively entering the diagnosis queue" {
  jq '.target="host/aiops-coordinator.service" | .reason="SystemdUnitFailed"' "$ALERT" > "$BATS_TEST_TMPDIR/self.json"
  run aiops ingest --input "$BATS_TEST_TMPDIR/self.json"
  [ "$status" -eq 0 ]
  jq -e '.incident.status == "firing" and .incident.execution.status == "self-observation"' <<< "$output"
  run aiops replay
  [ "$status" -ne 0 ]
}
@test "newer Argo recovery closes the same check on an older revision" {
  jq '.source="argocd" | .target="argocd/web" | .reason="ArgoSyncFailed"' "$ALERT" > "$BATS_TEST_TMPDIR/argo.json"
  run aiops ingest --input "$BATS_TEST_TMPDIR/argo.json"
  [ "$status" -eq 0 ]
  old="$(jq -r '.incident.id' <<< "$output")"
  jq '.eventId="recovery" | .status="resolved" | .revision="2222222222222222222222222222222222222222" | .observedAt="2026-09-12T00:10:00Z"' "$BATS_TEST_TMPDIR/argo.json" > "$BATS_TEST_TMPDIR/recovered.json"
  aiops ingest --input "$BATS_TEST_TMPDIR/recovered.json" >/dev/null
  run aiops show --incident "$old"
  [ "$status" -eq 0 ]
  jq -e '.incident.status == "resolved" and .incident.execution.status == "cancelled"' <<< "$output"
}
