#!/usr/bin/env bats
# teardown — 앱 ↔ 리소스 분리. 앱 teardown은 DB/캐시를 절대 건드리지 않고,
# 리소스 teardown은 참조 0 + tombstone 2단계 + 백업 게이트를 강제한다.
# ⚠️ 중간 단언은 [ ]만 사용 — bats가 bash 3.2로 돌 때 [[ ]] 실패는 침묵 통과된다.
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 픽스처 **단일 파일**이라 그것으로 닫힌다.
#    여기서 피시험 도구는 **파괴 도구**라 노출 축이 특별하다: `-ne 0`은 "항목이 등록 해제됨"과
#    "파일이 통째로 지워짐"을 같은 초록으로 읽는다 — 후자는 kustomize build를 깨는 정반대 결과다.
#    (실측: 지금 픽스처에서는 아래 대상 파일이 전부 살아남는다. 그 성질이 깨지면 red가 되는 것이 목적이다.)
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
  FR="$TMP/repo"
  mkdir -p "$FR/apps/orders/deploy/prod" "$FR/apps/billing/deploy/prod" \
    "$FR/infra/cloudflare" "$FR/docs" \
    "$FR/platform/cnpg/prod/databases" "$FR/platform/data-conn/prod" "$FR/platform/cache/prod/sessions"
  echo '{"db":["shared"],"redis":["sessions"],"autoDeploy":true}' > "$FR/apps/orders/deploy/prod/.bindings.json"
  echo '{"db":["shared"],"redis":[],"autoDeploy":true}' > "$FR/apps/billing/deploy/prod/.bindings.json"
  echo 'img' > "$FR/apps/orders/deploy/prod/values.yaml"
  cat > "$FR/infra/cloudflare/apps.json" <<'EOF'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "billing", "host": "billing.example.com", "public": true, "active": false }
]
EOF
  cat > "$FR/docs/memory-ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->
| <!-- ledger:row --> orders | prod | 64 | 128 |
| <!-- ledger:row --> billing | prod | 64 | 128 |

**합계:** req ≈ 128 Mi · limit ≈ 256 Mi (반드시 ≤ 8704 Mi 유지).
EOF
  # 리소스 산출물 (Phase 5 모양) — provision-db/-cache가 만드는 파일 + kustomization 등록
  printf 'kind: Database\nspec: { ensure: present }\n' > "$FR/platform/cnpg/prod/databases/shared.yaml"
  touch "$FR/platform/cnpg/prod/databases/db-shared-owner.sealed.yaml" \
    "$FR/platform/cnpg/prod/databases/db-shared-ro.sealed.yaml" \
    "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" \
    "$FR/platform/data-conn/prod/db-shared-ro-conn.sealed.yaml" \
    "$FR/platform/data-conn/prod/cache-sessions-conn.sealed.yaml" \
    "$FR/platform/data-conn/prod/cache-sessions-ro-conn.sealed.yaml"
  cat > "$FR/platform/cnpg/prod/databases/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: database
resources:
  - shared.yaml
  - db-shared-owner.sealed.yaml
  - db-shared-ro.sealed.yaml
EOF
  cat > "$FR/platform/data-conn/prod/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-shared-conn.sealed.yaml
  - db-shared-ro-conn.sealed.yaml
  - cache-sessions-conn.sealed.yaml
  - cache-sessions-ro-conn.sealed.yaml
EOF
  cat > "$FR/platform/cache/prod/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cache
resources:
  - sessions
EOF
  # pgdump 헤지 — DBS 손 목록. drop이 여기서 이름을 빼야 헤지 잡(`set -e`)이 DROP된 DB에서 죽지
  # 않고, test_pgdump_hedge.bats의 **집합 등식**(present CR은 DBS에 포함 · absent CR은 부재 ·
  # CR이 아예 없는 토큰도 red)도 함께 만족한다 — 세 번째 항이 티켓 53이 얹은 상한이다.
  # 실 매니페스트의 DBS 줄 형태(들여쓰기 18칸 + 인용)를 그대로 복제하고, 꼬리 보존을 재려고
  # **뒤따르는 주석**을 붙인다 — 편집 대상이 셸 스크립트 본문 한 줄이라 꼬리를 잃으면 의미가 변한다.
  # shared-archive는 **CR 파일이 없는** 이름이다(목록에만 사는 잔존 토큰 — drop no-CR 레인의 피연산자).
  HEDGE="$FR/platform/cnpg/prod/pgdump-hedge-cronjob.yaml"
  cat > "$HEDGE" <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pg-dump-hedge-r2
  namespace: database
spec:
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: pgdump-hedge
              args:
                - |
                  set -euo pipefail
                  DBS="app shared shared-archive" # app이 선두 = 복구 우선순위
                  for DB in ${DBS}; do
                    echo "[hedge] ${DB}"
                  done
