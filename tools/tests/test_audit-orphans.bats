#!/usr/bin/env bats
# audit-orphans — registry/매니페스트/원장 교차 드리프트 리포트 (읽기 전용; db/redis 바인딩 교차는 제거)
# ⚠️ 중간 단언은 [ ]만 사용 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
  FR="$TMP/repo"
  mkdir -p "$FR/apps/orders/deploy/prod" "$FR/infra/cloudflare" "$FR/docs" \
    "$FR/platform/cnpg/prod/databases" "$FR/platform/data-conn/prod" "$FR/platform/cache/prod"
  printf 'image: {repo: x, tag: sha-abc1234}\nroute: {public: true, host: orders.example.com}\n' \
    > "$FR/apps/orders/deploy/prod/values.yaml"
  echo '{"db":["shared"],"redis":[],"autoDeploy":true}' > "$FR/apps/orders/deploy/prod/.bindings.json"
  # active&&public 앱은 .activation 마커(registry projection)가 필수 — 없으면 missing-activation(차단).
  # $FR은 git 레포가 아니라 surfaceHash(HEAD)가 ""여서 surface-drift는 안 나온다(registry만 유효).
  printf '{"app":"orders","sha":null,"syncedRev":null,"surfaceHash":"seed","registry":{"name":"orders","host":"orders.example.com","public":true}}\n' \
    > "$FR/apps/orders/deploy/prod/.activation"
  cat > "$FR/infra/cloudflare/apps.json" <<'EOF'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "ghost", "host": "ghost.example.com", "public": true, "active": true }
]
EOF
  cat > "$FR/docs/memory-ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->
| <!-- ledger:row --> orders | prod | 64 | 128 |
| <!-- ledger:row --> stale-app | prod | 64 | 128 |
EOF
  # 워커의 `apps` 유닛 스코프는 tracked 열거다 — 픽스처도 추적 파일이어야 한다.
  # ⚠️ 커밋은 하지 않는다: HEAD가 없어야 surfaceHash(HEAD)가 ""를 유지해 surface-drift가 안 나온다
  # (위 주석의 성질 보존).
  printf 'kind: Database\n' > "$FR/platform/cnpg/prod/databases/shared.yaml"
  touch "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml"
  printf 'kind: Database\n' > "$FR/platform/cnpg/prod/databases/lonely.yaml"
  touch "$FR/platform/data-conn/prod/db-lonely-conn.sealed.yaml"
  # ⚠️ 의도적으로 data-conn/prod/kustomization.yaml을 여기서 만들지 않는다 — 위 두 conn 봉인본은
  # 이 스위트 대부분에서 inert(무배선)로 남아야 한다. conn 축을 겨냥하는 @test만 이 파일을
  # 직접 쓴다(직접 쓰지 않는 @test가 등록 없이 두 파일을 disk에 남기면 unwired-conn(역방향,
  # 감사 5라운드 set-kustomization-8)이 뜨므로, 그런 @test는 대신 두 파일을 정리한다).
  # cluster.yaml managed.roles — roles 도메인의 바닥값(기본 1)이 보는 자리다. 이 스위트의 도메인은
  # roles가 아니므로 **고아가 아닌** role 하나만 둔다(passwordSecret sealed 실재 → dangling-role 미발화).
  # 형제 스위트(test_audit-dangling-role.bats)가 고아 role 쪽을 진다.
  cat > "$FR/platform/cnpg/prod/cluster.yaml" <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: pg }
spec:
  managed:
    roles:
      - name: shared_owner
        passwordSecret: { name: db-shared-owner }
YAML
  touch "$FR/platform/cnpg/prod/databases/db-shared-owner.sealed.yaml"
  git -C "$FR" init -q; git -C "$FR" add -A
}
teardown() { rm -rf "$TMP"; }

@test "audit reports an active registry row whose app manifests are gone (orphan dns)" {
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "orphan-dns" and .subject == "ghost")'
}

@test "audit no longer emits dangling-binding/unreferenced-resource (connection is a sealed secret)" {
  # .bindings.json에 db/redis 참조가 없어 바인딩↔리소스 교차가 사라졌다 — 두 유형 모두 미발화.
  echo '{"db":["missing"],"redis":[],"autoDeploy":true}' > "$FR/apps/orders/deploy/prod/.bindings.json"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 0 ]
  run sh -c "bun '$ROOT/tools/audit-orphans.ts' --repo-root '$FR' | jq -e '.findings | any(.type == \"dangling-binding\" or .type == \"unreferenced-resource\")'"
  [ "$status" -ne 0 ]   # 해당 유형 0건
}

@test "audit reports stale ledger rows (prod row without app dir)" {
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "stale-ledger-row" and .subject == "stale-app")'
}

