# C05 관리 CLI `homelab bot`

- 단계: 1 기반
- 상태: integrated (봇 #115 병합 `cad247e`, homelab #1216 병합 `03971f9`, 운영 확인 2026-11-10. 차단·unknown 해제·멈춘 작업 재개는 C32로 나눔)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.3(동작 목록의 관리 기능 행), §4.8(관리 기능, ARCHITECTURE 계약 변경), §5 AC-20 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C01
- 연결 AC: AC-20
- 수행: 에이전트 + 사람(운영 확인: 봇 배포 뒤 승인받고 운영 1회 실행)
- 저장소·PR: 봇 PR → homelab PR (봇 이미지가 운영에 배포된 뒤 homelab PR을 병합한다)
- 파일 소유:
  - 봇: 새 관리 진입점(예: `src/admin-main.ts`와 명령 처리 모듈, 이름은 구현 때 정함) 소유. 기존 처리 경로를 부르기만 한다: `src/store.ts`(`control`의 `emergency-stop`·`resume-model`·`model-status`, `audit`. 연결 파일, 소유 C04(README 5절). 시그니처를 바꾸지 않는다), `src/policy.ts`(거부 목록 `denied_actors`. 표에 없는 공유 파일, C01도 고침), 작업 레인 해제 `src/claude-task-bridge.ts`·`src/codex.ts`의 `release`(연결 파일, 소유 C09. 시그니처를 바꾸지 않는다). `docs/ai-bot/ARCHITECTURE.md` §6 "허용 목록 반영"의 "즉시 철회 명령의 경계" 문단은 이 티켓이 고친다(추가만 규칙의 예외, 명세 4.8이 지정). 시험 `test/revoke-dispatch.test.ts`·`test/revoke-dispatch-pg.test.ts` 계열과 새 관리 진입점 시험.
  - homelab: `cli/` `homelab bot` 명령 묶음 소유(연결 파일, 뒤에 C22 `account add/use/list`, C23 `--by api`가 더한다). 새 명령 파일(예: `cli/src/commands/bot.ts`), 등록 `cli/src/registry.ts`, 봇 파드 exec 도우미(`cli/src/core/podops.ts`, 문맥 타입 `cli/src/core/command.ts`, 조립 `cli/src/core/runtime.ts`), 시험 `cli/test/commands/` 새 파일과 `cli/test/stub.ts` 필요분, 안내 `cli/README.md`, 설계 `docs/plans/2026-10-17-homelab-rebuild/platform/design.md` C.7 명령 표 행. 공유 파일(README 5절에 반영): `cli/src/core/podops.ts`·`command.ts`·`runtime.ts`, `cli/README.md`, design C.7 표(C22·C23도 고침).
- 설계 계약:
  - 봇 관리 진입점: ARCHITECTURE §6 "보안 경계"의 "허용 목록 반영(F01, AUTH-02)" 문단(즉시 철회의 경계, `revocationRestores` 해제 규칙), §11 "조회·예산·작업자 제어", §12 "작업 정리와 `unknown` 막힘" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 3, "작업 레인 unknown과 비상 중지 (사용자 2026-11-05)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - 봇 `src/store.ts`·`src/policy.ts`·작업 레인 `release`: 같은 §6·§11 절. 시그니처 불변.
  - homelab `cli/`: [design.md](../../2026-10-17-homelab-rebuild/platform/design.md) C.7 "CLI와 운영 경험"(얇게, `plan` 기본·`--apply`, `kubectl exec`는 쓰기로 판정, 명령 경계의 위협 모델, 재실행 안전), [cli/README.md](../../../../cli/README.md) "동작 규칙"·"명령 더하기". 봇 파드 대상은 design C.8 "봇 저장소"(ns `app-homelab-bot`, 앱 `homelab-bot`).

## 목표

owner가 대화와 섞지 않고 클러스터 접근 권한으로 `homelab bot <명령>`을 실행해 비상 정지, 해제(비상 정지·모델 멈춤), 차단(거부 목록 추가만), 상태 보기, unknown 해제를 한다. 이 명령은 모델을 거치지 않고, 감사 기록의 행위자는 CLI다. 시범 동안 같은 '/' 관리 명령도 그대로 동작한다. 봇 PR은 병합하면 바로 운영 이미지에 들어가지만 진입점은 CLI가 부를 때만 돈다.

## 할 일

1. 봇 관리 진입점: 이미지 안에서 `node`로 직접 실행하는 진입점을 둔다. 명령은 비상 정지, 해제(대상: 비상 정지 또는 멈춘 작업), 차단(대상 사용자 ID를 거부 목록에 더하기만), 상태 보기(`model-status`가 돌려주는 내용과 같음), unknown 해제(`task-release`와 같은 작업자 소멸 확인). 기존 저장소·작업 레인 함수를 부르고 시그니처를 바꾸지 않는다. 기존 함수가 owner 행위자·대화 ID를 요구해 CLI 행위자로 부를 수 없으면, 바꾸지 말고 그 함수와 필요한 변경을 결과에 적고 lead에 알린다.
2. 진입점 경계: 입력은 고정 명령과 형식 검사를 거친 ID만 받는다. 모델·작업자를 부르지 않는다. 차단은 거부를 더하기만 하고 해제 경로는 없다(해제는 지금처럼 Infisical `revocationRestores` 절차). 감사에 행위자 `cli`를 남긴다. 출력은 고정 문구와 상태 값뿐이고 비밀·원문을 싣지 않는다.
3. 봇 `ARCHITECTURE.md` §6 "즉시 철회 명령의 경계"를 "클러스터 접근 권한으로 도는 CLI 관리 명령, 모델을 거치지 않고 거부를 더할 수만 있다"로 고치고, 시범 동안 '/' 관리 명령이 예비로 남는다고 적는다. §14 "연결 지점" 표에 진입점 행을 더한다.
4. T21 AUTH-02 관련 항목을 다시 검증한다: 차단이 ESO 동기화 전에 효력이 있는지, 해제가 `revocationRestores` 규칙대로만 되는지, '/' 경로가 그대로인지. 로컬 시험 결과를 봇 `VERIFICATION.md`에 적는다.
5. homelab CLI: `homelab bot` 명령 묶음을 더한다. 봇 파드는 레이블로 찾고(ns `app-homelab-bot`), `kubectl exec`로 진입점을 위치 인자로 넘겨 실행한다(셸 문자열에 끼우지 않음, `podops.ts`의 기존 방식). 잘못된 ns·파드 대상이면 실행 전에 멈춘다.
6. 판단 필요(구현 전에 lead에 확인): design C.7은 `kubectl exec`를 쓰기로 판정해 `plan`에서 돌리지 않는다. 그래서 상태 보기도 `--apply`가 필요한지, 읽기 허용 exec 한 종류를 따로 둘지 정한다. 정한 것을 design C.7과 `cli/README.md`에 적는다.
7. 시험: homelab `cli/test` 가짜 kubectl(S3)로 명령별 argv, `plan`에서 쓰기 0, 잘못된 대상 거부. 봇 쪽 진입점 시험(S1)으로 차단이 거부만 더함, 모델 호출 0, 감사 행위자 `cli`, '/' 관리 명령 동작 유지.
8. 운영 확인(사람): 봇 PR이 운영에 배포된 뒤 owner 승인을 받고 상태 보기 1회와 영향 없는 명령 1회(예: 비상 정지가 없을 때의 해제 응답)를 실행해 결과를 [approvals.md](../../2026-10-17-homelab-rebuild/approvals.md)와 봇 `VERIFICATION.md`에 적는다. 운영 차단·비상 정지 실행은 owner가 따로 정한다.
9. 기록: 봇 `VERIFICATION.md`에 "C05 관리 CLI" 절, `DECISIONS.md` "동료 봇 전환" 3에 구현 위치 한 줄. homelab design C.7 표에 `homelab bot` 행, `cli/README.md`. 이 계획 폴더 `README.md`의 C05 상태 줄 갱신.

## 완료 조건

- [x] `homelab bot`으로 비상 정지, 해제(비상 정지), 상태 보기가 된다(AC-20). 차단·unknown 해제·멈춘 작업 재개는 C32.
- [x] 관리 기능은 모델을 부르지 않고, 상태를 바꾼 명령은 감사 `admin_command`에 행위자 `cli`가 남는다(AC-20). 차단의 거부만 더하기는 C32.
- [x] 시범 동안 같은 '/' 관리 명령도 동작한다(AC-20).
- [x] 봇 ARCHITECTURE §6 계약이 CLI 관리 명령으로 바뀌고, AUTH-02 재검증 결과가 `VERIFICATION.md`에 있다.
- [x] 운영 1회 확인이 `approvals.md`에 있다.

## 검증

- 경계: S3(homelab CLI, 가짜 kubectl)와 S1(봇 관리 진입점). 앞선 시험 예: homelab `cli/test`의 `secret set`, 봇 `revoke-dispatch`, `revoke-dispatch-pg`. 운영 1회는 S5.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험. homelab `pre-commit run --all-files`, `bun run ci`.
- 잡는 실패 / 못 잡는 범위: 잡는 것은 잘못된 파드·네임스페이스 대상, 차단이 거부 아닌 다른 변경을 하는 것, 감사 누락, `plan`의 쓰기다. 못 잡는 범위: 운영 클러스터 권한과 실제 파드 exec(S5 운영 1회가 본다).

## 결과

- 봇 PR #115(`feat/colleague-c05-admin-cli`, 결과 head `b4fcbe4`), 병합 `cad247e`. homelab PR #1216(`feat/colleague-c05-homelab-bot-cli`, head `ea5c54d`), 병합 `03971f9`(2026-11-10, 사용자 "진행해").
- 구현: 봇 `src/admin.ts`(고정 동작 단어, UUID·snowflake 형식만, `Store.control`을 대화 자리 `admin:cli`로 불러 상태 확인과 바꾸기를 한 트랜잭션에서, 상태를 바꾼 명령만 감사 `admin_command` 행위자 `cli`), `src/admin-main.ts`(`DATABASE_URL`만 읽음, stdout은 `homelab-bot-admin/v1` JSON 한 줄, 오류 로그는 stderr — Codex P2 반영). homelab `cli/src/commands/bot.ts`와 `core/podops.ts`의 `botRead`·`botWrite`(ns `app-homelab-bot`, Running·Ready 게시 서버 파드 정확히 1개, `kubectl exec … -c app -- node /app/dist/src/admin-main.js <동작> [ID]`, 위치 인자, 출력 꼴 검사). 설계 C.7대로 `kubectl exec`는 쓰기로 판정해 모든 명령이 `--apply`일 때만 실행.
- 완료 조건 근거: 봇 `test/admin-cli.test.ts` 10건(비상 정지·해제·상태 보기, '/' 경로와 같은 상태, 모델 호출 0, 감사 행위자, 사용법 64·미지원 4, 실패해도 stdout 한 줄), 기존 `foundation` OPS-01·AUTH-02. homelab `cli/test/commands/bot.test.ts` 8건(가짜 kubectl), `bun run ci` 30단계.
- 검사: 통합 담당 전체 검사(`b4fcbe4`, node 24.22.0, 실제 PG, 잠금): 2221 tests / 2199 pass / 0 fail / 22 skip. Codex 1차 P2 1 수정 뒤 지적 없음.
- 운영 확인(2026-11-10 10:2x, `KUBECONFIG=~/.kube/homelab.yaml`, homelab main 소스 `bun run cli -- bot …`): `bot status` plan → `--apply` 결과 `status (emergency=false, paused=false, executionPending=false, taskLaneClosed=none)`, `bot resume emergency-stop --apply` 결과 `not_stopped`(상태 변화 없음, 감사 행 없음은 설계대로). 진입점 경로 `/app/dist/src/admin-main.js`·컨테이너 `app`·owner kubeconfig의 `pods/exec` 권한 확인.
- 나눈 것: 차단(`PolicyGate.revoke`가 owner 행위자 요구), unknown 해제(`TaskBridge.releasable`이 owner·대화 대조), 멈춘 작업 재개(`Store.control resume-model <job>`이 owner·대화·구독 요구)는 C32(사용자 2026-11-10). 그때까지 진입점은 셋에 미지원(종료 4)으로 답하고 '/' 명령이 예비다.
- 남은 것: 상태 보기에서 대화에 묶인 대기 작업 목록은 빠진다. 설치된 `homelab` 바이너리는 다시 빌드해야 `homelab bot`이 생긴다(그때까지 소스 실행).