EOF
  # 동봉 계약 매니페스트 — orders는 등재돼 있고 billing은 아니다(제거 축과 무변경 축을 한 픽스처에서 잰다).
  mkdir -p "$FR/tools"
  VC="$FR/tools/vendored-contract.json"
  cat > "$VC" <<'JSON'
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
        },
        {
          "repo": "orders",
          "ref": "main",
          "path": "tools/seal-secret.mts",
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
        },
        {
          "repo": "orders",
          "ref": "main",
          "path": "tools/sealed-secrets-cert.pem",
          "normalize": "exact"
        }
      ]
    }
  ]
}
JSON
  mkdir -p "$FR/platform/victoria-stack/prod"
  printf 'apiVersion: batch/v1\nkind: CronJob\nmetadata: { name: digest-exporter }\nspec:\n  jobTemplate:\n    spec:\n      template:\n        spec:\n          containers:\n            - name: digest-exporter\n              env:\n                - name: APPS\n                  value: "orders=ghcr.io/ukyi-app/orders:sha-x"\n' > "$FR/platform/victoria-stack/prod/digest-exporter.yaml"
}
teardown() { rm -rf "$TMP"; }

# teardown-resource는 모든 모드에서 --refs-verified attestation 필수(F1 강화) — 자동 refcount 대체.
# 래퍼는 attestation을 항상 전달; 누락 거부는 별도 테스트에서 ${ROOT} raw 호출로 검증.
tdr() { bun "$ROOT/tools/teardown-resource.ts" --refs-verified manual-test "$@"; }

# 헤지 DBS 판정 — 토큰 단위다(부분 문자열 금지: shared ∈ "shared-archive"는 거짓이어야 한다).
dbs_line() { sed -n 's/^ *DBS="\([^"]*\)".*/\1/p' "$1"; }
dbs_count() { c=0; for t in $(dbs_line "$1"); do if [ "$t" = "$2" ]; then c=$((c + 1)); fi; done; echo "$c"; }

# ── teardown-app ─────────────────────────────────────────────────────────────

@test "teardown-app removes only app-scoped artifacts, never db/cache resources" {
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.remove | any(. == "apps/orders")'
  echo "$output" | jq -e '.appsJsonRow.name == "orders"'
  # conn Secret/Database CR/Valkey는 제거 대상 목록에 절대 없다
  bad=$(echo "$output" | jq -r '.remove[]' | grep -E "data-conn|databases|cache/prod" || true)
  [ -z "$bad" ]
}

