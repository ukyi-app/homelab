# 워크플로 디스패치 직관성 개선 — 구현 플랜

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** `dispatch-mutation` 멀티플렉서를 액션별 전용 워크플로로 분해하고, audit을 스케줄 reconciler로 옮기고, teardown/activate를 owner-local로 빼고, run-name·README 인덱스로 "무엇을 수동 실행하고 무엇을 쓰는지"를 직관적으로 만든다.

**Architecture:** 변이 4종(create-app/update-secrets/create-database/create-cache)은 각각 `workflow_dispatch` 전용 워크플로(thin wrapper: validate→기존 `_*.yaml` reusable→인라인 실패 notify)로 노출되고 전역 `homelab-mutation` 직렬화 그룹에 합류한다. audit은 dns-drift 패턴의 스케줄 reconciler가 된다. teardown은 안전 envelope를 보존하는 `scripts/teardown.sh`+`make` 타겟으로, activate-app은 런북으로 owner-local화한다. 변이 로직(`_create-*.yaml`·`tools/*.mjs`)·외부 계약(`reusable-app-build.yaml`)·`validate-mutation.mjs`는 불변.

**Tech Stack:** GitHub Actions(reusable workflow·`concurrency.queue`·`run-name`), Node 22 tools, bats(`scripts/run-bats.sh` 수집), shellcheck, Makefile.

**설계 SSOT:** `docs/plans/2026-06-18-workflow-dispatch-discoverability-design.md`. 적대적 리뷰 반영: 설계 A.5(F1 권한·F2 teardown래퍼), 플랜 패스1(C-F1 teardown 전용브랜치·C-F2 audit outcome·C-F3 merge-base 체크), 패스2(C-F4 게이트테스트 마이그레이션·C-F5 repo-wide 잔존참조).

---

## 작업 전 필독 (함정 — AGENTS.md 검증됨)

- **bats `@test` 이름은 영어** — 디렉토리 실행 시 한글 이름 인코딩 깨짐(침묵 스킵).
- **bash 3.2(macOS) `[[ ]]` 중간 단언 침묵 통과** — 단언은 `[ ]` 단순명령 또는 `run` + `[ "$status" -eq N ]`. `declare -A` 금지.
- **`queue: max` ↔ `cancel-in-progress: true` 병용 불가** — 검증 에러로 전체 불능. 변이 디스패처는 `cancel-in-progress: false` 고정.
- **비신뢰 입력은 env 경유** — `run:`에 `${{ github.event.inputs.* }}` 인라인 보간 금지(`with:` 구조 전달·`env:` 할당·run-name은 허용).
- **reusable workflow 권한은 caller 잡이 상한** — elevate 불가(A.5 F1).
- **telegram 콜사이트 테스트는 EXACT match yq로 with-keys/link/한국어-title 검증** — 디스패처 notify는 `./.github/actions/telegram-notify`를 **직접**(인라인) 써서 검증 대상이 되게 한다(composite로 감싸면 검증 누락). title에 한글 필수.
- **full `run-bats.sh`/`make ci`는 Task 10에서만** — Task 2~9는 토폴로지 전환 중이라 cross-cutting 게이트(telegram-callsites·setup-node-pnpm)가 일시 red. 중간 검증은 **타겟 bats**만. 피처 브랜치 중간 커밋 red는 허용(PR 게이트=최종 green).
- 하네스 셸=zsh, node는 mise 경유, 워크트리는 이미 생성됨. 테스트 경로는 `git rev-parse --show-toplevel` 기준.

---

## Task 1: 변이 디스패처 구조·notify 가드 테스트 (fail-first)

`test_dispatcher.bats`(dispatch-mutation 전용)의 단언을 **4 디스패처 전체**로 일반화한 가드를 먼저 작성한다. 디스패처가 아직 없어 실패한다.

**Files:**
- Create: `tools/tests/test_mutation-dispatch.bats`

**Step 1: 실패 테스트 작성**

```bash
#!/usr/bin/env bats
# 변이 디스패처(create-app/update-secrets/create-database/create-cache) 구조·notify 불변식.
# test_dispatcher.bats(dispatch-mutation 전용, Task 4에서 삭제)의 단언을 4 디스패처로 일반화.
# (@test 이름 영어, 단언은 run+[ ] — bash 3.2 [[ ]] 침묵통과 함정 회피)

setup() {
  ROOT="$(git rev-parse --show-toplevel)"; WF="$ROOT/.github/workflows"
  DISPATCHERS="create-app update-secrets create-database create-cache"
}

@test "every dispatcher serializes via homelab-mutation group with queue max" {
  for d in $DISPATCHERS; do
    f="$WF/$d.yaml"; [ -f "$f" ]
    grep -q "group: homelab-mutation" "$f"
    grep -q "queue: max" "$f"
    grep -q "cancel-in-progress: false" "$f"
  done
}

@test "no workflow combines queue:max with cancel-in-progress:true" {
  for f in "$WF"/*.yaml; do
    if grep -q "queue: max" "$f"; then
      run grep -q "cancel-in-progress: true" "$f"; [ "$status" -ne 0 ]
    fi
  done
}

@test "create-app dispatcher grants packages:read on the reusable call job" {
  grep -q "packages: read" "$WF/create-app.yaml"
}

@test "each dispatcher validates with fixed action then routes to its reusable" {
  for d in $DISPATCHERS; do
    f="$WF/$d.yaml"
    grep -q "validate-mutation.mjs --action $d" "$f"
    grep -q "needs: validate" "$f"
    grep -q "uses: ./.github/workflows/_$d.yaml" "$f"
  done
}

@test "each dispatcher triggers only on workflow_dispatch (homelab-initiated boundary)" {
  for d in $DISPATCHERS; do
    run grep -E "repository_dispatch|pull_request:|push:|schedule:" "$WF/$d.yaml"
    [ "$status" -ne 0 ]
  done
}

@test "each dispatcher references inputs only via env or with: (no run inline interpolation)" {
  for d in $DISPATCHERS; do
    bad=$(grep -n 'github.event.inputs' "$WF/$d.yaml" \
      | grep -vE '^[0-9]+:[[:space:]]*(#|[A-Z_]+:|(app_repo|sha|spec):)' || true)
    [ -z "$bad" ]
  done
}

@test "each dispatcher declares only its contract inputs" {
  grep -q "app_repo:" "$WF/create-app.yaml";    grep -q "sha:" "$WF/create-app.yaml"
  grep -q "app_repo:" "$WF/update-secrets.yaml"; grep -q "sha:" "$WF/update-secrets.yaml"
  grep -q "spec:" "$WF/create-database.yaml"
  grep -q "spec:" "$WF/create-cache.yaml"
}

@test "each dispatcher notify fires on cancelled as well as failure" {
  for d in $DISPATCHERS; do
    run grep -nE "if:\s*failure\(\)\s*\|\|\s*cancelled\(\)" "$WF/$d.yaml"
    [ "$status" -eq 0 ]
  done
}

@test "each dispatcher notify normalizes status from needs (not its own job.status)" {
  for d in $DISPATCHERS; do
    f="$WF/$d.yaml"
    run grep -nE 'toJSON\(needs\)' "$f"; [ "$status" -eq 0 ]
    run grep -nE 'status:[[:space:]]*\$\{\{[[:space:]]*steps\.norm\.outputs\.status' "$f"; [ "$status" -eq 0 ]
    run grep -nE 'status:[[:space:]]*\$\{\{[[:space:]]*job\.status[[:space:]]*\}\}' "$f"; [ "$status" -ne 0 ]
  done
}
```

