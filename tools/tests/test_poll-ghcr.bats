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
