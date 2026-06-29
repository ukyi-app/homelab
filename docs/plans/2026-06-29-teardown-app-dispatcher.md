# teardown-app 워크플로 디스패처 구현 계획

> **For Claude:** REQUIRED SUB-SKILL: superpowers:executing-plans 로 이 계획을 task 단위로 구현하라.

**Goal:** `make teardown-app`(owner-local CLI)와 공존하는 `🗑️ teardown-app` workflow_dispatch 디스패처를 추가한다 — confirm===app 가드 + 수동 머지로 파괴 안전을 보존하고, teardown-resource는 owner-local 유지.

**Architecture:** create-app 디스패처 패턴을 미러한다(`teardown-app.yaml` 디스패처 + `_teardown-app.yaml` reusable). confirm 가드는 `validate-mutation.ts` 단일 계약(`teardown-app: ["app","confirm"]` + `confirm===app`)으로, 디스패처는 owner가 앱명 재입력, CLI는 confirm=app 자동 주입. 수동 머지 = create-app처럼 `auto-merge-or-fail.sh`를 **호출하지 않음**(pr-sweeper는 auto-merge 무장 PR만 건드리므로 무관).

**Tech Stack:** GitHub Actions(workflow_dispatch + reusable), Bun/TS(validate-mutation·teardown-app.ts), bash(teardown.sh), bats, writer GitHub App 토큰.

---

## Phase 0 — 사실·앵커 (구현 전 숙지)

- **수동 머지 메커니즘**: create-app은 `gh pr create`만(auto-merge-or-fail.sh 미호출) → 수동 머지. create-cache/database/update-secrets/bump만 `scripts/auto-merge-or-fail.sh` 호출. **pr-sweeper.yaml은 "auto-merge 무장 + BEHIND" 봇 PR만** update-branch → teardown(무장 안 함)엔 무관. ⇒ teardown 수동 머지 = auto-merge-or-fail.sh 미호출.
- **입력 비신뢰**: 디스패처는 입력을 `env: PAYLOAD: ${{ toJSON(github.event.inputs) }}` 경유로만 validate-mutation에 전달(인라인 `${{ }}` run 보간 금지 — GHA injection 함정).
- **SHA 핀(create-app과 동일 — Renovate 관리)**: `actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4`, `actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0`. 공통 액션 `./.github/actions/setup-bun`, `./.github/actions/telegram-notify`.
- **teardown-app.ts**(기존, 미변경): `apps/<app>/` 삭제 + apps.json 행 제거 + 원장 행 제거. db/cache는 안 건드림.
- **allowlist**(teardown.sh와 동일): `apps/ docs/memory-ledger.md infra/cloudflare/apps.json platform/`.
- **writer App만**: teardown은 외부 레포 read 0 → reader 토큰·app_repo·GHCR·packages:read 불요(create-app보다 단순).

---

## Phase 1 — validate-mutation: confirm 계약 (TDD)

**Files:**
- Modify: `tools/validate-mutation.ts`
- Test: `tools/tests/test_validate-mutation.bats`

### Task 1.1: 실패 테스트 추가 (RED)

`tools/tests/test_validate-mutation.bats`에 추가(@test 영어):

```bash
@test "teardown-app accepts when confirm equals app" {
  run bun "$V" --action teardown-app --payload '{"app":"orders","confirm":"orders"}'
  [ "$status" -eq 0 ]
}

@test "teardown-app rejects when confirm differs from app (mis-fire guard)" {
  run bun "$V" --action teardown-app --payload '{"app":"orders","confirm":"order"}'
  [ "$status" -ne 0 ]
}

@test "teardown-app rejects missing confirm (legacy payload)" {
  run bun "$V" --action teardown-app --payload '{"app":"orders"}'
  [ "$status" -ne 0 ]
}

@test "non-teardown action rejects a stray confirm input" {
  run bun "$V" --action create-app --payload '{"app_repo":"ukyi-app/orders","confirm":"orders"}'
  [ "$status" -ne 0 ]
}
```

**Run (RED):** `bats tools/tests/test_validate-mutation.bats`
Expected: 신규 4 @test 중 accept는 통과/실패 혼재(현 계약은 confirm을 모르므로 `non-teardown ... stray confirm`은 PAYLOAD_KEYS 밖이라 이미 거부될 수도; accept/missing/differs는 현 `teardown-app:["app"]`라 confirm이 "허용 밖 키"로 떨어져 다르게 실패). 핵심: **confirm===app 의미 미구현이라 RED**.

