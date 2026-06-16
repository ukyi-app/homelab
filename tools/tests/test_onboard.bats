#!/usr/bin/env bats
# 멀티레포 온보딩 기계장치 검증: onboard-app.mjs(검증/스캐폴드) + 워크플로 보안 불변식.

ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

payload() { # $1=app $2=yaml-config -> /tmp 파일 경로 출력
  python3 - "$1" "$2" <<'EOF'
import json, base64, sys, tempfile
app, cfg = sys.argv[1], sys.argv[2]
p = {"app": app, "repo": f"ukyi-app/{app}", "tag": "sha-abc1234",
     "config_b64": base64.b64encode(cfg.encode()).decode()}
f = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False)
json.dump(p, f); f.close(); print(f.name)
EOF
}

run_onboard() { # $1=payload 파일 [추가 인자...]
  local p="$1"; shift
  (cd "$ROOT" && node tools/onboard-app.mjs --payload "$p" --domain ukyi.app "$@")
}

VALID_API='kind: api
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 500m, memory: 128Mi } }
route: { public: true }
db: { enabled: true, migrateCmd: ["/app/blog","migrate"] }
env: [{ name: LOG_LEVEL, value: info }]
secrets: [blog-secrets]'

@test "valid api: derived host + ledger budget + secrets checklist" {
  p=$(payload blog "$VALID_API")
  run run_onboard "$p" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"host": "blog.ukyi.app"'* ]]
  [[ "$output" == *'"budget": 8704'* ]]
  [[ "$output" == *'blog-secrets.enc.yaml'* ]]
}

@test "internal app derives *.home.<domain> host" {
  p=$(payload intapp 'kind: api
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 100m, memory: 64Mi } }')
  run run_onboard "$p" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"host": "intapp.home.ukyi.app"'* ]]
}

@test "reject: route on worker" {
  p=$(payload w1 'kind: worker
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 100m, memory: 64Mi } }
route: { public: true }')
  run run_onboard "$p" --dry-run
  [ "$status" -ne 0 ]; [[ "$output" == *"route"* ]]
}

@test "reject secret-pattern env / allow with allowPlaintext" {
  p=$(payload a2 'kind: api
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 100m, memory: 64Mi } }
env: [{ name: API_TOKEN, value: oops }]')
  run run_onboard "$p" --dry-run
  [ "$status" -ne 0 ]; [[ "$output" == *"API_TOKEN"* ]]
  p=$(payload a3 'kind: api
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 100m, memory: 64Mi } }
env: [{ name: CACHE_KEY_PREFIX, value: v1 }]
allowPlaintext: [CACHE_KEY_PREFIX]')
  run run_onboard "$p" --dry-run
  [ "$status" -eq 0 ]
}

@test "reject: budget / duplicate / internal-host rule / unknown field / tag format" {
  p=$(payload big 'kind: api
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 500m, memory: 1Gi } }
replicas: 3')
  run run_onboard "$p" --dry-run; [ "$status" -ne 0 ]; [[ "$output" == *"예산 초과"* ]]
  # duplicate: 인-레포 앱이 없으므로 fixture root에 앱을 미리 만들어 중복 거부를 검증
  fixdup="$(mktemp -d)"; mkdir -p "$fixdup/apps/dup/deploy/prod" "$fixdup/docs"
  cp "$ROOT/docs/memory-ledger.md" "$fixdup/docs/memory-ledger.md"
  p=$(payload dup 'kind: api
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 100m, memory: 64Mi } }')
  run run_onboard "$p" --dry-run --repo-root "$fixdup"; [ "$status" -ne 0 ]; [[ "$output" == *"이미 존재"* ]]
  rm -rf "$fixdup"
  p=$(payload a4 'kind: api
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 100m, memory: 64Mi } }
route: { public: false, host: a4.ukyi.app }')
  run run_onboard "$p" --dry-run; [ "$status" -ne 0 ]; [[ "$output" == *"home."* ]]
  p=$(payload a5 'kind: api
hostPort: 9999
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 100m, memory: 64Mi } }')
  run run_onboard "$p" --dry-run; [ "$status" -ne 0 ]; [[ "$output" == *"알 수 없는 필드"* ]]
  bad=$(payload t1 'kind: api
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 100m, memory: 64Mi } }')
  python3 - "$bad" <<'EOF'
import json,sys
p=json.load(open(sys.argv[1])); p["tag"]="latest"; json.dump(p, open(sys.argv[1],"w"))
EOF
  run run_onboard "$bad" --dry-run; [ "$status" -ne 0 ]; [[ "$output" == *"tag"* ]]
}