> 잔존-참조 가드는 여기 두지 않는다(F6) — `_audit`/`_teardown`/`dispatch-mutation`은 Task 4~6에서 단계적으로 삭제되고 `bump.yaml` 주석은 Task 8에서 정리되므로, "참조 0"은 그 *후*에만 참이다. 영구 가드는 Task 9(삭제 후)에, 최종 1회 검증은 Task 10 repo-wide `git grep`에 둔다.

**Step 2: 실패 확인**

Run: `cd "$(git rev-parse --show-toplevel)" && bats tools/tests/test_mutation-dispatch.bats`
Expected: FAIL (디스패처 부재 + dispatch-mutation/_audit/_teardown 존재).

**Step 3: 커밋**

```bash
git add tools/tests/test_mutation-dispatch.bats
git commit -m "test: 변이 디스패처 구조·notify 불변식 가드 (fail-first)"
```

---

## Task 2: create-app 변이 디스패처 (전체 예시)

가장 복잡(`packages: read` 필요 — A.5 F1). notify는 **인라인**(기존 콜사이트 테스트가 검증하도록).

**Files:** Create `.github/workflows/create-app.yaml`

```yaml
# create-app 변이 디스패처 — 신규 앱 온보딩(외부 레포 config를 SHA 고정 read → 매니페스트 PR, active:false).
# 트리거 경계(런북 app-platform): 앱 레포는 homelab-write 자격 0 — owner가 여기서 workflow_dispatch로 실행.
# 변이 로직은 _create-app.yaml(reusable)에 있다 — 이 파일은 trigger+validate+notify 셸.
name: "변이: create-app"
run-name: "변이: create-app — ${{ inputs.app_repo }}@${{ inputs.sha }}"
on:
  workflow_dispatch:
    inputs:
      app_repo:
        description: "ukyi-app/<app> — 온보딩할 앱 레포"
        required: true
      sha:
        description: "앱 레포 커밋 SHA (config를 이 SHA로 고정 read)"
        required: true

# 전역 직렬화: 모든 homelab-mutation 워크플로(변이 디스패처/bump-poll/iac/tf-reconcile)가 같은 그룹.
# queue: max — pending FIFO 큐잉. cancel-in-progress와 병용 불가(AGENTS.md 함정) — 절대 true 금지.
concurrency:
  group: homelab-mutation
  cancel-in-progress: false
  queue: max

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v4
        with: { ref: main }
      - uses: actions/setup-node@v4
        with: { node-version: "22" }
      - env:
          PAYLOAD: ${{ toJSON(github.event.inputs) }} # owner 입력도 비신뢰 — env 경유, 인라인 보간 금지
        run: |
          printf '%s' "$PAYLOAD" > /tmp/payload.json
          node tools/validate-mutation.mjs --action create-app --payload-file /tmp/payload.json

  create-app:
    needs: validate
    uses: ./.github/workflows/_create-app.yaml
    with:
      app_repo: ${{ github.event.inputs.app_repo }}
      sha: ${{ github.event.inputs.sha }}
    secrets: inherit
    permissions:
      contents: read
      packages: read # _create-app.yaml의 GHCR digest 해석에 필수 — reusable 권한은 caller가 상한 (A.5 F1)

  notify:
    needs: [validate, create-app]
    if: failure() || cancelled()
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v4
      - id: norm
        env:
          RESULTS: ${{ toJSON(needs) }}
        run: |
          # notify 잡의 job.status는 자기 자신(success)이라 거짓 — 상류 needs로 정규화(취소>실패)
          if printf '%s' "$RESULTS" | grep -q '"result": *"cancelled"'; then
            echo "status=cancelled" >> "$GITHUB_OUTPUT"
          else
            echo "status=failure" >> "$GITHUB_OUTPUT"
          fi
      - uses: ./.github/actions/telegram-notify
        with:
          status: ${{ steps.norm.outputs.status }}
          source: 변이
          title: create-app 실행
          link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
```