### Task 1.2: 구현 (GREEN)

`tools/validate-mutation.ts`:

1. CONTRACT(L22): `"teardown-app": ["app"],` → `"teardown-app": ["app", "confirm"],`
2. FIELD_RE(L27-32)에 추가: `confirm: APP_NAME_RE,` (형식은 app과 동일; 일치는 교차검증)
3. PAYLOAD_KEYS(L34): `"confirm"` 추가 → `new Set(["action", "app", "app_repo", "sha", "resource", "spec", "confirm"])`
4. disallow-loop(L109): 배열에 `"confirm"` 추가 → `["app", "app_repo", "sha", "resource", "spec", "confirm"]` (teardown-app 외 action에서 stray confirm 거부)
5. 교차검증 추가 — 필수 입력 검증 루프(L102-107) **직후**:
```ts
// teardown-app: confirm은 app과 정확히 일치해야 한다(파괴 오발사 방지 — GitHub repo 삭제 방식)
if (action === "teardown-app" && get("confirm") !== get("app"))
  die(`confirm이 app과 불일치(파괴 확인 실패): confirm=${get("confirm").slice(0, 40)} ≠ app=${get("app").slice(0, 40)}`);
```

**Run (GREEN):** `bats tools/tests/test_validate-mutation.bats`
Expected: 전부 PASS(기존 + 신규 4).

---

## Phase 2 — teardown.sh: confirm=app 자동 주입 (CLI 회귀 방지)

**Files:** Modify `scripts/teardown.sh`

### Task 2.1: app payload에 confirm 추가

`scripts/teardown.sh`의 `--app` 분기:
```bash
printf '{"app":"%s"}' "$target" >/tmp/td-payload.json
```
→
```bash
# confirm은 디스패처(UI)의 오발사 가드 — CLI는 이미 명시 명령+clean-worktree가 마찰이라 confirm=app 자동 주입(단일 계약 유지)
printf '{"app":"%s","confirm":"%s"}' "$target" "$target" >/tmp/td-payload.json
```

### Task 2.2: CLI 회귀 검증

**Run:** `DRY_RUN=1 make teardown-app APP=example-api` (또는 기존 teardown 테스트 `tools/tests/test_teardown*.bats`)
Expected: validate-mutation 통과(confirm=app 자동) → dry-run plan 출력. 기존 teardown bats GREEN.

> teardown 관련 bats가 payload를 단언하면 confirm 필드 추가 반영 갱신.

---

## Phase 3 — 디스패처 워크플로 (teardown-app.yaml + _teardown-app.yaml)

**Files:**
- Create: `.github/workflows/teardown-app.yaml`
- Create: `.github/workflows/_teardown-app.yaml`

### Task 3.1: 공개 디스패처 `teardown-app.yaml` (create-app.yaml 미러)

```yaml
# teardown-app 변이 디스패처 — 앱 철거(apps/<app> + apps.json 행 + 원장 행 제거 → 수동 머지 PR).
# 트리거 경계: owner가 여기서 workflow_dispatch로 실행. 변이 로직은 _teardown-app.yaml(reusable).
# 파괴 가드: confirm===app(validate-mutation) + 수동 머지(auto-merge 안 함).
name: "🗑️ teardown-app"
run-name: "🗑️ teardown-app — ${{ inputs.app }}"
on:
  workflow_dispatch:
    inputs:
      app:
        description: "철거할 앱 이름 (apps/<app>)"
        required: true
      confirm:
        description: "확인 — 위 앱 이름을 정확히 다시 입력 (불일치 시 거부)"
        required: true
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
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
        with: { ref: main }
      - uses: ./.github/actions/setup-bun
        with: { install: 'false' }
      - env:
          PAYLOAD: ${{ toJSON(github.event.inputs) }} # owner 입력도 비신뢰 — env 경유, 인라인 보간 금지
        run: |
          printf '%s' "$PAYLOAD" > /tmp/payload.json
          bun tools/validate-mutation.ts --action teardown-app --payload-file /tmp/payload.json
  teardown-app:
    needs: validate
    uses: ./.github/workflows/_teardown-app.yaml
    with:
      app: ${{ github.event.inputs.app }}
      confirm: ${{ github.event.inputs.confirm }}   # 파괴 경계(reusable)에서 confirm===app 재검증용
    secrets: inherit
    permissions:
      contents: read
  notify:
    needs: [validate, teardown-app]
    if: failure() || cancelled()
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - id: norm
        env:
          RESULTS: ${{ toJSON(needs) }}
        run: |
          if printf '%s' "$RESULTS" | grep -q '"result": *"cancelled"'; then
            echo "status=cancelled" >> "$GITHUB_OUTPUT"
          else
            echo "status=failure" >> "$GITHUB_OUTPUT"
          fi
      - uses: ./.github/actions/telegram-notify
        with:
          status: ${{ steps.norm.outputs.status }}
          source: 변이
          title: teardown-app 실행
          link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
```

