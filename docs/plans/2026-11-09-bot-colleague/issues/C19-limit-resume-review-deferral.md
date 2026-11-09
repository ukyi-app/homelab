# C19 한도 재개와 리뷰 미루기

- 단계: 5 멈춤과 계정
- 상태: 대기 (선행: C05, C09, C10, C11, C12)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.7 "멈춤 종류와 재개"·"리뷰 미루기", §5 AC-16·AC-17, §8 "`rate_limit_event` 필드" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C05, C09, C10, C11, C12
- 연결 AC: AC-16, AC-17
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 봇 `src/store.ts`: 연결 파일, 소유 C09. 이 티켓은 모델 멈춤 기록·재개 자리를 고친다: `waitForUser`(멈춤 시작), `releaseScheduler`, `controlLocked`의 `resume-model`(해제 때 바로 재개), 작업 레인 장벽(`taskLaneStopped`), 대화 claim.
  - 봇 `src/claude-task-bridge.ts`, `src/codex.ts`: 연결 파일, 소유 C09. 작업 레인 응답의 한도 정보를 읽어 같은 멈춤 기록에 넣는 자리만.
  - 봇 `src/runtime.ts`: 대화 레인 결과 처리(`limited`·`auth_expired` → `waitForUser`). 연결 표에 없는 공유 파일이다(C11이 v2 답 처리를, C20이 대기 안내를 같은 파일에서 고친다. README 5절에 반영).
  - 봇 `src/review.ts`: 리뷰 claim(`ReviewRuntime.claim`)과 리뷰 결과의 한도 처리. 연결 파일, 소유 C12(README 5절, 뒤 티켓 C18·C19·C20). 이 티켓은 claim 조건과 한도 정보 저장 자리만 고친다.
  - 봇 `src/briefing.ts`: 연결 파일, 소유 C10. 미룬 리뷰 건수 줄 하나만 더한다.
  - 봇 `src/main.ts`: 재개 예약 루프 배선. 연결 표에 없는 공유 파일이다(C20 상태 배선, C21 지표 배선과 겹친다. README 5절에 반영).
  - 봇 `src/contracts.ts`(작업자 응답의 한도 정보 칸): 연결 파일, 소유 C02. 읽기만 한다.
  - 봇 `migrations/`: 순번 공유. 멈춤 종류·풀리는 시각·다음 재시도 시각·리뷰 미룸 기한을 둔다.
  - 봇 시험: 가짜 시계 재개 시험(새 파일), `test/status-notice*.test.ts`, `test/review-*.test.ts`, `test/task-lane-pg.test.ts`, `test/memory-briefing.test.ts`의 해당 줄.
- 설계 계약:
  - `src/store.ts`, `src/runtime.ts`, `src/main.ts`: 봇 ARCHITECTURE "11. T16a 확정 계약과 로컬 구현"의 "호출 경로·직렬 대기·측정"(한도 대기, 자동 인증 전환 없음)과 "REVIEW-8: 마감 기준점·owner 재개·확정된 원격 응답", "13. 개선안 v2 적용"의 "상태 안내 (멘션 없음)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). 봇 DECISIONS "D-14 봇 모델 계정과 인증"의 "함께 지킬 조건 (결정의 일부)" 조건 2와 그 "변경(사용자 2026-11-09…)" 문단 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - `src/claude-task-bridge.ts`, `src/codex.ts`: 봇 ARCHITECTURE "12. T18 CODEX_BRIDGE 로컬 계약"의 "T18 작업 레인 계약 (Claude, 2026-11-05)"·"T18 게시 서버 스케줄링과 질문 (2026-11-05)", 봇 DECISIONS "T18 결정 (Claude 실행기 기준, 사용자 2026-11-04)"의 "작업 레인 unknown과 비상 중지 (사용자 2026-11-05)".
  - `src/review.ts`: 봇 DECISIONS "T17 결정 (사용자 2026-11-04)", 봇 ARCHITECTURE "11"의 "조회·예산·작업자 제어".
  - `src/briefing.ts`: 봇 DECISIONS "T20 기억·삭제 원장·브리핑 (로컬·mock, 2026-10-29)".
  - 한도 정보 칸의 모양: 봇 ARCHITECTURE "12"의 "T16b 실행기 프로필 (2026-10-30, D-14 변경)"(오류 분류)과 C02·C03이 더한 절.
  - 결정: 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 7.

## 목표

모델 한도에 걸리면 봇이 풀리는 시각 1분 뒤 같은 계정으로 저절로 이어서 한다. 풀리는 시각을 모르면 30분마다 다시 시도한다. 인증 만료는 owner가 계정을 바꾸고 해제하면 바로, 다른 길로 토큰을 바꿨으면 30분 안에 이어서 한다. 결제 멈춤과 비상 정지 중에는 저절로 재개하지 않는다. 다른 계정·모델·실행기로 저절로 넘어가는 일은 없다. 한도 경고가 오면 그 한도가 풀릴 때까지 새 PR 리뷰를 미루고 대화·작업은 계속하며, 브리핑에 미룬 건수가 나온다.

자동 재개와 리뷰 미루기는 스위치 밖이라 병합하면 바로 운영에 나간다. 한도 대기의 Discord 안내 문구 교체는 C20 몫이라 이 티켓 병합 뒤에도 지금 '/' 재개 안내가 남는다(자동 재개가 와도 안내가 틀리지 않도록 "저절로 이어서 한다"는 사실만 맞게 둔다).

## 할 일

