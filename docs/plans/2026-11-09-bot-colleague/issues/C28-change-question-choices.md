# C28 변경 질문 선택지

- 단계: 4 말로 실행
- 상태: integrated (봇 #133 병합 `9377c33`, 2026-11-10)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.10 "변경 질문 줄이기", §4.3 "작업 질문 바로 답", §4.9 스위치와 배포 순서, §5 AC-25 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C06, C16, C25
- 연결 AC: AC-25(질문 글·선택지 버튼·답 경로, S1)
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 연결 파일, 소유 C09: 봇 `src/task-bridge.ts`(`ask`: 선택지를 질문 행과 함께 저장하고, 켜짐 판 질문 글에 선택지 버튼과 "직접 답하기" 버튼을 다는 자리. 꺼짐 판 질문 글은 그대로), `src/claude-task-bridge.ts`(변경 작성 결과 `needs_input`의 선택지를 `ask`까지 넘기는 자리, `fetchResult`의 질문 공개 검사에 선택지를 더하는 자리, 변경 작성 요청 `start`·`resume`의 판을 `change-v2`로 바꾸는 자리. 판 전환은 이 티켓 한 곳이다(주 진행자 2026-11-10))
  - 연결 파일, 소유 C04: 봇 `src/discord.ts`(선택지 버튼·"직접 답하기" 상호작용 분기, C16이 만든 바로 답 분기에 CHANGE 질문을 더하는 자리, 저장 전 봉인 판단을 일반 메시지에도 쓰는 자리), `src/discord-protocol.ts`(C13이 만든 custom_id 허용 목록 표에 "변경 선택지"·"직접 답하기" 두 줄), `src/store.ts`(C13이 만든 outbox 버튼 칸을 쓰기만)
  - 연결 파일, 소유 C07: 봇 `src/change-runtime.ts`의 `changeAuthorSource.questionRisk`(질문과 함께 선택지 글도 공개 검사)
  - 연결 파일, 소유 C16: C16이 만든 질문 고르기 버튼과 같은 표·같은 검사(누른 사람 owner, 질문 열림, 기한 전)를 쓴다. 고르기 대기 중 메시지 원문 처리만 CHANGE 질문에 맞춰 더한다
  - 쓰기만 함: 봇 `src/change-commands.ts`의 `ChangeAnswerGuard`(`sealsAnswer`, `answerIn`에 공개 표시 `public`을 붙여 부름. 공개 검사·출처 기록 규칙은 고치지 않음), `src/task-contracts.ts`의 `needs_input` 선택지 칸(C25가 넓힌 계약을 읽기만)
  - 소유(이 티켓만 고침): 봇 `src/raw-text-retention.ts`(질문 원문 7일 정리에 선택지 칸을 더함)
  - 순번 공유: 봇 `migrations/`의 다음 번호. `codex_questions`에 선택지 칸(원문 정리 칸 포함). 병합 때 다음 번호로 다시 매긴다
  - 시험: `test/change-assembly.test.ts`(CHANGE 질문 답), `test/task-bridge.test.ts`(질문 글), `test/raw-text-retention.test.ts`·`test/raw-input-retention.test.ts`(선택지·답 원문 7일), `test/foundation.test.ts`(custom_id 허용 목록 줄), 새 선택지 버튼 시험
- 설계 계약:
  - `src/task-bridge.ts`, `src/claude-task-bridge.ts`: 봇 ARCHITECTURE §12 "질문 계약 (TASK-02, AUTH-02)"(응답자는 작업 owner 하나, 기한 1시간, 다른 대화·다른 사람 답 거부, 답은 승인·권한 변경이 아님), §12 "T18 게시 서버 스케줄링과 질문", §16.4 "작업 레인 v2: artifact와 무자격 검증 (B1)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md)
  - `src/discord.ts` 바로 답·봉인과 `src/change-commands.ts`: 봇 ARCHITECTURE §16.5 "조립과 꺼짐 배포 (B5)"의 CHANGE 질문 답(원문을 `events`에 두지 않고 저장 전 `sealsAnswer`로 봉인, 출처 label 기록, 공개 검사에 걸리면 작성자에 넘기지 않음), §11 "저장·권한·게시"
  - `src/discord-protocol.ts`: C13이 봇 ARCHITECTURE에 더하는 제안·실행 확인 계약 절의 custom_id 표, ARCHITECTURE §6 "보안 경계"의 Discord 입력 문단(버튼은 누른 사람 ID 대조)
  - `src/change-runtime.ts` `questionRisk`: 봇 ARCHITECTURE §16.3 "T19 B3 writer·공개 경계"(공개 검사 `scanPublicText`)
  - `src/raw-text-retention.ts`, `migrations/`: 봇 DECISIONS "T31 원문 칸 보존 (사용자 2026-11-09)", "T27 사람 입력 원문 보존 (사용자 2026-11-07)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md), ARCHITECTURE §14 "마이그레이션 실행"
  - 결정: 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 14(변경 질문: 선택지 버튼 2~4개와 "직접 답하기", 공개 여부를 묻지 않음), 9(스위치)

## 목표

스위치가 켜져 있을 때 변경 작업이 진행할 수 없어 질문하면, Discord 질문 글에 선택지 버튼(2~4개)과 "직접 답하기"가 붙는다. owner는 버튼 하나를 누르거나 그 스레드에서 그냥 답을 말하면 되고, 질문 ID나 `label=public`을 옮겨 적지 않는다. 답은 지금 규칙의 공개 표시로 작성 모델에 넘어가되 공개 검사에 걸리면 받지 않는다. 처음 게시 전 질문의 답은 뒤의 미리보기 승인 때 owner가 본다. 스위치가 꺼져 있으면 지금처럼 `/answer question:<ID> text:label=public | <답>`으로만 답한다. 병합해도 스위치가 꺼져 있으면 운영 동작은 그대로다.

## 할 일

1. 선택지 저장: C25가 넓힌 변경 작성 결과의 `needs_input` 선택지(2~4개)를 `claude-task-bridge.ts`의 변경 작성 경로에서 `task-bridge.ts`의 `ask`까지 넘기고, 질문 행과 같은 트랜잭션에 선택지 칸(마이그레이션)으로 저장한다. 선택지가 없거나 개수가 범위 밖인 응답은 C25 계약이 거부한다는 것을 시험으로 확인한다. 일반 작업(TASK) 질문은 선택지 없이 지금 모양 그대로다.
2. 공개 검사: 질문 글을 스레드에 내기 전에 `questionRisk`가 질문과 선택지 글을 모두 본다. 걸리면 지금처럼 질문 행과 게시 큐를 지나지 않고 그 변경을 막는다(`task_question_sensitive`).
3. 질문 글: 켜짐 판은 질문 본문, 선택지 버튼, "직접 답하기" 버튼, "이 스레드에서 답을 말해도 돼요" 안내, 답이 승인·권한 변경이 아니라는 문장을 둔다. 질문 ID 옮겨 적기와 `label=public` 서식 안내는 켜짐 판에서 뺀다. 버튼 custom_id에는 질문 ID와 선택지 순번만 싣고 선택지 글은 싣지 않는다(서버가 저장된 선택지를 읽음). 문구는 동료 말투 고정 문구로 상수에 둔다.
4. 선택지 버튼: 누른 사람이 owner(질문 응답자)인지, 질문이 같은 스레드에서 아직 열려 있고 기한 전인지 확인한 뒤, 저장된 그 선택지 글을 공개 표시 `public`으로 `ChangeAnswerGuard.answerIn`에 넘긴다. 처리 뒤 버튼을 없애고(메시지 갱신 응답), 같은 버튼을 다시 누르거나 다른 선택지를 눌러도 두 번 답하지 않는다(기존 답 경로의 중복 처리와 질문 상태 대조).
5. "직접 답하기" 버튼: owner에게만 보이는 응답으로 "이 스레드에 답을 말해 주세요"를 알리고 상태는 바꾸지 않는다. 버튼을 누르지 않고 말해도 같은 결과다.
6. 다음 말 답: C16이 만든 바로 답 분기에 CHANGE 질문을 더한다. 스레드에 열린 질문이 이 CHANGE 질문 하나면 owner의 다음 일반 메시지를 저장 전에 봉인(이벤트 원문을 비움)하고 그 원문을 공개 표시 `public`으로 `answerIn`에 넘긴다. 모델 호출과 대화 작업은 0건이다. 열린 질문이 둘 이상이고 그중 CHANGE 질문이 있으면 C16의 질문 고르기 버튼을 쓰되, 고르는 동안 원문을 `events`에 두지 않는다. 원문을 봉인한 채 들고 있을 자리가 마땅치 않으면 메시지를 답으로 쓰지 않고 "어느 질문의 답인지 먼저 골라 주세요"만 답하는 쪽으로 한다(구현 때 정하고 DECISIONS에 적음).
7. 공개 검사에 걸린 답: 지금 `ChangeAnswerGuard` 규칙(작성 모델에 넘기지 않고 그 변경을 막음, 출처 기록)을 그대로 쓴다. 안내 문구만 켜짐 판에서 '/' 이름 없이 동료 말투로 낸다. 공개 여부를 묻는 글은 어디에도 없다.
8. 원문 정리: 선택지 칸을 질문 원문과 같은 7일 기준(`purgeExpiredQuestionPrompts`)으로 비우고 digest를 남긴다. 봉인한 답 원문은 지금처럼 `ChangePrivateInputs`와 질문 행의 답 칸에만 있다.
9. 스위치 꺼짐: 선택지는 저장하되 질문 글은 지금 판(`/answer` 안내)이고 버튼이 없다. CHANGE 질문의 다음 말 바로 답도 열지 않는다.
10. 시험: 선택지 버튼으로 답 → 그 선택지 글이 공개 표시와 함께 작성자에 넘어가고 작업이 이어짐, 다음 말로 답 → 같은 결과와 이벤트 원문 빈칸·모델 호출 0건, 다른 사람·다른 스레드·기한 지난 질문의 버튼 거부, 처리된 버튼 다시 누르기 한 번만, 공개 검사에 걸린 답·선택지 거부, 공개 여부를 묻는 글 0, 스위치 꺼짐에서 지금 경로, 선택지 원문 7일 정리.
11. 기록: 봇 `docs/ai-bot/ARCHITECTURE.md` §16.5 CHANGE 질문 답 문단에 선택지·다음 말 경로를 더하고, `docs/ai-bot/DECISIONS.md`에 고르기 대기 중 원문 처리 판단, `docs/ai-bot/VERIFICATION.md`에 "C28 변경 질문 선택지" 절을 더한다. 이 계획 폴더 `README.md`의 C28 상태 줄을 갱신한다.

- C09에서 넘어옴(봇 #118 Codex 보안 리뷰, 2026-11-10): 질문 글 끝 안내(`src/chat-task-text.ts` `questionFooter`)는 켜짐 판에서도 `/answer question:<ID>`를 안내한다. 자연어 답 경로가 없을 때 그냥 말한 답이 봉인·label 검사를 건너뛰기 때문이다. 이 티켓이 변경 질문의 자연어 답 경로를 만들면서 변경 질문 질문 글의 켜짐 판 안내를 함께 바꾸고(작업·변경 질문이 같은 줄을 쓰므로 종류별로 나눈다), `test/chat-task-text.test.ts`의 켜짐 판 '/' 이름 0 검사 예외를 그 종류만큼 줄인다.

## 완료 조건

- [x] 스위치가 켜져 있을 때 진행이 불가능한 변경 질문이 Discord에 질문, 선택지 버튼(2~4개), "직접 답하기"로 나온다.
- [x] 버튼을 누르면 그 선택지가, 버튼 없이 owner가 다음에 보낸 말이 그 질문의 답이 되고 변경 작업이 이어진다. 버튼과 다른 답이 저장되지 않는다.
- [x] 공개 여부를 묻는 글이 없고, 답은 공개 표시로 넘어가며, 공개 검사에 걸린 답·선택지는 받지 않는다.
- [x] 말로 한 CHANGE 답 원문이 `events`에 남지 않는다.
- [x] 스위치가 꺼져 있으면 지금처럼 `/answer`와 `label=public` 서식으로만 답한다.

## 검증

- 경계: S1(PGlite, 가짜 Discord REST·상호작용). 앞선 시험 예: `change-assembly`, `task-bridge`, `raw-text-retention`, `foundation`. S2(선택지가 든 작성 출력 계약)는 C25가 맡는다.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 `npm test` 대상(전체는 C24 통합).
- 잡는 실패: 선택지 없는 질문 글, 버튼과 다른 답 저장, 공개 검사 누락, 원문이 봉인 없이 이벤트에 남는 것, 스위치 무시. 못 잡는 범위: 모델이 언제 가정하고 언제 묻는지의 판단 품질(C24 S5 표본).

## 결과

- 봇 PR #133, 병합 `9377c33`(2026-11-10). 변경 질문 선택지 버튼·"직접 답하기"·다음 말 답(스위치 뒤), 선택지 7일 정리, 마이그레이션 024. 게시 서버가 변경 작성 요청을 `change-v2` 판으로 보낸다(스위치 밖, 작업자가 알릴 때만. 재개는 시작 턴의 판).
- 완료 조건 5개 충족(S1): `test/c28-change-question.test.ts`와 `change-assembly`·`chat-task-text`·`foundation`·`raw-text-retention` 시험.
- 검사: 결과 `8f5fbc4`에서 `FPB_TEST_TIMEOUT=2400 test.sh <wt> c28-full3 --pg -- full` 2,457개 중 통과 2,435, 실패 0, skip 22. CI `build / test` 통과.
- Codex: 1차 P2 1(gap 복구 중 답 순서), 2차 P1 1(복구한 기존 이벤트 원문)·P2 2 수정. 3차 P2 1("직접 답하기"의 기한 검사)은 C18 할 일 3d로 넘김.
- 운영: 배포 확인(마이그레이션 24, 파드 Ready, digest 일치, 로그 오류 0). 실제 변경 1건이 새 판으로 도는 관측은 C24 S5.
- 한계: gap 복구 중에 한 변경 질문 답은 답으로 쓰지 않고 다시 말해 달라고 한다. 저장 전 판단과 수신 트랜잭션 사이의 경합은 미시험.
