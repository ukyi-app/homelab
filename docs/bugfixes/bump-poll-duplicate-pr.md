---
bugfix: bump-poll-duplicate-pr
invariant-class: bugfix
entry-track: incident
review-track: standard
pipeline-stage: executing
issue-tracker: local
symptom: "같은 앱 커밋(page sha-815abb…)에 대해 bump-poll이 11분 사이 PR 3개(#348·#350·#353)를 열었다. 각 PR이 15분짜리 required 게이트를 태우고, 먼저 머지된 하나를 뺀 나머지는 DIRTY(충돌)+auto-merge 무장 상태로 영구 잔류한다(pr-sweeper는 BEHIND만 처리)."
red-baseline: b68ec90ccfd9a9ecd7dd32811775a21c2c455ffb
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

**PR 생성을 멱등하게** 만든다. 설계는 structure 게이트 5라운드에서 확정됐다(아래 Review Decision Log).

### 1. 결정적 브랜치 + 실행기

- 브랜치명 `bump-poll/<app>-<tag>`(RUN_ID 제거) — **같은 bump = 같은 브랜치**.
- `tools/ensure-bump-pr.ts`가 **조회·결정·원격 변이를 모두** 수행한다. 워크플로는 **로컬 브랜치·커밋만**
  준비하고 도구를 호출한다(직접 `git push`·`gh pr create`·`auto-merge-or-fail.sh` 금지 — 호출부 게이트가 강제).

### 2. 조회 — 완전 열거 + 강한 일관성

```
gh api graphql --paginate --slurp
  repository.pullRequests(headRefName:<branch>, states:OPEN, first:100, after:$endCursor)
    { pageInfo{hasNextPage endCursor}
      nodes{ number isCrossRepository mergeStateStatus headRefOid baseRefName
             author{login __typename} autoMergeRequest{enabledAt} } }
```

- **상한 없는 완전 페이지네이션**. 마지막 페이지가 `hasNextPage:true`면 **fail-closed**(완전성 증명).
  이전의 `gh pr list --limit N`은 **포크 포화 = 배포 정지 무기**여서 폐기했다.
- **검색 API 금지**(`--author`/`--app`/`search(`) — 최종 일관성이라 방금 만든 PR이 **거짓 부재**가 되어
  고아 경로(force-push)로 빠진다. 강한 일관성의 connection API만 쓴다.

### 3. 신뢰 경계 (모두 클라이언트 재검증)

| 조건 | 이유 |
|---|---|
| `isCrossRepository === false` | 포크는 우리 ref를 만들 수 없다 |
| **`author.__typename === "Bot"`** + login 정규화(`app/<slug>`·`<slug>[bot]`·평문 `<slug>` 3표기) | ⚠️ GraphQL은 봇 login을 **평문**으로 준다. 봇의 실계정은 `<slug>[bot]`이므로 **사람이 평문 username을 등록**할 수 있다 → `__typename` 없이는 **사람 PR이 신뢰되어 auto-merge까지 무장**된다 |
| 신뢰된 PR이 **2건 이상** → fail-closed | 정상적으로 불가능 |

**식별**(우리 PR인가) = `(head, base)` 쌍 — 클라이언트에서 매칭.
**소유권**(이 ref를 force-push해도 되는가) = 그 head의 **동일-레포 PR 존재 여부**(base 무관).
→ base를 **서버 필터로 넣지 않는다**: 다른 base를 향하는 동일-레포 PR도 **우리 브랜치를 점유**하는데,
서버에서 숨기면 그것을 못 보고 force-push로 파괴한다.

### 4. 결정