### Task 3.2: 내부 reusable `_teardown-app.yaml` (writer 토큰만·수동 머지)

```yaml
# teardown-app reusable — dispatcher(action=teardown-app)가 호출. writer App 토큰으로 fresh main 브랜치에서
# apps/<app> 제거 + apps.json/원장 갱신 → PR(required check `gate`). **auto-merge 안 함 = 파괴는 수동 머지.**
name: "🧰 _teardown-app"
on:
  workflow_call:
    inputs:
      app:
        required: true
        type: string
      confirm:
        required: true
        type: string
jobs:
  teardown:
    runs-on: ubuntu-24.04-arm
    permissions:
      contents: read
    steps:
      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        id: writer
        with:
          app-id: ${{ secrets.HOMELAB_WRITER_APP_ID }}
          private-key: ${{ secrets.HOMELAB_WRITER_APP_PRIVATE_KEY }}
          permission-contents: write
          permission-pull-requests: write
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
        with:
          ref: main
          token: ${{ steps.writer.outputs.token }}
      - uses: ./.github/actions/setup-bun
      - name: confirm 가드 재검증 (파괴 경계 — defense-in-depth, teardown 前)
        env:
          APP: ${{ inputs.app }}
          CONFIRM: ${{ inputs.confirm }}
        run: |
          # 외부 디스패처가 이미 검사했어도 파괴 경계(reusable)에서 confirm===app을 다시 강제 —
          # 다른/미래 호출자가 confirm 없이·불일치로 호출하는 것을 차단(env 경유, 인라인 보간 금지).
          # writer 토큰의 destructive 사용(push/PR)은 이 검증 통과 후에만 일어난다.
          printf '{"app":"%s","confirm":"%s"}' "$APP" "$CONFIRM" > /tmp/td-payload.json
          bun tools/validate-mutation.ts --action teardown-app --payload-file /tmp/td-payload.json
      - name: 철거 plan + PR (수동 머지 — auto-merge 안 함)
        env:
          GH_TOKEN: ${{ steps.writer.outputs.token }}
          APP: ${{ inputs.app }}
          RUN_ID: ${{ github.run_id }}
        run: |
          set -euo pipefail   # 파괴 단계 명시 fail-closed(GHA 기본 -eo pipefail에 더한 belt-and-suspenders — bun|tee 실패가 PR 생성으로 새지 않게)
          [ -d "apps/$APP" ] || { echo "::error::apps/$APP 없음 — 이미 철거됐거나 이름 오류"; exit 1; }
          # 사전 active 상태 기록(롤백 시 DNS 복원 필요 여부 판단용 — #1)
          active=$(jq -r --arg a "$APP" '(map(select(.name==$a)) | .[0].active) // false' infra/cloudflare/apps.json 2>/dev/null || echo unknown)
          bun tools/teardown-app.ts --app "$APP" --repo-root . | tee /tmp/plan.json
          git config user.name "ukyi-homelab-writer[bot]"
          git config user.email "293311924+ukyi-homelab-writer[bot]@users.noreply.github.com"
          branch="teardown/teardown-app-${APP}-${RUN_ID}"
          git checkout -b "$branch"
          # teardown-app.ts가 제거/수정한 것 staging — allowlist(apps/<app> 삭제 + apps.json 행 + 원장 행)
          git add apps docs/memory-ledger.md infra/cloudflare/apps.json platform
          git commit -m "chore: ${APP} 앱 철거 (teardown-app)"
          git push -u origin "$branch"
          {
            echo "teardown-app 자동 생성 PR입니다. **머지 = 철거 승인** — ArgoCD가 Application/워크로드/SealedSecret prune; active였으면 머지 후 iac.yaml이 DNS/tunnel 제거."
            echo
            echo "**사전 상태**: active=${active} (롤백 시 DNS 복원 필요 여부 판단)"
            echo "**롤백**: 잘못 머지하면 이 PR을 git revert(또는 GitHub Revert) → apps/${APP}/(SealedSecret 포함)+apps.json 행+원장 행 복원 → ArgoCD 재생성 + (active였으면) iac DNS 재적용."
            echo
            echo '```json'; cat /tmp/plan.json; echo '```'
          } > /tmp/pr-body.md
          # auto-merge-or-fail.sh 호출 안 함 — 파괴는 수동 머지(create-app 패턴)
          gh pr create --base main --head "$branch" \
            --title "chore: ${APP} 앱 철거 (teardown-app)" --body-file /tmp/pr-body.md
      - name: telegram notify
        if: always()
        uses: ./.github/actions/telegram-notify
        with:
          status: ${{ job.status }}
          source: 앱철거
          title: 앱 철거
          ident: ${{ inputs.app }}
          body: "PR을 확인·머지하세요(수동)"
          link: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
```

