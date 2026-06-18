#!/usr/bin/env bats
# audit 스케줄 reconciler(audit.yaml) 불변식. 구 audit reusable 워크플로에서 이관된 단언 포함.
# (@test 이름 영어, 단언은 grep/run+[ ] — bash 3.2 [[ ]] 침묵통과 함정 회피)

setup() { ROOT="$(git rev-parse --show-toplevel)"; F="$ROOT/.github/workflows/audit.yaml"; }

@test "audit is a scheduled reconciler with manual dispatch" {
  [ -f "$F" ]; grep -q "schedule:" "$F"; grep -q "workflow_dispatch:" "$F"
}
@test "audit notifies only on drift or failure (no zero-count spam)" {
  grep -q "count != '0'" "$F"
}
@test "audit status is outcome-driven (failure not mislabeled as drift)" {
  grep -q "steps.audit.outcome == 'failure'" "$F"
}
@test "audit is read-only and not in the mutation serialization group" {
  run grep -q "group: homelab-mutation" "$F"; [ "$status" -ne 0 ]
}
@test "audit summary does not cap findings at 20" {
  run grep -c '\.findings\[:20\]' "$F"; [ "$output" = "0" ]
}
@test "audit summary does not swallow jq errors" {
  run grep -cE '2>/dev/null \|\| true' "$F"; [ "$output" = "0" ]
}
