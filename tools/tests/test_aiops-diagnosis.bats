#!/usr/bin/env bats
# Codex JSONL/최종 응답을 외부 엔진 대역으로 통과시키는 공개 경계.
bats_require_minimum_version 1.5.0
load helpers/aiops
setup() {
  aiops_setup
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  printf 'fixture\n' > "$REPO/README.md"
  git -C "$REPO" init -q
  git -C "$REPO" add .
  git -C "$REPO" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
  REVISION="$(git -C "$REPO" rev-parse HEAD)"
  seed_incident
  printf '{"collectedAt":"2026-09-12T00:10:00Z","items":[{"id":"state-1","kind":"state","target":"monitoring/vmalert","observedAt":"2026-09-12T00:01:00Z","data":{"reason":"FailedScheduling"}}]}' > "$BATS_TEST_TMPDIR/evidence.json"
  aiops collect --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" --input "$BATS_TEST_TMPDIR/evidence.json" >/dev/null
  ENGINE="$BATS_TEST_TMPDIR/engine"
  cat > "$ENGINE" <<'PY'
#!/usr/bin/python3
import sys,json
args=sys.argv[1:]
out=args[args.index('--output-last-message')+1]
evidence=json.load(open('evidence.json'))
report=dict(baseRevision=evidence['revision'],outcome='diagnosed',summary='스케줄링 실패 후보',causes=[dict(hypothesis='자원 부족',evidenceIds=['state-1'],counterEvidence=[],nextChecks=['노드 가용 메모리 확인'])],missingEvidence=[],patch=None)
json.dump(report,open(out,'w'))
print(json.dumps(dict(type='turn.completed',usage=dict(input_tokens=100,output_tokens=30,cached_input_tokens=0))))
PY
  chmod +x "$ENGINE"
}

@test "valid simulated engine output preserves evidence references and confirmed usage" {
  sed -i '/args=sys.argv/a\import os\nassert os.environ.get("CODEX_HOME") and not os.path.exists(os.environ["CODEX_HOME"]+"/auth.json")\nassert any(a.startswith("forced_login_method=") and "chatgpt" in a for a in args)' "$ENGINE"
  run aiops diagnose --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" --engine "$ENGINE" --mode replay
  [ "$status" -eq 0 ]
  run aiops show --incident "$INCIDENT"
  [ "$status" -eq 0 ]
  jq -e '.incident.execution.status == "diagnosed" and .incident.report.simulated == true and .incident.report.diagnosis.causes[0].evidenceIds == ["state-1"] and .incident.report.usage.inputTokens == 100 and .incident.report.patch == null and .incident.publication.status == "not-requested"' <<< "$output"
}

@test "a grounded patch is applied in a clean Git copy and unrelated evidence is rejected" {
  sed -i "s/patch=None/patch='diff --git a\/README.md b\/README.md\\\\n--- a\/README.md\\\\n+++ b\/README.md\\\\n@@ -1 +1 @@\\\\n-fixture\\\\n+fixed\\\\n'/" "$ENGINE"
  run aiops diagnose --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" --engine "$ENGINE" --mode replay
  [ "$status" -eq 0 ]
  jq -e '.incident.execution.status == "diagnosed" and (.incident.report.patch | contains("+fixed")) and (.incident.report.candidate.revision | length) == 40 and (.incident.report.candidate.manifestHash | length) == 64' <<< "$output"
  [ "$(cat "$REPO/README.md")" = fixture ]
  sed -i "s/'state-1'/'invented-id'/" "$ENGINE"
  run aiops diagnose --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" --engine "$ENGINE" --mode replay
  [ "$status" -eq 0 ]
  jq -e '.incident.execution.status == "invalid-result" and .incident.report.patch == null and (.incident.report.missing | index("diagnosis-evidence-invalid")) != null' <<< "$output"
}

@test "diagnosis reads a protected repository owned by the installation account" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/git" <<'SH'
#!/usr/bin/env bash
# 실제 Git의 다른 소유자 검사를 강제한다. 전역 safe.directory는 설정하지 않는다.
export GIT_TEST_ASSUME_DIFFERENT_OWNER=1
exec /usr/bin/git "$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run aiops diagnose --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" --engine "$ENGINE" --mode replay
  [ "$status" -eq 0 ]
  jq -e '.incident.execution.status == "diagnosed"' <<< "$output"
}

@test "authentication failure waits durably until an explicit recovery resumes admission" {
  cat > "$ENGINE" <<'PY'
#!/usr/bin/python3
import json,sys
print(json.dumps({'type':'turn.failed','error':{'message':'authentication token expired; login required'}}))
sys.exit(1)
PY
  run aiops diagnose --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" --engine "$ENGINE" --mode replay
  [ "$status" -eq 0 ]
  jq -e '.incident.execution.status == "waiting-authentication"' <<< "$output"
  run aiops replay
  [ "$status" -eq 1 ]
  run aiops resume --incident "$INCIDENT"
  [ "$status" -eq 0 ]
  jq -e '.incident.execution.status == "queued"' <<< "$output"
  run aiops list
  [ "$status" -eq 0 ]
  jq -e '([.budget.days[]] | add) == 1 and .budget.active == null' <<< "$output"
  run aiops replay
  [ "$status" -eq 0 ]
  run aiops list
  [ "$status" -eq 0 ]
  jq -e '([.budget.days[]] | add) == 2' <<< "$output"
}

@test "subscription capacity failure on stderr waits without exposing its raw message" {
  cat > "$ENGINE" <<'PY'
#!/usr/bin/python3
import sys
print('usage_limit_reached secret=private-capacity-canary',file=sys.stderr)
sys.exit(1)
PY
  run aiops diagnose --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" --engine "$ENGINE" --mode replay
  [ "$status" -eq 0 ]
  jq -e '.incident.execution.status == "waiting-capacity" and .incident.report.process.failureHint == "capacity"' <<< "$output"
  run grep -F private-capacity-canary <<< "$output"
  [ "$status" -eq 1 ]
}