@test "audit --ci blocks orphan-dns but passes stale-ledger (no false PR block)" {
  # 픽스처엔 orphan-dns(ghost)+stale-ledger-row(stale-app)가 있다 → --ci는 orphan-dns가 blocking이므로 비-0
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
  [ "$status" -ne 0 ]
  # ghost(orphan-dns)만 제거 — stale-app(원장 드리프트)는 남긴다(non-blocking)
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$FR/infra/cloudflare/apps.json"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
  [ "$status" -eq 0 ]   # stale-ledger-row(stale-app)가 남아도 --ci는 통과
  echo "$output" | jq -e '.findings | any(.type == "stale-ledger-row")'
}

@test "audit --strict exits nonzero when findings exist, zero when clean" {
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --strict
  [ "$status" -ne 0 ]
  # ghost 행/stale 행/lonely 제거 → clean. active 앱은 valid .activation 마커가 있어야 clean(races-5 불변식).
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$FR/infra/cloudflare/apps.json"
  printf '{"app":"orders","sha":"abc1234","surfaceHash":"seed","registry":{"name":"orders","host":"orders.example.com","public":true}}\n' \
    > "$FR/apps/orders/deploy/prod/.activation"
  sed -i '' '/stale-app/d' "$FR/docs/memory-ledger.md" 2>/dev/null || sed -i '/stale-app/d' "$FR/docs/memory-ledger.md"
  rm "$FR/platform/cnpg/prod/databases/lonely.yaml" "$FR/platform/data-conn/prod/db-lonely-conn.sealed.yaml"
  # setup()의 shared conn 봉인본도 정리한다 — 이 @test는 conn 축과 무관해 배선하지 않고 두는데
  # (setup() 헤더 주석), 등록 없이 disk에 남기면 unwired-conn(역방향)이 새로 떠 "clean" 어서션이
  # 깨진다. 실제로는 무관한 잔재라 배선 대신 제거가 맞다.
  rm "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --strict
  [ "$status" -eq 0 ]
}

@test "audit REPORTS surface drift for an active app changed after activation (informational, non-blocking)" {
  # active:true + .activation 마커(옛 tree-hash) + 그 후 apps/<app> 표면 변경 → drift.
  # git repo로 tree-hash를 계산한다(마커 포맷과 동일 알고리즘).
  G="$TMP/git"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  git -C "$G" add -A; git -C "$G" commit -qm init
  oldhash=$(bun "$ROOT/tools/lib/surface-hash.ts" "$G" HEAD orders)  # .activation 제외 canonical
  printf '{"app":"orders","sha":"abc1234","syncedRev":"abc1234","surfaceHash":"%s","registry":{"name":"orders","host":"orders.example.com","public":true}}\n' "$oldhash" \
    > "$G/apps/orders/deploy/prod/.activation"
  # 마커 기록 후 표면 변경
  printf 'image: {repo: x, tag: sha-NEW9999}\nroute: {public: true, host: orders.example.com}\n' \
    > "$G/apps/orders/deploy/prod/values.yaml"
  git -C "$G" add -A; git -C "$G" commit -qm "surface change post-activation"
  # apps.json: orders만 active:true (ghost 제거해 orphan-dns 노이즈 배제)
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  # ⚠️ codex pass3 F1: surface-drift는 정보성 — --ci를 막지 않는다(정상 bump 데드락 방지). 리포트는 된다.
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$G" --ci
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "activation-surface-drift"
}

@test "activation-surface-drift is report-only — excluded from the alerting count (still in findings)" {
  # B: surface-drift는 설계상 비차단·정보성이고 **이미지 bump마다 재발**한다 → 텔레그램 페이지 대상에서 제외.
  # 감사 JSON엔 남아(findings/count) 가시성 유지하되 alerting=0이라 audit.yaml이 페이지하지 않는다.
  G="$TMP/git-ro"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  # surface-drift **단독**으로 격리 — 다른 finding 원천 제거: ledger의 stale-app 행 삭제(orders만 남김) +
  # setup()의 무배선 conn 봉인본 2개(shared·lonely) 제거(안 그러면 unwired-conn이 새로 뜬다 —
  # 감사 5라운드 set-kustomization-8, 이 스위트의 conn 축과 무관).
  printf '<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->\n| <!-- ledger:row --> orders | prod | 64 | 128 |\n' \
    > "$G/docs/memory-ledger.md"
  rm -f "$G/platform/data-conn/prod/db-shared-conn.sealed.yaml" "$G/platform/data-conn/prod/db-lonely-conn.sealed.yaml"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  git -C "$G" add -A; git -C "$G" commit -qm init
  oldhash=$(bun "$ROOT/tools/lib/surface-hash.ts" "$G" HEAD orders)
  printf '{"app":"orders","sha":"abc1234","syncedRev":"abc1234","surfaceHash":"%s","registry":{"name":"orders","host":"orders.example.com","public":true}}\n' "$oldhash" \
    > "$G/apps/orders/deploy/prod/.activation"
  printf 'image: {repo: x, tag: sha-NEW9999}\nroute: {public: true, host: orders.example.com}\n' \
    > "$G/apps/orders/deploy/prod/values.yaml"
  git -C "$G" add -A; git -C "$G" commit -qm "surface change post-activation"
  # apps.json: orders만 active(ghost 제거해 다른 finding 배제) → 유일 finding = activation-surface-drift
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$G"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "activation-surface-drift")'   # findings엔 남는다
  echo "$output" | jq -e '.count >= 1'
  echo "$output" | jq -e '.alerting == 0'                                          # 페이지 대상 0
}

