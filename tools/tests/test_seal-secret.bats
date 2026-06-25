#!/usr/bin/env bats
# secret:seal CLI — .env→SealedSecret 봉인. allowlist 강제 + 값 비노출.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

@test "seal-secret only seals keys declared in secrets allowlist" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: service
secrets: [api-key, db-extra]
EOF
  cat > "$TMP/.env" <<'EOF'
API_KEY=topsecret
DB_EXTRA=more
UNDECLARED=should-not-seal
EOF
  # --dry-run은 봉인 없이 어떤 키가 대상인지 JSON으로 출력
  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "API_KEY"
  echo "$output" | grep -q "DB_EXTRA"
  ! echo "$output" | grep -q "UNDECLARED"
}

@test "seal-secret errors when a declared secret is missing from .env" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: service
secrets: [missing-key]
EOF
  printf 'OTHER=x\n' > "$TMP/.env"
  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "missing"
}

@test "seal-secret never prints secret values (dry-run or error paths)" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: service
secrets: [api-key]
EOF
  cat > "$TMP/.env" <<'EOF'
API_KEY=super-sensitive-value-xyz
EOF
  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "super-sensitive-value-xyz"
}

@test "seal-secret rejects a value pointing at the admin superuser (F2, best-effort)" {
  printf 'kind: service\nsecrets: [db-url]\n' > "$TMP/.app-config.yml"
  printf 'DB_URL=postgres://app_admin@pg-rw-tailscale:5432/app\n' > "$TMP/.env"  # C1 superuser 롤(SSOT=app_admin)
  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | grep -Eq "superuser|app_admin"
}

@test "seal-secret rejects a jdbc:postgresql superuser URL (F2, common JVM accident form)" {
  printf 'kind: service\nsecrets: [db-url]\n' > "$TMP/.app-config.yml"
  printf 'DB_URL=jdbc:postgresql://app_admin:pw@pg-rw-tailscale:5432/app\n' > "$TMP/.env"
  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | grep -Eq "superuser|app_admin"
}

@test "seal-secret rejects a quoted superuser URL (F2, blocks the .env quote bypass)" {
  printf 'kind: service\nsecrets: [db-url]\n' > "$TMP/.app-config.yml"
  printf 'DB_URL="postgres://app_admin:pw@pg-rw-tailscale:5432/app"\n' > "$TMP/.env"
  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | grep -Eq "superuser|app_admin"
}

@test "seal-secret allows an owner/ro connection URL (no false-positive on least-privilege creds)" {
  printf 'kind: service\nsecrets: [db-url]\n' > "$TMP/.app-config.yml"
  printf 'DB_URL=postgres://orders_ro:pw@pg-rw-tailscale:5432/orders\n' > "$TMP/.env"
  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -eq 0 ]
}

@test "seal-secret SEAL_FORCE=1 bypasses the F2 superuser guard (informed override, value still hidden)" {
  printf 'kind: service\nsecrets: [db-url]\n' > "$TMP/.app-config.yml"
  printf 'DB_URL=postgres://app_admin:topsecretpw@pg-rw-tailscale:5432/app\n' > "$TMP/.env"
  SEAL_FORCE=1 run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "topsecretpw"
}

@test "seal-secret pipes a plaintext Secret through kubeseal and writes sealed yaml" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: service
secrets: [api-key]
EOF
  cat > "$TMP/.env" <<'EOF'
API_KEY=sealme
EOF
  # kubeseal 스텁: stdin manifest를 받아 SealedSecret 모양으로 변환(평문 미포함 단언용)
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/kubeseal" <<'EOF'
#!/bin/sh
printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata:\n  name: STUB\nspec:\n  encryptedData: {}\n'
EOF
  chmod +x "$TMP/bin/kubeseal"
  : > "$TMP/cert.pem"
  PATH="$TMP/bin:$PATH" run bun "$ROOT/tools/seal-secret.mts" \
    --config "$TMP/.app-config.yml" --env "$TMP/.env" \
    --cert "$TMP/cert.pem" --app demo --namespace prod --out "$TMP/demo-secrets.sealed.yaml"
  [ "$status" -eq 0 ]
  grep -q "kind: SealedSecret" "$TMP/demo-secrets.sealed.yaml"
  # 평문 값이 산출/출력 어디에도 없다
  ! grep -rq "sealme" "$TMP/demo-secrets.sealed.yaml"
  ! echo "$output" | grep -q "sealme"
}
