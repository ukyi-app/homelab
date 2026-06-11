#!/usr/bin/env bats
WF=".github/workflows/bump.yaml"

# 인-레포 앱이 없으므로(앱은 외부 레포 체제) fixture root에 임시 앱 values를 만들어 테스트한다.
setup() {
  FIX="$(mktemp -d)"
  mkdir -p "$FIX/apps/blog/deploy/prod"
  cat > "$FIX/apps/blog/deploy/prod/values.yaml" <<'EOF'
image:
  repo: ghcr.io/ukyi-app/blog
  tag: sha-0000000
kind: api
EOF
}
teardown() { rm -rf "$FIX"; }

@test "bump rewrites only image.tag in the app's values.yaml" {
  f="$FIX/apps/blog/deploy/prod/values.yaml"
  before=$(yq '.kind' "$f")
  node tools/bump-tag.mjs blog sha-deadbee --repo-root "$FIX"
  run yq '.image.tag' "$f"
  [[ "$output" == "sha-deadbee" ]]
  after=$(yq '.kind' "$f")
  [ "$before" == "$after" ] # 그 외에는 아무것도 안 바뀜
}

@test "bump is idempotent (second run is a no-op)" {
  node tools/bump-tag.mjs blog sha-deadbee --repo-root "$FIX"
  run node tools/bump-tag.mjs blog sha-deadbee --repo-root "$FIX"
  [[ "$output" == *"no-op"* || "$output" == *"unchanged"* ]]
}

@test "bump refuses path traversal outside apps/" {
  run node tools/bump-tag.mjs ../../etc sha-deadbee --repo-root "$FIX"
  [ "$status" -ne 0 ]
}

@test "bump workflow is serialized via a single concurrency group" {
  run yq '.concurrency.group' "$WF"
  [ -n "$output" ]
  run yq '.concurrency.cancel-in-progress' "$WF"
  [[ "$output" == "false" ]] # 반쯤 끝난 write-back은 절대 취소하지 않는다
}
