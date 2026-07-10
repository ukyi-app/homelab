---
refactor: arch-deepen-2026-07-09
invariant-class: refactor
entry-track: architecture
review-track: full
pipeline-stage: executing
issue-tracker: local
behavior-baseline: 124d1f96a834d03405a0082805026129280ae72f
characterization-lock: done
first-increment: [R-1]
structure-gate: done
increments: [R-1, R-2, R-3]
spike-1:
---

# image-pin 커널 — 배포 핀 형식·descriptor 지식의 deep module 수렴

> 용어는 `CONTEXT.md`(배포 핀·apps 레인·베스포크 레인·인라인 핀·descriptor·
> autoDeploy)를 따른다. discover 증거 원문:
> `docs/reviews/arch-deepen-2026-07-09/discover-evidence.json`.

## Current shape (the problem)

"배포 핀"이라는 한 개념에 모듈이 없다. 읽기 반쪽은 `tools/poll-ghcr.ts`,
쓰기 반쪽은 `tools/bump-tag.ts`에 살고, 둘은 `bump-poll.yaml`이 plan JSON으로
잇는 한 프로토콜의 양단이다. 형식 지식이 seam 없이 산재한다:

- **인라인 핀 정규식이 바이트 동일 복제** — poll-ghcr.ts:178 ≡ bump-tag.ts:70
  `/^(.+?):(sha-[0-9a-f]{7,40})@(sha256:[0-9a-f]{64})$/`
- **sha-\* tag 형식 정규식 3벌** — poll:152 · bump:46 · create-app:41
- **sha256 digest 형식 정규식 3벌** — bump:50 · create-app:42 (repin-pgtools:17은
  개념 불일치로 수렴 제외 — ops 이미지)
- **descriptor(.image-pin.json) 의미론 양분** — 읽기 poll:176-185 / 읽기+쓰기
  bump:63-79, shape 합의는 주석뿐
- **autoDeploy `=== true` fail-closed 해석**이 poll 두 곳(bindings:159 ·
  descriptor:185)에 관용구로 반복

**Deletion test(적대 검증 통과)**: 이 커널을 지우면 위 지식이 2+파일에
재출현한다 — 집중이지 이동이 아니다. 방치 시 실패 모드: 한쪽 정규식만
느슨해지면 planner가 승인한 핀을 bumper가 거부(또는 그 역)해 해당 컴포넌트가
**영구 refuse 루프**에 빠지고, 이 cross-file skew는 현행 어떤 게이트도 잡지
못한다.

스켑틱 확정 축소 범위: 커널은 **얇은 형식/descriptor 계층만** — 깊은 로직
(ancestry 증명·TOCTOU·no-op·stale-digest 제거·path-traversal 가드)은 본질적으로
읽기/쓰기 측 소유라 옮기지 않는다(옮기면 이동일 뿐).

## Target shape (the deepening)

**design-it-twice 승자: B+C 하이브리드** (A=최소 인터페이스·B=유연성·C=최빈
호출자 3안 병렬 설계 → B 기반: 본문 SSOT·정규화 0·정책 원자 / C 접목: null-안전
autoDeploy·스프레드 왕복 관용구. A 기각 사유: descriptor 정규화 흡수가 행위
보존 증명을 조건부로 만듦).

신규 `tools/lib/image-pin.ts` — 의존성 카테고리 **in-process**(외부 의존 0,
순수 함수 leaf lib). seam은 컴파일타임 import이고 adapter는 콜사이트다:

```ts
// 형식 본문 SSOT — 형식 진화는 이 2줄만 수정(검증 RE와 인라인 문법에 동시 전파)
const TAG_BODY = String.raw`sha-[0-9a-f]{7,40}`;
const DIGEST_BODY = String.raw`sha256:[0-9a-f]{64}`;

export const TAG_RE = new RegExp(`^${TAG_BODY}$`);
export const DIGEST_RE = new RegExp(`^${DIGEST_BODY}$`);

export type InlinePin = { repo: string; tag: string; digest: string };
const INLINE_RE = new RegExp(`^(.+?):(${TAG_BODY})@(${DIGEST_BODY})$`);

// 형식 불량 = null (throw 금지 — poll은 refuse 사유, bump는 exit 2로 각자 처리)
export function parseInlinePin(scalar: string): InlinePin | null;
// parse의 역 — 왕복 항등: 정준 s에 대해 formatInlinePin(parseInlinePin(s)!) === s
export function formatInlinePin(pin: InlinePin): string;

export type PinDescriptor = { file: string; path: (string | number)[]; autoDeploy?: unknown };
// JSON.parse + 캐스트 — 정규화 0(throw 지점·필드 접근까지 콜사이트와 바이트 동일)
export function parseDescriptor(raw: string): PinDescriptor;
// autoDeploy fail-closed 정책 원자 — null-안전(C 접목): d?.autoDeploy === true
export function descriptorAutoDeploy(d: { autoDeploy?: unknown } | null | undefined): boolean;
```