@test "real write: values, source-repo, KSOPS generator, ledger row (fixture root)" {
  fix="$(mktemp -d)"
  mkdir -p "$fix/apps" "$fix/docs"
  cat > "$fix/docs/memory-ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->
| component | namespace | req_mi | limit_mi |
|---|---|---:|---:|
| <!-- ledger:row --> base | kube-system | 100 | 200 |
**Totals:** req ≈ 100 Mi · limit ≈ 200 Mi (must stay ≤ 8704 Mi).
EOF
  p=$(payload blog "$VALID_API")
  run run_onboard "$p" --repo-root "$fix"
  [ "$status" -eq 0 ]
  [ -f "$fix/apps/blog/deploy/prod/values.yaml" ]
  grep -q 'repo: ghcr.io/ukyi-app/blog' "$fix/apps/blog/deploy/prod/values.yaml"
  grep -q 'tag: sha-abc1234' "$fix/apps/blog/deploy/prod/values.yaml"
  grep -q 'host: blog.ukyi.app' "$fix/apps/blog/deploy/prod/values.yaml"
  [ "$(cat "$fix/apps/blog/deploy/prod/source-repo")" = "ukyi-app/blog" ]
  grep -q 'path: ksops' "$fix/apps/blog/deploy/prod/secret-generator.yaml"
  grep -q 'blog-secrets.enc.yaml' "$fix/apps/blog/deploy/prod/secret-generator.yaml"
  grep -q 'generators' "$fix/apps/blog/deploy/prod/kustomization.yaml"
  grep -q 'ledger:row --> blog' "$fix/docs/memory-ledger.md"
  grep -q 'limit ≈ 328 Mi' "$fix/docs/memory-ledger.md"   # 200 + 128
}

@test "no-secrets app STILL gets a kustomization.yaml (else ArgoCD parses values.yaml as manifest)" {
  fix="$(mktemp -d)"; mkdir -p "$fix/apps" "$fix/docs"
  cat > "$fix/docs/memory-ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->
| component | namespace | req_mi | limit_mi |
|---|---|---:|---:|
| <!-- ledger:row --> base | kube-system | 100 | 200 |
**Totals:** req ≈ 100 Mi · limit ≈ 200 Mi (must stay ≤ 8704 Mi).
EOF
  nosec='kind: api
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 500m, memory: 128Mi } }
route: { public: false }
db: { enabled: false }
env: []
secrets: []'
  p=$(payload demo "$nosec")
  run run_onboard "$p" --repo-root "$fix"
  [ "$status" -eq 0 ]
  [ -f "$fix/apps/demo/deploy/prod/kustomization.yaml" ]   # secrets 없어도 반드시 존재
  ! [ -f "$fix/apps/demo/deploy/prod/secret-generator.yaml" ]  # secrets 없으면 generator는 없음
  grep -q 'kind: Kustomization' "$fix/apps/demo/deploy/prod/kustomization.yaml"
  rm -rf "$fix"
}

# ── 워크플로 보안 불변식 ─────────────────────────────────────────────────────────
@test "bump: dispatch path shares serial group; legacy job scoped to workflow_run" {
  f="$ROOT/.github/workflows/bump.yaml"
  grep -q 'repository_dispatch' "$f"
  grep -q 'app-image' "$f"
  grep -qE "event_name == 'workflow_run'" "$f"
  grep -qE "event_name == 'repository_dispatch'" "$f"
  # 직렬 그룹은 하나만 (양 경로 공유)
  [ "$(grep -c 'group: values-writeback' "$f")" -eq 1 ]
}

@test "bump dispatch: untrusted payload env-only + source-repo binding + digest verify" {
  f="$ROOT/.github/workflows/bump.yaml"
  grep -q 'source-repo' "$f"
  grep -q 'docker manifest inspect' "$f"
  # client_payload 참조는 env 할당(APP:/TAG:/SRC:) 또는 주석에만 등장해야 한다 — run 인라인 보간 금지
  # (BSD grep은 \s 미지원 — POSIX [[:space:]] 사용)
  bad=$(grep -n 'client_payload' "$f" | grep -vE '^[0-9]+:[[:space:]]*(#|(APP|TAG|SRC):)' || true)
  [ -z "$bad" ]
}

@test "onboard: payload via toJSON env, app-token-created PR, ledger gate first" {
  f="$ROOT/.github/workflows/onboard.yaml"
  grep -q 'toJSON(github.event.client_payload)' "$f"
  # GITHUB_TOKEN PR은 required check를 트리거하지 않는다 — writer App 토큰발 PR이어야 한다
  grep -qE 'create-github-app-token@[0-9a-f]{40}' "$f"
  grep -q 'HOMELAB_WRITER_APP_ID' "$f"
  grep -q 'verify:ledger' "$f"
  grep -q 'kubeconform' "$f"
}

@test "reusable-app-build v1: build-only, dispatch jobs gone, dispatch-pat optional-compat" {
  f="$ROOT/.github/workflows/reusable-app-build.yaml"
  grep -q 'workflow_call' "$f"
  grep -q 'linux/arm64' "$f"
  # v1: homelab dispatch 경로 전부 제거 — 배포 반영은 bump-poll(GHCR 폴링)이 권위
  run grep -E "repos/.*/dispatches|app-onboard|app-image|environment: production" "$f"
  [ "$status" -ne 0 ]
  # 호환 장치: dispatch-pat은 required:false 선언만 유지(미사용) — caller 검증 실패 방지
  grep -q 'dispatch-pat' "$f"
  grep -A1 'dispatch-pat' "$f" | grep -vq 'required: true'
}
