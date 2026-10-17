# T18 봇 CODEX_BRIDGE

- 단계: P4 봇 V1
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: T16
- 선행 결정: D-14, D-15
- 연결 AC: AC-B5
- 수행: 개발 에이전트 (`STAGE=CODEX_BRIDGE`) + 사람 (모델 계정·키 준비(D-14), Infisical에 모델 자격 등록)

## 목표

`01` §6: Codex 작업을 시작하거나 명시적으로 연결하고, 질문·완료를 Discord로 중계한다 (R03, R08~R10).

## 제약

- 개인 Codex 홈을 자동 탐색하거나 제어하지 않는다. 대상은 NUC의 `~/.codex*` 전체다: `~/.codex`, `~/.codex-sub`, `~/.codex-work`와 그 심링크 `~/.codex2`(`-sub`), `~/.codex3`(`-work`). 옛 AIOps의 ChatGPT 구독 OAuth(시스템 사용자 `aiops-proxy`의 CLIProxyAPI 저장소)도 쓰지 않는다 (spec §4.5).
- 봇의 모델 계정과 Codex 홈은 D-14 결정값을 따른다. 추천은 전용 계정과 전용 CODEX_HOME이다.
- 작업자는 격리 공간에서 돌고, 게시 자격증명·운영 kubeconfig·SSH agent를 받지 않는다 (D-15).
- 모델 계정·키 준비와 Infisical 등록은 사람이 하고 [../approvals.md](../approvals.md)에 기록한다 (AC-X2).

## 완료 조건

- `04` §4 시험 TASK-01~03, SEC-02와 질문 경로의 AUTH-02 결과가 있다 (spec §7 AC-B5).
- spec §7 "단계 AC 공통 완료 규칙"을 따른다. 배정된 시험에 `fail`이 없다. `blocked`·`not_run`은 사유와 해소 티켓을 함께 적는다. 이 단계의 보안 경계 시험(SEC-02)은 이 경로에서 최소 `mock` 또는 `local_integration`으로 `pass`다.
- 어댑터 능력표가 있다.
- HANDOFF가 있다.

## 검증

`04` §4 시험. 지원되지 않는 기능은 `capability=false`로 표시한다.
