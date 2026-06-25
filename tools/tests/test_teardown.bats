#!/usr/bin/env bats
# teardown — 앱 ↔ 리소스 분리. 앱 teardown은 DB/캐시를 절대 건드리지 않고,
# 리소스 teardown은 참조 0 + tombstone 2단계 + 백업 게이트를 강제한다.
# ⚠️ 중간 단언은 [ ]만 사용 — bats가 bash 3.2로 돌 때 [[ ]] 실패는 침묵 통과된다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
  FR="$TMP/repo"
  mkdir -p "$FR/apps/orders/deploy/prod" "$FR/apps/billing/deploy/prod" \
    "$FR/infra/cloudflare" "$FR/docs" \
    "$FR/platform/cnpg/prod/databases" "$FR/platform/data-conn/prod" "$FR/platform/cache/prod/sessions"
  echo '{"db":["shared"],"redis":["sessions"],"autoDeploy":true}' > "$FR/apps/orders/deploy/prod/.bindings.json"
  echo '{"db":["shared"],"redis":[],"autoDeploy":true}' > "$FR/apps/billing/deploy/prod/.bindings.json"
  echo 'img' > "$FR/apps/orders/deploy/prod/values.yaml"
  cat > "$FR/infra/cloudflare/apps.json" <<'EOF'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "billing", "host": "billing.example.com", "public": true, "active": false }
]
EOF
  cat > "$FR/docs/memory-ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->
| <!-- ledger:row --> orders | prod | 64 | 128 |
| <!-- ledger:row --> billing | prod | 64 | 128 |

**합계:** req ≈ 128 Mi · limit ≈ 256 Mi (반드시 ≤ 8704 Mi 유지).
EOF
  # 리소스 산출물 (Phase 5 모양) — provision-db/-cache가 만드는 파일 + kustomization 등록
  printf 'kind: Database\nspec: { ensure: present }\n' > "$FR/platform/cnpg/prod/databases/shared.yaml"
  touch "$FR/platform/cnpg/prod/databases/db-shared-owner.sealed.yaml" \
    "$FR/platform/cnpg/prod/databases/db-shared-ro.sealed.yaml" \
    "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" \
    "$FR/platform/data-conn/prod/db-shared-ro-conn.sealed.yaml" \
    "$FR/platform/data-conn/prod/cache-sessions-conn.sealed.yaml" \
    "$FR/platform/data-conn/prod/cache-sessions-ro-conn.sealed.yaml"
  cat > "$FR/platform/cnpg/prod/databases/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: database
resources:
  - shared.yaml
  - db-shared-owner.sealed.yaml
  - db-shared-ro.sealed.yaml
EOF
  cat > "$FR/platform/data-conn/prod/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-shared-conn.sealed.yaml
  - db-shared-ro-conn.sealed.yaml
  - cache-sessions-conn.sealed.yaml
  - cache-sessions-ro-conn.sealed.yaml
EOF
  cat > "$FR/platform/cache/prod/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cache
resources:
  - sessions
EOF
}
teardown() { rm -rf "$TMP"; }

# teardown-resource는 모든 모드에서 --refs-verified attestation 필수(F1 강화) — 자동 refcount 대체.
# 래퍼는 attestation을 항상 전달; 누락 거부는 별도 테스트에서 ${ROOT} raw 호출로 검증.
tdr() { bun "$ROOT/tools/teardown-resource.ts" --refs-verified manual-test "$@"; }

# ── teardown-app ─────────────────────────────────────────────────────────────

@test "teardown-app removes only app-scoped artifacts, never db/cache resources" {
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.remove | any(. == "apps/orders")'
  echo "$output" | jq -e '.appsJsonRow.name == "orders"'
  # conn Secret/Database CR/Valkey는 제거 대상 목록에 절대 없다
  bad=$(echo "$output" | jq -r '.remove[]' | grep -E "data-conn|databases|cache/prod" || true)
  [ -z "$bad" ]
}

