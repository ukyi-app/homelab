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
  # tools-create-provision-4(8라운드) — 회전 시 재실행(멱등) 레인이 없어 dedup 가드(58-60행)가
  # 무증인이었다. 같은 인자로 재실행해 envFrom의 secretRef가 누적되지 않는지 확인한다.
  run bun "$ROOT/tools/update-secrets.ts" --app example-api --repo-root "$FR" --app-repo-root "$APPREPO"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'secretRef' "$FR/apps/example-api/deploy/prod/values.yaml")" -eq 1 ]
}

# 봉인 계약 정책 매트릭스(kind/namespace/name/empty/UPPER_SNAKE)는 커널이 소유한다
# (tools/tests/test_sealed-contract.bats). 여기선 커널 거부가 이 툴의 ::error:: 접두 + exit 1로
# 전파되는지만 증인한다(위임 증인 — 중복 정책 단언은 커널로 이관).
@test "update-secrets: a sealed-contract rejection surfaces as exit 1 with the tool's ::error:: prefix" {
  cat > "$APPREPO/deploy/example-api-secrets.sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: example-api-secrets
  namespace: default
spec:
  encryptedData:
    ENV_TEST: AgX...
EOF

  run bun "$ROOT/tools/update-secrets.ts" --app example-api --repo-root "$FR" --app-repo-root "$APPREPO"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q '::error::update-secrets: sealed namespace는 prod여야 한다'
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

@test "update-secrets workflow only needs the deploy directory from the app repo" {
  run grep -A8 'path: .apprepo' "$ROOT/.github/workflows/_update-secrets.yaml"

  [ "$status" -eq 0 ]
  block="$output"   # run 재호출이 ${output}을 덮으므로 보존
  # 중간 negate는 침묵 통과 → run+status로 강제(check-bats-style.sh)
  run grep -q ".app-config.yml" <<<"$block"
  [ "$status" -ne 0 ]
  echo "$block" | grep -q "deploy"
}
