# 워크플로 디스패치 직관성 개선 — 설계

- 날짜: 2026-06-18
- 상태: 설계 확정 (hardened-planning Phase A)
- 브랜치: `feat/workflow-dispatch-discoverability`

## 1. 배경 / 문제

`.github/workflows`의 19개 워크플로 중 **무엇을 수동 실행하고, 어떤 걸 써야 하는지** 직관적이지
않다. 원인 3가지:

1. **표시이름이 평범한 식별자뿐** (`bump`, `ci`, `iac`, `dispatch-mutation`…) — Actions
   사이드바에서 "owner가 클릭할 게 뭔지" 신호가 없다. `_create-app` 같은 부품도 사이드바에 그대로
   나열돼 클러터.
2. **`run-name` 미사용**(전체 0건) — 실행 이력이 전부 `dispatch-mutation #N`으로만 보여 "방금
   무슨 run인지" 구분 불가.
3. **`dispatch-mutation`의 `action`이 자유 텍스트 + 입력 5개 과적재** — owner가 8개 액션을 외워
   타이핑하고, 어떤 입력이 어떤 액션에 쓰이는지 폼에서 알 수 없다.

## 2. 목표 / 비목표

**목표**
- Actions 사이드바에서 "owner가 실행할 변이"가 각각 자기 이름으로 보이고, 폼엔 **해당 입력만** 뜬다.
- 실행 이력이 `run-name`으로 식별된다(수동 실행 가능 워크플로 전부).
- **파괴·로컬 작업은 CI 노출 0** — 의도적 owner-local 셸 실행으로만.
- 읽기 전용 워치독(`audit`)은 스케줄 reconciler로 옮겨 사람이 기억해 누르지 않아도 돈다.
- 전 워크플로의 트리거·실행주체·용도를 한 표(`README.md`)로 문서화.

**비목표**
- 변이 로직(App 토큰·config read·SealedSecret 검증·PR 생성) 자체 변경 — 기존 reusable을 그대로 둔다.
- 보안/신뢰 경계 변경 — App 토큰·PR-first 모델은 불변(단일 디스패처는 보안 요소가 아님).
- `reusable-app-build.yaml`(외부 앱 레포 cross-repo 계약) 손대지 않음.

## 3. 현재 구조 (코드로 확인된 사실)

- **변이 진입점**: `dispatch-mutation.yaml`(workflow_dispatch 전용)이 `action` 입력으로 8종을
  라우팅 — `create-app | activate-app | update-secrets | create-database | create-cache |
  teardown-app | teardown-resource | audit`. 내부적으로 `_*.yaml` reusable을 `uses:`로 호출.
- **전역 직렬화는 이미 다중 워크플로 패턴**: `dispatch-mutation`·`bump-poll`·`tf-reconcile`·`bump`
  네 개가 **이미** `concurrency: {group: homelab-mutation, queue: max, cancel-in-progress: false}`를
  공유한다(라이브 검증). → 변이를 워크플로별로 쪼개 같은 group에 합류시키는 건 *입증된 패턴의 확장*.
- **`audit`는 읽기 전용 드리프트 리포트**(`tools/audit-orphans.mjs`): 레지스트리↔매니페스트↔바인딩↔원장
  정적 교차 대조, 8종 드리프트(차단 2 / 정보 6). **차단성(orphan-dns·dangling-binding)은 이미
  `ci.yaml`의 `audit-orphans --ci`가 PR 게이트로 잡는다.** 수동 `audit`의 고유 가치는 정보성
  드리프트(incomplete-purge·unreferenced-resource·stale-ledger-row 등)를 온디맨드 리포트하는 것뿐.
- **teardown 안전경계는 워크플로에 있다(툴이 아니라)**: `_teardown.yaml`이 App 토큰으로 bot 브랜치 생성 +
  **allowlist `git add`**(`apps/`·`docs/memory-ledger.md`·`infra/cloudflare/apps.json`·`platform/`만) +
  PR + Telegram을 수행하고, 툴(`teardown-app.mjs`·`teardown-resource.mjs`)은 `.bindings.json` 참조 0
  강제·retain/purge·플랜 산출 등 **working tree 변이만** 한다. → owner-local로 옮기려면 이 staging/PR/notify
  경계를 **로컬 래퍼로 이식**해야 한다(단순 `node tools/teardown-*.mjs` 실행으론 부족 — §4.4, A.5 F2).