@test "teardown-app really removes the app dir, registry row, ledger row (idempotent)" {
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  [ "$status" -eq 0 ]
  [ ! -d "$FR/apps/orders" ]
  run jq -e 'map(select(.name == "orders")) | length == 0' "$FR/infra/cloudflare/apps.json"
  [ "$status" -eq 0 ]
  run grep "ledger:row --> orders" "$FR/docs/memory-ledger.md"
  [ "$status" -ne 0 ]
  # 리소스 산출물 무손상
  [ -f "$FR/platform/cnpg/prod/databases/shared.yaml" ]
  [ -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
  # 멱등: 한 번 더 → 0 종료
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  [ "$status" -eq 0 ]
}

# ── teardown-resource ────────────────────────────────────────────────────────

@test "any teardown is refused without --refs-verified attestation (F1 enforceable guard)" {
  # raw 호출(${ROOT} 중괄호 — tdr 래퍼 우회): attestation 누락이면 거부돼야 한다.
  run bun "${ROOT}/tools/teardown-resource.ts" --db shared --repo-root "$FR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "refs-verified"
}

@test "retain proceeds with --refs-verified <id> (auto refcount replaced by attestation)" {
  run bun "${ROOT}/tools/teardown-resource.ts" --db shared --refs-verified manual-2026-06-25 --repo-root "$FR"
  [ "$status" -eq 0 ]
  run jq -e '.["db:shared"].state == "retained"' "$FR/platform/data-conn/prod/.tombstones.json"
  [ "$status" -eq 0 ]
}

@test "teardown-resource retain (default) tombstones a zero-ref resource without deleting" {
  bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  bun "$ROOT/tools/teardown-app.ts" --app billing --repo-root "$FR"
  run tdr --db shared --repo-root "$FR"
  [ "$status" -eq 0 ]
  # 보존: CR/conn 전부 유지 + tombstone 기재 (접근 가능 상태 그대로)
  [ -f "$FR/platform/cnpg/prod/databases/shared.yaml" ]
  [ -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
  run jq -e '.["db:shared"].state == "retained"' "$FR/platform/data-conn/prod/.tombstones.json"
  [ "$status" -eq 0 ]
}

@test "purge without a verified backup id is refused (data deletion gate)" {
  bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  bun "$ROOT/tools/teardown-app.ts" --app billing --repo-root "$FR"
  run tdr --db shared --repo-root "$FR" --delete-data --step drop
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "backup"
}

@test "purge state machine: drop sets ensure absent; cleanup removes artifacts (resumable)" {
  bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  bun "$ROOT/tools/teardown-app.ts" --app billing --repo-root "$FR"
  run tdr --db shared --repo-root "$FR" --delete-data \
    --backup-verified barman-20260612 --step drop
  [ "$status" -eq 0 ]
  run grep "ensure: absent" "$FR/platform/cnpg/prod/databases/shared.yaml"
  [ "$status" -eq 0 ]
  # drop 재실행 = 멱등
  run tdr --db shared --repo-root "$FR" --delete-data \
    --backup-verified barman-20260612 --step drop
  [ "$status" -eq 0 ]
  # cleanup은 별도 커밋(별도 revision)용 단계 — CR/conn 제거, role은 워크플로가 cluster.yaml에서
  run tdr --db shared --repo-root "$FR" --delete-data \
    --backup-verified barman-20260612 --step cleanup
  [ "$status" -eq 0 ]
  [ ! -f "$FR/platform/cnpg/prod/databases/shared.yaml" ]
  [ ! -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
  run jq -e '.["db:shared"].state == "purged"' "$FR/platform/data-conn/prod/.tombstones.json"
  [ "$status" -eq 0 ]
}

@test "purge cleanup deregisters every removed file from its kustomization (no broken render)" {
  bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  bun "$ROOT/tools/teardown-app.ts" --app billing --repo-root "$FR"
  run tdr --db shared --repo-root "$FR" --delete-data \
    --backup-verified barman-1 --step cleanup
  [ "$status" -eq 0 ]
  # 파일 제거 (owner/ro 비밀번호 sealed 포함)
  [ ! -f "$FR/platform/cnpg/prod/databases/shared.yaml" ]
  [ ! -f "$FR/platform/cnpg/prod/databases/db-shared-owner.sealed.yaml" ]
  [ ! -f "$FR/platform/cnpg/prod/databases/db-shared-ro.sealed.yaml" ]
  [ ! -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
  # kustomization 등록 해제 — 남아 있으면 kustomize build가 missing file로 죽는다
  run grep -E "shared\.yaml|db-shared" "$FR/platform/cnpg/prod/databases/kustomization.yaml"
  [ "$status" -ne 0 ]
  run grep "db-shared" "$FR/platform/data-conn/prod/kustomization.yaml"
  [ "$status" -ne 0 ]
  # cache conn 항목은 무관하므로 보존
  run grep "cache-sessions-conn" "$FR/platform/data-conn/prod/kustomization.yaml"
  [ "$status" -eq 0 ]
  # cleanup 재실행 = 멱등
  run tdr --db shared --repo-root "$FR" --delete-data \
    --backup-verified barman-1 --step cleanup
  [ "$status" -eq 0 ]
}

@test "cache purge cleanup deregisters the instance dir and its conns" {
  bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  run tdr --cache sessions --repo-root "$FR" --delete-data \
    --backup-verified rdb-1 --step cleanup
  [ "$status" -eq 0 ]
  run grep "sessions" "$FR/platform/cache/prod/kustomization.yaml"
  [ "$status" -ne 0 ]
  run grep "cache-sessions" "$FR/platform/data-conn/prod/kustomization.yaml"
  [ "$status" -ne 0 ]
  # db 항목은 무관하므로 보존
  run grep "db-shared-conn" "$FR/platform/data-conn/prod/kustomization.yaml"
  [ "$status" -eq 0 ]
}

@test "cache teardown removes only that instance dir and its conn (per-app pvc isolation)" {
  bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  run tdr --cache sessions --repo-root "$FR" --delete-data \
    --backup-verified rdb-20260612 --step cleanup
  [ "$status" -eq 0 ]
  [ ! -d "$FR/platform/cache/prod/sessions" ]
  [ ! -f "$FR/platform/data-conn/prod/cache-sessions-conn.sealed.yaml" ]
  # db 산출물 무손상
  [ -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
}

@test "teardown-resource cache purge cleanup removes the cache-name ledger row (budget leak fix)" {
  D="$(mktemp -d)"; mkdir -p "$D/docs" "$D/apps" "$D/platform/data-conn/prod" "$D/platform/cache/prod/widget"
  printf '%s\n' '<!-- LIMIT_BUDGET_MIB=8704 -->' \
    '| <!-- ledger:row --> cache-widget   | cache          |     64 |      128 |' \
    '**합계:** req ≈ 64 Mi · limit ≈ 128 Mi (≤ 8704 Mi).' > "$D/docs/memory-ledger.md"
  echo '{}' > "$D/platform/data-conn/prod/.tombstones.json"
  run tdr --cache widget --repo-root "$D" --delete-data --backup-verified test-id --step cleanup
  [ "$status" -eq 0 ]
  run grep -c 'ledger:row --> cache-widget' "$D/docs/memory-ledger.md"
  [ "$output" = "0" ]
  run grep -q '"state": "purged"' "$D/platform/data-conn/prod/.tombstones.json"
  [ "$status" -eq 0 ]
}

@test "teardown-resource cache purge fails loud when totals prose drifted (no silent purge)" {
  D="$(mktemp -d)"; mkdir -p "$D/docs" "$D/apps" "$D/platform/data-conn/prod" "$D/platform/cache/prod/widget"
  printf '%s\n' '<!-- LIMIT_BUDGET_MIB=8704 -->' \
    '| <!-- ledger:row --> cache-widget   | cache          |     64 |      128 |' \
    'totals prose 누락(드리프트)' > "$D/docs/memory-ledger.md"
  echo '{}' > "$D/platform/data-conn/prod/.tombstones.json"
  run tdr --cache widget --repo-root "$D" --delete-data --backup-verified test-id --step cleanup
  [ "$status" -ne 0 ]
  run grep -q '"state": "purged"' "$D/platform/data-conn/prod/.tombstones.json"   # fail-loud: purged로 안 넘어가야
  [ "$status" -ne 0 ]
}