**Step 2: 부분 통과 확인** — Run `bats tools/tests/test_mutation-dispatch.bats -f "create-app"` → create-app 단언 PASS.

**Step 3: 커밋** — `git add .github/workflows/create-app.yaml && git commit -m "feat: create-app 변이 디스패처 (packages:read 보존)"`

---

## Task 3: 나머지 변이 디스패처 3종

create-app.yaml 본뜨되 **델타만**. 모두 route 잡 `permissions: contents: read`(packages 불필요). notify 잡은 동일 구조(`needs: [validate, <route-job>]`, title 한국어 `<action> 실행`).

**Files:** Create `update-secrets.yaml` · `create-database.yaml` · `create-cache.yaml`

**델타 (create-app.yaml 대비):**
- `name`/`run-name`/notify `title`의 `create-app` → 해당 액션.
- `validate` 스텝 `--action <액션>`.
- route 잡 이름 = 액션, `uses: ./.github/workflows/_<액션>.yaml`, route `permissions: contents: read`(packages 제거).
- notify `needs: [validate, <액션>]`.

**update-secrets.yaml** — 입력 `app_repo`+`sha`, `run-name: "변이: update-secrets — ${{ inputs.app_repo }}@${{ inputs.sha }}"`, route `with: {app_repo, sha}`, notify title `update-secrets 실행`.

**create-database.yaml** — 입력 `spec`만:
```yaml
on:
  workflow_dispatch:
    inputs:
      spec:
        description: '{"name":"<db>","extensions":["..."]} — owner는 받지 않음(name 고정)'
        required: true
run-name: "변이: create-database — ${{ inputs.spec }}"
```
route `with: { spec: ${{ github.event.inputs.spec }} }` → `_create-database.yaml`, notify title `create-database 실행`.

**create-cache.yaml** — `create-database.yaml`와 동일 구조, `_create-cache.yaml`, `run-name: "변이: create-cache — ${{ inputs.spec }}"`, title `create-cache 실행`.

**Step 1~3:** 세 파일 작성.
**Step 4: 디스패처 단언 통과** — Run `bats tools/tests/test_mutation-dispatch.bats`. Expected: `removed ... references` 외 전부 PASS(삭제 전이라 그 단언만 FAIL — 정상).
**Step 5: 커밋** — `git commit -m "feat: update-secrets·create-database·create-cache 변이 디스패처"`

---

## Task 4: dispatch-mutation 제거 + 전용 테스트 삭제

**Files:** Delete `.github/workflows/dispatch-mutation.yaml` · `tests/gates/test_dispatcher.bats`

`test_dispatcher.bats`의 단언은 이미 Task 1(디스패처 구조·notify)로 일반화 이관됨. `_audit.yaml` 단언 2개는 Task 5의 `test_audit-workflow.bats`로 이관(아래).

```bash
git rm .github/workflows/dispatch-mutation.yaml tests/gates/test_dispatcher.bats
test -f .github/workflows/dispatch-mutation.yaml && echo "삭제 실패" || echo "dispatch-mutation 파일 제거됨"
# 디스패처 구조 단언 전부 PASS. 잔존-참조(bump.yaml 주석 등)는 Task 8 정리 후 Task 9/10에서 검증.
bats tools/tests/test_mutation-dispatch.bats
git add -A && git commit -m "refactor: dispatch-mutation 멀티플렉서 + 전용 테스트 제거"
```
Expected: dispatch-mutation 파일 제거됨, test_mutation-dispatch 전부 PASS.

---

## Task 5: audit → 스케줄 reconciler (C-F2 outcome 처리 포함)

**Files:** Delete `_audit.yaml` · Create `audit.yaml` · Create `tools/tests/test_audit-workflow.bats`

**Step 1: 실패 테스트** (C-F2 + test_dispatcher에서 이관한 _audit 단언 2개)

```bash
#!/usr/bin/env bats
setup() { ROOT="$(git rev-parse --show-toplevel)"; F="$ROOT/.github/workflows/audit.yaml"; }

@test "audit is a scheduled reconciler with manual dispatch" {
  [ -f "$F" ]; grep -q "schedule:" "$F"; grep -q "workflow_dispatch:" "$F"
}
@test "audit notifies only on drift or failure (no zero-count spam)" {
  grep -q "count != '0'" "$F"
}
@test "audit status is outcome-driven (failure not mislabeled as drift)" {
  grep -q "steps.audit.outcome == 'failure'" "$F"
}
@test "audit is read-only and not in the mutation serialization group" {
  run grep -q "group: homelab-mutation" "$F"; [ "$status" -ne 0 ]
}
@test "audit summary does not cap findings at 20" {
  run grep -c '\.findings\[:20\]' "$F"; [ "$output" = "0" ]
}
@test "audit summary does not swallow jq errors" {
  run grep -cE '2>/dev/null \|\| true' "$F"; [ "$output" = "0" ]
}
```

Run: `bats tools/tests/test_audit-workflow.bats` → FAIL.

**Step 2: `_audit.yaml` 삭제 + `audit.yaml` 작성**

```bash
git rm .github/workflows/_audit.yaml
```

