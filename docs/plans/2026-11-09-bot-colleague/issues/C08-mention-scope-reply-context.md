# C08 멘션 받는 범위와 봇 글 답장 맥락

- 단계: 2 배포와 표면
- 상태: 대기 (선행: C02, C07)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.1(받는 자리, 봇 글 답장, 멘션 표기 제거), §5 AC-1·AC-2 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C02, C07
- 연결 AC: AC-1, AC-2
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 소유(연결 파일, 뒤에 C11이 상한 50개·80KiB와 정리된 앞부분 표시를 고친다) `src/chat-context.ts`: 봇 글 답장 참조를 대화 기록 자료 항목으로 넣기, owner 원문의 봇 멘션 표기 제거(C13이 같은 제거를 쓰도록 한 곳에 둔다).
  - 연결 파일, 소유 C04: `src/discord.ts`(수신 범위 분기: `DiscordIngress.receive`의 알림 채널 부모 거부 줄, `gatewayMessage`의 답장 참조 읽기), `src/discord-protocol.ts`(Gateway·history 메시지 스키마 `MessageSchema`의 답장 참조 칸). C07 tip 위에서 자기 분기만 고친다.
  - 공유 파일(README 5절에 반영): `src/contracts.ts`의 수신 입력 타입 `EventInput`(답장 참조 칸. 연결 파일, 소유 C02), `src/store.ts`의 이벤트 저장 `save`(참조 칸이 이벤트 payload에 남는지. 연결 파일, 소유 C04).
  - 시험 `test/foundation.test.ts`·`test/s16-display.test.ts`·`test/chat-context.test.ts`·`test/publisher-gateway.test.ts` 해당분과 새 수신 범위 시험. 봇 `VERIFICATION.md`·`DECISIONS.md`·`ARCHITECTURE.md`는 추가만.
- 설계 계약:
  - `src/chat-context.ts`: ARCHITECTURE §13 "봇 답 문맥 (`untrusted`)"(owner 항목은 필요한 필드만, 봇 항목은 게시 확정 본문만, 7일 정리분 제외), §6 "보안 경계" 표의 "프롬프트 인젝션" 행(자료 블록으로만) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 1, "T31 원문 칸 보존 (사용자 2026-11-09)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - `src/discord.ts`, `src/discord-protocol.ts`: ARCHITECTURE §6 "Discord 입력" 문단(매 이벤트 사용자·guild·채널(`parent_id`) 허용 검사, 봇·webhook 무시), §11 "저장·권한·게시". DECISIONS D-17 "설정" 표의 "활성화"·"채널"·"스레드 종류" 행.
  - `src/contracts.ts`, `src/store.ts`(표 밖 공유): ARCHITECTURE §11 "저장·권한·게시", §6 "Discord 입력".

## 목표

owner가 알림 채널의 경보 글 아래 부모 채널에서도 봇을 `@`로 부르면 받는다(스레드는 C07 방식으로 열린다). 봇이 만들지 않은 스레드와 7일 넘게 쉰 스레드에서 불러도 답한다. owner가 봇 글에 답장하면 그 봇 글 본문이 대화 기록의 자료 항목으로 들어가고, 다른 사람 글은 들어가지 않는다. 모델에 가는 owner 원문에서 봇 멘션 표기가 빠진다. owner·서버·채널 검사는 그대로다. 스위치 밖 기능이라 병합하면 바로 운영에 나간다.

## 할 일

