# 설계: `teardown-app` 워크플로 디스패처 (+ confirm 가드)

- 작성일: 2026-06-29
- 상태: 승인됨 (brainstorming HARD-GATE 통과)
- 레포: `ukyi-app/homelab` (단일 레포)

## 1. 동기·목표

현재 앱/리소스 **파괴는 owner-local CLI**(`make teardown-app`/`teardown-resource`)뿐이다(생성 변이는 디스패처: create-app/update-secrets/create-database/create-cache). owner가 앱 철거를 하려면 clean 로컬 체크아웃이 필요해 create-app과 위치가 비대칭이다.

목표: **`🗑️ teardown-app` workflow_dispatch 디스패처**를 추가해 owner가 homelab Actions UI에서 앱을 철거(create-app과 같은 곳). 단 파괴의 안전 마찰은 보존한다.

**비목표**: `teardown-resource`(DB/캐시) 디스패처화 — 데이터 파괴·`--refs-verified` attestation·purge 4단계 상태머신이라 **owner-local 유지**.

## 2. 결정 사항 (brainstorming)

| 결정 | 선택 |
|---|---|
| confirm 가드 | 디스패치 시 `confirm` 입력이 `app`과 **정확히 일치**해야 통과(GitHub repo 삭제 방식) |
| PR 머지 모드 | **수동 머지** — 디스패처는 PR만 생성, owner가 diff 리뷰 후 머지(파괴 체크포인트 유지) |
| CLI 공존 | `make teardown-app` 유지 — 같은 `teardown-app.ts`·`validate-mutation` 재사용 |

## 3. 컴포넌트 (create-app 디스패처 패턴 미러)

- **`.github/workflows/teardown-app.yaml`** (공개 디스패처)
  - `on: workflow_dispatch: inputs: { app, confirm }`
  - `run-name: "🗑️ teardown-app — ${{ inputs.app }}"`
  - `concurrency: { group: homelab-mutation, queue: max }` (전역 변이 직렬화 — create-app과 동일 그룹; `cancel-in-progress` 금지)
  - 입력을 **env(PAYLOAD=toJSON(github.event.inputs)) 경유** 비신뢰 처리(GHA injection 함정 — 인라인 보간 금지) → `bun tools/validate-mutation.ts --action teardown-app --payload-file ...`
  - 통과 시 `uses: ./.github/workflows/_teardown-app.yaml`
- **`.github/workflows/_teardown-app.yaml`** (내부 reusable)
  - **writer App 토큰만**(contents:write + pull-requests:write) — reader 토큰·app_repo 불요(외부 레포 read 0)
  - fresh `main` 기준 `teardown/teardown-app-<app>-<ts>` 브랜치
  - `bun tools/teardown-app.ts --app <app> --repo-root .`
  - allowlist staging(`apps/`·`docs/memory-ledger.md`·`infra/cloudflare/apps.json`·`platform/`)
  - `gh pr create`(제목 `chore: <app> 앱 철거 (teardown-app)`) — **auto-merge 안 함(수동 머지)**

## 4. confirm 가드 = 단일 계약(validate-mutation)

`tools/validate-mutation.ts`:
- 계약표: `teardown-app: ["app", "confirm"]` (현재 `["app"]`에서 확장)
- `PAYLOAD_KEYS`에 `"confirm"` 추가
- **교차검증**: `confirm === app` 아니면 fail-closed(불일치/누락 거부). action별 후처리에 추가.

두 호출자 모두 이 단일 계약을 만족:
- **디스패처**: owner가 `app` + `confirm`(앱명 재입력) 입력 → validator가 일치 강제(UI 오발사 방지)
- **CLI(`scripts/teardown.sh`)**: payload에 `confirm: <app>` **자동 주입**(CLI는 이미 clean-worktree+명시 명령이 마찰 → confirm 자동, 계약은 단일 유지)

→ confirm 로직이 **validate-mutation 한 곳**에 있어 bats로 테스트 가능, 디스패처/CLI 일관.

## 5. 흐름

```
owner: Actions UI → 🗑️ teardown-app (app=foo, confirm=foo)
  → 디스패처: PAYLOAD(env) → validate-mutation(teardown-app, confirm===app 강제) → _teardown-app.yaml
  → writer 토큰 → teardown/teardown-app-foo-<ts>(fresh main)
  → teardown-app.ts: apps/foo/ 삭제 + apps.json 행 제거 + 원장 행 제거
  → gh pr create "chore: foo 앱 철거 (teardown-app)" (수동 머지 대기)
owner: PR diff 리뷰 → gate 통과 → 수동 머지
  → ArgoCD prune(Application/워크로드/SealedSecret) + (active였으면) tf reconcile DNS 제거
```

## 6. 보안·안전

- **2중 파괴 가드**: `confirm === app`(디스패치) + **수동 머지**(PR diff 확인)
- writer App 토큰만(최소권한 — 외부 레포 접근 0). branch protection 우회 불가(required `gate`)
- 입력 **env 경유**·인라인 `${{ }}` 보간 금지(client_payload/owner input 비신뢰 함정)
- `queue: max`로 다른 변이(create-app/bump 등)와 직렬화
- teardown-resource 미변경(owner-local 유지)

## 7. 변경 목록

- 신규: `.github/workflows/teardown-app.yaml`, `.github/workflows/_teardown-app.yaml`
- 수정: `tools/validate-mutation.ts`(confirm 계약), `scripts/teardown.sh`(confirm=app 자동 주입)
- 테스트: `tools/tests/test_validate-mutation.bats`(confirm===app accept/mismatch/missing), 디스패처 구조 검증(`test_mutation-dispatch.bats` 류 — env 경유·queue:max·writer 토큰·auto-merge 부재)
- 문서: `AGENTS.md`(멀티레포 플로우 "파괴는 owner-local" → teardown-app 디스패처 추가·teardown-resource만 owner-local), README 워크플로 목록(🗑️ 이모지), `docs/runbooks/app-platform.md`(로컬 전용)

## 8. 테스트

- validate-mutation bats: teardown-app + `confirm===app` 통과 / `confirm≠app` 거부 / `confirm` 누락 거부 / 구 payload(confirm 없음) 거부
- 디스패처 구조 bats: env 경유 입력·`queue:max`·writer 토큰·**auto-merge 부재(수동 머지)** 검증
- CLI 회귀: `make teardown-app`이 confirm=app 자동으로 여전히 통과(`test_teardown*`/`teardown.sh` dry-run)

## 9. 비범위 (YAGNI)

- teardown-resource 디스패처화(owner-local 유지 — 데이터 파괴 안전)
- auto-merge(수동 머지 채택)
- `dry_run` 입력(수동 머지가 이미 PR diff 프리뷰 제공)

## 10. 리스크·미해결

- **bump-poll와 race**: 동 앱 이미지 업데이트 중 teardown — `queue: max`로 완화(같은 mutation 그룹인지 확인 필요), 수동 머지가 최종 게이트
- **confirm 계약 추가 시 CLI 회귀**: `teardown.sh` confirm=app 자동 주입으로 흡수(회귀 테스트로 보증). validate-mutation의 extra-key 거부 규칙과 PAYLOAD_KEYS 정합 필요
- **writer App 토큰이 파일 삭제+PR**: 기존 create-app과 동일 권한 표면(증가 없음)
- **수동 머지 = required check `gate`**: 디스패처가 PR만 만들고 멈추므로, owner가 머지 전 gate 통과 확인. auto-merge 미설정이 의도(파괴 체크포인트)
