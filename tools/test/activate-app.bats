#!/usr/bin/env bats
# activate-app 게이트 — 노출할 revision을 고정 검증한 뒤에만 apps.json active를 플립한다.
# moving-main 안전: synced가 sha의 descendant + 그 사이 이 앱 표면 무변경 + 행 동일성.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  A="$ROOT/tools/activate-app.mjs"
  TMP="$(mktemp -d)"
  R="$TMP/repo"
  mkdir -p "$R"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t && git -C "$R" config user.name t
  mkdir -p "$R/infra/cloudflare" "$R/apps/orders/deploy/prod" "$R/platform/charts/app"
  cat > "$R/infra/cloudflare/apps.json" <<'EOF'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": false }
]
EOF
  echo "v1" > "$R/apps/orders/deploy/prod/values.yaml"
  echo "chart" > "$R/platform/charts/app/Chart.yaml"
  git -C "$R" add -A && git -C "$R" commit -qm "merge: orders 등록"
  SHA="$(git -C "$R" rev-parse HEAD)"
  # 정상 status 픽스처 (kubectl -o json 모양)
  cat > "$TMP/status.json" <<'EOF'
{
  "application": { "status": { "sync": { "status": "Synced" }, "health": { "status": "Healthy" } } },
  "httproute": { "status": { "parents": [ { "conditions": [
    { "type": "Accepted", "status": "True" },
    { "type": "ResolvedRefs", "status": "True" }
  ] } ] } }
}
EOF
}
teardown() { rm -rf "$TMP"; }

@test "activates when synced rev equals the requested merge sha and status healthy" {
  run node "$A" --app orders --sha "$SHA" --synced-rev "$SHA" \
    --repo-dir "$R" --status-file "$TMP/status.json" --flip
  [ "$status" -eq 0 ]
  run jq -e '.[0].active == true' "$R/infra/cloudflare/apps.json"
  [ "$status" -eq 0 ]
}

@test "accepts a synced rev that is a descendant with unrelated changes only" {
  echo "x" > "$R/README.md" && git -C "$R" add -A && git -C "$R" commit -qm "docs: 무관 변경"
  SYNCED="$(git -C "$R" rev-parse HEAD)"
  run node "$A" --app orders --sha "$SHA" --synced-rev "$SYNCED" \
    --repo-dir "$R" --status-file "$TMP/status.json"
  [ "$status" -eq 0 ]
}

@test "rejects when synced rev is not a descendant of the merge sha" {
  git -C "$R" checkout -qb side "$SHA"
  echo "y" > "$R/side.txt" && git -C "$R" add -A && git -C "$R" commit -qm "side"
  SIDE="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" checkout -q main
  echo "z" > "$R/main.txt" && git -C "$R" add -A && git -C "$R" commit -qm "ahead"
  AHEAD="$(git -C "$R" rev-parse HEAD)"
  # synced(side)는 AHEAD의 조상이 아니고 AHEAD도 side의 조상이 아님 → 거부
  run node "$A" --app orders --sha "$AHEAD" --synced-rev "$SIDE" \
    --repo-dir "$R" --status-file "$TMP/status.json"
  [ "$status" -ne 0 ]
}

@test "rejects when the app surface changed between sha and synced (over-approval)" {
  echo "v2" > "$R/apps/orders/deploy/prod/values.yaml"
  git -C "$R" add -A && git -C "$R" commit -qm "chore: orders bump"
  SYNCED="$(git -C "$R" rev-parse HEAD)"
  run node "$A" --app orders --sha "$SHA" --synced-rev "$SYNCED" \
    --repo-dir "$R" --status-file "$TMP/status.json"
  [ "$status" -ne 0 ]
}

@test "rejects when the apps.json row drifted from the approved sha (host change)" {
  jq '.[0].host = "evil.example.com"' "$R/infra/cloudflare/apps.json" > "$R/infra/cloudflare/apps.json.new"
  mv "$R/infra/cloudflare/apps.json.new" "$R/infra/cloudflare/apps.json"
  # 워크트리 행이 승인 SHA의 행과 다름 (커밋 없이도 거부돼야 한다 — 비교는 worktree 기준)
  run node "$A" --app orders --sha "$SHA" --synced-rev "$SHA" \
    --repo-dir "$R" --status-file "$TMP/status.json"
  [ "$status" -ne 0 ]
}

@test "rejects when application is not Healthy or route not Accepted" {
  jq '.application.status.health.status = "Degraded"' "$TMP/status.json" > "$TMP/bad.json"
  run node "$A" --app orders --sha "$SHA" --synced-rev "$SHA" \
    --repo-dir "$R" --status-file "$TMP/bad.json"
  [ "$status" -ne 0 ]
  jq '.httproute.status.parents[0].conditions[0].status = "False"' "$TMP/status.json" > "$TMP/bad2.json"
  run node "$A" --app orders --sha "$SHA" --synced-rev "$SHA" \
    --repo-dir "$R" --status-file "$TMP/bad2.json"
  [ "$status" -ne 0 ]
}
