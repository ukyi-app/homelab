# T18 봇 CODEX_BRIDGE

- 단계: P4 봇 V1
- 상태: 진행 중 (로컬·mock 구현 병합 2026-10-29, 봇 저장소 PR #9 `1dba78e`, 시험 347. SEC-02는 부분이라 AC-B5 완료 아님. 완료는 T16b 뒤. 공개 저장소 내용으로 구독 모델을 부르는 작업은 D-14 차단 조건 뒤. 사용자 결정 대기 4건은 봇 저장소 `docs/ai-bot/DECISIONS.md` T18)
- 명세: [../spec.md](../spec.md)
- Blocked by: T16a(착수), T16b(완료)
  - 착수: [T16a](T16a-bot-foundation-local.md) 뒤. 작업자 계약(T16a)에 Codex 어댑터를 붙이는 로컬·mock 구현을 시작한다(V1 범위 조정 안 3).
  - 완료: [T16b](T16b-bot-foundation-deploy.md) 뒤. 작업자 파드와 영속 쓰기 공간이 T16b에서 배치돼야 그 안에서 실제 `codex exec`를 돌린다.
  - 차단 조건(D-14, 확정(사용자 2026-10-18, PR #3 리뷰)): OpenAI가 공개 저장소에 봇 전용 구독 인증 사용을 허용한다고 확인하거나 API 키 같은 공식 지원 인증으로 바꾸기 전에는, 공개 저장소 코드로 구독 모델을 부르는 작업을 하지 않는다. 모델을 부르지 않는 로컬·mock 구현은 T16a 뒤 착수할 수 있다. 봇 저장소 `docs/ai-bot/DECISIONS.md` D-14.
- 선행 결정: D-14 (확정(사용자 2026-10-18, T15): 봇 전용 ChatGPT 구독 계정 + 작업자 전용 CODEX_HOME. 권장안(OpenAI API 프로젝트 키)이 아니라 사용자가 골랐다), D-15 (확정(사용자 2026-10-18, T15): 작업자는 `sandbox` ns 상주 파드(동시성 1), 코드는 `codeload.github.com` 압축본 + `git init`, 작업자에 GitHub 자격 없음), R08 연결 방식 (확정(사용자 2026-10-18, T15): 보류, 이 티켓에서 다시 판단. T15 질문에서 추천으로 제시된 안을 사용자가 골랐다)
- 연결 AC: AC-B5
- 수행: 개발 에이전트 (`STAGE=CODEX_BRIDGE`) + 사람 (R08 연결 방식 결정, 인증 파일 분리·레인 분리 판단이 설계 C.8을 바꿀 때 그 결정(할 일 5), 재시드가 필요할 때 인증 시드). 봇 전용 ChatGPT 구독 계정 준비와 작업자 `auth.json` 첫 시드(D-14)는 T16b 전(모델을 처음 쓰는 단계 전)에 끝났다고 전제한다

## 목표

`01` §6: Codex 작업을 시작하거나 명시적으로 연결하고, 질문·완료를 Discord로 중계한다 (R03, R08~R10).

## 할 일

1. R08 연결 방식을 다시 판단한다(아래 "R08 연결 방식"). 후보와 근거를 봇 저장소 `DECISIONS.md`에 적고 사용자가 정한다.
2. 봇 소유 작업은 아래 "실행 경로"대로 만든다. 봇 저장소 `ARCHITECTURE.md` §4의 능력 표시 초안을 출발점으로 쓰되, `attach_task`(R08)는 1번 판단 전에는 정하지 않는다.
3. 다시 시드하는 절차를 정한다. 첫 시드는 T16b 전(모델을 처음 쓰는 단계 전)에 사람이 했다(D-14, T16b 할 일 4.2). 설계 C.8의 작업자 자격 전달(Infisical `/apps/homelab-bot/worker` → ESO)과 영속 쓰기 공간의 관계는 설계 C.8 변경(D-14)을 따른다: 작업자는 영속 공간에 파일이 없을 때만 시드를 복사한다. 파드를 다시 만들 때 옛 시드로 덮으면 회전된 갱신 토큰과 어긋나 사람이 다시 시드해야 한다 [확인: https://learn.chatgpt.com/docs/auth/ci-cd-auth , 2026-10-18].
4. `shell_environment_policy`를 `inherit = "none"` 또는 명시 `include`로 고정한다. 기본값은 `KEY`·`SECRET`·`TOKEN` 이름의 변수를 모델이 띄우는 명령에 넘긴다 [확인: https://learn.chatgpt.com/docs/config-file/config-advanced , 2026-10-18].
5. 봇 저장소 `ARCHITECTURE.md` §5.1의 열린 항목 둘을 판단한다. (1) 인증 파일(`auth.json`)을 작업 레인의 비신뢰 코드 실행(패키지 설치·시험, 모델이 띄우는 셸)에서 떼는 방법. (2) 대화 레인과 작업 레인의 분리. 판단과 근거는 `DECISIONS.md`에 적는다. 설계 C.8(작업자 상주 파드 하나, 동시성 1, 작업자 자격 하나)을 바꿔야 하면 사용자가 정한다. T19는 비신뢰 코드를 가장 많이 돌리므로 이 판단을 따른다(T19 제약).

## 실행 경로 (T15 조사)

- 봇 소유 작업은 작업자 파드에서 `codex exec --json`으로 돈다. 받은 코드는 작업자가 `git init`으로 한 번 커밋해 `codex exec`의 Git 저장소 요구를 맞춘다(D-15).
- `codex exec`에는 승인 정책 플래그(`-a/--ask-for-approval`)가 없다 [실측: codex-cli 0.163.0 `codex exec --help`]. 그래서 이 경로로는 tool approval을 Discord로 중계할 수 없다. 질문은 모델이 턴을 끝내며 묻고 봇이 `codex exec resume`으로 답을 잇는 clarification만 된다.
- `--approve-for-me`(자동 검토)는 사람 승인이 아니라서 쓰지 않는다(T15 제안, `ARCHITECTURE.md` §4).
- 승인 요청을 받는 API가 있는 `codex app-server`는 공식 문서가 "experimental and aren't supported for production workloads"라고 적는다 [확인: https://learn.chatgpt.com/docs/app-server , 2026-10-18]. V1 기본 경로가 아니라 어댑터 뒤 후보다(T15 제안).

## R08 연결 방식 (보류, 이 티켓에서 다시 판단)

- R08(V1 기능 3, 사용자가 명시적으로 연결한 기존 Codex 작업)은 요구 그대로다. 연결 방식만 T15에서 정하지 않고 이 티켓으로 넘겼다(확정(사용자 2026-10-18, T15)).
- herdr 경유는 쓰지 않는다. herdr는 Codex 상태를 화면으로 추정하고 소켓에 인증이 없다(T15 조사, 봇 저장소 `DISCOVERY.md`).
- 판단 전에는 사람 개인 세션 연결을 `capability=false`로 정했다고 쓰지 않는다.
- Codex 공식 훅 이벤트 목록은 T15에서 확인하지 않았다 [미확인].
- 연결 방식과 상관없이 아래 제약(개인 Codex 홈 자동 탐색·제어 금지)은 지킨다.

## 제약

- 개인 Codex 홈을 자동 탐색하거나 제어하지 않는다. 대상은 NUC의 `~/.codex*` 전체다: `~/.codex`, `~/.codex-sub`, `~/.codex-work`와 그 심링크 `~/.codex2`(`-sub`), `~/.codex3`(`-work`). 옛 AIOps의 ChatGPT 구독 OAuth(시스템 사용자 `aiops-proxy`의 CLIProxyAPI 저장소)도 쓰지 않는다 (spec §4.5).
- 봇의 모델 계정과 Codex 홈은 D-14 결정값을 따른다: 봇 전용 ChatGPT 구독 계정과 작업자 전용 CODEX_HOME(확정(사용자 2026-10-18, T15)). 함께 지킬 조건은 다음과 같다.
  - 개인 `~/.codex*`를 쓰거나 복사하지 않는다.
  - 한도 도달·인증 만료 때 다른 계정·인증으로 자동 전환하지 않고 대기 상태로 둔다(`00` §7 7항).
  - 작업은 직렬 1개(동시성 1)다.
  - 인증 갱신본은 작업자 전용 영속 쓰기 공간에 되쓴다(설계 C.8 변경, T08b·T16b).
  - 옛 구독 OAuth 프록시와 다계정 순회를 다시 쓰지 않는다.
- 작업자는 격리 공간에서 돌고, 게시 자격증명·운영 kubeconfig·SSH agent를 받지 않는다 (D-15). GitHub 자격도 없다.
- 봇 전용 구독 계정 준비와 첫 시드는 T16b 전(모델을 처음 쓰는 단계 전)에 사람이 했다. 재시드도 사람이 하고 [../approvals.md](../approvals.md)에 기록한다 (AC-X2).
- 남은 위험(D-14): 공식 CI/CD 인증 안내가 구독 무인 실행을 고급 경로로 두고 "public or open-source repositories"에 쓰지 말라고 적는다 [확인: https://learn.chatgpt.com/docs/auth/ci-cd-auth , 2026-10-18]. 적용 범위는 [미확인]이고 OpenAI 확인 항목이다(spec §10).
- 남은 위험(작업자): 작업자의 인증 파일과 비신뢰 코드(모델이 띄우는 셸, 작업 코드의 설치·시험)가 같은 파드에 있다. SEC-02에서 작업 레인이 이 파일과 환경 변수에 닿는지 시험하고 결과를 적는다. 대책은 할 일 5에서 판단한다.

## 완료 조건

- `04` §4 시험 TASK-01~03, SEC-02와 질문 경로의 AUTH-02 결과가 있다 (spec §7 AC-B5).
- spec §7 "단계 AC 공통 완료 규칙"을 따른다. 배정된 시험에 `fail`이 없다. `blocked`·`not_run`은 사유와 해소 티켓을 함께 적는다. 이 단계의 보안 경계 시험(SEC-02)은 이 경로에서 최소 `mock` 또는 `local_integration`으로 `pass`다.
- 어댑터 능력표가 있다.
- R08 연결 방식이 사용자 결정으로 정해져 있고, 근거가 `DECISIONS.md`에 있다.
- `ARCHITECTURE.md` §5.1 열린 항목 둘(인증 파일 분리, 레인 분리)의 판단과 근거가 `DECISIONS.md`에 있다. 설계 C.8을 바꾸는 판단이면 사용자 결정이다.
- HANDOFF가 있다.

## 검증

`04` §4 시험. 지원되지 않는 기능은 `capability=false`로 표시한다.