```yaml
# audit reconciler — 레포 정적 드리프트 워치독(registry↔매니페스트↔바인딩↔원장, 읽기 전용).
# 차단성(orphan-dns·dangling-binding)은 ci.yaml의 audit-orphans --ci가 PR 게이트로 잡는다.
# 이 워크플로는 정보성 드리프트(incomplete-purge·unreferenced-resource 등)를 주기적으로 잡아 알린다.
name: "🔁 audit — 드리프트 감사"
run-name: "🔁 audit — ${{ github.event_name == 'schedule' && '스케줄' || format('수동({0})', github.actor) }}"
on:
  schedule:
    - cron: "17 18 * * *"   # 매일 1회(UTC 18:17 = KST 03:17). 정적 드리프트라 저빈도. GHA cron=UTC.
  workflow_dispatch: {}
permissions:
  contents: read
concurrency:
  group: audit
  cancel-in-progress: false
jobs:
  audit:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v4
        with: { ref: main }
      - uses: ./.github/actions/setup-node-pnpm
      - id: audit
        run: |
          node tools/audit-orphans.mjs --repo-root . | tee /tmp/audit.json
          echo "count=$(jq -r .count /tmp/audit.json)" >> "$GITHUB_OUTPUT"
      - name: build audit summary
        id: report
        if: always() && (steps.audit.outcome == 'failure' || steps.audit.outputs.count != '0')
        env:
          OUTCOME: ${{ steps.audit.outcome }}
          COUNT: ${{ steps.audit.outputs.count }}
        run: |
          # 실패 시 audit.json이 없거나 깨졌을 수 있다 → 폴백 body (drift 오표기·빈 body 방지 — C-F2/obs-6)
          if [ "$OUTCOME" = "failure" ]; then
            body="감사 실행 실패 — 런 로그 확인 필요"
          else
            summary="$(jq -r '.findings[] | "- \(.type): \(.subject)"' /tmp/audit.json)"
            body="드리프트 건수: ${COUNT}"$'\n'"${summary}"
          fi
          { echo "body<<EOF"; printf '%s\n' "$body"; echo "EOF"; } >> "$GITHUB_OUTPUT"
      - name: telegram report (드리프트/실패 시에만)
        if: always() && (steps.audit.outcome == 'failure' || steps.audit.outputs.count != '0')
        uses: ./.github/actions/telegram-notify
        with:
          # status는 outcome 우선 — 실패를 drift로 오표기하지 않는다(C-F2)
          status: ${{ steps.audit.outcome == 'failure' && 'failure' || (steps.audit.outputs.count != '0' && 'drift' || 'success') }}
          source: 감사
          title: 드리프트 감사
          ident: ${{ steps.audit.outcome == 'failure' && '실행 실패' || format('{0}건', steps.audit.outputs.count) }}
          body: ${{ steps.report.outputs.body }}
          link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
      - name: drift 0건 — skip 알림
        if: success() && steps.audit.outputs.count == '0'
        run: echo "::notice::드리프트 0건 — 알림 skip"
```

**Step 3: 통과** — `bats tools/tests/test_audit-workflow.bats` → PASS.
**Step 4: 커밋** — `git add -A && git commit -m "refactor: audit을 스케줄 reconciler로 전환 (_audit reusable 제거, outcome 기반 알림)"`

---

## Task 6: owner-local teardown 래퍼 (C-F1) + activate-app 정리

`_teardown.yaml` envelope(fresh-main 전용 브랜치·allowlist staging·PR·notify)를 로컬 셸로 이식. **caller 현재 브랜치가 아닌 origin/main 기반 전용 브랜치**(C-F1).

**Files:** Create `scripts/teardown.sh` · Modify `Makefile` · Delete `_teardown.yaml` · Create `tools/tests/test_teardown-wrapper.bats` · Modify `tests/gates/test_apprepo-gitignore.bats`

**Step 1: 실패 테스트**

```bash
#!/usr/bin/env bats
setup() { ROOT="$(git rev-parse --show-toplevel)"; SH="$ROOT/scripts/teardown.sh"; }

@test "teardown wrapper refuses a dirty worktree" {
  run env TEARDOWN_DIRTY=1 DRY_RUN=1 bash "$SH" --app foo
  [ "$status" -ne 0 ]
}
@test "teardown wrapper dry-run creates a dedicated branch from origin/main" {
  run env TEARDOWN_DIRTY=0 TEARDOWN_TS=20260618 DRY_RUN=1 bash "$SH" --app foo
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "teardown/teardown-app-foo-20260618"
  echo "$output" | grep -q "origin/main"
}
@test "teardown wrapper dry-run prints the allowlist staging set" {
  run env TEARDOWN_DIRTY=0 DRY_RUN=1 bash "$SH" --app foo
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "apps/"
  echo "$output" | grep -q "infra/cloudflare/apps.json"
}
@test "teardown wrapper rejects unknown args" {
  run env DRY_RUN=1 bash "$SH" --bogus x
  [ "$status" -ne 0 ]
}

@test "teardown wrapper branches from freshly fetched FETCH_HEAD (F7)" {
  # 전체 base-SHA 검증은 mock remote 필요 — 단위 수준에선 FETCH_HEAD 분기를 단언(stale tracking ref 회피).
  grep -qE 'switch -c .* FETCH_HEAD' "$SH"
}
```

Run: `bats tools/tests/test_teardown-wrapper.bats` → FAIL.

**Step 2: `scripts/teardown.sh` 작성** (shellcheck 통과 필수)

