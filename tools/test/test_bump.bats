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

DIG="sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"

# 주의: 중간 assertion은 단순 명령 `[ ]`로 — bash 3.2의 set -e는 `[[ ]]`(compound command)
# 실패를 무시해 중간 실패가 조용히 통과한다 (macOS 기본 bash에서 검증된 함정).

@test "bump --digest records image.digest alongside the tag" {
  f="$FIX/apps/blog/deploy/prod/values.yaml"
  node tools/bump-tag.mjs blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  run yq '.image.digest' "$f"
  [ "$output" == "$DIG" ]
  # tag는 source SHA 추적용으로 함께 기록된다
  run yq '.image.tag' "$f"
  [ "$output" == "sha-deadbee" ]
}

@test "bump rejects a malformed digest with exit 2" {
  run node tools/bump-tag.mjs blog sha-deadbee --digest sha256:nothex --repo-root "$FIX"
  [ "$status" -eq 2 ]
}

@test "bump with same tag and digest is a no-op" {
  node tools/bump-tag.mjs blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  run node tools/bump-tag.mjs blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}

@test "tag-only bump removes a stale digest (image must follow the new tag)" {
  f="$FIX/apps/blog/deploy/prod/values.yaml"
  node tools/bump-tag.mjs blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  # digest 없이 tag만 bump하면 차트 helper가 stale digest를 계속 우선하므로 digest를 제거해야 한다
  node tools/bump-tag.mjs blog sha-feedbee --repo-root "$FIX"
  run yq '.image.digest' "$f"
  [ "$output" == "null" ]
  run yq '.image.tag' "$f"
  [ "$output" == "sha-feedbee" ]
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
