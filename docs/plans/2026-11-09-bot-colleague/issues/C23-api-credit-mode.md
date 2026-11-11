# C23 API 크레딧 방식

- 단계: 5 멈춤과 계정
- 상태: 진행 중 (2026-11-11 09:5x 착수. C22는 코드가 모두 병합된 상태에서 사람 단계를 기다리지 않고 시작, 사용자 2026-11-11 "예")
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.8 "계정 등록"(API 크레딧)·"계정 전환"·"API 크레딧 방식"·"권장 Console 설정(사람)", §5 AC-22 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C06, C22
- 연결 AC: AC-22
- 수행: 에이전트 + 사람(Console 봇 전용 workspace와 API 키 발급, sandbox 배포 PR 승인, 운영 전환 1회)
- 저장소·PR: 둘(봇 PR → homelab sandbox 사람 PR(작업자 이미지 digest + 키 이름) → homelab CLI PR. 앞의 둘은 sandbox 값 주석의 규칙대로 같은 PR로 묶을 수 있다)
- 파일 소유:
  - 봇 `src/executor-profiles.ts`: API 키 방식 프로필(또는 실행마다 방식을 고르는 자리). 소유(연결 표에 없음).
  - 봇 `src/credentials.ts`: 실행마다 방식 표시와 그 방식의 자격을 함께 읽고 불일치를 거부하는 자리. 소유(연결 표에 없음).
  - 봇 `src/executor-claude.ts`, `src/executor-claude-task.ts`: 인증 방식별 env와 init 이벤트 `apiKeySource` 기대값(`CLAUDE_AUTH`), 크레딧 소진 오류 분류(`classifyClaudeError`). 연결 표에 없는 공유 파일이다(C03이 한도 정보 읽기로 같은 파일을 고친다. README 5절에 반영).
  - 봇 `src/worker-main.ts`: 작업자 기동 env(`WORKER_ENV`)에 방식 표시가 더해지면 그 자리. 소유(연결 표에 없음).
  - 봇 관리 진입점(C05 소유, C22가 계정 기록을 더함): 계정 방식 값에 API를 더하는 자리만.
  - 봇 시험: `test/worker-claude.test.ts`, `test/worker-entry.test.ts`, `test/worker-server.test.ts`, `test/task-worker.test.ts`의 해당 줄.
  - homelab `platform/sandbox/`(`values.yaml`의 `worker`·`task` 블록, `values.schema.json`의 자격 키 `const`, `templates/worker-externalsecret.yaml`, `templates/task-worker-externalsecret.yaml`, 필요하면 `templates/worker-deployment.yaml`·`templates/task-worker-deployment.yaml`의 env, `ci/task-enabled.yaml`): 연결 파일, 소유 C06. 이 티켓은 키 이름과 작업자 이미지 digest만 바꾼다.
  - homelab `docs/runbooks-public/restore.md` 3.1: canary 검사가 sandbox 항목마다 키가 `CLAUDE_CODE_OAUTH_TOKEN` 하나라고 기대한다. 키를 더하면 같은 PR에서 고쳐야 한다(sandbox 값 주석 규칙). 연결 표에 없는 파일이다(README 5절에 반영).
  - homelab `cli/`의 `homelab bot account add --by api`, `account use --by api`: 연결 파일(`homelab bot` 명령 묶음), 소유 C05(C22가 `account` 명령을 만든 뒤).
  - homelab `docs/runbooks-public/rotate.md` 3e: 연결 파일, 소유 C22.
- 설계 계약:
  - 봇 작업자 자격·프로필(`src/executor-profiles.ts`, `src/credentials.ts`, `src/executor-claude*.ts`, `src/worker-main.ts`): 봇 ARCHITECTURE "5. 자격 배치 (키 이름만, 값은 Infisical)", "5.1 작업자에 구독 인증 파일이 있는 구조 (D-14·D-15)", "12. T18 CODEX_BRIDGE 로컬 계약"의 "T16b 작업자 진입점 (2026-10-30)"·"T16b 실행기 프로필 (2026-10-30, D-14 변경)"(오류 분류, init 대조), "14. 운영 세부"의 "작업자 실행" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). 봇 DECISIONS "D-14 봇 모델 계정과 인증"의 "변경(사용자 2026-10-30)"·"함께 지킬 조건 (결정의 일부)"·"변경(사용자 2026-11-09…)" 문단 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - homelab sandbox: [설계 C.8 봇을 위한 여지](../../2026-10-17-homelab-rebuild/platform/design.md)(작업자 격리·자격 행), `platform/sandbox/values.yaml`의 `worker.profile` 머리 주석(새 인증 방식은 봇 이미지가 먼저, 그 digest·블록·schema를 한 PR로), `templates/worker-externalsecret.yaml` 머리 주석(자격 둘을 동시에 두지 않음).
  - restore canary: [restore.md](../../../runbooks-public/restore.md) 3.1 "클러스터 유실 + Infisical 장애 (U40)".
  - CLI·런북: [설계 C.7 CLI와 운영 경험](../../2026-10-17-homelab-rebuild/platform/design.md), [rotate.md](../../../runbooks-public/rotate.md) 0절·3e.
  - 결정: 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 8.

