#!/usr/bin/env bats
# create-app 생성기 — .app-config.yml → values.yaml + .bindings.json + apps.json + sealed 시크릿
# ⚠️ 부재 단언 규약(`-eq 1`)은 docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a가 SSOT다.
#    이 파일 고유 사정: 비-0 단언 대부분은 create-app.ts의 **거부 계약**(중복 host·예약 host·
#    봉인 계약 위반)이라 비대상이고, 경로 피연산자는 생성 산출물을 보는 한 곳뿐이다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
  # 픽스처 homelab 루트(원장 + apps.json + 선프로비저닝된 리소스 핸들)
  FR="$TMP/repo"
  mkdir -p "$FR/apps" "$FR/docs" "$FR/infra/cloudflare" \
    "$FR/platform/cnpg/prod/databases" "$FR/platform/data-conn/prod"
  cat > "$FR/docs/memory-ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->
| component | namespace | req_mi | limit_mi |
|---|---|---:|---:|
| <!-- ledger:row --> base | kube-system | 100 | 200 |

**합계:** req ≈ 100 Mi · limit ≈ 200 Mi (반드시 ≤ 8704 Mi 유지).
EOF
  echo '[]' > "$FR/infra/cloudflare/apps.json"
  echo '{"platform_hosts":["argocd-webhook.ukyi.app","files.ukyi.app"]}' > "$FR/infra/cloudflare/reserved-hosts.json"
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
route: { public: true, host: orders.example.com }
deploy: { autoDeploy: false }
EOF
  # 동봉 계약 매니페스트 — 실 트리에는 항상 있는 추적 파일이다(create-app은 부재를 fail-closed로
  # 거부한다: 없는 채로 앱을 만들면 다음 contract-drift 리컨실이 missing-target으로 발화한다).
  mkdir -p "$FR/tools"
  cat > "$FR/tools/vendored-contract.json" <<'JSON'
{
  "_note": "동봉 계약 SSOT(픽스처)",
  "owner": "ukyi-app",
  "scaffoldRepos": [
    "homelab-app-template"
  ],
  "vendored": [
    {
      "source": "tools/seal-secret.mts",
      "targets": [
        {
          "repo": "homelab-app-template",
          "ref": "main",
          "path": "scaffold/common/tools/seal-secret.mts",
          "normalize": "typescript"
        }
      ]
    },
    {
      "source": "tools/sealed-secrets-cert.pem",
      "targets": [
        {
          "repo": "homelab-app-template",
          "ref": "main",
          "path": "scaffold/common/tools/sealed-secrets-cert.pem",
          "normalize": "exact"
        }
      ]
    }
  ]
}
JSON
  mkdir -p "$FR/platform/victoria-stack/prod"
  printf 'apiVersion: batch/v1\nkind: CronJob\nmetadata: { name: digest-exporter }\nspec:\n  jobTemplate:\n    spec:\n      template:\n        spec:\n          containers:\n            - name: digest-exporter\n              env:\n                - name: APPS\n                  value: ""\n' > "$FR/platform/victoria-stack/prod/digest-exporter.yaml"
}
teardown() { rm -rf "$TMP"; }

gen() {
  run bun "$ROOT/tools/create-app.ts" --config "$TMP/.app-config.yml" --app orders \
    --repo ukyi-app/orders --domain example.com --repo-root "$FR" \
    --digest sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    --tag sha-aaa1111000000000000000000000000000000000 "$@"
}

@test "create-app generates values.yaml with digest-pinned image" {
  gen
  [ "$status" -eq 0 ]
  grep -q "ghcr.io/ukyi-app/orders" "$FR/apps/orders/deploy/prod/values.yaml"
  grep -q "digest: sha256:1111" "$FR/apps/orders/deploy/prod/values.yaml"
}

@test "create-app values.yaml has no migrate/db.enabled (migrate removed)" {
  gen
  [ "$status" -eq 0 ]
  # ⚠️ 피연산자가 gen 산출물인데 이 @test에는 양성 형제가 없다 — create-app이 values.yaml을 다른
  #    경로에 쓰게 되면 `-ne 0` 형태는 "migrate 없음"을 조용히 계속 보고했다.
  run grep -E "migrateCmd|^db:" "$FR/apps/orders/deploy/prod/values.yaml"
  [ "$status" -eq 1 ]   # migrate Job 제거 → values.db.enabled/migrateCmd 미생성
}

