# C03 작업자 한도 정보 읽기

- 단계: 1 기반
- 상태: 대기 (선행: C02)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.2(한도 정보), §4.7(한도 정보 읽기), §5 AC-16, §8 "`rate_limit_event` 필드" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C02
- 연결 AC: AC-16(S2)
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유: 소유 `src/executor-claude.ts`(stream-json 축약 `compactClaudeEvent`에서 `rate_limit_event` 필드 보존, `interpretClaudeStream` 결과에 한도 정보, `classifyClaudeError` 결과에 풀리는 시각), `src/executor.ts`(실행기 중립 결과 `EngineOutcome`에 한도 정보), `src/executor-claude-task.ts`(작업 레인 응답에 한도 정보), `src/task-contracts.ts`(작업 레인 v1·v2 응답 스키마의 선택 칸), `src/review-lane.ts`·`src/review-http.ts`(리뷰 응답의 선택 칸). 연결 파일, 소유 C02: `src/chat-lane.ts`·`src/worker.ts`(C02가 만든 v2 응답 한도 칸을 채운다). 공유 파일(README 5절에 반영): `src/task-contracts.ts`·`src/review-http.ts`(게시 서버와 작업자가 함께 쓰는 응답 계약, 뒤에 C19가 읽는다). 시험 `test/worker-claude.test.ts`·`test/task-stream.test.ts`·`test/review-lane.test.ts`와 고정 stream-json fixture. 봇 `VERIFICATION.md`·`DECISIONS.md`·`ARCHITECTURE.md`는 추가만.
- 설계 계약:
  - `src/executor-claude.ts`, `src/executor.ts`: ARCHITECTURE §12 "T16b 실행기 프로필"(stream-json 해석 순서, 한도·인증 분류는 CLI의 구조화 필드만 근거), §11 "REVIEW-7: 실행 중 오류 분류 보존" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). DECISIONS D-14 "변경(사용자 2026-11-09…)" 문단과 "동료 봇 전환 (사용자 2026-11-09)" 7 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - `src/executor-claude-task.ts`, `src/task-contracts.ts`: ARCHITECTURE §12 "T18 작업 레인 계약 (Claude, 2026-11-05)", §16.4 "작업 레인 v2: artifact와 무자격 검증 (B1)".
  - `src/review-lane.ts`, `src/review-http.ts`: ARCHITECTURE §16.2 "미게시 후보 리뷰 (B2)", DECISIONS "T17 결정 (사용자 2026-11-04)".
  - `src/chat-lane.ts`, `src/worker.ts`: C02의 계약(ARCHITECTURE §12 "T16b 작업자 진입점").

## 목표

작업자가 Claude CLI 스트림의 `rate_limit_event`에서 상태(`allowed`·`allowed_warning`·`rejected`), 풀리는 시각(`resetsAt`), 종류(`rateLimitType`), 사용률(`utilization`)을 읽어 대화·리뷰·작업 레인 응답에 싣는다. 뒤 티켓(C19 재개·리뷰 미루기, C21 운영 알림)이 이 값을 쓴다. 게시 서버는 아직 이 칸을 읽지 않으므로 병합해도 운영 동작은 그대로다(게시 서버 쪽 응답 스키마가 선택 칸을 받게 바뀌는 것만 병합 즉시 나간다). 작업자 배포는 C06이다.

## 할 일

