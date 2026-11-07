# T27 봇 작업 답·변경 요청 원문의 보존과 삭제

- 단계: P4 후속 (T21 1회차 감사에서 나옴, 현 버전 필수 수정)
- 상태: 완료 (2026-11-07. 봇 #94 `630c48d`, 배포 homelab #1179. 두 원문 7일 정리, digest·영수증 유지. 다른 원문 칸은 T31)
- 명세: [../spec.md](../spec.md)
- Blocked by: 없음
- 선행 결정: 할 일 1 (확정(사용자 2026-11-07): `codex_questions.answer`와 `change_request_inputs.text` 모두 7일. digest·영수증은 남긴다. CHANGE artifact·리뷰 원문과 같은 기간)
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
   - 결과(2026-11-07, 사용자 결정): 두 원문 모두 7일, digest·영수증은 남긴다. 진행 중·`unknown` 예외와 복원 때 재적용은 구현에서 정하고 기록한다.
2. 정리 경로를 구현한다. cutoff 전후, 재개·`unknown`, 중복 정리, 복원 뒤 삭제된 원문이 다시 보이지 않는지 시험한다.
3. 봇 저장소 PR, 운영 배포, 봇 `ARCHITECTURE.md`·`VERIFICATION.md` 기록.

## 결과 (2026-11-07)

- 봇 #94 `630c48d`(구현은 Claude 작업자, lead가 두 가지 고침: `publisher-pg` 시험의 고정 migration 목록, Codex P2에 따라 정리를 레인 루프 밖으로). migration 019는 칸만 더한다. 요청 원문은 끝난 변경 요청 기준으로 `text=''`·`purged_at`, 답은 끝난 작업 기준(`COALESCE(finished_at, answered_at, created_at)`)으로 `answer=NULL`·`answer_purged_at`·`answer_sha256`. 두 정리(`change_retention`, `task_answer_retention`, 1시간)는 게시 서버가 뜨면 레인 스위치와 무관하게 돈다. 원문을 지운 superseded 변경의 `text:next`는 `input_purged`로 거절한다.
- 예외와 한계: 끝나지 않은 작업과 재개 가능한 세션의 답은 남긴다. 대기 세션을 가진 `failed` 작업의 답과 끝나지 않는 변경 요청의 원문은 7일을 넘길 수 있다. 복원 뒤 원문이 다시 보이는 창은 다음 정리까지 최대 1시간, 백업 속 원문은 14일.
- 시험: `raw-input-retention` 7/7(실제 PG 포함), 감사 A03 조건에서 두 원문이 남지 않음, main과 합친 전체 2,123 중 실패 0(PG). Codex 최종 head 지적 없음.
- 원문을 담는 다른 칸(`events.payload.text` 등 다섯)은 정리 경로가 없다. 사용자 결정(2026-11-07)으로 [T31](T31-bot-raw-text-retention.md)에 넘겼다.
- 기록은 봇 저장소 `docs/ai-bot/VERIFICATION.md` "T21 현 버전 필수 수정 T27·T28·T29", 결정은 `DECISIONS.md` "T27".

## 완료 조건

- 두 원문에 보존 기간과 정리 경로가 있고, 기간이 지나면 원문이 지워진다. 증거 digest는 남는다.
- 결정이 [../approvals.md](../approvals.md)와 봇 `DECISIONS.md`에 있다.

## 검증

`04` §4 DATA-02(원문 수명 하위 사례).
