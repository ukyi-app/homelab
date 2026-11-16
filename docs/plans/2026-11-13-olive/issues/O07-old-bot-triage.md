# O07 옛 봇 코드와 멈춘 작업 나누기

- 단계: 1 기반
- 상태: 결과 작성(2026-11-16). 표와 분류는 아래 "결과"에 있다. 코드 작성 작업자 코드는 O09에서 계약을 나누고 O13에서 옮긴다(관리자 2026-11-16, D-46). 봇 PR #155를 닫을지는 관리자 결정을 기다린다
- 명세: `spec.md` §2.2(마지막 줄), §4, §4.1(저장소 배치, D-18), §5.1 D-46(작업자 코드를 옮길지. 결정 전에는 §5.3에 있었다)
- Blocked by: 없음
- 연결 AC: AC-21(목록을 만든다. 지우기는 O22)
- 수행: 에이전트(문서만)
- 저장소·PR: 이 계획 문서 PR 하나
- 파일 소유: 이 티켓의 "결과" 절(표), `spec.md` §5.3 첫 줄
- 설계 계약: 보안 조사 1·6·7절(재사용 후보), 옛 봇 계획 `docs/plans/2026-11-09-bot-colleague/`

## 목표

옛 봇 저장소 `ukyi-app/homelab-bot` main의 모듈을 "현관으로 가져감 / 작업자로 가져감 / 버림"으로 나누고, 멈춘 작업(C40~C47, 봇 PR #155)의 코드를 보고 같은 기준으로 나눈 표를 만든다. 무엇을 할지는 이 표를 보고 관리자가 정한다.

## 할 일

1. 봇 main을 읽기 전용으로 받아(새 clone) 모듈 목록을 만든다. 로컬 도구·시험은 돌리지 않는다.
2. 재사용 후보부터 확인한다(조사에서 이름이 나온 것):
   - 현관: `PolicyGate`(관리자·채널 검사), 제안·확인 카드 상태기계(`ProposalDesk`, `pressProposal`), CHANGE 승인 묶음(`prepareApproval`), GitHub writer, `scanPublicText`, `Store.audit`, 원문 정리, 기억 삭제 원장, 관리 CLI의 비상 정지·상태 처리기, 모델 없는 조회(`catalog.ts`, `ReadRuntime`, `readSummary`).
   - 작업자: 샌드박스 작업자(bwrap, 자격 env 제거), 작업자 계약 v2, 한도 분류(C39의 허용표).
   - 기억: `memory.ts`의 분류·출처·상태 모델.
3. 버림 후보: '/' 명령 등록, 메시지마다 도구 0개로 부르는 대화 경로, 대화 프롬프트 조립 등 오케스트레이터가 대체하는 부분.
4. 멈춘 작업: C40~C47 티켓과 봇 PR #155의 diff를 읽고 각각 "가져감(어느 티켓으로) / 버림 / 관리자 판단 필요"로 표시하고 이유를 한 줄씩 적는다. PR #155를 닫거나 병합하지 않는다.
5. 새 코드는 새 공개 저장소 `ukyi-app/olive`에 둔다(D-18, 2026-11-13 관리자 결정. 이름은 D-44, 2026-11-16). 이 티켓은 표의 각 모듈에 "봇 저장소에 남음 / `olive`로 복사 / `olive`로 옮김"을 더한다. 기준은 `spec.md` §4.1: 모델을 돌리는 코드는 `olive`, 자격으로 바깥에 글을 쓰는 코드는 봇 저장소. 코드 작성 작업자 코드(`worker*`, `task-*`, `executor-*`, `process-launcher` 등)는 게시 서버와 나눠 쓰는 모듈이 많으므로, 옮길 때 끊어야 할 import를 함께 적는다.
6. 표의 각 줄에 받는 티켓(O08~O20)을 적는다. 받는 티켓이 없으면 O22 지우기 대상이다.

## 완료 조건

- [x] 모듈 표(가져감·버림·판단 필요, 받는 티켓)가 있다.
- [x] C40~C47, PR #155 각각의 분류와 이유가 있다.
- [x] 모듈마다 저장소 배치(남음·복사·옮김)가 있고, 코드 작성 작업자 코드를 옮길지와 시점의 안이 있다(결정은 관리자).

## 검증

- 경계: 문서. 코드 읽기만.
- 잡는 실패: 보안 기능을 실수로 버림. 못 잡는 범위: 재사용 모듈이 새 구조에서 실제로 맞는지(받는 티켓이 확인).

## 결과

**추천: 현관의 인가·게시·감사는 봇 저장소에 남기고, 모델 실행과 기억은 `olive`로 분리한다. 코드 작성 작업자는 O09에서 계약을 분리한 뒤 O13에서 옮기는 안을 추천하며, 최종 결정은 관리자에게 남긴다.**

### 조사 범위와 표 읽는 법

- 조사일: 2026-11-16. 옛 봇 기준은 `ukyi-app/homelab-bot`의 `02f5f3ffaa57a772ecf8a4c24cea488e308a070f`다. `src/`의 106개 파일을 표에 대조하고 구현을 읽었다. import는 이 커밋의 `git grep` 결과로 대조했다.
- [봇 PR #155](https://github.com/ukyi-app/homelab-bot/pull/155)는 조회 당시 OPEN, head `4ba5344ebb8ad78fd2ccdb7ef71ee2be072dcc5e`다. main에 들어온 코드와 PR의 코드를 구별했다.
- 아래 분류는 **재사용·교체 제안**이다. 새 구현의 완료나 실행 검증을 뜻하지 않는다. 계획·코드·Git 상태·PR·운영 설정을 바꾸지 않았고 시험·빌드도 실행하지 않았다.
- `olive`로 **복사**는 양쪽에서 필요한 순수 계약·검사 또는 일부 알고리즘을 분리해 재사용한다는 뜻이다. 런타임이나 DB를 공유한다는 뜻이 아니다. `olive`로 **옮김**은 최종 소유를 옮긴다는 제안이며, 옛 소비자가 없어졌는지는 O22가 확인한다.
- **버림 / 봇 저장소에 남음 / O22**는 지금 지운다는 뜻이 아니다. 대체 기능과 보안 검사를 받는 티켓이 인수한 뒤 O22에서 제거한다. 같은 파일이 여러 줄에 나오면 함수·책임을 나눠야 한다.
- 모델을 실행하는 코드와 외부 쓰기 자격을 가진 코드가 섞인 파일을 통째로 옮기지 않는다. 작성 작업자와 그 공용 코드의 최종 이동은 `spec.md` §5.3의 관리자 결정에 달려 있다.

### 1. 모듈 분류

#### 1.1 현관과 외부 게시

| 모듈 또는 파일 묶음 | 하는 일과 코드에서 확인한 재사용 범위 | 분류 | 저장소 배치 | 받는 티켓 | 옮길 때 끊거나 바꿀 import |
|---|---|---|---|---|---|
| `src/policy.ts`의 `PolicyGate` | 관리자·대화 범위·정책 revision을 검사한다. 모델이 승인 주체가 되지 않도록 현관에서 유지한다. | 현관으로 가져감 | 봇 저장소에 남음 | O08, O15 | `change-contracts`, `change-policy`의 순수 스키마만 참조하도록 유지. 모델 실행 의존을 더하지 않는다. |
| `src/discord.ts`, `src/discord-protocol.ts`, `src/gateway.ts` | Discord 수신·REST·Gateway 연결, 입력 중복 및 대화 소유 검사를 담당한다. 자연어 입력과 좁은 감독 API 연결로 바꾼다. | 현관으로 가져감 | 봇 저장소에 남음 | O08 | 옛 명령·모델 실행·외부 세션 연결을 조립한 의존은 제거하고 현관 서비스로 제한한다. |
| `src/chat-context.ts`의 `ownerText` | 이미 받은 입력에서 봇 멘션을 정리하는 순수 함수를 제공한다. 옛 대화 프롬프트 조립과 분리한다. | 현관으로 가져감 | 봇 저장소에 남음 | O08 | `proposals → chat-context.ownerText`를 현관 입력 모듈로 바꾼 뒤 옛 DB 프롬프트 조립을 지운다. |
| `src/recovery.ts` | 누락 복구 장벽, 세대 토큰, 대화별 재시도를 관리한다. 켜진 뒤 연결 단절 복구에 재사용한다. | 현관으로 가져감 | 봇 저장소에 남음 | O08 | `Store`는 현관 소유 유지. **꺼져 있던 기간의 요청을 소급 실행하지 않는 기동 경계**를 별도로 둔다. |
| `src/proposals.ts`, `src/proposal-retention.ts` | `ProposalDesk`·`pressProposal`의 소유자·만료·내용 digest·현재 정책 검사와 단일 상태 전이를 재사용한다. | 현관으로 가져감 | 봇 저장소에 남음 | O08, O15 | 옛 실행 핸들러와 버튼 dispatch를 분리한다. 승인 대상은 현관이 만든 게시 후보이며 모델의 제안 문자열이 아니다. |
| `src/change-publisher.ts`, `src/change-ci-policy.ts` | `prepareApproval`과 게시 gate가 artifact·검증·리뷰·정책·CI 근거를 묶고, 효과 상태를 기록해 중복 게시를 막는다. | 현관으로 가져감 | 봇 저장소에 남음 | O15 | 순수 계약과 현관 `ChangeStore`만 연결한다. 승인 시점과 게시 직전 검사를 모두 유지하되 아래의 보호 경로·main 이동 규칙을 교체한다. |
| `src/github-app.ts`, `src/github-writer.ts` | App 자격과 제한된 GitHub 쓰기를 담당한다. 허용 경로·요청 body 검사, `force: false`, 병합 API 부재를 보존한다. | 현관으로 가져감 | 봇 저장소에 남음 | O15, O19 | 모델 실행 코드로 복사하지 않는다. `change-policy`의 보호 경로 무조건 거절은 승인 확인으로 바꾼다. |
| `src/change-policy.ts` | 경로 정규화·보호 경로 탐지·패치 검사·정책 컴파일을 한다. 탐지는 유지하고 게시 허용 판정은 새 승인 규칙에 맞춘다. | 현관으로 가져감 | 봇 저장소에 남음 | O15 | `change-contracts`의 순수 타입 유지. `github-writer`, `change-review`의 중복 보호 경로 판정과 함께 수정한다. |
| `src/change-publication.ts`, `src/task-output.ts`, `src/chat-format.ts` | `scanPublicText`·payload 검사, 내부 표식·민감 출력 차단과 공개 문구 구성을 재사용한다. | 현관으로 가져감 | 봇 저장소에 남음 | O08, O15, O19 | `change-publication → task-contracts`, `task-output → review`의 실행 시 import를 순수 출력 스키마로 바꾼다. `safe_summary` 표시만으로 발송을 허용하지 않는다. |
| `src/store.ts`의 입력·발송함·감사, `src/database.ts`, `src/db-connect.ts`, `src/migrate-main.ts` | 현관 DB의 입력 중복 방지, 외부 효과와 감사 기록을 유지한다. `Store.audit`는 전달받은 JSON을 저장하므로 감사 호출자도 원문·비밀을 걸러야 한다. | 현관으로 가져감 | 봇 저장소에 남음 | O08, O15, O18 | `Store` 전체를 감독으로 가져가지 않는다. 모델 작업·계정 SQL과 현관 입력·발송함을 분리하고 감독은 자기 장부를 쓴다. |
| `src/change-store.ts`, `src/change-artifact.ts`의 `ChangeStoreArtifacts` | 게시 후보·불변 artifact·승인·효과 상태를 현관에 저장한다. | 현관으로 가져감 | 봇 저장소에 남음 | O15 | `change-artifact`의 파일시스템 작업자 구현을 분리한다. `ChangeStore`의 타입 import만 남아도 이 어댑터의 DB 소유는 현관이다. |
| `src/review.ts`의 요청·인가·게시, `src/review-request.ts`, `src/github-review-io.ts` | 고정된 PR 입력과 GitHub 리뷰 게시를 다룬다. `restrictGitHubWrite`의 COMMENT 전용 제한을 유지한다. | 현관으로 가져감 | 봇 저장소에 남음 | O08, O14 | `review.ts`의 모델 실행·옛 큐와 순수 정책 스키마를 분리한다. 작업자는 리뷰 결과만 반환하고 GitHub 자격을 받지 않는다. |
| `src/change-guidance.ts` | 고정된 변경·리뷰 근거에 맞춰 PR 안내를 렌더링하고 게시한다. | 현관으로 가져감 | 봇 저장소에 남음 | O14, O15 | `ReviewPolicySchema`와 `ChangeNoteSchema`를 각각 `review`, `task-contracts`에서 순수 계약으로 추출한다. |
| `src/change-commands.ts`, `src/task-commands.ts`, `src/memory-commands.ts`의 인가·입력 검사 | 관리자 요청을 검증하고 작업·기억 서비스에 전달한다. 명령 문법은 재사용 대상에서 제외한다. | 현관으로 가져감 | 봇 저장소에 남음 | O08, O13, O18 | `TaskBridge`·`MemoryService` 직접 호출을 버전 있는 감독·기억 API로 바꾼다. 기억의 오류·출처 타입도 공용 계약으로 분리한다. |
| `src/question-pick.ts`, `src/change-question.ts`의 응답 검증 | 질문 소유·세대·유효기간·한 번만 답하기 검사를 재사용한다. | 현관으로 가져감 | 봇 저장소에 남음 | O08, O13 | 옛 버튼 형식과 작업 큐 의존을 분리한다. 원문 답을 계속 보존하는 근거로 사용하지 않는다. |
| `src/activity.ts`, `src/typing.ts`, `src/reactions.ts` | 입력·진행 표시와 Discord 효과의 상태·재시도를 처리한다. | 현관으로 가져감 | 봇 저장소에 남음 | O08 | `Store`의 옛 job 상태 대신 감독이 보내는 검증된 진행 상태를 받도록 연결부를 바꾼다. |
| `src/away.ts`, `src/control-format.ts` | 중단·대기 상태를 표시한다. `away.ts`의 실제 상태 원천은 옛 `model_pauses`·`jobs` SQL이다. | 현관으로 가져감 | 봇 저장소에 남음 | O08, O17 | DB에서 모델 상태를 계산하는 부분을 감독의 제한된 상태 응답으로 교체한다. |
| `src/admin.ts`, `src/admin-main.ts`의 상태·정지 처리 | 관리 명령의 거부·미지원·상태 보고 의미를 보존한다. 옛 정지는 scheduler와 job 제어라 올리브 전체 정지의 증거가 아니다. | 현관으로 가져감 | 봇 저장소에 남음 | O08, O09 | `admin-main → main.taskPrecondition`, `ClaudeTaskBridge`, `task-http`, `task-policy` 결합을 끊는다. 전체 비상 정지는 O09의 `homelab` CLI·감독 구현으로 대체한다. |
| `src/health.ts`, `src/ops-metrics.ts`의 현관 상태, `src/config.ts`, `src/main.ts`의 현관 조립 | 현관의 준비 상태·Gateway·DB·HTTP와 지표를 구성한다. | 현관으로 가져감 | 봇 저장소에 남음 | O08, O09, O17 | `main`의 작업자·계정·기억 직접 조립을 제거한다. `ops-metrics → model-accounts`와 모델 SQL은 감독 상태 계약으로 바꾼다. |

#### 1.2 감독·실행기·작업자와 공용 계약

| 모듈 또는 파일 묶음 | 하는 일과 코드에서 확인한 재사용 범위 | 분류 | 저장소 배치 | 받는 티켓 | 옮길 때 끊거나 바꿀 import |
|---|---|---|---|---|---|
| `src/worker.ts`의 서명·capability, `src/task-contracts.ts`의 v2, `src/change-contracts.ts` | 요청·응답·artifact 스키마와서명된 권한의 대상·동작·기한·nonce를 검사한다. 새 역할·세대 계약의 출발점이다. | 작업자로 가져감 | `olive`로 복사 | O09, O13, O14, O15 | `task-contracts → codex`, `review-http`, `worker-state`의 실행 시 import를 끊는다. 상수·서명·스키마만 양쪽 계약에 남긴다. |
| `src/contracts.ts`, `src/format.ts`, `src/http.ts`, `src/log.ts`의 필요한 공용 부분 | 공용 오류·시간·제한·문구·본문 크기 검사·로그 함수를 제공한다. | 작업자로 가져감 | `olive`로 복사 | O09, O13 | 옛 job·대화 정책까지 통째로 복사하지 않는다. 호출자별 로그 공개 검사와 한도를 따로 보장한다. |
| `src/model-accounts.ts`, `src/execution-auth.ts` | 계정 이름·방식·실행 ID·자격 revision을 묶고 실행 선택 및 C39 한도 전환 근거를 검사한다. | 작업자로 가져감 | `olive`로 복사 | O09, O17 | `model-accounts → Store/Database` 타입과 실제 SQL을 감독 장부로 교체한다. `execution-auth → model-accounts.ACCOUNT_NAME`을 순수 계약으로 추출한다. |
| `src/credentials.ts`, `src/executor-profiles.ts` | 자격 묶음·지문·revision과 실행 프로필을 연결한다. 선택 불일치에서 실행하지 않는 성질을 유지한다. | 작업자로 가져감 | `olive`로 복사 | O09, O17 | `credentials`의 v1 양쪽 자격 필수·기본 방식 fallback을 새 계약에 맞춘다. `executor-profiles`는 역할별 프로필로 재구성하고 현관에는 자격 로더를 남기지 않는다. |
| `src/executor.ts`, `src/executor-claude.ts`, `src/executor-codex.ts` | 모델 실행 인터페이스와 결과·오류를 구조화한다. API 429를 일괄 결제 오류로 보는 기존 분류는 교체한다. | 작업자로 가져감 | `olive`로 옮김 | O09, O12, O14, O17 | `executor-codex → codex.CODEX_LIMITS`를 순수 상수로 분리한다. 프로필 등록과 새 오류 분류는 O17이 검증한다. |
| `src/codex-config.ts`, `src/codex-events.ts`, `src/codex-workspace.ts`, `src/personal-homes.ts` | 고정 CLI 설정·출력 파싱·작업 공간·개인 홈 접근 제한을 제공한다. | 작업자로 가져감 | `olive`로 옮김 | O09, O13, O14, O17 | 공용 `contracts`, `format`, `process-launcher`만 새 경계로 연결한다. 개인 홈 제한은 OpenCode의 설정·자격 경로까지 O17에서 확장한다. |
| `src/codex.ts`의 상수·실행 어댑터 | 모델 실행에 필요한 제한과 어댑터를 제공하지만 같은 파일에 게시 서버 `CodexBridge`가 있다. | 작업자로 가져감 | `olive`로 복사 | O09, O14 | `task-bridge`, `Store`, `PolicyGate`를 사용하는 bridge를 분리하고 필요한 순수 상수·어댑터만 가져간다. |
| `src/run-control.ts`, `src/process-launcher.ts` | 환경 허용 목록·자격 전달·출력·시간·취소·프로세스 종료를 통제한다. | 작업자로 가져감 | `olive`로 옮김 | O09, O13, O17 | `executor`, `credentials`, `execution-auth`, `codex-config`를 실행기 내부에 둔다. process group 종료만으로 탈출 프로세스까지 끝났다고 판정하지 않는다. |
| `src/task-containment.ts` | 전용 작성 파드의 PID 공간이 비었는지 확인하고 실행 종료 뒤 잔여 프로세스를 검사한다. | 작업자로 가져감 | `olive`로 옮김 | O09, O13 | `process-launcher`는 타입 의존이다. **hc·감독과 같은 PID 공간에 배치하지 않는다.** 이 코드는 전용 PID 공간 전체 종료를 전제로 한다. |
| `src/executor-claude-task.ts` | bwrap 필수·샌드박스 실패 시 거절, 고정 도구·MCP 제한, 도구 환경의 모델 자격 제거로 작성 세션을 실행한다. | 작업자로 가져감 | `olive`로 옮김 | O13, O17, O20 | 작업자 내부 `task-contracts`, `task-workspace`, `run-control`로 제한한다. 옛 strict MCP 설정을 오케스트레이터에 복사하지 않는다. OpenCode 작성 실행기는 별도 구현·검증이 필요하다. |
| `src/task-worker.ts`, `src/task-workspace.ts` | v2 접수·영수증·결과 회수와 고정 archive의 경로·링크·크기 검사를 제공한다. 종료·결과 불명에서 자동 재실행하지 않는다. | 작업자로 가져감 | `olive`로 옮김 | O09, O13 | `task-workspace → review-input.ArchiveError`와 공용 archive 타입을 분리한다. 작업자 결과 저장소는 감독·현관 DB와 공유하지 않는다. |
| `src/worker-state.ts` | nonce·receipt·저장소 identity·실행 파일의 안전한 소유와 지속성을 관리한다. | 작업자로 가져감 | `olive`로 옮김 | O09, O13 | `contracts`의 제한과 `personal-homes`를 실행기 공용으로 둔다. nonce 보존 상수는 계약이 구현 모듈을 import하지 않도록 분리한다. |
| `src/task-http.ts`, `src/worker-http.ts`, `src/worker-main.ts` | 제한된 요청 크기·서명 검사·접수 및 실행기 조립을 담당한다. 새 역할별 실행기 진입점의 재료다. | 작업자로 가져감 | `olive`로 옮김 | O09, O13, O14 | `task-http → task-bridge.TaskWorkerBusy/TaskWorkerRejected`를 순수 오류로 분리한다. `worker-main`의 옛 대화 모드를 제거하고 역할별로 조립한다. |
| `src/change-artifact.ts`의 수집·검증·파일 작업, `src/change-verifier.ts` | snapshot과 artifact digest를 대조하고, 네트워크 없는 고정 명령 검증과 결과 영수증을 만든다. | 작업자로 가져감 | `olive`로 옮김 | O13 | DB 어댑터 `ChangeStoreArtifacts`는 현관에 남긴다. `change-verifier → review.classify`, `task-bridge` 오류를 순수 검사·오류 모듈로 바꾼다. |
| `src/change-review.ts`의 `ChangeReviewWorker`·결과 스키마·검사 | 변경 snapshot을 도구 없는 모델에 주고 자체 리뷰 결과와 근거를 검증한다. | 작업자로 가져감 | `olive`로 옮김 | O13, O14 | 같은 파일의 `ChangeReviewService`가 쓰는 `Store/ChangeStore` 타입 및 DB 호출을 분리한다. 자체 `isProtectedPath`도 O15 판정과 맞춘다. |
| `src/review-input.ts`, `src/review-lane.ts`, `src/review-http.ts`의 실행기 | 고정 입력·archive·결과 크기를 검증하고 tools 0 리뷰를 실행한다. 격리 읽기·PR 리뷰의 출발점이다. | 작업자로 가져감 | `olive`로 옮김 | O12, O14 | `review-http`의 공용 크기 상수는 계약으로 추출한다. `review-lane → change-review`는 작업자 부분만 참조한다. 새 Codex 리뷰 어댑터는 별도 구현한다. |
| `src/archive-fetcher.ts` | 고정 SHA의 codeload archive만 받고 redirect·크기·시간을 제한한다. | 작업자로 가져감 | `olive`로 옮김 | O12, O13, O14 | `review-input`의 archive 오류·포트를 순수 모듈로 분리한다. 일반 웹 URL의 SSRF 방어 구현으로 간주하지 않는다. |
| `src/claude-task-bridge.ts`, `src/task-bridge.ts`, `src/task-policy.ts`의 실행 수명·고정 계획 검사 | 세대·turn·lease·결과 회수·누적 예산과 고정된 실행 계획 검사를 제공한다. | 작업자로 가져감 | `olive`로 복사 | O09, O13, O17 | `Store`, `PolicyGate`, `Database`, Discord 질문·문구 및 `runtime.DRAIN_MS`를 끊고 감독 포트·장부로 다시 연결한다. 옛 bridge 자체는 아래 O22 대상이다. |

#### 1.3 조회·경보·기억·학습

| 모듈 또는 파일 묶음 | 하는 일과 코드에서 확인한 재사용 범위 | 분류 | 저장소 배치 | 받는 티켓 | 옮길 때 끊거나 바꿀 import |
|---|---|---|---|---|---|
| `src/catalog.ts`, `src/read-runtime.ts`, `src/read.ts`의 `ReadRuntime`·`readSummary` | 고정 서비스·조회 템플릿, 실행 전후 인가, 모델 없는 요약을 제공한다. 현관의 결정적 조회 경로로 남긴다. | 현관으로 가져감 | 봇 저장소에 남음 | O08, O11, O19 | 현관은 새 중계 API를 사용한다. 기존 catalog는 일부 서비스만 담으므로 전체 진단 범위나 완성된 지도로 간주하지 않는다. |
| `src/read.ts`의 상한·응답 처리, `src/read-transports.ts`, `src/briefing-observations.ts` | 조회 시간·크기 제한, Kubernetes·관측 연결, 백업·예약·인증서 관측을 제공한다. | 작업자로 가져감 | `olive`로 복사 | O11, O19 | 클러스터 자격을 쓰는 연결부는 **관측 중계만** 가진다. `briefing-observations → briefing`의 날짜 함수·관측 타입을 순수 모듈로 분리한다. |
| `src/change-deployment.ts` | PR merge·digest·배포 상태를 읽고 정해진 모양으로 관측 결과를 만든다. | 작업자로 가져감 | `olive`로 복사 | O11, O15 | 현관의 GitHub 읽기 포트와 관측 중계 포트를 나눈다. GitHub App 자격을 포함한 조립을 모델 파드로 옮기지 않는다. |
| `src/alerts.ts` | 경보 입력을 정규화하고 group·fingerprint와 발송 상태로 중복을 줄인다. | 현관으로 가져감 | 봇 저장소에 남음 | O08, O16 | 옛 events/incidents/outbox 연결 중 현관 발송은 유지하고, 진단 시작은 좁은 감독 API로 전달한다. 송신자 인증 경계·자동 진단 정책·차단기는 O16이 인수한다. |
| `src/briefing.ts`의 시간표·발송 상태 | 하루 슬롯·재시도·발송 중복 방지를 관리한다. | 현관으로 가져감 | 봇 저장소에 남음 | O19 | `MemoryService`, `model-accounts.tokenExpiresAt`와 계정 SQL을 기억·감독의 제한된 응답으로 교체한다. |
| `src/memory.ts`의 분류·출처·상태 모델 | `internal/safe_summary`, 출처 revision, 후보·충돌·삭제 상태를 표현한다. | 기억으로 가져감 | `olive`로 복사 | O18, O19 | `PolicyGate`, `Database`, 현관 events/jobs/outbox/briefing 조회를 분리한다. 승인된 지식과 미검증 메모를 별도 계층으로 만든다. |
| `src/deletion-ledger.ts`, `src/ledger-lock.ts`, `src/memory.ts`의 삭제·복구 절차 | 삭제를 영속 원장에 먼저 남기고, 원장 확인·재적용 전 기억 접근과 브리핑을 막는다. | 기억으로 가져감 | `olive`로 옮김 | O18 | `Database` 타입뿐 아니라 DB generation 결합도 새 저장소에 맞춰 재설계한다. 원장·DB 공유로 현관 DB 접근을 허용하지 않는다. |
| `src/raw-text-retention.ts`, `src/change-store.ts`의 원문 정리 | 입력·질문·결과·발송함·변경 내용을 정리한다. 정리 책임과 대상 목록을 보존한다. | 기억으로 가져감 | `olive`로 복사 | O08, O18 | `raw-text-retention → task-bridge.JOB_FINAL/sessionHeld`를 끊는다. 현관 소유 데이터의 삭제기는 현관에 남기고, 원천 시각 기준 **168시간** 및 SSD 사본 정리를 독립 실행한다. |
| `src/document-source.ts` | 허용된 공개 저장소의 고정 커밋 문서가 존재하는지 검사한다. 내용의 진실 여부는 증명하지 않는다. | 기억으로 가져감 | `olive`로 복사 | O18, O19 | `memory` 타입을 순수 출처 계약으로 바꾼다. 비공개 지식 저장소의 승인 revision 배포는 새로 구현하고 GitHub 쓰기는 현관에 둔다. |

#### 1.4 교체 뒤 지울 옛 경로

| 모듈 또는 파일 묶음 | 하는 일과 버리는 범위 | 분류 | 저장소 배치 | 받는 티켓 | 옮길 때 끊거나 바꿀 import |
|---|---|---|---|---|---|
| `src/commands.ts`의 슬래시 정의·등록, 각 `*-commands`의 옛 문법 | `/` 등록·dispatch를 없앤다. 각 서비스의 인가·검사는 앞 표대로 인수한다. | 버림 | 봇 저장소에 남음 | O22; 대체 O08 | 먼저 명령 등록을 빈 목록으로 동기화하는 전환 절차를 O08이 맡고, 그 뒤 사용처를 제거한다. |
| `src/chat-lane.ts`, `src/chat-context.ts`, `src/bot-facts.ts`의 대화 프롬프트, `src/worker.ts`의 옛 chat 계약 | 메시지마다 tools 0 모델 호출·DB 프롬프트 조립·명령 사용 안내를 없앤다. | 버림 | 봇 저장소에 남음 | O22; 대체 O10 | `worker-main`, `runtime`, `main`, `store`의 해당 소비자를 먼저 끊고 `ownerText`는 앞 표대로 분리한다. `RunControl`, 서명, 출력 검사 및 리뷰용 tools 0 경로는 삭제 범위가 아니다. |
| `src/chat-currency.ts`의 옛 대화 job 판정 | 오래된 대화 결과가 실행·게시되지 않게 하는 옛 큐 전용 구현을 교체한다. | 버림 | 봇 저장소에 남음 | O22; 대체 O08, O09 | DB job 의존 제거 전 새 세대·요청·게시 후보 판정으로 같은 차단을 인수한다. |
| `src/runtime.ts`, `src/change-runtime.ts`, `src/change-assembly.ts`의 옛 실행·게시 통합 조립 | 현관 프로세스가 모델 큐·작성·검증·리뷰를 직접 조율하는 흐름을 없앤다. | 버림 | 봇 저장소에 남음 | O22; 대체 O08, O09, O13, O15 | 현관 게시·복구·정리만 남기고 모델 스케줄러와 bridge를 분리한다. `DRAIN_MS` 등 공용 상수를 먼저 추출한다. |
| `src/claude-task-bridge.ts`, `src/task-bridge.ts`, `src/codex.ts`의 옛 게시 서버 bridge | 현관 DB와 실행기를 직접 연결하는 bridge를 없앤다. 앞 표의 실행 수명 불변 조건은 감독이 인수한다. | 버림 | 봇 저장소에 남음 | O22; 대체 O09, O13 | 타입·오류·상수 사용처까지 모두 새 계약으로 바꾼 뒤 제거한다. |
| `src/external-task-commands.ts`, `src/external-task-links.ts`, `src/external-task-receiver.ts`, `src/session-key-proposal.ts` | 외부 세션 붙이기·일회 키 공개·서명 알림 수신을 없앤다. | 버림 | 봇 저장소에 남음 | O22; 대체 O08 | `main`, `proposals` 등의 붙이기 연결을 제거한다. 폐쇄하는 API의 보안 처리와 계속 쓰는 API의 보안 처리를 혼동하지 않는다. |
| `src/chat-task-text.ts`, `src/change-advice.ts`의 옛 명령 안내 | 옛 `/task`·변경 재시작 안내 문구를 새 자연어 흐름으로 교체한다. | 버림 | 봇 저장소에 남음 | O22; 대체 O08, O13 | `task-bridge`, `claude-task-bridge`, `codex`뿐 아니라 `discord`, `control-format`, `review`, `store`의 문구 import도 새 현관 메시지로 바꾼다. |

### 2. 그대로 가져가면 어긋나는 동작

| 코드에서 확인한 동작 | 받는 티켓이 바꿀 부분 |
|---|---|
| `pressProposal`은 버튼 경로와 옛 제안 핸들러에 붙어 있다. | O08·O15: 소유자·digest·만료·현재 정책 검사는 유지하고, 카드 뒤 정확한 전체 메시지 `올려` / `취소`로 전환한다. 카드 24시간, 승인 후 10분, 여러 카드이면 답장 대상이 필요하다. |
| `change-policy`·`github-writer`·`change-review`가 보호 경로를 각자 거절하며 `ChangePublisher.gate`는 기준 branch 이동을 거절 사유로 삼는다. | O13·O15: 보호 경로 탐지는 유지하고 해당 경로는 승인된 후보만 통과시킨다. 보호 경로가 아닌 후보는 카드 없이 게시하되 공통 게시 검사는 그대로 거친다. **main의 무관한 이동만으로 승인을 없애지 않는다.** 내용·정책·대상 변경과 충돌은 별도 검사한다. 제외 저장소 넷의 게시 거부도 현관에서 보장한다. |
| `model-accounts.switchAccount`가 넓은 대기를 풀고, `executor-claude.classifyClaudeError`는 API rate limit/429를 결제 오류로 분류한다. | O17: 역할별 후보, 잠금·소진·미상 보류를 분리한다. 새 revision·재시작만으로 잠금을 풀지 않는다. C39의 전환 허용표는 출발점이며 실제 신호는 O04 결과로 대조한다. |
| `MethodEnvCredential`의 묶음 v1은 두 자격 파일·지문을 함께 요구하며, 실행 선택이 없는 옛 요청은 기본 방식으로 갈 수 있다. | O09·O17: 등록된 방식만 있는 v2 묶음, 감독만 전체 묶음 보유, 실행마다 자격 하나, 불일치에서 실행 거절로 바꾼다. |
| `executor-profiles`의 Codex 프로필은 `reviewAdapter: null`이고 작성 능력도 없다. OpenCode 실행기도 없다. | O13·O14·O17: 기존 Codex 어댑터만 옮겨 PR 리뷰·API 작성이 준비됐다고 판단하지 않는다. 새 어댑터와 계약 검증이 필요하다. |
| `executor-claude-task`는 전용 작성 환경·strict MCP·샌드박스를 전제로 하며 Unix socket 전체 허용 설정이 있다. | O09·O13: 작성 파드에 hc·감독을 같이 두지 않는다. 역할별 소켓·네트워크 경계를 다시 확인한다. O10 관리 MCP 구성에 작성용 플래그를 복사하지 않는다. |
| `memory.insert`는 출처 확인 등에 따라 바로 `active`로 만들 수 있다. 작업 성공·문서 존재는 진술의 참을 증명하지 않는다. | O18·O19: 원문 7일, 미검증 메모 30일, 관리자 병합 지식의 세 층으로 나눈다. 후보·메모를 실행 지시나 승인된 지식으로 올리지 않는다. |
| `raw-text-retention`은 미완료 job·질문 세션·발송 상태 등에 따라 원문을 남기거나 완료 시각부터 기한을 센다. | O08·O18: 종료·미결 구조화 상태를 먼저 남기고 원천 시각 기준 168시간을 예외 없이 적용한다. 원문을 재요약해 보관 시계를 새로 시작하지 않는다. |
| `ReadRuntime`의 고정 조회는 한정된 서비스·템플릿과 상한을 사용한다. | O11: 옛 catalog를 진단 가능한 자원의 전체 목록으로 쓰지 않는다. 새 허용 리소스·get/list·전 응답 가림·출구 제한을 구현한다. O19 지도 생성기는 `homelab` 소유다. |
| `admin`의 비상 정지는 옛 scheduler/job 상태를 바꾼다. | O09: CLI·실행 접수 잠금·파드 생성 차단·실제 종료 증거를 구현한다. 현관·관측 중계·정리 작업은 정지 중에도 살아 있어야 한다. |

### 3. 끊어야 할 import의 핵심

다음 화살표는 기준 커밋의 `git grep`으로 확인한 직접 의존이다. 파일명은 모두 `src/` 아래다. 타입 import와 런타임 import를 구별했으며, **타입만 바꾸어도 실제 DB 접근이 사라지는 것은 아니다.**

1. **계약에서 실행기로 역참조:** `task-contracts.ts → codex.ts`의 `CODEX_DEFAULTS/CODEX_LIMITS/EVIDENCE_PATHS`, `→ review-http.ts`의 `MAX_TASK_BYTES`, `→ worker-state.ts`의 `NONCE_RETENTION_MS`는 실행 시 import다. 순수 상수·스키마로 추출한다. `worker.ts`의 서명 봉투와 옛 chat 계약도 분리한다.
2. **작업자에서 현관 오류·검사로 역참조:** `task-http.ts`, `change-verifier.ts → task-bridge.ts`의 `TaskWorkerBusy/TaskWorkerRejected`, `change-verifier.ts → review.ts`의 `classify`는 실행 시 import다. 공유 오류와 비밀 검사로 분리한다.
3. **공용 상수 때문에 bridge까지 따라옴:** `executor-codex.ts → codex.ts`의 `CODEX_LIMITS`, `claude-task-bridge.ts → runtime.ts`의 `DRAIN_MS`를 분리한다. `codex.ts`와 `runtime.ts` 전체를 `olive`에 복사하는 이유로 삼지 않는다.
4. **혼합 파일 두 개:** `change-artifact.ts → change-store.ts`와 `change-review.ts → Store/ChangeStore`는 타입 import지만, 각각 `ChangeStoreArtifacts`와 `ChangeReviewService`가 실제 저장소 메서드를 호출한다. artifact 파일 처리·모델 리뷰와 현관 DB 어댑터를 서로 다른 파일로 나눈다.
5. **현관 공개 검사가 작업 계약을 끌어옴:** `change-publication.ts`, `change-guidance.ts → task-contracts.ts`의 `CHANGE_NOTE_LIMITS/ChangeNoteSchema`, `task-output.ts`, `change-guidance.ts → review.ts`의 `ReviewPolicySchema`를 순수 게시 계약으로 추출한다.
6. **수명 관리와 현관 DB 결합:** `task-bridge.ts → database/policy/store/change-question`, `claude-task-bridge.ts → store/policy/task-output/runtime`, `task-policy.ts → Store/Policy/TaskPlanSource`를 감독 포트·장부로 바꾼다. 일부는 타입 import지만 기존 함수 본문이 현관 SQL·서비스에 의존한다.
7. **계정 이름 때문에 DB 모듈을 끌어옴:** `execution-auth.ts → model-accounts.ts`의 `ACCOUNT_NAME`, `ops-metrics.ts → model-accounts.ts`의 `ACCOUNT_METHODS/ACCOUNT_NAME`를 순수 계약으로 뺀다. 계정 전환의 SQL은 O17 감독 소유로 다시 구현한다.
8. **정리·기억이 실행 수명에 의존:** `raw-text-retention.ts → task-bridge.ts`의 `JOB_FINAL/sessionHeld`를 없애고 O18 기한 기준을 적용한다. `memory.ts → PolicyGate/Database`는 타입이지만 현관 DB 조회와 인가가 본문에 있으므로 새 기억 서비스에 통째로 복사하지 않는다.
9. **관측과 브리핑이 서로 얽힘:** `briefing-observations.ts → briefing.ts`의 날짜 함수, `briefing.ts → memory.ts/model-accounts.ts`의 런타임 import를 순수 날짜·관측 계약과 좁은 기억·감독 API로 바꾼다.

계약은 판 번호를 고정하고 양쪽 저장소에서 같은 요청·응답 fixture와 거부 사례를 확인한다. 현관이 모델 실행 모듈을 import하거나 감독이 현관 DB를 여는 방식으로 편의를 얻지 않는다. 삭제 순서는 소비자 교체 → 계약 검증 → O22다.

### 4. 멈춘 작업의 분류

티켓의 계획과 실제 코드를 구별했다. C40~C45 문서는 있었고, C46·C47 문서는 지정된 계획의 README·issues에서 찾지 못했다. 아래의 “가져감”은 새 티켓에 책임을 인계한다는 뜻이며 미작성 기능을 구현 완료로 인정하지 않는다.

| 대상 | 분류 | 받는 티켓·배치 | 이유와 범위 |
|---|---|---|---|
| C40 방식 선택·대기·이어가기 | 가져감, 선택·귀속·복구 원리만 | O09, O17 · `olive`로 복사 | PR #155의 실행 선택 고정, 중복 전이 방지, 늦은 결과 귀속·결과 회수는 유용하다. 옛 단일 계정·구독/API 두 방식 정책과 현관 DB 구현은 교체한다. |
| C41 기록·지표·브리핑 | 가져감, 요구와 기존 기반 | O17, O19 · 감독 기록은 `olive`, 브리핑 발송은 봇 | 기존 `ops-metrics`·`briefing`은 기반으로 쓸 수 있다. 선택과 실제 시작을 구분하는 영속 사건이 필요하며, C41 전용 구현 완료는 확인하지 못했다. |
| C42 두 방식 함께 설치 CLI | 가져감, 등록·부분 실패 안전성 요구 | O17 · CLI는 `homelab`, 계정 관리기는 `olive` | 기존 `admin`·`model-accounts`·`credentials`가 출발점이다. 두 작업자에 둘 다 설치하는 구조는 버리고 감독만 묶음을 받아 실행 하나에 자격 하나를 준다. 별도 C42 미커밋 코드는 확인하지 않았다. |
| C43 옛 두 작업자 배포 | 버림, 옛 rollout | O22; 대체 O09, O13, O17 · 배포 선언은 `homelab` | 옛 두 작업자에 두 자격을 넣는 배포를 재개하지 않는다. 호환 확인·부분 반영 거부·digest 고정 요구는 새 역할별 배포가 인수한다. |
| C44 방식 전환 Telegram 알림 | 가져감, 알림 요구 | O17 · 감독 발송함은 `olive`, Alertmanager 경로는 `homelab` | 사건별 전환·복귀·잠금 알림을 새 영속 발송함에 붙인다. 기존 `ops-metrics`만으로 C44의 전달 완료를 확인할 수 없다. 올리브 자체 경보를 진단 입력에서 제외하는 책임은 O16이다. |
| C45 옛 자동 사용 켜기·실연동 | 버림, 옛 활성화 절차 | O22; 검증 요구 인수 O17 | 옛 봇을 다시 켜는 목적은 폐기한다. 실제 자격·재개·종료·알림 확인은 O03~O05 결과를 받아 O17·O21에서 검증해야 하며 이번 조사에서는 실행하지 않았다. |
| C46 | 관리자 판단 필요 | O22 목록에 미확인으로 보류 | 원본 티켓과 대응 코드가 제공된 범위에서 확인되지 않아 가져올 기능이나 폐기 대상을 추정할 수 없다. |
| C47 | 관리자 판단 필요 | O22 목록에 미확인으로 보류 | C46과 동일하게 원본과 대응 변경이 없어 기능을 이름 붙이거나 완료·폐기로 판정하지 않는다. |
| 봇 PR #155 | 관리자 판단 필요, 부분 재사용 추천 | O09, O17 · 필요한 부분만 `olive`로 복사; 옛 연결은 O22 | `MethodRouter`는 유용하지만 옛 현관 DB와 라우팅 정책에 묶여 있다. 통째 병합을 추천하지 않으며 PR을 닫거나 병합하는 결정·행동은 하지 않았다. |

**PR #155에서 가져올 것:** `select/admit/start/settle` 단계의 실행 선택 고정, 시작 직전 재검사, 단일 복귀 probe, 계정·revision·실행별 늦은 결과 귀속, 저장 결과 회수·ACK와 누적 예산 보존이다. `c40-method-routing` 시험들의 경합·시작 전 잠금·늦은 결과·예산 보존 사례도 새 감독 계약의 검증 재료가 된다. diff에서 시험 사례를 확인했으며 실행 결과를 재확인한 것은 아니다.

**PR #155에서 가져오지 않을 것:** `src/method-routing.ts`의 현관 `Store.atomic/lockScheduler` 결합, `MODEL_RESUME`를 `src/store.ts`에서 가져오는 의존, 옛 `jobs`에 결합한 migration, 전역 현재 계정 한 개, API limited를 결제 잠금으로 다루는 정책, 새 자격 revision으로 API 잠금을 풀 수 있는 설치 동작, 옛 요청으로 되돌려 실행하는 `not_run` 호환 경로다. 새 O17은 역할별 순서·상태 분리·명시적 잠금 해제와 엄격한 실행 선택을 따른다.

### 5. 코드 작성 작업자 이동안

| 선택지 | 시점·방식 | 이점과 비용 |
|---|---|---|
| A. 봇 저장소에 계속 둠 | O13도 봇 소스·이미지에서 작성 실행기를 만든다. | 초기 파일 이동은 적지만 현관과 모델 실행 이미지·도구 버전이 계속 결합한다. D-18의 분리 목적을 충분히 충족하지 못한다. |
| B. O09에서 계약을 분리하고 O13에서 이동 **추천** | O09는 순수 계약·실행 인터페이스·서명·상태 포트를 분리한다. 관리자 결정 후 O13에서 작성 실행기·workspace·containment·artifact·검증·리뷰 작업자와 필요한 시험을 `olive`로 옮긴다. | 위 import 경계를 한 번 정리할 수 있고, 현관의 GitHub·Discord 자격과 모델 자격을 다른 이미지에 둔다. 원본 제거는 소비자 교체와 O21 확인 뒤 O22가 맡는다. |
| C. O09에서 실행기 전체를 먼저 이동 | 감독 구현 전에 작성·검증·리뷰 실행기를 모두 옮긴다. | 소유를 일찍 통일하지만 새 감독 계약이 정해지기 전에 옛 bridge·DB 결합까지 복사하거나 같은 부분을 다시 고칠 위험이 크다. |

**관리자 결정 사항:** O13 시작 전 관리자가 B 또는 다른 안을 확정한다. 이번 결과는 추천안이며 `spec.md` §5.3의 결정을 대신하거나 해당 파일을 고치지 않았다.

**관리자 결정(2026-11-16, D-46):** B. O09에서 계약을 나누고 O13에서 옮긴다. `spec.md` §5.3의 줄은 §5.1로 옮겼다.

B를 택할 때의 인수 순서는 다음과 같다.

1. O09: 양쪽이 사용하는 버전 계약·고정 역할·실행 선택·서명·nonce·영수증 포트를 분리하고 감독이 현관 DB를 참조하지 않게 한다.
2. O13: 작성 파드는 hc 없이 직접 실행한다. bwrap 필수, 환경 허용 목록, 도구 env 자격 제거, archive·artifact 검사, 종료 불명 시 다음 실행 차단을 보존한다. 검증 실행기는 모델이 고른 임의 명령을 실행하지 않는다.
3. O14·O15·O17: 리뷰 실행기, 현관 writer, 계정 상태를 각각 연결한다. 게시 자격은 봇에만 있고 모든 발송의 최종 payload·대상·정책·digest를 검사한다. O20은 승인된 스킬 revision과 필수 스킬 영수증을 새로 구현한다.
4. O22: 옛 imports·엔드포인트·이미지 소비자가 없고 대체 보안 검사가 인수됐음을 확인한 뒤 옛 bridge·대화 경로를 지운다. 이번 조사에서는 이동·삭제를 실행하지 않는다.

### 6. “버림”에 걸린 보안 기능의 별도 목록

**보호 목적까지 버리는 항목은 없다.** 아래는 없어지는 표면의 보안 코드이거나 새 규칙으로 교체할 판정이다. O22가 파일 단위로 지우면서 남길 검사를 놓치지 않도록 따로 기록한다.

| 버리는 구현·동작 | 사라지는 것 | 반드시 남길 보호와 인수 티켓 |
|---|---|---|
| 외부 세션 연결·수신 모듈 | 폐쇄하는 API의 송신자 서명·재전송 방지·기한·크기 제한, 일회 키 표시와 복구 세대 처리 | 해당 엔드포인트·키 발급 기능을 함께 폐쇄한다. 계속 쓰는 현관↔감독↔실행기 요청의 인증·서명·nonce·세대·크기 검사는 O08·O09가 별도로 보존한다. |
| 슬래시·버튼 dispatch와 옛 질문 UI | 옛 interaction에 매달린 승인·응답 진입점 | 관리자·대화 소유·수정된 메시지 거부·만료·한 번만 전이·후보 digest를 O08·O15 자연어 처리에 인수한다. |
| 옛 대화 큐·bridge와 `chat-currency` | 오래된 job·lease·세션에 묶인 실행/게시 차단 구현 | 감독의 실행 세대·서명·영수증, 현관의 현재 후보·정책 검사로 바꾼다. unknown 결과와 미확정 외부 효과는 자동 재실행하지 않는다(O09·O13·O15). |
| 보호 경로 무조건 거절·기준 main 이동 시 승인 무효화 | 새 보호 경로 승인 규칙과 충돌하는 옛 차단 조건 | 경로 정규화·탐지, 승인 대상 내용·정책·대상 고정, 게시 직전 재검사와 충돌 차단은 유지한다. 자기 저장소 등 제외 네 곳은 계속 거절한다(O15). |
| API 429 일괄 결제 잠금·revision 교체 시 해제·넓은 `use` 대기 해제 | 잘못된 상태 결합과 자동 잠금 해제 | 방식·계정·범위별 판정, 미상 보류, 명시적 잠금 해제, 종료 확인 후 자격 하나로 전환을 구현한다(O17). |
| 진행 중 job·세션의 원문 보관 예외 | 미결 작업 때문에 7일을 넘기는 보존과 완료 시각부터 다시 세는 기한 | 원천 시각 168시간 삭제, 구조화 인계, SSD 사본 정리, 복원 후 삭제 원장 재적용을 보존한다(O08·O18). |
| 출처 확인만으로 `active`에 올리는 기억 동작 | 검증 안 된 진술이 장기 신뢰 지식으로 취급될 가능성 | 30일 메모는 미검증 표시, 승인 지식은 관리자 병합 revision만, 충돌은 보류한다(O18·O19). |

반대로 **삭제 대상으로 분류하지 않은 보안 핵심**은 `PolicyGate`, `pressProposal`의 상태·digest 검사, `prepareApproval`과 게시 gate, GitHub 제한 writer, `scanPublicText`, 감사, 원문 삭제기, 삭제 원장·잠금·복원 재적용, 샌드박스 실패 시 실행 차단, 도구 env 자격 제거, v2 요청·영수증·결과 확인, C39 전환 근거 허용표다. 재사용 중에도 새 경계에 맞는 검증은 필요하다.

### 7. 확인하지 못한 것과 다음 담당자의 경계

- **C46·C47 원본 부재:** 지정된 옛 계획에는 C40~C45까지만 있다. 원본 티켓·대응 diff를 확보하기 전에는 삭제 대상으로 확정하지 않는다.
- **다른 멈춘 작업의 구현 범위:** C41~C45 계획과 기준 커밋의 관련 기반은 확인했지만 별도 브랜치·미커밋 작업은 제공되지 않았다. 특히 C42의 별도 작업 트리를 보지 않았다. PR #155의 head 이외 변경을 추정하지 않는다.
- **실행·통합 적합성:** 빌드·시험·모델 호출·클러스터 조회를 실행하지 않았다. PR에 적힌 성공 기록을 이번 검증 결과로 사용하지 않았다. 샌드박스·프로세스 종료·실제 오류 신호·세션 재개·계약 호환은 O02~O05 결과와 O09~O17 검증이 필요하다.
- **보안 조사 원문:** O07이 참조한 별도 보안 조사 1·6·7절 원문은 이번 제공 자료에서 직접 확인하지 못했다. 재사용 판단은 읽은 구현과 import에 근거했다.
- **외부 설정:** GitHub App 설치·서버 규칙, Discord 독자, 자격·Console·Infisical·운영 배포 상태를 조사하거나 바꾸지 않았다. 코드의 차단과 실제 외부 권한이 일치하는지는 O06 등 해당 검증이 확인해야 한다.
- **새 구현과 관리자 결정:** 감독·OpenCode·Codex 리뷰·격리 웹 읽기·지식 저장소·스킬 강제는 옛 모듈을 복사하는 것만으로 완성되지 않는다. 작성 코드 이동안과 원문 백업 방식은 여전히 관리자 결정 사항이다. 이번 산출물은 O07 결과 초안이며 계획의 상태·완료 체크를 수정하지 않았다.

### 8. 호출자가 더한 확인(2026-11-16)

- 위 3절의 import 가운데 넷(`task-contracts.ts`의 `codex.js`·`review-http.js`·`worker-state.js`, `change-verifier.ts`의 `task-bridge.js`, `claude-task-bridge.ts`의 `runtime.js`, `execution-auth.ts`의 `model-accounts.js`)을 같은 커밋에서 `git grep`으로 다시 확인했다. 시험 파일을 뺀 `src/` 파일 수도 106개로 같다.
- C46·C47은 티켓 파일이 만들어지지 않았다. 옛 진행 기록(저장소 밖)에는 "등록한 계정을 지우는 기능"으로만 적혀 있고 대응하는 코드도 없다. 같은 요구는 O17의 계정 삭제(`accounts.md` §7, B-17)가 맡는다. 분류는 위 표대로 "관리자 판단 필요"로 두되, 가져올 코드는 없다.
- 병합되지 않은 옛 작업 사본(C40의 수정 중이던 것, C42의 것)은 이 조사에서 읽지 않았다. PR #155의 head가 C40의 기준이다.
