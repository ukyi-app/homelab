# C32 관리 CLI 나머지 동작(차단·unknown 해제·멈춘 작업 재개)

- 단계: 1 기반
- 상태: integrated (봇 #122 병합 `d353fc0`, homelab #1226 병합 `aef553c`, 운영 확인 2026-11-10)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.3(동작 목록의 관리 기능 행), §4.8(관리 기능), §5 AC-20 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C04, C05, C09
- 연결 AC: AC-20(C05와 함께)
- 수행: 에이전트 + 사람(운영 확인: 영향 없는 대상 1회)
- 저장소·PR: 봇 PR (homelab `homelab bot`은 C05가 다섯 동작을 이미 받으므로 바꾸지 않는다)
- 파일 소유:
  - 봇 관리 진입점 `src/admin.ts`·`src/admin-main.ts`(C05가 만든 연결 파일. 이 티켓이 미지원으로 막아 둔 세 동작을 연다. 뒤에 C22가 계정 명령을 더한다).
  - 연결 파일, 소유 C04: `src/store.ts`에 CLI 행위자용 관리 메서드를 더한다(멈춘 작업 재개: 작업 ID만으로, owner·대화·구독 대조 없이, 감사 행위자 `cli`). 기존 `control`·`controlLocked` 시그니처와 '/' 경로는 바꾸지 않는다.
  - 공유 파일: `src/policy.ts`에 관리용 거부 더하기(정책 revision만 읽고 실패하면 닫힘, 거부 행만 더함, 해제 경로 없음). 기존 `PolicyGate.revoke`·`authorize`는 바꾸지 않는다.
  - 연결 파일, 소유 C09: 작업 브리지 `src/task-bridge.ts`(`releasable`)·`src/claude-task-bridge.ts`·`src/codex.ts`(`release`)에 작업 ID만으로 같은 작업자 소멸 확인을 거치는 관리용 해제 경로를 더한다. 기존 owner 경로와 시그니처는 그대로.
  - 시험: `test/admin-cli.test.ts`, `test/revoke-dispatch.test.ts`·`test/revoke-dispatch-pg.test.ts` 계열, 작업 브리지 해제 시험(`task-bridge`·`codex-bridge`·`claude-task-bridge` 해당분).
  - 봇 `docs/ai-bot/ARCHITECTURE.md`(§6 "즉시 철회 명령의 경계", §14 "연결 지점"의 관리 진입점 행)·`VERIFICATION.md`·`DECISIONS.md`는 추가만.
- 설계 계약:
  - 관리 진입점·`policy.ts`·`store.ts`: 봇 ARCHITECTURE §6 "보안 경계"의 "허용 목록 반영(F01, AUTH-02)" 문단(즉시 철회의 경계, `revocationRestores` 해제 규칙)과 C05가 고친 "즉시 철회 명령의 경계", §11 "조회·예산·작업자 제어" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 3, "C05 관리 CLI" 절(막아 둔 이유와 필요한 변경), "작업 레인 unknown과 비상 중지 (사용자 2026-11-05)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - 작업 브리지 해제: 봇 ARCHITECTURE §12 "작업 정리와 `unknown` 막힘"(작업자 소멸 확인 뒤에만 해제, fail-closed).
  - 결정: 이 티켓은 C05에서 나눴다(사용자 2026-11-10 "진행해", homelab `approvals.md`).

## 목표

owner가 `homelab bot block <사용자 ID>`, `homelab bot release <작업 ID>`, `homelab bot resume job <작업 ID>`를 실행하면 봇이 지금 '/revoke'·'/task-release'·'/resume-model'과 같은 효과를 CLI 행위자로 낸다. C05는 이 셋을 기존 함수가 Discord owner 행위자·대화를 요구해 미지원(종료 4)으로 막아 두었다. 이 티켓이 관리용 경로를 더해 연다. 동료 기능 켜짐 판 문구(C09)가 unknown 해제·멈춘 작업 재개를 이 CLI로 안내하므로 C24(스위치 켜기) 전에 끝나야 한다.

## 할 일

1. 차단: 정책 revision만 읽어(읽기 실패면 닫힘) 대상 사용자 ID를 거부 목록 행으로 더한다. 이미 있으면 재실행 안전(같은 결과, 상태 변화 없음). owner 자신도 막을 수 있어야 하므로 owner 대조를 하지 않는다(기존 `PolicyGate.revoke`를 owner ID로 부르면 owner가 이미 거부된 뒤 재실행이 `Denied`로 깨진다, C05 보고). 해제 경로는 없다(지금처럼 Infisical `revocationRestores`). ESO 동기화 전에 효력이 있는지 시험한다(AUTH-02).
2. unknown 해제: 작업 ID만으로 기존 `release`와 같은 작업자 소멸 확인을 거친다(확인 못 하면 해제하지 않음). owner·대화 대조는 하지 않고 감사 행위자는 `cli`다. Claude·Codex 두 브리지 모두.
3. 멈춘 작업 재개: 작업 ID만으로 모델 멈춤(`waiting_user`의 한도·인증 대기) 작업을 재개한다. 구독 상태·대화 대조 없이, 그 작업이 실제로 그 대기 상태일 때만. 비상 정지 해제는 C05 그대로.
4. 관리 진입점(`src/admin.ts`): 세 동작의 미지원 분기를 지우고 위 경로를 부른다. 상태 확인과 바꾸기를 한 트랜잭션에서 하고, 결과 이름(`blocked`·`already_blocked`·`released`·`not_releasable`·`resumed`·`not_waiting` 등)은 homelab CLI(`cli/src/core/podops.ts` `BOT_RESULTS`)가 받는 집합 안에서 정하거나, 새 이름이 필요하면 homelab 쪽 집합도 같은 순서로 넓히는 PR을 따로 낸다(봇 PR 배포 뒤 병합). 감사 `admin_command`에 행위자 `cli`.
5. '/' 경로 유지: '/revoke'·'/task-release'·'/codex-release'·'/resume-model'이 그대로 동작하고 같은 상태를 본다.
6. 시험(S1): 각 동작의 정상·재실행 안전·대상 없음·잘못된 상태, 모델 호출 0, 감사 행위자 `cli`, 차단 뒤 그 사용자 이벤트 거부(ESO 동기화 전), unknown 해제는 소멸 확인 실패 때 해제하지 않음, 실제 PostgreSQL 경합(같은 작업에 '/' 해제와 CLI 해제가 겹쳐도 한 번).
7. 운영 확인(사람 승인 뒤): 영향 없는 대상으로 한 번씩(예: 없는 작업 ID의 해제·재개 → `not_releasable`·`not_waiting`). 실제 차단은 owner가 따로 정한다.
8. 기록: 봇 ARCHITECTURE §6·§14, `VERIFICATION.md` "C32 관리 CLI 나머지 동작" 절, `DECISIONS.md` "C05 관리 CLI" 절 뒤에 구현 위치. 이 계획 폴더 `README.md`의 C32 상태 줄 갱신.

## 완료 조건

- [x] `homelab bot block`·`release`·`resume job`이 '/' 경로와 같은 효과를 CLI 행위자로 낸다(AC-20).
- [x] 차단은 거부만 더하고 모델을 부르지 않으며, 감사에 행위자 `cli`가 남는다(AC-20).
- [x] unknown 해제는 작업자 소멸을 확인하지 못하면 해제하지 않는다.
- [x] '/' 관리 명령이 그대로 동작한다.
- [x] 운영 1회 확인이 `approvals.md`에 있다.

## 검증

- 경계: S1(봇 관리 진입점·저장소·작업 브리지, 실제 PostgreSQL 포함). 앞선 시험 예: `admin-cli`, `revoke-dispatch`, `revoke-dispatch-pg`, 작업 브리지 해제 시험. 운영 1회는 S5.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험. 전체 `npm test`는 통합 담당.
- 잡는 실패 / 못 잡는 범위: 잡는 것은 차단이 거부 아닌 변경을 하는 것, 소멸 확인 없는 해제, 대기 상태가 아닌 작업의 재개, 감사 누락, '/' 경로 회귀다. 못 잡는 범위: 운영 클러스터 권한과 실제 작업자 프로세스(S5 운영 1회).

## 결과

- 봇 PR #122(`feat/colleague-c32-admin-cli-remaining`, head `edb60cb`), 병합 `d353fc0`. homelab PR #1226(`feat/colleague-c32-homelab-bot-results`, head `2d925e8`, 새 결과 이름), 병합 `aef553c`(봇보다 먼저, 옛 이미지에 영향 없음).
- 구현: 봇 `src/admin.ts`·`src/admin-main.ts`(미지원 분기 제거, `AdminPorts`, 차단 때만 `RUNTIME_POLICIES`, 해제 때만 게시 서버 설정을 읽음), `src/policy.ts` `PolicyGate.deny`(행위자 대조 없이 거부 행만, 이미 있으면 그대로, `revocationRestores`의 옛 거부만 새로), `src/store.ts` `Store.adminResumeJob`, 작업 브리지 `adminRelease`(같은 소멸 확인·해제 CAS, 감사 행위자 인자). homelab `cli/src/core/podops.ts` `BOT_RESULTS`에 `blocked`·`already_blocked`·`resumed`·`not_releasable`·`not_waiting`·`emergency_stopped`·`queue_full`, `cli/src/commands/bot.ts` 다음 행동 안내.
- 완료 조건 근거: 봇 `admin-cli` 18개(차단 거부만·모델 0·감사 `cli`·정책 못 읽으면 닫힘·ESO 동기화 전 효력, 해제 소멸 확인 못 하면 `running_jobs`, 재개 대기 상태일 때만), `task-bridge` 4개, `task-lane-pg`('/' 해제와 CLI 해제가 겹쳐도 한 번)·`revoke-dispatch-pg`. homelab `bot.test` 새 결과 이름 시험(빨강→초록).
- 검사: 봇 작업자 관련 11개 파일 436/436(실제 PG), 통합 담당 전체 검사(`edb60cb`): 2313 / 2291 pass / 0 fail / 22 skip. homelab `bun run ci` 30단계. 두 PR 모두 Codex 지적 없음·CI 통과.
- 운영 확인(2026-11-10 11:2x, homelab main 소스): `bot release <없는 ID> --apply` → `not_releasable`(다음 행동 안내, 상태 변화 없음), `bot resume <없는 ID> --apply` → `not_waiting`. 해제 경로가 운영 파드에서 게시 서버 설정을 읽어 브리지를 조립하는 것까지 확인. 실제 차단은 owner가 따로 정한다.
- 분해 불일치: 진입점이 읽는 env가 넓어졌다(차단 `RUNTIME_POLICIES`, 해제 게시 서버 설정, 그 밖은 `DATABASE_URL`만). Codex 브리지는 운영에서 조립되지 않아 그 `adminRelease`는 시험으로만. `/revoke`와 달리 CLI 차단은 이미 있는 거부 행을 덮지 않는다.
- 남은 것: VERIFICATION C05·C09 절의 "CLI가 아직 unknown 해제·재개를 받지 않는다" 문장은 통합 때 정리. `queue_full` 경로 미시험.