@test "teardown-app really removes the app dir, registry row, ledger row (idempotent)" {
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  [ "$status" -eq 0 ]
  [ ! -d "$FR/apps/orders" ]
  run jq -e 'map(select(.name == "orders")) | length == 0' "$FR/infra/cloudflare/apps.json"
  [ "$status" -eq 0 ]
  # 원장을 증언하는 형제 단언이 없다 — 아래 [ -f ]들은 리소스 산출물이라 원장 삭제를 못 본다
  run grep "ledger:row --> orders" "$FR/docs/memory-ledger.md"
  [ "$status" -eq 1 ]
  # 리소스 산출물 무손상
  [ -f "$FR/platform/cnpg/prod/databases/shared.yaml" ]
  [ -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
  # 멱등: 한 번 더 → 0 종료
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  [ "$status" -eq 0 ]
}

# ── teardown-resource ────────────────────────────────────────────────────────

@test "any teardown is refused without --refs-verified attestation (F1 enforceable guard)" {
  # raw 호출(${ROOT} 중괄호 — tdr 래퍼 우회): attestation 누락이면 거부돼야 한다.
  run bun "${ROOT}/tools/teardown-resource.ts" --db shared --repo-root "$FR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "refs-verified"
}

@test "retain proceeds with --refs-verified <id> (auto refcount replaced by attestation)" {
  run bun "${ROOT}/tools/teardown-resource.ts" --db shared --refs-verified manual-2026-06-25 --repo-root "$FR"
  [ "$status" -eq 0 ]
  run jq -e '.["db:shared"].state == "retained"' "$FR/platform/data-conn/prod/.tombstones.json"
  [ "$status" -eq 0 ]
}

@test "teardown-resource retain (default) tombstones a zero-ref resource without deleting" {
  bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  bun "$ROOT/tools/teardown-app.ts" --app billing --repo-root "$FR"
  run tdr --db shared --repo-root "$FR"
  [ "$status" -eq 0 ]
  # 보존: CR/conn 전부 유지 + tombstone 기재 (접근 가능 상태 그대로)
  [ -f "$FR/platform/cnpg/prod/databases/shared.yaml" ]
  [ -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
  run jq -e '.["db:shared"].state == "retained"' "$FR/platform/data-conn/prod/.tombstones.json"
  [ "$status" -eq 0 ]
}

@test "purge without a verified backup id is refused (data deletion gate)" {
  bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  bun "$ROOT/tools/teardown-app.ts" --app billing --repo-root "$FR"
  run tdr --db shared --repo-root "$FR" --delete-data --step drop
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "backup"
}

@test "purge state machine: drop sets ensure absent; cleanup removes artifacts (resumable)" {
  bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  bun "$ROOT/tools/teardown-app.ts" --app billing --repo-root "$FR"
  run tdr --db shared --repo-root "$FR" --delete-data \
    --backup-verified barman-20260612 --step drop
  [ "$status" -eq 0 ]
  run grep "ensure: absent" "$FR/platform/cnpg/prod/databases/shared.yaml"
  [ "$status" -eq 0 ]
  # drop 재실행 = 멱등
  run tdr --db shared --repo-root "$FR" --delete-data \
    --backup-verified barman-20260612 --step drop
  [ "$status" -eq 0 ]
  # cleanup은 별도 커밋(별도 revision)용 단계 — CR/conn 제거, role은 워크플로가 cluster.yaml에서
  run tdr --db shared --repo-root "$FR" --delete-data \
    --backup-verified barman-20260612 --step cleanup
  [ "$status" -eq 0 ]
  [ ! -f "$FR/platform/cnpg/prod/databases/shared.yaml" ]
  [ ! -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
  run jq -e '.["db:shared"].state == "purged"' "$FR/platform/data-conn/prod/.tombstones.json"
  [ "$status" -eq 0 ]
}

@test "purge cleanup deregisters every removed file from its kustomization (no broken render)" {
  bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  bun "$ROOT/tools/teardown-app.ts" --app billing --repo-root "$FR"
  # cleanup은 drop **뒤**에만 온다 — CR이 아직 ensure: present면 fail-closed다(살아 있는 DB를
  # 헤지 백업 목록에서 빼는 동작이라). 상태머신 순서를 지켜 cleanup에 정상 도달시킨다.
  tdr --db shared --repo-root "$FR" --delete-data --backup-verified barman-1 --step drop
  run tdr --db shared --repo-root "$FR" --delete-data \
    --backup-verified barman-1 --step cleanup
  [ "$status" -eq 0 ]
  # 파일 제거 (owner/ro 비밀번호 sealed 포함)
  [ ! -f "$FR/platform/cnpg/prod/databases/shared.yaml" ]
  [ ! -f "$FR/platform/cnpg/prod/databases/db-shared-owner.sealed.yaml" ]
  [ ! -f "$FR/platform/cnpg/prod/databases/db-shared-ro.sealed.yaml" ]
  [ ! -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
  # kustomization 등록 해제 — 남아 있으면 kustomize build가 missing file로 죽는다
  # cnpg 쪽 kustomization에는 양성 대조가 없다(resources 3개가 전부 제거 대상) — rc만이 실재 증인이다
  run grep -E "shared\.yaml|db-shared" "$FR/platform/cnpg/prod/databases/kustomization.yaml"
  [ "$status" -eq 1 ]
  run grep "db-shared" "$FR/platform/data-conn/prod/kustomization.yaml"
  [ "$status" -eq 1 ]
  # cache conn 항목은 무관하므로 보존
  run grep "cache-sessions-conn" "$FR/platform/data-conn/prod/kustomization.yaml"
  [ "$status" -eq 0 ]
  # cleanup 재실행 = 멱등
  run tdr --db shared --repo-root "$FR" --delete-data \
    --backup-verified barman-1 --step cleanup
  [ "$status" -eq 0 ]
}

@test "cache purge cleanup deregisters the instance dir and its conns" {
  bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  run tdr --cache sessions --repo-root "$FR" --delete-data \
    --backup-verified rdb-1 --step cleanup
  [ "$status" -eq 0 ]
  # cache kustomization의 resources는 `sessions` 하나뿐이라 양성 대조를 세울 항목이 없다 — rc가 유일한 증인
  run grep "sessions" "$FR/platform/cache/prod/kustomization.yaml"
  [ "$status" -eq 1 ]
  run grep "cache-sessions" "$FR/platform/data-conn/prod/kustomization.yaml"
  [ "$status" -eq 1 ]
  # db 항목은 무관하므로 보존
  run grep "db-shared-conn" "$FR/platform/data-conn/prod/kustomization.yaml"
  [ "$status" -eq 0 ]
}

@test "cache teardown removes only that instance dir and its conn (per-app pvc isolation)" {
  bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  run tdr --cache sessions --repo-root "$FR" --delete-data \
    --backup-verified rdb-20260612 --step cleanup
  [ "$status" -eq 0 ]
  [ ! -d "$FR/platform/cache/prod/sessions" ]
  [ ! -f "$FR/platform/data-conn/prod/cache-sessions-conn.sealed.yaml" ]
  # db 산출물 무손상
  [ -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
}

@test "teardown-resource cache purge cleanup removes the cache-name ledger row (budget leak fix)" {
  D="$(mktemp -d)"; mkdir -p "$D/docs" "$D/apps" "$D/platform/data-conn/prod" "$D/platform/cache/prod/widget"
  printf '%s\n' '<!-- LIMIT_BUDGET_MIB=8704 -->' \
    '| <!-- ledger:row --> cache-widget   | cache          |     64 |      128 |' \
    '**합계:** req ≈ 64 Mi · limit ≈ 128 Mi (≤ 8704 Mi).' > "$D/docs/memory-ledger.md"
  echo '{}' > "$D/platform/data-conn/prod/.tombstones.json"
  run tdr --cache widget --repo-root "$D" --delete-data --backup-verified test-id --step cleanup
  [ "$status" -eq 0 ]
  run grep -c 'ledger:row --> cache-widget' "$D/docs/memory-ledger.md"
  [ "$output" = "0" ]
  run grep -q '"state": "purged"' "$D/platform/data-conn/prod/.tombstones.json"
  [ "$status" -eq 0 ]
}

@test "teardown-resource cache purge fails loud when totals prose drifted (no silent purge)" {
  D="$(mktemp -d)"; mkdir -p "$D/docs" "$D/apps" "$D/platform/data-conn/prod" "$D/platform/cache/prod/widget"
  printf '%s\n' '<!-- LIMIT_BUDGET_MIB=8704 -->' \
    '| <!-- ledger:row --> cache-widget   | cache          |     64 |      128 |' \
    'totals prose 누락(드리프트)' > "$D/docs/memory-ledger.md"
  echo '{}' > "$D/platform/data-conn/prod/.tombstones.json"
  [ -f "$ROOT/tools/teardown-resource.ts" ]
  run tdr --cache widget --repo-root "$D" --delete-data --backup-verified test-id --step cleanup
  [ "$status" -ne 0 ]
  # ⚠️ `-ne 0`은 「원장 드리프트로 abort했다」와 「teardown-resource.ts가 없다」를 구별하지 못한다
  #    (실측: 도구 삭제 시 14레인 중 이 레인이 그대로 초록). 실제 abort 문구를 문다.
  printf '%s' "$output" | grep -qF -- 'ledger Totals 프로즈를 찾지 못함' 
  # ⚠️ fail-loud의 증인이 이 한 줄뿐이다 — `-ne 0`이면 도구가 tombstone 파일을 **지워버린** 경우도
  #    "purged로 안 넘어갔다"로 읽혀, 가장 나쁜 실패가 초록이 된다
  run grep -q '"state": "purged"' "$D/platform/data-conn/prod/.tombstones.json"   # fail-loud: purged로 안 넘어가야
  [ "$status" -eq 1 ]
}

@test "teardown-app removes the app from digest-exporter APPS" {
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  [ "$status" -eq 0 ]
  # digest-exporter CronJob 자체가 지워지면 APPS 목록에서 앱을 뺀 것이 아니다 — rc 2를 통과로 읽지 않는다
  run grep -q 'orders=' "$FR/platform/victoria-stack/prod/digest-exporter.yaml"
  [ "$status" -eq 1 ]
}

@test "the dry-run plan judges digest-exporter membership with the kernel, not a partial-match regex" {
  # 같은 실행의 계획과 행동이 다른 문법을 보면, 파괴 PR을 승인하는 사람이 읽는 plan이 실제 diff와
  # 갈린다(_teardown-app.yaml이 그 plan을 PR 본문에 싣는다). 손 정규식 `(^|[" ])<app>=`는 APPS
  # value 밖의 셸 로그 문자열에도 매치했다 — 라이브 재현: `--app app`·`--app ref`.
  printf '              command: ["sh","-c","echo digest scrape failed: app=$APP ref=$REF"]\n' \
    >> "$FR/platform/victoria-stack/prod/digest-exporter.yaml"
  # 대조군 — APPS에 실재하는 항목은 여전히 계획에 오른다(판정을 통째로 끈 것이 아니다).
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.remove | any(. == "digest-exporter APPS 항목")'
  # 본체 — APPS 밖 텍스트에만 있는 이름은 계획에 오르지 않는다(계획 = 행동의 예고).
  run bun "$ROOT/tools/teardown-app.ts" --app app --repo-root "$FR" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.remove | any(. == "digest-exporter APPS 항목") | not'
}

# ── 동봉 계약 target 행(도구가 뺀다 — 커널 tools/lib/vendored-targets.ts) ──────────

@test "teardown-app removes the app's vendored-contract rows and plans them first" {
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.remove | any(. == "vendored-contract target 행")'
  # 계획은 행동의 예고다 — dry-run은 파일을 만지지 않는다.
  before="$(cat "$VC")"
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  [ "$status" -eq 0 ]
  [ "$(cat "$VC")" != "$before" ]
  run jq -e '[.vendored[].targets[] | select(.repo == "orders")] | length == 0' "$VC"
  [ "$status" -eq 0 ]
  # 템플릿 행은 무손상(앱 축만 뺀다 — 계약 자체가 꺼지면 안 된다).
  run jq -e '[.vendored[].targets[] | select(.repo == "homelab-app-template")] | length == 2' "$VC"
  [ "$status" -eq 0 ]
}

@test "an app with no vendored rows leaves the manifest byte-identical and off the plan" {
  before="$(cat "$VC")"
  run bun "$ROOT/tools/teardown-app.ts" --app billing --repo-root "$FR" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.remove | any(. == "vendored-contract target 행") | not'
  run bun "$ROOT/tools/teardown-app.ts" --app billing --repo-root "$FR"
  [ "$status" -eq 0 ]
  [ "$(cat "$VC")" = "$before" ]
}

@test "the anchor-emptying refusal fires in the plan, before any surface is torn down" {
  # 🔴 적대 검토 실측: plan 단계 판정이 `hasAppTargets`뿐이면 그 술어가 **모르는** 두 번째 거부 축
  #    (앵커 행까지 비우는 제거)이 쓰기 시퀀스 중간에서 처음 던졌다 — dry-run은 rc 0으로 전 항목을
  #    약속하고, 실행은 apps/·apps.json·digest-exporter를 이미 쓴 뒤 죽어 원장 행만 남았다(반쪽 철거).
  #    도달 조건: 앵커(템플릿) 행은 손 편집 축이라, 앱 행만 가진 source가 하나 생기면 열린다.
  jq 'del(.vendored[0].targets[] | select(.repo == "homelab-app-template"))' "$VC" > "$TMP/vc.json"
  mv "$TMP/vc.json" "$VC"
  # ⚠️ 비-0만 보면 usage(rc 2)·잘못된 --repo-root·픽스처 붕괴로 죽어도 통과한다(레포 규약:
  #    tests/gates/test_staged-completeness.bats). 그래서 진단이 그 거부를 지목하는지 함께 잰다 —
  #    커널 형제 레인(tools/tests/test_vendored-targets.bats의 앵커 거부)과 같은 형태다.
  #    `::error::teardown-app:` 접두는 fail() 규약 — 없으면 raw 스택트레이스라 GHA 어노테이션에 안 뜬다.
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR" --dry-run
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF '::error::teardown-app:'
  printf '%s\n' "$output" | grep -qF 'tools/seal-secret.mts'
  printf '%s\n' "$output" | grep -qF '앵커'
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF '::error::teardown-app:'
  printf '%s\n' "$output" | grep -qF 'tools/seal-secret.mts'
  # 거부는 어떤 표면도 만지기 전이다 — 네 표면 전부가 철거 전 상태로 살아 있다.
  [ -d "$FR/apps/orders" ]
  run jq -e '[.[] | select(.name == "orders")] | length == 1' "$FR/infra/cloudflare/apps.json"
  [ "$status" -eq 0 ]
  grep -q 'ledger:row --> orders' "$FR/docs/memory-ledger.md"
  grep -q 'orders=ghcr.io/ukyi-app/orders:sha-x' "$FR/platform/victoria-stack/prod/digest-exporter.yaml"
}

@test "a non-canonical manifest survives an unrelated app's teardown untouched (no plan-less rewrite)" {
  # 🔴 적대 검토 실측: 쓰기 가드가 `vcBefore !== null`뿐이면, 그 앱 행이 0개여도 커널이 돌아
  #    `JSON.stringify(…, 2)` **정준화 바이트**를 낸다. `_note`/`_roster` 산문 때문에 손 편집을 받는
  #    파일이라 들여쓰기가 어긋난 순간, 무관한 앱의 철거가 파일 전체를 재포맷해 계획(remove)에
  #    없는 변경으로 철거 PR에 실렸다(이 경로는 add-paths·ALLOWLIST 안이라 잔여물 판정에도 안 걸린다).
  jq --indent 4 '.' "$VC" > "$TMP/vc.json"
  mv "$TMP/vc.json" "$VC"
  before="$(cat "$VC")"
  run bun "$ROOT/tools/teardown-app.ts" --app billing --repo-root "$FR"
  [ "$status" -eq 0 ]
  [ "$(cat "$VC")" = "$before" ]
  # 양성 대조 — 같은 비-정준 픽스처에서 등재된 앱의 철거는 실제로 이 파일을 만진다(무변경이 상수가 아니다).
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  [ "$status" -eq 0 ]
  [ "$(cat "$VC")" != "$before" ]
}

@test "a missing manifest is a quiet no-op for teardown (idempotent removal contract)" {
  # create-app과 방향이 다르다: 거기서는 부재가 '행이 영영 안 들어감'(다음 리컨실이 발화)이지만,
  # 철거에서는 뺄 행 자체가 없다 — 형제 처방(digest-exporter)도 같은 비대칭이다.
  rm "$VC"
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  [ "$status" -eq 0 ]
  [ ! -d "$FR/apps/orders" ]
}

@test "every path teardown-app writes is inside both the workflow add-paths and the wrapper ALLOWLIST" {
  # 🔴 형제 실사고(2026-08-18, `.github/workflows/_create-app.yaml` 주석이 SSOT): 도구가 천장 밖에
  #    쓰면 `git add`가 그 변경을 스테이징하지 않아 커밋에서 조용히 유실된다. 철거 쪽은 그 증인이
  #    없었다 — 여기서 두 천장(디스패처 add-paths · owner-local teardown.sh ALLOWLIST)을 한 번에 잰다.
  sig() { (cd "$FR" && find . -type f -exec cksum {} \; | sed 's|^\([0-9]* [0-9]*\) \./|\1 |' | LC_ALL=C sort); }
  before="$(sig)"
  run bun "$ROOT/tools/teardown-app.ts" --app orders --repo-root "$FR"
  [ "$status" -eq 0 ]
  after="$(sig)"
  # 추가·변경·삭제 전부가 천장 대상이다(제거도 `git add <path>`가 스테이징해야 한다).
  changed="$(comm -3 <(echo "$before") <(echo "$after") | sed 's|^[[:space:]]*||; s|^[0-9]* [0-9]* ||' | LC_ALL=C sort -u)"
  [ -n "$changed" ]

  wf_paths="$(sed -n 's/^ *add-paths: *//p' "$ROOT/.github/workflows/_teardown-app.yaml" | sed 's/\${{[^}]*}}/orders/g')"
  [ -n "$wf_paths" ]
  allow="$(sed -n 's/^ALLOWLIST="\(.*\)"$/\1/p' "$ROOT/scripts/teardown.sh")"
  [ -n "$allow" ]

  covered() {  # $1=경로 $2=천장 목록(공백 구분). 끝이 `/`면 디렉토리 접두, 아니면 파일 또는 디렉토리.
    for p in $2; do
      case "$p" in
        */) case "$1" in "$p"*) return 0 ;; esac ;;
        *)  case "$1" in "$p"|"$p"/*) return 0 ;; esac ;;
      esac
    done
    return 1
  }
  n_changed=0; n_wf=0; n_allow=0; uncovered=""
  for c in $changed; do
    n_changed=$((n_changed + 1))
    if covered "$c" "$wf_paths"; then n_wf=$((n_wf + 1)); else uncovered="$uncovered add-paths:$c"; fi
    if covered "$c" "$allow"; then n_allow=$((n_allow + 1)); else uncovered="$uncovered ALLOWLIST:$c"; fi
  done
  if [ -n "$uncovered" ]; then
    echo "teardown-app이 쓰지만 천장이 안 덮는 경로:$uncovered"
    echo "선언된 add-paths: $wf_paths"
    echo "선언된 ALLOWLIST: $allow"
    return 1
  fi
  # 전수의 상한 — 덮인 건수 == 관측된 변경 건수(진단 문자열이 비었다는 사실만으로는 루프가
  # 0회 돌았을 때도 초록이다).
  [ "$n_wf" = "$n_changed" ]
  [ "$n_allow" = "$n_changed" ]
}

# ── 헤지 DBS 대칭 ───────────────────────────────────────────────────────────

@test "purge drop removes the database from the pgdump hedge DBS in the same step" {
  # 같은 단계인 것이 요점이다: CR이 absent인데 DBS에 이름이 남으면 헤지 잡이 `set -e`로 통째로
  # 죽어 뒤에 선 DB의 덤프까지 잃고, test_pgdump_hedge의 부재 조건도 red가 된다.
  run tdr --db shared --repo-root "$FR" --delete-data --backup-verified barman-1 --step drop
  [ "$status" -eq 0 ]
  run grep "ensure: absent" "$FR/platform/cnpg/prod/databases/shared.yaml"
  [ "$status" -eq 0 ]
  [ "$(dbs_count "$HEDGE" shared)" = "0" ]
  [ "$(dbs_count "$HEDGE" app)" = "1" ]             # 부트스트랩 app 보존
  [ "$(dbs_count "$HEDGE" shared-archive)" = "1" ]  # 토큰 경계 — 접두가 같은 형제는 남는다
}

@test "hedge DBS removal is idempotent across a repeated drop and the later cleanup" {
  tdr --db shared --repo-root "$FR" --delete-data --backup-verified barman-1 --step drop
  run tdr --db shared --repo-root "$FR" --delete-data --backup-verified barman-1 --step drop
  [ "$status" -eq 0 ]
  [ "$(dbs_count "$HEDGE" shared)" = "0" ]
  # cleanup은 이미 빠진 이름에 대해 no-op이어야 한다(재개 가능 상태 머신 — 중단 후 재실행 안전)
  run tdr --db shared --repo-root "$FR" --delete-data --backup-verified barman-1 --step cleanup
  [ "$status" -eq 0 ]
  [ "$(dbs_count "$HEDGE" shared)" = "0" ]
  [ "$(dbs_count "$HEDGE" app)" = "1" ]
}

@test "purge drop --dry-run leaves the hedge DBS untouched" {
  before="$(cat "$HEDGE")"
  run tdr --db shared --repo-root "$FR" --delete-data --backup-verified barman-1 --step drop --dry-run
  [ "$status" -eq 0 ]
  [ "$(cat "$HEDGE")" = "$before" ]
}

@test "retain teardown never touches the hedge DBS (the database keeps existing)" {
  before="$(cat "$HEDGE")"
  run tdr --db shared --repo-root "$FR"
  [ "$status" -eq 0 ]
  [ "$(cat "$HEDGE")" = "$before" ]
}

@test "cache purge never edits the hedge DBS (it is a logical-database surface)" {
  before="$(cat "$HEDGE")"
  run tdr --cache sessions --repo-root "$FR" --delete-data --backup-verified rdb-1 --step cleanup
  [ "$status" -eq 0 ]
  [ "$(cat "$HEDGE")" = "$before" ]
}

@test "purge drop fails closed when the hedge manifest is missing (no half transition)" {
  rm "$HEDGE"
  run tdr --db shared --repo-root "$FR" --delete-data --backup-verified barman-1 --step drop
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'pgdump-hedge-cronjob.yaml'
  # CR은 present 그대로 — DBS를 못 빼면 CR만 absent로 가는 반쪽 전이가 남으면 안 된다
  run grep "ensure: present" "$FR/platform/cnpg/prod/databases/shared.yaml"
  [ "$status" -eq 0 ]
}

# ── 헤지 편집의 선행 조건(대상 실재·단계 순서) ────────────────────────────────

@test "purge drop refuses reserved bootstrap names before touching the hedge DBS" {
  # `--db app`은 부트스트랩 DB다: CR 파일이 없어 옛 판정은 "CR 없음 — 멱등 no-op"이라고 **말하면서**
  # DBS에서는 app을 지웠다. 그 한 번으로 restore_canary를 담은 부트스트랩 DB가 논리 백업 0이 된다.
  # 이름 정책은 provision과 같은 SSOT(identity.resourceNameError)여야 한다 — 예약 이름은 fail-closed.
  before="$(cat "$HEDGE")"
  run tdr --db app --repo-root "$FR" --delete-data --backup-verified barman-1 --step drop
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '예약된 DB 이름'
  [ "$(cat "$HEDGE")" = "$before" ]
  [ "$(dbs_count "$HEDGE" app)" = "1" ]
}

@test "purge drop refuses the reserved -ro suffix with the same policy provision uses" {
  before="$(cat "$HEDGE")"
  run tdr --db shared-ro --repo-root "$FR" --delete-data --backup-verified barman-1 --step drop
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- "'-ro' 접미사 예약"
  [ "$(cat "$HEDGE")" = "$before" ]
}

@test "purge drop with no Database CR leaves the hedge DBS untouched and reports the residue" {
  # shared-archive는 DBS에만 사는 이름이다(CR 파일 없음). 대상 실재를 확인하기 전에 공유 목록을
  # 편집하면 "CR 없음 — 멱등 no-op"이라는 보고와 파일 변경이 서로 모순된다.
  before="$(cat "$HEDGE")"
  run tdr --db shared-archive --repo-root "$FR" --delete-data --backup-verified barman-1 --step drop
  [ "$status" -eq 0 ]
  [ "$(cat "$HEDGE")" = "$before" ]
  [ "$(dbs_count "$HEDGE" shared-archive)" = "1" ]
  echo "$output" | jq -e '.action | test("CR 없음")'
  echo "$output" | jq -e '.hedge | test("잔존")'
}

@test "purge drop leaves the hedge file byte-identical when the name is already absent" {
  # 비정규 공백(이중 공백) 위에서 "없는 이름 제거"가 파일을 쓰면, 멱등 판정이 텍스트 diff라는
  # 사실이 그대로 드러난다 — 재실행이 매번 공유 매니페스트를 건드리는 diff를 낳는다.
  sed 's/DBS="app shared shared-archive"/DBS="app  shared  shared-archive"/' "$HEDGE" > "$TMP/h" && mv "$TMP/h" "$HEDGE"
  printf 'kind: Database\nspec: { ensure: absent }\n' > "$FR/platform/cnpg/prod/databases/shared.yaml"
  sed 's/ shared / /' "$HEDGE" > "$TMP/h2" && mv "$TMP/h2" "$HEDGE"
  before="$(cat "$HEDGE")"
  run tdr --db shared --repo-root "$FR" --delete-data --backup-verified barman-1 --step drop
  [ "$status" -eq 0 ]
  [ "$(cat "$HEDGE")" = "$before" ]
}

@test "purge drop preserves the DBS line indentation, quoting and trailing comment" {
  run tdr --db shared --repo-root "$FR" --delete-data --backup-verified barman-1 --step drop
  [ "$status" -eq 0 ]
  grep -qxF -- '                  DBS="app shared-archive" # app이 선두 = 복구 우선순위' "$HEDGE"
}

@test "purge cleanup refuses to run while the Database CR is still present (drop must come first)" {
  # cleanup의 헤지 제거는 '벨트'로 들어왔지만, drop을 건너뛴 경로에서는 **살아 있는 DB**를 조용히
  # 백업 목록에서 빼는 동작이다. 선행 조건 검사로 바꿔 fail-closed여야 한다.
  before="$(cat "$HEDGE")"
  run tdr --db shared --repo-root "$FR" --delete-data --backup-verified barman-1 --step cleanup
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '--step drop'
  [ "$(cat "$HEDGE")" = "$before" ]
  [ -f "$FR/platform/cnpg/prod/databases/shared.yaml" ]
  [ -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
}

@test "purge cleanup removes the hedge token once the Database CR is absent" {
  printf 'kind: Database\nspec: { ensure: absent }\n' > "$FR/platform/cnpg/prod/databases/shared.yaml"
  run tdr --db shared --repo-root "$FR" --delete-data --backup-verified barman-1 --step cleanup
  [ "$status" -eq 0 ]
  [ "$(dbs_count "$HEDGE" shared)" = "0" ]
  [ "$(dbs_count "$HEDGE" app)" = "1" ]
}

@test "purge cleanup aborts before any removal when the hedge manifest is missing" {
  printf 'kind: Database\nspec: { ensure: absent }\n' > "$FR/platform/cnpg/prod/databases/shared.yaml"
  rm "$HEDGE"
  run tdr --db shared --repo-root "$FR" --delete-data --backup-verified barman-1 --step cleanup
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'pgdump-hedge-cronjob.yaml'
  # rm **전에** abort — 파괴 작업이 이미 지나갔으면 이 두 파일이 없다
  [ -f "$FR/platform/cnpg/prod/databases/shared.yaml" ]
  [ -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
}

@test "purge drop fails closed when the CR has no ensure anchor and leaves both files untouched" {
  # L5의 반대 방향 증인: 헤지는 CR 편집보다 먼저 조립되지만 write는 CR 단언 **뒤**에 있다. CR에
  # `ensure:`도 bare `spec:` 줄도 없으면 absent 전환을 조립할 수 없고, 그때 헤지가 이미 쓰였다면
  # "헤지엔 없는데 CR은 present"라는 반쪽 전이가 남는다 — 두 파일 모두 바이트 동일이어야 한다.
  CR="$FR/platform/cnpg/prod/databases/shared.yaml"
  printf 'apiVersion: postgresql.cnpg.io/v1\nkind: Database\nmetadata:\n  name: shared\nspec: { cluster: { name: pg }, name: shared, owner: shared }\n' > "$CR"
  before_h="$(cat "$HEDGE")"; before_c="$(cat "$CR")"
  run tdr --db shared --repo-root "$FR" --delete-data --backup-verified barman-1 --step drop
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "ensure를 설정하지 못함"
  [ "$(cat "$HEDGE")" = "$before_h" ]
  [ "$(cat "$CR")" = "$before_c" ]
  [ "$(dbs_count "$HEDGE" shared)" = "1" ]
}

@test "purge cleanup leaves the hedge DBS untouched when no Database CR file exists" {
  # drop의 불변식(대상이 실재하지 않으면 공유 목록을 편집하지 않는다)은 cleanup에도 같다 — CR 파일이
  # 이미 없는 재실행·손 삭제 경로에서 잔존 토큰을 보고만 하고 나머지 정리는 멱등하게 이어간다.
  rm "$FR/platform/cnpg/prod/databases/shared.yaml"
  before="$(cat "$HEDGE")"
  run tdr --db shared --repo-root "$FR" --delete-data --backup-verified barman-1 --step cleanup
  [ "$status" -eq 0 ]
  [ "$(cat "$HEDGE")" = "$before" ]
  [ "$(dbs_count "$HEDGE" shared)" = "1" ]
  echo "$output" | jq -e '.hedge | test("잔존")'
}