> ⚠️ 코멘트 외 `${{ }}`를 `run:` 인라인에 쓰지 말 것(injection). 입력은 env(APP/RUN_ID) 경유 — 위 패턴 준수.

---

## Phase 4 — 디스패처 구조 테스트

**Files:** Modify `tools/tests/test_mutation-dispatch.bats`

### Task 4.1: DISPATCHERS에 teardown-app 추가 + 전용 단언

1. `DISPATCHERS="create-app update-secrets create-database create-cache"` → `+ teardown-app` 추가 → 루프 기반 @test(queue:max·no cancel-in-progress·`_$d.yaml` 라우팅·workflow_dispatch only·env 입력·notify×2)가 teardown-app도 커버.
2. teardown 전용 @test 추가:
```bash
@test "teardown-app dispatcher declares only app and confirm inputs" {
  grep -q "app:" "$WF/teardown-app.yaml"
  grep -q "confirm:" "$WF/teardown-app.yaml"
  run grep -q "app_repo:" "$WF/teardown-app.yaml"; [ "$status" -ne 0 ]
}

@test "teardown-app reusable uses writer token only (no reader, no GHCR)" {
  grep -q "HOMELAB_WRITER_APP_ID" "$WF/_teardown-app.yaml"
  run grep -q "HOMELAB_READER_APP_ID" "$WF/_teardown-app.yaml"; [ "$status" -ne 0 ]
}

@test "teardown-app reusable enforces confirm at its boundary (workflow_call input + re-validate)" {
  grep -q "confirm:" "$WF/_teardown-app.yaml"                                  # workflow_call에 confirm 입력
  grep -q "validate-mutation.ts --action teardown-app" "$WF/_teardown-app.yaml" # teardown 前 재검증(defense-in-depth)
}

@test "teardown-app reusable does NOT auto-merge (destruction = manual merge)" {
  # 주석 제외 후 실행 라인만 검사 — 워크플로 주석에 'auto-merge-or-fail' 설명 문구가 있어 그대로 grep하면 오탐(#2)
  run bash -c "grep -v '^[[:space:]]*#' '$WF/_teardown-app.yaml' | grep -q 'auto-merge-or-fail'"; [ "$status" -ne 0 ]
  run bash -c "grep -v '^[[:space:]]*#' '$WF/_teardown-app.yaml' | grep -qE 'gh pr merge.*--auto'"; [ "$status" -ne 0 ]
}
```

> ⚠️ 만약 기존 루프 @test가 create-app 전용 속성(packages:read 등)을 모든 DISPATCHERS에 강제하면 teardown-app 추가로 깨질 수 있음 — 그 경우 해당 @test를 create-app 한정으로 유지(루프 밖). **추가 후 `bats tools/tests/test_mutation-dispatch.bats` 실행해 확인·조정.**

**Run:** `bats tools/tests/test_mutation-dispatch.bats`
Expected: 전부 PASS.

---

## Phase 5 — 문서

**Files:**
- Modify: `AGENTS.md` (멀티레포 플로우 "생성 변이" 항목)
- Modify: `.github/workflows/README.md` (워크플로 목록)
- (owner-local·gitignored) `docs/runbooks/app-platform.md`

### Task 5.1: AGENTS.md

`AGENTS.md`의 "**파괴(teardown-app/teardown-resource)·activate-app은 owner-local**(`make teardown-*`·런북)" 을:
"**파괴: teardown-app은 디스패처(`🗑️ teardown-app`, confirm===app + 수동 머지) + owner-local CLI 공존. teardown-resource·activate-app은 owner-local**(`make teardown-*`·런북 — 데이터 파괴·attestation)." 로 갱신.

### Task 5.2: README 워크플로 목록

