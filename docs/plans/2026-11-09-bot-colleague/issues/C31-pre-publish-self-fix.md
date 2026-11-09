# C31 게시 전 자체 리뷰 고치기

- 단계: 6 PR 수정
- 상태: 대기 (선행: C06, C17, C25)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.10, §5 AC-31 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C06, C17, C25
- 연결 AC: AC-31
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 연결 파일, 소유 C07: 봇 `src/change-runtime.ts`(`reviewing`에서 자체 리뷰가 `blocked`일 때 바로 닫던 분기를 고치기 차례로 잇는 자리)
  - 연결 파일, 소유 C17: 봇 `src/change-store.ts`(같은 generation 안에서 `reviewing` → `authoring`으로 돌아가는 전이와 차례 수)
  - 연결 파일, 소유 C25: 봇 `src/change-contracts.ts`(전이 표·차례 칸. C25가 만든 수정 차례 입력을 쓴다)
  - 연결 파일, 이 티켓이 소유하고 C27이 뒤에 고친다: 봇 `src/change-review.ts`(차례 키로 receipt를 저장·조회하는 자리)
  - 연결 파일, 소유 C09: 봇 `src/claude-task-bridge.ts`(작성 실행에 자체 리뷰 발견을 자료 블록으로 넘기는 자리)
  - 봇 `migrations/`(순번 공유)
  - 시험: `test/change-store.test.ts`·`test/change-store-pg.test.ts`, `test/change-assembly.test.ts`, `test/change-review.test.ts`와 새 고치기 차례 시험
  - 봇 `docs/ai-bot/VERIFICATION.md`·`DECISIONS.md`·`ARCHITECTURE.md`는 추가만
- 설계 계약:
  - `src/change-runtime.ts`, `src/change-store.ts`, `src/change-contracts.ts`: 봇 ARCHITECTURE "16. T19 CHANGE_PR 계약"의 흐름·전이 표·끝 상태와 재시작 문단, "16.2 미게시 후보 리뷰 (B2)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 17 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - `src/change-review.ts`: ARCHITECTURE "16.2 미게시 후보 리뷰 (B2)"의 receipt·판정 규칙.
  - `src/claude-task-bridge.ts`: ARCHITECTURE §12 "T18 작업 레인 계약", "16.4 작업 레인 v2: artifact와 무자격 검증 (B1)".

## 목표

봇이 변경을 다 만든 뒤 자체 리뷰에서 P0·P1 문제가 나오면, 지금처럼 바로 막지 않고 게시 전에 스스로 고쳐서 다시 시험·리뷰한다. 동료가 리뷰를 부탁하기 전에 자기가 본 문제를 먼저 고치는 것과 같다. 고치기는 최대 2번(기본값)이고, 그래도 P0·P1이 남으면 지금처럼 `review_blocked`로 닫고 Discord에 이유를 알린다. P2·P3는 고치지 않고 남은 위험으로 넘겨 C29 안내 댓글이 다룬다.

변경 기능(`CHANGE_PR_ENABLED`) 안의 흐름이라 그 스위치가 꺼져 있으면 동작이 없다. 동료 기능 스위치와는 별개다.

## 할 일

1. 지금 흐름을 확인한다: `reviewing`에서 자체 리뷰가 `blocked`이면 바로 닫고, 같은 generation에서 리뷰를 다시 돌리는 길이 없다(코드 읽기, 2026-11-09 티켓 작성 때 관측. 구현 전에 다시 본다).
2. 같은 generation 안의 고치기 차례를 더한다: `reviewing`(P0·P1 있음) → 고치기 차례 → `authoring` → `snapshot_ready` → `verifying` → `reviewing`. 차례 수를 저장하고 2번을 넘으면 지금처럼 닫는다. 브랜치·base는 바뀌지 않는다(아직 게시 전).
3. 고치기 작성 실행은 C25의 수정 차례 입력을 쓴다: 지시는 "자체 리뷰의 P0·P1을 고친다", 자료 블록은 그 리뷰의 발견(제목·조건·근거·위치)이다. 자료는 지시가 아니다.
4. 차례마다 증거(스냅숏, 시험, 자체 리뷰)를 새로 만들고 승인 digest는 마지막 차례 기준으로만 만든다. 이전 차례의 증거로 승인되지 않게 한다.
5. 고치기 중 진행이 불가능하면 지금의 변경 질문 경로(작업 질문, `ChangeAnswerGuard`)를 그대로 쓴다. C28이 병합된 뒤에는 그 경로에 선택지 버튼이 붙는다. 이 티켓은 질문 경로를 새로 만들지 않으므로 C28을 기다리지 않는다.
6. Discord 안내: 고치기 차례 시작은 알리지 않는다(진행 중 표시는 기존 입력 중 표시). 2번 뒤에도 남아 닫히면 동료 말투로 남은 문제 요지와 함께 알린다(원문 대신 제목 수준, 공개 검사).
7. 시험: P0 하나 → 고치기 1번 → 통과해 미리보기, P0가 계속 남음 → 2번 뒤 `review_blocked`, P2만 → 고치기 없이 미리보기(남은 위험), 차례 중 취소, 차례 중 base 이동(기존 신선도 규칙), PostgreSQL 두 연결에서 차례 전이 경합.
8. 기록: 봇 `docs/ai-bot/ARCHITECTURE.md` §16 전이 표에 고치기 차례, `docs/ai-bot/DECISIONS.md`에 구현 선택(상한 2번은 기본값), `docs/ai-bot/VERIFICATION.md`에 "C31 게시 전 자체 리뷰 고치기" 절, 이 계획 폴더 `README.md`의 C31 상태 줄 갱신.

## 완료 조건

- [ ] 자체 리뷰가 P0·P1을 내면 게시 전에 최대 2번 스스로 고치고, 고친 뒤 시험·리뷰를 새로 돈다.
- [ ] 2번 뒤에도 P0·P1이 남으면 지금처럼 `review_blocked`로 닫히고 Discord에 이유가 간다.
- [ ] P2·P3만 남으면 고치기 없이 미리보기로 가고, 남은 위험으로 넘어간다.
- [ ] 승인 digest는 마지막 차례 증거로만 만들어진다.

## 검증

- 경계: S1(변경 상태 전이와 런타임, PostgreSQL 두 연결 포함), S2(작성 입력의 자료 블록). 앞선 시험 예: `change-store`, `change-store-pg`, `change-assembly`, `change-review`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험. 전체 `npm test`는 통합 담당.
- 잡는 실패 / 못 잡는 범위: 잡는 것은 상한 무시, 이전 차례 증거로의 승인, 고치기 없이 닫힘, P2·P3까지 고치려는 것이다. 못 잡는 범위: 모델이 실제로 문제를 고치는 품질(S5, C24).

## 결과

(구현 뒤 채운다)
