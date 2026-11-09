# C16 작업 질문 바로 답

- 단계: 4 말로 실행
- 상태: 대기 (선행: C09, C13)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.3 "작업 질문 바로 답", §4.9 스위치와 배포 순서, §4.10 "변경 질문 줄이기"(CHANGE 질문은 C28) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C09, C13
- 연결 AC: AC-8
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 연결 파일, 소유 C04: 봇 `src/discord.ts`(수신 분기: 스위치 켜짐이고 그 스레드에 열린 작업 질문이 있으면 owner의 일반 메시지를 대화 작업 대신 기존 답 경로 `answerIn`으로 보내는 자리, 저장 전 봉인 판단), `src/discord-protocol.ts`(custom_id 표에 "질문 고르기" 줄)
  - 연결 파일, 소유 C09: 봇 `src/task-bridge.ts`(열린 질문 조회, 질문 글의 켜짐 판에서 질문 ID 옮겨 적기 안내 빼기), `src/claude-task-bridge.ts`·`src/codex.ts`(질문 머리말이 판에 따라 달라지면 그 줄만), `src/store.ts`(질문 고르기 글의 outbox 게시. 이 파일은 소유 C04)
  - 연결 파일, 소유 C13: 봇 제안 모듈(작업 질문 종류 줄, 질문 고르기 버튼의 검사를 같은 방식으로 쓸 때)
  - 쓰기만 함: 봇 `src/change-commands.ts`의 `sealsAnswer`(CHANGE 질문을 가려 바로 답 대상에서 빼는 데 씀)
  - 시험: `test/task-bridge.test.ts`, `test/task-assembly.test.ts`, `test/codex-bridge.test.ts`, `test/change-assembly.test.ts`(CHANGE 질문이 바로 답에서 빠짐), `test/raw-input-retention.test.ts`(답 원문 7일)의 해당 경로와 새 바로 답 시험
- 설계 계약:
  - `src/task-bridge.ts`, `src/claude-task-bridge.ts`, `src/codex.ts`: 봇 ARCHITECTURE §12 "질문 계약 (TASK-02, AUTH-02)"(응답자는 작업 owner 하나, 기한 1시간, 다른 대화·다른 사람 답 거부, 같은 이벤트 재전달 한 번만, 기한 지난 질문 거부, 답은 승인·권한 변경이 아님), §12 "T18 게시 서버 스케줄링과 질문" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md)
  - `src/discord.ts` 수신 분기와 봉인: 봇 ARCHITECTURE §16.5 "조립과 꺼짐 배포 (B5)"의 CHANGE 질문 답(`label=public | <답>` 서식, 원문을 `events`에 두지 않고 저장 전 `sealsAnswer`로 봉인), §12 "T18 작업 레인 조립"의 `/answer` 줄(수신 트랜잭션 안 `answerIn`), §11 "저장·권한·게시"
  - 답 원문 보존: 봇 DECISIONS "T27 사람 입력 원문 보존 (사용자 2026-11-07)", "T31 원문 칸 보존 (사용자 2026-11-09)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md)
  - `src/discord-protocol.ts`: C13이 더하는 제안·실행 확인 계약 절의 custom_id 표

## 목표

스위치가 켜져 있을 때 작업이 질문을 하나 남기면 owner는 질문 ID를 옮겨 적지 않고 그 스레드에서 그냥 답을 말하면 된다. 그 말은 모델을 거치지 않고 그 질문의 답이 되고 작업이 이어진다. 열린 질문이 둘 이상이면 봇이 질문마다 버튼을 달아 어느 질문의 답인지 고르게 하고, 고른 질문에만 답이 붙는다. 답으로 도구 실행을 승인하거나 권한을 바꿀 수 없다는 규칙은 그대로다. 병합해도 스위치가 꺼져 있으면 '/' `answer` 경로 그대로다. 변경(CHANGE) 작업의 질문은 이 티켓 범위 밖이고 C28이 선택지 버튼과 함께 맡는다.

## 할 일

