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

run_onboard() { # $1=payload-file [extra args...]
  local p="$1"; shift
  (cd "$ROOT" && node tools/onboard-app.mjs --payload "$p" --domain ukyi.app "$@")
}

VALID_API='kind: api
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 500m, memory: 128Mi } }
route: { public: true }
db: { enabled: true, migrateCmd: ["/app/blog","migrate"] }
env: [{ name: LOG_LEVEL, value: info }]
secrets: [blog-secrets]'

@test "정상 api: host 자동 유도 + 원장 예산 계산 + 시크릿 체크리스트" {
  p=$(payload blog "$VALID_API")
  run run_onboard "$p" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"host": "blog.ukyi.app"'* ]]
  [[ "$output" == *'"budget": 8704'* ]]
  [[ "$output" == *'blog-secrets.enc.yaml'* ]]
}

@test "내부 앱은 *.home.<domain>으로 유도" {
  p=$(payload intapp 'kind: api
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 100m, memory: 64Mi } }')
  run run_onboard "$p" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"host": "intapp.home.ukyi.app"'* ]]
}

@test "거부: worker에 route" {
  p=$(payload w1 'kind: worker
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 100m, memory: 64Mi } }
route: { public: true }')
  run run_onboard "$p" --dry-run
  [ "$status" -ne 0 ]; [[ "$output" == *"route"* ]]
}

@test "거부: env 시크릿 패턴 / 허용: allowPlaintext" {
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

@test "거부: 원장 예산 초과 / 중복 앱 / internal host 규칙 / 미지 필드 / 태그 형식" {
  p=$(payload big 'kind: api
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 500m, memory: 1Gi } }
replicas: 3')
  run run_onboard "$p" --dry-run; [ "$status" -ne 0 ]; [[ "$output" == *"예산 초과"* ]]
  p=$(payload api 'kind: api
resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 100m, memory: 64Mi } }')
  run run_onboard "$p" --dry-run; [ "$status" -ne 0 ]; [[ "$output" == *"이미 존재"* ]]
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

@test "실쓰기: values/source-repo/KSOPS generator/원장 행이 생성된다 (픽스처 root)" {
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
  grep -q 'ledger:row --> blog' "$fix/docs/memory-ledger.md"
  grep -q 'limit ≈ 328 Mi' "$fix/docs/memory-ledger.md"   # 200 + 128
  rm -rf "$fix"
}

# ── 워크플로 보안 불변식 ─────────────────────────────────────────────────────────
@test "bump: dispatch 경로가 직렬 그룹 공유 + 기존 잡은 workflow_run으로 한정" {
  f="$ROOT/.github/workflows/bump.yaml"
  grep -q 'repository_dispatch' "$f"
  grep -q 'app-image' "$f"
  grep -qE "event_name == 'workflow_run'" "$f"
  grep -qE "event_name == 'repository_dispatch'" "$f"
  # 직렬 그룹은 하나만 (양 경로 공유)
  [ "$(grep -c 'group: values-writeback' "$f")" -eq 1 ]
}

@test "bump dispatch: 비신뢰 payload는 env로만 + source-repo 바인딩 + digest 검증" {
  f="$ROOT/.github/workflows/bump.yaml"
  grep -q 'source-repo' "$f"
  grep -q 'docker manifest inspect' "$f"
  # client_payload 참조는 env 할당(APP:/TAG:/SRC:) 또는 주석에만 등장해야 한다 — run 인라인 보간 금지
  # (BSD grep은 \s 미지원 — POSIX [[:space:]] 사용)
  bad=$(grep -n 'client_payload' "$f" | grep -vE '^[0-9]+:[[:space:]]*(#|(APP|TAG|SRC):)' || true)
  [ -z "$bad" ]
}

@test "onboard: payload는 toJSON→env 경유, PAT로 PR 생성(required check 트리거), ledger 게이트 선행" {
  f="$ROOT/.github/workflows/onboard.yaml"
  grep -q 'toJSON(github.event.client_payload)' "$f"
  grep -q 'DEPLOY_BOT_PAT' "$f"
  grep -q 'verify:ledger' "$f"
  grep -q 'kubeconform' "$f"
}

@test "reusable-app-build: arm64 + jq --arg 인용 + onboard/image 분기 + 승인 게이트 잡" {
  f="$ROOT/.github/workflows/reusable-app-build.yaml"
  grep -q 'workflow_call' "$f"
  grep -q 'linux/arm64' "$f"
  grep -q 'jq -n --arg' "$f"
  grep -q 'app-onboard' "$f"
  grep -q 'app-image' "$f"
  grep -q 'environment: production' "$f"
}
