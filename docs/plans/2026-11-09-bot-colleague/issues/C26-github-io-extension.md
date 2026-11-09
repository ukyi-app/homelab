# C26 GitHub 쓰기·읽기 확장: fast-forward 갱신, PR 리뷰·댓글 읽기, 안내 리뷰 게시 포트

- 단계: 1 기반
- 상태: integrated (봇 #113 병합 `1ef5843`, 2026-11-10)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.10 "GitHub 쓰기"·"수정 요청"·"안내 댓글"·"PR 댓글 경계", §5 AC-27, AC-28, §8 "PR 댓글 자료" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: 없음
- 연결 AC: AC-27(포트), AC-28(포트)
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 봇 `src/github-writer.ts`: 소유(연결 파일. 뒤에 C27이 fast-forward 갱신을 쓴다). 자리: route 표(`ROUTES`)와 body 키 검사(`bodyAllowed`)에 기존 봇 브랜치 ref 갱신 한 줄, 도메인 메서드 하나(fast-forward 갱신)와 그 응답 대조.
  - 고치지 않음: 봇 `src/change-contracts.ts`의 `ChangeWriterPort`(소유 C25). 선행이 없는 이 티켓이 그 파일을 고치면 소유 규칙이 깨지므로, fast-forward 갱신은 `src/github-writer.ts`가 내보내는 writer 타입의 메서드로 두고 `ChangeWriterPort`에 올리는 일은 C27이 한다.
  - 봇 `src/github-review-io.ts`: 소유(연결 파일. 뒤에 C27이 읽기 포트를, C29가 게시 포트를, C30이 저장소 조회를 쓴다). 자리: 새 읽기 포트(PR 리뷰·리뷰 댓글·대화 댓글)와 새 게시 포트(봇 PR의 `COMMENT` 리뷰, 인라인 포함, 대조 표식으로 유실 회수). 기존 `githubReviewIO`의 `reader`·`transport`는 바꾸지 않는다.
  - 봇 `src/github-app.ts`: 리뷰 App 허용 경로 표(`ALLOWED`)에 읽기 두 줄을 더하는 자리. 연결 파일, 이 티켓이 소유하고 C30이 뒤에 고친다(README 5절).
  - 쓰기만 함(고치지 않음): 봇 `src/review.ts`(소유 C12)의 `restrictGitHubWrite`·`GitHubWrite`·`GitHubError`·`reviewMarker`·`GitHubReader`. 리뷰 App 쓰기 제한과 포트 타입이 이 파일에 있어서, 새 포트는 `src/github-review-io.ts`에 따로 선언하고 `review.ts`는 부르기만 한다.
  - 시험: `test/github-writer.test.ts`, `test/github-review-app.test.ts`, 가짜 GitHub `test/change-github-fake.ts`.
  - 봇 `docs/ai-bot/ARCHITECTURE.md`·`VERIFICATION.md`·`DECISIONS.md`: 추가만(ARCHITECTURE §16.3의 "V1에는 `PATCH git/refs`와 `PATCH pulls`가 없다… 리뷰 API … 없다" 문장과 §6 표는 이 티켓이 바뀐 내용으로 고친다).
- 설계 계약:
  - `src/github-writer.ts`: 봇 ARCHITECTURE "16.3 T19 B3 writer·공개 경계"의 구조 문단(쓰기는 `exchange` 한 곳, URL·method·token을 받는 함수 없음), 메서드·경로 표(`POST …/git/refs`는 자기 change·generation 브랜치만, `force` 필드 없음), 토큰 문단(contents 토큰), 유실 지점별 복구 표("ref 응답 유실·422")와 최신성 문단(다른 SHA의 브랜치는 `head_changed`로 막고 덮지 않음) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). 봇 DECISIONS "D-24 봇 변경 PR 작성 신원"의 "T19 세부 결정 (사용자 2026-11-05)" 표(토큰 분리, ruleset E는 `ukyi-writer`만 `bot/**` 생성·갱신·삭제)와 그 아래 허용 API 초안(`PATCH /git/refs/heads/bot/…`는 `force: false`) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - `src/github-review-io.ts`, `src/github-app.ts`: 봇 ARCHITECTURE "6. 보안 경계"의 리뷰 행(REVIEW-04: `event=COMMENT`만, `commit_id`는 검토한 head SHA, APPROVE·REQUEST_CHANGES·dismiss·merge 거부)과 "7. 상태, 영속, 복구"의 GitHub 행, "16.3"의 마지막 문단(`github-app.ts`의 리뷰 allowlist와 writer는 `TokenResponse`·`grantedExactly`만 공유). 봇 DECISIONS "D-16 PR 리뷰 방식" 머리의 "변경(사용자 2026-11-09…)" 문단(댓글은 수정 요청 때 그 PR에서만 자료로 읽음)과 "T17 결정 (사용자 2026-11-04)".
  - 결정: 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 16·17.

## 목표

