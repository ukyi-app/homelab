#!/usr/bin/env bats
# secret:seal CLI — .env→SealedSecret 봉인. .env 키가 SSOT이며 값은 비노출.
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 이 파일의 경로 피연산자는 전부 픽스처가 방금 만든
#    단일 파일이라 그것으로 닫힌다. 히어스트링(`<<<"$seal_output"`) 자리는 부재할 경로가 없어
#    대상이 아니다. cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a

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
  # 봉인 도구가 설정 파일을 **지워도** "secrets를 안 썼다"로 초록이던 자리다.
  run grep -q "secrets" "$TMP/.app-config.yml"
  [ "$status" -eq 1 ]
  echo "$seal_output" | grep -q "ENV_TEST"
  echo "$seal_output" | grep -q "API_KEY"
  # 중간 negate는 침묵 통과 → run+status로 강제(check-bats-style.sh). $seal_output 보존됨.
  run grep -q "hello" <<<"$seal_output"
  [ "$status" -ne 0 ]
  run grep -q "topsecret" <<<"$seal_output"
  [ "$status" -ne 0 ]
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
  # 같은 불변식의 cwd-상대 형태 — 기본값 유도가 이 @test의 주제라 피연산자도 상대다.
  run grep -q "secrets" .app-config.yml
  [ "$status" -eq 1 ]
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
  seal_output="$output"   # run 재호출이 $output을 덮으므로 보존
  grep -q "kind: SealedSecret" "$TMP/demo-secrets.sealed.yaml"
  # 평문 값이 산출/출력 어디에도 없다 (중간 negate는 침묵 통과 → run+status로 강제)
  # 산출물이 아예 안 써져도 "평문 없음"이 초록이던 자리다 — 위 `kind: SealedSecret` 단언이
  # **같은 피연산자**로 산출물 실재를 요구하는 양성 대조다.
  # ⚠️ `-r`을 붙이지 않는다 — 피연산자가 단일 파일이라 재귀는 무의미한데, 그 플래그 하나가
  #    이 자리를 디렉토리 형태로 읽히게 만든다(빈 디렉토리 rc 1 = 무매치라 `-eq 1`로 못 닫는
  #    형태). 실측(2026-08-31): 없는 **파일**에는 `grep -q`도 `grep -rq`도 rc **2** · 빈
  #    **디렉토리**에는 `grep -rq`가 rc **1**. 그래서 단일 파일 피연산자는 `-eq 1` 하나로
  #    리네임·미작성이 닫힌다. 뮤테이션 확증: 산출물을 다른 이름으로 쓰게 하면 이 @test는 red.
  run grep -q "sealme" "$TMP/demo-secrets.sealed.yaml"
  [ "$status" -eq 1 ]
  run grep -q "sealme" <<<"$seal_output"
  [ "$status" -ne 0 ]
}
