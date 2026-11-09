# 동료 봇 계획 (2026-11-09)

homelab-bot을 회사에서 같이 일하는 동료처럼 바꾸는 계획의 티켓 색인이다. owner는 '/' 명령 대신 `@` 멘션으로 부르고, 봇은 해요체로 결론부터 답하며, 무언가를 바꾸는 일은 봇이 한 줄로 되묻고 owner가 버튼으로 확정해야 실행된다. 모델이 멈추면 Discord에는 자리 비움만 보이고 원인은 Telegram으로 간다. 관리 기능과 계정 전환은 `homelab bot` CLI로 한다. 봇이 만든 변경 PR은 owner가 GitHub에서 리뷰하고, 고칠 것은 Discord에서 말하면 봇이 같은 PR에 수정 커밋을 올린다. 다른 PR도 Discord에서 리뷰를 부탁할 수 있다.

- 명세: 봇 저장소 `ukyi-app/homelab-bot`의 `docs/ai-bot/COLLEAGUE_SPEC.md`(https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md). 인수 조건 AC-1~AC-30과 검증 경계 S1~S5가 거기 있다.
- 결정: 같은 저장소 `docs/ai-bot/DECISIONS.md` "동료 봇 전환 (사용자 2026-11-09)"과 D-14의 변경 문단.
- 용어: 같은 저장소 루트 `GLOSSARY.md`.
- 상태: 계획 완료(feature-plan 합의·명세·티켓, 사용자 2026-11-09). 구현 대기.
- 다른 계획과의 관계: 재구축 계획(`docs/plans/2026-10-17-homelab-rebuild/`)의 T33(봇 PR #108, A05 승인 digest 한 페이지)이 C17의 외부 선행이다. 재구축 계획의 T35(V1 시범 운영)는 이 계획이 끝난 뒤, 곧 마지막 티켓 C24(시범 통합 검증)가 끝난 뒤 시작한다(사용자 2026-11-09). 처음 C01~C24였고 같은 날 PR 수정 반복 갈래(C25~C31)가 더해졌다.
- 기록 규칙: 티켓 상태가 바뀌면 티켓 머리말과 1절 표를 같이 고친다. 외부 변경(배포 PR 병합, 운영 스위치, 계정 등록)은 재구축 계획의 `approvals.md`에 적는다(AGENTS.md 변경 규칙). 이 폴더 이름을 바꾸면 재구축 계획 T35 머리말과 `spec.md` §8의 경로도 같은 변경에서 고친다.

## 1. 티켓 목록

| ID | 제목 | 단계 | Blocked by | 상태 | 수행 |
|---|---|---|---|---|---|
| [C01](issues/C01-colleague-switch.md) | 동료 기능 스위치 | 1 기반 | 없음 | 진행 중 | 에이전트 |
| [C02](issues/C02-worker-contract-v2.md) | 작업자 대화·리뷰 계약 v2 받기 | 1 기반 | 없음 | 진행 중 | 에이전트 |
| [C03](issues/C03-worker-rate-limit-info.md) | 작업자 한도 정보 읽기 | 1 기반 | C02 | 대기 | 에이전트 |
| [C04](issues/C04-reaction-lifecycle.md) | 반응 수명 | 1 기반 | 없음 | 진행 중 | 에이전트 |
| [C05](issues/C05-admin-cli-homelab-bot.md) | 관리 CLI `homelab bot` | 1 기반 | C01 | 대기 | 에이전트 + 사람(운영 확인) |
| [C06](issues/C06-deploy-worker-v2.md) | 작업자 v2 배포 | 2 배포와 표면 | C02, C03, C25 | 대기 | 에이전트 + 사람(배포 PR) |
| [C07](issues/C07-reply-owner-call-thread-marker.md) | 답장·owner 호출·스레드 제목·작은 표식 | 2 배포와 표면 | C04, C09 | 대기 | 에이전트 |
| [C08](issues/C08-mention-scope-reply-context.md) | 멘션 받는 범위와 봇 글 답장 맥락 | 2 배포와 표면 | C02, C07 | 대기 | 에이전트 |
| [C09](issues/C09-fixed-text-chat-task-control.md) | 고정 문구 1: 대화·작업·제어 안내 | 2 배포와 표면 | C01, C04 | 대기 | 에이전트 |
| [C10](issues/C10-fixed-text-memory-briefing.md) | 고정 문구 2: 기억·브리핑 | 2 배포와 표면 | C01, C04 | 대기 | 에이전트 |
| [C11](issues/C11-chat-v2-switchover.md) | 대화 v2 전환 | 3 새 형식 켜기 | C01, C04, C06, C08 | 대기 | 에이전트 |
| [C12](issues/C12-pr-review-voice.md) | PR 리뷰 말투 | 3 새 형식 켜기 | C06 | 대기 | 에이전트 |
| [C13](issues/C13-proposal-run-confirmation.md) | 제안과 실행 확인 | 4 말로 실행 | C01, C11 | 대기 | 에이전트 |
| [C14](issues/C14-remaining-actions.md) | 나머지 동작 연결 | 4 말로 실행 | C13 | 대기 | 에이전트 |
| [C15](issues/C15-attach-key-button.md) | 세션 연결 키 버튼 | 4 말로 실행 | C13 | 대기 | 에이전트 |
| [C16](issues/C16-task-question-direct-answer.md) | 작업 질문 바로 답 | 4 말로 실행 | C09, C13 | 대기 | 에이전트 |
| [C17](issues/C17-publish-approval-button.md) | 게시 승인 버튼 | 4 말로 실행 | C13, 재구축 T33(외부, 충족) | 대기 | 에이전트 |
| [C18](issues/C18-fixed-text-change-review-alert-attach.md) | 고정 문구 3: 변경·리뷰 알림·경보·세션 연결 | 4 말로 실행 | C01, C12, C15, C17 | 대기 | 에이전트 |
| [C19](issues/C19-limit-resume-review-deferral.md) | 한도 재개와 리뷰 미루기 | 5 멈춤과 계정 | C05, C09, C10, C11, C12 | 대기 | 에이전트 |
| [C20](issues/C20-away-status.md) | 자리 비움 | 5 멈춤과 계정 | C04, C09, C12, C19, C21 | 대기 | 에이전트 |
| [C21](issues/C21-ops-alert-telegram.md) | 운영 알림 | 5 멈춤과 계정 | C19 | 대기 | 에이전트 + 사람(발화 시험) |
| [C22](issues/C22-account-switch-token-expiry.md) | 계정 등록·전환(구독)과 토큰 만료 알림 | 5 멈춤과 계정 | C05, C10, C19, C21 | 대기 | 에이전트 + 사람(실토큰·운영 전환) |
| [C23](issues/C23-api-credit-mode.md) | API 크레딧 방식 | 5 멈춤과 계정 | C06, C22 | 대기 | 에이전트 + 사람(Console 키·배포 PR) |
| [C24](issues/C24-pilot-integration-verification.md) | 시범 통합 검증 | 7 통합 | C01~C23, C25~C31 전부 | 대기 | 에이전트 + 사람 |
| [C25](issues/C25-change-authoring-v2.md) | 작업자 변경 작성 v2: 확인할 것·선택지 질문·수정 차례 입력 | 1 기반 | C03 | 대기 | 에이전트 |
| [C26](issues/C26-github-io-extension.md) | GitHub 쓰기·읽기 확장 | 1 기반 | 없음 | 진행 중 | 에이전트 |
| [C27](issues/C27-change-pr-revision.md) | 수정 요청 | 6 PR 수정 | C06, C13, C17, C25, C26, C29, C31 | 대기 | 에이전트 |
| [C28](issues/C28-change-question-choices.md) | 변경 질문 선택지 | 4 말로 실행 | C06, C16, C25 | 대기 | 에이전트 |
| [C29](issues/C29-guide-comments-check-items.md) | 안내 댓글과 확인할 것 | 4 말로 실행 | C06, C17, C25, C26 | 대기 | 에이전트 |
| [C30](issues/C30-review-request.md) | 리뷰 요청(Discord, 조직 저장소) | 4 말로 실행 | C12, C13, C19, C26 | 대기 | 에이전트 + 사람(리뷰 App 설치 범위) |
| [C31](issues/C31-pre-publish-self-fix.md) | 게시 전 자체 리뷰 고치기 | 6 PR 수정 | C06, C17, C25 | 대기 | 에이전트 |

티켓 파일은 `issues/`에 있다.

## 2. 의존성 간선

```text
C02 → C03
C03 → C25
C02, C03, C25 → C06
C04, C09 → C07
C02, C07 → C08
C01, C04 → C09
C01, C04 → C10
C01 → C05
C01, C04, C06, C08 → C11
C06 → C12
C01, C11 → C13
C13 → C14
C13 → C15
C09, C13 → C16
C13, 재구축 T33 → C17
C01, C12, C15, C17 → C18
C05, C09, C10, C11, C12 → C19
C19 → C21
C04, C09, C12, C19, C21 → C20
C05, C10, C19, C21 → C22
C06, C22 → C23
C06, C16, C25 → C28
C06, C17, C25, C26 → C29
C06, C17, C25 → C31
C06, C13, C17, C25, C26, C29, C31 → C27
C12, C13, C19, C26 → C30
C01 … C23, C25 … C31 → C24
C24 → 재구축 T35(V1 시범 운영)
```

**연결 파일에서 온 간선:** C07·C08·C09·C10 ← C04(`store.ts`·`discord.ts`), C07·C16·C19·C20 ← C09(작업 브리지), C08 ← C02(`contracts.ts` `EventInput`), C19·C22 ← C10(`briefing.ts`), C18·C19·C20 ← C12(`review.ts`), C18 ← C15·C17, C11 ← C08(`chat-context.ts`), C23 ← C06(`platform/sandbox`), C22 ← C05(관리 진입점·`homelab bot` 묶음), C05 ← C01(`policy.ts`), C22 ← C21(`ops-metrics.ts`).

**사용 관계에서 온 간선:** C11이 C04의 반응 훅과 C06에 배포된 v2 작업자를 쓴다. C13이 C11의 제안 칸을 쓴다. C19가 C05의 관리 진입점 해제로 바로 재개한다. C20은 C21 뒤다: Discord의 원인 안내를 없애기 전에 운영 알림이 먼저 있어야 owner가 원인을 놓치지 않는다.

**정정(2026-11-09, 티켓 작성 중 코드 대조):** 승인한 분해의 연결 파일 표가 실제 코드와 어긋난 곳을 고쳤다. `store.ts` 소유를 C09에서 C04로(C04·C07·C08이 C09보다 먼저 고친다), `change-runtime.ts` 소유를 C17에서 C07로 옮기고, 표에 없던 공유 파일(`runtime.ts`, `main.ts`, `worker-http.ts`, 실행기·응답 계약 파일, `change-commands.ts`, `ops-metrics.ts`, 봇 관리 진입점)을 5절에 더했다. 그에 따라 위 간선 여덟 개가 늘었고 C05는 실행 가능에서 대기(C01)가 됐다.

## 3. 실행 상태

- **통합 기준:** 봇 `main`, 시작 기준 `e160cb1`(2026-11-09). 티켓마다 봇 PR 하나를 선행 순서대로 main에 병합한다(7절, 사용자 2026-11-09 feature-build 커밋 질문). 명세 머리말에도 같은 줄이 있다.
- **실행 가능:** 없음(아래 진행 중 외에는 선행 대기).
- **진행 중:** C01, C02, C04, C26(2026-11-09 착수, 티켓별 worktree).
- **대기:** 나머지(1절 Blocked by).
- **외부 선행:** 충족. 재구축 T33(봇 PR #108)이 2026-11-09 병합됐고 homelab #1209로 배포, 봇 #109에 검증을 기록했다. C17은 C13만 기다린다.
- **통합 검증 담당:** C24. AC-24와 AC-25~AC-31의 S5 범위를 포함해, 각 AC에서 S1~S4로 못 잡아 S5로 넘긴 범위(말투 품질, 제안 오독, 2.1.308 한도 필드, 실제 Discord·GitHub·Telegram 동작, 계정 전환)를 모두 본다. 각 티켓은 자기 AC의 S1~S4 시험을 맡는다.

## 4. 병렬 후보와 소유 범위

같은 cwd에서는 병렬로 고치지 않는다. 병렬은 아래 범위가 겹치지 않고 티켓마다 별도 worktree일 때만 한다. 5절 연결 파일은 표의 자리가 겹치지 않을 때만 분리로 본다.

| 묶음 | 조건 | 소유 범위 |
|---|---|---|
| C01 · C02 · C04 | 지금 | C01 런타임 정책·설정(`policy.ts`·`config.ts`). C02 작업자 계약 파일(`contracts`·`worker`·`worker-http`·`chat-lane`·`bot-facts`·`review-input`, Codex 형식). C04 `discord.ts`·`discord-protocol.ts`·`store.ts`의 반응 자리. 공유: `ARCHITECTURE.md`는 자기 절만 |
| C03 · C05 · C09 · C10 | C02(C03), C01(C05), C01·C04(C09·C10) 뒤 | C03 실행기 스트림 읽기와 응답 계약 파일. C05 새 관리 진입점과 homelab `cli/`의 `homelab bot`(`store.ts`·`policy.ts`는 부르기만). C09 작업 브리지·제어 문구와 `store.ts` 문구 자리. C10 기억·브리핑 문구. C09·C10은 `discord.ts`의 서로 다른 문구 줄만 고친다 |
| C07 | C04·C09 뒤 | `discord.ts`·`discord-protocol.ts` 게시 자리, `store.ts` outbox 페이로드, owner 호출 표시 |
| C08 · C12 | C07(C08), C06(C12) 뒤 | C08 수신 자리와 `chat-context.ts`. C12 `review.ts` 렌더러·`review-lane.ts` |
| C14 · C15 · C16 · C17 | C13 뒤 | C14 제안 동작 표의 줄. C15 `external-task-commands.ts`와 custom_id 줄. C16 작업 브리지 질문 자리와 수신 분기. C17 `change-runtime.ts`·변경 승인과 custom_id 줄. custom_id 허용 목록은 줄 추가만 |
| C25 · C26 | C03(C25) 뒤, C26은 지금 | C25 작업 레인 작성 지시·출력 계약(`change-contracts.ts` 소유)과 수정 차례 입력. C26 `github-writer.ts` fast-forward 갱신, 리뷰 App 입출력의 댓글 읽기·안내 리뷰 게시 포트 |
| C28 · C29 · C30 · C31 | C28: C06·C16·C25, C29: C06·C17·C25·C26, C30: C12·C13·C19·C26, C31: C06·C17·C25 뒤 | C28 변경 질문 글과 선택지 버튼 줄. C29 `change-publication.ts`·미리보기의 확인할 것과 안내 댓글. C30 리뷰 요청 동작 줄과 `review.ts`의 명시 트리거 대상 해석. C31 `change-runtime.ts`·`change-store.ts`의 게시 전 고치기 차례(C27과 같은 파일이라 C31이 먼저) |
| C20 · C21 · C22 | C19 뒤(C22는 C05·C10도) | C20 Gateway 상태와 💤·안내 문구. C21 지표와 homelab vmalert 규칙. C22 homelab `cli/` 계정 명령, 계정 마이그레이션, `rotate.md` 3e |

## 5. 연결 파일

여러 티켓이 함께 고치는 파일이다. 뒤 티켓은 소유 티켓을 선행으로 두고(2절), 자기 자리만 고친다.

| 파일 | 소유 | 뒤에 고치는 티켓과 자리 | 병합 규칙 |
|---|---|---|---|
| 봇 `src/discord.ts`, `src/discord-protocol.ts` | C04 | C07 게시(답장·호출·스레드·표식), C08 수신 범위·답장 참조, C09·C10·C18 문구 줄, C13 상호작용 분기와 custom_id 허용 목록 표, C15·C16·C17 각 버튼 줄과 분기, C20 💤 | C04가 반응 훅 자리를 만든다. 허용 목록은 C13이 표 모양으로 만들고 뒤 티켓은 줄만 더한다 |
| 봇 `src/store.ts` | C04 | C07 outbox 페이로드(답장·owner 호출·스레드 칸), C08 이벤트 저장, C09 문구, C13 outbox 버튼 칸(C15·C17이 씀), C16 질문 고르기 게시, C19 멈춤·재개·claim, C20 안내 → 자리 비움 | C05는 store 시그니처를 바꾸지 않는다 |
| 봇 작업 브리지(`src/task-bridge.ts`, `src/claude-task-bridge.ts`, `src/codex.ts`) | C09 | C07 owner 호출 표시, C16 질문 바로 답·질문 글, C19 한도 정보 경로, C20 한도 안내, C28 변경 질문 선택지, C27 수정 차례 실행, C31 고치기 자료 블록 | |
| 봇 작업자 계약(`src/contracts.ts`, `src/worker.ts`, `src/worker-http.ts`, `src/chat-lane.ts`, `src/bot-facts.ts`, `src/review-input.ts`) | C02 | C03 응답 한도 칸, C08 `EventInput` 답장 참조 칸, C11 서버 쪽 v2 사용, C12 리뷰 v2 사용 | 계약 모양은 C02가 정하고 뒤 티켓은 칸을 채우거나 쓰기만 한다 |
| 봇 실행기·응답 계약(`src/executor.ts`, `src/executor-claude.ts`, `src/executor-claude-task.ts`, `src/task-contracts.ts`, `src/review-http.ts`, `src/review-lane.ts`) | C03 | C12 리뷰 프롬프트 줄, C23 인증 방식별 env·크레딧 소진 분류, C25 변경 작성 지시·출력 | 응답 칸은 C03, 인증 방식은 C23 |
| 봇 `src/chat-context.ts` | C08 | C11 상한 50개·80KiB, 정리된 앞부분 표시 | |
| 봇 `src/runtime.ts` | C11 | C13 제안 처리, C19 한도 대기 결과, C20 멈춤 배선 | 대화 성공·대기 분기마다 자기 자리만 |
| 봇 `src/main.ts` | C19 | C20 Gateway 상태 배선, C21 지표 배선, C30 조립 인수(바뀔 때만) | |
| 봇 `src/briefing.ts` | C10 | C19 미룬 리뷰 건수 줄, C22 토큰 만료 줄 | 줄 단위 추가 |
| 봇 `src/review.ts` | C12 | C18 Discord 리뷰 안내 문구, C19 리뷰 claim·한도 처리, C20 리뷰 대기 안내, C30 리뷰 요청의 대상 해석 | 렌더러는 C12, Discord 문구 자리는 C18 |
| 봇 `src/change-runtime.ts` | C07 | C17 미리보기 버튼, C18 변경 알림 문구, C27 수정 결과 알림, C28 선택지 공개 검사, C29 미리보기의 확인할 것, C31 고치기 차례 분기 | |
| 봇 `src/change-commands.ts` | C17 | C18 문구 | C14는 이 파일을 부르기만 한다 |
| 봇 `src/external-task-commands.ts` | C15 | C18 세션 연결 문구 | |
| 봇 `src/change-store.ts` | C17 | C31 게시 전 고치기 차례, C27 수정 차례 전이 | |
| 봇 `src/change-contracts.ts` | C25 | C31 고치기 차례 칸, C27 수정 차례 상태·입력 | |
| 봇 `src/change-publication.ts`, `src/change-publisher.ts` | C29 | C27 수정 커밋 게시와 안내 댓글 호출 | PR 설명은 처음 게시 때만 쓴다 |
| 봇 `src/change-review.ts` | C31 | C27 수정 차례 키 | |
| 봇 `src/task-http.ts` | C25 | 없음(작업 레인 intake 판 목록) | |
| 봇 `src/github-app.ts` | C26 | C30 설치 조회 허용 경로 | |
| 봇 `src/raw-text-retention.ts` | C28 | 없음(선택지 칸 7일 정리) | |
| 봇 `src/github-writer.ts`, 리뷰 App 입출력(`src/github-review-io.ts`) | C26 | C27 fast-forward·댓글 읽기, C29 안내 리뷰, C30 리뷰 대상 확인(정책 목록 밖 설치 저장소 토큰) | 포트는 C26, 사용은 뒤 티켓. 리뷰 포트 타입이 있는 `review.ts`(소유 C12)는 C26이 부르기만 한다 |
| 봇 `src/ops-metrics.ts` | C21 | C22 계정 이름·방식 값 | |
| 봇 관리 진입점(C05가 만드는 파일) | C05 | C22 계정 기록·목록·전환 뒤 해제 | |
| 봇 `migrations/` | 순번 공유 | C13 제안, C19 재개 시각, C22 계정 정보, C27 수정 차례, C28 선택지, C31 고치기 차례 | 병합 때 다음 번호로 다시 매긴다 |
| 봇 `docs/ai-bot/VERIFICATION.md`, `DECISIONS.md`, `ARCHITECTURE.md` | 추가만 | 모든 티켓 | 자기 절·문단만 더하거나 고친다 |
| homelab `cli/`의 `homelab bot` 묶음(명령 파일, `cli/src/core/` 도우미, `cli/README.md`, 설계 C.7 표) | C05 | C22 `account add/use/list`, C23 `--by api` | |
| homelab `platform/sandbox/` | C06 | C23 키 이름·작업자 이미지 digest | |
| homelab `docs/runbooks-public/rotate.md` 3e | C22 | C23 | |

한 티켓만 고치는 파일(예: C18의 `change-advice.ts`, C20의 `change-assembly.ts`, C23의 `restore.md` 3.1)은 각 티켓의 "파일 소유"에 있다.

## 6. AC → 티켓 → 검증

| AC | 구현 티켓 | 검증 |
|---|---|---|
| AC-1 멘션 호출 범위 | C08(스레드 여는 방식 C07) | S1, S5(C24) |
| AC-2 봇 글 답장 맥락 | C08 | S1 |
| AC-3 대화 답 형식과 공개 검사 | C02, C11 | S1, S2, 말투 표본 S5(C24) |
| AC-4 작업자 계약 v2 호환 | C02, C06, C11 | S2, 운영 관측(C06) |
| AC-5 대화 기록 50개·80KiB | C02, C08, C11 | S1, S2, 표본 S5(C24) |
| AC-6 제안과 실행 확인(리뷰 제어 장소 포함) | C13, C14 | S1(PostgreSQL 두 연결 포함), S5(C24) |
| AC-7 읽기 요청 | C13, C14 | S1, S5(C24) |
| AC-8 작업 질문 바로 답 | C16 | S1 |
| AC-9 세션 연결 키 | C15 | S1, S5(C24) |
| AC-10 게시 승인 버튼 | C17 | S1, S5(C24) |
| AC-11 고정 문구와 '/' 이름 | C02(신뢰 문맥), C09, C10, C11(surface), C18 | S1, owner 검토(C24) |
| AC-12 표식·스레드 제목·답장·owner 호출 | C07 | S1, S5(C24) |
| AC-13 PR 리뷰 말투 | C02, C12 | S1, S2, S5(C24) |
| AC-14 반응 | C04, C11(👍), C20(💤) | S1, S5(C24) |
| AC-15 자리 비움 | C20 | S1, S5(C24) |
| AC-16 한도 재개 | C03, C19 | S2, S1, 2.1.308 실측 S5(C24) |
| AC-17 리뷰 미루기 | C19 | S1, S5(C24) |
| AC-18 운영 알림 | C21 | S1, S4, 운영 발화 시험(C21, C24) |
| AC-19 토큰 만료 알림 | C22 | S1 |
| AC-20 관리 CLI | C05 | S3, S1, 운영 1회(C05) |
| AC-21 계정 등록·전환·목록 | C22 | S3, S2, S5(C24) |
| AC-22 API 크레딧 방식 | C23 | S2, S5(C24) |
| AC-23 스위치 | C01, C09, C10, C11, C13, C15, C16, C17, C18, C27, C28, C30 | S1(두 상태) |
| AC-25 변경 질문과 확인할 것 | C25, C28, C29 | S2, S1, S5(C24) |
| AC-26 변경 요청 확인 문구 | C14 | S1 |
| AC-27 안내 댓글 | C26, C29, C27(수정 뒤 diff 밖 항목의 Discord 요약) | S1, S5(C24) |
| AC-28 수정 요청 | C25, C26, C27 | S1(PostgreSQL 두 연결 포함), S2, S5(C24) |
| AC-29 PR 댓글 경계 | C27 | S1 |
| AC-30 리뷰 요청 | C30 | S1, S5(C24) |
| AC-31 게시 전 자체 리뷰 고치기 | C25, C31 | S1(PostgreSQL 두 연결 포함), S2, S5(C24) |
| AC-24 시범 통합 | C24 | S5 |

## 7. 추천 구현 전략

**의존 그래프 방식(`implement-spec`)을 추천한다.** 티켓 31개 사이에 실제 선행 관계와 연결 파일이 많고, 사람 배포 관문(C06·C23 작업자 배포), 외부 선행(재구축 T33), 통합 검증 담당(C24)이 정해져 있기 때문이다.

- **병합 단위:** 봇 main 병합은 곧 운영 배포다(이미지 digest PR 자동 병합). 그래서 티켓마다 봇 PR 하나를 선행 순서대로 main에 병합하고, 티켓 하나하나가 그 자체로 운영에 나가도 안전해야 한다. 위험한 경로는 C01 스위치가 막는다. homelab 쪽(C05·C06·C21·C22·C23)은 티켓마다 homelab PR이고 owner가 검토해 병합한다.
- **병렬:** 4절 묶음 안에서만, 티켓별 worktree로 한다. 같은 연결 파일의 같은 자리를 두 티켓이 동시에 고치지 않는다.
- **순서상 주의:** C11은 C06 배포를 운영에서 확인한 뒤 병합한다. C12·C27·C28·C29·C31도 같다(C25가 C06으로 배포된다). C16과 C28 사이에는 켜짐 판 CHANGE 질문 글에 '/' 안내가 남는다. 스위치는 C24 전까지 꺼져 있어 운영 영향은 없다. C17은 재구축 T33 배포 뒤다.
- 커밋·브랜치·worktree 허락은 feature-build의 커밋 질문에서 받는다.

## 8. 사람만 하는 일

- C05: 운영에서 관리 CLI 1회 확인 승인.
- C06·C23: 작업자 이미지 배포 PR 검토·병합(`platform/sandbox`, D2).
- C21: 운영 발화 시험 승인.
- C22: Anthropic 새 이용 정책(2026-11-12 시행) 재확인 결과 판단, 실제 구독 토큰 등록(브라우저 로그인), 운영 계정 전환 확인.
- C23: Claude Console API 키 발급, 봇 전용 workspace와 자동 충전 끄기.
- C30: 리뷰 App `ukyi-review` 설치 범위를 조직의 모든 저장소(All repositories)로 넓히기, 승인 기록.
- C24: 스위치 켜기 승인, 말투 표본 수용, 시범 통합 결과 수용.
