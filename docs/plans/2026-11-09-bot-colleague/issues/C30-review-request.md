# C30 리뷰 요청(Discord, 조직 저장소)

- 단계: 4 말로 실행
- 상태: integrated (봇 #132 병합 `5e66d78`, 2026-11-10)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.10 "리뷰 요청"·"사람 작업", §4.3 동작 목록의 "PR 리뷰 부탁" 줄, §4.9 스위치와 배포 순서, §5 AC-30, §8 "리뷰 App 설치 범위" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C12, C13, C19, C26
- 연결 AC: AC-30
- 수행: 에이전트 + 사람(리뷰 App `ukyi-review` 설치 범위를 조직의 All repositories로 넓히기, homelab `approvals.md` 승인 기록)
- 저장소·PR: 봇 PR(사람의 GitHub 설정 변경과 승인 기록은 homelab `approvals.md`)
- 파일 소유:
  - 연결 파일, 소유 C13: 봇 제안 모듈(동작 표에 "리뷰 요청" 줄: 종류 실행이지만 확인 없음, 스위치 뒤, 대상 값은 저장소 이름과 PR 번호)
  - 연결 파일, 소유 C02: 봇 `src/contracts.ts`(`PROPOSAL_RUN_ACTIONS` 끝에 리뷰 요청 ID 한 줄. 목록에 없어 더한다. 작업자 계약 digest·이미지 영향은 구현 때 확인, 주 진행자 2026-11-10)
  - 연결 파일, 소유 C12: 봇 `src/review.ts`(`ReviewQueue.admitLive`에 Discord 리뷰 요청을 명시 트리거로 넣는 자리, 정책 목록 밖 저장소의 대상 기록(저장소 ID·이름·설치 ID·visibility)을 받는 자리, 실행 직전·게시 직전 판단이 그 기록을 쓰는 자리. 조직 이름을 정책에 둘 경우 `ReviewPolicySchema` 한 칸). `GitHubIngress`의 웹훅 저장소 검사(`repository`)는 고치지 않는다
  - 연결 파일, 소유 C26: 봇 `src/github-review-io.ts`(`policyRepositories`가 정책 목록 밖이라도 Discord 리뷰 요청으로 접수된 저장소 기록이면 토큰 범위를 정하는 자리), `src/github-app.ts`(허용 경로 표에 저장소의 App 설치 조회와 저장소 정보 읽기 두 줄)
  - 연결 파일, 소유 C04: 봇 `src/discord.ts`(리뷰 요청 동작을 실행해 접수 결과를 그 스레드에 일반 답으로 다는 분기). 버튼이 없으므로 `src/discord-protocol.ts`는 고치지 않는다
  - 연결 파일, 소유 C19: 봇 `src/main.ts`(리뷰 저장소 조회 조립 `githubReviewIO({ repositories: … })`의 인수가 바뀔 때만 그 줄)
  - 순번 공유: 봇 `migrations/`의 다음 번호. `pr_reviews`의 트리거 값에 Discord 요청을 더하거나 대상 저장소 기록 칸이 더 필요할 때만
  - 시험: `test/pr-review.test.ts`, `test/review-9.test.ts`·`test/review-9-pg.test.ts`(대기열·명시 트리거), `test/github-review-app.test.ts`(허용 경로·토큰 범위), `test/publisher-review.test.ts`(게시 직전 저장소 대조), 새 리뷰 요청 시험
- 설계 계약:
  - `src/review.ts` 대기열·트리거: 봇 DECISIONS "T17 결정 (사용자 2026-11-04)"(`commentCommand` `/homelab-review`, 댓글은 늘 새 세대, `rereviewOnBaseMove` false), "D-16 PR 리뷰 방식"과 그 맨 앞 "변경(사용자 2026-11-09…)" 문단, 하위 결정 "모델 호출 전 작성자 확인의 App 예외"(작성자 association·fork 거부 유지) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md). 봇 ARCHITECTURE §7 "상태, 영속, 복구"의 GitHub 행(세대 키, 폴링 대조) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md)
  - `src/github-review-io.ts`, `src/github-app.ts`: 봇 ARCHITECTURE §3 "도구·런타임"의 GitHub 행(작업마다 저장소 하나·필요 권한만의 설치 토큰), §6 "보안 경계"의 리뷰 행(`COMMENT`만), DECISIONS "D-16"의 "리뷰 App 권한과 구독 이벤트"
  - 제안 동작: C13이 봇 ARCHITECTURE에 더하는 제안·실행 확인 계약 절의 동작 표
  - `src/discord.ts`: 봇 ARCHITECTURE §11 "저장·권한·게시"
  - 결정: 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 18(리뷰 요청, 설치 범위, 자동 리뷰 대상은 정책 목록 그대로), 9(스위치)
  - 승인 기록: homelab 저장소 `AGENTS.md` "변경 규칙"(외부 변경은 사람 승인 뒤, [approvals.md](../../2026-10-17-homelab-rebuild/approvals.md)에 기록)

