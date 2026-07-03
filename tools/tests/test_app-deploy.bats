#!/usr/bin/env bats
# apps/<name>/deploy/prod 배포 계약 가드 — 필수 4산출물(values.yaml·.bindings.json·source-repo·
# kustomization.yaml) + source-repo 발견 계약. 인레포 배포앱 0개라 양성/음성 fixture로 체커를 검증. bash 3.2: 단언은 [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CHECK="$ROOT/scripts/check-app-deploy.sh"
}

@test "check-app-deploy passes on the real tree (in-repo deploy apps vacuously satisfy contract)" {
  run bash "$CHECK"
  [ "$status" -eq 0 ]
}

@test "positive fixture: deploy/prod with all 4 artifacts passes" {
  d="$BATS_TEST_TMPDIR/app/deploy/prod"; mkdir -p "$d"
  echo "image: {}" > "$d/values.yaml"
  echo "{}" > "$d/.bindings.json"
  echo "ukyi-app/myapp" > "$d/source-repo"
  echo "resources: []" > "$d/kustomization.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -eq 0 ]
}

@test "negative fixture: missing source-repo fails (poll-ghcr would never discover the app)" {
  d="$BATS_TEST_TMPDIR/bad/deploy/prod"; mkdir -p "$d"
  echo "image: {}" > "$d/values.yaml"
  echo "{}" > "$d/.bindings.json"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'source-repo'
}

@test "negative fixture: empty source-repo fails" {
  d="$BATS_TEST_TMPDIR/empty/deploy/prod"; mkdir -p "$d"
  echo "image: {}" > "$d/values.yaml"
  echo "{}" > "$d/.bindings.json"
  : > "$d/source-repo"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
}

@test "negative fixture: missing kustomization.yaml fails (appset kustomize render needs it)" {
  d="$BATS_TEST_TMPDIR/nokust/deploy/prod"; mkdir -p "$d"
  echo "image: {}" > "$d/values.yaml"
  echo "{}" > "$d/.bindings.json"
  echo "ukyi-app/myapp" > "$d/source-repo"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'kustomization.yaml'
}

@test "app-deploy .bindings.json contract is autoDeploy-centric (db/redis dropped)" {
  # 연결=SealedSecret 이후 .bindings.json은 autoDeploy만 기록 — 계약 설명에서 db/redis 제거 회귀 가드.
  # 단일 run+status로 검사(bats는 마지막 명령만 평가하므로 중간 grep 단언은 함정).
  run jq -e '.properties.".bindings.json".description | test("autoDeploy") and (test("db/redis") | not)' \
    "$ROOT/tools/app-deploy-schema.json"
  [ "$status" -eq 0 ]
}

@test "poll-ghcr discovers apps by source-repo (contract: missing source-repo = never polled)" {
  run grep -nE 'source-repo' "$ROOT/tools/poll-ghcr.ts"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'continue'
}
