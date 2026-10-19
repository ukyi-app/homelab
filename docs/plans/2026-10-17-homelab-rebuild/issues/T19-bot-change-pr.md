# T19 봇 CHANGE_PR

- 단계: P4 봇 V1
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: T17, T18
- 선행 결정: D-07 (자동 병합 범위. 확정(사용자 2026-10-18, T05): 배포 App이 만든 한 앱의 digest PR만 자동 병합, 서버 강제), D-24 (봇 변경 PR 작성 자격. 확정(사용자 2026-10-18, T15): 봇 전용 쓰기 GitHub App. Contents write + Pull requests write + Metadata read, Workflows·Actions·Administration·Issues 없음, webhook 끔, 선택 저장소 설치, 작업마다 저장소 하나로 좁힌 1시간 토큰. 토큰 분리, ruleset E 여부, App 이름·설치 저장소, 허용 파일 경로는 이 티켓에서 정한다), D-15 (확정(사용자 2026-10-18, T15): 작업자는 GitHub 자격 없이 `codeload.github.com` 압축본만 읽고, push와 PR 생성은 게시 서버가 D-24 App으로 한다), D-16 (확정(사용자 2026-10-18, T15): 허용 봇 작성자 목록에 D-24 App의 봇 사용자를 생성 뒤 넣는다)
- 연결 AC: AC-B6
- 수행: 개발 에이전트 (`STAGE=CHANGE_PR`) + 사람 (D-24의 남은 하위 항목 결정, 봇 쓰기 신원(D-24) 생성·설치와 키의 Infisical 등록, 허용 봇 작성자 ID 추가, 시험 PR 게시 승인)

## 목표

`01` §7: 격리 작업공간에서 수정하고, 별도 세션이 검토한 뒤, 제안 PR을 만들고, 병합 뒤 배포 상태를 읽는다 (R13~R15).

## 할 일

1. 사용자가 D-24의 남은 하위 항목을 정한다: App 이름, 설치 저장소, 토큰 분리, ruleset E 여부, 허용 파일 경로(설정 키 `github.change_writer_allow_paths`). 추천과 근거는 봇 저장소 `DECISIONS.md` D-24에 있다. 허용 파일 경로는 `DECISIONS.md` D-24와 `V1_PLAN.md` §5 T19 행이 이 티켓으로 넘겼고 추천은 아직 없다.
2. 시작 전에 D-24 신원이 생성돼 허용 저장소에 설치돼 있는지 확인한다. 생성·설치와 키의 Infisical `/apps/homelab-bot/` 등록은 사람이 하고 [../approvals.md](../approvals.md)에 기록한다 (AC-X2).
3. 이 App의 봇 사용자 숫자 ID를 허용 봇 작성자 목록에 넣는다(D-16, T17 할 일 1). 실제 ID는 Infisical runtime policy(키 이름 예: `review.allowed_bot_author_ids`)에만 둔다. 사람이 등록한다.
4. 플랫폼이 이 신원의 PR을 자동 병합하지 않는지 확인한다(AC-P8). 확인하지 못하면 봇 PR을 만들지 않고 `blocked`로 둔다.
5. `01` §7의 계약을 코드와 시험에 반영한다.
6. 게시 서버의 허용 API 목록을 정하고 CHANGE-02로 시험한다. 출발점은 `DECISIONS.md` D-24 "게시 서버 허용 API" 초안([가정]. git data API, `bot/` 접두 ref만 만들고 `force: false`로 갱신, head가 `bot/…`인 `POST /pulls`, 제목·본문만 바꾸는 `PATCH /pulls/{n}`)이다. 그 밖은 거부한다.

## 제약

- main 쓰기, merge, auto-merge 활성화, workflow_dispatch는 게시 서버가 거부한다. 자동 병합 범위(D-07)에 걸리는 PR은 만들지 않는다.
- 병합 API(`PUT /pulls/{n}/merge`), `POST /merges`, `repository_dispatch`, update-branch, GraphQL 병합은 Contents write 권한으로 막을 수 없다. 그래서 게시 서버 허용 목록이 막는다(D-24).
- 브랜치 push와 PR 생성은 D-24 신원으로만 한다. 리뷰 App 키나 플랫폼의 배포 쓰기 자격을 쓰지 않는다(`00` §6, `01` §5).
- push와 PR 생성은 게시 서버가 한다. 작업자는 GitHub 자격이 없고, 코드는 `codeload.github.com` 압축본 + `git init`으로 받는다(D-15).
- 봇은 `.github/workflows` 변경 PR을 만들 수 없다. Workflows 권한이 없기 때문이고, V1의 범위 축소로 받아들였다(D-24). git push 경로로도 워크플로 파일 변경이 거부되는지는 [미확인]이다(설계 E5 시험).
- 비신뢰 코드 실행: 작업 코드의 패키지 설치·시험과 모델이 띄우는 셸은 T18이 정한 인증 파일 분리 방식(봇 저장소 `ARCHITECTURE.md` §5.1 열린 항목, T18 할 일 5)을 따른다. 그 판단이 나오기 전에는 비신뢰 코드를 인증 파일(`auth.json`)이 없는 경로에서만 돌리고, 그럴 수 없으면 그 작업을 `blocked`로 둔다.

## 완료 조건

- `04` §4 시험 CHANGE-01~03, DEPLOY-01, DATA-01과 변경 작업자 경로의 SEC-02, 게시 경로의 EVENT-02 결과가 있다 (spec §7 AC-B6).
- spec §7 "단계 AC 공통 완료 규칙"을 따른다. 배정된 시험에 `fail`이 없다. `blocked`·`not_run`은 사유와 해소 티켓을 함께 적는다. 이 단계의 보안 경계 시험(SEC-02, DATA-01, CHANGE-02)은 이 경로에서 최소 `mock` 또는 `local_integration`으로 `pass`다.
- CHANGE-02에 D-24 사례가 있다: merge, `/merges`, `/dispatches`, update-branch, GraphQL 병합·auto-merge, `bot/` 밖 ref, force push, 워크플로 파일 변경 거부.
- HANDOFF가 있다.

## 검증

`04` §4 시험.