**seam이 진짜인 이유(adapter ≥2)**: `parseInlinePin`/`formatInlinePin` —
poll(읽기 adapter) + bump(읽기·쓰기 adapter). `TAG_RE`/`DIGEST_RE` — 5개
검증지(create-app×2·bump×2·poll×1). `descriptorAutoDeploy` — 베스포크
descriptor + apps `.bindings.json` 두 레인이 같은 fail-closed 정책 공유.
`PinDescriptor`+`parseDescriptor` — poll·bump 두 소비자.

**커널 비소유(경계)**: 파일 I/O · YAML Document 변이(node.value/comment) ·
path-traversal 가드 · TOCTOU(expect-current) · no-op 판정 · stale-digest 제거 ·
ancestry/descendant 증명 · **모든 에러 문구·exit 코드·전송로**(콜사이트 잔존).

## Behavior Contract

리팩터 전 구간에서 다음 관측 행동은 바이트 단위로 불변이다. 특성화가 고정하고
모든 게이트가 이 표에 대해 판정한다.

| # | 표면 | 불변 행동 |
|---|---|---|
| B1 | poll-ghcr CLI | 플래그 계약(`--root/--fixtures/--dry-run/--owner`)·plan JSON 형태(action/reason/current/candidate/pin/writePath)·exit 0 |
| B2 | poll-ghcr refuse 사유 | `인라인 핀 형식 불량(repo:sha-*@sha256:*): <image>` · `핀 repo(<repo>)가 source-repo(<src>)와 불일치` · `배포 tag가 sha-* 형식이 아니라…` · `플랜 실패: <msg>`(JSON throw는 outer catch 경유 — parseDescriptor는 정규화 0이라 throw 지점 동일) |
| B3 | autoDeploy 해석 | `=== true`만 자동, false/누락/파싱 불가 = 전부 수동(fail-closed) — 두 레인 동일 |
| B4 | bump-tag 인자 검증 | bad app/tag/digest → 기존 stderr 문구 그대로 + exit 2 (`tag ?? ""` 관용구 유지) |
| B5 | bump-tag TOCTOU/no-op | `expect-current` 불일치 → 기존 문구 + exit 3 · tag+digest 쌍 일치 → no-op 로그 + exit 0 |
| B6 | bump-tag 파일 변이 | values.yaml(tag 갱신·digest 기록/stale 제거)·deployment.yaml(인라인 스칼라 `${repo}:${tag}@${digest}` + lineComment 갱신) — `doc.toString()` 산출 바이트 동일 |
| B7 | bump-tag 보안 가드 | apps/·platform/ 밖 쓰기 거부 문구 + exit 2 (콜사이트 잔존 — 커널 미접촉) |
| B8 | digest-exporter 동기 | 현행 무성-skip 의미론·로그 문구 그대로 (fail-loud화는 F-1로 명시 제외) |
| B9 | create-app 검증 | `tag 형식 불량: '<tag>'` · `digest 형식 불량(불변 핀 필수): '<digest>'` + exit — 문구·경로 불변 |
| B10 | 수용 집합 | TAG_RE/DIGEST_RE/INLINE_RE가 수용·거부하는 문자열 집합이 기존 리터럴과 동일(본문 문자열 동일 조립이므로 정의상 성립) |

성능 envelope: 해당 없음(순수 함수, 로컬 문자열 연산 — 측정 지표 없음이 Rule 0
전제).

## Characterization plan

**래더 rung (a) — 기존 상위 seam 테스트 재사용**: 계약 전 행이 이미 CLI
seam(stdout+exit+파일 산출물)에서 hermetic bats로 green 커버됨(seam 평가 실측):

- B1·B2·B3 → `tools/tests/test_poll-ghcr.bats` (15 tests — 형식 refuse·인라인
  핀 파싱·autoDeploy fail-closed·cross-repo·transient/404)
- B4·B5·B6·B7 → `tools/tests/test_bump.bats` (~20 앵커 — exit 0/2/3 전량·인라인
  왕복·stale-digest) + `tools/tests/test_bump-poll-toctou.bats`
- B8 → `tools/tests/test_digest-exporter-lib.bats` + test_bump.bats의 동기 케이스
- B9 → `tools/tests/test_create-app.bats`
- B10 → 위 스위트들의 수용/거부 케이스 집합(간접) + R-1의 lib 단위 테스트(직접)

**백필(plan-gate P-1 수용)**: 기존 5 스위트는 계약 행의 플로우를 덮지만 정확
문자열·바이트 단언이 부족 — `tools/tests/test_image-pin-charlock.bats`가
B2(정확 refuse 사유 4종)·B4(정확 stderr+exit 2)·B6(인라인 YAML 전체 바이트 +
lineComment·stale-digest 제거 문구)·B8(동기/skip 로그 정확 문구)·B9(불량
tag/digest 정확 문구)·B10(tag 7/40 hex 경계·digest 64 hex 경계·non-greedy repo)
을 리팩터 전 코드에서 born-green으로 고정한다.