`.github/workflows/README.md`에 `🗑️ teardown-app` 디스패처 + `🧰 _teardown-app` 행 추가(기존 ✨/🧰 규약 따름).

### Task 5.3: (owner-local) app-platform.md 런북에 teardown-app 디스패처 절차 추가 — git 밖, owner가 로컬에서.

---

## Phase 6 — 전체 게이트 + 커밋

### Task 6.1: 게이트 (fail-closed)
```bash
cd <worktree>
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
set -e
make ci                      # validate-mutation·dispatch bats + tsc + shellcheck + actionlint(있으면)
bats tools/tests/test_validate-mutation.bats tools/tests/test_mutation-dispatch.bats
# 워크플로 YAML lint(actionlint가 게이트에 있으면 거기서, 없으면 — 부재만 허용·lint 실패는 게이트 실패):
if command -v actionlint >/dev/null; then
  actionlint .github/workflows/teardown-app.yaml .github/workflows/_teardown-app.yaml
else
  echo "actionlint 미설치 — skip(부재만 허용; 설치돼 있으면 lint 실패가 게이트를 막는다)"
fi
```
Expected: GREEN. **`|| true` 금지** — actionlint가 설치돼 있으면 lint 실패가 게이트를 실패시켜야 한다(부재만 if/else로 허용).

### Task 6.2: 논리 그룹 커밋
```bash
git add tools/validate-mutation.ts tools/tests/test_validate-mutation.bats
git commit -m "feat: validate-mutation에 teardown-app confirm===app 계약 추가"
git add scripts/teardown.sh
git commit -m "fix: teardown.sh가 confirm=app 자동 주입 (단일 계약 유지)"
git add .github/workflows/teardown-app.yaml .github/workflows/_teardown-app.yaml
git commit -m "feat: teardown-app 워크플로 디스패처 + reusable (수동 머지)"
git add tools/tests/test_mutation-dispatch.bats
git commit -m "test: teardown-app 디스패처 구조 검증 추가"
git add AGENTS.md .github/workflows/README.md
git commit -m "docs: teardown-app 디스패처를 문서에 반영"
```

---

## Phase 7 — owner-local 검증 + 롤백 (머지 후)

### 정상 검증
- Phase 6 PR 머지 → Actions에 `🗑️ teardown-app` 디스패처 등장
- **실증(선택)**: example-api 철거에 디스패처 사용 — Actions UI에서 `app=example-api, confirm=example-api` 실행 → PR 생성(수동 머지 대기) → diff 확인 → 머지 → ArgoCD prune + DNS 제거 확인
- **confirm 오발사**: `app=example-api, confirm=wrong` → validate에서 거부(잡 실패) 확인. (reusable을 직접 호출해도 confirm 없으면 거부 — defense-in-depth)

### 롤백 (잘못된 머지 복구 — git revert, #1)
teardown는 git-tracked + 수동 머지라 복구는 PR revert로 한다(파괴는 비가역이 아님):
1. teardown 머지 커밋을 `git revert <sha>`(또는 GitHub "Revert" 버튼) → `apps/<app>/`(SealedSecret 포함) + apps.json 행 + 원장 행 **복원**
2. revert PR이 gate 통과 → 머지
3. ArgoCD가 Application/워크로드/SealedSecret **재생성** + (PR body의 사전 active=true였으면) iac.yaml이 DNS/tunnel **재적용**
- **수용 기준(실증, 선택)**: example-api 철거→revert→앱 다시 Healthy + (active였으면) `curl https://example-api.ukyi.app` 복원 확인
- PR body의 "사전 active 상태" 기록으로 DNS 복원 필요 여부 판단

---

## 리스크·미해결 (Phase C 리뷰가 검증)

