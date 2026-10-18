# T15 봇 V1 DISCOVERY

- 단계: P3 봇 준비 (P2와 병행)
- 상태: 진행 중 (2026-10-18). D-14~D-17·D-24와 V1 범위 조정안은 확정(사용자 2026-10-18, T15)이다(할 일 4·6 진행 메모). 산출물은 아직 로컬 초안이다. 남은 일은 셋이다. (1) 봇 저장소 `docs/ai-bot/` PR. (2) `ukyi-app/homelab-bot-ops` push. (3) homelab `rebuild` 커밋·push(spec §12). 셋 다 사람 승인 뒤에 한다. (2) 전에 하기로 한 Codex Connector 설치 범위 축소는 완료했다(사람 2026-10-18 17:45, [../approvals.md](../approvals.md). 할 일 4 진행 메모 D-16)
- 명세: [../spec.md](../spec.md)
- Blocked by: T14
- 선행 결정: D-14~D-17과 D-24(봇 변경 PR 작성 자격). 모두 이 티켓에서 정했다(확정(사용자 2026-10-18, T15)). 산출물 위치는 D-13(확정(사용자 2026-10-18, T14))
- 연결 AC: AC-B2
- 수행: 개발 에이전트 (`MODE=plan`) + 사람 (D-14~D-17·D-24 결정과 검토, Codex Connector 설치 범위 축소(`homelab-bot-ops` push 전. 2026-10-18 17:45 완료), Discord 서버·봇 계정과 모델 계정 준비). 모델 계정 준비의 시점은 T16b 전(모델을 처음 쓰는 단계 전)이고(spec §11 모델 행) T15 완료 조건이 아니다

## 목표

`01` §3을 실행해 봇 V1의 아키텍처, 결정, 능력표, 구현 순서, 수용 시험 계획을 만든다.

## 입력

- `00`과 `01` (T14 정비본). 실행 프롬프트는 [`00` §2](https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/prompts/00-start.md)(봇 저장소, 2026-10-18에 옮김).
- 플랫폼 설계 문서 [../platform/design.md](../platform/design.md) (T05 결정 포함).
- 이 명세 §1, §4.5, §5.
- `01` §3 "참고 입력: 옛 AIOps 교훈". 커밋 `2d2054a`(`legacy` 태그가 가리킬 커밋)에서 읽는다. 옛 사본에서는 fetch하지 않는다(`00` §5).
- 이미 설치된 ChatGPT Codex Connector App. org 전체 저장소에 쓰기 권한으로 설치돼 있었고(2026-10-18 17:45에 선택 저장소로 줄임), PR을 열면 자동 리뷰를 단다(spec §4.5, D-26). D-16 대안 비교의 실측 대상이다.

## 할 일

1. `01` §3의 질문 7개를 조사한다.
   - 진행 메모: 조사했다(2026-10-18). 답은 공개 초안 `DISCOVERY.md`에, 내부 경로와 실측 세부는 운영 초안(`DISCOVERY-internal.md`, evidence)에 있다.
2. 능력표를 실측한다: Discord, Codex(NUC에 codex-cli 0.163.0), herdr(0.9.5), GitHub App.
   - 진행 메모: 읽기 전용 실측(`--help`·버전, `gh api` GET, 패키지 로드)으로 `VERIFICATION.md` 초안을 채웠다. 모델 호출, 봇 계정 로그인, App 설치, 게시는 하지 않았다. 플랫폼이 필요한 항목은 `blocked`다(할 일 7).
