# C09 고정 문구 1: 대화·작업·제어 안내

- 단계: 2 배포와 표면
- 상태: 대기 (선행: C01, C04)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.4 고정 문구와 말투, §4.9 스위치와 배포 순서, §4.1 '/' 명령 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C01, C04
- 연결 AC: AC-11(대화·작업·제어 안내 범위), AC-23(문구 두 판)
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 작업 브리지는 소유(연결 파일, 뒤에 C07 owner 호출 표시, C16 질문 바로 답·질문 글, C19 멈춤·재개, C20 한도 안내 → 자리 비움이 고침), `src/store.ts`는 문구 자리만(연결 파일, 소유 C04): 봇 `src/store.ts`(대화·작업 실패, 취소, 대기 상태 안내, unknown 안내, read 만료 안내, 상호작용 만료 안내, `control` 제어 결과 문구), `src/task-bridge.ts`(작업 질문 글, 답 처리 결과, 질문 만료, `FOREIGN_SESSION_STATUS`), `src/claude-task-bridge.ts`(질문 머리말·답 받음·unknown 막힘·한도·인증 멈춤·질문 공개 검사 거부·완료 요약 머리말·24시간 대기·해제 결과), `src/codex.ts`(Codex 작업 같은 자리의 문구. 모델 지시 문장은 건드리지 않음)
  - 소유(표 밖, 이 티켓만 고침): 봇 `src/control-format.ts`(작업 레인 닫힘 안내, 구독 제어 결과), `src/task-commands.ts`(작업 접수 거부, 작업 취소·해제 응답)
  - 연결 파일, 소유 C04: 봇 `src/discord.ts`의 작업 직접 명령 일시 오류 줄과 텍스트 ACK 대체 문구 두 줄만. 반응 훅·수신 분기는 건드리지 않는다
  - 시험: 위 문구를 리터럴로 비교하는 `test/status-notice.test.ts`, `test/s16-display.test.ts`, `test/task-bridge.test.ts`, `test/task-assembly.test.ts`, `test/codex-bridge.test.ts`, `test/task-contracts.test.ts`, `test/foundation.test.ts`, `test/read-lane.test.ts`, `test/review-9.test.ts`, `test/pr-review.test.ts`(리뷰 취소 제어 결과 줄), `test/task-lane-fixture.ts`의 해당 줄
  - 손대지 않음: `src/chat-format.ts`의 대화 빈 답 문구(C11), 기억·브리핑 문구(C10), 변경·리뷰 알림·경보·세션 연결 문구(C18), `src/change-advice.ts`의 CHANGE 자식 작업 안내(C18 범위로 봄, 분해 표에 없음), `src/commands.ts`의 '/' 명령 설명(명세 §4.1 등록·동작 그대로)
- 설계 계약:
  - `src/store.ts`: 봇 ARCHITECTURE §13 "상태 안내 (멘션 없음)"(멱등 키·`safe_summary`·멘션 막음), §13 "read 레인"(read 만료 안내), §13 "정상 종료 (SIGTERM)"·"불확실한 결과와 chat unknown"(실패·unknown 안내가 나가는 조건), §11 "조회·예산·작업자 제어" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md)
  - `src/task-bridge.ts`, `src/claude-task-bridge.ts`, `src/codex.ts`: 봇 ARCHITECTURE §12 "질문 계약 (TASK-02, AUTH-02)"(답이 승인·권한 변경이 아님, 기한), §12 "T18 게시 서버 스케줄링과 질문", §12 "작업 정리와 `unknown` 막힘"
  - `src/control-format.ts`, `src/task-commands.ts`: 봇 ARCHITECTURE §12 "T18 작업 레인 조립"(명령 표와 응답 방식)
  - `src/discord.ts`(두 줄): 봇 ARCHITECTURE §13 "수신·진행 신호"(403/404 텍스트 대체)
  - 문구 두 판과 스위치: 봇 COLLEAGUE_SPEC §4.4·§4.9, DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 4·9 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md)

## 목표

