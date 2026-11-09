# T32 봇 CHANGE 정리의 선정 조건 재확인 (T21 2회차 A09)

- 단계: P4 후속 (T21 2회차 감사에서 나옴)
- 상태: 완료 (2026-11-09. 1차 봇 #104 `4a10f3c`, 2차 봇 #106 `772599f`, 배포 homelab #1200·#1202. T21 4회차 A09 fixed·DATA-02 pass)
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

## 결과 (2026-11-09)

- 1차(봇 #104 `4a10f3c`, 배포 homelab #1200): 부모 행을 `FOR UPDATE`로 잠근 뒤 선정 조건 전체(`changePurgeDue`)를 그 id로 다시 보고 맞을 때만 지운다. `linkChildJob`은 부모를 `FOR SHARE`로 잡는다. 같은 모양의 T31 네 칸과 T27 질문 답 정리는 UPDATE 한 문장이라 해당 없음.
- T21 3회차 감사: 원래 경합은 해소됐지만 A09 `partially_fixed`. 정리 제외 조건이 정리 전 세션을 진행 중 상태와 `cleanup_state='pending'`으로만 알아봐서, 세션이 `completed`로 커밋된 뒤 pending이 붙기 전 틈(`session_retained=true`)에 7일 지난 변경을 지우고 다음 generation을 `input_purged`로 막았다(PostgreSQL 두 연결).
- 2차(봇 #106 `772599f`, 배포 homelab #1202): 제외 조건에 `session_retained`를 더했다. retained는 작업자 정리를 확인한 뒤에만 false가 되고 true가 되는 곳은 세션 시작뿐이라 재검사 뒤 뒤집히지 않는다. `change-purge-race` 11/11, 전체 2,147 중 실패 0.
- T21 4회차 감사: A09 fixed, DATA-02 pass, 판정 `READY_FOR_SCOPED_PILOT`. 남은 조건: 작업자 정리를 끝내 확인하지 못한 세션의 변경 원문은 7일을 넘겨 남는다(pending과 같은 성질, retained·cleanup 지표로 보임).
- 같이 고친 것: 봇 #105(`1835f11`, 시험만). `codex-bridge` hang 시험이 빈 `env.json`을 읽던 경합(main `1079cb4` 빌드 실패).
- 기록: 봇 `VERIFICATION.md` "T32 CHANGE 정리의 선정 조건 재확인", `DECISIONS.md` "CHANGE 정리의 선정·삭제 경합", 감사 증거는 private `homelab-bot-ops` `evidence/release-audit-3/`·`release-audit-4/`.