@test "a co-occurring alerting drift is NOT hidden by a report-only surface-drift (alerting counts only the pageable)" {
  # surface-drift(report-only) + orphan-dns(blocking·alerting) 공존 → count=2, alerting=1(orphan-dns만).
  # report-only가 다른 실측 finding의 페이지를 삼키지 않음을 못박는다.
  G="$TMP/git-mix"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  git -C "$G" add -A; git -C "$G" commit -qm init
  oldhash=$(bun "$ROOT/tools/lib/surface-hash.ts" "$G" HEAD orders)
  printf '{"app":"orders","sha":"abc1234","syncedRev":"abc1234","surfaceHash":"%s","registry":{"name":"orders","host":"orders.example.com","public":true}}\n' "$oldhash" \
    > "$G/apps/orders/deploy/prod/.activation"
  printf 'image: {repo: x, tag: sha-NEW9999}\nroute: {public: true, host: orders.example.com}\n' \
    > "$G/apps/orders/deploy/prod/values.yaml"
  git -C "$G" add -A; git -C "$G" commit -qm "surface change"
  # apps.json: orders(surface-drift) + ghost(active·매니페스트 부재=orphan-dns 차단)
  cat > "$G/infra/cloudflare/apps.json" <<'EOF'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "ghost", "host": "ghost.example.com", "public": true, "active": true }
]
EOF
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$G"
  echo "$output" | jq -e '.findings | any(.type == "activation-surface-drift")'
  echo "$output" | jq -e '.findings | any(.type == "orphan-dns" and .subject == "ghost")'
  echo "$output" | jq -e '.alerting >= 1'    # orphan-dns는 페이지된다(surface-drift가 안 삼킴)
  # alerting = count - (report-only 건수). surface-drift 1건 제외됨을 확인.
  echo "$output" | jq -e '(.alerting) == (.count - 1)'
}

@test "audit does NOT flag an active app whose surface matches AFTER the .activation marker is committed (F3 regression)" {
  G="$TMP/git2"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  git -C "$G" add -A; git -C "$G" commit -qm init
  # ⚠️ codex pass1 F3: canonical surfaceHash(.activation 제외)로 마커를 만들고 .activation을 **커밋**한다.
  # 커밋이 apps/orders 트리를 바꿔도 canonical 해시는 불변이라 drift가 없어야 한다(자기 무효화 회귀).
  curhash=$(bun "$ROOT/tools/lib/surface-hash.ts" "$G" HEAD orders)
  printf '{"app":"orders","sha":"abc1234","syncedRev":"abc1234","surfaceHash":"%s","registry":{"name":"orders","host":"orders.example.com","public":true}}\n' "$curhash" \
    > "$G/apps/orders/deploy/prod/.activation"
  git -C "$G" add -A; git -C "$G" commit -qm "activate orders (+.activation marker)"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$G"
  [ "$status" -eq 0 ]
  run sh -c 'echo "$1" | grep -c activation-surface-drift' _ "$output"
  [ "$output" -eq 0 ]
}

@test "audit BLOCKS an active+public app that has no .activation marker (create-app/activate-app must record one)" {
  # 마커가 없으면 유일 차단 재노출 게이트(activation-exposure-drift)가 registry projection 부재로 이 앱을
  # 영구 제외한다(감사 사각). create-app(공개 생성)·activate-app(--flip) 둘 다 마커를 기록하므로 부재 = BLOCKING.
  G="$TMP/git3"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  rm -f "$G/apps/orders/deploy/prod/.activation"
  git -C "$G" add -A; git -C "$G" commit -qm init
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$G" --ci
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "missing-activation"
}

@test "audit accepts an active+public app that has a valid .activation marker (create-app/activate-app path)" {
  # setup의 orders는 registry projection을 담은 .activation 마커가 있으므로 missing-activation 미발화·--ci 통과.
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$FR/infra/cloudflare/apps.json"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
  [ "$status" -eq 0 ]
  run bash -c "bun '$ROOT/tools/audit-orphans.ts' --repo-root '$FR' | jq -e '.findings | any(.type == \"missing-activation\")'"
  [ "$status" -ne 0 ]
}