owner가 Discord에서 보는 대화·작업·제어 안내가 해요체 동료 말투로 결론부터 짧게 나온다. 다음 행동을 '/' 명령 이름으로 안내하던 줄은 동료 스위치가 꺼져 있으면 지금처럼 '/'를 안내하고, 켜져 있으면 '/' 이름 없이 말로 하는 안내가 된다. 병합하면 말투가 바뀐 문구는 바로 운영에 나가고, 켜짐 판은 스위치를 켤 때(C24)부터 보인다.

## 할 일

1. 소유 파일의 고정 문구를 모아 동료 말투로 다시 쓴다(해요체, 결론부터, 자기를 "봇"이라 부르지 않음). 상태 안내, 실패·취소, 제어 결과, 작업 레인 닫힘, 작업 대기, 작업 질문 머리말, 완료 요약 머리말, 해제 결과가 대상이다. 상태·사유 코드(`unknown`, `cleanup_pending` 등)를 owner가 읽는 문장 대신 보여 주던 곳은 뜻을 풀어 쓰되, 감사·로그의 코드는 바꾸지 않는다.
2. '/' 이름을 안내하는 줄은 C01 스위치 값으로 두 판을 고른다. 꺼짐 판은 지금 안내를 말투만 바꾸고, 켜짐 판은 말로 하는 안내(예: "작업 목록 보여 줘"라고 말하기)다. 관리 기능(비상 정지 해제, unknown 해제, 모델 상태)을 안내하는 줄의 켜짐 판은 `homelab bot` CLI로 한다고만 말한다(명령 이름은 C05가 정한 것을 쓴다).
3. 한도·인증 대기 안내(`src/store.ts` 대기 안내, `src/claude-task-bridge.ts`·`src/codex.ts`의 모델 멈춤 줄)는 말투만 바꾼다. 자리 비움으로 바꾸는 것은 C20이다.
4. 작업 질문 글의 "질문 ID를 옮겨 적어 답하라"는 안내는 두 판 모두 남긴다. 켜짐 판에서 빼는 것은 C16이다. 질문 답이 도구 승인·권한 변경이 아니라는 문장은 두 판 모두 남긴다.
5. 공개 검사 사유, 작업·질문 ID, 숫자는 문장에 그대로 싣는다. 모델이 쓴 글(질문 본문, 완료 요약)을 감싸는 머리말만 바꾸고 모델 글 자체와 공개 검사 경로는 건드리지 않는다.
6. 리터럴 비교 시험을 상수 참조로 옮겨 고친다(명세 §6: 리터럴 비교는 안전 규칙에만). 켜짐 판에 '/' 명령 이름이 하나도 없음을 소유 문구 전체에 대해 검사하는 시험을 더한다(명령 이름 목록은 `src/commands.ts`의 등록 목록에서 읽는다).
7. 기록: 봇 `docs/ai-bot/VERIFICATION.md`에 "C09 고정 문구 1" 절(바꾼 문구 수, 두 판 줄 수, 시험 결과), `docs/ai-bot/DECISIONS.md`에 문구 판단(사유 코드를 풀어 쓴 곳, 관리 기능 안내 방식)이 있으면 그 절, 이 계획 폴더 `README.md`의 C09 상태 줄 갱신.

## 완료 조건

- [ ] 소유 파일의 Discord 고정 문구가 해요체이고 "봇"이라는 자기 지칭이 없다.
- [ ] 스위치 꺼짐이면 '/' 안내 줄이 지금과 같은 '/' 이름을 안내한다.
- [ ] 스위치 켜짐이면 소유 파일의 고정 문구 어디에도 '/' 명령 이름이 없다(시험으로 확인).
- [ ] 멱등 키, 분류(`safe_summary`), 멘션 막음, 질문 답이 승인·권한 변경이 아니라는 안내가 그대로다.
- [ ] 바뀐 파일 관련 시험이 통과한다.

## 검증

- 경계: S1(게시 서버). 앞선 시험 예: `status-notice`, `s16-display`, `task-bridge`, `codex-bridge`, `foundation`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 `npm test` 대상(전체는 C24 통합).
- 잡는 실패: 새로 쓴 문구의 '/' 이름 잔존, 스위치 분기 누락, 안내 멱등 키·분류 회귀. 못 잡는 범위: 문구의 자연스러움(owner 검토, C24 말투 표본).

## 결과

(구현 뒤 채운다)