@test "bindings.json records only autoDeploy (no db/redis — connection is a sealed secret)" {
  gen
  [ "$status" -eq 0 ]
  run jq -e '(has("db")|not) and (has("redis")|not) and .autoDeploy == false' \
    "$FR/apps/orders/deploy/prod/.bindings.json"
  [ "$status" -eq 0 ]
}

@test "create-app registers public app in apps.json with active:true (merge exposes DNS)" {
  gen
  [ "$status" -eq 0 ]
  run jq -e '.[0] == {name:"orders", host:"orders.example.com", public:true, active:true}' \
    "$FR/infra/cloudflare/apps.json"
  [ "$status" -eq 0 ]
}

@test "create-app records an .activation marker for a public app (audit re-exposure gate coverage)" {
  # 공개 생성은 재노출 감사(audit-orphans activation-exposure-drift)가 검사할 .activation 마커를
  # activate-app --flip과 동일 포맷으로 남겨야 한다(마커 없으면 게이트에서 영구 제외).
  gen
  [ "$status" -eq 0 ]
  M="$FR/apps/orders/deploy/prod/.activation"
  [ -f "$M" ]
  run jq -e '.registry == {name:"orders", host:"orders.example.com", public:true}' "$M"
  [ "$status" -eq 0 ]
  # sha/syncedRev는 생성 시점 미확정(PR 머지 sha는 미래)이라 null이어야 한다.
  run jq -e '.sha == null and .syncedRev == null' "$M"
  [ "$status" -eq 0 ]
}

@test "create-app marker surfaceHash matches the committed canonical hash (no activation-surface-drift on merge)" {
  # working-tree에서 산출한 surfaceHash가 커밋 후 surfaceHash(HEAD)와 동일해야 머지 직후 audit이
  # activation-surface-drift(오탐)를 내지 않는다. git 레포로 커밋 후 공용 lib와 대조한다.
  git -C "$FR" init -q -b main; git -C "$FR" config user.email t@t; git -C "$FR" config user.name t
  gen
  [ "$status" -eq 0 ]
  M="$FR/apps/orders/deploy/prod/.activation"
  git -C "$FR" add -A; git -C "$FR" commit -qm "create orders"
  expected=$(bun "$ROOT/tools/lib/surface-hash.ts" "$FR" HEAD orders)
  [ -n "$expected" ]
  run jq -r '.surfaceHash' "$M"
  [ "$output" == "$expected" ]
}