- **스케줄 reconciler 패턴 확립**: `dns-drift`가 `if: failure() || count != '0'` + preflight skip +
  `::notice::`로 **드리프트 있을 때만 Telegram** → "매일 0건" 스팸 없음. audit 전환의 템플릿.
- **교차참조**: 표시이름으로 참조되는 건 `bump.yaml`의 `workflow_run: workflows:[build]` 1건뿐.
  본 설계는 `build`의 `name:`을 바꾸지 않으므로 무관.

## 4. 설계

### 4.1 `dispatch-mutation` 멀티플렉서 + choice 드롭다운 완전 제거

`dispatch-mutation.yaml` 삭제. action 선택 개념 폐기.

### 4.2 변이 4종 → 전용 `workflow_dispatch` 워크플로

신규 파일: `create-app.yaml` · `update-secrets.yaml` · `create-database.yaml` · `create-cache.yaml`.
파일명 규약은 기존 `_x.yaml`(reusable) ↔ `x.yaml`(공개 디스패처) 페어링으로 일관.

각 디스패처 구조(**thin wrapper — 기존 reusable 보존**):
- `name: "변이: <action>"` — 사이드바에서 `변이:` 접두사로 그룹화.
- `run-name:` — 대상 식별. 예 `변이: create-app — ${{ inputs.app_repo }}@${{ inputs.sha }}`.
- `on: workflow_dispatch` — **해당 액션 입력만**:
  - `create-app` / `update-secrets`: `app_repo`, `sha`
  - `create-database` / `create-cache`: `spec`
- `concurrency: {group: homelab-mutation, queue: max, cancel-in-progress: false}` — 전역 직렬화 합류.
- **권한은 액션별(A.5 F1)**: `create-app`은 호출 잡에 `packages: read` 유지 — `_create-app.yaml`이
  GHCR `docker login` + `imagetools inspect`로 digest를 해석(이미지 없으면 create-app 중단)하고,
  **reusable 권한은 caller 잡이 상한이라 elevate 불가**하기 때문. 나머지(`update-secrets`/
  `create-database`/`create-cache`)는 `contents: read`. 일괄 `contents: read`는 create-app을 깨뜨림.
- 잡 흐름: `validate`(`validate-mutation.mjs --action <고정> --payload-file`, **비신뢰 입력 env 경유·
  인라인 보간 금지**) → `uses: ./.github/workflows/_<action>.yaml`(기존 reusable 그대로, `secrets: inherit`)
  → `notify`(`if: failure() || cancelled()`).

**대안 거부 — reusable 인라인(`_*.yaml`을 디스패처에 합쳐 파일 절감):** 검증된 변이 로직을 옮겨
쓰는 churn·리스크가 큼. 사이드바 클러터는 `_*`가 Run 버튼이 없고 README가 설명하므로 thin wrapper가
우월(안전 우선).

### 4.3 `audit` → 스케줄 reconciler

`_audit.yaml` 삭제, 신규 top-level `audit.yaml`:
- `name: "🔁 audit — 드리프트 감사"`(가칭), `run-name`으로 수동/스케줄 출처 식별.
- `on: { schedule: [cron], workflow_dispatch }` — cron은 **UTC**(GHA). 정적 드리프트라 일 1회 수준 권장
  (정확 주기는 플랜에서). `workflow_dispatch`로 강제실행 유지.
- **dns-drift 패턴 차용**: 드리프트 count>0 또는 실패 시에만 Telegram, 0건은 `::notice::`로 skip.
- `concurrency: { group: audit, cancel-in-progress: false }` — **읽기 전용이라 homelab-mutation 그룹 아님**
  (변이 직렬화와 무관, 별도 group).
- 변이 그룹에서 완전히 이탈 → reconciler 가족(bump-poll/tf-reconcile/pr-sweeper/dns-drift)에 합류.

### 4.4 owner-local 액션 (워크플로 없음)