```bash
#!/usr/bin/env bash
# owner-local teardown 래퍼 — _teardown.yaml의 안전 envelope를 로컬에 이식(A.5 F2, C-F1).
# clean-worktree 가드 → origin/main fetch → teardown/<target>-<ts> 전용 브랜치(fresh main 기반) 생성 →
# 툴(plan) → allowlist staging → PR(gh). App 토큰이 아니라 owner 본인 gh 자격(owner=admin).
# fresh main 기반 전용 브랜치라 stale main/무관 커밋이 teardown PR에 실리지 않는다(C-F1).
# purge(--delete-data)는 런북 절차로만. 사용: scripts/teardown.sh --app <name> | --resource <db|cache>:<name>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

DRY_RUN="${DRY_RUN:-0}"
ALLOWLIST="apps/ docs/memory-ledger.md infra/cloudflare/apps.json platform/"
BASE_REF="${TEARDOWN_BASE_REF:-origin/main}"
dirty="${TEARDOWN_DIRTY:-$([ -n "$(git status --porcelain)" ] && echo 1 || echo 0)}"
ts="${TEARDOWN_TS:-$(date +%Y%m%d%H%M%S)}"

mode=""; target=""
case "${1:-}" in
  --app)      mode="app"; target="${2:-}";;
  --resource) mode="resource"; target="${2:-}";;
  *) echo "사용: $0 --app <name> | --resource <db|cache>:<name>" >&2; exit 2;;
esac
[ -n "$target" ] || { echo "대상 누락" >&2; exit 2; }

# clean-worktree 가드 — 전용 브랜치로 전환하기 전 미커밋 작업 보호
[ "$dirty" = "0" ] || { echo "거부: 워킹트리 dirty — 정리/스태시 후 재실행" >&2; exit 1; }

# 입력 형식 검증(validate-mutation 계약 재사용) + 툴 명령·제목·slug 결정
if [ "$mode" = "app" ]; then
  printf '{"app":"%s"}' "$target" > /tmp/td-payload.json
  node tools/validate-mutation.mjs --action teardown-app --payload-file /tmp/td-payload.json
  plan_cmd=(node tools/teardown-app.mjs --app "$target" --repo-root .)
  slug="teardown-app-${target}"; title="chore: ${target} 앱 철거 (teardown-app)"
else
  printf '{"resource":"%s"}' "$target" > /tmp/td-payload.json
  node tools/validate-mutation.mjs --action teardown-resource --payload-file /tmp/td-payload.json
  kind="${target%%:*}"; name="${target#*:}"
  plan_cmd=(node tools/teardown-resource.mjs "--${kind}" "$name" --repo-root .)
  slug="teardown-resource-${kind}-${name}"; title="chore: ${target} retain tombstone (teardown-resource)"
fi
branch="teardown/${slug}-${ts}"

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] base: ${BASE_REF} (fresh fetch → FETCH_HEAD, F7)"
  echo "[dry-run] dedicated branch: ${branch}"
  echo "[dry-run] plan: ${plan_cmd[*]}"
  echo "[dry-run] staging allowlist: ${ALLOWLIST}"
  echo "[dry-run] PR title: ${title}"
  exit 0
fi

# fresh main 기반 전용 브랜치 — FETCH_HEAD로 분기(remote-tracking ref stale 엣지 회피, refspec/버전 무관 — C-F1·F7)
git fetch origin main
git switch -c "$branch" FETCH_HEAD
"${plan_cmd[@]}" | tee /tmp/td-plan.json
[ -n "$(git status --porcelain)" ] || { echo "변경 없음 — 멱등 no-op"; exit 0; }
echo "── 플랜(/tmp/td-plan.json) 검토 후 Enter로 PR 생성, Ctrl-C로 중단 ──"; read -r _
# shellcheck disable=SC2086  # ALLOWLIST는 의도적 단어 분할(없는 경로는 git이 무시)
git add $ALLOWLIST 2>/dev/null || true
git commit -m "$title"
git push -u origin "$branch"
gh pr create --base main --head "$branch" --title "$title" --body-file /tmp/td-plan.json
echo "PR 생성됨 — 머지=철거 승인."
```

**Step 3: `Makefile` 타겟 추가** (`## [teardown]` help 그룹)
```makefile
.PHONY: teardown-app teardown-resource
teardown-app: ## [teardown] APP= 앱 철거(owner-local — clean-worktree·fresh-main 전용브랜치·PR). 예: make teardown-app APP=foo
	@scripts/teardown.sh --app "$(APP)"
teardown-resource: ## [teardown] RESOURCE=<db|cache>:<name> 리소스 retain 철거(owner-local). 예: make teardown-resource RESOURCE=db:foo
	@scripts/teardown.sh --resource "$(RESOURCE)"
```

**Step 4: `test_apprepo-gitignore.bats` 재타겟** — `_teardown.yaml` 단언을 `scripts/teardown.sh`로:
```bash
# 기존 line ~16-20을 교체:
@test "teardown wrapper does not use git add -A (explicit allowlist only)" {
  run grep -E 'git add -A' scripts/teardown.sh
  [ "$status" -ne 0 ]
  run grep -E 'apps/' scripts/teardown.sh
  [ "$status" -eq 0 ]
}
```

**Step 5: `_teardown.yaml` 삭제 + 검증**
```bash
chmod +x scripts/teardown.sh
git rm .github/workflows/_teardown.yaml
bats tools/tests/test_teardown-wrapper.bats tests/gates/test_apprepo-gitignore.bats
shellcheck scripts/teardown.sh
grep -rn "_teardown.yaml" .github/workflows/ || echo "참조 없음"
```
Expected: bats PASS, shellcheck 0, 참조 0.

**Step 6: 커밋** — `git add -A && git commit -m "feat: owner-local teardown 래퍼(fresh-main 전용브랜치) + make 타겟, _teardown 워크플로 제거"`

> `activate-app`은 dispatch-mutation echo 스텁이라 Task 4에서 제거됨 — 절차는 Task 8 README/런북에.

---

## Task 7: run-name 전체 적용 (기존 수동 트리거 6종)

**Files (Modify, `name:` 다음에 `run-name:` 추가):**
- `build.yaml`: `run-name: "🔧 build — ${{ github.event_name == 'workflow_dispatch' && format('수동({0})', github.actor) || 'push' }}"`
- `bump-poll.yaml`·`tf-reconcile.yaml`·`pr-sweeper.yaml`·`dns-drift.yaml`·`renovate.yaml`(`<wf>` 치환):
  `run-name: "🔁 <wf> — ${{ github.event_name == 'schedule' && '스케줄' || format('수동({0})', github.actor) }}"`

