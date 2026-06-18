#!/usr/bin/env bats
# audit-orphans — registry/매니페스트/바인딩/원장 교차 드리프트 리포트 (읽기 전용)
# ⚠️ 중간 단언은 [ ]만 사용 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
  FR="$TMP/repo"
  mkdir -p "$FR/apps/orders/deploy/prod" "$FR/infra/cloudflare" "$FR/docs" \
    "$FR/platform/cnpg/prod/databases" "$FR/platform/data-conn/prod" "$FR/platform/cache/prod"
  printf 'image: {repo: x, tag: sha-abc1234}\nroute: {public: true, host: orders.example.com}\n' \
    > "$FR/apps/orders/deploy/prod/values.yaml"
  echo '{"db":["shared"],"redis":[],"autoDeploy":true}' > "$FR/apps/orders/deploy/prod/.bindings.json"
  cat > "$FR/infra/cloudflare/apps.json" <<'EOF'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "ghost", "host": "ghost.example.com", "public": true, "active": true }
]
EOF
  cat > "$FR/docs/memory-ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->
| <!-- ledger:row --> orders | prod | 64 | 128 |
| <!-- ledger:row --> stale-app | prod | 64 | 128 |
EOF
  printf 'kind: Database\n' > "$FR/platform/cnpg/prod/databases/shared.yaml"
  touch "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml"
  printf 'kind: Database\n' > "$FR/platform/cnpg/prod/databases/lonely.yaml"
  touch "$FR/platform/data-conn/prod/db-lonely-conn.sealed.yaml"
}
teardown() { rm -rf "$TMP"; }

@test "audit reports an active registry row whose app manifests are gone (orphan dns)" {
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "orphan-dns" and .subject == "ghost")'
}

@test "audit reports dangling bindings (db ref without provisioned artifacts)" {
  echo '{"db":["missing"],"redis":[],"autoDeploy":true}' > "$FR/apps/orders/deploy/prod/.bindings.json"
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "dangling-binding" and .subject == "orders→db:missing")'
}

@test "audit reports unreferenced resources as retained candidates (informational)" {
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "unreferenced-resource" and .subject == "db:lonely")'
}

@test "audit reports stale ledger rows (prod row without app dir)" {
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "stale-ledger-row" and .subject == "stale-app")'
}

@test "audit --ci blocks orphan-dns but passes stale-ledger and unreferenced (no false PR block)" {
  # 픽스처엔 orphan-dns(ghost)+stale-ledger-row(stale-app)+unreferenced(db:lonely)가 있다 →
  # --ci는 orphan-dns(ghost)가 blocking이므로 비-0
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --ci
  [ "$status" -ne 0 ]
  # ghost(orphan-dns)만 제거 — stale-app(원장 드리프트)·db:lonely는 남긴다(둘 다 non-blocking)
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$FR/infra/cloudflare/apps.json"
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --ci
  [ "$status" -eq 0 ]   # stale-ledger-row(stale-app)·unreferenced가 남아도 --ci는 통과
  echo "$output" | jq -e '.findings | any(.type == "stale-ledger-row")'
}

@test "audit --ci blocks a dangling db binding (missing Secret at deploy)" {
  mkdir -p "$FR/apps/orders/deploy/prod"
  printf 'image: {repo: x, tag: sha-abc1234}\n' > "$FR/apps/orders/deploy/prod/values.yaml"
  echo '{"db":["nonexistent"],"redis":[],"autoDeploy":true}' > "$FR/apps/orders/deploy/prod/.bindings.json"
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --ci
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "dangling-binding"
}

@test "audit --strict exits nonzero when findings exist, zero when clean" {
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --strict
  [ "$status" -ne 0 ]
  # ghost 행/stale 행/lonely 제거 → clean. active 앱은 valid .activation 마커가 있어야 clean(races-5 불변식).
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$FR/infra/cloudflare/apps.json"
  printf '{"app":"orders","sha":"abc1234","surfaceHash":"seed","registry":{"name":"orders","host":"orders.example.com","public":true}}\n' \
    > "$FR/apps/orders/deploy/prod/.activation"
  sed -i '' '/stale-app/d' "$FR/docs/memory-ledger.md" 2>/dev/null || sed -i '/stale-app/d' "$FR/docs/memory-ledger.md"
  rm "$FR/platform/cnpg/prod/databases/lonely.yaml" "$FR/platform/data-conn/prod/db-lonely-conn.sealed.yaml"
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --strict
  [ "$status" -eq 0 ]
}

