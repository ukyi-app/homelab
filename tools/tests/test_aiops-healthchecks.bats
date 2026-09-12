#!/usr/bin/env bats
# 외부 API 대역을 실제 HTTP로 pull하고 재시작 후 공개 상태를 조회한다.
bats_require_minimum_version 1.5.0
load helpers/aiops
setup() {
  aiops_setup
  API_ROOT="$BATS_TEST_TMPDIR/api"
  mkdir -p "$API_ROOT/api/v3/checks/1111111111111111111111111111111111111111/flips"
  printf '{"checks":[{"unique_key":"1111111111111111111111111111111111111111","status":"down"}]}' > "$API_ROOT/api/v3/checks/index.html"
  printf '[{"timestamp":"2026-09-12T00:00:00Z","up":0}]' > "$API_ROOT/api/v3/checks/1111111111111111111111111111111111111111/flips/index.html"
  cat > "$BATS_TEST_TMPDIR/server.py" <<'PY'
import http.server,os,sys
os.chdir(sys.argv[1])
server=http.server.HTTPServer(('127.0.0.1',0),http.server.SimpleHTTPRequestHandler)
print(server.server_address[1],flush=True)
server.serve_forever()
PY
  python3 "$BATS_TEST_TMPDIR/server.py" "$API_ROOT" > "$BATS_TEST_TMPDIR/port" 2> "$BATS_TEST_TMPDIR/server.err" &
  server=$!
  for attempt in $(seq 1 60); do [ -s "$BATS_TEST_TMPDIR/port" ] && break; sleep 0.02; done
  port="$(cat "$BATS_TEST_TMPDIR/port")"
  printf local-read-only-key > "$BATS_TEST_TMPDIR/token"
  jq -n --arg url "http://127.0.0.1:$port/api/v3/" --arg token "$BATS_TEST_TMPDIR/token" '{mode:"replay",healthchecks:{baseUrl:$url,readKeyFile:$token,keyAccess:"read-only",checks:[{id:"1111111111111111111111111111111111111111",target:"alert-pipeline"}]}}' > "$BATS_TEST_TMPDIR/config.json"
}
teardown() { kill "$server" 2>/dev/null || :; wait "$server" 2>/dev/null || :; }

@test "healthcheck flips deduplicate across pulls and a newer recovery clears the queued incident" {
  run aiops poll-healthchecks --config "$BATS_TEST_TMPDIR/config.json"
  [ "$status" -eq 0 ]
  run aiops list
  [ "$status" -eq 0 ]
  jq -e '.incidents[0].status == "firing" and .sources.healthchecks.status == "observed"' <<< "$output"
  printf '[{"timestamp":"2026-09-12T00:05:00Z","up":1},{"timestamp":"2026-09-12T00:00:00Z","up":0}]' > "$API_ROOT/api/v3/checks/1111111111111111111111111111111111111111/flips/index.html"
  run aiops poll-healthchecks --config "$BATS_TEST_TMPDIR/config.json"
  [ "$status" -eq 0 ]
  run aiops poll-healthchecks --config "$BATS_TEST_TMPDIR/config.json"
  [ "$status" -eq 0 ]
  run aiops list
  [ "$status" -eq 0 ]
  jq -e '.incidents[0].status == "resolved" and .incidents[0].observationCount == 2 and .incidents[0].execution.status == "cancelled"' <<< "$output"
}

@test "missing read key API failure and current down state without retained flips remain visible" {
  printf '[]' > "$API_ROOT/api/v3/checks/1111111111111111111111111111111111111111/flips/index.html"
  run aiops poll-healthchecks --config "$BATS_TEST_TMPDIR/config.json"
  [ "$status" -eq 0 ]
  run aiops list
  [ "$status" -eq 0 ]
  jq -e '.incidents[0].status == "firing" and .sources.healthchecks.gap == true' <<< "$output"
  kill "$server"
  wait "$server" 2>/dev/null || :
  run aiops poll-healthchecks --config "$BATS_TEST_TMPDIR/config.json"
  [ "$status" -ne 0 ]
  run aiops list
  [ "$status" -eq 0 ]
  jq -e '.incidents[0].status == "firing" and .sources.healthchecks.status == "unobservable"' <<< "$output"
  printf '{}' > "$BATS_TEST_TMPDIR/config.json"
  run aiops poll-healthchecks --config "$BATS_TEST_TMPDIR/config.json"
  [ "$status" -ne 0 ]
  jq -e '.source.status == "unconfigured"' <<< "$output"
}