1. **DISPATCHERS 루프 @test 회귀** — teardown-app 추가가 create-app 전용 가정을 깰 수 있음 → Task 4.1이 실행·조정으로 흡수.
2. **confirm 계약 추가 ↔ CLI** — teardown.sh confirm=app 자동(Task 2)으로 흡수, 회귀 테스트로 보증.
3. **수동 머지 보장** — auto-merge-or-fail.sh 미호출 + pr-sweeper는 무장 PR만 → teardown 무관(Task 4.1 #3 단언).
4. **allowlist 스테이징** — `git add apps ... platform`이 삭제를 스테이징하는지(teardown-app.ts가 제거한 apps/<app>). 머지 후 검증(Phase 7).
5. **bump-poll race** — `queue: max` 같은 그룹 직렬화 + 수동 머지가 최종 게이트.
6. **GHA injection** — 입력 전부 env 경유(Task 3 단언: env 입력·인라인 보간 금지).

---

## Adversarial review dispositions

> 사후 감사 추적(post-approval). codex 적대 리뷰 — 계획 3패스(C, 캡 도달). Phase A.5 설계 리뷰는 사용자가 취소. 총 발견 5건, **전부 ACCEPTED**(0 rejected — pass3은 partial false-positive를 방어적 ACCEPT).

**Phase C Pass 1 (needs-attention):**
- (high) actionlint fallback `|| true`가 set -e 우회 → lint 실패 마스킹 — **ACCEPTED** → `if command -v actionlint; then ...; else echo skip; fi`(부재만 허용).
- (medium) manual-merge 네거티브 테스트가 워크플로 주석을 grep 매치해 실패 — **ACCEPTED** → grep 전 주석 제외(`grep -v '^[[:space:]]*#'`).

**Phase C Pass 2 (needs-attention):**
- (high) 파괴 머지 후 롤백 경로 미정의 — **ACCEPTED** → Phase 7 롤백 명문화(git revert→복원)+수용기준, PR body에 사전 active 상태 기록.
- (high) reusable이 confirm 가드 우회(app만 받음) — **ACCEPTED** → `_teardown-app.yaml` workflow_call에 confirm 추가 + 디스패처 전달 + teardown 前 validate-mutation 재검증(defense-in-depth).

**Phase C Pass 3 (needs-attention — 캡 도달):**
- (high) `bun | tee`가 teardown 실패를 가려 PR 생성 — **ACCEPTED(방어적)**. **전제는 partial false-positive**: GHA 기본 `run:` 셸=`bash -eo pipefail`이라 이미 전파됨(런북 app-platform.md:144 명문화, `_create-app.yaml:103` 동일 패턴). 그러나 파괴 단계라 명시 `set -euo pipefail` 추가(self-evident fail-closed). "`| tee` 거부" 테스트는 미추가(기존 create-app 오탐 방지).

**최종 판정:** Pass 3 verdict=`needs-attention`, summary="...the destructive workflow pipes the tool through `tee` without specifying pipefail semantics." → 명시 pipefail로 방어적 반영. 3패스 캡 도달 후 사용자가 **"확정(추가 패스 없음)"** 정보 기반 승인. 미반영 high/critical 잔여 0.

---

## Execution directives

- **Skill:** 별도 세션에서 `executing-plans`로 구현. **이 워크트리**(`/Users/ukyi/workspace/homelab/.claude/worktrees/feat+teardown-app-dispatcher`, 브랜치 `worktree-feat+teardown-app-dispatcher`)에서 수행(단일 레포).
- **연속 실행:** 배치 사이 일상 리뷰로 멈추지 말 것. **진짜 블로커일 때만** 멈춤(누락 의존·반복 실패 검증·불명확 지시·치명적 갭). 그 외 전 배치 완료까지.
- **워크플로 함정:** `run:` 입력은 **env 경유**(인라인 `${{ }}` 보간 금지 — GHA injection). 게이트에 `|| true` 금지(actionlint는 if/else 부재만 허용). bats `@test` 영어.
- **커밋 — 아래 규칙 직접 적용; `Skill(commit)` 호출 금지**(연속 실행):
  - **언어** 한국어, **AI 마커 금지**(`🤖`·`Co-Authored-By: Claude` 등).
  - **형식** `<type>(<scope>): 한국어 설명`.
  - **type(이 7개만)** `feat`/`fix`/`refactor`/`docs`/`style`/`test`/`chore`. `perf`/`build`/`ci` 금지.
  - **그룹화** ① 같은 모듈/목적 함께 ② 목적별 분리(feature vs test vs docs) ③ config/테스트/문서 각각 별도. Phase 6 Task 6.2의 그룹 참고.
  - **위치** 각 Commit step에서 현재 워크트리 브랜치에 직접(이미 main 밖, 새 브랜치 불요). homelab은 PR-first.
- **게이트 fail-closed:** `make ci`·bats가 RED면 해결. `make verify-posture`는 KUBECONFIG 없으면 자체 skip.
- **머지:** Phase 6 PR은 **수동 머지**(파괴 디스패처라 auto-merge 미설정 — 본 PR 자체도 일반 기능 PR이므로 owner 판단). Phase 7 owner-local 검증·롤백 실증은 머지 후.