@test "an inactive (active:false) orphan row is non-blocking info, not orphan-dns" {
  # dns.tf는 public && active만 노출 — active:false orphan은 DNS를 노출하지 않으므로 PR을 막으면 안 된다.
  cat > "$FR/infra/cloudflare/apps.json" <<'JSON'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "pending-app", "host": "pending.example.com", "public": true, "active": false }
]
JSON
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
  [ "$status" -eq 0 ]   # active:false orphan은 비차단 → --ci 통과
  # 비차단 정보 유형으로 보고는 된다(가시성 유지)
  echo "$output" | jq -e '.findings | any(.type == "orphan-dns-inactive" and .subject == "pending-app")'
  # 차단 유형(orphan-dns)으로는 잡히지 않는다
  run bash -c "bun '$ROOT/tools/audit-orphans.ts' --repo-root '$FR' | jq -e '.findings | any(.type == \"orphan-dns\" and .subject == \"pending-app\")'"
  [ "$status" -ne 0 ]
}

@test "an active:true orphan row is still blocking under --ci" {
  cat > "$FR/infra/cloudflare/apps.json" <<'JSON'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "ghost", "host": "ghost.example.com", "public": true, "active": true }
]
JSON
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'orphan-dns:ghost'
}

@test "audit BLOCKS exposure drift when apps.json host/public changes after activation (restale2 F1)" {
  # ⚠️ codex pass4 F1 + restale2 F1: 앱 트리 무변경이어도 apps.json host/public가 바뀌면 DNS 노출이 변한다 →
  # 마커 registry projection과 불일치 → activation-exposure-drift는 **차단**(데드락 무관, 미재검증 노출 막음).
  G="$TMP/git5"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name t
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  # ⚠️ surfaceHash는 git ls-tree HEAD:apps/<app>이므로 HEAD가 존재해야(=먼저 commit) 비-empty가 된다.
  # (마커 surfaceHash가 비면 audit이 missing-activation으로 빠져 continue → exposure 검사 자체가 안 돈다.)
  git -C "$G" add -A; git -C "$G" commit -qm init
  curhash=$(bun "$ROOT/tools/lib/surface-hash.ts" "$G" HEAD orders)
  # 마커는 옛 host(orders.example.com)로 기록
  printf '{"app":"orders","sha":"abc1234","syncedRev":"abc1234","surfaceHash":"%s","registry":{"name":"orders","host":"orders.example.com","public":true}}\n' "$curhash" \
    > "$G/apps/orders/deploy/prod/.activation"
  git -C "$G" add -A; git -C "$G" commit -qm "+marker"
  # 앱 트리는 그대로 두고 apps.json host만 변경(노출 표면 변경)
  echo '[{ "name": "orders", "host": "neworders.example.com", "public": true, "active": true }]' \
    > "$G/infra/cloudflare/apps.json"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$G" --ci
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "activation-exposure-drift"
}

@test "audit reports unreferenced conn handles and skips ro-conn (mode-2 debug handles)" {
  # data-conn 등록 conn인데 어느 apps/*/values.yaml envFrom도 참조 안 함 → 정보성 발화(#211 클래스).
  cat > "$FR/platform/data-conn/prod/kustomization.yaml" <<'KEOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-orders-conn.sealed.yaml
  - db-orders-ro-conn.sealed.yaml
  - db-lonely-conn.sealed.yaml
KEOF
  printf 'image: {repo: x, tag: sha-abc1234}\nroute: {public: true, host: orders.example.com}\nenvFrom:\n  - secretRef:\n      name: orders-secrets\n  - secretRef:\n      name: db-orders-conn\n' \
    > "$FR/apps/orders/deploy/prod/values.yaml"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "unreferenced-conn" and .subject == "db-lonely-conn")'
  # 참조된 conn과 ro-conn(의도적 미참조)은 미발화
  run bash -c "bun '$ROOT/tools/audit-orphans.ts' --repo-root '$FR' | jq -e '.findings | any(.type == \"unreferenced-conn\" and (.subject == \"db-orders-conn\" or .subject == \"db-orders-ro-conn\"))'"
  [ "$status" -ne 0 ]
}

