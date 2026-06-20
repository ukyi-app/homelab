#!/usr/bin/env bats
# 변이 디스패처(create-app/update-secrets/create-database/create-cache) 구조·notify 불변식.
# 구 단일 디스패처 전용 테스트(삭제됨)의 단언을 4 디스패처로 일반화.
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
    grep -q "validate-mutation.ts --action $d" "$f"
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
  # create-app/update-secrets는 app_repo만 — sha는 reusable이 앱 레포 main HEAD에서 해석(입력 없음).
  grep -q "app_repo:" "$WF/create-app.yaml";     run grep -q "sha:" "$WF/create-app.yaml";     [ "$status" -ne 0 ]
  grep -q "app_repo:" "$WF/update-secrets.yaml"; run grep -q "sha:" "$WF/update-secrets.yaml"; [ "$status" -ne 0 ]
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

@test "dispatcher rejects a reserved db name before the executor" {
  run bun "$ROOT/tools/validate-mutation.ts" --action create-database --payload '{"spec":"{\"name\":\"postgres\"}"}'
  [ "$status" -ne 0 ]
}
@test "dispatcher rejects a cache -ro suffix name" {
  run bun "$ROOT/tools/validate-mutation.ts" --action create-cache --payload '{"spec":"{\"name\":\"foo-ro\"}"}'
  [ "$status" -ne 0 ]
}
@test "dispatcher rejects a db -ro suffix name (F8)" {
  run bun "$ROOT/tools/validate-mutation.ts" --action create-database --payload '{"spec":"{\"name\":\"foo-ro\"}"}'
  [ "$status" -ne 0 ]
}

@test "workflow inline name regex matches the <=30 SSOT policy (no stale copy)" {
  for wf in _create-cache _create-database; do
    run grep -Fq '{0,28}' "$WF/$wf.yaml"; [ "$status" -eq 0 ]            # ≤30(RESOURCE_NAME_RE와 동일) 존재
  done
  run grep -Fq '{0,27}' "$WF/_create-cache.yaml"; [ "$status" -ne 0 ]        # 옛 ≤29 제거
  run grep -Fq '[a-z0-9-]*[a-z0-9]' "$WF/_create-database.yaml"; [ "$status" -ne 0 ]  # 옛 무제한 제거
}