## 목표

스위치가 켜져 있을 때 owner가 Discord에서 ukyi-app 조직 저장소의 PR 링크와 함께 "이 PR 리뷰해 줘"라고 하면, 확인 버튼 없이 바로 리뷰 작업이 생기고 그 PR에 `COMMENT` 리뷰가 달린다. 리뷰 App이 없는 저장소나 조직 밖 PR이면 동료 말투로 못 한다고 답한다. 자동 리뷰 대상은 지금 정책 목록(`homelab-smoke`) 그대로라서, App을 조직 전체에 설치해도 목록 밖 저장소의 PR 이벤트는 리뷰를 만들지 않는다. 병합해도 스위치가 꺼져 있으면 운영 동작은 그대로다.

## 할 일

1. 동작 줄: C13 동작 표에 "리뷰 요청"을 더한다. 확인 글과 버튼 없이 바로 실행하고, 스위치가 꺼져 있으면 제안을 버린다. 대상 값은 저장소 이름과 PR 번호이고, 서버는 owner 원문에 그 PR 링크나 저장소·번호가 있는지 대조한다(확인 버튼이 없으므로 맥락 자료가 대상을 바꾸지 못하게 함).
2. 대상 해석: 저장소 소유자가 ukyi-app 조직인지 먼저 보고, 아니면 GitHub에 묻지 않고 거절한다. 조직 안이면 App JWT로 그 저장소의 App 설치를 조회하고(설치 없음이면 거절), 설치 토큰으로 저장소 ID·visibility와 PR을 읽는다. 쓰는 GitHub 경로는 `github-app.ts` 허용 표에 정확한 모양으로 더한다(경로 이름과 응답 필드는 구현 때 GitHub REST 문서로 확인).
3. 접수: 정책 목록에 있는 저장소면 지금 정책 기록을, 목록 밖이면 2의 조회 기록을 써서 `ReviewQueue.admitLive`에 PR 댓글 명령과 같은 명시 트리거 의미(draft 예외, 늘 새 세대, 대체에서 보호)로 넣는다. 출처가 Discord 요청임을 구분할 수 있게 기록한다. fork·작성자 association·닫힌 PR 판단(`pullRequestDecision`)은 그대로다.
4. 실행·게시 경로: 정책 목록 밖 저장소의 리뷰 작업도 실행 직전 판단과 게시 직전 저장소 대조, 설치 토큰 발급(`policyRepositories`)이 그 접수 기록으로 통과하게 한다. 목록 밖 저장소의 범위는 그 작업 하나뿐이고, 정책 목록과 폴링 대조(`reconcile`)에는 더하지 않는다.
5. 자동 리뷰 경계: `GitHubIngress`의 저장소 검사(정책 목록과 설치 ID)를 그대로 둔다. 그래서 목록 밖 저장소의 `pull_request` 이벤트와 `/homelab-review` 댓글은 지금처럼 `installation_or_repository`로 거부된다. 이것을 시험으로 고정한다.
6. 답: 접수되면 그 스레드에 "리뷰 시작했어요" 한 줄(PR 링크), 거절이면 이유 한 줄(조직 밖, 리뷰 App 없음, fork, 작성자 조건, 닫힘)을 동료 말투 고정 문구로 단다. 리뷰 결과 알림은 지금처럼 알림 채널의 리뷰 요약 경로를 따른다.
7. 사람 작업: owner에게 `ukyi-review` 설치 범위를 ukyi-app 조직의 All repositories로 넓혀 달라고 승인 요청한다. 요청에 위험(App 키가 새면 비공개 `homelab-bot-ops`를 포함한 모든 저장소의 내용 읽기와 PR 글쓰기가 열림, 코드 변경·병합 권한은 없음)과 되돌리는 방법(설치 범위를 다시 선택 저장소로)을 적는다. 승인과 수행 시각을 homelab [approvals.md](../../2026-10-17-homelab-rebuild/approvals.md)에 기록한다. 리뷰 App 약관·권한은 명세 4.8처럼 구현 시작 때 다시 확인한다.
8. 시험: ukyi-app 저장소 PR 요청 → 확인 버튼 없이 리뷰 작업 생성(가짜 GitHub), 정책 목록 밖이지만 설치된 저장소 → 리뷰 작업과 `COMMENT` 게시, 설치 없음·조직 밖 → 거절 답과 작업 0건, 목록 밖 저장소의 `pull_request` 이벤트·댓글 명령 → 리뷰 0건, owner 원문에 없는 대상 → 거절, 스위치 꺼짐 → 리뷰 0건, fork·작성자 조건 거부 유지.
9. 기록: 봇 `docs/ai-bot/ARCHITECTURE.md` §7 GitHub 행 또는 리뷰 계약 문단에 Discord 리뷰 요청과 목록 밖 저장소 범위, `docs/ai-bot/DECISIONS.md` D-16에 설치 범위 수행 결과, `docs/ai-bot/VERIFICATION.md`에 "C30 리뷰 요청" 절을 더한다. homelab `approvals.md`에 사람 작업 승인 줄. 이 계획 폴더 `README.md`의 C30 상태 줄을 갱신한다.

