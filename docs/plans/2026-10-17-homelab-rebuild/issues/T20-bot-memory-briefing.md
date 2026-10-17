# T20 봇 MEMORY_BRIEFING

- 단계: P4 봇 V1
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: T16
- 연결 AC: AC-B7
- 수행: 개발 에이전트 (`STAGE=MEMORY_BRIEFING`)

## 목표

`01` §8: 출처 기반 기억과 일일 브리핑 (R16~R18).

## 메모

`01`의 권장 순서는 CHANGE_PR 뒤지만, 실제로 막는 것은 FOUNDATION의 예약 기능뿐이다. 그래서 T17·T18과 병행할 수 있다. 브리핑에 넣는 Codex 작업 상태와 승인·질문 대기(`01` §8 일일 브리핑)는 T18이 끝난 뒤 연결한다.

## 완료 조건

- `04` §4 시험 MEM-01, BRIEF-01, DATA-02, AUTH-02 결과가 있다 (spec §7 AC-B7).
- spec §7 "단계 AC 공통 완료 규칙"을 따른다. 배정된 시험에 `fail`이 없다. `blocked`·`not_run`은 사유와 해소 티켓을 함께 적는다. 이 단계에 배정된 보안 경계 시험은 없다.
- HANDOFF가 있다.

## 검증

`04` §4 시험.