@test "surfaceHash(HEAD) and surfaceHashWorktree agree when the app tree has a symlink" {
  # walk()이 심볼릭 링크를 조용히 건너뛰면
  # surfaceHashWorktree가 surfaceHash(HEAD)와 값이 갈려 활성화 직후 activation-surface-drift가
  # 오탐한다(헤더 :31 「커밋 후 동일한 값」 계약 위반). create-app 산출물 자체는 심볼릭 링크를
  # 만들지 않으므로(gen()으로는 재현 불가) apps/<app> 트리를 직접 구성해 두 함수를 나란히 부른다.
  git -C "$FR" init -q -b main
  git -C "$FR" config user.email t@t
  git -C "$FR" config user.name t
  mkdir -p "$FR/apps/symtest/deploy/prod"
  echo hello > "$FR/apps/symtest/deploy/prod/a.txt"
  ln -s a.txt "$FR/apps/symtest/deploy/prod/link.txt"
  before=$(bun -e "
    import { surfaceHashWorktree } from '$ROOT/tools/lib/surface-hash.ts';
    console.log(surfaceHashWorktree('$FR', 'symtest'));
  ")
  [ -n "$before" ]
  git -C "$FR" add -A
  git -C "$FR" commit -qm "symlink fixture"
  after=$(bun "$ROOT/tools/lib/surface-hash.ts" "$FR" HEAD symtest)
  [ -n "$after" ]
  [ "$before" == "$after" ]
}

@test "create-app rejects duplicate host in apps.json (silent toset collision guard)" {
  echo '[{"name":"other","host":"orders.example.com","public":true,"active":true}]' \
    > "$FR/infra/cloudflare/apps.json"
  gen
  [ "$status" -ne 0 ]
}

@test "create-app copies and validates a sealed secret, registering it in kustomization resources" {
  cat > "$TMP/sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: orders-secrets
  namespace: prod
spec:
  encryptedData: { API_KEY: AgX... }
EOF
  gen --sealed "$TMP/sealed.yaml"
  [ "$status" -eq 0 ]
  [ -f "$FR/apps/orders/deploy/prod/orders-secrets.sealed.yaml" ]
  grep -q "orders-secrets.sealed.yaml" "$FR/apps/orders/deploy/prod/kustomization.yaml"
  grep -q "orders-secrets" "$FR/apps/orders/deploy/prod/values.yaml" # envFrom secretRef
}

@test "create-app writes a checksum/secrets pod annotation so rotation rolls declaratively" {
  cat > "$TMP/sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: orders-secrets
  namespace: prod
spec:
  encryptedData: { API_KEY: AgX... }
EOF
  gen --sealed "$TMP/sealed.yaml"
  [ "$status" -eq 0 ]
  grep -q "checksum/secrets" "$FR/apps/orders/deploy/prod/values.yaml"
}

@test "create-app output satisfies the check-app-deploy checksum gate (raw-byte hash convention, #277 guard)" {
  # 봉인본을 원본 바이트 그대로 기록하고 그 바이트로 checksum을 산출하므로 게이트가 통과해야 한다
  # (update-secrets.ts와 동일 규약 — 재직렬화 드리프트로 checksum이 어긋나던 회귀를 잠근다).
  cat > "$TMP/sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: orders-secrets
  namespace: prod
spec:
  encryptedData: { API_KEY: AgX... }
EOF
  gen --sealed "$TMP/sealed.yaml"
  [ "$status" -eq 0 ]
  run bash "$ROOT/scripts/check-app-deploy.sh" "$FR/apps/orders/deploy/prod"
  [ "$status" -eq 0 ]
}

@test "create-app writes the sealed file verbatim (raw bytes, not re-serialized)" {
  cat > "$TMP/sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: orders-secrets
  namespace: prod
spec:
  encryptedData: { API_KEY: AgX... }
EOF
  gen --sealed "$TMP/sealed.yaml"
  [ "$status" -eq 0 ]
  run diff "$TMP/sealed.yaml" "$FR/apps/orders/deploy/prod/orders-secrets.sealed.yaml"
  [ "$status" -eq 0 ]
}

# 봉인 계약 정책 매트릭스(kind/namespace/name/empty/UPPER_SNAKE)는 커널이 소유한다
# (tools/tests/test_sealed-contract.bats). 여기선 커널 거부가 이 툴의 ::error:: 접두 + exit 1로
# 전파되는지만 증인한다(위임 증인 — 중복 정책 단언은 커널로 이관).
@test "create-app: a sealed-contract rejection surfaces as exit 1 with the tool's ::error:: prefix" {
  cat > "$TMP/sealed.yaml" <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: orders-secrets
  namespace: default
spec:
  encryptedData: {}
EOF
  gen --sealed "$TMP/sealed.yaml"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '::error::create-app: sealed namespace는 prod여야 한다'
}

@test "create-app disables metrics by default for web apps" {
  gen
  [ "$status" -eq 0 ]
  yq -e '.metrics.enabled == false' "$FR/apps/orders/deploy/prod/values.yaml"
}

@test "create-app preserves metrics opt-in from app config" {
  cat >> "$TMP/.app-config.yml" <<'EOF'
metrics: { enabled: true }
EOF
  gen
  [ "$status" -eq 0 ]
  yq -e '.metrics.enabled == true' "$FR/apps/orders/deploy/prod/values.yaml"
}

@test "create-app maps kind=site to internal sws without exposing static.server in app config" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: site
resources: { requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 100m, memory: 64Mi} }
route: { public: false }
EOF
  gen
  [ "$status" -eq 0 ]
  yq -e '.kind == "site" and .static.server == "sws" and .route.host == "orders.home.example.com"' \
    "$FR/apps/orders/deploy/prod/values.yaml"
}