`teardown-app` · `teardown-resource` · `activate-app`을 Actions 노출에서 제외하되, teardown은
**안전경계를 보존하는 first-class owner-local 래퍼**로 이식한다(A.5 F2 — 단순 툴 실행은 PR/staging/notify
경계를 잃음):
- `_teardown.yaml` 삭제. **신규 `make teardown-app APP=<x>` / `make teardown-resource RESOURCE=<db|cache>:<name>`**
  타겟(로직은 `scripts/teardown.sh`)이 `_teardown.yaml`의 envelope를 로컬에서 강제: **clean-worktree·
  not-on-main 가드 → 툴 실행(plan/dry-run) → 플랜 리뷰 표시 → 동일 allowlist staging(`apps/`·
  `docs/memory-ledger.md`·`infra/cloudflare/apps.json`·`platform/`) → `gh pr create` → (선택)Telegram**.
  App 토큰 대신 owner 본인 `gh` 자격 사용(owner=admin이라 push/PR 가능).
- 툴(`teardown-app.mjs`·`teardown-resource.mjs`)·purge 상태머신은 불변 — 래퍼가 감쌀 뿐.
- `activate-app`은 클러스터 게이트라 디스패처 echo 스텁이었음 — 스텁째 제거.
- README/런북에 `make teardown-*` 사용법 + "왜 CI에 없는지"(파괴/로컬) 명시.

### 4.5 `run-name` 전체 적용

수동 실행 가능한 워크플로 **전부**에 `run-name` 추가, 트리거 출처(수동/스케줄)와 맥락을 박는다:
- 신규 변이 4종(대상 식별), `audit`(수동/스케줄).
- 기존 수동 트리거: `build`·`bump-poll`·`tf-reconcile`·`pr-sweeper`·`dns-drift`·`renovate`
  — 예 `🔁 tf-reconcile — 스케줄` vs `🔁 tf-reconcile — 수동(${{ github.actor }})`.

### 4.6 `.github/workflows/README.md` 인덱스

디렉토리 열람 시 GitHub가 렌더. 표 컬럼: **워크플로 | 트리거 | 실행 주체 | 언제 쓰나**.
4그룹(🎛️ 변이·수동 / 🔁 reconciler·자동+수동 / 🤖 자동·건들지말것 / 🧩 reusable·직접실행불가) +
**owner-local 액션 절**(teardown×2·activate-app: 로컬 명령 + 사유).

### 4.7 실패 알림 DRY

변이 4 디스패처의 failure/cancelled 알림(취소>실패 정규화 + action sanitize + telegram 전송)을
**공유 단위로 추출**해 4중 복제를 피한다. 형태(기존 `./.github/actions/telegram-notify` composite를
감싸는 신규 composite action 권장 vs reusable workflow)는 플랜에서 확정. 목표는 "복제 0".

### 4.8 문서/메모리 정합 (의도된 churn)

- `AGENTS.md`:
  - 네이밍 컨벤션 절 — `_*.yaml`="dispatch-mutation만 호출" → "per-action 변이 디스패처가 호출".
    공개 디스패처(`x.yaml`)/owner-local/`audit` reconciler 분류 추가.
  - 멀티레포 앱 플로우 절 — "owner가 dispatch-mutation 실행" 서술을 액션별 워크플로 + teardown
    owner-local로 갱신.
  - 함정 절 — 직렬화 불변 가드 신설 반영.
- 런북 `app-platform.md`(로컬) — "단일 진입점" 서술, teardown/activate owner-local 절차.
- 메모리(`homelab-plan-progress` 등) — 디스패처 구조 변경 반영.

## 5. 파일 변동 요약

| 변동 | 파일 |
|---|---|
| 삭제 | `dispatch-mutation.yaml` · `_audit.yaml` · `_teardown.yaml` |
| 신설 | `create-app.yaml` · `update-secrets.yaml` · `create-database.yaml` · `create-cache.yaml`(전용 디스패처) · `audit.yaml`(스케줄) · `README.md` · 공유 실패-알림 단위(composite 추정) · `scripts/teardown.sh`(owner-local teardown 래퍼, A.5 F2) |
| 수정 | `build`·`bump-poll`·`tf-reconcile`·`pr-sweeper`·`dns-drift`·`renovate`(run-name 추가) · `AGENTS.md` · `Makefile`(`teardown-app`/`teardown-resource` 타겟) · 직렬화·권한 가드 테스트 |
| 유지(불변) | `_create-app`·`_update-secrets`·`_create-database`·`_create-cache.yaml` · `tools/{teardown-app,teardown-resource,audit-orphans,validate-mutation}.mjs` · `reusable-app-build.yaml` · `ci.yaml`(audit --ci 게이트) |