@test "audit REPORTS surface drift for an active app changed after activation (informational, non-blocking)" {
  # active:true + .activation 마커(옛 tree-hash) + 그 후 apps/<app> 표면 변경 → drift.
  # git repo로 tree-hash를 계산한다(마커 포맷과 동일 알고리즘).
  G="$TMP/git"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  git -C "$G" add -A; git -C "$G" commit -qm init
  oldhash=$(bun "$ROOT/tools/lib/surface-hash.ts" "$G" HEAD orders)  # .activation 제외 canonical
  printf '{"app":"orders","sha":"abc1234","syncedRev":"abc1234","surfaceHash":"%s"}\n' "$oldhash" \
    > "$G/apps/orders/deploy/prod/.activation"
  # 마커 기록 후 표면 변경
  printf 'image: {repo: x, tag: sha-NEW9999}\nroute: {public: true, host: orders.example.com}\n' \
    > "$G/apps/orders/deploy/prod/values.yaml"
  git -C "$G" add -A; git -C "$G" commit -qm "surface change post-activation"
  # apps.json: orders만 active:true (ghost 제거해 orphan-dns 노이즈 배제)
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  # ⚠️ codex pass3 F1: surface-drift는 정보성 — --ci를 막지 않는다(정상 bump 데드락 방지). 리포트는 된다.
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$G" --ci
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "activation-surface-drift"
}

@test "audit does NOT flag an active app whose surface matches AFTER the .activation marker is committed (F3 regression)" {
  G="$TMP/git2"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  git -C "$G" add -A; git -C "$G" commit -qm init
  # ⚠️ codex pass1 F3: canonical surfaceHash(.activation 제외)로 마커를 만들고 .activation을 **커밋**한다.
  # 커밋이 apps/orders 트리를 바꿔도 canonical 해시는 불변이라 drift가 없어야 한다(자기 무효화 회귀).
  curhash=$(bun "$ROOT/tools/lib/surface-hash.ts" "$G" HEAD orders)
  printf '{"app":"orders","sha":"abc1234","syncedRev":"abc1234","surfaceHash":"%s"}\n' "$curhash" \
    > "$G/apps/orders/deploy/prod/.activation"
  git -C "$G" add -A; git -C "$G" commit -qm "activate orders (+.activation marker)"
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$G"
  [ "$status" -eq 0 ]
  run sh -c 'echo "$1" | grep -c activation-surface-drift' _ "$output"
  [ "$output" -eq 0 ]
}

@test "audit REPORTS missing-activation for an active app with no marker but does NOT block (F1 non-blocking)" {
  # ⚠️ codex pass3 F1: 마커 없음은 정보성 missing-activation — --ci를 막지 않는다(정상 active-app 데드락 방지).
  G="$TMP/git3"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  rm -f "$G/apps/orders/deploy/prod/.activation"
  git -C "$G" add -A; git -C "$G" commit -qm init
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$G" --ci
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "missing-activation"
}

@test "an inactive (active:false) orphan row is non-blocking info, not orphan-dns" {
  # dns.tf는 public && active만 노출 — active:false orphan은 DNS를 노출하지 않으므로 PR을 막으면 안 된다.
  cat > "$FR/infra/cloudflare/apps.json" <<'JSON'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "pending-app", "host": "pending.example.com", "public": true, "active": false }
]
JSON
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --ci
  [ "$status" -eq 0 ]   # active:false orphan은 비차단 → --ci 통과
  # 비차단 정보 유형으로 보고는 된다(가시성 유지)
  echo "$output" | jq -e '.findings | any(.type == "orphan-dns-inactive" and .subject == "pending-app")'
  # 차단 유형(orphan-dns)으로는 잡히지 않는다
  run bash -c "node '$ROOT/tools/audit-orphans.mjs' --repo-root '$FR' | jq -e '.findings | any(.type == \"orphan-dns\" and .subject == \"pending-app\")'"
  [ "$status" -ne 0 ]
}

@test "an active:true orphan row is still blocking under --ci" {
  cat > "$FR/infra/cloudflare/apps.json" <<'JSON'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "ghost", "host": "ghost.example.com", "public": true, "active": true }
]
JSON
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --ci
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'orphan-dns:ghost'
}

@test "audit BLOCKS exposure drift when apps.json host/public changes after activation (restale2 F1)" {
  # ⚠️ codex pass4 F1 + restale2 F1: 앱 트리 무변경이어도 apps.json host/public가 바뀌면 DNS 노출이 변한다 →
  # 마커 registry projection과 불일치 → activation-exposure-drift는 **차단**(데드락 무관, 미재검증 노출 막음).
  G="$TMP/git5"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  # ⚠️ surfaceHash는 git ls-tree HEAD:apps/<app>이므로 HEAD가 존재해야(=먼저 commit) 비-empty가 된다.
  # (마커 surfaceHash가 비면 audit이 missing-activation으로 빠져 continue → exposure 검사 자체가 안 돈다.)
  git -C "$G" add -A; git -C "$G" commit -qm init
  curhash=$(bun "$ROOT/tools/lib/surface-hash.ts" "$G" HEAD orders)
  # 마커는 옛 host(orders.example.com)로 기록
  printf '{"app":"orders","sha":"abc1234","syncedRev":"abc1234","surfaceHash":"%s","registry":{"name":"orders","host":"orders.example.com","public":true}}\n' "$curhash" \
    > "$G/apps/orders/deploy/prod/.activation"
  git -C "$G" add -A; git -C "$G" commit -qm "+marker"
  # 앱 트리는 그대로 두고 apps.json host만 변경(노출 표면 변경)
  echo '[{ "name": "orders", "host": "neworders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$G" --ci
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "activation-exposure-drift"
}
