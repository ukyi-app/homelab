# C07 답장·owner 호출·스레드 제목·작은 표식

- 단계: 2 배포와 표면
- 상태: 진행 중 (ready-for-agent, 2026-11-10 착수. 선행 C04·C09 integrated)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.4(대조 표식, 스레드 제목, 답장과 owner 호출), §5 AC-12 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C04, C09
- 연결 AC: AC-12
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 연결 파일, 소유 C04: `src/discord.ts`(게시 분기: `DiscordPublisher.deliver`의 답장·owner 호출·멘션 허용, 대화 멘션의 스레드 열기 enqueue와 `confirm`, `markedContent`·`hasMarker` 표식), `src/discord-protocol.ts`(`DiscordRest` 구현: 메시지에서 스레드 열기, `findDelivery`의 새·옛 표식과 메시지 스레드 대조). C04 tip 위에서 자기 분기만 고친다.
  - 공유 파일(README 5절에 반영): `src/store.ts`의 outbox 페이로드 타입 `Delivery.payload`(답장 대상·owner 호출·스레드 방식 칸)와 대화 답·실패 enqueue(연결 파일, 소유 C04), owner 호출 글을 만드는 곳 `src/task-bridge.ts`(작업 질문)·`src/claude-task-bridge.ts`·`src/codex.ts`(작업 질문·완료·실패. 연결 파일, 소유 C09), `src/change-runtime.ts`(변경 미리보기·변경 실패. 연결 파일, 이 티켓이 소유하고 C17·C18이 뒤에 고친다). 이 티켓은 이 파일들에 owner 호출 표시를 넘기는 자리만 고치고 문구는 바꾸지 않는다. 경보 스레드(`src/alerts.ts`)는 지금 방식(표식 이름의 독립 스레드)을 유지한다.
  - 시험 `test/s16-display.test.ts`·`test/foundation.test.ts`·`test/chat-ack.test.ts`·`test/publisher-recovery.test.ts`·`test/task-bridge.test.ts`·`test/change-assembly.test.ts` 해당분과 새 게시·대조 시험. 봇 `VERIFICATION.md`·`DECISIONS.md`·`ARCHITECTURE.md`는 추가만.
- 설계 계약:
  - `src/discord.ts`, `src/discord-protocol.ts`: ARCHITECTURE §11 "저장·권한·게시"(outbox, 응답 유실 뒤 대조, 재게시 금지), §6 "보안 경계"의 "Discord 입력" 문단(모든 봇 메시지 `allowed_mentions: {"parse": []}`. 이 티켓이 owner 호출 넷의 예외로 고친다), §13 "상태 안내 (멘션 없음)"("owner를 부르는 개입 알림은 아직 넣지 않았다") (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). DECISIONS D-17 "설정" 표의 "멘션 기본값"·"스레드 종류"·"`auto_archive_duration`" 행, "동료 봇 전환 (사용자 2026-11-09)" 4·11 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - `src/store.ts`(표 밖 공유): ARCHITECTURE §11 "저장·권한·게시".
  - 작업 브리지(`src/task-bridge.ts`, `src/claude-task-bridge.ts`, `src/codex.ts`): ARCHITECTURE §12 "T18 게시 서버 스케줄링과 질문", "질문 계약 (TASK-02, AUTH-02)".
  - `src/change-runtime.ts`: ARCHITECTURE §16.5 "조립과 꺼짐 배포 (B5)", §16.3 "T19 B3 writer·공개 경계".

## 목표

봇 답이 owner 메시지에 대한 답장으로 달리되 알림은 울리지 않는다. owner 손이 필요한 넷(작업 질문, 작업 완료·실패, 변경 미리보기, 변경 실패)만 owner를 부르고 나머지는 지금처럼 멘션을 막는다. 메시지 끝 대조 표식은 Discord 작은 글씨 줄이 되고, 대조는 새·옛 모양을 둘 다 찾아 재게시하지 않는다. owner가 채널에서 멘션으로 대화를 시작하면 그 메시지에서 스레드가 열리고 제목은 owner 메시지 앞부분이다. 스위치 밖 기능이라 병합하면 바로 운영에 나간다.

## 할 일

