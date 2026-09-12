#!/usr/bin/env bats
# 실제 Git 기준과 공개 조사 자료 조회 경계.
bats_require_minimum_version 1.5.0
load helpers/aiops
setup() {
  aiops_setup
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/docs/decisions"
  printf '운영 수정 초안은 자동 적용하지 않는다.\n' > "$REPO/CONTEXT.md"
  printf '수렴과 시드의 소유권\n' > "$REPO/docs/decisions/0007-seed-vs-live-ssot.md"
  git -C "$REPO" init -q
  git -C "$REPO" add .
  git -C "$REPO" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
  REVISION="$(git -C "$REPO" rev-parse HEAD)"
  jq --arg sha "$REVISION" '.revision=$sha' "$ALERT" > "$BATS_TEST_TMPDIR/revised.json"
  mv "$BATS_TEST_TMPDIR/revised.json" "$ALERT"
}

@test "collection pins Git and selects incident evidence without exporting sensitive fields" {
  seed_incident
  cat > "$BATS_TEST_TMPDIR/evidence.json" <<'JSON'
{"collectedAt":"2026-09-12T00:10:00Z","items":[
{"id":"state-1","kind":"state","target":"monitoring/vmalert","observedAt":"2026-09-12T00:01:00Z","data":{"phase":"Pending","reason":"FailedScheduling","token":"never-export-me"}},
{"id":"log-1","kind":"logs","target":"monitoring/vmalert","observedAt":"2026-09-12T00:02:00Z","container":"main","data":"connection failed postgres://admin:never-export-me@private.internal/db\nretry exhausted"},
{"id":"other","kind":"logs","target":"ns/other","observedAt":"2026-09-12T00:03:00Z","container":"main","data":"not-related"},
{"id":"old","kind":"logs","target":"monitoring/vmalert","observedAt":"2026-09-11T00:00:00Z","container":"main","data":"old-secret"},
{"id":"raw","kind":"Secret","target":"monitoring/vmalert","observedAt":"2026-09-12T00:03:00Z","data":{"value":"never-export-me"}}
]}
JSON
  run aiops collect --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" --input "$BATS_TEST_TMPDIR/evidence.json"
  [ "$status" -eq 0 ]
  run aiops show --incident "$INCIDENT"
  [ "$status" -eq 0 ]
  jq -e --arg sha "$REVISION" '.incident.evidence.revision == $sha and .incident.evidence.items[0].data.phase == "Pending" and (.incident.evidence.items | length) == 2 and (.incident.evidence.omitted | length) == 3 and .incident.evidence.redactions > 0' <<< "$output"
  run grep -E 'never-export-me|private.internal|not-related|old-secret' <<< "$output"
  [ "$status" -eq 1 ]
  run aiops show --incident "$INCIDENT"
  [ "$status" -eq 0 ]
  jq -e '.incident.evidence.rules[0].path == "CONTEXT.md" and .incident.evidence.partial == true' <<< "$output"
}

@test "log caps span multiple entries per container and missing evidence stays partial" {
  seed_incident
  python3 - "$BATS_TEST_TMPDIR/evidence.json" <<'PY'
import json,sys
items=[dict(id=f'log-{i}',kind='logs',target='monitoring/vmalert',observedAt='2026-09-12T00:02:00Z',container='main',data='\n'.join(f'line-{j}' for j in range(150))) for i in range(2)]
json.dump(dict(collectedAt='2026-09-12T00:10:00Z',items=items),open(sys.argv[1],'w'))
PY
  run aiops collect --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" --input "$BATS_TEST_TMPDIR/evidence.json"
  [ "$status" -eq 0 ]
  jq -e '[.incident.evidence.items[].data | split("\n") | length] | add == 200' <<< "$output"
  jq -e '.incident.evidence.partial and .incident.evidence.truncated == ["log-1"] and .incident.evidence.bytes < 262144' <<< "$output"
  printf '{"collectedAt":"2026-09-12T00:10:00Z","items":[]}' > "$BATS_TEST_TMPDIR/evidence.json"
  run aiops collect --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" --input "$BATS_TEST_TMPDIR/evidence.json"
  [ "$status" -eq 0 ]
  jq -e '.incident.evidence.partial and .incident.evidence.items == []' <<< "$output"
}