1. 멈춤 기록을 한곳에 둔다: 종류(한도, 인증 만료, 결제), 풀리는 시각, 한도 종류(`rateLimitType`), 마지막 사용률, 다음 재시도 시각. 마이그레이션을 더한다(순번 공유). C21의 지표가 이 기록을 읽는다.
2. 대화·리뷰 실행 결과(`src/runtime.ts`, `src/review.ts`)와 작업 레인 응답(`src/claude-task-bridge.ts`, `src/codex.ts`)에서 C03이 채운 한도 정보를 읽어 멈춤 기록을 쓴다. 작업 레인 응답에 한도 정보가 없거나 게시 서버가 그 칸을 받지 못하는 경우(C03 결과)는 30분 재시도로 내려앉게 한다.
3. 결제를 한도와 구별한다. 지금 실행기는 `billing_error`를 `rate_limit`과 같은 한도 대기로 분류한다(`src/executor-claude.ts`의 `LIMIT_KINDS`). 작업자 응답(C02 계약, C03 한도 정보 칸)에 결제 구분이 있으면 그것을 쓴다. 없으면 이 티켓에서 작업자 계약을 바꾸지 말고 lead에 알린다(계약 모양은 C02 소유).
4. 재개 예약 루프를 둔다(`src/main.ts` 배선): 한도 + 풀리는 시각이면 그 시각 + 1분, 시각이 없으면 30분 간격, 인증 만료는 30분 간격. 재개는 지금 `resume-model`과 같은 상태 전이(`waiting_user` → `queued`, 재시도 상한 유지)를 쓰고, 같은 계정·같은 실행기 그대로다. 비상 정지(`scheduler_emergency`) 중이거나 결제 멈춤이면 아무것도 하지 않는다. 감사 기록 행위자는 자동 재개로 남긴다.
5. 관리 진입점 해제(C05의 `homelab bot` 해제, 시범 동안 '/' `resume-model`도)가 들어오면 인증 만료 멈춤을 바로 재개한다. 해제 진입점은 store의 같은 해제 함수를 부르게 해서 어느 쪽에서 와도 같게 한다(C05가 먼저 병합됐으면 그 경로를 쓰고, 아니면 store 함수 자리만 맞춘다).
6. 리뷰 미루기: 대화·리뷰 실행에서 `allowed_warning`과 그 한도의 풀리는 시각을 받으면 그 시각까지 새 리뷰 claim(`ReviewRuntime.claim`)을 빼고, 대화·작업 claim은 그대로 둔다. 기한이 지나면 claim이 다시 리뷰를 집는다. 미룬 리뷰는 대기열에 남고 유실되지 않는다. 미룸 기한도 멈춤 기록과 같이 저장해 재시작 뒤에도 같다.
7. 브리핑에 미룬 리뷰 건수 줄을 더한다(`src/briefing.ts`, 0이면 줄 없음). 문구는 C10의 동료 말투 규칙을 따른다.
8. 가짜 시계 시험: 시각 + 1분 재개, 시각 없음 30분, 인증 만료 30분과 해제 때 바로, 결제 재개 0, 비상 정지 중 재개 0, 재개 뒤 계정·모델·실행기 그대로, 경고 중 리뷰 claim 0과 대화 claim 계속, 기한 뒤 리뷰 재개, 재시작 뒤 기록 유지.
9. 기록: 봇 `docs/ai-bot/VERIFICATION.md`에 "C19 한도 재개와 리뷰 미루기" 절, `docs/ai-bot/DECISIONS.md`에 재개 스케줄과 결제 구분 방식 문단, `docs/ai-bot/ARCHITECTURE.md` "상태 안내"·"호출 경로" 절에 자동 재개 문단을 더한다. 이 계획 폴더 `README.md`의 C19 상태 줄을 갱신한다.

## 완료 조건

- [ ] `rejected`와 풀리는 시각이 있으면 그 시각 1분 뒤 같은 계정으로 저절로 이어서 한다. 시각이 없으면 30분마다 다시 시도한다.
- [ ] 인증 만료는 관리 진입점 해제 뒤 바로, 그 밖의 토큰 교체 뒤 30분 안에 이어서 한다.
- [ ] 결제 멈춤은 저절로 재개하지 않고, 비상 정지 중에는 어떤 재개도 없다. 다른 계정·모델·실행기로 바뀐 실행이 0건이다.
- [ ] `allowed_warning`을 받으면 그 한도가 풀릴 때까지 새 리뷰 작업을 집지 않고 대화·작업은 계속한다. 풀리면 이어서 하고, 브리핑에 미룬 건수가 나온다.

## 검증

- 경계: S2(고정 stream-json에서 한도 정보 읽기, C03의 fixture)와 S1(가짜 시계로 재개 스케줄과 claim 순서, PGlite). 앞선 예: `status-notice`, `status-notice-pg`, `review-lane`, `task-lane-pg`, `memory-briefing` 시험.
- 명령: 봇 `npm run check`, `npm test`(작업자 완료 검사는 바뀐 파일 관련 시험만, 전체는 통합 담당 C24).
- 잡는 실패: 재개 누락·조기 재개, 결제·비상 정지 중 재개, 자동 전환, 경고 중 리뷰 시작, 대화 지연, 미룬 리뷰 유실. 못 잡는 범위: 2.1.308 `-p` 구독 모드에서 실제로 `resetsAt`·사용률이 오는지(첫 실제 한도 때 S5, C24가 실측. 안 오면 30분 재시도로 동작하고 리뷰 미루기는 동작하지 않는다), 실제 경고 빈도(S5).

## 결과

(구현 뒤 채운다)
