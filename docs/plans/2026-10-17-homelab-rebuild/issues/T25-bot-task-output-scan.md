# T25 봇 작업 레인 질문·완료 요약의 공개 검사

- 단계: P4 후속 (T21 1회차 감사에서 나옴, 출시 차단)
- 상태: 완료 (2026-11-07. 봇 #89 `8e21a9c`, 배포 homelab #1175. 작업 레인 질문·완료 요약이 `scanPublicText`를 지나고, 감사 재현 A01은 Discord 도달 0)
- 명세: [../spec.md](../spec.md)
- Blocked by: 없음
- 연결 AC: AC-B8 (DATA-01, F04·F09·R09)
- 수행: 에이전트

## 목표

`/task` v1 작업 레인이 작업자의 질문과 완료 요약을 비밀 패턴·비공개 표식 검사 없이 Discord로 보낸다. T21 1회차 감사 A01(봇 저장소 `docs/ai-bot/V1_RELEASE_REPORT.md`, 결함 후보 FIX-01)이다. 질문과 완료 요약이 Discord로 나가기 전 같은 경계에서 검사하고, 걸리면 원문 없는 고정 안내만 보낸다.

## 메모

- 위치(봇 `dda891f`): 질문은 `src/task-bridge.ts`의 `ask`가 `safe_summary`로 원문을 넣는다. 완료 요약은 `src/claude-task-bridge.ts`의 `store.finish` 호출이 `response.summary`를 그대로 넣는다.
- 시험 `test/task-bridge.test.ts` "TASK-02 질문 중계: 공개 검사는 CHANGE 경로에만 있어…"가 합성 토큰이 그대로 나가는 동작을 통과 조건으로 고정했다. 수정과 함께 이 시험을 뒤집는다.
- CHANGE 질문·공개 답 검사(봇 #86)와 모델 자격 정확 일치 반사 검사는 이미 있다. 같은 검사기를 재사용할 수 있는지 먼저 본다.
- 실제 자격 유출 사고로 확정한 것은 아니다. 작업자가 가진 실제 자격은 모델 자격뿐이고 그 정확 일치 검사는 있다.

## 할 일

1. 질문과 완료 요약의 공통 게시 경계에서 출처·수신 범위·민감 패턴을 검사한다. 차단 때는 원문 없는 고정 안내와 사유 코드만 남긴다.
2. 합성 토큰, 내부 표식, 인코딩 변형, 정상 질문·요약을 bridge → outbox → publisher 경로로 시험한다. DB·로그에도 원문이 남지 않는지 본다.
3. 봇 저장소 PR, 운영 배포, 봇 `VERIFICATION.md` 기록.

## 결과 (2026-11-07)

- 봇 #89 `8e21a9c`(구현은 Claude 작업자, Codex 코드·보안 리뷰 지적 없음). 검사 모듈 `src/task-output.ts`. 내부 표식은 모든 CHANGE 저장소의 `internalMarkers`와 `review.internalMarkers`의 합이다. 질문이 걸리면 질문 행·outbox 없이 `failed(task_question_sensitive)`로 닫고 사유 코드만 안내한다. 완료 요약이 걸리면 그 줄만 고정 문구로 바꾼다. 정책을 못 읽으면 막는다.
- 작업 레인에서 모델 글이 Discord로 나가는 경로는 질문과 완료 요약뿐이다(전수 확인). 운영에서 만들지 않는 `CodexBridge`(`src/codex.ts`)에는 같은 경로가 남아 있어, 다시 연결하면 같은 검사가 필요하다.
- 시험: `task-bridge` 74/74(사례 6개 × 질문·요약·정책 불가, REST 본문·outbox·`codex_questions`·로그에 원문 0), 감사 재현 A01 Discord 도달 0, 전체 2,087 중 실패 0(PG). 남은 위험: 공개 메타데이터 기준이라 이메일·긴 숫자·`/home/` 경로가 든 평범한 질문도 막혀 작업이 실패로 끝난다(CHANGE 질문과 같은 경계).
- 배포: homelab #1175(T26과 함께), 파드 1/1 Ready·imageID 일치. 기록은 봇 저장소 `docs/ai-bot/VERIFICATION.md` "T21 출시 차단 수정 T25·T26". 실모델 출력 시험은 T30 INT-07.

## 완료 조건

- 합성 비밀·내부 표식이 든 질문·요약은 실제 게시 경로에서 Discord REST 호출 0 또는 고정 비민감 안내다.
- 정상 질문·요약 중계는 그대로 된다.
- 감사 재현(ops `evidence/release-audit/` `audit-probes.mjs`의 A01)이 막힌다.

## 검증

`04` §4 DATA-01, TASK-02. 실모델 출력 시험은 [T30](T30-bot-v1-integration-tests.md) INT-07.
