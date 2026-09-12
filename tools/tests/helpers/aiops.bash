# AIOps 공개 CLI 하네스 — 내부 DB/모듈은 접근하지 않는다.
aiops_setup() {
  cd "$BATS_TEST_DIRNAME/../.." || exit 1
  AIOPS_STATE="$BATS_TEST_TMPDIR/state"
  ALERT="$BATS_TEST_TMPDIR/alert.json"
  cat > "$ALERT" <<'JSON'
{"source":"alertmanager","eventId":"event-1","target":"monitoring/vmalert","observedAt":"2026-09-12T00:00:00Z","revision":"1111111111111111111111111111111111111111","severity":"warning","reason":"TargetDown","status":"firing"}
JSON
}
aiops() { bun tools/aiops.ts "$@" --state-dir "$AIOPS_STATE"; }
seed_incident() {
  run aiops ingest --input "$ALERT"
  [ "$status" -eq 0 ]
  INCIDENT="$(jq -r '.incident.id' <<< "$output")"
}