1. 답장: 대화 답(첫 페이지)을 그 owner 메시지에 대한 답장으로 단다. 답장 대상 메시지가 지워졌으면 답장 없이 게시한다(답장 참조 실패로 게시가 막히지 않게). 답장 알림은 울리지 않는다(답장 사용자 멘션 끔).
2. owner 호출: outbox 페이로드에 owner 호출 표시를 둔다. 그 표시가 있는 글만 owner 한 사람의 사용자 멘션을 허용하고, everyone·역할·다른 사용자는 늘 막는다. 표시를 넘기는 곳은 작업 질문, 작업 완료·실패, 변경 미리보기(게시 승인 요청), 변경 실패 넷뿐이다. 문구는 바꾸지 않는다(C09·C17·C18 몫).
3. 대조 표식: 메시지 끝 표식을 Discord 작은 글씨 줄로 바꾼다. 재게시 방지 대조(`hasMarker`, `findDelivery`)는 새 모양과 옛 모양(`[ref:<marker>]`)을 둘 다 찾는다. JSON 본문 표식(목록·제어 결과) 규칙은 그대로 둔다. 1900자 게시 상한 안에서 표식이 들어가는지 확인한다.
4. 스레드 열기: 채널 부모의 멘션 대화는 owner 메시지에서 스레드를 연다. 제목은 owner 메시지 앞부분(멘션·마크업 제거, 최대 40자, 비면 고정 문구). '/' 경로와 경보 스레드는 지금 방식(표식 이름)이다.
5. 스레드 중복 대조: 응답 유실 뒤에는 그 메시지에 이미 스레드가 있는지로 대조한다. "메시지에서 연 스레드의 ID는 그 메시지 ID와 같다"를 구현 때 Discord 문서로 다시 확인하고 출처와 확인 날짜를 `ARCHITECTURE.md`에 적는다. 이미 있으면 그 스레드를 확정하고 새로 만들지 않는다.
6. 계약 문서: 봇 `ARCHITECTURE.md` §6 "Discord 입력"의 멘션 규칙을 "기본 `parse: []`, owner 호출 넷만 owner 사용자 ID 하나 허용"으로 고치고, §13 "상태 안내"의 "owner를 부르는 개입 알림은 아직 넣지 않았다"를 갱신한다.
7. 시험(가짜 Discord REST): 대화 답이 답장이고 답장 멘션 꺼짐, owner 호출 넷만 owner 멘션 허용(다른 글은 `parse: []`), 새 표식 모양, 응답 유실 뒤 새·옛 표식 모두 찾아 재게시 0, 멘션 대화가 메시지에서 스레드를 열고 제목 40자·멘션 제거, 같은 메시지로 스레드 두 번 생성 0, '/' 경로·경보 스레드 그대로.
8. 기록: 봇 `ARCHITECTURE.md` §11 "저장·권한·게시"에 표식·답장·스레드 문단, `VERIFICATION.md`에 "C07 답장·owner 호출·스레드·표식" 절, `DECISIONS.md` D-17 "멘션 기본값" 행 옆에 동료 봇 전환 4·11로 바뀐 점 한 줄. 이 계획 폴더 `README.md`의 C07 상태 줄 갱신.

## 완료 조건

- [ ] 봇 글의 대조 표식이 작은 글씨 줄이고, 응답 유실 뒤 대조가 새·옛 표식을 모두 찾아 재게시하지 않는다(AC-12).
- [ ] 멘션으로 연 스레드의 제목이 owner 메시지 앞부분이고, 같은 메시지로 스레드를 두 번 만들지 않는다(AC-12).
- [ ] 봇 답이 owner 메시지에 대한 답장이고 알림이 울리지 않는다(AC-12).
- [ ] owner 호출 목록 넷의 글만 owner를 부른다(AC-12).

## 검증

- 경계: S1(게시·대조, 가짜 Discord REST). 앞선 시험 예: `s16-display`, `foundation`, `chat-ack`, `discord-rest-timeout`, `task-bridge`, `change-assembly`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험. 전체 `npm test`는 통합 담당.
- 잡는 실패 / 못 잡는 범위: 잡는 것은 중복 게시, 중복 스레드, 의도치 않은 알림, 호출 누락이다. 못 잡는 범위: Discord의 실제 알림 동작과 작은 글씨 표시, 메시지 스레드 ID 규칙의 실제 응답(S5, C24).

## 결과

(구현 뒤 채운다)