## 목표

owner가 봇 계정을 API 크레딧 방식(Claude Console API 키)으로 등록하고 바꿀 수 있다. API 방식이면 작업자 실행 env에 API 키 하나만 있고 구독 토큰은 없다. 작업자는 실행마다 방식 표시와 그 방식의 자격을 함께 읽고, 둘이 맞지 않으면 실행하지 않는다. 모델은 같은 Opus 5.5다. 크레딧이 떨어지면 결제 멈춤으로 닫히고 저절로 재개하지 않는다(C19). 시크릿 값은 Infisical에만 있고 저장소에는 키 이름만 있다.

봇 PR은 게시 서버 쪽 변경이 없으면 병합해도 운영 동작이 바뀌지 않는다(작업자는 sandbox 사람 PR로만 올라간다). sandbox PR은 병합하면 Argo CD가 바로 작업자를 바꾸므로, 방식 표시의 기본값이 지금과 같은 구독이어야 한다.

## 할 일

1. 봇 작업자: 인증 방식 표에 API 키 방식을 더한다(`CLAUDE_AUTH`: env는 API 키 변수, init `apiKeySource` 기대값). `-p`에서는 API 키가 OAuth 토큰보다 우선하므로 한 실행에 자격 변수는 하나만 넣는다. 지금 주석이 요구하는 `--bare` 검토(bare는 OAuth를 읽지 않음)와 금지 플래그 목록을 다시 보고 결론을 적는다.
2. 실행마다 방식 표시와 자격을 함께 읽는다(`src/credentials.ts`). 방식 표시가 구독이면 구독 토큰만, API면 API 키만 읽어 넣는다. 표시가 없거나 다른 방식의 자격만 있으면 실행하지 않고 사유 코드만 남긴다(값 없음). 파드 재시작 없이 다음 실행부터 바뀌어야 한다(지금 구독 토큰과 같은 Secret 볼륨 방식).
3. 크레딧 소진 오류를 결제 멈춤으로 분류한다(`classifyClaudeError`). 소진 오류의 실제 `error` 종류·상태 코드는 미확인이다. Console 문서와 CLI 바이너리로 확인하고, 확인하지 못한 모양은 한도가 아니라 결제 쪽으로 닫히게 한다. 결제 구분이 작업자 응답에 실리는 방식은 C19의 결정을 따른다.
4. 시험(S2): 방식별 실행 env에 자격 변수가 정확히 하나, 불일치 거부, 소진 오류 → 결제 멈춤, 구독 기본값 유지.
4a. C22 넘김(봇 PR #142 Codex 2차 P2, 2026-11-11): `Store.observeRateLimit`(`src/store.ts`)이 "이 실행이 계정 전환보다 먼저 시작했는가"를 잠금 없이 확인한 뒤 한도 상태를 적는다. 전환(`switchAccount`)이 아직 커밋 전이면 확인을 통과하고, 전환이 `model_limit_state`를 비운 뒤에 쓰기가 실행돼 옛 계정의 `allowed_warning`이 새 계정의 사용률·리뷰 미루기 기한으로 남을 수 있다. 확인과 쓰기를 전환과 같은 잠금(scheduler 행, 기존 잠금 순서 scheduler → 한도 상태) 아래에서 한 번에 한다. `claude-task-bridge.ts` `settle`은 트랜잭션 밖에서 부르므로 그 호출이 잠금을 잡아도 순환하지 않는지 본다. 시험: 전환 커밋과 겹친 옛 실행의 관측이 새 계정에 남지 않는다.
5. 봇 PR 병합 뒤 main 빌드 digest를 얻는다.
6. homelab sandbox 사람 PR: ExternalSecret에 레인별 API 키와 방식 표시 키 이름을 더한다(`/apps/homelab-bot/worker` 아래 키 이름만, 값 없음). `values.yaml` 프로필 블록, `values.schema.json`의 `const`, 두 작업자 이미지 digest(`worker.image`, `task.image`)를 같은 PR에서 바꾼다. 이 digest는 C19가 든 봇 main 빌드여야 한다. C19가 작업자 턴 번호 상한(`src/task-contracts.ts`)을 넓혔고, 그 전 이미지의 작업자는 한도·인증 멈춤으로 턴 번호가 17 이상이 된 작업을 거부한다. Infisical에 새 키가 없으면 ExternalSecret이 Degraded라 root가 sandbox wave에서 멈추므로, 병합 전에 키(방식 표시 = 구독, API 키 자리)가 Infisical에 있어야 한다는 순서를 PR 설명에 적는다. `restore.md` 3.1의 키 개수·canary 검사를 같은 PR에서 고친다. egress는 API 방식도 `api.anthropic.com`만 쓰는지 확인한다.
7. homelab CLI: `account add <이름> --by api`(Console API 키를 레인마다 하나씩 보이지 않는 입력으로 받음), `account use <이름> --by api`(두 레인의 API 키와 방식 표시를 작업자 키로 옮기고 C22와 같은 반영 확인·해제). 기본은 구독이다. 시험(S3): 값 비노출, 두 레인 함께 바뀜, 방식 표시와 자격이 같이 바뀜.
8. `rotate.md`에 API 키 교체·철회 절차와 권장 Console 설정(봇 전용 workspace, 자동 충전 끔. 키가 새도 피해가 그달 크레딧까지)을 더한다.
9. 사람 단계: owner가 Console에서 봇 전용 workspace와 키를 만들고, 승인 뒤 운영에서 `--by api` 전환 1회와 구독 복귀 1회를 한다. 결과를 homelab [approvals.md](../../2026-10-17-homelab-rebuild/approvals.md)와 봇 `VERIFICATION.md`에 적는다.
10. 기록: 봇 `docs/ai-bot/VERIFICATION.md`에 "C23 API 크레딧 방식" 절, `docs/ai-bot/DECISIONS.md`에 방식 표시 모양과 `--bare` 결론 문단, `docs/ai-bot/ARCHITECTURE.md` "5. 자격 배치"에 키 이름 줄을 더한다. 이 계획 폴더 `README.md`의 C23 상태 줄을 갱신한다.

## 완료 조건

- [ ] API 방식으로 바꾸면 작업자 실행 env에 API 키 하나만 있고 구독 토큰은 없다. 구독으로 돌아가면 그 반대다.
- [ ] 방식 표시와 자격이 맞지 않으면 실행하지 않는다.
- [ ] 크레딧 소진 오류는 결제 멈춤으로 닫히고 저절로 재개하지 않는다.
- [ ] 저장소에는 키 이름만 있고 `kind: Secret` 매니페스트나 값이 없다. `restore.md` 3.1 canary 검사가 새 키 모양과 맞다.
- [ ] `account add --by api`, `account use --by api`가 값을 argv·출력·파일에 남기지 않는다.

## 검증

- 경계: S2(작업자 자격 읽기와 실행 env, 가짜 CLI), S3(CLI `--by api`, 가짜 infisical·kubectl). 운영 전환은 S5(C24). 앞선 예: 봇 `worker-claude`, `worker-entry`, `worker-server` 시험, homelab `cli/test`의 `secret set` 시험.
- 명령: 봇 `npm run check`, `npm test`(바뀐 파일 관련 시험만). homelab `pre-commit run --all-files`, `bun run ci`(sandbox schema·렌더와 gitleaks 포함).
- 잡는 실패: 두 자격 동시 주입, 불일치 실행, 소진 오류의 잘못된 분류, 키 이름 불일치로 인한 ExternalSecret Degraded(렌더·schema 단계까지), 값 노출. 못 잡는 범위: 실제 크레딧 차감(S5에서 Console로 본다), Infisical에 키를 먼저 넣는 사람 순서.

## 결과

- 봇 PR #143, 병합 `4df0a4f`(2026-11-11): `src/credentials.ts` `MethodEnvCredential`(실행마다 방식 표시와 그 방식의 자격을 다시 읽음), `CLAUDE_AUTH`에 `api-key`(env `ANTHROPIC_API_KEY`), `classifyClaudeError`의 결제 분류, 관리 진입점 `account record|use <이름> api`, 할 일 4a(한도 관측의 확인·쓰기를 scheduler 잠금 아래에서). 전체 검사(결과 `49db1a7`, `FPB_TEST_TIMEOUT=2400 .fpb/test.sh wt-c23 c23-full --pg -- full`): 2,586개 중 통과 2,564, 실패 0, skip 22. `build / test` 통과, Codex 지적 없음.
- 키 이름(sandbox PR과 CLI가 그대로 쓴다): Infisical `/apps/homelab-bot/worker`의 `CLAUDE_AUTH_METHOD`(`subscription`·`api`, 없으면 구독), `ANTHROPIC_API_KEY`·`ANTHROPIC_API_KEY_TASK`(안 쓰면 `unset`), `CLAUDE_CODE_OAUTH_TOKEN`·`CLAUDE_CODE_OAUTH_TOKEN_TASK`(안 쓰면 `unset`). 계정 값은 `/bot-accounts/<이름>`의 `ANTHROPIC_API_KEY`·`ANTHROPIC_API_KEY_TASK`. 두 레인 Secret의 파일 이름은 `CLAUDE_AUTH_METHOD`·`CLAUDE_CODE_OAUTH_TOKEN`·`ANTHROPIC_API_KEY`.
- 분해 불일치(주 진행자 수용): 방식 표시가 없으면 실행을 거부하지 않고 구독으로 본다(할 일 2의 글자와 다름). 거부하면 지금 Secret + 새 작업자 조합과 손 Secret 복원에서 봇 전체가 멈춘다. 표시가 없는데 API 키만 있으면 거부한다. 비교는 봇 DECISIONS "C23 API 크레딧 방식".
- 구현 선택(owner에 알림 2026-11-11): API 방식에서는 429도 결제 멈춤으로 닫는다(429가 월 지출 상한에도 쓰이고 API 방식에는 풀리는 시각이 없다). 진짜 분당 한도에서도 owner가 `account use`로 풀어야 한다.
- homelab CLI PR #1256(`account add|use --by api`, `rotate.md` 3e, 설계 C.7 행, head `51cf995`, 병합 `5f7f4e5` 2026-11-11 사용자 "그래"): Codex 1차 P1 1(sandbox 지원 확인 전에 구독 토큰을 `unset`으로 덮음) 수정. 이제 두 작업자 ExternalSecret의 `spec.data` 매핑을 먼저 확인해 지원하지 않는 배포에서는 쓰기 전에 거부하고, 옛 방식 자격은 새 자격의 Secret·볼륨 반영 확인 뒤에만 비운다. 재리뷰 지적 없음, `bun run test:cli` 796개 통과, `bun run ci` 30단계·`ci` 통과.
- homelab sandbox PR #1258(할 일 6, head `083104f`, owner 병합 대기): 작업자 이미지 둘을 봇 `4df0a4f` 빌드 digest `sha256:a0ee26b9…`로(빌드 증명 `gh attestation verify` exit 0), 두 ExternalSecret `spec.data`에 레인별 API 키와 `CLAUDE_AUTH_METHOD`, `values.schema.json` 고정, `restore.md` 3.1 canary(키 18 → 22, 내보내기 경로 18 → 21), `bootstrap.md` 2.2 vm 1단계. Codex 지적 없음, `bun run ci` 30단계·`ci` 통과. **병합 전 사람 순서:** (#1256은 병합됨) → `homelab bot account add <이름>`(지금 쓰는 구독 계정) → `account use <이름> --apply`(Infisical에 방식 표시와 API 키 자리 생성) → plan으로 `same` 확인 → VM이 있으면 `homelab-dev`에도 세 키 → 병합. 키가 없으면 두 ExternalSecret이 Degraded라 root가 sandbox wave에서 멈춘다. `homelab secret set`으로는 넣을 수 없다(하위 폴더·16자 미만 값 거부).
- 봇 배포 확인(2026-11-11 11:32): 게시 서버 새 파드 Ready, digest 일치, 로그 오류 0. 작업자 둘은 #1258 전까지 `9b067e9` 그대로.
- 남은 것: #1256·#1258 owner 병합(위 순서), 병합 뒤 확인(두 ExternalSecret Ready, 두 작업자 새 이미지 Ready, 구독 대화 1회), 할 일 9(사람 단계: Console 키, `--by api` 전환 1회와 구독 복귀 1회). 미확인(S5, C24): API 방식 egress, 실제 `apiKeySource` 표시, 실제 크레딧 차감·소진 응답. 설계 C.8의 "모델 자격을 파드마다 하나" 문구는 이제 "Secret 하나에 두 방식 자리 + 방식 표시"로 읽어야 한다(#1258 병합 뒤 고칠지 정한다).