뒤 티켓이 쓸 GitHub 포트 셋을 둔다. 봇 쓰기 App은 자기 변경 브랜치를 fast-forward로만 앞으로 옮길 수 있고(강제 갱신 없음), 리뷰 App은 봇 PR의 리뷰·리뷰 댓글·대화 댓글을 작성자 ID·association과 함께 읽고, 봇 PR에 `COMMENT` 리뷰(인라인 포함)를 단다. 이 티켓은 포트만 더하고 부르는 곳이 없어서, 병합해도 owner가 보는 동작과 GitHub에 나가는 요청은 그대로다. C27(수정 요청)·C29(안내 댓글)·C30(리뷰 요청)이 이 포트를 쓴다.

## 할 일

1. writer fast-forward 갱신(`src/github-writer.ts`): route 표에 자기 변경 브랜치 ref 갱신 한 줄(`PATCH …/git/refs/heads/<봇 브랜치>`)을 더하고, body 키는 `sha`와 `force`(값은 항상 거짓)만 받는다. 도메인 메서드는 대상 change·generation의 브랜치(`ownsBranch`)만 받고, 호출자가 넘긴 기대 head와 새 커밋을 받는다. 보내기 전에 브랜치 head가 기대 head와 같은지, 새 커밋의 부모가 그 head 하나인지 읽어 확인하고, 다르면 보내지 않고 `head_changed`로 돌려준다. 응답의 ref·SHA를 대조한다. 응답 유실·422는 기존 ref 대조 규칙(정확한 ref GET, 새 SHA면 확정, 다른 SHA면 `head_changed`, 없으면 unknown)을 따른다. contents 토큰을 쓴다.
2. 그 메서드는 `createGitHubWriter`가 돌려주는 writer에 두고(`ChangeWriterPort`는 고치지 않음), 결과는 기존 넷(`confirmed`·`not_sent`·`rejected`·`unknown`)이다. PR 제목·본문 수정(`PATCH pulls`)은 넣지 않는다. 명세 4.10에 없고, 수정 커밋 뒤 diff 밖 확인할 것을 PR 설명에 다시 쓸지는 C29·C27이 정한다(필요하면 그 티켓이 이 파일에 한 줄을 더한다).
3. 리뷰 App 읽기 경로(`src/github-app.ts` `ALLOWED`): PR 리뷰 댓글 목록과 PR 대화 댓글(issue 댓글) 목록을 페이지 단위로 읽는 GET 두 줄을 더한다. 기존 리뷰 목록 경로는 그대로 쓴다. 지금 읽기 토큰 권한(`contents:read`, `pull_requests:read`)으로 issue 댓글 목록을 읽을 수 있는지 구현 때 GitHub 문서로 확인하고, 권한을 더해야 하면 멈추고 owner에게 알린다(App 권한 변경은 사람 작업).
4. 읽기 포트(`src/github-review-io.ts`): PR 하나의 리뷰(상태·본문·커밋), 리뷰 댓글(경로·줄·본문·답글 관계), 대화 댓글을 모아 돌려준다. 항목마다 작성자 숫자 ID·login·`author_association`·작성 시각·URL ID를 담고, 본문은 자료로만 넘긴다(포트는 해석하지 않는다). 페이지·개수·글자 상한을 두고 넘치면 잘렸다고 표시한다. 대상 PR은 정확한 저장소·번호 하나이고 다른 PR 댓글이 섞이지 않게 응답의 PR·저장소를 대조한다. 봇 자신(리뷰 App·writer App)의 글을 구분할 수 있게 작성자 종류를 둔다.
5. 게시 포트(`src/github-review-io.ts`): 봇 PR에 `COMMENT` 리뷰 하나(본문 + 인라인 댓글 최대 50개, `side: RIGHT`)를 단다. 요청은 반드시 `restrictGitHubWrite`(`src/review.ts`)를 지나 대상 저장소·PR·head SHA가 고정되고 `event`는 `COMMENT`뿐이다. 본문에는 호출자가 준 키로 대조 표식(`reviewMarker`와 같은 모양, 종류를 구분하는 접두)을 넣는다. 응답 유실이면 다시 보내지 않고, PR 리뷰 목록에서 표식과 head SHA로 찾는 회수 함수를 따로 둔다(지금 `review.ts`의 `existing`과 같은 규칙). 게시 상태 저장(outbox·재시도)은 부르는 쪽(C29)이 맡는다.
6. 저장소 범위: 지금 리뷰 App 토큰은 리뷰 정책 저장소 목록(`policyRepositories`)으로만 발급된다. 새 포트도 같은 조회를 쓰고, 변경 저장소가 리뷰 정책 목록에 없으면 토큰 없이 거부(`Denied`)로 닫는다. 정책 목록 밖 조직 저장소를 위한 설치 조회는 C30이 정한다. 이 사실을 ARCHITECTURE에 적는다.
7. 시험: writer route 표가 새 갱신 한 줄만 열고 `force: true`·다른 브랜치·base 브랜치·남의 change 브랜치 갱신을 보내지 않는지, 기대 head 불일치면 보내지 않는지, 응답 유실·422 대조. 리뷰 App 경로 표에 새 GET 두 줄만 늘었는지(쓰기 경로 그대로), 읽기 포트가 다른 PR 응답을 거부하고 잘림을 표시하는지, 게시 포트가 APPROVE·REQUEST_CHANGES·다른 head·인라인 51개를 거부하는지, 유실 뒤 표식으로 회수하고 재전송하지 않는지. 가짜 GitHub(`test/change-github-fake.ts`)에 필요한 끝점을 더한다.
8. 기록: 봇 ARCHITECTURE §16.3 메서드·경로 표에 갱신 줄과 "V1에는 … 없다" 문장 정정, §6 리뷰 행에 안내 리뷰 게시 포트, `VERIFICATION.md`에 "C26 GitHub 쓰기·읽기 확장" 절, `DECISIONS.md` "동료 봇 전환" 16·17에 구현 위치 한 줄. 이 계획 폴더 `README.md`의 C26 상태 줄 갱신.

