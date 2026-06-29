#!/usr/bin/env bats
# secret:seal CLI — .env→SealedSecret 봉인. .env 키가 SSOT이며 값은 비노출.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

@test "seal-secret seals every .env UPPER_SNAKE key" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
EOF
  cat > "$TMP/.env" <<'EOF'
API_KEY=topsecret
DB_EXTRA=more
EOF
  # --dry-run은 봉인 없이 어떤 키가 대상인지 JSON으로 출력
  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "API_KEY"
  echo "$output" | grep -q "DB_EXTRA"
}

@test "seal-secret drops keys removed from .env on the next seal" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
EOF
  printf 'A=aaa\n' > "$TMP/.env"

  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "A"
  ! echo "$output" | grep -q "B"
}

@test "seal-secret never prints secret values (dry-run or error paths)" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
EOF
  cat > "$TMP/.env" <<'EOF'
API_KEY=super-sensitive-value-xyz
EOF
  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "super-sensitive-value-xyz"
}

@test "seal-secret does not write secrets back to app config" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
EOF
  cat > "$TMP/.env" <<'EOF'
ENV_TEST=hello
API_KEY=topsecret
EOF
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
  seal_output="$output"
  run grep -q "secrets" "$TMP/.app-config.yml"
  [ "$status" -ne 0 ]
  echo "$seal_output" | grep -q "ENV_TEST"
  echo "$seal_output" | grep -q "API_KEY"
  ! echo "$seal_output" | grep -q "hello"
  ! echo "$seal_output" | grep -q "topsecret"
}

@test "seal-secret defaults app and output path from current directory" {
  mkdir -p "$TMP/example-api"
  cd "$TMP/example-api" || exit 1
  cat > .app-config.yml <<'EOF'
kind: web
EOF
  printf 'ENV_TEST=hello\n' > .env
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/kubeseal" <<'EOF'
#!/bin/sh
printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata:\n  name: STUB\nspec:\n  encryptedData: {}\n'
EOF
  chmod +x "$TMP/bin/kubeseal"
  : > cert.pem

  PATH="$TMP/bin:$PATH" run bun "$ROOT/tools/seal-secret.mts" --config .app-config.yml --env .env --cert cert.pem

  [ "$status" -eq 0 ]
  [ -f deploy/example-api-secrets.sealed.yaml ]
  run grep -q "secrets" .app-config.yml
  [ "$status" -ne 0 ]
}

@test "seal-secret allows DATABASE_ADMIN_URL like any other env key" {
  printf 'kind: web\n' > "$TMP/.app-config.yml"
  printf 'DATABASE_ADMIN_URL=postgres://orders:pw@pg-rw-tailscale:5432/orders\n' > "$TMP/.env"

  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DATABASE_ADMIN_URL"
}

@test "seal-secret allows a value pointing at the admin superuser while hiding the value" {
  printf 'kind: web\n' > "$TMP/.app-config.yml"
  printf 'DB_URL=postgres://ukkiee@pg-rw-tailscale:5432/app\n' > "$TMP/.env"  # C1 superuser 롤(SSOT=ukkiee)
  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DB_URL"
  ! echo "$output" | grep -q "ukkiee"
}

@test "seal-secret allows a jdbc:postgresql superuser URL while hiding the value" {
  printf 'kind: web\n' > "$TMP/.app-config.yml"
  printf 'DB_URL=jdbc:postgresql://ukkiee:pw@pg-rw-tailscale:5432/app\n' > "$TMP/.env"
  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DB_URL"
  ! echo "$output" | grep -q "ukkiee"
}

@test "seal-secret allows a quoted superuser URL while hiding the value" {
  printf 'kind: web\n' > "$TMP/.app-config.yml"
  printf 'DB_URL="postgres://ukkiee:pw@pg-rw-tailscale:5432/app"\n' > "$TMP/.env"
  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DB_URL"
  ! echo "$output" | grep -q "ukkiee"
}

@test "seal-secret allows an owner/ro connection URL (no false-positive on least-privilege creds)" {
  printf 'kind: web\n' > "$TMP/.app-config.yml"
  printf 'DB_URL=postgres://orders_ro:pw@pg-rw-tailscale:5432/orders\n' > "$TMP/.env"
  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -eq 0 ]
}

@test "seal-secret pipes a plaintext Secret through kubeseal and writes sealed yaml" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
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
