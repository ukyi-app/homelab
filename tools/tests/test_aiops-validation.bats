#!/usr/bin/env bats
# 후보 행 + 고정 기준 상한을 실제 Git·conftest 경계에서 판정한다.
bats_require_minimum_version 1.5.0
load helpers/aiops
setup() {
  aiops_setup
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/docs" "$REPO/tools/lib" "$REPO/policy"
  cp tools/lib/ledger-totals.ts "$REPO/tools/lib/"
  cp policy/ledger.rego "$REPO/policy/"
  printf '<!-- ledger:meta LIMIT_BUDGET_MIB=100 -->\n' > "$REPO/docs/memory-ledger.md"
  for n in $(seq 1 12); do printf '| <!-- ledger:row --> app%s | prod | 1 | 5 |\n' "$n" >> "$REPO/docs/memory-ledger.md"; done
  git -C "$REPO" init -q
  git -C "$REPO" add .
  git -C "$REPO" -c user.name=Test -c user.email=test@example.invalid commit -qm baseline
  BASE="$(git -C "$REPO" rev-parse HEAD)"
  seed_incident
}
commit_candidate() {
  git -C "$REPO" add .
  git -C "$REPO" -c user.name=Test -c user.email=test@example.invalid commit -qm candidate
  CANDIDATE="$(git -C "$REPO" rev-parse HEAD)"
}

@test "raising candidate rows and budget cannot pass the baseline policy by changing its helper" {
  sed -i 's/BUDGET_MIB=100/BUDGET_MIB=1000/;s/| 1 | 5 |/| 1 | 10 |/' "$REPO/docs/memory-ledger.md"
  printf 'export function parseLedgerRows() { return []; }\n' > "$REPO/tools/lib/ledger-totals.ts"
  printf 'package main\n' > "$REPO/policy/ledger.rego"
  commit_candidate
  run aiops validate --incident "$INCIDENT" --repo "$REPO" --revision "$BASE" --candidate "$CANDIDATE"
  [ "$status" -eq 0 ]
  run aiops show --incident "$INCIDENT"
  [ "$status" -eq 0 ]
  jq -e --arg base "$BASE" --arg candidate "$CANDIDATE" '.incident.validation.baseline.revision == $base and .incident.validation.candidate.revision == $candidate and .incident.validation.ledger.baselineBudget == 100 and .incident.validation.ledger.candidateBudget == 1000 and .incident.validation.ledger.totalLimit == 120 and .incident.validation.ledger.fixed.status == "failed" and .incident.validation.ledger.proposed.status == "passed" and .incident.validation.policyChanged == true' <<< "$output"
}

@test "missing candidate metadata cannot hide rows and invalid baseline metadata never falls back" {
  sed -i '/ledger:meta/d;s/| 1 | 5 |/| 1 | 10 |/' "$REPO/docs/memory-ledger.md"
  commit_candidate
  run aiops validate --incident "$INCIDENT" --repo "$REPO" --revision "$BASE" --candidate "$CANDIDATE"
  [ "$status" -eq 0 ]
  jq -e '.incident.validation.ledger.totalLimit == 120 and .incident.validation.ledger.candidateBudget == null and .incident.validation.ledger.fixed.status == "failed" and .incident.validation.ledger.proposed.status == "unverifiable"' <<< "$output"
  invalid_base="$CANDIDATE"
  printf '<!-- ledger:meta LIMIT_BUDGET_MIB=1000 -->\n' >> "$REPO/docs/memory-ledger.md"
  commit_candidate
  run aiops validate --incident "$INCIDENT" --repo "$REPO" --revision "$invalid_base" --candidate "$CANDIDATE"
  [ "$status" -eq 0 ]
  jq -e '.incident.validation.ledger.baselineBudget == null and .incident.validation.ledger.fixed.status == "unverifiable" and .incident.validation.ledger.fixed.reason == "invalid-baseline-budget-no-fallback"' <<< "$output"
}

@test "malformed candidate row cannot disappear from the baseline count" {
  sed -i 's/app1 /APP1 /' "$REPO/docs/memory-ledger.md"
  commit_candidate
  run aiops validate --incident "$INCIDENT" --repo "$REPO" --revision "$BASE" --candidate "$CANDIDATE"
  [ "$status" -eq 0 ]
  jq -e '.incident.validation.ledger.fixed.status == "failed" and .incident.validation.ledger.fixed.reason == "candidate-row-marker-or-number-invalid"' <<< "$output"
}

@test "new malformed data file fails a trusted format check without executing candidate scripts" {
  printf '{broken json\n' > "$REPO/broken.json"
  printf '#!/bin/bash\ntouch SHOULD_NOT_EXIST\n' > "$REPO/candidate.sh"
  commit_candidate
  run aiops validate --incident "$INCIDENT" --repo "$REPO" --revision "$BASE" --candidate "$CANDIDATE"
  [ "$status" -eq 0 ]
  jq -e '.incident.validation.checks | any(.name == "format:broken.json" and .status == "failed")' <<< "$output"
  [ ! -e "$REPO/SHOULD_NOT_EXIST" ]
}