## 완료 조건

- [x] writer가 자기 변경 브랜치를 기대 head에서 새 커밋으로만 fast-forward 갱신하고, 강제 갱신·다른 브랜치·기대 head 불일치는 요청을 보내지 않는다.
- [x] 리뷰 App 읽기 포트가 PR 하나의 리뷰·리뷰 댓글·대화 댓글을 작성자 ID·association과 함께 자료로 돌려주고, 다른 PR의 글이 섞이지 않는다.
- [x] 게시 포트가 봇 PR에 `COMMENT` 리뷰(인라인 포함)만 달고, 유실 뒤에는 표식으로 회수하며 다시 보내지 않는다.
- [x] 병합해도 GitHub에 나가는 요청과 owner가 보는 동작이 그대로다(부르는 곳 없음).

## 검증

- 경계: S1(가짜 GitHub. 앞선 예: `github-writer`, `github-review-app`, `change-freshness`, `publisher-review`).
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험(`github-writer`, `github-review-app`). 전체 `npm test`는 통합 담당 C24.
- 잡는 실패 / 못 잡는 범위: 잡는 것은 강제 갱신, 남의 브랜치 갱신, 허용 목록 밖 경로, 다른 PR 댓글 혼입, `COMMENT` 밖 리뷰 이벤트, 유실 뒤 중복 게시다. 못 잡는 범위: 실제 GitHub의 fast-forward 거부·ruleset E 동작, issue 댓글 읽기 권한, 인라인 위치 표시(S5, C24).

## 결과

- 봇 PR #113(`feat/colleague-c26-github-io`, 결과 head `9ae002d`), 병합 `1ef5843`(2026-11-10). 첫 작업자는 2026-11-09 22:48 NUC 커널 크래시로 최종 답 없이 끊겼고, 이어받은 작업자가 커밋 6개를 티켓과 대조해 코드 추가 없이 완료 검사만 했다.
- 구현: `src/github-writer.ts` `GitHubWriterPort.fastForwardBranch`(ROUTES에 자기 변경 브랜치 `PATCH git/refs` 한 줄, body는 `sha`·`force:false`만, 부모 불일치는 `not_sent(not_fast_forward)`, 유실·409·422는 ref 재조회 대조만). `src/github-review-io.ts` `discussion.read`(리뷰·리뷰 댓글·대화 댓글, 작성자 ID·association, 상한·truncated, 다른 PR·저장소 거부)와 `guidance.post`·`guidance.find`(COMMENT·RIGHT 인라인, `guidanceMarker` 회수, 재전송 없음). `src/github-app.ts` ALLOWED에 GET 두 줄.
- 완료 조건 근거: `test/github-writer.test.ts` "C26 writer:" 6건, `test/github-review-app.test.ts` "PR 자료 읽기:" 4건·"안내 리뷰 게시:" 3건·허용 경로 1건. 부르는 곳: `src`에서 두 파일 밖 사용 0(grep).
- 검사: 작업자 관련 시험 372 pass·0 fail·0 skip(실제 PG 포함). 통합 담당 전체 검사(`9ae002d`, node 24.22.0, 실제 PG, 잠금): 2176 tests / 2154 pass / 0 fail / 22 skip(SEC02_IMAGE). Codex 코드·보안 지적 없음, `build / test` 통과.
- 분해 불일치(작은 차이): 갱신 거부는 422 외 409도 같은 대조. 부모 불일치는 `head_changed`가 아니라 `not_sent(not_fast_forward)`.
- [미확인] 대화 댓글 읽기(`issues/{n}/comments`)가 리뷰 App의 `pull_requests:read`로 되는지. 첫 실제 호출(C27·C24 S5)에서 403이면 App에 `issues:read` 추가가 사람 작업이다.
- 뒤 티켓에 넘김: C27은 `fastForwardBranch`를 `ChangeWriterPort`에 올리고 `discussion.read`에 두 App의 사용자 ID(`selfAuthors`)를 넘긴다. C29는 `guidance.post`·`find`와 outbox 처리(`unknown`인데 `find`로도 못 찾으면 포트는 다시 게시하지 않음). C30은 정책 목록 밖 저장소 설치 조회(지금은 `Denied`, 게시는 `not_sent(repository_denied)`).
