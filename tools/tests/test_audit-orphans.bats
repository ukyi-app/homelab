#!/usr/bin/env bats
# audit-orphans — registry/매니페스트/원장 교차 드리프트 리포트 (읽기 전용; db/redis 바인딩 교차는 제거)
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
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "orphan-dns" and .subject == "ghost")'
}

@test "audit no longer emits dangling-binding/unreferenced-resource (connection is a sealed secret)" {
  # .bindings.json에 db/redis 참조가 없어 바인딩↔리소스 교차가 사라졌다 — 두 유형 모두 미발화.
  echo '{"db":["missing"],"redis":[],"autoDeploy":true}' > "$FR/apps/orders/deploy/prod/.bindings.json"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 0 ]
  run sh -c "bun '$ROOT/tools/audit-orphans.ts' --repo-root '$FR' | jq -e '.findings | any(.type == \"dangling-binding\" or .type == \"unreferenced-resource\")'"
  [ "$status" -ne 0 ]   # 해당 유형 0건
}

@test "audit reports stale ledger rows (prod row without app dir)" {
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "stale-ledger-row" and .subject == "stale-app")'
}

@test "audit --ci blocks orphan-dns but passes stale-ledger (no false PR block)" {
  # 픽스처엔 orphan-dns(ghost)+stale-ledger-row(stale-app)가 있다 → --ci는 orphan-dns가 blocking이므로 비-0
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
  [ "$status" -ne 0 ]
  # ghost(orphan-dns)만 제거 — stale-app(원장 드리프트)는 남긴다(non-blocking)
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$FR/infra/cloudflare/apps.json"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
  [ "$status" -eq 0 ]   # stale-ledger-row(stale-app)가 남아도 --ci는 통과
  echo "$output" | jq -e '.findings | any(.type == "stale-ledger-row")'
}

@test "audit --strict exits nonzero when findings exist, zero when clean" {
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --strict
  [ "$status" -ne 0 ]
  # ghost 행/stale 행/lonely 제거 → clean. active 앱은 valid .activation 마커가 있어야 clean(races-5 불변식).
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$FR/infra/cloudflare/apps.json"
  printf '{"app":"orders","sha":"abc1234","surfaceHash":"seed","registry":{"name":"orders","host":"orders.example.com","public":true}}\n' \
    > "$FR/apps/orders/deploy/prod/.activation"
  sed -i '' '/stale-app/d' "$FR/docs/memory-ledger.md" 2>/dev/null || sed -i '/stale-app/d' "$FR/docs/memory-ledger.md"
  rm "$FR/platform/cnpg/prod/databases/lonely.yaml" "$FR/platform/data-conn/prod/db-lonely-conn.sealed.yaml"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --strict
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
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$G" --ci
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
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$G"
  [ "$status" -eq 0 ]
  run sh -c 'echo "$1" | grep -c activation-surface-drift' _ "$output"
  [ "$output" -eq 0 ]
}

@test "audit accepts an active app without an activation marker (create-app merge is approval)" {
  # create-app PR 머지 자체가 첫 공개 승인이다. .activation 마커는 별도 재활성화/노출 변경
  # 재증명에만 쓰므로, 초기 active:true 앱에 마커가 없어도 audit 노이즈를 내지 않는다.
  G="$TMP/git3"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  rm -f "$G/apps/orders/deploy/prod/.activation"
  git -C "$G" add -A; git -C "$G" commit -qm init
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$G" --ci
  [ "$status" -eq 0 ]
  run sh -c 'echo "$1" | grep -c missing-activation' _ "$output"
  [ "$output" -eq 0 ]
}

@test "an inactive (active:false) orphan row is non-blocking info, not orphan-dns" {
  # dns.tf는 public && active만 노출 — active:false orphan은 DNS를 노출하지 않으므로 PR을 막으면 안 된다.
  cat > "$FR/infra/cloudflare/apps.json" <<'JSON'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "pending-app", "host": "pending.example.com", "public": true, "active": false }
]
JSON
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
  [ "$status" -eq 0 ]   # active:false orphan은 비차단 → --ci 통과
  # 비차단 정보 유형으로 보고는 된다(가시성 유지)
  echo "$output" | jq -e '.findings | any(.type == "orphan-dns-inactive" and .subject == "pending-app")'
  # 차단 유형(orphan-dns)으로는 잡히지 않는다
  run bash -c "bun '$ROOT/tools/audit-orphans.ts' --repo-root '$FR' | jq -e '.findings | any(.type == \"orphan-dns\" and .subject == \"pending-app\")'"
  [ "$status" -ne 0 ]
}

@test "an active:true orphan row is still blocking under --ci" {
  cat > "$FR/infra/cloudflare/apps.json" <<'JSON'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "ghost", "host": "ghost.example.com", "public": true, "active": true }
]
JSON
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
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
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$G" --ci
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "activation-exposure-drift"
}

@test "audit reports unreferenced conn handles and skips ro-conn (mode-2 debug handles)" {
  # data-conn 등록 conn인데 어느 apps/*/values.yaml envFrom도 참조 안 함 → 정보성 발화(#211 클래스).
  cat > "$FR/platform/data-conn/prod/kustomization.yaml" <<'KEOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-orders-conn.sealed.yaml
  - db-orders-ro-conn.sealed.yaml
  - db-lonely-conn.sealed.yaml
KEOF
  printf 'image: {repo: x, tag: sha-abc1234}\nroute: {public: true, host: orders.example.com}\nenvFrom:\n  - secretRef:\n      name: orders-secrets\n  - secretRef:\n      name: db-orders-conn\n' \
    > "$FR/apps/orders/deploy/prod/values.yaml"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "unreferenced-conn" and .subject == "db-lonely-conn")'
  # 참조된 conn과 ro-conn(의도적 미참조)은 미발화
  run bash -c "bun '$ROOT/tools/audit-orphans.ts' --repo-root '$FR' | jq -e '.findings | any(.type == \"unreferenced-conn\" and (.subject == \"db-orders-conn\" or .subject == \"db-orders-ro-conn\"))'"
  [ "$status" -ne 0 ]
}

@test "unreferenced-conn is informational and never blocks --ci" {
  # ghost(orphan-dns, 차단 유형)를 제거해 --ci 판정을 unreferenced-conn만으로 격리
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$FR/infra/cloudflare/apps.json"
  cat > "$FR/platform/data-conn/prod/kustomization.yaml" <<'KEOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-lonely-conn.sealed.yaml
KEOF
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "unreferenced-conn" and .subject == "db-lonely-conn")'
}
