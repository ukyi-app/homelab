# T26 봇 권한 철회와 Discord 발송 시작의 순서

- 단계: P4 후속 (T21 1회차 감사에서 나옴, 출시 차단)
- 상태: 완료 (2026-11-07. 봇 #90 `f83afd4`, 배포 homelab #1175. 철회가 먼저 커밋되면 Discord REST 0, 실제 PostgreSQL 두 연결 시험으로 확인)
- 명세: [../spec.md](../spec.md)
- Blocked by: 없음
- 연결 AC: AC-B8 (AUTH-02, F01·F04·F09·R01)
- 수행: 에이전트

## 목표

`/revoke`가 끝난 뒤에도 이미 권한 확인을 지난 Discord 발송이 시작될 수 있다. T21 1회차 감사 A02(봇 저장소 `docs/ai-bot/V1_RELEASE_REPORT.md`, 결함 후보 FIX-02)다. 철회가 먼저 끝났으면 발송을 시작하지 않도록 두 동작의 순서를 정하고 집행한다.

## 메모

- 위치(봇 `dda891f`): `src/discord.ts` `DiscordPublisher.deliver`는 `authorized`(여기서만 `denied_actors` 확인) → `scheduled` → `discordPauseUntil` → `store.dispatchDelivery` → REST 순서다. `dispatchDelivery`(`src/store.ts`)는 lease와 state만 CAS하고 철회를 다시 보지 않는다. `PolicyGate.revoke`(`src/policy.ts`)는 `denied_actors`에 행을 넣기만 한다.
- 창은 DB 왕복 몇 번이다. 사후 confirm의 ACL 검사로 outbox는 `unknown`이 되지만, 이미 나간 메시지는 회수하지 못한다.
- 봇 #86은 GitHub writer 경로에 전송 직전 재인가를 넣었다. Discord 경로에는 없다. T19 넘긴 항목 "즉시 중단은 `/revoke`"는 Discord에서 지금 보장되지 않는다.
- 이미 시작한 외부 요청은 취소할 수 없다. 그 한계는 문서로 남긴다.

## 할 일

1. 철회와 발송 시작의 기준점을 정한다. 예: `dispatchDelivery` CAS에 최신 철회·대화 상태 조건을 넣거나, 철회와 dispatch가 같은 잠금을 잡는다.
2. message·thread·예약 사본, 다른 대화에서 owner 철회, 실제 PostgreSQL 두 연결의 경합에서 철회가 먼저 끝나면 REST 호출 0을 시험한다. 재시작·`unknown` 회귀도 본다.
3. 봇 저장소 PR, 운영 배포, 봇 `VERIFICATION.md` 기록.

## 결과 (2026-11-07)

- 봇 #90 `f83afd4`(구현은 Claude 작업자, Codex 코드·보안 리뷰 지적 없음). 기준점은 `Store.dispatchDelivery`의 UPDATE 한 문장이다. lease와 함께 `denied_actors`(owner)·대화 소유자·구독·gap을 보고, 철회·대화 거부는 같은 문장에서 `blocked`로 닫는다. 상호작용 응답·리액션·대체 게시는 철회 조회를 REST 전 마지막 DB 읽기로, typing은 REST 직전 재조회에 철회 조건을 넣었다. 읽기 전용 REST와 기동 때 명령 등록은 쓰기가 아니거나 사용자와 무관해 그대로 둔다.
- 시험: `revoke-dispatch` 16/16(PGlite), `revoke-dispatch-pg` 5/5(PostgreSQL 두 연결), 고치기 전 코드에서는 새 시험 16개 실패. 관련 기존 시험 719개 통과, 전체 2,106 중 실패 0(PG). main(T25)과 합친 트리 전체에서 `external-task-pg` R08 동시 시험 1건이 실패했고 단독 8/8 통과라 부하 간헐로 분류했다(원인 미확정).
- 한계: 그 문장 뒤에 커밋된 철회는 이미 시작한 요청을 되돌리지 못한다(outbox는 `unknown` 뒤 대조로 `blocked`). 상호작용 응답·typing은 영속 표시가 없어 조회와 fetch 사이 짧은 창이 남는다. 봇 `ARCHITECTURE.md`에 적었다.
- 배포: homelab #1175, 파드 1/1 Ready·imageID 일치, 재시작 뒤 게이트 open·로그 오류 0. 기록은 봇 저장소 `docs/ai-bot/VERIFICATION.md` "T21 출시 차단 수정 T25·T26". AUTH-02 재판정은 T21 재실행.

## 완료 조건

- 철회가 발송 시작보다 먼저 커밋되면 Discord REST 호출이 0이다.
- 감사 재현(ops `evidence/release-audit/` `audit-probes.mjs`의 A02)이 막힌다.
- 이미 시작한 요청의 한계가 봇 `ARCHITECTURE.md`에 적혀 있다.

## 검증

`04` §4 AUTH-02.
