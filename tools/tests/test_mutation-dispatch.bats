#!/usr/bin/env bats
# 변이 디스패처(create-app/update-secrets/create-database/create-cache) 구조·notify 불변식.
# 구 단일 디스패처 전용 테스트(삭제됨)의 단언을 4 디스패처로 일반화.
# (@test 이름 영어, 단언은 run+[ ] — bash 3.2 [[ ]] 침묵통과 함정 회피)

setup() {
  ROOT="$(git rev-parse --show-toplevel)"; WF="$ROOT/.github/workflows"
  DISPATCHERS="create-app update-secrets create-database create-cache teardown-app"
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
      | grep -vE '^[0-9]+:[[:space:]]*(#|[A-Z_]+:|(sha|spec|app|confirm):)' || true)
    [ -z "$bad" ]
  done
}

@test "each dispatcher declares only its contract inputs" {
  # create-app/update-secrets는 app만(repo=ukyi-app/<app>·sha는 reusable이 main HEAD에서 해석 — 입력 없음).
  grep -q "app:" "$WF/create-app.yaml";     run grep -q "app_repo:" "$WF/create-app.yaml";     [ "$status" -ne 0 ]
  grep -q "app:" "$WF/update-secrets.yaml"; run grep -q "app_repo:" "$WF/update-secrets.yaml"; [ "$status" -ne 0 ]
  grep -q "spec:" "$WF/create-database.yaml"
  grep -q "spec:" "$WF/create-cache.yaml"
}

@test "create-app and update-secrets no longer reference app_repo anywhere (org is structurally ukyi-app)" {
  # 단일 결정 단언(bats는 마지막 명령만 평가) — 4 파일 어디에도 app_repo가 없어야 한다.
  run grep -l "app_repo" "$WF/create-app.yaml" "$WF/_create-app.yaml" "$WF/update-secrets.yaml" "$WF/_update-secrets.yaml"
  [ "$status" -ne 0 ]
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

@test "teardown-app dispatcher declares only app and confirm inputs (no app_repo)" {
  grep -q "app:" "$WF/teardown-app.yaml"
  grep -q "confirm:" "$WF/teardown-app.yaml"
  run grep -q "app_repo:" "$WF/teardown-app.yaml"; [ "$status" -ne 0 ]
}

@test "teardown-app reusable uses writer token only (no reader, no GHCR)" {
  grep -q "HOMELAB_WRITER_APP_ID" "$WF/_teardown-app.yaml"
  run grep -q "HOMELAB_READER_APP_ID" "$WF/_teardown-app.yaml"; [ "$status" -ne 0 ]
}

@test "teardown-app reusable enforces confirm at its boundary (workflow_call input + re-validate)" {
  grep -q "confirm:" "$WF/_teardown-app.yaml"                                  # workflow_call에 confirm 입력
  grep -q "validate-mutation.ts --action teardown-app" "$WF/_teardown-app.yaml" # teardown 前 재검증(defense-in-depth)
}

@test "teardown-app reusable does NOT auto-merge (destruction = manual merge)" {
  # 주석 제외 후 실행 라인만 검사 — 워크플로 주석에 'auto-merge-or-fail' 설명 문구가 있어 그대로 grep하면 오탐
  run bash -c "grep -v '^[[:space:]]*#' '$WF/_teardown-app.yaml' | grep -q 'auto-merge-or-fail'"; [ "$status" -ne 0 ]
  run bash -c "grep -v '^[[:space:]]*#' '$WF/_teardown-app.yaml' | grep -qE 'gh pr merge.*--auto'"; [ "$status" -ne 0 ]
}

@test "every mutation reusable routes its PR through the pr-first-commit composite" {
  for wf in _create-app _create-database _create-cache _update-secrets _teardown-app; do
    grep -q 'uses: ./.github/actions/pr-first-commit' "$WF/$wf.yaml"
  done
}

@test "auto-merge policy is preserved per reusable (db/cache/secrets=true, app/teardown=false)" {
  for wf in _create-database _create-cache _update-secrets; do
    grep -qE "auto-merge:[[:space:]]*'true'" "$WF/$wf.yaml"
  done
  for wf in _create-app _teardown-app; do
    grep -qE "auto-merge:[[:space:]]*'false'" "$WF/$wf.yaml"
  done
}

@test "the bot commit identity lives only in the pr-first-commit composite (no 5x literal copies)" {
  a="$ROOT/.github/actions/pr-first-commit/action.yml"
  grep -q 'ukyi-homelab-writer\[bot\]' "$a"
  run grep -l '293311924+ukyi-homelab-writer' "$WF"/_create-app.yaml "$WF"/_create-database.yaml "$WF"/_create-cache.yaml "$WF"/_update-secrets.yaml "$WF"/_teardown-app.yaml
  [ "$status" -ne 0 ]
}

@test "reusables carry no inline RESOURCE_NAME_RE copy (identity.ts SSOT via validate-mutation)" {
  for wf in _create-cache _create-database; do
    run grep -Fq '{0,28}' "$WF/$wf.yaml"; [ "$status" -ne 0 ]
    grep -q 'validate-mutation.ts --action' "$WF/$wf.yaml"
  done
}

@test "every mutation reusable re-validates via validate-mutation at its boundary (symmetric defense-in-depth)" {
  for wf in _create-app _update-secrets _create-database _create-cache _teardown-app; do
    grep -q 'validate-mutation.ts --action' "$WF/$wf.yaml"
  done
}
