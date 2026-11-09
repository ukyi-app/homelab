# T32 봇 CHANGE 정리의 선정 조건 재확인 (T21 2회차 A09)

- 단계: P4 후속 (T21 2회차 감사에서 나옴)
- 상태: 진행 중 (2026-11-09 착수, 사용자 결정)
- 명세: [../spec.md](../spec.md)
- Blocked by: 없음
- 연결 AC: AC-B8 (F04, R13, DATA-02)
- 수행: 에이전트 (구현은 Claude 작업자, 검토·전체 시험·배포는 lead)

## 목표

T21 2회차 감사(2026-11-09, 판정 `NOT_READY`)의 유일한 출시 차단 A09(medium)를 고친다. 봇 `src/change-store.ts` `purgeExpiredChangeContent`는 정리 후보를 트랜잭션 밖에서 고른 뒤, 건마다 부모 행을 잠그고 **상태(phase)만** 다시 본다. 고른 뒤 owner가 새 generation을 열고 그 generation이 다시 끝 상태가 되면, 종료 경과 0ms인 새 generation의 artifact·리뷰 발견·요청 원문·brief까지 지우고 다음 generation 열기가 `input_purged`로 막힌다. 감사가 PGlite와 PostgreSQL 18에서 재현했다(봇 저장소 `docs/ai-bot/V1_RELEASE_REPORT.md` "A09", 비공개 ops `evidence/release-audit-2/`).

이 구조는 원래 artifact 정리에 있었고 T27·T31이 지우는 범위를 넓혔다.

## 할 일

1. 부모 행을 잠근 뒤 선정 조건 전체(현재 generation의 끝 상태와 기준 시각이 cutoff 이전, 미확정 effect 없음, 진행 중 자식 job·정리 전 세션 없음, 지울 것이 남음)를 같은 트랜잭션에서 다시 확인하고 맞을 때만 지운다.
2. 감사 재현을 시험으로 고정한다(오래된 후보 → 새 generation → 다시 끝 → 정리: 새 데이터가 남고, 새 종료 시각+7일에는 지워짐). PGlite와 실제 PostgreSQL 두 연결. `observing_deploy` 상태 변경, 새 미정리 자식 job 경합도.
3. 같은 모양의 다른 정리(T31 `raw-text-retention`, T27 질문 답)는 한 문장 UPDATE 안에서 조건을 보는지 확인한다.
4. 봇 PR, 운영 배포, 봇 `DECISIONS.md`·`VERIFICATION.md` 기록.

## 완료 조건

- A09 재현 시험이 새 코드에서 새 generation 데이터를 지우지 않고, 기존 보존 시험이 통과한다.
- 배포 뒤 A09와 DATA-02를 다시 검증한 결과가 봇 `VERIFICATION.md`와 [../approvals.md](../approvals.md)에 있다.

## 검증

`04` §4 DATA-02(원문 수명). 결과는 T21 재검증이 판정한다.