@test "with zero deployable apps the unreferenced-conn verdict is vacuous and folded out of the page" {
  # 참조자 집합(apps/*/values.yaml envFrom)이 구조적으로 공집합이라 모든 rw conn이 자동으로 '미참조'다
  # — 판별력 0인 판정이다. 그걸 매일 페이지하면 유일한 정보성 드리프트 채널이 학습된 무시로 죽는다
  # (라이브: 앱 0개가 된 2026-08-12 이후 매일 같은 「드리프트 감사 · 3건」). findings에는 그대로 남긴다.
  G="$TMP/noapps"; mkdir -p "$G"; cp -R "$FR/." "$G/"
  rm -rf "$G/apps"
  echo '[]' > "$G/infra/cloudflare/apps.json"
  # 남는 finding을 unreferenced-conn 하나로 격리 — 원장 행은 platform/ 실재 컴포넌트로(stale-ledger-row 배제).
  printf '<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->\n| <!-- ledger:row --> data-conn | prod | 64 | 128 |\n' \
    > "$G/docs/memory-ledger.md"
  # shared도 등록해 둔다(디스크엔 $FR에서 복사된 db-shared-conn.sealed.yaml도 있다) — 안 그러면
  # unwired-conn(역방향)이 이 @test가 겨냥하는 축(unreferenced-conn 접힘) 밖에서 alerting을 채운다.
  cat > "$G/platform/data-conn/prod/kustomization.yaml" <<'KEOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-shared-conn.sealed.yaml
  - db-lonely-conn.sealed.yaml
KEOF
  git -C "$G" add -A
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$G"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.scan["audit-orphans:apps"] == 0'
  echo "$output" | jq -e '.findings | any(.type == "unreferenced-conn")'
  echo "$output" | jq -e '.alerting == 0'
}

@test "an app that wires no envFrom still pages unreferenced-conn (the zero-app fold must not swallow #211)" {
  # 대조군. 앱이 있는데 envFrom을 통째로 빠뜨린 상태가 정확히 #211(trip-mate 실재발)이고, 이 판정이
  # 존재하는 이유다. 억제 술어를 `referenced.size === 0`으로 쓰면 그 자리가 함께 묻히는데, 이 레인이
  # 없으면 그 뒤집힘이 무증인이다(뮤테이션이 전건 red여도 픽스처가 안 밟는 조건은 증언되지 않는다).
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$FR/infra/cloudflare/apps.json"
  printf '<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->\n| <!-- ledger:row --> orders | prod | 64 | 128 |\n' \
    > "$FR/docs/memory-ledger.md"
  cat > "$FR/platform/data-conn/prod/kustomization.yaml" <<'KEOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-lonely-conn.sealed.yaml
KEOF
  git -C "$FR" add -A
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.scan["audit-orphans:apps"] == 1'
  echo "$output" | jq -e '.findings | any(.type == "unreferenced-conn")'
  echo "$output" | jq -e '.alerting >= 1'
}

@test "a missing apps.json fails loudly instead of collapsing the registry to zero rows" {
  # 병(라이브 재현): registry가 `readJson(…, [])`로 접히면 **진짜 BLOCKING 위반이 있는 상태에서도**
  # --ci가 rc=0이었다 — BLOCKING 3종이 전부 registry 순회 안에 있어 0행이면 동시에 무발화한다.
  # 대조군 — 마커를 지워 missing-activation(BLOCKING)을 심으면 게이트가 막는다.
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$FR/infra/cloudflare/apps.json"
  rm -f "$FR/apps/orders/deploy/prod/.activation"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
  [ "$status" -ne 0 ]
  out="$output"
  run grep -q "missing-activation" <<<"$out"
  [ "$status" -eq 0 ]
  # 실험군 — 같은 위반 상태에서 apps.json만 치운다. 예전엔 blocking 0 + rc=0(stderr 0줄)이었다.
  rm -f "$FR/infra/cloudflare/apps.json"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
  [ "$status" -eq 1 ]
  out="$output"
  run grep -q "registry 읽기 실패" <<<"$out"
  [ "$status" -eq 0 ]
}

@test "an empty registry trips the scan-floor at any positive floor, and 0 lets it through" {
  # ⚠️ 바닥값을 **명시해서** 부른다 — 기본값은 인-레포 앱 0개에 맞춰 0이라(page #455 ·
  #    trip-mate-api 철거) 무인자 호출로는 트립을 볼 수 없다. 수치를 박아야 "바닥값이 실제로
  #    작동한다"는 계약이 앱 개수와 무관하게 증명된다.
  echo '[]' > "$FR/infra/cloudflare/apps.json"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci --floor registry=1
  [ "$status" -eq 1 ]
  out="$output"
  run grep -q "scan-floor" <<<"$out"
  [ "$status" -eq 0 ]
  # 바닥값 **수치**는 소비자가 소유한다 — 빈 registry가 정당한 픽스처는 낮춰 부른다(래칫 아님).
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci --floor registry=0
  [ "$status" -eq 0 ]
}

@test "a non-numeric --floor registry value is a usage error, never a silently disabled floor" {
  # NaN 비교는 항상 false다 — 오타 하나로 바닥값이 조용히 사라지는 자리(이 캠페인이 지우는 바로 그 병).
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci --floor registry=abc
  [ "$status" -eq 2 ]
}