@test "create-app rejects static.server in external app config" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: site
resources: { requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 100m, memory: 64Mi} }
route: { public: false }
static: { server: sws }
EOF
  gen
  [ "$status" -ne 0 ]
}

@test "create-app rejects legacy kind=service with actionable message (rename gate)" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: service
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
route: { public: false }
EOF
  gen
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "web"   # 안내가 신값 web을 가리켜야
}

@test "create-app adds a ledger row and respects the budget gate" {
  gen
  [ "$status" -eq 0 ]
  grep -q "ledger:row --> orders" "$FR/docs/memory-ledger.md"
}

@test "create-app kustomization always exists (ArgoCD kustomize source contract)" {
  gen
  [ "$status" -eq 0 ]
  [ -f "$FR/apps/orders/deploy/prod/kustomization.yaml" ]
}

@test "create-app wires the app into digest-exporter APPS (R6 drift tracking)" {
  gen
  [ "$status" -eq 0 ]
  grep -q 'orders=ghcr.io/ukyi-app/orders:sha-aaa1111' "$FR/platform/victoria-stack/prod/digest-exporter.yaml"
}

# ── 동봉 계약 target 행(도구가 쓴다 — 커널 tools/lib/vendored-targets.ts) ──────────────────
# 종전에는 앱 온보딩 PR에 사람이 이 행 2개를 손으로 넣었다(#691 실측) — 빠뜨리면 contract-drift의
# 로스터 등식이 missing-target으로 발화한다. 이제 create-app이 커널(lib/vendored-targets)로 쓴다.

@test "create-app writes the app's vendored-contract target rows (roster equality lands with the PR)" {
  gen
  [ "$status" -eq 0 ]
  V="$FR/tools/vendored-contract.json"
  run jq -e '[.vendored[].targets[] | select(.repo == "orders")] | length == 2' "$V"
  [ "$status" -eq 0 ]
  run jq -e '[.vendored[] | select(.source == "tools/sealed-secrets-cert.pem") | .targets[] | select(.repo == "orders")] | .[0] == {repo:"orders", ref:"main", path:"tools/sealed-secrets-cert.pem", normalize:"exact"}' "$V"
  [ "$status" -eq 0 ]
  # 템플릿 행은 그대로다(앱 축만 만진다).
  run jq -e '[.vendored[].targets[] | select(.repo == "homelab-app-template")] | length == 2' "$V"
  [ "$status" -eq 0 ]
}

@test "the plan announces the vendored rows and --dry-run writes none of them" {
  before="$(cat "$FR/tools/vendored-contract.json")"
  gen --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.vendoredTargets | length == 2'
  echo "$output" | jq -e '[.vendoredTargets[].path] == ["tools/seal-secret.mts", "tools/sealed-secrets-cert.pem"]'
  [ "$(cat "$FR/tools/vendored-contract.json")" = "$before" ]
}

@test "create-app then teardown-app returns the manifest byte-identical and keeps the roster in equality" {
  # 실 트리는 앱 0건(greenfield)이라 로스터 등식(test_contract-drift.bats)의 판별력이 0이다 —
  # "커널이 쓰는 `repo` 값 == `deriveAppRepos`가 source-repo에서 파생하는 이름"이라는 **결합 명제**를
  # 재는 자리가 없었다(두 반쪽은 따로 고정돼 있다). 그리고 create가 쓰는 집합 == teardown이 빼는
  # 집합이라는 대칭도, 두 스위트가 서로 다른 픽스처에서 독립으로 초록이라 무증인이었다.
  # `--roster`는 오프라인 모드다(라이브 fetch 없음).
  V="$FR/tools/vendored-contract.json"
  before="$(cat "$V")"
  gen
  [ "$status" -eq 0 ]
  # 항진 배제 — 사이에 실제로 앱 행 2개가 서 있었다(왕복이 no-op의 왕복이 아니다).
  run jq -e '[.vendored[].targets[] | select(.repo == "orders")] | length == 2' "$V"
  [ "$status" -eq 0 ]
  run bun "$ROOT/tools/contract-drift-check.ts" --roster --root "$FR" --manifest "$V"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"status": "matched"'
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  [ "$status" -eq 0 ]
  [ "$(cat "$V")" = "$before" ]
  run bun "$ROOT/tools/contract-drift-check.ts" --roster --root "$FR" --manifest "$V"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"status": "greenfield"'
}

