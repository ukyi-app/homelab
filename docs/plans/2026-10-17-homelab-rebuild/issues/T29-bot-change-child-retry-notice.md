# T29 봇 CHANGE 자식 실패 안내의 복구 명령

- 단계: P4 후속 (T21 1회차 감사에서 나옴, 현 버전 필수 수정)
- 상태: 완료 (2026-11-07. 봇 #93 `d014c0e`, 배포 homelab #1179. CHANGE 자식 실패 안내에 `/retry` 없음)
- 명세: [../spec.md](../spec.md)
- Blocked by: 없음
- 연결 AC: AC-B8 (R03·R13)
- 수행: 에이전트

## 목표

CHANGE 자식 작업이 실패하면 일반 실패 안내가 "/retry로 재시도"를 권한다. 그런데 `/retry`는 CHANGE 자식을 되살리지 않고 거부한다. 같은 실패에 CHANGE 부모는 새 `/change`를 요구하는 다른 안내를 보낸다. T21 1회차 감사 A06(봇 저장소 `docs/ai-bot/V1_RELEASE_REPORT.md`, 결함 후보 FIX-05)이다. 안내를 실제로 가능한 복구 명령에 맞춘다.

## 메모

- 위치(봇 `dda891f`): `src/store.ts`의 `fail`(실패 outbox 문구)과 retry UPDATE(`change_child_jobs`가 있는 행 제외), `src/change-runtime.ts`의 부모 안내.
- 자식을 되살리지 않는 보호 조건 자체는 맞다. 문구만 틀렸다.

## 할 일

1. CHANGE 자식 실패는 부모 상태와 새 요청·세대 안내를 쓰고, 일반 작업만 `/retry`를 제시한다.
2. 실제 자식 실패 알림에서 불가능한 명령을 권하지 않는 회귀 시험을 둔다.
3. 봇 저장소 PR, 운영 배포.

## 결과 (2026-11-07)

- 봇 #93 `d014c0e`(구현은 Claude 작업자). `Store.fail`이 `change_child_jobs`를 보고 자식이면 `/change-status`와 새 `/change` 안내를 보낸다. 부모·자식 문구는 `src/change-advice.ts` 한 곳.
- `/retry`를 권하는 안내 셋 중 자식에게 나가는 것은 `Store.fail` 하나였다(`resolveUnknown`은 chat·review만, T25 질문 차단 안내는 CHANGE 경로 밖). `/resume-model` 안내도 자식에게 나갈 수 있으나 그 명령은 자식을 거부하지 않는다(재개 뒤 CHANGE 흐름은 확인하지 않음).
- 시험: 새 시험 "A06 자식 실패 안내…" 통과, `change-assembly` 115/115, `unknown-probe` 15/15, main(T28)과 합친 전체 2,116 중 실패 0(PG). 기록은 봇 저장소 `docs/ai-bot/VERIFICATION.md` "T21 현 버전 필수 수정 T27·T28·T29".

## 완료 조건

- CHANGE 자식 실패 안내에 `/retry`가 없고, 안내한 명령이 실제로 동작한다.
- 감사 재현(ops `evidence/release-audit/` `retry-probe.mjs`)이 바뀐 안내를 보인다.

## 검증

`04` §4 CHANGE-01(실패 안내 하위 사례), CHAT-02.