@test "an empty or blank --floor registry value is a usage error too (Number('') is 0, not NaN)" {
  # ⚠️ `Number("")===0`·`Number(" ")===0`이라 isFinite 검사만으로는 **빈 값이 유효한 0으로 통과**해
  # 바닥값이 조용히 꺼진다. 위 @test가 불가능하다고 선언한 상태가 실제로 가능했다(적대 검토 실측).
  echo '[]' > "$FR/infra/cloudflare/apps.json"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci --floor "registry="
  [ "$status" -eq 2 ]
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci --floor "registry= "
  [ "$status" -eq 2 ]
  # 값 없이 마지막 인자로 두면 undefined — 같은 경로로 막혀야 한다
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci --floor
  [ "$status" -eq 2 ]
}

@test "unreferenced-conn is informational and never blocks --ci" {
  # ghost(orphan-dns, 차단 유형)를 제거해 --ci 판정을 unreferenced-conn만으로 격리
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$FR/infra/cloudflare/apps.json"
  cat > "$FR/platform/data-conn/prod/kustomization.yaml" <<'KEOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-lonely-conn.sealed.yaml
KEOF
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "unreferenced-conn" and .subject == "db-lonely-conn")'
}

@test "audit reports a conn whose source resource is gone (orphan-conn via the layout kernel)" {
  # 소스(Database CR / 인스턴스 디렉토리)가 사라진 conn 등록 — 지금까지 어떤 유형도 못 보던
  # 관측(설계 게이트 r1 D2가 요구한 역방향의 감사 소비). shared는 CR이 실재하므로 대조군.
  cat > "$FR/platform/data-conn/prod/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-shared-conn.sealed.yaml
  - db-waif-conn.sealed.yaml
  - db-waif-ro-conn.sealed.yaml
  - cache-stray-conn.sealed.yaml
YAML
  touch "$FR/platform/data-conn/prod/db-waif-conn.sealed.yaml"
  touch "$FR/platform/data-conn/prod/db-waif-ro-conn.sealed.yaml"
  touch "$FR/platform/data-conn/prod/cache-stray-conn.sealed.yaml"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "orphan-conn" and .subject == "db-waif-conn")'
  # ro-conn도 검사된다 — purge 삼중이 conn→ro-conn 순 제거라 중단이 남기는 것이 정확히 ro-conn(리뷰 지적).
  echo "$output" | jq -e '.findings | any(.type == "orphan-conn" and .subject == "db-waif-ro-conn")'
  echo "$output" | jq -e '.findings | any(.type == "orphan-conn" and .subject == "cache-stray-conn")'
  # 음성 대조는 같은 성공 출력의 카운트=0으로 — 별도 파이프의 rc 기반(-ne 0)은 bun이 죽어도 통과한다.
  [ "$(echo "$output" | jq '[.findings[] | select(.type == "orphan-conn" and .subject == "db-shared-conn")] | length')" = "0" ]
}

@test "audit reports a conn sealed file on disk that kustomization never registered (unwired-conn, reverse direction)" {
  # 위 orphan-conn은 정방향(kustomization → 소스)만 본다. 이 레인은 역방향 — 디스크에 conn
  # 봉인본이 있는데 kustomization resources 자체에 등록이 안 된 경우(멱등 등록 실패/손 편집으로
  # 줄 누락) — 정방향 열거로는 원리적으로 못 보는 붕괴다(감사 5라운드 set-kustomization-8).
  # setup()이 이미 db-shared-conn.sealed.yaml·db-lonely-conn.sealed.yaml 둘 다 touch해 뒀다(:33,35) —
  # kustomization에는 shared만 등록해 lonely를 등록 누락 상태로 만든다.
  cat > "$FR/platform/data-conn/prod/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-shared-conn.sealed.yaml
YAML
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "unwired-conn" and .subject == "db-lonely-conn.sealed.yaml")'
  # 음성 대조 — 등록된 shared는 unwired로 뜨지 않는다.
  [ "$(echo "$output" | jq '[.findings[] | select(.type == "unwired-conn" and .subject == "db-shared-conn.sealed.yaml")] | length')" = "0" ]
}

@test "audit surfaces malformed conn entries instead of silently dropping them (observation preserved)" {
  # 커널 분류가 null인 conn 형상 엔트리를 조용히 건너뛰면 손으로 쓴 불량 엔트리가 감사에서
  # 사라진다(티켓 06 리뷰 이월 — 관측 축소 금지). 별도 유형으로 표면화한다.
  cat > "$FR/platform/data-conn/prod/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-BAD-conn.sealed.yaml
YAML
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "malformed-conn" and .subject == "db-BAD-conn.sealed.yaml")'
}