@test "a shape-drifted manifest is refused before any surface is written (no half landing)" {
  # 🔴 적대 검토 실측: 「판정·조립은 쓰기 앞이다」(create-app.ts)를 재는 레인이 **파일 부재**
  #    하나뿐이라, 조립을 쓰기 뒤로 옮겨도 이 스위트가 34/34 초록이었다. 그 상태로 형상
  #    드리프트(normalize 열거 밖)를 주면 rc 1인데 apps/orders·apps.json·digest-exporter는
  #    이미 쓰인 반쪽 착지가 난다. 부재 축(아래 레인)과 달리 여기서는 파일이 **있고** 커널이
  #    던진다 — 커널의 거부 축이 전부 이 한 경로를 지난다.
  V="$FR/tools/vendored-contract.json"
  jq '.vendored[0].targets[0].normalize = "TypeScript"' "$V" > "$TMP/vc.json"
  mv "$TMP/vc.json" "$V"
  aj="$(cat "$FR/infra/cloudflare/apps.json")"
  lg="$(cat "$FR/docs/memory-ledger.md")"
  de="$(cat "$FR/platform/victoria-stack/prod/digest-exporter.yaml")"
  gen
  [ "$status" -eq 1 ]
  # 진단은 create-app의 fail() 규약을 지난다 — raw 스택트레이스는 GHA 에러 어노테이션에 안 뜬다.
  printf '%s' "$output" | grep -qF '::error::create-app:'
  printf '%s' "$output" | grep -qF 'normalize'
  # 반쪽 착지 금지는 앱 디렉토리만이 아니라 **앱-외부 표면 전부**에 걸린다.
  [ ! -d "$FR/apps/orders" ]
  [ "$(cat "$FR/infra/cloudflare/apps.json")" = "$aj" ]
  [ "$(cat "$FR/docs/memory-ledger.md")" = "$lg" ]
  [ "$(cat "$FR/platform/victoria-stack/prod/digest-exporter.yaml")" = "$de" ]
}

@test "create-app fails closed when the vendored contract manifest is missing (no silent skip)" {
  # 조용한 skip이면 앱은 만들어지는데 로스터 행만 없어, 다음 리컨실 주기가 missing-target으로
  # 발화한다 — 정확히 이 티켓이 없애는 실패다. 형제 처방: digest-exporter.yaml 부재도 exit 1.
  rm "$FR/tools/vendored-contract.json"
  aj="$(cat "$FR/infra/cloudflare/apps.json")"
  lg="$(cat "$FR/docs/memory-ledger.md")"
  de="$(cat "$FR/platform/victoria-stack/prod/digest-exporter.yaml")"
  gen
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'vendored-contract.json'
  # 반쪽 착지 금지 — 거부는 앱 표면과 앱-외부 표면 어느 쪽도 쓰기 전이다(위 레인과 같은 술어).
  [ ! -d "$FR/apps/orders" ]
  [ "$(cat "$FR/infra/cloudflare/apps.json")" = "$aj" ]
  [ "$(cat "$FR/docs/memory-ledger.md")" = "$lg" ]
  [ "$(cat "$FR/platform/victoria-stack/prod/digest-exporter.yaml")" = "$de" ]
}

@test "create-app rejects a reserved platform host (reserved-hosts.json SSOT)" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
route: { public: true, host: files.ukyi.app }
EOF
  run bun "$ROOT/tools/create-app.ts" --config "$TMP/.app-config.yml" --app orders \
    --repo ukyi-app/orders --domain ukyi.app --repo-root "$FR" \
    --digest sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    --tag sha-aaa1111000000000000000000000000000000000
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "예약 host"
}

