#!/usr/bin/env bats
# audit-orphans dangling-role: cluster.yaml managed.roles 항목의 passwordSecret sealed가 부재하면 고아.
# (purge cleanup이 sealed/CR을 지웠지만 cluster.yaml role 제거 커밋이 빠진 상태.)
# ⚠️ 중간 단언은 [ ]만.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"; FR="$TMP/repo"
  mkdir -p "$FR/apps" "$FR/infra/cloudflare" "$FR/docs" \
    "$FR/platform/cnpg/prod/databases" "$FR/platform/data-conn/prod" "$FR/platform/cache/prod"
  # ⚠️ 이 스위트의 도메인은 cluster.yaml managed.roles다 — registry도 원장도 정당하게 비어 있다.
  # audit-orphans의 registry scan-floor는 그래서 `--floor registry=0`으로 **명시** 해제해 부른다
  # (선례: check-image-pins `--floor total=1`). 바닥값 판정은 모드 분기보다 **앞**이라 기본·--ci·--strict
  # 세 모드에 전부 적용된다(증인: test_audit-orphans.bats의 `--ci --floor registry=1` → rc 1).
  # ⚠️ 원장도 같은 이유로 `--floor ledger=0`이다 — 아래 픽스처의 원장은 meta 줄뿐(행 0)이고,
  # audit-orphans의 원장 바닥값 기본은 1이다(실 트리 docs/memory-ledger.md는 CI가 강제하는 예산
  # SSOT라 구조적으로 항상 ≥1행 — 0행은 파서/파일 붕괴다). 픽스처는 **명시**로 내린다.
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
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --floor registry=0 --floor ledger=0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "dangling-role" and .subject == "orders_ro")'
  # owner role은 sealed가 살아있어 고아 아님
  run bash -c "bun '$ROOT/tools/audit-orphans.ts' --repo-root '$FR' --floor registry=0 --floor ledger=0 | jq -e '.findings | any(.type==\"dangling-role\" and .subject==\"orders_owner\")'"
  [ "$status" -ne 0 ]
}

@test "dangling-role is informational (non-blocking under --ci)" {
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci --floor registry=0 --floor ledger=0
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
  run bash -c "bun '$ROOT/tools/audit-orphans.ts' --repo-root '$FR' --floor registry=0 --floor ledger=0 | jq -e '.findings | any(.type==\"dangling-role\" and .subject==\"ukkiee\")'"
  [ "$status" -ne 0 ]   # ukkiee은 .enc.yaml로 해소 → 고아 아님
}
