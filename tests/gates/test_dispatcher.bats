#!/usr/bin/env bats
# dispatch-mutation 워크플로 — 직렬화/비신뢰 입력 게이트

setup() { F="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/.github/workflows/dispatch-mutation.yaml"; }

@test "dispatcher serializes via homelab-mutation group with queue max (no pending loss)" {
  grep -q "group: homelab-mutation" "$F"
  grep -q "queue: max" "$F"
  grep -q "cancel-in-progress: false" "$F"
}

@test "dispatcher inputs reach run steps only via env or reusable with: (no inline interpolation)" {
  # github.event.inputs 참조는 env 할당([A-Z_]:), reusable with: 입력(소문자 키), 주석에만 —
  # run 인라인 보간 금지 (with:는 구조적 전달이라 셸 주입 표면이 아니다)
  bad=$(grep -n 'github.event.inputs' "$F" \
    | grep -vE '^[0-9]+:[[:space:]]*(#|[A-Z_]+:|(app|app_repo|sha|resource|spec|action):)' || true)
  [ -z "$bad" ]
}

@test "dispatcher validates payload with validate-mutation.mjs before routing" {
  grep -q "validate-mutation.mjs" "$F"
  # route는 validate를 기다린다
  grep -q "needs: validate" "$F"
}

@test "dispatcher only triggers on workflow_dispatch (homelab-initiated boundary)" {
  run grep -E "repository_dispatch|pull_request:|push:" "$F"
  [ "$status" -ne 0 ]
}
