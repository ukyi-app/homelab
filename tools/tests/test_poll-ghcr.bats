#!/usr/bin/env bats
# GHCR 폴링 bump 플래너 — 신뢰 경계: source-repo 바인딩 + GitHub/GHCR 사실만.
# 앱 레포가 보낸 어떤 payload도 입력으로 받지 않는다. main 커밋 순서가 권위(후진 배포 차단).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  P="$ROOT/tools/poll-ghcr.ts"
  TMP="$(mktemp -d)"
  D="$TMP/apps/orders/deploy/prod"
  FX="$TMP/fx"
  mkdir -p "$D" "$FX"
  printf 'ukyi-app/orders' > "$D/source-repo"
  cat > "$D/values.yaml" <<'EOF'
image:
  repo: ghcr.io/ukyi-app/orders
  tag: sha-aaa1111000000000000000000000000000000000
  digest: sha256:1111111111111111111111111111111111111111111111111111111111111111
EOF
  cat > "$D/.bindings.json" <<'EOF'
{ "db": [], "redis": [], "autoDeploy": true }
EOF
  # 픽스처: main 커밋(최신순), compare, manifest(digest)
  cat > "$FX/orders.commits.json" <<'EOF'
[ { "sha": "bbb2222000000000000000000000000000000000" }, { "sha": "aaa1111000000000000000000000000000000000" } ]
EOF
  cat > "$FX/orders.compare-aaa1111-main.json" <<'EOF'
{ "status": "ahead", "ahead_by": 1 }
EOF
  cat > "$FX/orders.compare-aaa1111-bbb2222.json" <<'EOF'
{ "status": "ahead", "ahead_by": 1 }
EOF
  cat > "$FX/orders.manifest-sha-bbb2222.json" <<'EOF'
{ "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222" }
EOF
}
teardown() { rm -rf "$TMP"; }

run_poll() { run bun "$P" --root "$TMP" --fixtures "$FX" --dry-run; }

@test "autoDeploy true app with a newer eligible main commit becomes a bump with digest" {
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "bump"'
  echo "$output" | jq -e '.[0].candidate.digest == "sha256:2222222222222222222222222222222222222222222222222222222222222222"'
  echo "$output" | jq -e '.[0].candidate.tag == "sha-bbb2222000000000000000000000000000000000"'
}

@test "autoDeploy false app is only ever a PR candidate (approval gate preserved)" {
  cat > "$D/.bindings.json" <<'EOF'
{ "db": [], "redis": [], "autoDeploy": false }
EOF
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "propose-pr"'
}

@test "missing autoDeploy (or bindings file) is fail-closed: PR candidate, never auto bump" {
  rm -f "$D/.bindings.json"
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "propose-pr"'
}

@test "noop when the newest main commit is already deployed" {
  cat > "$FX/orders.commits.json" <<'EOF'
[ { "sha": "aaa1111000000000000000000000000000000000" } ]
EOF
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "noop"'
}

@test "refuses when deployed sha is not an ancestor of main (non-fast-forward guard)" {
  cat > "$FX/orders.compare-aaa1111-main.json" <<'EOF'
{ "status": "diverged", "ahead_by": 0 }
EOF
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "refuse"'
}

@test "commit without a built image is skipped (older eligible commit wins)" {
  rm -f "$FX/orders.manifest-sha-bbb2222.json"
  cat > "$FX/orders.commits.json" <<'EOF'
[ { "sha": "ccc3333000000000000000000000000000000000" },
  { "sha": "bbb2222000000000000000000000000000000000" },
  { "sha": "aaa1111000000000000000000000000000000000" } ]
EOF
  cat > "$FX/orders.compare-aaa1111-ccc3333.json" <<'EOF'
{ "status": "ahead", "ahead_by": 2 }
EOF
  cat > "$FX/orders.manifest-sha-ccc3333.json" <<'EOF'
{ "digest": "sha256:3333333333333333333333333333333333333333333333333333333333333333" }
EOF
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].candidate.tag == "sha-ccc3333000000000000000000000000000000000"'
}

@test "same digest resolves to noop (idempotent poll)" {
  cat > "$FX/orders.manifest-sha-bbb2222.json" <<'EOF'
{ "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111" }
EOF
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "noop"'
}

@test "source-repo outside ukyi-app org is refused" {
  printf 'evil/orders' > "$D/source-repo"
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "refuse"'
}