@test "the retired --min-registry vocabulary is a usage error (kernel-followups 05)" {
  # 인자 거부는 레지스트리 읽기보다 앞이다 — setup 픽스처(FR) 그대로 쓴다.
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci --min-registry 1
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

# ── 스캔 신호 규약(티켓 14) ────────────────────────────────────────────────────────
# 이 도구는 stdout이 기계 판독 JSON이라 `SCAN:` 마커를 낼 수 없다 — 같은 정보를 페이로드
# `scan: {라벨: 건수}`에 싣는다(형제 tools/dns-drift-check.ts의 관용구, 단 그 파일의 **합계**
# 결함은 복제하지 않는다). 아래 증인들이 그 두 축(도메인별 관측 · 근거 있는 바닥값)을 진다.

# 일곱 도메인 접미사 — 아래 @test들이 공유하는 로스터. 비면 루프가 0회 도는 것이 곧 vacuous이므로
# 각 @test가 반복 횟수를 세어 7과 대조한다(열거 붕괴 → vacuous green의 자기 적용).
AUDIT_DOMAINS="registry apps caches ledger roles conns tombstones"

# 페이로드의 한 도메인 건수를 읽는다. $1=repo-root · $2=도메인 접미사 · 나머지=그대로 전달.
scan_count_of() {
  local root="$1" dom="$2"
  shift 2
  bun "$ROOT/tools/audit-orphans.ts" --repo-root "$root" "$@" | jq -r ".scan[\"audit-orphans:$dom\"]"
}

# 일곱 도메인이 모두 비지 않은 픽스처로 올린다(양성 대조 — 붕괴 관측의 기준선).
seed_all_domains() {
  mkdir -p "$FR/platform/cache/prod/sessions"
  cat > "$FR/platform/data-conn/prod/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - db-shared-conn.sealed.yaml
YAML
  # state=purged — incomplete-purge를 만들지 않으면서 tombstone 도메인만 채운다.
  printf '{"db:gone":{"state":"purged"}}\n' > "$FR/platform/data-conn/prod/.tombstones.json"
}

@test "all seven enumerations are non-empty in the seeded fixture (positive control for the collapse witness)" {
  seed_all_domains
  out="$(bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR")"
  # 도메인 수 자체를 먼저 고정한다 — 라벨이 빠지면 아래 루프가 조용히 짧아진다.
  echo "$out" | jq -e '.scan | length == 7'
  seen=0
  for dom in $AUDIT_DOMAINS; do
    n="$(echo "$out" | jq -r ".scan[\"audit-orphans:$dom\"]")"
    [ "$n" -ge 1 ]
    seen=$((seen + 1))
  done
  [ "$seen" -eq 7 ]
}

@test "each of the seven enumerations collapses to zero visibly in the payload (per-domain, never a sum)" {
  # 형제 dns-drift-check는 `scanned: a.length + b.length` 합계라 작은 레인의 붕괴를 큰 레인이 덮는다.
  # 여기서는 한 레인을 무너뜨려도 **그 레인만** 0이 되고 다른 레인은 그대로 보여야 한다.
  seed_all_domains
  # 원장·role은 바닥값이 1이라 붕괴시키면 종료코드가 1이 된다(그 축은 아래 두 @test가 진다).
  # 이 @test의 질문은 "붕괴가 페이로드에 보이는가"이므로 두 바닥값만 명시 해제한다.
  LOW="--floor ledger=0 --floor roles=0"
  collapsed=0
  rm -f "$FR/platform/data-conn/prod/.tombstones.json"
  [ "$(scan_count_of "$FR" tombstones $LOW)" = "0" ]
  [ "$(scan_count_of "$FR" conns $LOW)" -ge 1 ]      # 공붕괴 아님 — 다른 레인은 그대로
  collapsed=$((collapsed + 1))
  rm -f "$FR/platform/data-conn/prod/kustomization.yaml"
  [ "$(scan_count_of "$FR" conns $LOW)" = "0" ]
  [ "$(scan_count_of "$FR" caches $LOW)" -ge 1 ]
  collapsed=$((collapsed + 1))
  rm -rf "$FR/platform/cache/prod/sessions"
  [ "$(scan_count_of "$FR" caches $LOW)" = "0" ]
  [ "$(scan_count_of "$FR" roles $LOW)" -ge 1 ]
  collapsed=$((collapsed + 1))
  rm -f "$FR/platform/cnpg/prod/cluster.yaml"
  [ "$(scan_count_of "$FR" roles $LOW)" = "0" ]
  [ "$(scan_count_of "$FR" ledger $LOW)" -ge 1 ]
  collapsed=$((collapsed + 1))
  printf '<!-- ledger:meta -->\n' > "$FR/docs/memory-ledger.md"
  [ "$(scan_count_of "$FR" ledger $LOW)" = "0" ]
  [ "$(scan_count_of "$FR" registry $LOW)" -ge 1 ]
  collapsed=$((collapsed + 1))
  echo '[]' > "$FR/infra/cloudflare/apps.json"
  [ "$(scan_count_of "$FR" registry $LOW)" = "0" ]
  [ "$(scan_count_of "$FR" apps $LOW)" -ge 1 ]
  collapsed=$((collapsed + 1))
  rm -rf "$FR/apps/orders"
  [ "$(scan_count_of "$FR" apps $LOW)" = "0" ]
  collapsed=$((collapsed + 1))
  [ "$collapsed" -eq 7 ]   # 일곱 도메인을 모두 밟았다(루프가 짧아지면 여기서 red)
}

