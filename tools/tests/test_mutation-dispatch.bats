#!/usr/bin/env bats
# 변이 디스패처(create-app/update-secrets/create-database/create-cache) 구조·notify 불변식.
# test_dispatcher.bats(dispatch-mutation 전용, Task 4에서 삭제)의 단언을 4 디스패처로 일반화.
# (@test 이름 영어, 단언은 run+[ ] — bash 3.2 [[ ]] 침묵통과 함정 회피)

setup() {
  ROOT="$(git rev-parse --show-toplevel)"; WF="$ROOT/.github/workflows"
  DISPATCHERS="create-app update-secrets create-database create-cache"
}

@test "every dispatcher serializes via homelab-mutation group with queue max" {
  for d in $DISPATCHERS; do
    f="$WF/$d.yaml"; [ -f "$f" ]
    grep -q "group: homelab-mutation" "$f"
    grep -q "queue: max" "$f"
    grep -q "cancel-in-progress: false" "$f"
  done
}

@test "no workflow combines queue:max with cancel-in-progress:true" {
  for f in "$WF"/*.yaml; do
    if grep -q "queue: max" "$f"; then
      run grep -q "cancel-in-progress: true" "$f"; [ "$status" -ne 0 ]
    fi
  done
}

@test "create-app dispatcher grants packages:read on the reusable call job" {
  grep -q "packages: read" "$WF/create-app.yaml"
}

@test "each dispatcher validates with fixed action then routes to its reusable" {
  for d in $DISPATCHERS; do
    f="$WF/$d.yaml"
    grep -q "validate-mutation.mjs --action $d" "$f"
    grep -q "needs: validate" "$f"
    grep -q "uses: ./.github/workflows/_$d.yaml" "$f"
  done
}

@test "each dispatcher triggers only on workflow_dispatch (homelab-initiated boundary)" {
  for d in $DISPATCHERS; do
    run grep -E "repository_dispatch|pull_request:|push:|schedule:" "$WF/$d.yaml"
    [ "$status" -ne 0 ]
  done
}

@test "each dispatcher references inputs only via env or with: (no run inline interpolation)" {
  for d in $DISPATCHERS; do
    bad=$(grep -n 'github.event.inputs' "$WF/$d.yaml" \
      | grep -vE '^[0-9]+:[[:space:]]*(#|[A-Z_]+:|(app_repo|sha|spec):)' || true)
    [ -z "$bad" ]
  done
}

@test "each dispatcher declares only its contract inputs" {
  grep -q "app_repo:" "$WF/create-app.yaml";    grep -q "sha:" "$WF/create-app.yaml"
  grep -q "app_repo:" "$WF/update-secrets.yaml"; grep -q "sha:" "$WF/update-secrets.yaml"
  grep -q "spec:" "$WF/create-database.yaml"
  grep -q "spec:" "$WF/create-cache.yaml"
}

@test "each dispatcher notify fires on cancelled as well as failure" {
  for d in $DISPATCHERS; do
    run grep -nE "if:\s*failure\(\)\s*\|\|\s*cancelled\(\)" "$WF/$d.yaml"
    [ "$status" -eq 0 ]
  done
}

@test "each dispatcher notify normalizes status from needs (not its own job.status)" {
  for d in $DISPATCHERS; do
    f="$WF/$d.yaml"
    run grep -nE 'toJSON\(needs\)' "$f"; [ "$status" -eq 0 ]
    run grep -nE 'status:[[:space:]]*\$\{\{[[:space:]]*steps\.norm\.outputs\.status' "$f"; [ "$status" -eq 0 ]
    run grep -nE 'status:[[:space:]]*\$\{\{[[:space:]]*job\.status[[:space:]]*\}\}' "$f"; [ "$status" -ne 0 ]
  done
}