**Step 1~2:** 6개 추가 + YAML 유효성 검증:
```bash
for f in build bump-poll tf-reconcile pr-sweeper dns-drift renovate create-app update-secrets create-database create-cache audit; do
  node -e "require('yaml').parse(require('fs').readFileSync('.github/workflows/$f.yaml','utf8'))" && echo "$f OK"
done
```
Expected: 전부 OK.

**Step 3: 커밋** — `git add .github/workflows/ && git commit -m "feat: 수동 실행 가능 워크플로에 run-name 추가 (트리거 출처 식별)"`

---

## Task 8: README 인덱스 + 문서/CLI/메모리 정합 (C-F5)

**Files:** Create `.github/workflows/README.md` · Modify `AGENTS.md` · `tools/create-app.mjs` · `tools/README.md` · `apps/README.md` · `bump.yaml`(주석)

**Step 1: `.github/workflows/README.md`** — 4그룹 표 + owner-local 절(컬럼: 워크플로 | 트리거 | 실행 주체 | 언제):
```markdown
# 워크플로 인덱스

**owner가 직접 누르는 건 🎛️ 변이뿐**(생성류). 파괴·로컬은 셸(아래 owner-local).

## 🎛️ 변이 — owner 수동 (workflow_dispatch)
| 워크플로 | 입력 | 언제 |
|---|---|---|
| 변이: create-app | app_repo·sha | 신규 앱 온보딩(매니페스트 PR, active:false) |
| 변이: update-secrets | app_repo·sha | 앱 SealedSecret 갱신 |
| 변이: create-database | spec | 앱용 CNPG DB 프로비전 |
| 변이: create-cache | spec | 앱용 redis 프로비전 |

전역 직렬화(`group: homelab-mutation`, `queue: max`)로 bump-poll/iac/tf-reconcile과 직렬 실행.

## 🔁 reconciler — 스케줄 + 수동 강제
| 워크플로 | 주기 | 역할 |
|---|---|---|
| 🔁 audit | 매일 | 정적 드리프트 감사(차단성은 ci gate가) |
| bump-poll | 10분 | GHCR 폴링 → 배포 bump |
| tf-reconcile | 30분 | terraform 드리프트 수렴 |
| pr-sweeper | 30분 | PR 브랜치 업데이트 |
| dns-drift | 6시간 | active&&public DNS resolve 체크 |
| renovate | 주1 | 의존성 갱신 PR |

## 🤖 자동 — 이벤트 트리거 (건들지 말 것)
| 워크플로 | 트리거 | 역할 |
|---|---|---|
| ci | PR·push | 권위 게이트(job `gate` = 유일 required) |
| verify | PR·push | 보조 점검 |
| iac | PR·push(cloudflare) | terraform apply |
| bump | build 완료·repo_dispatch | 이미지 write-back |
| onboard | repo_dispatch | 앱 온보딩 |

## 🧩 reusable — 직접 실행 불가 (Run 버튼 없음)
`_create-app`·`_update-secrets`·`_create-database`·`_create-cache` = 변이 디스패처가 `uses:`로 호출.
`reusable-app-build` = 외부 앱 레포가 `@main`으로 호출하는 cross-repo 계약.

## 💻 owner-local — Actions에 없음 (파괴/로컬, 의도적)
| 작업 | 명령 | 사유 |
|---|---|---|
| 앱 철거 | `make teardown-app APP=<x>` | 파괴 — 원클릭 금지. 래퍼가 clean-worktree·fresh-main 전용브랜치·PR 강제 |
| 리소스 철거(retain) | `make teardown-resource RESOURCE=<db\|cache>:<name>` | 위와 동일. purge(--delete-data)는 런북 절차로만 |
| 앱 활성화(DNS 노출) | `tools/activate-app.mjs`(런북 app-platform) | Healthy 게이트에 클러스터 접근 필요 |
```

**Step 2: 참조 갱신(C-F5) — discovery 스윕 우선(열거 누락 방지, F-class 근본)**

먼저 옛 식별자의 *모든* 추적 참조를 찾아 빠짐없이 갱신 대상에 넣는다(아래 열거는 알려진 집합일 뿐, **이 grep이 권위** — docs/traps.md 등 누락분 포함):
```bash
git grep -lE "dispatch-mutation|_audit\.yaml|_teardown\.yaml|test_dispatcher" \
  -- ':!docs/plans/*' ':!.github/workflows/reusable-app-build.yaml'
```
출력의 모든 파일을 신 구조로 갱신. 알려진 대상:
- `AGENTS.md`: 네이밍 컨벤션 절(`_*.yaml`="dispatch-mutation만 호출"→"per-action 변이 디스패처가 호출"; 공개 디스패처·owner-local·audit reconciler 분류 추가); 멀티레포 플로우 절("owner가 dispatch-mutation 실행 — create-app|…|audit"→"액션별 디스패처 실행; teardown/activate=owner-local(`make teardown-*`·런북); audit=스케줄 reconciler"); teardown 절 갱신.
- `tools/create-app.mjs`: dispatch-mutation을 안내하는 사용자 메시지 → 신 워크플로(예: "변이: create-app")/`make teardown-*`로.
- `tools/README.md`·`apps/README.md`: dispatch-mutation 언급 갱신.
- `bump.yaml`: 직렬화 주석의 "dispatch-mutation" → "변이 디스패처".
- **예외(미수정)**: `reusable-app-build.yaml`은 외부계약 byte-stable 가드(C-F3) 대상이라 주석 미변경 — 잔존 언급 수용(외부 caller는 파일명/입력만 의존).

**Step 3: 검증** — 신규 README 파싱 + AGENTS.md 표 깨짐 없음.
**Step 4: 커밋** — `git add -A && git commit -m "docs: 워크플로 README 인덱스 + AGENTS/CLI/문서 디스패처 구조 정합"`

---