@test "refuses when values image.repo does not match the source-repo binding (cross-repo guard)" {
  # source-repo=ukyi-app/orders인데 values가 다른 레포 이미지를 가리키면 다른 레포를 폴링/bump하게 되므로 거부.
  cat > "$D/values.yaml" <<'EOF'
image:
  repo: ghcr.io/ukyi-app/evil
  tag: sha-aaa1111000000000000000000000000000000000
  digest: sha256:1111111111111111111111111111111111111111111111111111111111111111
EOF
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "refuse"'
  echo "$output" | jq -e '.[0].reason | test("image.repo|불일치")'
}

@test "refuses when the candidate is not a descendant of the deployed sha (non-fast-forward re-verification)" {
  # 배포 SHA는 main 조상(baseCmp ahead)이지만, 후보(bbb2222)를 배포 SHA 기준으로 재비교하면 diverged →
  # merge 목록 비선형성 방어 재증명(candCmp)이 refuse해야 한다.
  cat > "$FX/orders.compare-aaa1111-bbb2222.json" <<'EOF'
{ "status": "diverged", "ahead_by": 0 }
EOF
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "refuse"'
  echo "$output" | jq -e '.[0].reason | test("descendant")'
}

@test "noop when the deployed sha is identical to main tip (already at HEAD)" {
  # baseCmp(deployed..main)=identical → 후보 탐색 없이 noop(멱등).
  cat > "$FX/orders.compare-aaa1111-main.json" <<'EOF'
{ "status": "identical", "ahead_by": 0 }
EOF
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "noop"'
  echo "$output" | jq -e '.[0].reason | test("tip")'
}

@test "a transient imagetools error (not a genuine 404) refuses instead of treating image as absent" {
  # bbb2222 manifest를 transient 오류로 표시 — 진짜 404가 아니므로 'absent'로 삼키면 안 되고 refuse여야.
  rm -f "$FX/orders.manifest-sha-bbb2222.json"
  cat > "$FX/orders.manifest-sha-bbb2222.error.json" <<'JSON'
{ "message": "received unexpected HTTP status: 500 Internal Server Error" }
JSON
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "refuse"'
  echo "$output" | jq -e '.[0].reason | test("manifest|transient|일시")'
}

@test "a genuine manifest-unknown 404 is still treated as image absent (not built)" {
  rm -f "$FX/orders.manifest-sha-bbb2222.json"
  cat > "$FX/orders.manifest-sha-bbb2222.error.json" <<'JSON'
{ "message": "ghcr.io/ukyi-app/orders:sha-bbb...: not found" }
JSON
  run_poll
  [ "$status" -eq 0 ]
  # 404는 absent → 후보 없음(noop), refuse 아님
  echo "$output" | jq -e '.[0].action == "noop"'
}

# RED(red-capture): 중복 bump PR 버그의 회귀 락.
# bump-poll.yaml은 run마다 새 브랜치(bump-poll/<app>-<RUN_ID>)로 PR을 열고, 플래너는 "GHCR 최신 vs
# main의 배포 핀"만 본다 — PR이 머지되기 전엔 main이 여전히 옛 digest라 매 주기 bump로 판정한다.
# 라이브: 같은 커밋(page sha-815abb…)에 11분간 PR 3개(#348/#350/#353) → 1개만 머지, 나머지는 충돌 잔류.
# 기대(수정 후): 같은 후보(app+tag/digest)를 제안 중인 열린 PR이 있으면 noop + reason에 PR 번호.
# bats test_tags=regression
@test "an open bump PR proposing the same candidate suppresses the duplicate bump (dedupe)" {
  cat > "$FX/orders.open-prs.json" <<'EOF'
[ { "number": 350,
    "tag": "sha-bbb2222000000000000000000000000000000000",
    "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222" } ]
EOF
  run_poll
  [ "$status" -eq 0 ]
  # 플래너가 그 사실을 관측은 했는지(데이터 소스 배선 확인) — 배선이 죽었다면 버그가 아니라 하네스 결함이다.
  echo "$output" | jq -e '.[0].openPrs[0].number == 350' > /dev/null \
    || { echo "harness: planner never observed the open PR fact (openPrs 배선 확인)"; echo "$output"; false; }
  # ⚠️ bash 3.2: 중간 복합 단언은 침묵 통과 → 한 줄씩 명시적으로 실패시킨다.
  action="$(echo "$output" | jq -r '.[0].action')"
  case "$action" in
    noop|skip) ;;
    *) echo "duplicate bump PR: planner still says '$action' while PR #350 already proposes the same candidate (app=orders tag=sha-bbb2222…)"
       echo "--- plan ---"; echo "$output"
       false ;;
  esac
  reason="$(echo "$output" | jq -r '.[0].reason')"
  echo "$reason" | grep -q "350" \
    || { echo "duplicate bump PR: reason must name the existing PR number (#350) — got: '$reason'"; false; }
}