@test "create-app rejects an internal app whose host collides with an existing app's route.host (mis-routing guard)" {
  mkdir -p "$FR/apps/other/deploy/prod"
  printf 'route: { host: shared.home.example.com, public: false }\n' > "$FR/apps/other/deploy/prod/values.yaml"
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
route: { public: false, host: shared.home.example.com }
EOF
  run bun "$ROOT/tools/create-app.ts" --config "$TMP/.app-config.yml" --app orders \
    --repo ukyi-app/orders --domain example.com --repo-root "$FR" \
    --digest sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    --tag sha-aaa1111000000000000000000000000000000000
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "이미 배선"
}

@test "every file create-app writes is covered by the workflow's add-paths (staging guard)" {
  # 🔴 2026-08-18: `_create-app.yaml`의 add-paths에 `platform`이 빠져 있었다. create-app.ts는
  #    digest-exporter의 APPS 목록(`platform/victoria-stack/prod/digest-exporter.yaml`)에도 쓰는데,
  #    pr-first-commit의 `git add $ADD_PATHS`가 그 수정을 스테이징하지 않아 커밋에서 조용히 유실되고
  #    parity 게이트가 want≠got으로 red가 된다. `apps/`가 비어 있어 잠복해 있었을 뿐이다.
  # 정적 경로 추출은 거짓 양성을 낸다(도구가 `${ROOT}/tools/...`를 읽기로도 쓴다) → 실제 쓰기를 관측한다.
  sig() { (cd "$FR" && find . -type f -exec cksum {} \; | sed 's|^\([0-9]* [0-9]*\) \./|\1 |' | LC_ALL=C sort); }
  before="$(sig)"
  gen
  [ "$status" -eq 0 ]
  after="$(sig)"
  # 추가·변경된 파일 경로(체크섬이 다르거나 새로 생긴 것)
  changed="$(comm -13 <(echo "$before") <(echo "$after") | sed 's|^[0-9]* [0-9]* ||' | LC_ALL=C sort -u)"
  [ -n "$changed" ]

  # 워크플로가 선언한 add-paths — GitHub 표현식은 픽스처 앱명으로 치환
  wf="$ROOT/.github/workflows/_create-app.yaml"
  paths="$(sed -n 's/^ *add-paths: *//p' "$wf" | sed 's/\${{[^}]*}}/orders/g')"
  [ -n "$paths" ]

  uncovered=""
  for c in $changed; do
    ok=0
    for p in $paths; do
      case "$c" in "$p" | "$p"/*) ok=1; break ;; esac
    done
    [ "$ok" = 1 ] || uncovered="$uncovered $c"
  done
  if [ -n "$uncovered" ]; then
    echo "create-app이 쓰지만 add-paths가 안 덮는 경로:$uncovered"
    echo "선언된 add-paths: $paths"
    return 1
  fi
}

@test "create-app rejects values that only the schema pattern/minItems catch (mini-validator witness)" {
  # 미니 검증기(create-app.ts check())가 pattern/minItems를 **실제로 평가하는지**의 유일한 증인.
  # test_app-config.bats:52는 스키마 JSON과 손으로 베낀 OK Set만 대조하므로 구현이 빠지는 방향을
  # 원리적으로 못 본다(실측: :68 pattern 삭제 + :71 minItems 무력화에도 33/33 초록).
  # ⚠️ tests/gates/test_staged-completeness.bats 헤더가 이 파일의 add-paths 레인을 **이름**으로
  #    인용한다(구 줄번호 인용은 레인이 하나 끼면서 이미 어긋나 있었다).
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
resources: { requests: {cpu: 50m, memory: 32Mi}, limits: {cpu: 200m, memory: "64 mega bytes"} }
route: { public: false }
EOF
  gen
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF -- '불일치'
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
resources: { requests: {cpu: 50m, memory: 32Mi}, limits: {cpu: 200m, memory: 64Mi} }
route: { public: false, paths: [] }
EOF
  gen
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF -- '최소 1개'
}

@test "create-app adds a wiring checklist line only when a same-named conn already exists (floor 2)" {
  # create-app은 앱 자기 봉인본만 envFrom에 넣는다 — db/cache conn 배선은 손 편집 PR이
  # 유일 경로다. 자동 배선은 하지 않고(이름≠앱 케이스), **이미 있는** conn을 체크리스트로 표면화한다.
  # 형식은 create-database가 이미 쓰는 문구(provision-db checklist)와 같다.
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamespace: prod\nresources:\n  - db-orders-conn.sealed.yaml\n  - db-orders-ro-conn.sealed.yaml\n' \
    > "$FR/platform/data-conn/prod/kustomization.yaml"
  gen --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.checklist[]' | grep -q "db-orders-conn"
  echo "$output" | jq -r '.checklist[]' | grep -q "envFrom"
  # 대조군 — 같은 이름의 캐시 conn은 없으므로 캐시 줄은 나오지 않는다(상수 출력이 아님).
  [ "$(echo "$output" | jq -r '.checklist[]' | grep -c "cache-orders-conn")" = "0" ]
  # 부재 축의 양성 대조 — conn 등록이 아예 없으면 배선 줄도 없다.
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamespace: prod\nresources: []\n' \
    > "$FR/platform/data-conn/prod/kustomization.yaml"
  gen --dry-run
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.checklist[]' | grep -c "db-orders-conn")" = "0" ]
  # 체크리스트 자체는 비어 있지 않다(열거 붕괴로 0건이 된 게 아니다).
  [ "$(echo "$output" | jq -r '.checklist | length')" -ge 1 ]
}

# ── autoDeploy 기본값 축(결정 Q4) ──────────────────────────────────────────
# 이 레포의 다른 승인 게이트(bump-poll 누락=false · validate-mutation · activate-app)는 전부
# fail-closed인데 생성기만 `?? true`로 fail-open이었다 — `.app-config.yml`에 deploy 절을 안 쓴 앱이
# 자동 배포로 착지했다는 뜻이다. 기본은 승인 PR이고 자동 배포는 명시 opt-in이다.

@test "an app-config without deploy.autoDeploy yields autoDeploy false (fail-closed default)" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
route: { public: true, host: orders.example.com }
EOF
  gen
  [ "$status" -eq 0 ]
  run jq -e '.autoDeploy == false' "$FR/apps/orders/deploy/prod/.bindings.json"
  [ "$status" -eq 0 ]
}

@test "deploy.autoDeploy true is an explicit opt-in that still reaches bindings" {
  # 양성 대조 — 기본값 반전이 "필드를 통째로 무시한다"로 접히지 않았음을 가른다.
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
route: { public: true, host: orders.example.com }
deploy: { autoDeploy: true }
EOF
  gen
  [ "$status" -eq 0 ]
  run jq -e '.autoDeploy == true' "$FR/apps/orders/deploy/prod/.bindings.json"
  [ "$status" -eq 0 ]
}

@test "an empty deploy block is the same as a missing one (fail-closed)" {
  # `deploy: {}`는 "절을 썼지만 값을 안 썼다" — 누락과 같은 판정이어야 한다(옵셔널 체이닝 경로).
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
route: { public: true, host: orders.example.com }
deploy: {}
EOF
  gen
  [ "$status" -eq 0 ]
  run jq -e '.autoDeploy == false' "$FR/apps/orders/deploy/prod/.bindings.json"
  [ "$status" -eq 0 ]
}

@test "the fail-closed default and its opt-in key are stated in prose (tools README + AGENTS + apps README)" {
  # 기본값 반전은 opt-in 경로가 문서에 없으면 그냥 고장으로 읽힌다("왜 자동 배포가 안 되나").
  # 세 표면 전부가 ① 기본이 승인 PR임과 ② 그것을 여는 키를 함께 말해야 한다.
  n=0
  for f in tools/README.md AGENTS.md apps/README.md; do
    grep -qF 'deploy.autoDeploy: true' "$ROOT/$f"
    grep -qF '승인 PR' "$ROOT/$f"
    n=$((n + 1))
  done
  # 열거 바닥값 — 루프가 0바퀴 돌면 위 단언이 하나도 실행되지 않고 통과한다.
  [ "$n" -eq 3 ]
}
