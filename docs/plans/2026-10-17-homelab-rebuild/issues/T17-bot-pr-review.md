# T17 봇 PR_REVIEW

- 단계: P4 봇 V1
- 상태: 진행 중 (로컬·mock 구현 병합 2026-10-29, 봇 저장소 PR #7 `de304c8`, 시험 358. 완료는 T16b 뒤. 공개 저장소 내용으로 구독 모델을 부르는 작업의 D-14 차단 조건은 2026-11-04 해제(Claude 구독 프로필). 결정 5건·시험 저장소 `homelab-smoke`는 2026-11-04 사용자 확정(봇 저장소 `docs/ai-bot/DECISIONS.md` "T17 결정"). 리뷰 레인의 인증 격리 조건은 무도구 경계 시험으로 갈음(사용자 2026-11-04, DECISIONS "T18 결정 (Claude 실행기 기준)"). 리뷰 App `ukyi-review` 생성·`homelab-smoke` 설치·키 등록 2026-11-04(사람). **실가동 구현 운영 배포 2026-11-04, 리뷰는 꺼짐:** 봇 저장소 PR #38~#44(main `bd0bc8f`), homelab #1053(리뷰 App 자격 연결, `REVIEW_ENABLED` 없음)·#1055(sandbox 작업자 이미지). 작업자 로그 `review:"open"`, 게시 서버 로그 `review_gate closed switch_off`, 실제 모델 호출·리뷰 게시 0건. 모델 없는 배포 확인(작업자 파드에서 `homelab-smoke` 실제 압축본을 프록시로 받아 해제, 금지 호스트·SNI 위장 차단, 리뷰 job·게시 0건)은 통과. **리뷰 켬 2026-11-04 17:31(사용자 승인, 시범 P-2 시작, 대상 `homelab-smoke`만):** Infisical `RUNTIME_POLICIES` review 절(17:22), homelab #1058(`REVIEW_ENABLED`). 첫 시험 PR `homelab-smoke` #11은 두 번 막힌 뒤 게시됐다. (1) 비공개 조직 멤버십이라 작성자가 `CONTRIBUTOR`로 보여 `author_denied`. 멤버십 공개로 해소(사용자 승인 17:40). 설계 C.8 허용 목록은 사람 작성자가 공개 멤버이거나 협업자라는 전제가 필요하다. (2) CLI 2.1.308 내장 플러그인 때문에 무도구 경계가 `policy_violation`. 봇 #46·homelab #1060으로 해소. 18:13 COMMENT 리뷰 1건(인라인 2)과 Discord 요약이 나갔고, 심은 결함 2개를 모두 찾았다(오탐 0). Codex 자동 리뷰는 오지 않았다. 반례·복구 시험 A 묶음 7건 pass(2026-11-04 19:22~19:33, 사용자 승인: 댓글 명령, 닫기·다시 열기, draft, 실행 중 head 이동, base 바꾸기, 공개 범위 차단, partial). A7에서 난 오탐(제외 파일을 모델이 몰라 "파일 없음")은 봇 #50·homelab #1067로 모델 입력에 제외 목록을 넣어 고쳤고, 같은 PR 재시험에서 사라졌다(20:21). 남은 것: B 묶음(Renovate PR, fork·허용 밖 작성자, webhook 재전송, 한도·인증 대기와 제어 명령, 게시 응답 유실 대조, 일부 사람 준비), 실모델 평가 사례 확대, 완료 판정. 시험 기록은 봇 저장소 `docs/ai-bot/VERIFICATION.md` "T17 실가동 구현")
- 명세: [../spec.md](../spec.md)
- Blocked by: T16a(착수), T16b(완료)
  - 차단 조건(D-14, 확정(사용자 2026-10-18, PR #3 리뷰). Claude 구독 프로필에서 해제(사용자 2026-11-04, 봇 저장소 `docs/ai-bot/DECISIONS.md` D-14 "재조사와 해제"). 아래는 해제 전 조건이고 Codex 프로필로 돌아가면 다시 적용): OpenAI가 공개 저장소에 봇 전용 구독 인증 사용을 허용한다고 확인하거나 API 키 같은 공식 지원 인증으로 바꾸기 전에는, 공개 저장소 PR 내용으로 구독 모델을 부르는 일(평가셋, `authorized_external`, 시범 P-2)을 하지 않는다. 모델을 부르지 않는 로컬·mock 구현은 T16a 뒤 착수할 수 있다. 봇 저장소 `docs/ai-bot/DECISIONS.md` D-14.
  - 인증 파일 격리(봇 저장소 `ARCHITECTURE.md` §5.1 "인증 파일 분리")를 정하고 그 SEC-02 사례(작업 레인 비신뢰 코드에서 `auth.json` 읽기 거부)가 통과한 뒤에만 모델을 부른다(봇 저장소 PR #3 마지막 리뷰 반영). T18보다 먼저 모델을 부르면 이 판단을 여기서 한다.
  - 착수: [T16a](T16a-bot-foundation-local.md) 뒤. 공유 계약(T16a 소유)에 PR 경로를 더하는 로컬·mock 구현을 시작한다(V1 범위 조정 안 3).
  - 완료: [T16b](T16b-bot-foundation-deploy.md) 뒤. 봇이 배포되고 webhook 경로(T08a)가 있어야 리뷰 App 시험 PR의 실연동(`authorized_external`)을 본다.
- 선행 결정: D-16 (확정(사용자 2026-10-18, T15): 기본안. 전용 리뷰 App + 격리 리뷰어 + 제한 게시 서버, 작성자 확인의 App 예외는 허용 봇 작성자 목록), D-18 (의존성 업데이트 PR의 출처. 확정(사용자 2026-10-18, T05): 호스팅형 Renovate App 저장소별 설치, 자동 병합 모두 끔), D-14 (확정(사용자 2026-10-18, T15): 봇 전용 ChatGPT 구독 계정. 아래 "남은 위험"), D-15 (확정(사용자 2026-10-18, T15): 작업자 코드 읽기는 `codeload.github.com` 압축본만, 작업자에 GitHub 자격 없음), D-17 (확정(사용자 2026-10-18, T15): 리뷰 요약은 알림·리뷰·브리핑 채널), V1 범위 조정 안 3 (확정(사용자 2026-10-18, T15): STAGE별 제한 시범 운영)
- 연결 AC: AC-B4
- 수행: 개발 에이전트 (`STAGE=PR_REVIEW`) + 사람 (리뷰 전용 App 생성·설치와 그 키의 Infisical 등록, 봇 리뷰 저장소의 Codex 자동 리뷰 끄기, 허용 봇 작성자 ID 등록, 시험 PR 게시 승인, 시범 운영 승인). Codex Connector 설치 범위 축소는 T15에서 사람이 했고(2026-10-18 17:45) 이 티켓은 확인만 한다. 봇 전용 구독 계정 준비와 `auth.json` 첫 시드(D-14)는 T16b 전(모델을 처음 쓰는 단계 전)에 끝났다고 전제한다

## 목표

`01` §5: 전용 GitHub App으로 PR을 자동 리뷰하고 `COMMENT`만 게시한다 (R11, R12). R14(독립 검증)는 CHANGE_PR(T19)에만 배정한다(사용자 2026-10-18, T14).

## 할 일

1. 시작 전에 사람 작업을 확인한다. 모두 [../approvals.md](../approvals.md)에 기록한다 (AC-X2).
   - 리뷰 전용 App 생성·설치(시험 저장소부터)와 키의 Infisical `/apps/homelab-bot/` 등록. 권한은 설계 C.8 표대로 `issues read`(PR 댓글 리뷰 요청의 `issue_comment` 구독용)까지 넣는다. T10 시험 App에는 이 권한이 빠져 있었다(T13 봇 자리 확인, 2026-10-27).
   - 봇이 리뷰하는 저장소마다 저장소별 Codex 설정에서 Codex 자동 리뷰를 끈다. 수동 `@codex review`는 남긴다(D-16).
   - Codex Connector 설치 범위 축소는 확인만 한다. 축소는 사람이 T15에서 `homelab-bot-ops`에 운영 산출물을 처음 올리기 전에 했다(2026-10-18 17:45, D-16, D-26 연계. 시점은 확정(사용자 2026-10-18, T15)). 설치 범위가 선택 저장소이고 `homelab-bot-ops`가 없는지, 그 기록이 approvals에 있는지 본다. 그 기록에서 API로 확인한 것은 `repository_selection` = `selected`뿐이다. 남긴 저장소 목록은 사용자 보고이고 API 확인은 아직이다(`read:user` 권한 없음).
   - D-14 봇 전용 구독 계정 준비와 작업자 `auth.json` 첫 시드가 T16b 전(모델을 처음 쓰는 단계 전)에 끝났고 approvals에 기록돼 있는지 본다. 리뷰어는 같은 작업자와 같은 `auth.json`을 쓴다(동시성 1).
   - 허용 봇 작성자 목록에 호스팅형 Renovate 봇의 숫자 사용자 ID를 넣는다. D-24 App의 봇 사용자는 T19에서 App을 만든 뒤 넣는다. 실제 ID는 Infisical runtime policy(키 이름 예: `review.allowed_bot_author_ids`)에만 둔다.
2. `01` §5의 계약을 코드와 시험에 반영한다.
3. 모델 호출 전 작성자 확인을 D-16대로 만든다.
   - 통과: `author_association`이 OWNER·MEMBER·COLLABORATOR(설계 C.8)이거나, `pull_request.user.type`이 `Bot`이고 숫자 `user.id`가 허용 봇 작성자 목록에 있다.
   - 이유: App이 연 PR은 `NONE` 또는 `CONTRIBUTOR`로 찍혀 앞의 확인에 막혔다 [실측: T15, `gh api` GET].
   - 목록에 넣지 않는 것: 배포 갱신 App(`ukyi-deploy`), Codex Connector, 옛 writer App.
   - `CONTRIBUTOR`는 허용하지 않는다. fork PR은 제외한다.
   - 댓글 트리거는 `comment.author_association`을 보고, Bot이 쓴 댓글은 무시한다.
   - 허용 작성자의 PR 본문도 비신뢰 자료로 다룬다. Renovate PR 본문에는 상류 릴리스 노트가 그대로 들어간다 [실측: T15].
4. 리뷰어 작업자는 GitHub 자격 없이 `codeload.github.com`의 base·head 압축본만 받고, diff는 두 압축본으로 만든다(D-15). 게시는 게시 서버가 리뷰 App으로 한다.
5. 끈 뒤 시험 저장소에서 Codex 자동 리뷰가 달리지 않는지 확인한다. 저장소 설정에서 어떤 작성자의 PR까지 Codex가 리뷰하는지(봇·Renovate PR 포함 여부)는 사람이 Codex 설정 화면에서 확인해 HANDOFF에 적는다.
6. 실연동 전에 봇 저장소 PR #7(2026-10-29)에서 이월한 Codex 리뷰 P2를 고친다(`src/review.ts`·`src/review-input.ts`). T16b 할 일 7에서 옮겼다(lead 결정 2026-11-02. 리뷰 레인이 T16b에서 꺼져 있었다). 같은 멈춤 규칙(1라운드 수정 → 재리뷰 → P1 없으면 병합)을 따르고, 스레드 답글은 이미 남겼다.
   - 중복 세대에 댓글 명시 요청의 `trigger`를 `comment`로 올린다.
   - 원격 조회 뒤 POST 직전에 최신 정책(저장소 허용·revision·출력 분류·게시 상한)을 다시 확인한다.
   - `unknown` 게시 행 대조 대상을 커서로 순환한다(지금은 최신 20개만).
   - 보안: `editScript` diff 계산의 메모리 상한(linear-space diff 또는 계산 전 복잡도 한도·deadline). 입력 한도 `maxDiffBytes`는 계산 뒤에만 본다.
7. T16b에서 `not_run`으로 남은 EVENT-01(같은 논리 이벤트 중복 전달 → 작업 1건)을 GitHub webhook 재전송(`duplicate_delivery`)으로 실연동한다. Discord에서는 중복 전달을 시점을 정해 만들 수 없었고, webhook 재전송은 재현할 수 있다(T16b "결과"). Discord 경로는 T21이다.

## 시범 운영 (완료 뒤)

- 이 티켓이 끝나면 시험 저장소에서 PR 리뷰만 실사용한다(V1 범위 조정 안 3, 확정(사용자 2026-10-18, T15)). V1 출시 판정 기준은 그대로다.
- 대상 저장소를 늘릴 때마다 사람이 승인하고 [../approvals.md](../approvals.md)에 기록한다.

## 제약

- App 설치는 시험 저장소부터 시작한다. 승인은 [../approvals.md](../approvals.md)에 남긴다 (AC-X2).
- `APPROVE`, `REQUEST_CHANGES`, merge, auto-merge는 게시 서버가 코드로 거부한다.
- 리뷰는 참고용이다. 자동 병합 범위(D-07) 안의 PR은 리뷰보다 먼저 병합될 수 있다.
- 한 저장소에 두 기본 리뷰를 동시에 켜지 않는다(`01` §3). Codex Connector는 설치된 저장소의 PR마다 자동 리뷰한다(spec §4.5, D-26). T15의 축소 뒤에도 남긴 저장소는 public 저장소(`homelab`, `homelab-app-template`, `files`, `homelab-bot`. 사용자 보고, 2026-10-18 17:45)라 봇이 리뷰하는 저장소와 겹친다. 그래서 봇이 리뷰하는 저장소에서는 Codex 자동 리뷰를 끈다(할 일 1, 5).
- D-16이 기본안으로 확정돼(사용자 2026-10-18, T15) 리뷰는 봇의 제한 게시 서버를 거친다. 외부 자동 리뷰를 고를 때 필요했던 REVIEW-04·DATA-01 검증 경계 재정의는 하지 않는다.
- 남은 위험(D-14): 공식 CI/CD 인증 안내가 구독 무인 실행을 "public or open-source repositories"에 쓰지 말라고 적는다 [확인: https://learn.chatgpt.com/docs/auth/ci-cd-auth , 2026-10-18]. 이 티켓의 리뷰 대상은 public 저장소다. 적용 범위는 [미확인]이고 OpenAI 확인 항목이다(spec §10).

## 완료 조건

- `04` §4 시험 REVIEW-01~05, SEC-01·02, DATA-01, EVENT-02와 PR 경로의 AUTH-01·EVENT-01·EVENT-03 결과가 있다 (spec §7 AC-B4).
- spec §7 "단계 AC 공통 완료 규칙"을 따른다. 배정된 시험에 `fail`이 없다. `blocked`·`not_run`은 사유와 해소 티켓을 함께 적는다. 이 단계의 보안 경계 시험(AUTH-01, SEC-01·02, DATA-01, REVIEW-04)은 이 경로에서 최소 `mock` 또는 `local_integration`으로 `pass`다.
- PR 경로의 AUTH-01에 D-16 사례가 있다: `MEMBER` 통과, `NONE`·`CONTRIBUTOR`·`FIRST_TIME_CONTRIBUTOR` 차단, 허용 봇 ID 통과, 허용 밖 봇 ID 차단, fork PR 차단, Bot 댓글 무시.
- 의존성 갱신 PR(D-18, Renovate PR)의 리뷰 결과가 1건 이상 있다.
- `04` §6 리뷰 품질 표가 있다.
- 봇이 리뷰하는 저장소에서 Codex 자동 리뷰가 꺼져 있고, Codex Connector 설치 범위에 `homelab-bot-ops`가 없다.
- HANDOFF가 있다.

## 검증

`04` §4 시험과 §6 품질 측정.
