#!/usr/bin/env bats
# audit-orphans dangling-role: cluster.yaml managed.roles 항목의 passwordSecret sealed가 부재하면 고아.
# (purge cleanup이 sealed/CR을 지웠지만 cluster.yaml role 제거 커밋이 빠진 상태.)
# ⚠️ 중간 단언은 [ ]만.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"; FR="$TMP/repo"
  mkdir -p "$FR/apps" "$FR/infra/cloudflare" "$FR/docs" \
    "$FR/platform/cnpg/prod/databases" "$FR/platform/data-conn/prod" "$FR/platform/cache/prod"
  echo '[]' > "$FR/infra/cloudflare/apps.json"
  printf '<!-- ledger:meta -->\n' > "$FR/docs/memory-ledger.md"
  # cluster.yaml: orders DB의 owner/ro managed role 2개. ro sealed는 제거됨(고아), owner sealed는 존재.
  cat > "$FR/platform/cnpg/prod/cluster.yaml" <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: pg }
spec:
  managed:
    roles:
      - name: orders_owner
        passwordSecret: { name: db-orders-owner }
      - name: orders_ro
        passwordSecret: { name: db-orders-ro }
YAML
  # owner sealed만 존재 — ro sealed는 cleanup이 지웠지만 role은 cluster.yaml에 잔존(고아)
  touch "$FR/platform/cnpg/prod/databases/db-orders-owner.sealed.yaml"
}
teardown() { rm -rf "$TMP"; }

@test "a managed role whose passwordSecret sealed file is gone is reported as dangling-role" {
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "dangling-role" and .subject == "orders_ro")'
  # owner role은 sealed가 살아있어 고아 아님
  run bash -c "bun '$ROOT/tools/audit-orphans.ts' --repo-root '$FR' | jq -e '.findings | any(.type==\"dangling-role\" and .subject==\"orders_owner\")'"
  [ "$status" -ne 0 ]
}

@test "dangling-role is informational (non-blocking under --ci)" {
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
  [ "$status" -eq 0 ]
}

@test "a managed role backed by a KSOPS .enc.yaml seed (ukkiee) is NOT dangling" {
  # ukkiee superuser 비번은 databases/*.sealed.yaml가 아니라 cnpg root의 KSOPS .enc.yaml에 있다.
  cat >> "$FR/platform/cnpg/prod/cluster.yaml" <<'YAML'
      - name: ukkiee
        passwordSecret: { name: pg-admin-credentials }
YAML
  # KSOPS 시드 파일 존재(secret-generator가 렌더) — 평문 아님(테스트는 파일 존재만 본다)
  touch "$FR/platform/cnpg/prod/pg-admin-credentials.enc.yaml"
  run bash -c "bun '$ROOT/tools/audit-orphans.ts' --repo-root '$FR' | jq -e '.findings | any(.type==\"dangling-role\" and .subject==\"ukkiee\")'"
  [ "$status" -ne 0 ]   # ukkiee은 .enc.yaml로 해소 → 고아 아님
}