3. D-16 대안은 Codex Connector로 실측한다. 트리거, 게시 방식, 설치 범위, 결과를 Discord로 가져올 수 있는지를 본다. 기존 PR 기록을 읽기 전용으로 조회해 확인하고(예: homelab PR #752의 리뷰 기록), 시험 PR이 더 필요하면 사람에게 요청한다.
   - 진행 메모: 기존 PR 기록을 읽기 전용 `gh api` GET으로 조회했다. 사람이 연 PR에는 자동 리뷰가 달렸고, 봇 App이 연 PR 1건에는 달리지 않았다(표본 1건). 결과는 `DECISIONS.md` D-16 근거와 `VERIFICATION.md`에 있다. D-16은 대안이 아니라 기본안으로 정했다(할 일 4).
4. D-14(모델 계정·인증)는 공식 약관을 확인한 뒤, D-15(실행 호스트·격리)·D-16(리뷰 방식)·D-17(Discord 대상)·D-24(봇 변경 PR 작성 자격)와 함께 결정한다. 에이전트는 근거와 추천을 `DECISIONS.md`에 적고, 결정은 사용자가 한다. D-16을 정할 때 모델 호출 전 `author_association` 확인(OWNER·MEMBER·COLLABORATOR, 설계 C.8)이 Renovate App PR과 봇 변경 PR App의 PR을 막는지 실측하고, 막으면 허용할 App을 따로 둘지 정한다(V1 기능 7, AC-B4).
   - 진행 메모: 확정(사용자 2026-10-18, T15). 사용자가 2026-10-18 16:29에 T15 질문에 답했다. 에이전트의 추천과 근거는 `DECISIONS.md` 초안에 있다.
     - D-14: 봇 전용 ChatGPT 구독 계정 + 작업자 전용 CODEX_HOME. 권장안(OpenAI API 프로젝트 키)이 아니라 사용자가 골랐다. 함께 지킬 조건은 다섯이다. 개인 `~/.codex*` 사용·복사 금지. 한도·인증 만료 때 다른 계정·인증으로 자동 전환하지 않고 대기. 작업 직렬 1개(동시성 1). 인증 갱신본 되쓰기를 위한 작업자 전용 영속 쓰기 공간(설계 C.8 변경, T08b·T16b 반영). 옛 구독 OAuth 프록시·다계정 순회 재사용 금지.
     - D-14 남은 위험: 공식 CI/CD 인증 안내가 구독 무인 실행을 고급 경로로 두고 "public or open-source repositories"에 쓰지 말라고 적는다 [확인: https://learn.chatgpt.com/docs/auth/ci-cd-auth , 2026-10-18]. 봇의 리뷰 대상은 public 저장소다. 이 문구의 적용 범위는 [미확인]이고 OpenAI 확인 항목으로 남긴다(spec §10).
     - D-15: NUC 클러스터 안. 게시 서버는 ns `app-homelab-bot`, 작업자는 `sandbox` ns의 상주 파드(동시성 1). 라벨 `homelab-bot`, 앱·작업자 포트 8080, 경보 수신 포트 8081. 작업자의 코드 읽기는 `codeload.github.com` 압축본만이다(작업자 egress에서 `github.com`·`api.github.com`·gist 제외, 작업자에 GitHub 자격 없음). 받은 코드는 작업자가 `git init`으로 한 번 커밋해 `codex exec`의 Git 저장소 요구를 맞추고, diff는 base·head 압축본으로 만든다. push와 PR 생성은 게시 서버가 D-24 App으로 한다. 파드 방화벽(U13)이 안 되면 호스트 전용 UID + nft로 물러난다. 사용자는 에이전트 설명(D-14 구독 인증 파일이 작업자에 있어 GitHub를 허용하면 남의 토큰으로 gist·push 유출이 가능하다)을 듣고 골랐다.
     - D-16: 기본안(전용 리뷰 App + 격리 리뷰어 + 제한 게시 서버). 봇이 리뷰하는 저장소는 저장소별 Codex 설정에서 Codex 자동 리뷰를 끈다(사람 작업, 수동 `@codex review`는 남김). Codex Connector 설치 범위는 선택 저장소로 줄이고 private 운영 저장소 `homelab-bot-ops`는 뺀다(사람 작업, D-26 연계).
     - D-16 Connector 축소 시점(확정(사용자 2026-10-18, T15), 위 결정 뒤 따로 받은 답): 사람이 이 티켓에서 `homelab-bot-ops`에 운영 산출물을 처음 올리기 전에 한다. 남길 저장소 후보는 public 저장소(`homelab`, `homelab-app-template`, `files`, `homelab-bot`)이고, `homelab-bot-ops`와 private 저장소(제거 예정 `aiops`·`mac-uptime-guard`, 보관 `aiops-autodeploy-canary`)는 뺀다. 최종 목록은 사람이 고른다. T17은 축소가 됐는지 확인만 한다.
     - D-16 Connector 축소 실행: 완료(사람 2026-10-18 17:45, [../approvals.md](../approvals.md)). `repository_selection` = `selected`는 `gh api` GET으로 확인했다. 남긴 저장소는 사용자 보고로 위 public 4개다. 저장소 목록은 `read:user` 권한이 없어 API로 확인하지 못했다.
     - D-16 하위(작성자 확인의 App 예외. 새 D-ID를 만들지 않고 D-16 안에 둔다): 실측에서 App이 연 PR은 `NONE` 또는 `CONTRIBUTOR`로 찍혀 OWNER·MEMBER·COLLABORATOR 확인에 막혔다. 그래서 허용 봇 작성자 목록을 둔다. `pull_request.user.type`이 `Bot`이고 숫자 `user.id`가 목록에 있으면 통과한다. 초기 목록은 호스팅형 Renovate 봇과 D-24 App의 봇 사용자(생성 뒤)다. 배포 갱신 App(`homelab-deploy`), Codex Connector, 옛 writer는 뺀다. fork PR은 제외하고, 댓글 트리거는 `comment.author_association`을 보며 Bot 댓글은 무시한다. `CONTRIBUTOR`는 허용하지 않는다. 실제 ID는 Infisical runtime policy(키 이름 예: `review.allowed_bot_author_ids`)에만 둔다. 허용 작성자의 PR 본문도 비신뢰 자료로 다룬다.
     - D-17: 봇 전용 개인 서버를 새로 만든다. `MESSAGE_CONTENT` 특권 intent 켬. 허용 채널에서 멘션이나 `/` 명령으로 공개 스레드를 시작하고 스레드 안은 멘션 없이 처리한다. 허용 사용자는 owner 1명, 채널 2개(대화, 알림·리뷰·브리핑), `auto_archive_duration` 1440분. 관리자·MANAGE_THREADS·MENTION_EVERYONE 권한 없음(허용 채널 overwrite로 권한). Public Bot 끔, 서버 설치만, Interactions Endpoint 비움(Gateway). `allowed_mentions`의 `parse`는 빈 목록. 실제 서버·채널·사용자 ID는 Infisical `/apps/homelab-bot/`에만 둔다. DM 허용 여부와 브리핑 시각은 T16a에서 정한다(미정). 에이전트 추천을 사용자가 수락했다.
     - D-24: 봇 전용 쓰기 GitHub App. Contents write + Pull requests write + Metadata read이고 Workflows·Actions·Administration·Issues는 없다. webhook 끔, 선택 저장소 설치, 작업마다 저장소 하나로 좁힌 1시간 토큰. 병합 API·`/merges`·`repository_dispatch`·update-branch·GraphQL 병합은 권한으로 못 막으므로 게시 서버 허용 목록이 막는다. 봇은 `.github/workflows` 변경 PR을 만들 수 없다(범위 축소로 명시). 토큰 분리, ruleset E 여부, App 이름·설치 저장소, 허용 파일 경로(설정 키 `github.change_writer_allow_paths`)는 T19에서 정한다(미정).
     - R08(V1 기능 3, 사용자가 명시적으로 연결한 기존 Codex 작업): 요구는 그대로 두고 연결 방식은 T18에서 다시 판단한다. 그때까지 보류다. T15 질문에서 추천으로 제시된 안이고 사용자가 골랐다. herdr 경유는 상태를 화면으로 추정하고 소켓에 인증이 없어 쓰지 않는다는 조사 결과는 근거로 남긴다.
5. 결정이 나면 같은 변경에서 spec §5.1로 옮기고 근거를 적는다. 봇 저장소 `docs/ai-bot/prompts/` 전체에서 그 D-ID를 검색해 자리를 고친다(spec §12). 이 변경은 봇 저장소 PR로 한다.
   - 진행 메모: 남은 일이다. 봇 저장소 `docs/ai-bot/prompts/`의 D-ID 자리 수정은 봇 저장소 PR로 하고, 사람 승인 뒤에 올린다. 수정 초안에서 T14 키워드 77줄의 줄 번호는 같다. 색인 표 끝에 행을 더해 `01`은 2줄(§11), `04`는 1줄(§10) 늘었고 `00`은 그대로다. 이 줄 수 변화는 허용했다(에이전트 정리).
6. `V1_PLAN.md`에 일정 위험(spec §10 6번) 대응으로 범위 조정안을 제안한다. 사용자가 정한다.
   - 예: STAGE별 제한 시범 운영(T17 뒤 시험 저장소에서 PR 리뷰만 실사용), T16의 로컬·mock 구현을 T13 완료 전에 시작하고 실연동만 T13 뒤로.
   - 기능 수를 줄이는 것은 C-08 변경이라 별도 결정이다.
   - 순서를 바꾸는 안을 고르면 spec §8 그래프와 해당 티켓을 같은 변경에서 고친다.
   - 진행 메모: 확정(사용자 2026-10-18, T15): 안 3(시범 운영 + 로컬 선행). (1) STAGE별 제한 시범 운영: 예를 들어 T16b 뒤 허용 채널에서 읽기 조회만, T17 뒤 시험 저장소에서 PR 리뷰만 실사용한다. 단계마다 사람이 승인하고 [../approvals.md](../approvals.md)에 기록한다. (2) T16을 T16a(FOUNDATION 로컬·mock, T15 뒤 바로 착수)와 T16b(실연동·첫 배포, T13 뒤)로 나눈다. 기능 수는 줄이지 않는다(C-08 그대로). 티켓은 할 일 8에서 고쳤다.
7. 플랫폼이 아직 구축 중이면 플랫폼 실측 항목은 `blocked`로 남기고, T16b 시작 때 다시 확인한다(T16을 나눈 뒤 플랫폼 실연동은 T16b다).
   - 진행 메모: `blocked`로 남긴 항목은 읽기 계정 셋, Grafana 질의 범위(U12), Argo CD live ConfigMap, sandbox init 방화벽(U13)·DNS 없는 도구(U29), webhook 경로(T08a), Alertmanager 봇 route, ruleset A~D, 새 Renovate·봇 App PR의 `author_association`, 봇 파드의 Discord IPv4 443 연결, 작업자의 `codeload.github.com` 받기와 다른 GitHub 호스트 차단, 영속 쓰기 공간 유지다. 전체 목록은 봇 저장소 `DISCOVERY.md` §9, 확인 명령은 `VERIFICATION.md` 끝 점검표다. T16b 할 일 1이 다시 확인한다.
8. 끝나면 T16~T21을 `V1_PLAN.md`에 맞춰 갱신한다(spec §12).
   - 진행 메모: 2026-10-18에 고쳤다. T16을 [T16a](T16a-bot-foundation-local.md)(로컬·mock, T15 뒤)와 [T16b](T16b-bot-foundation-deploy.md)(실연동·첫 배포, T13·T16a 뒤)로 나누고 옛 T16 파일은 지웠다. T17~T21에 확정 결정과 그 결정이 바꾸는 범위를 넣었다. T17·T18·T20은 T16a 뒤 착수, T16b 뒤 완료다. T22의 T16 참조는 T16b로 바꿨다.

## 산출물

산출물은 공개 여부로 나눈다(D-13 확정(사용자 2026-10-18, T14): 봇 저장소는 public, 운영 산출물은 봇 저장소에 두지 않는다).

- 봇 저장소 `ukyi-app/homelab-bot`의 `docs/ai-bot/`(공개): `DISCOVERY.md`(내부 경로·실제 허용 목록을 뺀 판), `ARCHITECTURE.md`, `DECISIONS.md`, `VERIFICATION.md`(요약. 내부 정보는 뺀다), `V1_PLAN.md`, `PROJECT_STATUS.md`, 비밀값 없는 설정 초안(키 이름만).
- private 저장소 `ukyi-app/homelab-bot-ops`: HANDOFF, evidence, DISCOVERY의 내부 경로·실측 세부.
- Infisical `/apps/homelab-bot/`: runtime-policies와 허용 목록의 실제 값(봇이 실행 중 읽는 값). 등록은 사람이 한다(spec §11). 봇 저장소에는 키 이름만 둔다.

봇 저장소(`homelab-bot`, `homelab-bot-ops`)가 아직 없으면 같은 구성을 로컬 초안으로 두고, 저장소 커밋을 `blocked`(사유: 봇 저장소 없음, 해소: T14의 생성 요청)로 기록한다. 초안의 위치는 HANDOFF에 적는다.

진행 메모: 두 저장소는 T14가 2026-10-18에 만들었다. 지금 산출물이 로컬 초안인 이유는 저장소가 없어서가 아니라 사람 승인 대기다. 저장소 반영은 `blocked`(사유: 사람 승인 대기, 해소: [../approvals.md](../approvals.md) 기록 뒤)로 기록한다. 로컬 경로는 공개 문서에 쓰지 않고 운영 초안 `DISCOVERY-internal.md` §2에 적었다. 세션 임시 위치라 세션이 끝나면 사라질 수 있다.

## 제약

- 계정 생성, App 설치, 외부 PR·댓글 게시, 운영 배포를 하지 않는다 (`00` §2).
- 봇 저장소 `ukyi-app/homelab-bot`은 public이다(D-13). 저장소에 넣는 산출물은 공개되므로 시크릿 값과 운영 민감 정보(토큰 목록, 내부 접근 경로의 세부)를 쓰지 않는다. 플랫폼 프롬프트 머리말의 "공개 범위"와 같은 기준이다. HANDOFF와 운영 산출물은 위 "산출물"대로 `homelab-bot-ops`와 Infisical에 둔다.
- Discord 서버·봇 계정과 모델 계정은 사람이 준비하고 [../approvals.md](../approvals.md)에 기록한다 (AC-X2). 모델 계정 준비의 시점은 T16b 전(모델을 처음 쓰는 단계 전)이고(spec §11 모델 행) T15 완료 조건이 아니다.

## 완료 조건

- `01` §3 완료 조건을 채웠다.
- D-14~D-17, D-24가 결정됐고, spec §5.1과 봇 저장소 `docs/ai-bot/prompts/`의 자리에 반영됐다.
- `V1_PLAN.md`에 범위 조정안과 사용자의 선택이 있다.
- 공개 산출물이 봇 저장소에 PR로 병합돼 있고(main은 `app-main`으로 보호돼 PR로만 들어간다. 병합은 사람 승인 뒤), HANDOFF와 개발 산출물은 private 저장소 `ukyi-app/homelab-bot-ops`에 있고, 봇 저장소에는 운영 산출물이 없다(D-13). spec 변경은 homelab `rebuild`(T07 뒤에는 PR로 main)에, 봇 문서 변경은 봇 저장소 PR로 들어가 있다 (명세 AC-X1).

## 검증

`04` §7 HANDOFF 양식으로 검토한다. 추정을 사실로 쓴 곳이 없는지 확인한다.