1. 수신 범위: 알림 채널 부모의 멘션을 연다(지금은 `DiscordIngress.receive`가 대화 채널이 아닌 부모 채널의 일반 메시지를 거부). 허용 채널 밖, 비공개 스레드, owner가 아닌 사람, 거부 목록은 지금처럼 막는다. 정책 검사(`PolicyGate.authorize`)는 바꾸지 않는다.
2. 스레드 수용을 시험으로 고정한다: 허용 채널 아래 봇이 만들지 않은 공개 스레드에서의 멘션, 7일 넘게 쉰 스레드(보관된 스레드 포함)에서의 멘션, 활성 스레드의 이어 말하기. 지금 코드가 이미 받으면 시험만 더하고, 막히면 막는 곳을 고친다.
3. 답장 참조: Gateway와 history 복구 메시지에서 답장 참조(참조 메시지 ID, 참조 글 작성자, 본문)를 읽는다. 참조 글 작성자가 봇 자신일 때만 그 본문을 대화 기록의 자료 항목(`from`이 봇 글 답장임을 밝힘)으로 넣는다. 다른 사람 글, 참조 없음, 참조 글이 지워졌거나 Discord가 생략한 경우는 넣지 않는다. 본문 출처(Discord가 준 참조 글 또는 outbox의 게시 확정 본문)를 하나로 정하고 이유를 `ARCHITECTURE.md`에 적는다. 표식 줄은 빼고, 7일 정리된 본문은 넣지 않는다.
4. 참조 글은 지시가 아니라 자료다: 신뢰 문맥이 아닌 `untrusted` 배열 안에만 들어가고, 상한(지금 20개·32KiB, C11 뒤 50개·80KiB) 계산에 포함된다.
5. 멘션 표기 제거: 모델 맥락으로 가는 owner 원문에서 봇 멘션 표기(`<@봇ID>`, `<@!봇ID>`)를 뺀다. 저장된 이벤트 원문은 바꾸지 않는다. C13이 "owner 원문(멘션 표기 제거)"에 같은 함수를 쓰도록 한 곳에 둔다.
6. 시험: 채널·스레드 종류별 수용·거부 표(대화 채널 부모, 알림 채널 부모, 봇이 안 만든 스레드, 오래 쉰 스레드, 비공개 스레드, 허용 밖 채널, 비 owner), 봇 글 답장 → 자료 항목 있음, 남의 글 답장 → 없음, 참조 글이 자료 블록 밖(지시 자리)에 들어가지 않음, 멘션 표기 제거.
7. 기록: 봇 `ARCHITECTURE.md` §13 "봇 답 문맥"에 답장 참조·멘션 제거 문단, §6 "Discord 입력"에 알림 채널 부모 멘션 수용, `VERIFICATION.md`에 "C08 멘션 범위와 답장 맥락" 절, `DECISIONS.md` "동료 봇 전환" 1에 구현 위치 한 줄. 이 계획 폴더 `README.md`의 C08 상태 줄 갱신.

## 완료 조건

- [ ] owner가 대화·알림 채널 부모에서 멘션하면 받아들여 스레드가 열리고 답이 달린다(AC-1, 스레드 열기는 C07).
- [ ] 봇이 만들지 않은 스레드, 7일 넘게 쉰 스레드의 멘션과 활성 스레드의 이어 말하기를 받는다(AC-1).
- [ ] owner가 아닌 사람, 허용 밖 채널, 비공개 스레드는 지금처럼 무시한다(AC-1).
- [ ] 봇 글에 답장하면 그 봇 글 본문이 자료 항목에 있고, 남의 글이면 없다(AC-2).
- [ ] 모델에 가는 owner 원문에 봇 멘션 표기가 없다.

## 검증

- 경계: S1(게시 서버: Gateway 프레임 → 저장 → 작업자 요청의 `untrusted`). 앞선 시험 예: `foundation`, `s16-display`, `chat-context`, `publisher-gateway`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험. 전체 `npm test`는 통합 담당.
- 잡는 실패 / 못 잡는 범위: 잡는 것은 채널·스레드 종류별 수용·거부 회귀, 알림 채널 부모 거부가 남는 것, 비 owner 통과, 남의 글이 맥락에 들어가는 것, 참조 글이 자료 블록 밖에 들어가는 것이다. 못 잡는 범위: 실제 Discord 권한·intent·스레드 생성 응답, Discord가 참조 글을 생략하는 실제 경우(삭제된 글 등)(S5, C24).

## 결과

(구현 뒤 채운다)