| 신뢰된 PR | 동일-레포 PR(비신뢰) | 원격 브랜치 | 결정 |
|---|---|---|---|
| 없음 | **있음** | (필연적으로 있음) | **fail-closed** — 사람/다른 봇의 브랜치를 절대 덮지 않는다 |
| 없음 | 없음 | 있음(고아) | **adopt** — leased push(원격 OID) → PR 생성 |
| 없음 | 없음 | 없음 | **create** — `git push origin HEAD:refs/heads/<b>` → PR 생성 |
| 있음 · CLEAN/BEHIND/BLOCKED/**UNKNOWN** | — | — | **skip** — 변이 0 |
| 있음 · **DIRTY** | — | — | **rebuild** — leased push(`headRefOid`) → PR 재사용(create 금지) |

**포크는 결정을 막지 못한다**(면제) — 포크가 배포를 억제하는 지렛대가 되면 안 된다.

**push argv 계약**(stub이 계약 밖 형태를 거부): create = `git push origin HEAD:refs/heads/<b>` ·
adopt/rebuild = `git push --force-with-lease=refs/heads/<b>:<expected OID> origin HEAD:refs/heads/<b>`.
⚠️ bare lease는 원격 추적 참조가 없어 **stale로 거부**된다(bare 원격 실측) → 기대 OID 명시가 필수.

### 5. auto-merge 무장 — 결정과 **직교하는 축**, 양방향 reconcile

| lane | 상태 | 행동 |
|---|---|---|
| `bump` | 새 PR(create/adopt) | 생성 직후 무장 |
| `bump` | 신뢰 PR + **미무장** | **재무장**(결정이 skip이든 rebuild든) — 무장이 유실되면 배포가 조용히 정지한다 |
| `bump` | 신뢰 PR + 무장됨 | 손대지 않음(멱등 — force-push는 무장을 지우지 않는다) |
| **`propose-pr`** | 신뢰 PR + 무장됨 | **disarm**(`gh pr merge --disable-auto <number>`) — `.bindings.json`이 `autoDeploy: true→false`로 바뀌어도 **낡은 인가로 승인 없이 머지**되지 않게 |
| `propose-pr` | — | **절대 무장하지 않는다** |

**인증된 셀렉터를 변이 경로 전체에 전달**한다: 기존 PR은 `trusted.number`, 새 PR은 `gh pr create`의 URL에서
파싱한 번호. **브랜치 셀렉터 금지** — `gh pr merge <branch>`는 **동명 포크 PR로 해석**될 수 있다(= 공격자
PR에 auto-merge 무장). 파싱 실패 시 fail-closed(브랜치 폴백 금지).

**승인 게이트 우회 차단**: `--auto-merge` 플래그를 **제거**하고 **`--action <bump|propose-pr>`(필수·기본값
없음)** 로 대체. lane은 `tools/poll-ghcr.ts`가 `.bindings.json`의 `autoDeploy`에서 유도하며(SSOT), 호출부
게이트가 워크플로의 **verbatim 전달**을 강제(하드코딩·읽은 뒤 덮어쓰기 거부). 따라서 `autoDeploy:false` 앱을
자동 배포하려면 **`.bindings.json`을 고쳐야** 한다.

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
| 동일-레포지만 **비-writer 작성자**(사람·다른 봇) → **fail-closed** | ⚠️ structure 게이트 r3에서 교정: 동일-레포 PR의 head ref는 **반드시 우리 레포에 존재**하므로, 예전 계약(create)은 실제로는 그 브랜치를 **force-push로 파괴**하고 중복 PR을 여는 경로였다. 이제 변이 0으로 죽는다 |
| **포크 PR만** 존재 → 결정을 막지 않는다(create/adopt) | 포크는 우리 ref를 만들 수 없다. 포크가 배포를 억제하는 지렛대가 되면 안 된다(r3·r4) |
| **포크가 몇 개든**(포화) 배포가 계속 진행된다 | 완전 페이지네이션 — 상한 fail-closed는 **DoS 무기**였다(r4) |
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
| **B-1** | **(a)** `tools/ensure-bump-pr.ts`: 동결된 create 경로를 **실제 상태 기계**로 교체(create / adopt / skip / rebuild). **원격에 대한 모든 변이(조회·push·PR 생성·auto-merge)는 이 도구 안에서만** 일어난다. **(b)** `.github/workflows/bump-poll.yaml`: **로컬 브랜치·커밋만 준비**하고(`git switch -c bump-poll/<app>-<tag> origin/main` → `bump-tag.ts` → `git commit`) 도구를 호출한다. 워크플로는 **`gh pr create`도 `git push`도 직접 하지 않는다**(호출부 게이트가 강제). 브랜치명에서 `RUN_ID` 제거 | none | `first-increment`. r3 R-6 정정: 이전 문구는 push/PR 생성을 워크플로에 배정해 실행기 계약과 모순됐다 |

## Follow-up backlog

- **F-1 (구조 개선, structure r12 R-38에서 분리)**: bump-poll.yaml의 항목별 오케스트레이션(브랜치 생성·
  bump-tag·add·commit·실행기 호출)을 **테스트된 도구 + 격리 worktree**로 이관. 현재는 인-워크플로 셸 루프이고,
  R-38에서 `git checkout -f main` finally 식 정리로 트랜잭션 격리는 복원했지만, `CONTRIBUTING.md:39-41`은 이 루프를
  "테스트된 도구에 속하는 경계"로 명시한다 — 셸 루프를 worktree-격리 도구로 대체하면 항목 간 상태 공유 표면
  자체가 사라진다. 별도 파이프라인.

- **F-0 (권장, 이 픽스의 한계)**: `bump-poll/**` ref를 **writer App 전용으로 예약하는 GitHub ruleset**
  (`infra/github` terraform). 이 픽스의 커밋 소유권 검증은 **안전 인터록이지 인증이 아니다** — 워크플로의
  `git commit` + 토큰 push는 **서명되지 않으므로**(GitHub은 API로 만든 커밋만 서명한다) git author/committer는
  자유 텍스트이고, 적대적 `contents:write` 행위자는 신원·메시지를 **위조**할 수 있다. 인터록은 *우발적* 파괴
  (다른 봇/사람의 push, 동명 브랜치 재사용, 미지의 고아)를 확실히 막고 심층 방어가 되지만, **강제 가능한
  불변식은 ruleset뿐**이다. 별도 파이프라인.

- **F-1**: 좀비 PR **#348·#350·#351** 정리(운영 — 랜딩 시 수동 close).
- **F-2**: `pr-sweeper`가 **DIRTY + auto-merge 무장** PR을 감지해 경고하도록 확장(별도 flip).
- **F-3**: 콘텐츠 동일 재빌드가 새 인덱스 digest를 만들어 **무의미한 배포 회전**을 일으키는 문제
  (buildx attestation 비결정성 — 원래 F-1의 다른 절반). 별도 파이프라인.

## Review Decision Log

### Codex Structure Review — r11: needs-attention → 2건 전부 Accept (owner 2026-07-15)

> ⚠️ **게이트 실행 함정(재발 주의)**: r11의 첫 3회 실행이 `review-incomplete`로 나왔는데, capacity가 아니라
> **직전 실패 아티팩트(`structure-r11.json`)가 미커밋**이라 무결성 preflight가 `stale-branch-review`로 리뷰를
> **아예 실행하지 않은** 것이었다 — 브랜치-스코프 게이트 전에 트리를 클린하게(아티팩트 커밋) 만들어야 한다.

| ID | 심각도 | 발견 | 결정 | 반영 |
|---|---|---|---|---|
| R-36 | high | `Blocker: exhaustive pagination is re-bounded by the parent process` — `fetchConnection`이 **모든 페이지 전체를 `pages`에 보관**했다가 사후 일괄 파싱·직렬화한다 → R-33에서 subprocess 캡처는 페이지 단위로 잡았지만 **부모 Bun 힙·워크플로 로그**는 여전히 포크 수에 **선형**. 억제 무기가 한 계층 위로 올라갔을 뿐. 승인 설계는 "page → reduce → cursor"인데 구현은 "page → 전량 보관 → 전량 파싱/출력" | **Accept** | `foldConnection`이 각 페이지를 **받는 즉시 접어** 결정에 필요한 신뢰 PR 후보 + 경계 있는 카운터만 남기고 **원본 페이지·미신뢰 포크 노드는 버린다**. 상한 없음·`hasNextPage` fail-closed·SEARCH 금지·강한 일관성 유지. ★ 적대 검증(2렌즈)이 **잔여 누출**을 추가 발견: `runSoft`가 페이지마다 **719바이트 PR_QUERY를 `executed` 감사 배열**에 쌓고 `.executed`로 로그에 직렬화 → 읽기 전용 조회는 감사 대상이 아니다(감사 대상은 변이) → `foldConnection` 조회를 `executed`에서 빼고 **O(1) `graphqlPages` 카운터**로 대체. (구현자 판단: `api graphql`이 아니라 `pullRequests`로 매칭 — 커밋 소유권 증명 쿼리도 `gh api graphql`이라 false-RED 회피) |
| R-37 | medium | `Test-quality: W70 pins the vulnerable representation instead of public behavior` — W70이 `.observed.prs`에 **651 노드 전량**을 요구 → R-36이 없애려는 **전량 보관·직렬화를 동결**. 미래 작업이 "자원 고갈 표면 보존 vs 잠긴 regression 편집" 중 택일하게 강요 | **Accept** | W70/W71을 **공개 행위**로 재작성 — 전량 노드 배열 대신 **경계 있는 총계 요약 + 마지막 페이지 신뢰 PR + 종단 결정(skip·push 0·create 0 / reconcile=disarm)**. `.executed`에 `pullRequests` 페이지 조회가 **0건**임을 단언(감사 출력이 포크 수와 무관함을 고정). 포화 입력·4 MiB 경계 넘김은 유지, RED→GREEN 바이트 동일 |

**뮤턴트(컨덕터 직접 재실행)**: `foldConnection` 조회를 `executed`에 되살림 → **W70·W71 RED** · `--slurp` 단일 캡처로 복원 → W70·W71 RED · 전량 보관 출력(M5) → W70의 `has("prs")|not` 단언에서 정확히 RED.

**최종 baseline**: `red..green` diff = **scope 4파일 정확히**(테스트 변경 0) · regression 110/110 baseline RED · characterization 63/63 green · `--verify-flip` **flipOk: true**.

### Codex Structure Review — r10: needs-attention → 3건 전부 Accept (owner 2026-07-15)

| ID | 심각도 | 발견 | 결정 | 반영 |
|---|---|---|---|---|
| R-33 | high | `Blocker: exhaustive pagination is re-bounded by spawnSync` — `gh api graphql --paginate --slurp`의 **전 페이지를 한 subprocess 캡처**에 담는다. `spawnSync`는 유한 버퍼(기본 1 MiB)이고 스트리밍도 `maxBuffer`도 없다 → **포크 포화 응답이 `gh`를 죽여** 그 앱의 폴링이 반복 억제된다. **R-13에서 없앤 배포 억제 무기가 질의 계층 *아래에서* 부활** | **Accept** | ★ **먼저 실측**(bun 1.3.14 · `node:child_process`): 기본 `maxBuffer` = **1 MiB**, 정확히 1 MiB는 정상, **1 MiB + 1바이트는 자식을 SIGTERM으로 죽인다**(`ENOBUFS`) — 조용한 절단이 아니라 **프로세스 사망** → 매 주기 exit 1. 큰 응답에 **fail-closed 하는 건 해법이 아니다**(그게 곧 억제다) → `--slurp`를 버리고 **페이지를 우리가 따라간다**(`fetchConnection`: 한 페이지 → 축약 → `endCursor`). **캡처 하나 = 한 페이지**라 공격자가 키울 수 없다. 상한 없음·`hasNextPage` 완전성·SEARCH 금지·강한 일관성 전부 보존. `maxBuffer` 4 MiB는 **심층 방어일 뿐** — 1 MiB로 낮춰도 증인은 green(**페이징이 픽스**임을 뮤턴트로 증명). 증인 W70(본 질의 ≈4.5 MiB)·W71(형제 스윕) |
| R-34 | high | `Blocker: reconcile treats an unobservable author as "not ours"` — **형제 파서는 `author` 키 누락을 `null`(계정 삭제)로 접는데** 메인 파서는 스키마 실패로 본다 → `isTrustedSibling`이 걸러내어 **무장된 writer PR이 회수에서 증발**하고 run은 **exit 0**(`revocationBlind`도 안 탄다). V-2 위반이며 **파서·신뢰 모델을 둘로 유지한 대가** | **Accept** | 파서·신뢰 술어를 **하나로 통일**(`parsePrNode`/`isTrustedPr`). `author` 키는 **존재를 요구**하고, **명시적 `null`만** 계정 삭제로 허용, 누락·불량은 **관측 실패**(본 질의=fail-closed / 형제·reconcile=`revocationBlind` → 비-0 종료 + 대상 이름 보고). 증인 W72·W73. ⚠️ **컨덕터 뮤턴트 검증에서 구현자 주장이 거짓임을 발견**: 키 부재 가드만 지우면 **바로 다음 타입 검사**가 `undefined`를 잡아 증인이 green으로 남는다 → **옛 파서 동작을 충실히 재현한 뮤턴트**(키 부재 → 느슨한 비교로 `null` 접기)를 만들어서야 W72·W73이 RED가 됨을 확인 |
| R-35 | high | `Blocker: the branch escapes scope[] and publishes the retired seam` — `tools/README.md`가 main 대비 변경됐는데 `scope[]`에 **없다**(단일-flip 규칙 위반). 게다가 그 **공개 계약이 낡았다** — 상한 있는 `gh pr list` 조회와 `BEHIND → skip`을 광고하는데 구현은 완전 GraphQL이고 BEHIND를 rebuild한다. increment 아티팩트도 동일하게 낡음 | **Accept** | `tools/README.md`를 **`scope[]`에 추가**(이 픽스가 바꾸는 비-테스트 표면이 맞다)하고 내용을 **최종 계약으로 정정**. increment·계획서도 동기화(실측 수치 포함). baseline을 **scope 4파일**로 다시 굳혔다. ★ 동기화 과정에서 내 개요의 **오류 4곳이 코드 기준으로 교정**됐다: 레인 출처는 메인 경로에선 `--action`(플래너 verbatim)이고 SSOT 직독은 `--reconcile-only`뿐(그래서 그 모드는 `--action`을 **거부**한다) · 소유권 증명은 force-push만이 아니라 **무장 자체**를 게이트한다(skip 경로 포함, R-23) · `DIRTY|BEHIND`는 **필요조건일 뿐** 사람 흔적이 있으면 skip으로 뒤집힌다(H-4) · hold 라벨은 `hold`·`do-not-close` **2종** |

**최종 baseline**: `red..green` diff = **scope 4파일 정확히**(테스트 변경 0) · `--verify-flip` **flipOk: true**.

### Codex Structure Review — r9: needs-attention → 3건 전부 Accept (owner 2026-07-15)

| ID | 심각도 | 발견 | 결정 | 반영 |
|---|---|---|---|---|
| R-30 | high | `Blocker: the final RED→GREEN lock compares different test contracts` — 핀된 red/green 사이에서 `regressionCmd`가 지목한 **두 테스트 파일이 모두 수정**됐다(W49 재작성, W59·W60·W62~W64는 green 쪽에만 존재). RED 레코드는 `1..94`인데 GREEN은 `ok 100` → R-26~R-28의 행위는 **최종 단언 아래에서 RED로 증명된 적이 없고**, green의 일부가 프로덕션이 아니라 **테스트 변경**에 귀속될 수 있다 | **Accept** | 컨덕터의 북키핑 오류(baseline을 R-26~R-28 **전에** 세웠다). **최종 테스트 트리를 고정한 뒤** baseline을 다시 세우고 두 레코드를 재생성 → `red..green` diff가 **scope 3파일뿐**(테스트 변경 0), `--verify-flip` **flipOk: true** |
| R-31 | high | `Blocker: reader configuration still gates the independent revocation job` — 공유 `configured` 출력이 **READER && WRITER**를 요구하는데 `reconcile`이 거기 걸려 있다 → **reader가 없거나 회전 중**이면 writer 자격이 멀쩡해도 GitHub이 revocation을 깨끗이 **skip**한다. R-27이 떼어내려던 **바로 그 열화 구간**에서 무장이 살아남는다 | **Accept** | preflight를 **`writer`/`reader` 두 출력**으로 분리 — reconcile은 `writer`만, poll은 둘 다 요구. R-27을 **반쪽만** 고쳤었다(job 본문에서 reader를 뺐지만 **선행 job의 게이트**에 남아 있었다) |
| R-32 | high | `Blocker: the two revocation paths have conflicting failure contracts` — `--reconcile-only`는 실패를 모아 비-0 종료하는데 메인 경로의 **superseded 스윕은 warn하고 계속**한다. `autoDeploy:true` 앱에선 reconcile-only가 무장을 건드리지 않으므로 **이 스윕이 유일한 회수자**인데, disable-auto 실패 + close 차단이 겹치면 **프로세스는 성공, 알림 0, 옛 PR은 무장된 채** 남는다 | **Accept** | 회수를 **결과를 나르는 단일 연산**으로 통일 — 두 경로가 같은 집계·같은 비-0 종료를 쓴다. 변이는 계속 수행(억제는 공격 표면), 실패는 끝에서 알린다 |

**적대 검증(2렌즈)이 R-32 수정에서 더 깊은 구멍을 실측 재현 — V-1·V-2로 함께 수정:**

| # | 결함 | 수정 |
|---|---|---|
| V-1 | **`--reconcile-only`가 bump 레인을 통째로 건너뛴다**(`if (laneHere === "bump") continue`). 회수 트리거는 셋(레인 뒤집힘·**superseded 형제**·**미증명 head**)인데 reconcile은 **하나만** 담당했다 → `autoDeploy:true` 앱의 superseded 무장 PR을 회수하는 **유일한 주체는 메인 경로 형제 스윕**이고, 그건 **플래너가 후보를 낸 주기에만** 돈다. **bump가 머지되면 그 앱은 곧장 `noop`** — 스윕이 필요한 **바로 그 다음 주기부터** 스윕이 굶는다. 옛 태그의 무장 PR이 **영구 잔류**하고 run은 **계속 초록**(하네스 실측: `armed:true, disarmed:false, exit 0`). 그 뒤 누구든 브랜치를 전진시키면 **무승인 롤백** = R-25가 막으려던 바로 그 피해 | reconcile이 **네임스페이스를 완결**한다: bump 레인은 그 앱의 **가장 최신** 열린 신뢰 PR만 무장을 유지하고 **더 오래된 형제는 전부 회수**. `createdAt` 순서를 세울 수 없으면 **전부 회수**한다 — 이 분기는 **한 앱에 열린 신뢰 PR이 2개 이상**일 때만 도달하므로 **최소 하나는 확실히 superseded**다. ★ 비대칭: **과잉 회수는 다음 주기가 재무장**(R-10)하지만 **과소 회수는 무승인 머지**다. 미증명 head 회수(R-23 패리티)도 이 패스에 넣는다. 단독 PR은 제외(churn 방지 = W48의 원래 의도) |
| V-2 | 형제 스윕의 **관측 실패**(ref 열거·PR 조회·파싱·모호성)가 `closeAbandoned` + warn만 하고 **exit 0**. `closeAbandoned`는 **close만** 막고 종료코드엔 **영향이 없다** → "회수 실패는 보안 사실"이 거짓이었다. ★ **W42가 그 구멍을 GREEN으로 고정**하고 있었다(무장된 형제 + 조회 실패를 주입하고 `status -eq 0`을 단언) | **회수 대상을 가릴 수 있는 관측 실패는 그 자체가 회수 실패다** → 두 경로가 같은 집계로 모아 비-0 종료. W42를 정정된 계약으로 재작성(메인 변이는 수행 · run은 빨강 · 실패한 대상이 보고에 이름으로 남는다) |

**뮤턴트(컨덕터 직접 재실행 포함)**: bump 레인 건너뛰기 복원 → **W48·W67·W68·W69 RED** · `uniqueNewest` fail-open(순서 불명이면 유지) → W68 RED · reconcile의 R-23 패리티 제거 → W69 RED · `revocationBlind` 미집계 → **W42 RED**.

**최종 baseline 실측**: regression **106/106 RED**(공짜 통과 0), characterization **63/63 GREEN**, 양 끝단 동일 파티션. `red..green` diff = **scope 3파일 정확히**(테스트 변경 0) → `--verify-flip` **flipOk: true**.

### Codex Structure Review — r8: needs-attention → 4건 전부 Accept (owner 2026-07-14)

세 결함(R-26·R-27·R-28)은 **같은 교훈의 세 얼굴**이다 — 인가(authorization)에서 fail-closed는
"아무것도 하지 않음"이 아니라 **"권한을 회수함"**이고, 회수의 **대상 목록**은 회수와 무관한 것의
성공에 의존해선 안 되며, **상한 있는 조회는 거짓 부재를 만든다**.

| ID | 심각도 | 발견 | 결정 | 반영 |
|---|---|---|---|---|
| R-26 | high | `Blocker: missing bindings has conflicting authorization semantics` — 플래너는 `.bindings.json` 부재를 `autoDeploy:false`/`propose-pr`로 보는데 `probeLane`은 "레인 불명 → **회수 안 함**"으로 처리했다 → 바인딩이 제거되면 무장된 PR의 **낡은 인가가 그대로 생존**. 하나의 SSOT가 인가 경계에서 **다른 해석**으로 갈라졌다 | **Accept** | 플래너(`poll-ghcr.ts:156-162` — 부재·손상·false를 **모두** `propose-pr`)와 같은 해석으로 통일. `probeLane`은 **언제나 레인을 준다**: 부재 → `propose-pr`(회수, exit 0 — 플래너가 정상 상태로 취급) / 손상 → `propose-pr`(회수 + **실패 기록** → run 빨강). **부재와 손상은 보고에서만 갈리고, 인가 경계에선 동일하다.** 증인 W49(재작성)·W59 |
| R-27 | high | `Blocker: revocation still depends on successful planning` — 회수 대상 인벤토리를 `/tmp/plan.json`(reader 토큰 + GHCR 플래너의 산출물)에서 뽑았다 → 토큰 스텝 실패·플래너 예외·앱이 출력에서 누락되면 **회수에 도달조차 못 한다**. H-1이 의존성을 한 칸(`action` 필터 → `plan.json`) 옮겼을 뿐이다 | **Accept** | 회수를 **독립 job**으로 분리 — **writer 토큰만** 쓰고 reader·docker·플래너 스텝을 **하나도 갖지 않는다**. 대상은 `bump-poll/*` **네임스페이스에서 직접 열거**(`git ls-remote` → 브랜치명에서 app 유도; `--reconcile-only`는 `--app`을 **거부**한다). `poll`의 `needs: [preflight, reconcile]`는 **직렬화 전용**(`if: !cancelled()`) — 성공 요구가 아니다. **양방향 비-기아**: reconcile이 죽어도 poll은 돌고, poll이 죽어도 reconcile은 돈다 |
| R-28 | high | `Blocker: truncated human-trace queries can authorize destructive mutation` — 흔적 가드가 **코멘트 100·라벨 50 첫 페이지**만 보고 `totalCount`·페이지네이션·절단 신호가 없다 → 사람 코멘트나 hold 라벨이 **뒤 페이지**에 있으면 "흔적 없음"으로 읽혀 **리뷰 중인 PR을 force-push**하거나 **사람이 보호한 PR을 close**한다 | **Accept** | 두 질의에 `totalCount` 추가 + `connectionOf()`가 **절단 또는 관측불가 ⇒ 사람 흔적 있음**으로 접는다(close 0·force-push 0). ★ **PR 열거에서 이미 배운 함정(상한 있는 조회 = 거짓 부재)을 흔적 조회에는 적용하지 않았다** — 같은 덫에 두 번 걸렸다. 증인 W62(코멘트 뒤 페이지)·W63(hold 라벨 뒤 페이지)·W64(close)·W57(확장) |
| R-29 | high | `Blocker: HEAD has no committed machine-owned GREEN proof` — 락의 `green.sha`가 비어 있어, 아티팩트는 baseline RED만 증명할 뿐 **프로덕션 코드 때문에 flip이 일어났고 HEAD에서 characterization이 여전히 green**임을 증명하지 못한다 | **Accept**(순서대로) | R-26~R-28 커밋 후 `bugfix-status.mjs --verify-flip` 실행 → **flipOk: true**(red에서 regression FAIL + symptomToken, green에서 PASS, 양단 characterization green, 원 repro 소멸) → RED·GREEN 레코드 커밋 + `green.sha` 핀 |

**뮤턴트 증명(에이전트 10종 + 컨덕터 직접 재실행 2종)**: 부재 SSOT → `bump` 레인 = **W49 RED** · 손상 SSOT → `bump` 레인 / 실패 미보고 = **W59 RED** · reconcile이 다시 `plan.json`에서 대상을 뽑음 = 호출부 증인 2건 RED · reconcile job을 `poll`에 다시 접음 = 호출부 3건 RED · `poll`이 reconcile **성공**을 요구 = 기아 증인 RED · `connectionOf`가 절단을 보고 안 함 = **W62·W63·W64 RED** · `totalCount` 미요청 = W62·W64 RED · `totalCount` 부재를 "절단 아님"으로 읽음 = **W57 RED**(절단 가드와 관측불가 가드가 **독립적으로** 고정됐음을 증명).

**파티션 재측정**: baseline에서 regression **100/100 RED**(공짜 통과 0), characterization **60/60 GREEN**. W61(`--reconcile-only`가 `--action`/`--app`/`--tag`를 거부)은 baseline에서 **공짜로 통과**(baseline은 미지의 `--reconcile-only` 플래그 자체로 exit 2)하므로 **양 끝단 불변식 → characterization**으로 둔다.

### Codex Structure Review — r7: needs-attention → 1건 Accept (owner 2026-07-14)

| ID | 심각도 | 발견 | 결정 | 반영 |
|---|---|---|---|---|
| R-25 | high | `Blocker: pr-sweeper can win the autoDeploy-off race` — `pr-sweeper`(30분 크론)가 **레인을 모른 채** 무장+BEHIND인 `bump-poll/*` PR을 `update-branch`로 수렴시킨다. autoDeploy가 true→false로 뒤집혀도 이미 무장된 PR은 그대로라, 체크가 green이 되는 순간 **사람 승인 없이 auto-merge** 된다. 신뢰된 내부 자동화만으로 성립하므로 F-0 ruleset으로는 못 막는다 | **Accept**(scope 확장) | ★★ 적대 검증이 **더 큰 것**을 찾았다: `gh pr update-branch`는 head에 **머지 커밋**을 만든다 → `proveOurCommit`의 메시지 검사가 **반드시** 실패 → 다음 주기부터 disarm + exit 1 영구 반복 → 그 앱의 bump **하드 스톨**. 즉 R-25는 보안 이전에 **정합성** 문제이며, 스위퍼 제거는 선택이 아니다. 그래서 BEHIND도 DIRTY와 **같은 leased force-push**로 푼다(실행기는 `gh pr update-branch`를 한 번도 부르지 않는다). scope에 `.github/workflows/pr-sweeper.yaml` 추가, RED baseline 재구성 |

**적대 검증(3렌즈 반증 + 완결성 비평)이 구현에서 추가로 잡아낸 4건 — 전부 수정:**

| # | 결함 | 수정 |
|---|---|---|
| H-1 | 해제 스윕이 "그 앱에 이번 주기 **후보가 있을 때**"만 돈다(`bump-poll.yaml`이 `select(.action=="bump" or =="propose-pr")`로 거른다) → `noop`/`refuse` 주기엔 실행기가 아예 호출되지 않아 **낡은 무장이 무기한 생존** | **`--reconcile-only`** 모드 — 해제는 **가용성이 아니라 보안 속성**이다. 후보가 없어도 **매 주기 전 앱**에 대해 돈다. 레인은 `.bindings.json`/`.image-pin.json`에서 **직접** 읽는다(워크플로가 레인을 지어내면 그게 승인 게이트 우회다) |
| H-2 | 루프가 `jq \| while read` + `bash -e` → 한 앱의 fail-closed(미증명 head = 사람이 고칠 때까지 **영구**)가 파이프라인을 죽여 **뒤따르는 모든 앱이 매 주기 실행기에 도달조차 못 한다** → 스위퍼가 빠진 지금 이 기아는 **인가 회수의 실패**다 | 항목별 **서브셸 격리** + 실패는 모아 **맨 끝에서** 비-0 종료(run은 빨갛고 telegram 발화). ⚠️ `if ! ( … )`의 조건 문맥은 errexit를 **서브셸까지** 끄므로 안에서 `set -e`를 다시 켠다 |
| H-3 | close 스윕이 **REOPENED 이벤트를 보지 않는다** — reopen은 author·createdAt·head를 바꾸지 않고 유일한 코멘트는 **봇 자신의 close 코멘트**다 → 사람이 reopen하면 **10분마다 다시 닫힌다**. 게다가 close 코멘트가 바로 그 reopen을 구제책으로 안내한다(함정) | `timelineItems(itemTypes:[REOPENED_EVENT])` 관측 → `humanTouchOf`에 편입(**관측 불가 = 흔적 있음**). close 코멘트는 **실효 탈출구(hold 라벨)** 를 명시 |
| H-4 | BEHIND가 rebuild 트리거가 되면서 strict main에선 **머지마다** 발생 → 승인 레인의 열린 PR이 10분마다 force-push되어 **사람의 리뷰가 dismiss되고 인라인 코멘트가 outdated** 된다(close엔 humanTouch 가드가 있는데 rebuild엔 없었다) | rebuild에도 **같은 흔적 가드** — 리뷰·코멘트·담당자·리뷰요청·draft·hold 라벨·reopen 중 하나라도 있으면 **밀지 않는다** |

**뮤턴트 증명(컨덕터 직접 실행)**: `--reconcile-only` 스윕 제거 → W47·W48 RED · reopen 절 제거 → W53·W54 RED · rebuild 흔적 가드 제거 → W56·W57·W58 RED · 루프 격리 제거 → 호출부 기아 증인 RED · reconcile 스텝 제거/비-0 종료 → 각 호출부 증인 RED.

**RED baseline 재구성 실측**: regression **94건 전부 baseline RED**(공짜 통과 0 — 부정 증인 5건 W35·W36·W40·W45·W50은 양 끝단 불변식이라 characterization으로 재분류), characterization **60건 양 끝단 green**, symptomToken 3/3. `red..HEAD`의 비-테스트 변경 = scope 3파일 정확히 일치.

### Codex Structure Review — r6: needs-attention → 3건 전부 Accept (owner 2026-07-14)

| ID | 심각도 | 발견 | 결정 | 반영 |
|---|---|---|---|---|
> **R-22 이행 중 드러난 더 깊은 사실**(재구성이 폭로했다): 옛 동결 executor는 `gh pr list` 프로토콜이라
> 최종 stub(GraphQL)과 어긋나 **fail-closed(exit 3)** 로 죽었다 → "변이하지 않는다·무장하지 않는다"류 단언을
> **공짜로 만족** → W11c·W11e·W11f·W17·W21~W24·W26 **9개 증인이 RED였던 적이 없다**. 또 하네스 가드가
> `.observed.*`를 증상 단언보다 **먼저** 요구해, **조회를 아예 하지 않는** executor를 잡지 못했다(픽스의 설계를
> 버그 관측의 전제로 삼는 순환). 교정: baseline을 **main 인라인 그대로**(조회 0·무조건 create·비-lease push·
> 브랜치 셀렉터 무장) 모델링하고, 증상은 **argv 원장만으로** 단언한다. 결과 — regression **65건 전부 baseline RED**
> (공짜 통과 0), characterization 54건 양 끝단 green, symptomToken 3/3 적중.

| R-22 | high | `Blocker: the locked regression partition changes between RED and HEAD` — 커밋된 RED 레코드는 regression **15**케이스를 돌렸는데, 태그 필터가 그대로인 채 HEAD에선 **37**케이스를 고른다. W8/W9·W20~W24는 `red.sha` **이후에** 추가돼 잠긴 baseline에서 **RED였던 적이 없다** → GREEN 레코드가 **다른 테스트 집합**과 비교되어 동일-테스트 단일-flip을 증명하지 못한다 | **Accept**(권고 대신 대안 이행) | **RED baseline 재구성**: `main` + **최종 테스트 전량** + 동결 executor 로 pre-fix 커밋을 만들고 `--verify-red` 재실행 → `red.sha`·`red-baseline` 재핀. 양 끝단이 **같은 파티션**을 돈다. ⚠️ Codex의 "쪼개서 별도 버그픽스로" 권고는 **Reject**: disarm·ownership은 *이 픽스가 만든* 위험(멱등 브랜치가 force-push 표면을 새로 연다)을 막는 **방어물**이라 분리하면 그 사이 구간이 무방비다 — 단일 flip의 **안전 전제조건**이지 두 번째 관측 행위가 아니다 |
| R-23 | high | `Blocker: ownership proof does not protect auto-merge authorization` — `assertOurCommit`이 force-push 경로에서만 돈다. head가 **교체된** writer PR은 skip 경로에서 여전히 신뢰돼 **미검증 head에 auto-merge가 유지·추가**되고, 반대로 **무장된 DIRTY propose-pr**은 ownership 실패로 `--disable-auto` **이전에 죽어** 낡은 인가가 살아남는다 | **Accept** | provenance를 **인가 reconcile의 입력**으로 승격 — 미검증 head엔 무장 금지 + **이미 무장돼 있으면 회수**. **순서 규칙**: 회수(안전 방향)는 **중단 가능한 ownership 검사보다 먼저**. 증인: foreign-head skip(무장 0·회수 1) · foreign-head DIRTY(push 0 + 회수) · **무장된 propose-pr은 ownership fail-closed여도 disarm 수행** |
| R-24 | medium | `Test-quality: the ownership call-site witness checks dead text` — 워크플로의 `git config`·`git commit` **리터럴 grep** + `BUMP_COMMIT_MESSAGE` 존재 확인뿐 → 이후 config/env 오버라이드·`--amend`가 **실효 커밋을 바꿔도 전부 green** → adopt/rebuild가 **영구 fail-closed**(조용한 배포 정지) | **Accept** | hermetic 루프 증인의 `git` stub이 **실효 user.name/user.email(마지막 쓰기 승)** 과 **실효 최종 커밋 메시지**(amend 반영)를 원장에 기록하고 executor의 ownership 기대식과 대조. 리터럴 grep 단언 제거 |

### Codex Structure Review — r1~r5: needs-attention → 전건 Accept (owner 2026-07-14)

| ID | 라운드·심각도 | 발견 | 반영 |
|---|---|---|---|
| R-12 | r1 · high | `Blocker: propose-pr preserves stale auto-merge authorization` — `.bindings.json`이 `autoDeploy: true→false`로 바뀌어도 **이전에 무장된 PR이 그대로** 남아 **승인 없이 머지**된다 | propose-pr 레인에서 무장된 신뢰 PR을 **disarm**(`gh pr merge --disable-auto <number>`). 무장은 결정과 **직교하는 축**이자 **양방향 reconcile** |
| R-13 | r1 · high | `Blocker: bounded fork results can hide the writer PR` — 상한 있는 조회(`--limit N`)는 포크 PR이 결과를 채우면 우리 PR을 **가린다** → create 중복 or force-push 고아 경로. **포크 포화 = 배포 억제 무기** | **상한 없는 완전 페이지네이션**(GraphQL connection + `--paginate --slurp`). 마지막 페이지가 `hasNextPage:true`면 **fail-closed** |
| R-14 | r2 · high | `Test-quality: arming drops the authenticated PR identity` — 무장 셀렉터가 브랜치면 `gh pr merge <branch>`가 **동명 포크 PR로 해석**될 수 있다(공격자 PR에 auto-merge) | **인증된 PR 번호**만 셀렉터로 전달(기존=`trusted.number`, 신규=`gh pr create` URL 파싱). 파싱 실패 시 fail-closed(브랜치 폴백 금지) |
| R-15 | r3 · high | `Test-quality: the non-writer PR witness models the wrong seam` — 비-writer PR 증인이 검색 API 응답을 흉내내 **실제 seam(강한 일관성 connection)** 을 검증하지 못한다 | stub을 **GraphQL connection 응답 형태**로 재작성. 검색 API(`--author`/`search(`) 사용을 호출부 게이트가 금지 |
| R-16 | r4 · high | `Blocker: PR identity drops the requested base branch` — head만으로 식별하면 **다른 base를 향하는 동일-레포 PR**을 우리 PR로 오인해 재사용한다 | **식별 = `(head, base)` 쌍**(클라이언트 매칭). 단 **소유권**(force-push 가부)은 base 무관 — base를 서버 필터로 넣으면 브랜치를 점유한 타 PR을 못 보고 파괴한다 |
| R-17 | r4 · high | `Blocker: fork saturation remains a deployment-suppression primitive` — 포크 PR 존재만으로 결정이 막히면 외부인이 **배포를 정지**시킬 수 있다 | **포크는 결정을 막지 못한다**(면제) — `isCrossRepository === true`는 신뢰 후보에서 제외될 뿐, create/adopt/skip/rebuild 판정을 차단하지 않는다 |
| R-18 | r5 · medium | `Accepted structure decisions are absent from the authoritative contract` — 계획서가 확정 설계와 어긋난다(낡은 "비-writer → create" 행 포함) | 계획서를 최종 상태 기계로 **동기화**(`8efcb42`) |
| R-19 | r5 · high | `Blocker: PR authorship is treated as branch ownership` — `adopt`가 PR 없는 ref를 무조건 force-push하고, writer PR도 **다른 동일-레포 actor가 head에 push한 뒤** 계속 신뢰된다 → **남의 커밋이 지워진다** | force-push **직전에 원격 head 커밋의 소유권 검증**(author·committer = `<writer>[bot]` + 결정적 bump 커밋 메시지). 아니면 fail-closed. ⚠️ **커밋은 서명되지 않으므로 이는 안전 인터록이지 인증이 아니다**(적대적 `contents:write`는 위조 가능) → 강제 가능한 불변식은 `bump-poll/**` ruleset(**F-0**, 별건) |
| R-20 | r5 · high | `Test-quality: the fork-saturation witness never crosses a page boundary` — stub이 모든 노드를 **단일 종단 페이지**로 감싸 첫 페이지만 소비하는 구현도 통과 | stub이 노드를 **실제 `first:100` 페이지**로 분할(`hasNextPage`/`endCursor`). 포화 증인은 **신뢰 PR을 마지막 페이지에** 배치 → 첫-페이지-only 구현이 RED임을 뮤테이션으로 확인 |

### Codex Plan Review — r8: clean — **approve**(발견 0). "Ship the plan to GREEN." (2026-07-14)

아티팩트: `docs/reviews/bump-poll-duplicate-pr/plan-r8.json`. 락·계획서·state가 `b9d294d`로 정합하고 그
트리가 커밋된 verify-record와 일치한다. 그 baseline이 mixed-lane hermetic 증인 · 단일-대입 가드 ·
공백 구분 `--action` 계약 · propose-pr × 네 결정 경로 증인을 포함한다.

### Codex Plan Review — r7: needs-attention → Accept (owner 2026-07-14)

`Blocker: the r6 witness is outside the locked RED baseline` — 북키핑 스크립트가 **파이썬 인코딩 오류로
조용히 죽어** 락이 옛 sha(`4fd7c55`)에 머물렀고, 그 baseline에는 hermetic 증인이 **없었다**. → 락·계획서·
state를 `b9d294d`로 재고정하고 그 트리에서 verify-record를 재생성했다(회귀 15 · characterization 79).

### Codex Plan Review — r6: needs-attention → 1건 Accept (owner 2026-07-14)

| ID | 심각도 | 발견 | 결정 | 반영 |
|---|---|---|---|---|
| R-12 | high | `Blocker: R-11's structural approval seal still permits false GREENs` — 호출부 게이트가 "`.action` 대입 존재 + 각 `--action` 인자가 `$action`"만 보므로 **읽은 뒤 덮어쓰기**(`action=$(jq …); action=bump;`)를 통과시킨다. 실행기 테스트도 `propose-pr`을 create·skip 경로에서만 덮어 **adopt/rebuild에서 무장하는 구현**이 GREEN이 된다 | **Accept** | **hermetic 루프 증인** 신설: `bump-poll.yaml`의 bump 스텝 `.run` 본문을 yq로 추출해 `git`/`gh`/`bun` stub 아래에서 **두 레인의 plan.json**으로 실제 실행하고 실행기에 전달된 **실제 argv**를 원장으로 단언한다(하네스 자기증명 포함). + **단일-대입 가드**(post-read 덮어쓰기 금지). + `propose-pr` × **네 결정 경로 전부** 무장 0회 증인. **실측**: 후보 B(읽은 뒤 덮어쓰기)·G(조건부 덮어쓰기)가 **구 정적 봉인을 통과**했고 hermetic 실행에서 `trip-mate → --action bump`(승인 앱을 자동 배포 레인으로 위조)를 냈다 — r6의 지적이 실증됐다. 덤: `--action=<val>` 등호 형태는 도구 파서가 **exit 2로 죽는데** 게이트가 통과시키던 결함도 교정 |

### Codex Plan Review — r5: needs-attention → 2건 전부 Accept (owner 2026-07-14)

| ID | 심각도 | 발견 | 결정 | 반영 |
|---|---|---|---|---|
| R-10 | high | `Blocker: auto-merge arming is not idempotent` — 신뢰된 비-DIRTY PR은 항상 skip이므로, push+PR 생성은 됐는데 **무장이 실패**하면 다음 폴링이 그 PR을 보고 **영원히 skip** → autoDeploy 배포가 조용히 정지(pr-sweeper는 이미 무장된 PR만 다룬다) | **Accept** | `autoMergeRequest`를 관측(라이브 스키마 확인: 미무장=`null`)하고 **무장을 desired state**로 취급 — 신뢰 PR + lane=bump + 미무장이면 **재무장**(결정과 **직교하는 축**). 증인 W4(재무장)·W5(멱등)·**W6(DIRTY+미무장 = rebuild+재무장)**·W7(DIRTY+무장 = 재무장 0) |
| R-11 | high | `Blocker: the call-site gate can auto-merge approval PRs` — 게이트가 `--auto-merge` 토큰 존재만 봐서, 두 레인 모두에 무조건 전달해도 GREEN이 된다 → **`autoDeploy:false` 승인 PR이 자동 배포**(승인 게이트 우회 = 단일 flip 밖의 두 번째 행위 변경) | **Accept** | **`--auto-merge` 플래그 제거** → **`--action <bump\|propose-pr>`(필수·기본값 없음)**. 레인은 `.bindings.json`(autoDeploy SSOT)에서만 나오고, 호출부 게이트가 **워크플로의 verbatim 전달**을 강제(하드코딩 거부). 7가지 후보 호출부로 이빨 검증: R-11 우회(양쪽에 `--action bump`)·반쪽 하드코딩·레인 재해석은 **전부 FAIL**, 정상 전달 3형태는 PASS |

### Codex Plan Review — r4: needs-attention → 2건 전부 Accept (owner 2026-07-14)

| ID | 심각도 | 발견 | 결정 | 반영 |
|---|---|---|---|---|
| R-8 | high | `Blocker: executor ownership can still go GREEN with broken workflow ordering` — 호출부 게이트가 도구 존재·직접 push/create 부재·RUN_ID 부재만 본다. **순서**(브랜치 생성 → bump-tag → commit → 실행기)를 증명하지 않고, 워크플로에 남은 **직접 `auto-merge-or-fail.sh` 호출**도 금지하지 않는다 | **Accept** | 호출부 증인 2건 추가(순서 · **auto-merge 독점**). ⚠️ 이 과정에서 **교차 게이트 충돌** 발견: `test_automerge-fallback.bats`가 "bump-poll이 그 스크립트를 호출할 것"을 요구하고 있었다(픽스 후 머지 불가가 될 뻔) → 불변식 소유자를 **파일 → 도구**로 재조준(픽스 전후 모두 GREEN) |
| R-9 | high | `Blocker: the exact-argv harness discards argument boundaries` — stub이 `"$*"`로 평탄화해 기록/비교 → `git push 'origin HEAD:refs/heads/<b>'`(1인자, 라이브에서 **실패**)가 계약(2인자)과 **같은 원장 줄**이 되어 통과한다(거짓 GREEN) | **Accept** | 원장을 **NUL 구분**(레코드 = `arg\0…` + RS)으로 바꿔 argc·인자 경계 보존. 계약 매칭은 **argv 배열 hex 키**로 정확 비교(결합 인자는 `0x20` vs `0x00`으로 갈린다). negative 증인 10종(결합 remote/refspec, 결합 lease/remote/refspec 포함) — **구 하네스가 실제로 거짓 GREEN을 냈음을 재현으로 확인** |

### Codex Plan Review — r3: needs-attention → 2건 전부 Accept (owner 2026-07-14)

| ID | 심각도 | 발견 | 결정 | 반영 |
|---|---|---|---|---|
| R-6 | high | `Blocker: B-1 contradicts the executor contract` — B-1이 `gh pr list`·PR 생성·rebuild push를 **워크플로에 배정**해 "모든 원격 변이는 도구가 한다"는 계약과 모순 → 구현자가 호출부 게이트에서 죽거나 R-4의 분리 순서를 재현한다 | **Accept** | B-1 정정: 워크플로는 **로컬 브랜치·커밋만 준비**하고 도구를 호출. 조회·push·PR 생성·auto-merge는 **전부 도구 안** |
| R-7 | high | `Blocker: lease witnesses accept an unusable push target` — 증인이 lease **접두만** grep하고 git stub이 다른 argv를 수용 → `origin <branch>`를 빼먹은 구현도 GREEN이 되고 **라이브 회복은 실패**한다 | **Accept** | push argv를 **완전 형태로 계약화**(create/rebuild/adopt 3종) + **git stub이 계약 밖 형태를 exit 3으로 거부**. 증인은 원장 줄 **전체 일치**로 단언. **실측(bare 원격)**: bare lease = `stale info` 거부 / 명시 OID lease + `origin HEAD:refs/heads/<b>` = fetch 없이 성공 |

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