1. 수신 분기: 스위치가 켜져 있고, owner가 보낸 일반 메시지(명령·버튼 아님)이고, 그 스레드(대화)에 기한이 지나지 않은 열린 작업 질문이 있으면 대화 작업을 만들지 않는다. 열린 질문 조회는 저장 전에 하고, 질문 대화·응답자·기한 조건은 질문 계약과 같다.
2. 열린 질문이 하나면 그 메시지를 기존 답 경로(`answerIn`)로 같은 수신 트랜잭션 안에서 처리한다. 같은 이벤트 재전달은 한 번만 반영된다. 결과는 기존 답 처리 안내(동료 말투, C09)로 알린다.
3. 둘 이상이면 질문마다 버튼(질문 앞부분 표시)을 단 한 줄 글을 게시하고, 메시지는 고를 때까지 답으로 쓰지 않는다. 버튼을 누르면 누른 사람이 owner인지, 질문이 아직 열려 있고 기한 전인지, 메시지가 같은 스레드의 그 owner 것인지 확인한 뒤 그 질문에만 답을 붙인다. 처리 뒤 버튼을 없앤다. 고르는 사이 질문이 닫히면 거부하고 이유만 답한다.
4. CHANGE 질문은 이 티켓의 바로 답 대상에서 뺀다. 변경 작업 질문의 선택지 버튼과 다음 말 답은 C28이 맡는다(DECISIONS "동료 봇 전환" 14). 이 티켓에서는 열린 질문을 셀 때 `sealsAnswer`로 CHANGE 질문을 가려 빼고(바로 답·질문 고르기 버튼 모두), CHANGE 질문 답은 지금 '/' `answer`와 `label=public | <답>` 서식 경로 그대로 둔다. 바로 답 분기는 C28이 CHANGE 질문 종류를 더할 수 있게 질문 종류별로 나눠 둔다.
5. Claude 작업과 Codex 작업 질문에 같은 규칙을 쓴다. 다른 실행기 세션의 질문은 기존 거부(`FOREIGN_SESSION_STATUS`)를 따른다.
6. 질문 글: 켜짐 판에서 질문 ID 옮겨 적기 안내를 빼고 "이 스레드에서 답을 말해 주세요"로 바꾼다. 답이 승인·권한 변경이 아니라는 문장은 남긴다. 꺼짐 판은 그대로다. CHANGE 질문 글은 `ask`를 함께 쓰지만 바로 답 대상이 아니므로 이 티켓에서는 지금 판(질문 ID와 `label=public` 서식 안내)을 켜짐에서도 그대로 둔다(C28이 바꾼다).
7. 시험: 열린 질문 하나 → 다음 메시지가 답으로 저장되고 작업이 이어지며 모델 호출·대화 작업 0건, 둘 이상 → 버튼 글과 고른 질문에만 답, 기한 지난 질문 제외, 다른 사람·다른 스레드 메시지 무시, 스위치 꺼짐에서 일반 대화로 처리, Codex 질문 같은 규칙, 같은 이벤트 재전달 한 번 반영, 답 원문 7일 정리가 그대로.
8. 기록: 봇 `docs/ai-bot/ARCHITECTURE.md` §12 "질문 계약"에 바로 답 문단, `docs/ai-bot/VERIFICATION.md`에 "C16 작업 질문 바로 답" 절, 이 계획 폴더 `README.md`의 C16 상태 줄 갱신.

- C09에서 넘어옴(봇 #118 Codex 보안 리뷰, 2026-11-10): 질문 글 끝 안내(`src/chat-task-text.ts` `questionFooter`)는 켜짐 판에서도 `/answer question:<ID>`를 안내한다. 자연어 답 경로가 없을 때 그냥 말한 답이 봉인·label 검사를 건너뛰기 때문이다. 이 티켓이 작업 질문의 자연어 답 경로를 만들면서 작업 질문 질문 글의 켜짐 판 안내를 함께 바꾸고(작업·변경 질문이 같은 줄을 쓰므로 종류별로 나눈다), `test/chat-task-text.test.ts`의 켜짐 판 '/' 이름 0 검사 예외를 그 종류만큼 줄인다.

## 완료 조건

- [ ] 스레드에 열린 작업 질문이 하나면 owner의 다음 메시지가 모델 호출 없이 그 답으로 저장되고 작업이 이어진다.
- [ ] 둘 이상이면 질문별 버튼이 달리고, 고른 질문에만 답이 붙는다.
- [ ] 기한 지난 질문에는 답이 붙지 않고, 같은 메시지로 대화 작업이 함께 생기지 않는다.
- [ ] 답이 권한·도구 승인으로 쓰이지 않는다는 규칙과 안내가 그대로다.
- [ ] 스위치가 꺼져 있으면 지금처럼 '/' `answer`로만 답하고 질문 글이 질문 ID를 안내한다.
- [ ] CHANGE 질문은 바로 답과 질문 고르기 대상에서 빠져 있고, 지금처럼 '/' `answer` 경로로만 답한다(선택지와 다음 말 답은 C28).

## 검증

- 경계: S1(PGlite, 가짜 Discord REST). 앞선 시험 예: `task-bridge`, `task-assembly`, `codex-bridge`, `change-assembly`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 `npm test` 대상(전체는 C24 통합).
- 잡는 실패: 다른 질문에 답이 붙는 것, 기한 지난 질문에 답이 붙는 것, 대화 작업이 같이 생기는 것, CHANGE 질문이 바로 답으로 처리돼 원문이 봉인 없이 이벤트에 남는 것. 못 잡는 범위: 없음(전부 결정적 경로).

## 결과

(구현 뒤 채운다)
