#!/usr/bin/env bats
# update-secrets 도구 — 앱 레포 봉인본을 homelab 배포에 검증·배선한다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
  FR="$TMP/repo"
  APPREPO="$TMP/apprepo"
  mkdir -p "$FR/apps/example-api/deploy/prod" "$APPREPO/deploy"
  cat > "$FR/apps/example-api/deploy/prod/values.yaml" <<'EOF'
image:
  repo: ghcr.io/ukyi-app/example-api
  tag: sha-aaaaaaaa
  digest: sha256:1111111111111111111111111111111111111111111111111111111111111111
kind: web
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits: { cpu: 500m, memory: 128Mi }
route:
  host: example-api.ukyi.app
  public: true
EOF
  cat > "$FR/apps/example-api/deploy/prod/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
EOF
  cat > "$APPREPO/deploy/example-api-secrets.sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: example-api-secrets
  namespace: prod
spec:
  encryptedData:
    ENV_TEST: AgX...
EOF
}
teardown() { rm -rf "$TMP"; }

@test "update-secrets wires first app secret into values and kustomization" {
  run bun "$ROOT/tools/update-secrets.ts" --app example-api --repo-root "$FR" --app-repo-root "$APPREPO"

  [ "$status" -eq 0 ]
  grep -q "example-api-secrets" "$FR/apps/example-api/deploy/prod/values.yaml"
  grep -q "envFrom:" "$FR/apps/example-api/deploy/prod/values.yaml"
  grep -q "checksum/secrets" "$FR/apps/example-api/deploy/prod/values.yaml"
  grep -q "example-api-secrets.sealed.yaml" "$FR/apps/example-api/deploy/prod/kustomization.yaml"
  [ -f "$FR/apps/example-api/deploy/prod/example-api-secrets.sealed.yaml" ]
}

@test "update-secrets rejects invalid sealed key names" {
  cat > "$APPREPO/deploy/example-api-secrets.sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: example-api-secrets
  namespace: prod
spec:
  encryptedData:
    bad-key: AgX...
EOF

  run bun "$ROOT/tools/update-secrets.ts" --app example-api --repo-root "$FR" --app-repo-root "$APPREPO"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "bad-key"
}

@test "update-secrets accepts key removal from the sealed secret" {
  cat > "$APPREPO/deploy/example-api-secrets.sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: example-api-secrets
  namespace: prod
spec:
  encryptedData:
    A: AgX...
EOF

  run bun "$ROOT/tools/update-secrets.ts" --app example-api --repo-root "$FR" --app-repo-root "$APPREPO"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"A"'
  ! echo "$output" | grep -q '"B"'
}

@test "update-secrets allows DATABASE_ADMIN_URL when it is already sealed" {
  cat > "$APPREPO/deploy/example-api-secrets.sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: example-api-secrets
  namespace: prod
spec:
  encryptedData:
    DATABASE_ADMIN_URL: AgX...
EOF

  run bun "$ROOT/tools/update-secrets.ts" --app example-api --repo-root "$FR" --app-repo-root "$APPREPO"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DATABASE_ADMIN_URL"
}

@test "update-secrets workflow only needs the deploy directory from the app repo" {
  run grep -A8 'path: .apprepo' "$ROOT/.github/workflows/_update-secrets.yaml"

  [ "$status" -eq 0 ]
  block="$output"   # run 재호출이 $output을 덮으므로 보존
  # 중간 negate는 침묵 통과 → run+status로 강제(check-bats-style.sh)
  run grep -q ".app-config.yml" <<<"$block"
  [ "$status" -ne 0 ]
  echo "$block" | grep -q "deploy"
}