**노출(Run 버튼) 표면**: 변이 8종 후보 → **변이 4 + audit(reconciler)** 로 축소. teardown×2·activate=로컬.
(yaml 파일 수는 19→약 22로 증가하나, `_*`는 Run 버튼이 없어 "무엇을 실행하나" 혼란에 기여하지 않음.)

## 6. 안전성 / 불변식

- **전역 직렬화 가드(신규)**: 모든 변이 디스패처가 `group: homelab-mutation` + `queue: max` +
  `cancel-in-progress: false`를 공유함을 강제하는 가드(bats 또는 `scripts/check-*`). queue:max ↔
  cancel-in-progress:true 병용 금지 함정(AGENTS.md)이 4파일로 퍼지는 드리프트를 차단.
- **권한 천장 가드(신규, A.5 F1)**: `create-app` 디스패처 호출 잡이 `packages: read`를 부여하는지
  (= 호출 reusable의 필요 스코프 충족) 정적 검사 — reusable 권한은 caller가 상한이라 elevate 불가한
  규칙의 회귀를 차단.
- **owner-local teardown 안전 envelope(A.5 F2)**: 래퍼가 not-on-main·clean-worktree·allowlist
  staging·dry-run plan 리뷰·PR을 강제 — CI `_teardown.yaml`이 주던 감사·알림 경계 보존.
- **비신뢰 입력**: owner 입력도 비신뢰 — `validate`/`notify`에서 env 경유, `with:` 인라인 보간 금지(현 패턴 보존).
- **외부 계약 불변**: `reusable-app-build.yaml`·`bump↔build` 무영향.
- **audit**: 차단성은 PR 게이트(`--ci`)가 계속 잡음. 스케줄 알림은 드리프트>0/실패만(스팸 방지). cron=UTC.

## 7. 검증 전략 (TDD 대상)

- 게이트: `make verify` · `make ci` · bats(`tools/tests`·`scripts`) · actionlint(존재 시).
- **직렬화 불변 가드 테스트**(신규, fail-first).
- 각 신규 디스패처: 올바른 입력만 선언 + 올바른 reusable로 라우팅 + validate가 고정 action 강제(정적/bats).
- **create-app 디스패처가 호출 잡에 `packages: read`를 선언하는지 정적 검사(A.5 F1 회귀)**.
- `audit.yaml`: schedule+dispatch 존재 + 조건부 notify(0건 skip) — dns-drift류 검증.
- **owner-local teardown 래퍼(`scripts/teardown.sh`)**: not-on-main·clean-worktree 가드·allowlist
  staging·dry-run plan을 bats로 검증(A.5 F2).
- 회귀: `dispatch-mutation`/`_audit`/`_teardown` 참조가 레포 어디에도 남지 않음(grep 가드).
- 외부 계약 무변경 확인.

## 8. 리스크 & 오픈 질문

- `queue:max`의 워크플로 경계 동작 — 라이브 4워크플로로 입증됨. `iac.yaml`도 같은 group인지 플랜에서 재확인.
- 사이드바에 `_*` reusable + 신규 디스패처 공존 — `변이:`/`🔁` 표시이름 접두사 + README로 구분.
- 문서 churn 범위가 넓음(AGENTS.md·런북·메모리) — 의도된 것, 누락 시 정합성 저하.
- audit 스케줄 주기(일 1회 vs 6시간) — 플랜에서 확정.

## 9. A.5 설계 적대적 리뷰 dispositions

Codex 설계 리뷰(`--kind design`, `ok:true`/`planInDiff:true`/`verdict:needs-attention`, high 2건):

- **F1 (high) — 래퍼 `contents: read` 천장이 create-app `packages: read` 박탈 → 수용.**
  `_create-app.yaml`이 GHCR `imagetools inspect`로 digest 해석(필수), reusable 권한은 caller가 상한.
  반영: §4.2 액션별 권한(create-app=`packages: read`) + §6 권한 천장 가드 + §7 정적 검사.
- **F2 (high) — owner-local teardown이 PR/allowlist staging/notify 안전경계 상실 → 수용.**
  `_teardown.yaml`이 bot 브랜치+allowlist `git add`+PR+telegram을 수행(툴은 working tree만).
  반영: §3·§4.4 first-class owner-local 래퍼(`scripts/teardown.sh` + `make teardown-*`) + §6 envelope 불변식 + §7 bats 검증.

수용 0 reject / 2 accept. 둘 다 코드 검증·범위 내·high.
