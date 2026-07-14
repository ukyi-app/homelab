---
bugfix: bump-poll-duplicate-pr
invariant-class: bugfix
entry-track: incident
review-track: standard
pipeline-stage: design
issue-tracker: local
symptom: "같은 앱 커밋(page sha-815abb…)에 대해 bump-poll이 11분 사이 PR 3개(#348·#350·#353)를 열었다. 각 PR이 15분짜리 required 게이트를 태우고, 먼저 머지된 하나를 뺀 나머지는 DIRTY(충돌)+auto-merge 무장 상태로 영구 잔류한다(pr-sweeper는 BEHIND만 처리)."
red-baseline: e9f4d59731a0822855ab1e045b145e613be5c55e
bugfix-lock: red
first-increment: [B-1]
increments: [B-1]
spike-1:
---

# bump-poll 중복 PR — PR 생성이 멱등하지 않다

## Root cause

`.github/workflows/bump-poll.yaml`은 폴링 run마다 **새 브랜치**(`bump-poll/<app>-${RUN_ID}`)를 만들고
**기존 열린 PR을 확인하지 않은 채** `gh pr create`한다. 플래너(`tools/poll-ghcr.ts`)는 GHCR 최신 후보와
**main의 배포 핀**만 비교하므로, PR이 머지되기 전에는 main이 여전히 옛 digest라 **폴링마다 "bump 필요"**
로 판정한다 → **같은 후보에 대해 PR이 계속 새로 열린다.**

**라이브 실측(2026-07-13)** — page의 한 커밋(`sha-815abb…`):

| PR | 시각 | 트리거 | 결과 |
|---|---|---|---|
| #348 | 06:34 | 앱 빌드 dispatch | **OPEN · DIRTY · auto-merge 무장**(좀비) |
| #350 | 06:35 | 크론 `*/10` | **OPEN · DIRTY · auto-merge 무장**(좀비) |
| #353 | 06:45 | 크론 | MERGED |

(+ `#351` trip-mate-api도 같은 형태의 좀비 — red-capture 중 발견.)

**왜 아무도 안 치우나**: `pr-sweeper`는 **auto-merge 무장 + BEHIND**만 `update-branch`한다. 중복 PR은
형제가 먼저 머지되며 **DIRTY(충돌)** 이 되므로 스위퍼 대상이 아니다.

**피해**: PR당 15분 required 게이트 소모 · 좀비 PR 누적 · 충돌 PR에 auto-merge가 무장된 채 방치.

## The fix

**PR 생성을 멱등하게** 만든다(plan 게이트 r1이 제시한 더 단순한 대안 채택).

1. **결정적 브랜치**: `bump-poll/<app>-<tag>` (RUN_ID 제거). **같은 bump = 같은 브랜치**.
2. **PR 생성 직전** writer 토큰으로 **자기 레포의 그 브랜치 PR만** 조회:
   `gh pr list --head "bump-poll/<app>-<tag>" --state open --json number,isCrossRepository,mergeStateStatus,author`
3. `tools/ensure-bump-pr.ts`가 **결정 + 원격 변이를 모두 수행하는 실행기**다(plan 게이트 r2의 R-4 반영 —
   워크플로가 `gh pr create`/`git push`를 **직접 하지 않는다**). 관측 사실:
   `gh pr list --head <branch> --state open --json number,isCrossRepository,mergeStateStatus,author,headRefOid`
   + `git ls-remote --heads origin <branch>`(고아 브랜치 탐지). 판정:

| 관측 | 결정 | 근거 |
|---|---|---|
| 열린 PR 없음 + 원격 브랜치 없음 | **create** | 정상 경로(push → PR 생성) |
| 열린 PR 없음 + **원격 브랜치 있음(고아)** | **adopt** | 이전 run이 push 후 `gh pr create`에서 실패한 흔적 → 최신 main에서 재구축 → **leased push** → PR 생성. 이게 없으면 다음 폴링이 고아 브랜치와 충돌해 **배포가 정지**한다(r2 R-4) |
| 동일-레포(`isCrossRepository=false`) + **writer 작성자** + 상태 정상(`CLEAN`/`BEHIND`/`BLOCKED`/**`UNKNOWN`**) | **skip** | 이미 진행 중 — 중복 금지 |
| 동일-레포 + writer + **`DIRTY`**(충돌) | **rebuild** | 최신 main에서 재구축 → **`--force-with-lease=refs/heads/<branch>:<headRefOid>`** push → **같은 PR이 깨끗해진다**(create 금지). ⚠️ **bare lease 금지** — 원격 추적 참조가 없으면 stale로 거부돼 회복이 반복 실패한다(r2 R-5) → 기대 OID를 `headRefOid`로 관측해 명시한다 |
| **cross-repo(포크) PR만** 존재 | **create** | 포크는 신뢰하지 않는다 |
| 동일-레포지만 **writer가 아닌 작성자** | **create** | 신뢰하지 않는다 |
| 잘못된/빈 JSON | **fail-closed(에러)** | 조용한 create 금지 |

**push argv 계약(완전 형태 — plan r3)**: 도구가 낼 수 있는 push는 **정확히 이 셋뿐**이고, 회귀 증인은
원장 줄 **전체**를 `grep -Fx`로 단언하며 테스트의 git stub은 계약 밖 push argv를 **exit 3**으로 죽인다
(접두만 맞고 목적지 refspec을 빠뜨린 구현이 GREEN이 되는 걸 막는다 — 라이브에선 아무것도 밀지 못한다).

| 경로 | argv |
|---|---|
| create | `git push origin HEAD:refs/heads/<branch>` |
| rebuild | `git push --force-with-lease=refs/heads/<branch>:<PR headRefOid> origin HEAD:refs/heads/<branch>` |
| adopt | `git push --force-with-lease=refs/heads/<branch>:<고아 원격 OID> origin HEAD:refs/heads/<branch>` |

근거 — git-push(1): `--force-with-lease=<refname>:<expect>`만이 "…or we do not even have to have such a
remote-tracking branch when this form is used". **bare 원격 레포로 실측(git 2.50, main만 single-branch
clone = 워크플로 checkout 재현)**: bare lease → `! [rejected] (stale info)` / lease 없는 push(두 표기 모두)
→ `! [rejected] (fetch first)`(고아와 non-fast-forward) / **명시 OID lease + `HEAD:refs/heads/<b>` → forced
update 성공**(기대 OID의 로컬 오브젝트가 없어도 된다 — 40-hex는 파싱만 한다). 목적지를 `refs/heads/`로 완전
수식해 lease의 `<refname>`과 **글자 그대로 같은 ref**로 만든다. `-u`(upstream)는 소비자가 없어 뺀다
(PR 생성은 `gh pr create --head`, auto-merge는 브랜치명이 몫).

### plan 게이트 r1의 3개 high 지적이 이 설계에서 해소되는 방식

- **R-2(공개 레포 — 포크가 배포를 억제)**: 조회를 **`--head <우리 브랜치>` + `isCrossRepository=false` +
  writer 작성자**로 좁힌다. 포크는 우리 레포에 브랜치를 push할 수 없고, 같은 이름의 포크 PR은
  `isCrossRepository=true`로 걸러진다. **본문 파싱을 아예 하지 않는다**(공격 표면 제거).
  ⚠️ **실측 교정**: writer 봇의 `author.login`은 **`app/ukyi-homelab-writer`** 다(`<slug>[bot]`이 아니다 —
  red-capture에서 라이브로 확인). 도구는 두 표기를 정규화하고 보존 테스트가 그 계약을 락한다.
- **R-3(DIRTY 교착)**: DIRTY는 **skip이 아니라 rebuild**다 → 깨끗한 대체가 자동으로 생긴다(같은 PR).
  ⚠️ **`UNKNOWN`은 DIRTY가 아니다**(GitHub가 mergeability를 지연 계산 — 라이브에서 흔하다). `UNKNOWN`에
  rebuild하면 **매 폴링마다 force-push**가 난다 → `UNKNOWN`은 **skip**으로 못박고 테스트가 락한다.
- **R-1(RED가 프로덕션 입력을 우회)**: 회귀 테스트가 **`gh pr list --json`의 원시 스키마 그대로**를 먹인다
  (본문·digest 파싱 없음 — 애초에 안 쓴다). `skip`·`rebuild` 두 증인을 모두 RED로 고정했다.

**force-push 안전성**: `bump-poll/<app>-<tag>`는 writer 소유·비보호 브랜치이고, 워크플로는
`concurrency: homelab-mutation` + `queue: max`로 직렬화된다. 그래도 `--force-with-lease`를 쓴다.

## Single-Flip Contract

**flip(하나)**: "우리 레포의 같은 bump 브랜치에 대한 열린 writer PR이 이미 있는" 상태에서
**PR을 또 만들던 것 → 만들지 않는다**(정상이면 skip, 충돌이면 같은 PR을 rebuild).

- **before**: 폴링마다 중복 PR(게이트 소모 + 좀비 누적 + 충돌 PR에 auto-merge 무장).
- **after**: bump당 PR 1개. 충돌 시 그 PR이 최신 main 위로 재구축된다.

**변경 표면(`scope[]`)**: `tools/ensure-bump-pr.ts` · `.github/workflows/bump-poll.yaml`.

**워크플로 호출부 계약**(신규 게이트 `tests/gates/test_bump-poll-callsite.bats`가 강제): bump-poll은
`gh pr create`·`git push`를 **직접 호출하지 않고** `tools/ensure-bump-pr.ts`를 통해서만 원격을 변이하며,
브랜치명에 **`RUN_ID`가 없다**. 이게 없으면 도구만 GREEN이 되고 프로덕션은 그대로일 수 있다(r2 R-4).

## Preserved Contract

`characterizationCmd`가 고정(전부 red baseline에서 GREEN):

| 보존 | 왜 위험한가 |
|---|---|
| 열린 PR 0건 → **create** | 정상 bump가 막히면 배포가 멈춘다 |
| **포크 PR만** 존재 → **create** | 포크가 배포를 억제하면 안 된다(R-2) |
| 동일-레포지만 **비-writer 작성자** → **create** | 사람 PR이 봇 파이프라인을 막으면 안 된다 |
| writer login **두 표기**(`app/<slug>`·`<slug>[bot]`) 인식 | 표기 하나만 맞추면 프로덕션에서 dedupe가 조용히 죽는다 |
| 잘못된 JSON → **fail-closed** | 조용한 create = 중복 재발 |
| `poll-ghcr` 판정 전부(bump/propose-pr/noop/refuse·TOCTOU 가드) | 플래너는 이 픽스에서 **건드리지 않는다** |

## Regression test (already RED at red.sha)

- **seam**: `tools/ensure-bump-pr.ts`(PR 생성 결정) + `tools/tests/test_ensure-bump-pr.bats`(원시
  `gh pr list --json` 스키마를 fixtures로 주입하는 hermetic 테스트).
- **stub 하네스**: 테스트가 `gh`·`git`을 PATH stub으로 가로채 **argv를 원장에 기록**한다(레포 관용구 —
  kubectl/skopeo/curl stub 선례). 호출 **횟수·순서·플래그**를 단언한다.
- `regressionCmd`: `bats tools/tests/test_ensure-bump-pr.bats tests/gates/test_bump-poll-callsite.bats --filter-tags regression`
- `characterizationCmd`: `bats --filter-tags '!regression' tools/tests/test_ensure-bump-pr.bats tests/gates/test_bump-poll-callsite.bats tools/tests/test_poll-ghcr.bats tools/tests/test_bump.bats tools/tests/test_bump-poll-toctou.bats`
- **증인 7개(같은 flip)**: W1 정상 PR → push·create **0회** 기대 · W2 DIRTY → **rebuild argv leased push 1회 +
  create 0회** 기대 · W3 고아 브랜치 → **adopt argv leased push + create** 기대(둘 다 위 완전 argv를 `grep -Fx`) ·
  워크플로 계약 4건(직접 `gh pr create` 금지 / 직접 `git push` 금지 / 도구 경유 / RUN_ID 없는 브랜치명).
- **보존 22건**: 정상 create 경로(**완전 argv 단언**) · **조회가 변이보다 먼저**(순서 단언) · 조회 argv 정확성
  (headRefOid 포함) · 포크·비-writer 불신 · writer login 두 표기 정규화 · fail-closed 6종 ·
  **bare-lease 금지 가드** · **하네스 증명**(계약 밖 push argv 6종을 stub이 exit 3으로 죽이고 계약 3종만 통과 — r3).
- RED verify-record 커밋됨(회귀 exit=1 + 증상토큰, characterization exit=0 / 보존 22 + 기존 41 = 63).

## Increment plan

| id | what the fix does here | blocked-by | notes |
|---|---|---|---|
| **B-1** | **(a)** `tools/ensure-bump-pr.ts`: 동결된 `create`를 **실제 판정**으로 교체(위 표). **(b)** `bump-poll.yaml`: 브랜치명을 `bump-poll/<app>-<tag>`로, writer 토큰 스텝에서 `gh pr list --head …`로 사실 수집 → 도구 호출 → `create`면 PR 생성(+auto-merge), `skip`이면 생략, `rebuild`면 최신 main에서 브랜치 재구축 후 `--force-with-lease` push | none | `first-increment`. ⚠️ 워크플로 변경은 `actionlint`가 검사(로컬 `make ci`엔 없음 → 푸시 전 수동 실행) |

## Follow-up backlog

- **F-1**: 좀비 PR **#348·#350·#351** 정리(운영 — 랜딩 시 수동 close).
- **F-2**: `pr-sweeper`가 **DIRTY + auto-merge 무장** PR을 감지해 경고하도록 확장(별도 flip).
- **F-3**: 콘텐츠 동일 재빌드가 새 인덱스 digest를 만들어 **무의미한 배포 회전**을 일으키는 문제
  (buildx attestation 비결정성 — 원래 F-1의 다른 절반). 별도 파이프라인.

## Review Decision Log

### Codex Plan Review — r2: needs-attention → 2건 전부 Accept (owner 2026-07-14)

| ID | 심각도 | 발견 | 결정 | 반영 |
|---|---|---|---|---|
| R-4 | high | `Blocker: GREEN can pass without fixing the production workflow` — 회귀가 도구만 호출하고 워크플로의 **순서·부작용**을 증명하지 않는다 → 도구만 GREEN이 되고 프로덕션은 그대로일 수 있다. 또한 **push 성공 + `gh pr create` 실패** 시 다음 폴링이 고아 원격 브랜치와 충돌해 **배포 정지** | **Accept** | 도구를 **실행기**로(조회→결정→변이 전부) + **stub 하네스**로 호출 횟수·순서·플래그를 락. **고아 브랜치 상태(adopt)** 추가. **워크플로 호출부 계약 게이트** 신설(직접 `gh pr create`/`git push` 금지, RUN_ID 브랜치 금지) — 4건 모두 red.sha에서 RED |
| R-5 | high | `DIRTY rebuild has no usable force-with-lease precondition` — 기대 OID를 캡처하지도 브랜치를 fetch하지도 않아 **bare lease가 stale로 거부** → 회복 반복 실패 → 배포 정지 | **Accept** | 관측 사실에 **`headRefOid`** 추가 → `--force-with-lease=refs/heads/<branch>:<headRefOid>` **명시 형태**로 못박고, **bare-lease 금지 가드**를 보존 테스트로 락 |

### Codex Plan Review — r1: needs-attention → 3건 전부 Accept (owner 2026-07-14)

아티팩트: `docs/reviews/bump-poll-duplicate-pr/plan-r1.json`.

| ID | 심각도 | 발견 | 결정 | 반영 |
|---|---|---|---|---|
| R-1 | high | `Blocker: the RED witness bypasses the production null-digest injection path` — 회귀가 정규화된 fixtures(디지스트 포함)를 쓰는데 실제 PR 본문엔 digest가 없다 → tag+digest 매칭 구현이 RED를 green으로 만들면서 프로덕션은 계속 중복 | **Accept** | **seam 자체를 교체**: 본문/digest 파싱을 없애고 `gh pr list --json` **원시 스키마**를 먹이는 `ensure-bump-pr` seam으로 red.sha 재고정(`7373cdf`). 증인 2개(skip·rebuild) |
| R-2 | high | `The plan trusts attacker-controlled PR metadata as a deployment-suppression fact` — 공개 레포에서 포크 PR이 브랜치명+본문 SHA로 위장해 **배포를 무기한 억제** 가능 | **Accept** | 조회를 `--head <우리 브랜치>`로 좁히고 **`isCrossRepository=false` + writer 작성자**만 신뢰. 본문 파싱 제거. 실측으로 writer login 표기(`app/<slug>`) 교정 |
| R-3 | high | `Open question: a DIRTY witness can deadlock polling indefinitely` — DIRTY PR을 skip하면 깨끗한 대체가 영영 안 생겨 **배포가 조용히 정지** | **Accept** | DIRTY → **rebuild**(최신 main에서 재구축 + `--force-with-lease`). ⚠️ `UNKNOWN`(지연 계산)은 **DIRTY 아님** → skip으로 못박고 테스트로 락(아니면 매 폴링 force-push) |