**testCmd** (로컬·hermetic — 라이브 gh/docker/클러스터 0):

```bash
bats tools/tests/test_poll-ghcr.bats tools/tests/test_bump.bats \
     tools/tests/test_digest-exporter-lib.bats tools/tests/test_create-app.bats \
     tools/tests/test_bump-poll-toctou.bats tools/tests/test_image-pin-charlock.bats
```

특성화 절차: 리팩터 전 코드에서 위 testCmd green 확인 → 커밋 →
`characterization-lock.json` 기록(behavior-baseline = 그 sha). **기존 5개 스위트
+ charlock 백필 파일은 리팩터 전 구간 무수정**(수정·약화·스킵 = 구조/릴리스
게이트 Blocker, anti-cheat). 신규 테스트(lib 단위·grep-guard)는 증분에서
**추가만** 한다.

## Increment plan

| id | what moves | blocked-by | notes |
|---|---|---|---|
| R-1 | `tools/lib/image-pin.ts` 신설(위 표면 전체) + `tools/tests/test_image-pin-lib.bats`(형식 원자 수용/거부·parse/format 왕복 항등·descriptor 관용·autoDeploy fail-closed, @test 영어) + **poll-ghcr 채택**(planComponent: parseInlinePin·parseDescriptor·descriptorAutoDeploy / planApp: TAG_RE·bindings에 descriptorAutoDeploy) | none | **first-increment(seam-erecting)** — 구조 게이트 대상. refuse 문구·throw 경로 콜사이트 유지 |
| R-2 | **bump-tag 채택** — TAG_RE/DIGEST_RE(46·50), 인라인 모드 parseInlinePin + `formatInlinePin({ ...pin, tag, digest })` 스프레드 왕복(C 관용구), PinDescriptor 타입 | R-1 | TOCTOU·no-op·가드·comment 갱신·syncDigestExporter 무접촉. `doc.toString()` 바이트 동일 확인 |
| R-3 | **create-app 채택**(TAG_RE/DIGEST_RE) + 부기(tools/README.md lib 등재·AGENTS.md lib 개수 산문) + **안티드리프트 grep-guard**(@test 1개: poll-ghcr.ts·bump-tag.ts에 인라인 핀 정규식 리터럴 재출현 시 FAIL — test_ledger-budget.bats:64-68 선례) | R-2 | 전 증분 공통 규율: 한 변경 → lock testCmd green → 커밋 |

## Follow-up backlog

- **F-1** digest-exporter APPS-sync의 무성-skip을 "미감시 앱(정상 no-op)" vs
  "감시 중인데 포맷 드리프트(fail-loud)"로 구분 — **행위 변경**이라 본 리팩터
  제외, 별도 트랙(gated-pipeline 판정). 스켑틱이 stale APPS 참조 → 거짓
  ImageDigestDrift 재현 경로로 지목한 갭.
- **F-2** repin-pgtools:17의 digest 형식 정규식 — 배포 핀 개념 밖(ops 이미지)
  이라 수렴 제외. DIGEST_RE 재사용 여부는 별도 판단(개념 경계 vs 형식 SSOT).
- **F-3** bump-tag syncDigestExporter:15의 언앵커드 `sha-[0-9a-f]{7,40}` 잔존
  (R-2 Standards 리뷰 발견) — 커널이 TAG_BODY(언앵커드 본문)를 의도적으로 미노출한
  결과. 부분매치용 본문 export는 커널 인터페이스 확장이라 별도 판단.

## Review Decision Log

### Codex Plan Review — r1
| ID | Finding | Severity | Decision | Reason | Action |
|----|---------|----------|----------|--------|--------|
| P-1 | Behavior-lock coverage is materially overstated | critical | Accept | 5개 스위트가 B2 정확 refuse 문자열·B6 lineComment/바이트 출력·B9 불량 tag/digest 문구·B4/B8 정확 stderr/로그를 미고정 — refuse 메시지·YAML 출력이 바뀌어도 lock이 green일 수 있음(Codex가 스위트 직접 판독) | 신규 `tools/tests/test_image-pin-charlock.bats` 추가 전용 백필(기존 5 스위트는 무수정 동결 유지) → testCmd 포함 → characterization-lock.json 재기록(새 baselineSha·케이스 수) → r2 |

### Codex Plan Review — r2: clean — verdict approve, 0 findings. "P-1 materially addressed: charlock 17케이스 실재 + lock 85 green @124d1f9 확인. 추가 고위험 플랜 갭 없음." (엔진 노트: 각 green-commit 경계에서 lock 재실행으로 드리프트 즉시 검출)

### Codex Structure Review — r1: clean — verdict approve, 0 findings. "R-1 구조 건전: 좁힌 형식/descriptor 원자 집합의 seam이 실제로 집중됐고, 행위 보존 콜은 seam에서 무변경, 특성화 lock 계약은 추가 전용으로만 확장." (frontier 개방 — R-2/R-3 진행 가능)
