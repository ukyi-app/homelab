# T20 봇 MEMORY_BRIEFING

- 단계: P4 봇 V1
- 상태: 착수 가능 (선행 T16a 완료 2026-10-20. 로컬·mock 구현부터, 완료는 T16b 뒤)
- 명세: [../spec.md](../spec.md)
- Blocked by: T16a(착수), T16b(완료)
  - 착수: [T16a](T16a-bot-foundation-local.md) 뒤. 이 티켓을 실제로 막는 FOUNDATION의 예약 기능을 T16a가 로컬·mock으로 만든다(V1 범위 조정 안 3).
  - 완료: [T16b](T16b-bot-foundation-deploy.md) 뒤. 브리핑을 실제 D-17 브리핑 채널로 보내는 시험(BRIEF-01 `authorized_external`)은 배포된 봇이 필요하다.
- 선행 결정: D-17 (확정(사용자 2026-10-18, T15): 브리핑은 알림·리뷰·브리핑 채널. 브리핑 시각은 매일 08:50 Asia/Seoul(확정(사용자 2026-10-20, T16a)))
- 연결 AC: AC-B7
- 수행: 개발 에이전트 (`STAGE=MEMORY_BRIEFING`)

## 목표

`01` §8: 출처 기반 기억과 일일 브리핑 (R16~R18).

## 메모

`01`의 권장 순서는 CHANGE_PR 뒤지만, 실제로 막는 것은 FOUNDATION의 예약 기능뿐이다. 그래서 T17·T18과 병행할 수 있다. 예약 기능은 T16a가 만든다. 브리핑에 넣는 Codex 작업 상태와 승인·질문 대기(`01` §8 일일 브리핑)는 T18이 끝난 뒤 연결한다.

DATA-02: 봇 DB는 공유 PostgreSQL 백업(14일 보존, spec §5.1 "설계 기본값")에 들어간다. 삭제한 기억도 14일 동안 백업에 남을 수 있으므로 삭제 표식은 복원 대상 밖의 삭제 원장(예: R2 append-only 객체)에 두고, 원장 기록이 확인된 뒤에만 삭제 완료로 응답하며, 기동 때 원장의 삭제를 다시 적용한다. 기억 ID는 재사용되지 않는 값으로 두고 원장에 `created_at`을 함께 둔다 [가정: 봇 저장소 `ARCHITECTURE.md` §7 제안, PR #3 Codex 리뷰 반영]. 원장을 R2에 두면 `/apps/homelab-bot/`에 자격이 하나 는다.

## 완료 조건

- `04` §4 시험 MEM-01, BRIEF-01, DATA-02, AUTH-02 결과가 있다 (spec §7 AC-B7).
- spec §7 "단계 AC 공통 완료 규칙"을 따른다. 배정된 시험에 `fail`이 없다. `blocked`·`not_run`은 사유와 해소 티켓을 함께 적는다. 이 단계에 배정된 보안 경계 시험은 없다.
- HANDOFF가 있다.

## 검증

`04` §4 시험.