## Task 9: cross-cutting 게이트 테스트 마이그레이션 (C-F4)

모든 워크플로 변경 완료 후, 신 토폴로지로 cross-cutting 게이트를 일괄 정합화한다. (이 시점 전까지 telegram-callsites·setup-node-pnpm은 일시 red — 의도됨.)

**Files (Modify):** `tests/gates/test_telegram-callsites.bats` · `tests/gates/test_setup-node-pnpm.bats` · `tests/gates/test_workflow-yaml.bats`

**Step 1: `test_telegram-callsites.bats` EXPECTED 맵** — 삭제분 제거 + 신규 추가(count grep은 substring이라 디스패처 `telegram-notify`/audit 모두 1씩; 합계는 self-deriving):
```
삭제: _teardown.yaml 1 · _audit.yaml 1 · dispatch-mutation.yaml 1
추가: create-app.yaml 1 · update-secrets.yaml 1 · create-database.yaml 1 · create-cache.yaml 1 · audit.yaml 1
```
(유지: `_create-app/_create-database/_create-cache/_update-secrets` 각 1, bump 2, bump-poll/onboard/iac 1, tf-reconcile 3, dns-drift/pr-sweeper/build 1.)

**Step 2: `test_setup-node-pnpm.bats`** — node 워크플로 리스트에서 `_teardown.yaml`·`_audit.yaml` 제거, `audit.yaml` 추가(9→8). `@test "all 9 ..."` → `"all 8 ..."`. corepack-제외 주석 "dispatch-mutation" → "변이 디스패처(validate 전용, pnpm 미사용)".

**Step 3: `test_workflow-yaml.bats`** — ① `.yml` stale-ref 리스트(line 32)에서 `_audit|_teardown|dispatch-mutation` 제거. ② **영구 stale-ref 가드 신설(F6 — 삭제·참조정리 후 도입이라 일관)**: 삭제된 워크플로가 추적 파일에 잔존하지 않음(`docs/plans/`·외부계약 `reusable-app-build.yaml` 제외):
```bash
@test "deleted dispatch workflows have no tracked references" {
  run bash -c "git -C \"$ROOT\" grep -lE 'dispatch-mutation|_audit\.yaml|_teardown\.yaml' -- ':!docs/plans/*' ':!.github/workflows/reusable-app-build.yaml' || true"
  [ -z "$output" ]
}
```
신규 `.yaml`는 "every workflow valid YAML" 단언으로 커버.

**Step 4: `docs/traps.md` 원장 마이그레이션 (F8)** — line 23~24 가드 경로 `tests/gates/test_dispatcher.bats` → `tools/tests/test_mutation-dispatch.bats`(client_payload·queue:max 단언을 이관받음). 트랩 문구의 `dispatch-mutation`/"dispatcher 직렬화" → split-dispatcher 모델. 이래야 `make verify-traps`(가드 파일 실재 확인, 게이트 `test_verify-traps.bats`로 수집)와 Task 10 잔존-ref grep이 통과.

**Step 5: 통과 확인**
```bash
cd "$(git rev-parse --show-toplevel)"
bats tests/gates/test_telegram-callsites.bats tests/gates/test_setup-node-pnpm.bats tests/gates/test_workflow-yaml.bats
make verify-traps   # docs/traps.md 가드 경로 실재(F8 — test_dispatcher 삭제 후 정합)
```
Expected: PASS(신 토폴로지 + 트랩 원장 정합).

**Step 6: 커밋** — `git add tests/gates/ docs/traps.md && git commit -m "test: cross-cutting 게이트 + traps 원장을 신 디스패처 토폴로지로 마이그레이션"`

---

## Task 10: 최종 회귀 게이트 (C-F3 merge-base · C-F5 repo-wide)

**Step 1: 전체 게이트 green**
```bash
cd "$(git rev-parse --show-toplevel)"
./scripts/run-bats.sh                       # 전체 bats 수집(신규 3 + 마이그레이션 반영) PASS
shellcheck $(git ls-files '*.sh')           # scripts/teardown.sh 포함
make verify                                 # skeleton·bats-accounting·app-deploy·ledger·sops
make chart-test                             # 공유 차트 무영향 확인
```
Expected: 전부 PASS. (`make ci`의 docker/age 스텝은 환경 가능 시; 부족하면 위 항목 + PR CI gate가 최종.)

**Step 2: 외부 계약·잔존 참조 최종 확인 (C-F3·C-F5)**
```bash
base=$(git merge-base origin/main HEAD)
# C-F3: 보호 경로 전체 브랜치 무변경
protected=$(git diff --name-only "$base"..HEAD -- \
  .github/workflows/reusable-app-build.yaml tools/validate-mutation.mjs \
  .github/workflows/_create-app.yaml .github/workflows/_create-database.yaml \
  .github/workflows/_create-cache.yaml .github/workflows/_update-secrets.yaml)
[ -z "$protected" ] && echo "보호 경로 무변경 ✅" || { echo "변경됨:"; echo "$protected"; exit 1; }
# C-F5: repo-wide 잔존 참조 0 (docs/plans 히스토리 + 외부계약 reusable-app-build 주석 제외)
stale=$(git grep -lE "dispatch-mutation|_audit\.yaml|_teardown\.yaml" -- \
  ':!docs/plans/*' ':!.github/workflows/reusable-app-build.yaml' || true)
[ -z "$stale" ] && echo "잔존 참조 0 ✅" || { echo "잔존:"; echo "$stale"; exit 1; }
```
Expected: 보호 경로 무변경, 잔존 참조 0.

**Step 3: 메모리 갱신**(별도) — `homelab-plan-progress.md`에 "dispatch-mutation → 액션별 디스패처 + audit 스케줄 + teardown owner-local" 반영, MEMORY.md 1줄.

---

## 완료 기준 (DoD)