1. stream-json 축약(`src/executor-claude.ts` `compactClaudeEvent`)이 지금은 모르는 이벤트를 `type`·`subtype`만 남기고 버린다. `rate_limit_event`의 `rate_limit_info`에서 네 필드만 모양을 검사해 남긴다(문자열 열거, 시각·사용률은 숫자 범위). 다른 필드와 원문은 남기지 않는다. 작업 레인 축약(`compactTaskEvent`)과 정책 검사가 이 이벤트를 위반으로 보지 않는지 확인한다.
2. 해석 결과(`src/executor.ts` `EngineOutcome`, `interpretClaudeStream`)에 그 실행에서 마지막으로 본 한도 정보를 싣는다. 성공·한도 오류·다른 실패 어느 결과에도 실을 수 있다.
3. 오류 분류(`classifyClaudeError`)는 그대로 둔다(인증 종류, 한도 종류 `rate_limit`·`billing_error`, HTTP 상태). 한도 오류로 분류되면 같은 실행의 `rejected` 한도 정보의 풀리는 시각을 함께 붙일 수 있게만 한다. 결제(`billing_error`)를 한도와 가를 수 있는 값도 함께 넘긴다(C19가 결제 멈춤을 자동 재개에서 뺀다).
4. 대화 레인: C02가 만든 v2 응답 한도 칸을 채운다(`src/chat-lane.ts`). v1 요청 응답에는 싣지 않는다.
5. 리뷰 레인: 리뷰 응답(`src/review-lane.ts`, `src/review-http.ts`)에 선택 칸으로 싣는다. 리뷰 요청은 v1·v2 구분 없이 같은 응답이므로, 게시 서버 쪽 응답 스키마(strict)가 이 칸을 받는지 먼저 바꾼다.
6. 작업 레인: v1·v2 작업 응답(`src/task-contracts.ts` `TaskResponseSchema`·`TaskV2ResultResponseSchema`, 둘 다 strict)에 선택 칸으로 싣는다(`src/executor-claude-task.ts`). 게시 서버(`src/claude-task-bridge.ts`가 같은 스키마로 파싱)는 모르는 칸을 받으면 응답을 거부한다 [확인: strictObject]. 대안: 이 PR에서 스키마에 선택 칸을 먼저 더하면 게시 서버는 병합 즉시 받는 쪽이 되고, 작업자는 C06 배포 뒤에야 칸을 보낸다. 그래서 순서는 맞다. 게시 서버만 이 PR 이전으로 롤백하면 새 작업자 응답이 거부되므로, 이 사실을 `VERIFICATION.md`와 C06 롤백 절차에 적는다.
7. 미게시 변경 리뷰(`src/change-review.ts`의 작업자 결과 스키마)도 같은 실행기를 쓰는지 확인하고, 쓰면 같은 선택 칸을 넣을지 C19 범위와 함께 적는다(이 티켓은 넣지 않아도 된다).
8. 고정 fixture: 로컬 2.1.319 바이너리에서 확인한 이벤트 모양(명세 4.7)으로 `allowed`, `allowed_warning`(사용률 포함), `rejected`(풀리는 시각 포함), 한도 오류 결과와 함께 온 `rejected`, 이벤트 없음을 만든다. 이미지의 2.1.308 `-p` 구독 모드에서 같은 필드가 오는지는 미확인으로 남긴다(C24에서 실측).
9. 시험: 레인별로 fixture → 응답의 한도 칸, 모르는 상태 값과 깨진 필드는 칸 없음, 이벤트 없음은 칸 없음, 한도 오류 분류가 그대로인지, 원문 필드가 응답에 새지 않는지.
10. 기록: 봇 `ARCHITECTURE.md` §12 "T16b 실행기 프로필"에 한도 정보 문단, `VERIFICATION.md`에 "C03 작업자 한도 정보" 절(2.1.308 미확인 포함), `DECISIONS.md` "동료 봇 전환" 7에 구현 위치 한 줄. 이 계획 폴더 `README.md`의 C03 상태 줄 갱신.

## 완료 조건

- [ ] 고정 stream-json의 `rate_limit_event`가 대화 v2·리뷰·작업 레인 응답의 한도 칸으로 나온다(AC-16 S2).
- [ ] 한도 오류 결과에 `rejected`의 풀리는 시각이 붙고, 오류 분류(한도·인증·결제)는 바뀌지 않는다.
- [ ] 게시 서버 쪽 응답 스키마가 한도 칸이 있는 응답과 없는 응답을 둘 다 받는다.
- [ ] 2.1.308 실측이 미확인으로 `VERIFICATION.md`에 남아 있다.

## 검증

- 경계: S2(고정 stream-json을 내는 가짜 CLI → 작업자 응답). 앞선 시험 예: `worker-claude`, `task-stream`, `review-lane`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험(`worker-claude`, `task-stream`, `review-lane`, 작업 레인 계약 시험 `task-contracts`). 전체 `npm test`는 통합 담당.
- 잡는 실패 / 못 잡는 범위: 잡는 것은 한도 정보 누락·잘못 읽기, 응답 스키마 불일치로 인한 거부, 분류 회귀다. 못 잡는 범위: 2.1.308 `-p` 구독 모드에서 실제로 `resetsAt`이 오는지(첫 실제 한도 때 S5, C24. 안 오면 C19의 30분 재시도로 동작한다), 재개 스케줄(C19의 S1 가짜 시계 시험).

## 결과

(구현 뒤 채운다)
