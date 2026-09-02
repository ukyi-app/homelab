# 워크플로 인덱스

`.github/workflows`에서 **무엇을 수동 실행하고 무엇이 자동인지** 한눈에. **owner가 직접 누르는 건 ✨ 변이(생성류) + 🗑️ teardown-app(파괴 — confirm===app 가드+수동 머지)**. 그 외 파괴(리소스)·로컬 작업은 셸(아래 💻 owner-local).

> 네이밍: `<action>.yaml`=공개 디스패처(Run 버튼 O) · `_*.yaml`=내부 reusable(버튼 X, 디스패처가 `uses:`) · `reusable-*.yaml`=cross-repo 계약(외부 앱 레포가 `@main` 호출).

> ⏱️ `timeout-minutes`는 **전 워크플로의 전 잡**에 있어야 한다(route 잡 `uses:`만 예외 — actionlint가 거부하므로 값은 그 reusable의 잡에). 없으면 platform max(6h)라 hang이 6시간 침묵이 되고, `360`을 적는 것은 천장이 아니라 no-op이다. 값은 라이브 실측(잡 실행구간 p50/max) 기반이며 근거 전문은 그룹 밖=`ci.yaml` gate 잡 · `homelab-mutation` 그룹=`bump-poll.yaml` preflight 잡 주석에 있다. 가드: `tools/tests/test_mutation-dispatch.bats`(존재 + 정수 + 360 미만, 분모=`.github/workflows/*.yaml` 전체).

## ✨ 변이 — owner 수동 (workflow_dispatch)

| 워크플로 | 입력 | 언제 |
|---|---|---|
| ✨ create-app | app | 신규 앱 온보딩(앱 이름만 — repo=ukyi-app/<app> main HEAD 기준, 매니페스트+공개 PR) |
| ✨ update-secrets | app | 앱 SealedSecret 첫 추가/갱신(앱 이름만 — repo=ukyi-app/<app> main HEAD 기준) |
| ✨ create-database | name + 확장(체크박스 pg_trgm/pgcrypto/citext/vector/postgis + 자유입력) | 앱용 CNPG DB 프로비전 |
| ✨ create-cache | name + maxmemory(선택) | 앱용 redis 프로비전 |
| 🗑️ teardown-app | app, confirm | 앱 철거 — **파괴**(confirm===app 가드 + **수동 머지**; reusable이 파괴 경계에서 confirm 재검증). owner-local `make teardown-app`과 공존 |

전역 직렬화(`group: homelab-mutation`, `queue: max`, `cancel-in-progress: false`)로 bump-poll/iac/tf-reconcile과 한 줄로 직렬 실행. ⚠️ 그래서 이 그룹의 **모든 잡에 `timeout-minutes`가 있어야 한다** — 하나가 hang하면 나머지가 platform max(6h)까지 pending FIFO로 선다. route 잡(`uses:`)엔 걸 수 없어(actionlint 거부) 값은 동명 `_*.yaml`의 잡에 있다(가드: `tools/tests/test_mutation-dispatch.bats`). 변이 로직은 동명 `_*.yaml` reusable에, 이 디스패처는 **actor 가드(owner-only, `vars.HOMELAB_OWNER`)→validate→route→실패 notify(`.github/actions/mutation-notify`)** 셸. reusable의 PR-first 커밋은 `.github/actions/pr-first-commit`(브랜치·커밋·PR·선택적 auto-merge) 공통 사용. ⚠️ actor 가드는 `vars.HOMELAB_OWNER` 미설정 시 fail-closed — owner 로그인을 repo variable로 1회 설정해야 변이 실행 가능.

## 🔁 reconciler — 스케줄 + 수동 강제 (workflow_dispatch)

| 워크플로 | 주기 | 역할 |
|---|---|---|
| 🔁 audit | 매일 | 레포 정적 드리프트 감사(정보성; 차단성은 `ci` gate가 `--ci`로) |
| bump-poll | 10분 | GHCR 이미지 폴링 → 배포 bump |
| tf-reconcile | 30분 | terraform 드리프트 수렴 |
| pr-sweeper | 30분 | stale auto-merge PR update-branch |
| dns-drift | 6시간 | active&&public DNS resolve 체크 |
| contract-drift | 주1(월) | 동봉 계약(vendored) 사본 드리프트 체크 |
| credential-expiry | 주1(월) | 자격증명 만료 D-14 감시(telegram 경고) |
| renovate | 주1 | 의존성 갱신 PR |

run-name에 트리거 출처(`스케줄`/`수동(actor)`)가 박혀 이력에서 구분된다.

**준비상태 회계(G-09)** — 자격/설정이 없어 job이 통째로 skip되면 GHA는 run을 **초록**으로 끝내고, 그 job 안의 알림 스텝은 `if: always()`여도 함께 skip된다(skip된 job은 스텝을 0개 실행한다). 그래서 `tf-reconcile`·`bump-poll`·`renovate`·`iac`에는 게이트 **밖**의 `accounting` job이 있다: `if: ${{ !cancelled() }}`로 항상 뜨고, `needs.*.result`/`needs.*.outputs.executed`를 `policy/workflow-readiness.json` 원장과 대조해 미실행을 `::error::`(run red) 또는 `::warning::`으로 낸다. telegram은 스케줄 reconciler 3종(tf-reconcile·bump-poll·renovate)만 발화하고, `iac`는 PR 컨텍스트라 red 체크 자체가 신호다(매 PR 알림은 소음). 원장에 **선언된 갭**은 알림에 넣지 않는다 — 매 주기 재발해 진짜 신호를 덮는다. 선언되지 않은 미설정은 required gate(`ci.yaml`의 `bun tools/check-workflow-readiness.ts`)가 정적으로 막는다. ⚠️ 새 job에 시크릿 준비상태 게이트를 달면 **원장 선언이 필수**다(안 하면 gate red).

## 🤖 자동 — 이벤트 트리거 (건들지 말 것)

| 워크플로 | 트리거 | 역할 |
|---|---|---|
| ci | PR·push | 권위 게이트(job `gate` = 유일 required check) |
| iac | PR·push(cloudflare) | terraform apply |
| build | push(`ops/**`)·수동 | 플랫폼 ops 이미지 빌드(pg-tools → GHCR, `:sha-<sha>`+`:18-rclone`) — 배포-전용 apps/는 외부 레포에서 빌드 |
| bump | build 완료(workflow_run) | 이미지 write-back |

## 🧩 reusable — 직접 실행 불가 (Run 버튼 없음)

`_create-app`·`_update-secrets`·`_create-database`·`_create-cache`·`_teardown-app` = 변이 디스패처가 `uses:`로 호출.
`reusable-app-build` = 외부 앱 레포가 `@main`으로 호출하는 cross-repo 계약(파일명·입력이 계약).

## 💻 owner-local — Actions에 없음 (파괴/로컬, 의도적)

| 작업 | 명령 | 사유 |
|---|---|---|
| 앱 철거(로컬) | `make teardown-app APP=<x>` | 디스패처 `🗑️ teardown-app`과 공존하는 로컬 경로(오프라인/파워유저). 래퍼가 clean-worktree·fresh-main 전용브랜치·allowlist staging·PR 강제 + confirm=app 자동 |
| 리소스 철거(retain) | `make teardown-resource RESOURCE=<db\|cache>:<name>` | 위와 동일. purge(--delete-data)는 런북 절차로만 |
| 앱 재활성화/노출 재승인 | `tools/activate-app.ts` (런북 app-platform) | host/public 변경 등 별도 재증명이 필요할 때만 |