- [ ] 변이 4 디스패처 + 직렬화·권한·라우팅·입력·notify(cancelled/normalize) 가드 PASS.
- [ ] create-app 호출 잡 `packages: read` 보존(A.5 F1).
- [ ] audit = 스케줄 reconciler, outcome 기반 status(C-F2), 0건 skip.
- [ ] teardown = `make teardown-*`(fresh-main FETCH_HEAD 전용브랜치·allowlist·PR — C-F1·F7) + shellcheck 통과, `_teardown.yaml` 제거.
- [ ] 기존 게이트 테스트·원장 마이그레이션(C-F4·F8): test_dispatcher 삭제·telegram-callsites·setup-node-pnpm·workflow-yaml·apprepo-gitignore·`docs/traps.md` 정합, `make verify-traps` 통과.
- [ ] run-name 수동 워크플로 전부.
- [ ] README + AGENTS + CLI/문서 참조 정합, repo-wide 잔존 참조 0(C-F5).
- [ ] 보호 경로(reusable-app-build·validate-mutation·_create-*) 전체 브랜치 무변경(C-F3).
- [ ] `run-bats.sh` + shellcheck + `make verify`/`chart-test` PASS.

---

## Adversarial review dispositions (감사 추적 — post-finalize)

설계 1패스(A.5) + 플랜 4패스. **전 발견 수용·반영, reject 0.**

| 출처 | 발견 | 심각도 | 판정 | 반영 |
|---|---|---|---|---|
| A.5 | F1 래퍼 `contents:read`가 create-app `packages:read` 박탈 | high | Accept | §4.2 액션별 권한(create-app=packages:read) |
| A.5 | F2 owner-local teardown이 PR/staging/notify 경계 상실 | high | Accept | first-class 래퍼(`scripts/teardown.sh`+make) |
| 플랜 P1 | C-F1 teardown이 stale/현재 브랜치 발행 | high | Accept | fresh-main 전용 브랜치 |
| 플랜 P1 | C-F2 audit 실패를 drift로 오표기 | med | Accept | outcome 기반 status + 폴백 body |
| 플랜 P1 | C-F3 계약 체크가 마지막 커밋만 | med | Accept | merge-base 전체 브랜치 비교 |
| 플랜 P2 | C-F4 삭제 후 게이트 테스트 미마이그레이션 | high | Accept | Task 9 cross-cutting 마이그레이션 |
| 플랜 P2 | C-F5 잔존-ref 체크 협소 | med | Accept | repo-wide grep + 사용자 참조 갱신 |
| 플랜 P3 | F6 stale-ref 가드가 너무 일찍 요구됨 | high | Accept | Task 1 제거, Task 9/10으로 이동 |
| 플랜 P4 | F7 래퍼가 fresh-main base 미보장 | high | Accept | FETCH_HEAD 분기 |
| 플랜 P4 | F8 test_dispatcher 삭제가 traps 원장 stale화 | med | Accept | Task 9 `docs/traps.md` 마이그레이션 |

**최종 상태(정직 기록):** 3패스 캡을 사용자 인가 확인 패스 1회 초과(총 4패스). 패스 4 verdict=`needs-attention`(F7·F8) — **clean `approve` 아님.** 사용자가 열린 항목을 보고 "수정 반영 후 확정" 선택. F7·F8 반영 + **discovery 스윕**(열거 누락 방지) 추가로, 반복되던 "마이그레이션 완전성" 발견 클래스를 *구조적으로* 차단(discovery 스윕 + Task 9 영구 가드 + Task 10 repo-wide 게이트). F7·F8 수정은 기계적이라 재리뷰 없이 수용(사용자 인가 잔여 리스크). 잔존 참조는 Task 10 게이트가 실행 단계에서 기계적으로 강제.

## Execution directives

- **Skill:** 이 플랜은 **별도 세션, 이 워크트리**에서 `executing-plans`로 구현한다.
- **연속 실행:** 배치 사이에 루틴 리뷰로 멈추지 않는다. 멈추는 건 진짜 블로커일 때만 — 의존성 누락, 반복 실패하는 검증, 모순/불명확 지시, 치명적 플랜 갭(executing-plans의 "When to Stop and Ask"). 그 외엔 전 배치를 완주.
- **중간 게이트 주의:** Task 2~9는 토폴로지 전환 중이라 cross-cutting 게이트(telegram-callsites·setup-node-pnpm·verify-traps)가 일시 red일 수 있다. **full `run-bats.sh`/`make ci`는 Task 10에서만** 판정. 중간은 타겟 bats만. 피처 브랜치 중간 커밋 red 허용(최종 green이 기준).
- **커밋 — 아래 규칙을 직접 적용, `Skill(commit)` 호출 금지**(인터랙티브 확인이 연속 실행을 깨뜨림):
  - **언어:** 한국어. **AI 마커 금지**(`🤖 Generated with`, `Co-Authored-By: Claude` 등 절대 금지).
  - **형식:** `<type>(<scope>): 한국어 설명` (필요 시 `- 상세` 본문).
  - **type — 이것만:** `feat`(새 기능)·`fix`(버그)·`refactor`(리팩토링/성능)·`docs`(문서)·`style`(포맷)·`test`(테스트)·`chore`(빌드/설정). `perf`/`build`/`ci` 등 금지.
  - **그룹화:** ① 같은 기능/모듈 디렉토리 함께 ② 목적별 분리(refactor vs fix vs feature) ③ 서로 참조하는 파일 함께 ④ config·테스트·문서·스타일은 각자 별도 커밋. (플랜의 각 Task `커밋` 스텝이 기본 단위.)
  - **위치:** 각 Task 커밋 스텝에서 현재 피처 워크트리 브랜치에 직접 커밋(이미 main 밖이라 새 브랜치 불필요).
