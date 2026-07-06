#!/usr/bin/env bats
# apps/<name>/deploy/prod 배포 계약 가드 — 필수 4산출물(values.yaml·.bindings.json·source-repo·
# kustomization.yaml) + source-repo 발견 계약. 인레포 배포앱 0개라 양성/음성 fixture로 체커를 검증. bash 3.2: 단언은 [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CHECK="$ROOT/scripts/check-app-deploy.sh"
}

# 봉인본 원본 바이트 sha256 앞 16자 — 게이트 재산출 규약(create-app/update-secrets와 동일)
sha16() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -c1-16; else sha256sum "$1" | cut -c1-16; fi; }

# apps/<app>/deploy/prod 레이아웃 fixture 생성(app 이름은 조부모 디렉토리명) — 4산출물 + 봉인본
make_app_fixture() {
  app="$1"; base="$BATS_TEST_TMPDIR/$2"; d="$base/$app/deploy/prod"; mkdir -p "$d"
  echo "{}" > "$d/.bindings.json"
  echo "ukyi-app/$app" > "$d/source-repo"
  printf 'resources:\n  - %s-secrets.sealed.yaml\n' "$app" > "$d/kustomization.yaml"
  printf 'kind: SealedSecret\nmetadata:\n  name: %s-secrets\nspec:\n  encryptedData:\n    FOO: AgABC\n' "$app" > "$d/$app-secrets.sealed.yaml"
  echo "$d"
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

@test "checksum gate: matching checksum passes (sha256(sealed raw bytes) == values checksum/secrets)" {
  d="$(make_app_fixture myapp match)"
  want="$(sha16 "$d/myapp-secrets.sealed.yaml")"
  printf 'image: {}\npodAnnotations:\n  checksum/secrets: %s\n' "$want" > "$d/values.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -eq 0 ]
}

@test "checksum gate: mismatched checksum fails (re-sealed without bumping checksum = #277 regression)" {
  d="$(make_app_fixture myapp mismatch)"
  printf 'image: {}\npodAnnotations:\n  checksum/secrets: deadbeefdeadbeef\n' > "$d/values.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '불일치'
}

@test "checksum gate: sealed present but no checksum/secrets fails (secret change would not roll the pod)" {
  d="$(make_app_fixture myapp nochecksum)"
  echo "image: {}" > "$d/values.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'checksum/secrets 없음'
}

@test "checksum gate: comment lines above checksum/secrets are tolerated (trip-mate-api layout)" {
  # trip-mate-api values.yaml은 podAnnotations와 checksum 사이에 한국어 주석 3줄 — sed 추출이 이를 건너뛰어야 한다.
  d="$(make_app_fixture myapp comments)"
  want="$(sha16 "$d/myapp-secrets.sealed.yaml")"
  printf 'image: {}\npodAnnotations:\n  # 재봉인 주석 1\n  # 재봉인 주석 2\n  checksum/secrets: %s\n' "$want" > "$d/values.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -eq 0 ]
}

@test "checksum gate: no sealed file means no checksum requirement (secretless app passes)" {
  d="$BATS_TEST_TMPDIR/plain/app/deploy/prod"; mkdir -p "$d"
  echo "image: {}" > "$d/values.yaml"
  echo "{}" > "$d/.bindings.json"
  echo "ukyi-app/app" > "$d/source-repo"
  echo "resources: []" > "$d/kustomization.yaml"
  run bash "$CHECK" "$d"
  [ "$status" -eq 0 ]
}
