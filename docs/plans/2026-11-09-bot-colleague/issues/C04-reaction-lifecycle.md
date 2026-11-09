# C04 반응 수명

- 단계: 1 기반
- 상태: 진행 중 (ready-for-agent, 2026-11-09 착수)
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

- [ ] 받으면 👀, 다른 일 뒤에 기다리면 ⏳가 더해지고, 답이 게시되면 봇 반응이 모두 지워진다(AC-14).
- [ ] 실패가 확정되면 반응이 지워지고 실패 한 줄이 달린다(AC-14).
- [ ] 남의 반응을 지우는 호출이 0이다.
- [ ] 👍·💤를 더할 자리가 같은 훅에 있다(뒤 티켓이 상태만 더하면 된다).

## 검증

- 경계: S1(반응 REST 호출 순서, 가짜 Discord). 앞선 시험 예: `chat-ack`, `discord-rest-timeout`, `foundation`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험(`chat-ack`, `discord-rest-timeout`, 새 반응 시험). 전체 `npm test`는 통합 담당.
- 잡는 실패 / 못 잡는 범위: 잡는 것은 반응이 남거나 잘못 지워지는 것, 남의 반응 삭제, 403/404 대체 규칙 회귀다. 못 잡는 범위: Discord 반응 rate limit의 실제 영향(S5, C24), 👍(C11)·💤(C20)의 실제 사용.

## 결과

(구현 뒤 채운다)
