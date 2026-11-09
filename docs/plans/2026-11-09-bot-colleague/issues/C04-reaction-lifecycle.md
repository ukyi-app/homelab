# C04 반응 수명

- 단계: 1 기반
- 상태: integrated (봇 #114 병합 `ca243f5`, 2026-11-10)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.5, §5 AC-14, §8 "반응 rate limit" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: 없음
- 연결 AC: AC-14(👀·⏳·지우기·실패)
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유: 소유(연결 파일, 뒤 티켓 C07·C08·C13·C15·C16·C17·C20이 자기 분기만 고친다) `src/discord.ts`(`DiscordRest`에 반응 지우기·더하기, `DiscordPublisher` 게시 확정 뒤 반응 정리 훅 호출), `src/discord-protocol.ts`(`DiscordApi`에 `DELETE`, 봇 자신의 반응 지우기 REST, ⏳ 더하기, 403/404 대체 규칙). 새 반응 상태 모듈(예: `src/reactions.ts`, 이름은 구현 때 정함)을 소유한다: 👀·⏳·지우기와 뒤의 👍(C11)·💤(C20)가 같은 자리에서 바뀌는 훅. 소유(연결 파일, 뒤에 C07·C08·C09·C13·C16·C19·C20이 자기 자리만 고친다): `src/store.ts`(⏳를 판단할 모델 자리 점유 `claim`, 확정 실패 `fail`의 실패 안내 게시. README 5절 표의 소유도 C04), `src/runtime.ts`(대화 실행·완료·실패 흐름의 반응 훅 자리만. README 5절 표의 소유는 뒤의 C11). 시험 `test/chat-ack.test.ts`·`test/discord-rest-timeout.test.ts`와 새 반응 순서 시험. 봇 `VERIFICATION.md`·`DECISIONS.md`·`ARCHITECTURE.md`는 추가만.
- 설계 계약:
  - `src/discord.ts`, `src/discord-protocol.ts`, 새 반응 모듈: ARCHITECTURE §13 "수신·진행 신호"(👀, 403/404 텍스트 대체 한 번, 429는 대체 없음, ACK 오류가 `receive()` 밖으로 나가지 않음), §11 "저장·권한·게시"(outbox 게시 확정), §6 "보안 경계"의 "Discord 입력" 문단 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 5, D-17 "설정" 표의 "봇 권한" 행(관리 권한 없음, `ADD_REACTIONS`만) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - `src/store.ts`, `src/runtime.ts`(표 밖 공유): ARCHITECTURE §11 "호출 경로·직렬 대기·측정"(모델 자리 하나와 직렬 대기), §13 "상태 안내 (멘션 없음)".

## 목표

owner가 보낸 메시지에 봇이 받으면 👀, 다른 모델 일이 자리를 쓰고 있어 기다리면 ⏳를 더하고, 답이 게시되면 봇이 단 반응을 모두 지운다. 실패가 확정되면 반응을 지우고 실패 한 줄을 단다. 지우기는 봇 자신의 반응만이다. 뒤 티켓이 👍(C11)·💤(C20)를 같은 훅으로 쓴다. 스위치 밖 기능이라 병합하면 바로 운영에 나간다.

## 할 일

1. REST: `src/discord-protocol.ts`의 `DiscordApi`에 `DELETE`를 더하고, 봇 자신의 반응 지우기(메시지·emoji의 `@me`)와 반응 더하기를 `DiscordRest`(`src/discord.ts`)에 둔다. 남의 반응을 지우는 경로는 만들지 않는다. Gateway dispatch 안에서 부르면 지금처럼 짧은 제한(1초)을 쓴다.
2. 반응 상태 훅: 메시지 하나의 반응 상태(받음, 대기, 지움, 실패, 그리고 뒤에 올 👍·💤)를 한곳에서 바꾸는 모듈을 만든다. 상태를 바꿀 때 지금 붙어 있는 봇 반응을 알고 필요한 것만 더하고 지운다. 뒤 티켓은 상태 이름만 더한다.
3. ⏳: 받은 메시지의 대화 작업이 다른 모델 일이 자리를 쓰고 있어 바로 집히지 못하면 ⏳를 더한다. 판단 자리는 모델 자리 점유(`src/store.ts` `claim`과 `src/runtime.ts` `tick`)다. 대기 판단이 결정적이도록 상태와 시각을 저장소에서 읽는다.
4. 답 게시 확정: 대화 답(페이지가 여럿이면 마지막 페이지)이 `sent`로 확정되면 그 owner 메시지의 봇 반응을 모두 지운다(✅ 없음). `unknown`인 동안은 지우지 않는다.
5. 실패 확정: 대화 작업이 `failed`로 확정되면 반응을 지우고 실패 한 줄을 남긴다. 실패 한 줄은 지금 실패 안내 게시(`src/store.ts` `fail`)를 쓴다. 문구를 동료 말투로 다시 쓰는 것은 C09이고, 실패 안내가 없는 확정 실패 경로가 있으면 고정 문구 하나를 이 티켓에서 더한다(문구 상수는 C09가 다듬는다).
6. 실패 처리: 반응 REST가 403/404면 지금 규칙(텍스트 대체 한 번, 감사 `ack_reaction_fallback`)은 👀에만 쓰고, 지우기·⏳의 403/404는 감사만 남기고 대체 글을 달지 않는다. 429는 rate limit만 기록한다. 반응 오류가 게시·작업 상태를 바꾸지 않는다.
7. 재시작: 게시 서버가 재시작돼도 답한 메시지에 👀·⏳가 남지 않도록, 반응 변경이 저장된 상태에서 다시 시도되는지(또는 잃어도 되는 표시로 둘지) 정하고 `ARCHITECTURE.md`에 적는다.
8. 시험(가짜 Discord REST): 받음 → 답 게시 → 지움의 호출 순서, 대기 → ⏳ 더함 → 답 → 모두 지움, 실패 확정 → 지움 + 실패 한 줄, 지우기는 `@me`만(남의 반응 경로 호출 0), 403/404·429 처리, `unknown` 게시 동안 지우지 않음.
9. 기록: 봇 `ARCHITECTURE.md` §13 "수신·진행 신호"에 반응 수명 문단, `VERIFICATION.md`에 "C04 반응 수명" 절, `DECISIONS.md` "동료 봇 전환" 5에 구현 위치 한 줄. 이 계획 폴더 `README.md`의 C04 상태 줄 갱신.

## 완료 조건

- [x] 받으면 👀, 다른 일 뒤에 기다리면 ⏳가 더해지고, 답이 게시되면 봇 반응이 모두 지워진다(AC-14).
- [x] 실패가 확정되면 반응이 지워지고 실패 한 줄이 달린다(AC-14).
- [x] 남의 반응을 지우는 호출이 0이다.
- [x] 👍·💤를 더할 자리가 같은 훅에 있다(뒤 티켓이 상태만 더하면 된다).

## 검증

- 경계: S1(반응 REST 호출 순서, 가짜 Discord). 앞선 시험 예: `chat-ack`, `discord-rest-timeout`, `foundation`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험(`chat-ack`, `discord-rest-timeout`, 새 반응 시험). 전체 `npm test`는 통합 담당.
- 잡는 실패 / 못 잡는 범위: 잡는 것은 반응이 남거나 잘못 지워지는 것, 남의 반응 삭제, 403/404 대체 규칙 회귀다. 못 잡는 범위: Discord 반응 rate limit의 실제 영향(S5, C24), 👍(C11)·💤(C20)의 실제 사용.

## 결과

- 봇 PR #114(`feat/colleague-c04-reactions`, 결과 head `267ece6`), 병합 `ca243f5`(2026-11-10). 스위치 밖이라 병합과 함께 운영 배포. 첫 작업자는 2026-11-09 22:48 커널 크래시로 끊겼고, 이어받은 작업자가 코드 추가 없이 완료 검사를 했다. Codex 리뷰 세 차례: 1차 P1 1·P2 3, 2차 P2 3을 새 작업자 둘이 고쳤고(각 지적을 빨강→초록 시험으로), 3차 P2 1(실행 중 `/stop` 뒤 `superseded` 종료의 반응 정리)은 PR 리뷰 규칙대로 C11 할 일 8a로 넘겼다.
- 구현: `src/reactions.ts`(상태 표 `REACTIONS`·`FROM`, `recordReceived`·`moveReactions`·`settleReactions`·`ReactionSync`, 행은 `controls`의 `reaction:<event id>`, 끝 상태까지 맞추면 행 삭제, 결과 불확실한 더하기는 `maybe`로 기록해 지움 대상, 행마다 lease 표 재확인). `src/discord-protocol.ts`·`src/discord.ts` 봇 자신의 반응 더하기·지우기(`@me`만), 게시 루프는 반응 동기화를 최대 1초만 기다림. `src/store.ts` `claim`·`refreshWaiting`의 ⏳ 판단, `fail`·`resolveUnknown`·`cancelledNotice`의 정리, 복구 버퍼 폐기 경로의 정리. `src/runtime.ts`는 고치지 않았다.
- 완료 조건 근거: `test/reaction-lifecycle.test.ts`(1차 17개 + 리뷰 수정 6개): `흐름: 받음 👀 → 답 게시 → 봇 반응 모두 지움(✅ 없음)`, `흐름: 다른 모델 일 뒤에 기다리면 ⏳를 더하고…`(운영과 같은 순차 tick), `흐름: 실패가 확정되면 반응을 지우고 실패 한 줄을 단다`, `protocol 흐름: 반응 REST는 모두 @me이고 남의 반응을 지우는 호출은 0이다`. 👍(C11)·💤(C20)는 `REACTIONS`·`FROM`에 상태만 더하면 된다.
- 검사: 통합 담당 전체 검사(`267ece6`, node 24.22.0, 실제 PG, 잠금): 2211 tests / 2189 pass / 0 fail / 22 skip(SEC02_IMAGE). 앞 head `ad88503` 전체 검사의 1 fail(`R08 실제 PostgreSQL: 같은 event_id를 동시에…`, 외부 작업 수신)은 단독 2회 12/12 통과라 부하 흔들림으로 기록. `build / test` 통과.
- 분해 불일치: 반응 상태는 전용 표가 아니라 `controls` 행(마이그레이션 없음). `runtime.ts` 반응 훅 자리 불필요. 실패 고정 문구 추가 불필요(실패 안내 없는 확정 실패 경로 없음). `test/helpers.ts`의 `MockDiscord`에 반응 메서드 둘을 더했다(컴파일에 필요).
- 남은 위험: 작업 루프를 끈 배치에서 task가 대화를 막는 경우는 `claim` 때만 ⏳. 반응 REST가 30초를 넘기면 그 행을 다른 서버가 가져갈 수 있다(기록은 덮지 않음). 답할 때마다 반응 지우기 호출이 늘어 실제 rate limit 영향은 C24(S5).