@test "the ledger-row floor is red at zero rows, and the explicit override lets a fixture through" {
  # 실 트리 docs/memory-ledger.md는 CI가 강제하는 예산 SSOT라 구조적으로 항상 ≥1행이다 —
  # 0행은 "검사할 게 없다"가 아니라 파일 부재/행 마커 포맷 드리프트이고, 그 상태에서
  # stale-ledger-row 검사가 통째로 vacuous해진다.
  printf '<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->\n' > "$FR/docs/memory-ledger.md"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "audit-orphans:ledger"
  echo "$output" | grep -q "열거 붕괴"
  # 바닥값 **수치**는 소비자가 소유한다 — 정당하게 빈 픽스처는 명시로 내린다(래칫 아님).
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --floor ledger=0
  [ "$status" -eq 0 ]
}

@test "the managed-role floor is red when cluster.yaml is gone (dangling-role would be vacuous)" {
  # cluster.yaml managed.roles에는 superuser 시드(ukkiee)가 구조적으로 상주해 실 트리는 항상 ≥1이다.
  # 0 = 파일 부재/키 경로(spec.managed.roles) 변경 → dangling-role 검사가 0건 검사 후 초록이 된다.
  rm -f "$FR/platform/cnpg/prod/cluster.yaml"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "audit-orphans:roles"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --floor roles=0
  [ "$status" -eq 0 ]
}

@test "simultaneous collapses are collected and reported together, not one per run" {
  # 첫 도메인에서 죽으면 나머지 여섯의 상태를 한 번에 못 본다(guardMain ②와 같은 규율).
  rm -f "$FR/platform/cnpg/prod/cluster.yaml"
  printf '<!-- ledger:meta -->\n' > "$FR/docs/memory-ledger.md"
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "열거 붕괴 2건"
  echo "$output" | grep -q "audit-orphans:roles"
  echo "$output" | grep -q "audit-orphans:ledger"
}

@test "every one of the seven domains is a declared --floor key, and a typo is a usage error" {
  # assertFloorKeys는 오타 키를 **조용히 꺼진 바닥값**이 아니라 사용법 오류(2)로 접는다.
  # 일곱 개가 전부 로스터에 있는지는 하나씩 실제로 넘겨서 확인한다(선언 목록 대조가 아니라 실행).
  seed_all_domains
  accepted=0
  for dom in $AUDIT_DOMAINS; do
    run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --floor "$dom=0"
    [ "$status" -eq 0 ]
    accepted=$((accepted + 1))
  done
  [ "$accepted" -eq 7 ]
  run bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --floor connz=0
  [ "$status" -eq 2 ]
}

@test "stdout stays machine-readable JSON in all three exit modes (the emission contract)" {
  # 방출 규약: 마커를 어느 모드에서도 내지 않는다. 마커 한 줄이 audit.yaml:52의 tee→jq와
  # 이 스위트의 jq 단언을 통째로 깬다. jq가 stdout **전체**를 파싱하는 것이 그 증인이다.
  seed_all_domains
  modes=0
  for mode in default ci strict; do
    case "$mode" in
      default) out="$(bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" || true)" ;;
      ci) out="$(bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --ci || true)" ;;
      strict) out="$(bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" --strict || true)" ;;
    esac
    printf '%s\n' "$out" | jq -e '.scan | length == 7'
    modes=$((modes + 1))
  done
  [ "$modes" -eq 3 ]
}

@test "the audit.yaml consumption (tee then jq .count/.alerting) survives the scan payload" {
  seed_all_domains
  bun "$ROOT/tools/audit-orphans.ts" --repo-root "$FR" | tee "$TMP/audit.json" > /dev/null
  count="$(jq -r .count "$TMP/audit.json")"
  alerting="$(jq -r .alerting "$TMP/audit.json")"
  [ "$count" -ge 1 ]        # 픽스처엔 orphan-dns(ghost)가 있다 — null/빈 값이면 여기서 red
  [ "$alerting" -ge 1 ]
  jq -e '.scan["audit-orphans:registry"] == 2' "$TMP/audit.json"
}
