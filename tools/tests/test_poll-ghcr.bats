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

run_poll() { run bun "$P" --root "$TMP" --fixtures "$FX"; }

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

@test "an app directory without source-repo is not polled at all (discovery is binding-gated — behavioural witness)" {
  # 발견 계약의 행동 증인(정적 grep 증인의 짝) — source-repo 바인딩이 없는 앱은 plan에 아예 없어야
  # 하고, 있는 앱은 있어야 한다(양성 대조 — 열거 자체가 붕괴한 vacuous green 차단).
  mkdir -p "$TMP/apps/unbound/deploy/prod"
  printf 'image:\n  repo: ghcr.io/ukyi-app/unbound\n  tag: sha-aaa1111000000000000000000000000000000000\n' > "$TMP/apps/unbound/deploy/prod/values.yaml"
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.[] | select(.target.name=="unbound")] | length == 0'
  echo "$output" | jq -e '[.[] | select(.target.name=="orders")] | length == 1'
}

@test "an app without bindings but with a same-name platform pin is refused (cross-kind identity, no lane borrowing)" {
  # 03 Comments ④의 무테스트 분기 — planApp의 resolveLane이 이름을 bespoke로 해소하면(바인딩 부재 +
  # 동명 .image-pin.json 실재) 그 이름의 apps 레인은 어느 인가도 빌려 쓰지 못하고 refuse여야 한다.
  rm -f "$D/.bindings.json"
  PD="$TMP/platform/orders/prod"; mkdir -p "$PD"
  printf '{ "file": "deployment.yaml", "path": ["a"], "autoDeploy": true }\n' > "$PD/.image-pin.json"
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.target.name=="orders" and .target.kind=="app") | .action == "refuse"'
  echo "$output" | jq -e '.[] | select(.target.name=="orders" and .target.kind=="app") | .reason | test("신원|bespoke")'
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
  run bun "$P" --root "$TMP" --fixtures "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.target.name=="files") | .action == "bump"'
  echo "$output" | jq -e '.[] | select(.target.name=="files") | .pin == "platform/files/prod/.image-pin.json"'
  echo "$output" | jq -e '.[] | select(.target.name=="files") | .writePath == "platform/files/prod/deployment.yaml"'
  echo "$output" | jq -e '.[] | select(.target.name=="files") | .candidate.tag == "sha-bbb2222000000000000000000000000000000000"'
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
  run bun "$P" --root "$TMP" --fixtures "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.target.name=="files") | .action == "propose-pr"'
}

# ── 라이브 분기(--fixtures 부재) 증인 — seam 이관 코드(gh api·docker inspect)가 실제로 도는 유일한
# 경로다. 위 픽스처 테스트들은 makeQuery의 fixtures 분기에서 early return하므로 이관 코드를 한 줄도
# 밟지 않는다(d6② 동작 등가는 여기서만 실증된다). PATH stub이 원격을 대신한다.
live_stubs() {
  S="$BATS_TEST_TMPDIR/livebin"; mkdir -p "$S"
  cat > "$S/gh" <<'GH'
#!/bin/sh
[ -n "${GH_FAIL:-}" ] && { echo "gh: api 실패(주입 — 인증/네트워크)" >&2; exit 1; }
case "$2" in
  repos/*/commits*) printf '[ { "sha": "bbb2222000000000000000000000000000000000" }, { "sha": "aaa1111000000000000000000000000000000000" } ]' ;;
  repos/*/compare/*) printf '{ "status": "ahead", "ahead_by": 1 }' ;;
  *) echo "stub gh: 예상치 못한 호출: $*" >&2; exit 3 ;;
esac
GH
  cat > "$S/docker" <<'DK'
#!/bin/sh
case "${DOCKER_MODE:-ok}" in
  notfound)  echo "ERROR: ghcr.io/ukyi-app/orders:sha-bbb2222...: not found" >&2; exit 1 ;;
  transient) echo "received unexpected HTTP status: 500 Internal Server Error" >&2; exit 1 ;;
  ok)        printf '{"digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"}' ;;
esac
DK
  chmod +x "$S/gh" "$S/docker"
}

@test "live branch: the seam-routed gh/docker path yields the same bump verdict as the fixtures path" {
  live_stubs
  run env PATH="$S:$PATH" DOCKER_MODE=ok bun "$P" --root "$TMP"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "bump"'
  echo "$output" | jq -e '.[0].candidate.digest == "sha256:2222222222222222222222222222222222222222222222222222222222222222"'
}

@test "live branch: a genuine not-found on stderr is image-absent (noop), reading the seam's captured err" {
  # 종전 execFileSync는 e.stderr∪e.message 두 입력을 봤다 — seam 이관 후엔 r.err(trim된 stderr) 하나다.
  # docker의 실제 실패 표면(stderr)이 isNotFound에 그대로 걸리는지를 라이브 분기로 실증한다.
  live_stubs
  run env PATH="$S:$PATH" DOCKER_MODE=notfound bun "$P" --root "$TMP"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "noop"'
  echo "$output" | jq -e '.[0].reason | test("빌드된 main 커밋 없음")'
}

@test "live branch: a transient docker failure refuses (never swallowed as absent) through the seam" {
  live_stubs
  run env PATH="$S:$PATH" DOCKER_MODE=transient bun "$P" --root "$TMP"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "refuse"'
  echo "$output" | jq -e '.[0].reason | test("transient|일시")'
}

@test "live branch: a gh api failure folds to refuse via the planner's outer catch (fail-closed preserved)" {
  live_stubs
  run env PATH="$S:$PATH" GH_FAIL=1 bun "$P" --root "$TMP"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].action == "refuse"'
  echo "$output" | jq -e '.[0].reason | test("플랜 실패")'
}
