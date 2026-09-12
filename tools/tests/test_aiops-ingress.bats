#!/usr/bin/env bats
# 생산자 원문 → 인증된 HTTP 인입 → 공개 조회.
bats_require_minimum_version 1.5.0
load helpers/aiops
setup() {
  aiops_setup
  printf 'local-test-token' > "$BATS_TEST_TMPDIR/token"
  jq -n --arg token "$BATS_TEST_TMPDIR/token" '{mode:"replay",ingress:{address:"127.0.0.1",port:0,tokens:{alertmanager:$token,argocd:$token,cnpg:$token}}}' > "$BATS_TEST_TMPDIR/config.json"
}
teardown() { if [ -n "${server:-}" ]; then kill "$server" 2>/dev/null || :; wait "$server" 2>/dev/null || :; fi; }
start_ingress() {
  bun tools/aiops.ts serve --state-dir "$AIOPS_STATE" --config "$BATS_TEST_TMPDIR/config.json" > "$BATS_TEST_TMPDIR/server.out" 2> "$BATS_TEST_TMPDIR/server.err" &
  server=$!
  for attempt in $(seq 1 60); do
    if [ -s "$BATS_TEST_TMPDIR/server.out" ]; then break; fi
    sleep 0.02
  done
  ENDPOINT="$(jq -r '.listening' "$BATS_TEST_TMPDIR/server.out")"
  [ -n "$ENDPOINT" ]
}

@test "Alertmanager delivery requires authentication and persists before acknowledging" {
  start_ingress
  cat > "$BATS_TEST_TMPDIR/payload.json" <<'JSON'
{"version":"4","status":"firing","alerts":[{"status":"firing","labels":{"alertname":"TargetDown","namespace":"monitoring","pod":"vmalert","severity":"critical"},"startsAt":"2026-09-12T00:00:00Z","endsAt":"0001-01-01T00:00:00Z","fingerprint":"deadbeef"}]}
JSON
  run curl -sS -o /dev/null -w '%{http_code}' -X POST "$ENDPOINT/sources/alertmanager" --data-binary @"$BATS_TEST_TMPDIR/payload.json"
  [ "$status" -eq 0 ]
  [ "$output" = 401 ]
  run curl -fsS -H 'Authorization: Bearer local-test-token' -H 'Content-Type: application/json' "$ENDPOINT/sources/alertmanager" --data-binary @"$BATS_TEST_TMPDIR/payload.json"
  [ "$status" -eq 0 ]
  jq -e '.accepted == 1' <<< "$output"
  run aiops list
  [ "$status" -eq 0 ]
  jq -e '.incidents[0].status == "firing" and .incidents[0].observation.target == "monitoring/vmalert" and .sources.alertmanager.status == "observed"' <<< "$output"
}

@test "Argo hook failure stays firing despite Healthy Synced and CNPG incomplete success cannot recover" {
  start_ingress
  cat > "$BATS_TEST_TMPDIR/argo.json" <<'JSON'
{"check":"sync","name":"page-prod","namespace":"argocd","phase":"Failed","health":"Healthy","sync":"Synced","observedAt":"2026-09-12T00:00:00Z","revision":null}
JSON
  run curl -fsS -H 'Authorization: Bearer local-test-token' "$ENDPOINT/sources/argocd" --data-binary @"$BATS_TEST_TMPDIR/argo.json"
  [ "$status" -eq 0 ]
  cat > "$BATS_TEST_TMPDIR/cnpg.json" <<'JSON'
{"check":"restore-drill","target":"database/pg18","runId":"run-1","status":"warning","completed":true,"observedAt":"2026-09-12T00:00:00Z"}
JSON
  run curl -fsS -H 'Authorization: Bearer local-test-token' "$ENDPOINT/sources/cnpg" --data-binary @"$BATS_TEST_TMPDIR/cnpg.json"
  [ "$status" -eq 0 ]
  jq '.status="healthy" | .completed=false | .observedAt="2026-09-12T00:01:00Z"' "$BATS_TEST_TMPDIR/cnpg.json" > "$BATS_TEST_TMPDIR/incomplete.json"
  run curl -fsS -H 'Authorization: Bearer local-test-token' "$ENDPOINT/sources/cnpg" --data-binary @"$BATS_TEST_TMPDIR/incomplete.json"
  [ "$status" -eq 0 ]
  run aiops list
  [ "$status" -eq 0 ]
  jq -e '.incidents | length == 2 and all(.[]; .status == "firing")' <<< "$output"
}