## 완료 조건

- [x] owner가 Discord에서 ukyi-app 저장소 PR의 리뷰를 부탁하면 확인 버튼 없이 리뷰 작업이 생기고 GitHub에 `COMMENT` 리뷰가 달린다.
- [x] 리뷰 App이 없는 저장소나 조직 밖 PR은 못 한다고 답하고 리뷰 작업이 생기지 않는다.
- [x] 정책 목록 밖 저장소의 PR 이벤트와 댓글 명령은 자동 리뷰를 만들지 않는다.
- [x] 스위치가 꺼져 있으면 리뷰 요청이 동작하지 않는다.
- [x] `ukyi-review` 설치 범위 변경이 owner 승인 뒤 수행되고 homelab `approvals.md`에 기록돼 있다.

## 검증

- 경계: S1(리뷰 대상 해석·대기열, 가짜 GitHub, PGlite). 앞선 시험 예: `pr-review`, `review-9`, `github-review-app`, `publisher-review`. S5(다른 저장소 실제 리뷰 한 건)는 C24.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 `npm test` 대상(전체는 C24 통합).
- 잡는 실패: 목록 밖 저장소 자동 리뷰, 조직 밖 리뷰, 확인 버튼 등장, 맥락 자료가 고른 대상으로 리뷰. 못 잡는 범위: App 설치 범위의 실제 설정(사람 작업, C24 S5).

## 결과

- 봇 PR #132, 병합 `5e66d78`(2026-11-10). Discord 리뷰 요청(스위치 뒤), 제안 동작 ID `review_request`, 목록 밖 조직 저장소의 요청 세대, 마이그레이션 023.
- 완료 조건: 1~4 충족(S1, `test/c30-review-request.test.ts`·`github-review-app`·`pr-review`). 5(설치 범위)는 2026-11-10 사용자 승인으로 All repositories로 넓히고 approvals.md에 기록.
- 검사: 결과 `0f8d5f0`에서 전체 2,437개 중 통과 2,415, 실패 0, skip 22. CI `build / test` 통과.
- Codex: 1차 P2 1(비공개 대상은 접수에서 거절) 수정. 2차 P2 2(신뢰 문맥에 리뷰 요청 없음, GitHub 조회 뒤 최신성 재검사)는 C18 할 일 3b·3c로 넘김.
- 운영: 배포 확인(마이그레이션 23, 파드 Ready, digest 일치, 로그 오류 0).
- 한계: 모델이 이 제안을 내려면 작업자 이미지 교체가 필요하다(게시 서버 먼저). 목록 밖 저장소는 공개 저장소만 받는다(비공개는 인증된 압축본 경로가 없어 거절). 실제 다른 저장소 리뷰 1건은 C24 S5.
