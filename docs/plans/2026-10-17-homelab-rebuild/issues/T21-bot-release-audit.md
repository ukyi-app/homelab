# T21 봇 V1 RELEASE_AUDIT

- 단계: P4 봇 V1 (봇 V1 통합 검증 담당)
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: T17, T18, T19, T20
- 연결 AC: AC-B8
- 수행: 구현 세션과 다른 독립 감사 에이전트 (`MODE=audit`). 사람은 수용 결정

## 목표

V1을 판정한다. 판정 정의는 `04` §9, end-to-end 흐름은 `01` §9, 시험과 양식은 `04` 전체가 기준이다.

## 할 일

1. `04` §1 감사 프롬프트를 실행한다.
2. `04` §4의 시험 30개 결과를 모두 기록한다.
3. F01~F09, R01~R18의 구현 위치와 증거를 추적한다.
4. `01` §9의 end-to-end 흐름 5개를 확인한다.
5. 판정을 내린다: `NOT_READY`, `LOCAL_VERIFIED_INTEGRATION_PENDING`, `READY_FOR_SCOPED_PILOT`, `V1_ACCEPTED`.

## 제약

감사자는 사용자 수용을 대신 선언하지 않는다. V2를 시작하지 않는다.

## 완료 조건

`V1_RELEASE_REPORT.md`와 요구사항·시험 추적표가 있고, 판정이 `READY_FOR_SCOPED_PILOT` 이상이다.

판정이 그보다 낮으면 감사는 끝났지만 T21은 완료가 아니다. 차단 사유를 둘로 나눠 티켓을 만들고, 처리 뒤 T21을 다시 실행한다.

- 결함(`fail`, 경계 위반, 필수 범위 누락): 사유마다 수정 티켓을 만든다.
- 사람 승인이 필요한 미실시 실연동(`LOCAL_VERIFIED_INTEGRATION_PENDING`의 원인, spec §11): 승인·연동 티켓을 만든다. 승인은 [../approvals.md](../approvals.md)에 남긴다.

## 검증

`04` §8 보고 양식, §9 판정 기준.