@test "an open bump PR proposing a different candidate still allows a new bump (dedupe is candidate-scoped)" {
  # 보존 계약: 중복 억제는 "같은 후보"에만 걸린다 — 진짜 새 후보는 계속 PR을 연다.
  cat > "$FX/orders.open-prs.json" <<'EOF'
[ { "number": 349,
    "tag": "sha-999aaaa000000000000000000000000000000000",
    "digest": "sha256:9999999999999999999999999999999999999999999999999999999999999999" } ]
EOF
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "bump"'
  echo "$output" | jq -e '.[0].candidate.tag == "sha-bbb2222000000000000000000000000000000000"'
}

@test "no open bump PR leaves the planner at bump (dedupe fact defaults to empty)" {
  # 배선이 기본값(빈 목록)에서 기존 판정을 건드리지 않음을 고정 — open-prs 픽스처 없음 = 열린 제안 0.
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "bump"'
  echo "$output" | jq -e '.[0].openPrs == []'
}

@test "a bespoke platform component (image-pin descriptor) joins the bump lane with pin+writePath" {
  PD="$TMP/platform/files/prod"; mkdir -p "$PD"
  printf 'ukyi-app/files' > "$PD/source-repo"
  cat > "$PD/.image-pin.json" <<'JSON'
{ "file": "deployment.yaml", "path": ["spec","template","spec","containers",0,"image"], "autoDeploy": true }
JSON
  cat > "$PD/deployment.yaml" <<'YAML'
spec:
  template:
    spec:
      containers:
        - name: files
          image: ghcr.io/ukyi-app/files:sha-aaa1111000000000000000000000000000000000@sha256:1111111111111111111111111111111111111111111111111111111111111111
YAML
  cat > "$FX/files.commits.json" <<'EOF'
[ { "sha": "bbb2222000000000000000000000000000000000" }, { "sha": "aaa1111000000000000000000000000000000000" } ]
EOF
  printf '{ "status": "ahead", "ahead_by": 1 }\n' > "$FX/files.compare-aaa1111-main.json"
  printf '{ "status": "ahead", "ahead_by": 1 }\n' > "$FX/files.compare-aaa1111-bbb2222.json"
  printf '{ "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222" }\n' > "$FX/files.manifest-sha-bbb2222.json"
  run bun "$P" --root "$TMP" --fixtures "$FX" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.app=="files") | .action == "bump"'
  echo "$output" | jq -e '.[] | select(.app=="files") | .pin == "platform/files/prod/.image-pin.json"'
  echo "$output" | jq -e '.[] | select(.app=="files") | .writePath == "platform/files/prod/deployment.yaml"'
  echo "$output" | jq -e '.[] | select(.app=="files") | .candidate.tag == "sha-bbb2222000000000000000000000000000000000"'
}

@test "bespoke descriptor without autoDeploy is fail-closed (propose-pr, never auto bump)" {
  PD="$TMP/platform/files/prod"; mkdir -p "$PD"
  printf 'ukyi-app/files' > "$PD/source-repo"
  printf '{ "file": "deployment.yaml", "path": ["spec","template","spec","containers",0,"image"] }\n' > "$PD/.image-pin.json"
  cat > "$PD/deployment.yaml" <<'YAML'
spec:
  template:
    spec:
      containers:
        - name: files
          image: ghcr.io/ukyi-app/files:sha-aaa1111000000000000000000000000000000000@sha256:1111111111111111111111111111111111111111111111111111111111111111
YAML
  cat > "$FX/files.commits.json" <<'EOF'
[ { "sha": "bbb2222000000000000000000000000000000000" }, { "sha": "aaa1111000000000000000000000000000000000" } ]
EOF
  printf '{ "status": "ahead", "ahead_by": 1 }\n' > "$FX/files.compare-aaa1111-main.json"
  printf '{ "status": "ahead", "ahead_by": 1 }\n' > "$FX/files.compare-aaa1111-bbb2222.json"
  printf '{ "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222" }\n' > "$FX/files.manifest-sha-bbb2222.json"
  run bun "$P" --root "$TMP" --fixtures "$FX" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.app=="files") | .action == "propose-pr"'
}
