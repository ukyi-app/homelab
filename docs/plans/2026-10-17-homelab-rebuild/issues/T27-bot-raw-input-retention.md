# T27 봇 작업 답·변경 요청 원문의 보존과 삭제

- 단계: P4 후속 (T21 1회차 감사에서 나옴, 현 버전 필수 수정)
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: 없음
- 선행 결정: 할 일 1 (사용자 결정, 미정)
- 연결 AC: AC-B8 (F04)
- 수행: 에이전트 + 사람(보존 기간 결정)

## 목표

작업 레인 질문의 답(`codex_questions.answer`)과 변경 요청 원문(`change_request_inputs.text`)에 보존 기간과 정리 경로가 없다. 7일 정리는 CHANGE artifact와 리뷰 원문에만 걸린다. T21 1회차 감사 A03(봇 저장소 `docs/ai-bot/V1_RELEASE_REPORT.md`, 결함 후보 FIX-03)이다. 원문 종류별 보존 계약을 정하고 집행한다.

## 메모

- 위치(봇 `dda891f`): `src/task-bridge.ts`(답 저장), `migrations/009_codex_bridge.sql`, `src/change-store.ts`의 `purgeExpiredChangeContent`. 감사 재현에서 8일 뒤 정리를 돌리면 artifact만 지워지고 두 원문은 남았다.
- 원문이 DB와 백업에 기간 없이 쌓인다. 7일 규칙이 이 필드에도 합의됐다고 보지 않는다.
- digest와 receipt는 증거라 남기고 원문만 정리하는 방향이 감사 제안이다.

## 할 일

1. 원문 종류별 보존 기간, 삭제 요청, 진행 중·`unknown` 예외, 백업 복원 때 재적용을 정한다(사용자 결정).
2. 정리 경로를 구현한다. cutoff 전후, 재개·`unknown`, 중복 정리, 복원 뒤 삭제된 원문이 다시 보이지 않는지 시험한다.
3. 봇 저장소 PR, 운영 배포, 봇 `ARCHITECTURE.md`·`VERIFICATION.md` 기록.

## 완료 조건

- 두 원문에 보존 기간과 정리 경로가 있고, 기간이 지나면 원문이 지워진다. 증거 digest는 남는다.
- 결정이 [../approvals.md](../approvals.md)와 봇 `DECISIONS.md`에 있다.

## 검증

`04` §4 DATA-02(원문 수명 하위 사례).
