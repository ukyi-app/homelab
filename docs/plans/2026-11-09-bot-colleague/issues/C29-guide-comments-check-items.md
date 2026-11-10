# C29 안내 댓글과 확인할 것

- 단계: 4 말로 실행
- 상태: integrated (봇 #134 병합 `83b2de6`, 2026-11-10)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.10 "변경 질문 줄이기"(확인할 것을 미리보기와 PR 설명에), "안내 댓글", §5 AC-27, AC-25(미리보기·PR 설명 줄) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C06, C17, C25, C26
- 연결 AC: AC-27, AC-25(미리보기·PR 설명의 확인할 것 줄)
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 소유(연결 파일, 뒤에 C27이 고침): 봇 `src/change-publication.ts`(PR 설명에 확인할 것·남은 위험 절을 그리는 `renderBody`와 입력 스키마 `PublicationInputSchema`, 안내 댓글 본문을 그리고 공개 검사하는 새 함수. C27이 수정 커밋 뒤 같은 함수를 부른다)
  - 연결 파일, 소유 C07: 봇 `src/change-runtime.ts`(미리보기 글 `preview`에 확인할 것 줄, 게시 확정(`proposed`) 뒤 안내 댓글을 한 번 부르는 자리)
  - 연결 파일, 소유 C25: 봇 `src/change-contracts.ts`(확인할 것·남은 위험 항목 모양을 읽기만. 안내 댓글 전송 기록을 게시 effect 표에 둘 경우 그 단계 줄)
  - 연결 파일, 소유 C09: 봇 `src/claude-task-bridge.ts`(`fetchResult`의 snapshot 반환에 `checks`·`risks`를 넘기는 자리만. 요청 판 전환은 C28, 주 진행자 2026-11-10)
  - 연결 파일, 소유 C26: 봇 `src/github-review-io.ts`·`src/github-app.ts`의 `COMMENT` 리뷰(인라인) 게시 포트를 쓰기만
  - 공유 파일(README 5절 표에 없음): 봇 `src/change-publisher.ts`(`prepareApproval`이 `renderPublication`에 확인할 것을 넘기는 자리, 게시 확정 뒤 안내 댓글 호출을 여기에 둘 경우 그 자리). C27의 fast-forward 갱신도 이 파일을 쓸 수 있다
  - 고치지 않음: 봇 `src/change-review.ts`(자체 리뷰 지시·판정·`findings` 비공개 규칙 그대로. hunk 판단 도우미가 있으면 쓰기만)
  - 순번 공유: 봇 `migrations/`의 다음 번호. 안내 댓글 전송 기록(변경 ID, generation, 수정 차례, 대상 head SHA, 상태, 게시된 리뷰 ID)이 기존 표로 안 되면 하나 더한다
  - 시험: `test/change-publication.test.ts`(PR 설명 렌더·공개 검사), `test/change-assembly.test.ts`(미리보기 줄), `test/change-github-fake.ts`를 쓰는 게시 시험, `test/publisher-review.test.ts`(리뷰 게시 경로 대조)
- 설계 계약:
  - `src/change-publication.ts`: 봇 ARCHITECTURE §16 "T19 CHANGE_PR 계약"의 digest 문단(승인 digest가 제목·본문을 묶음, 공개 텍스트가 바뀌면 새 generation), §16.3 "T19 B3 writer·공개 경계"(공개 payload 검사, `PATCH pulls` 없음, PR 확정 뒤 사후 검사) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). 파일 머리 주석의 계약("raw 로그·대화·리뷰 자유문을 받을 자리가 스키마에 없다")을 이 티켓이 바꾸므로 같은 절에 바뀐 계약을 적는다
  - `src/change-runtime.ts` 미리보기: 봇 ARCHITECTURE §16 상태 전이 표(`awaiting_publish_approval`, `proposed`), §16.5 "조립과 꺼짐 배포 (B5)"
  - 자체 리뷰 비공개: 봇 ARCHITECTURE §16.2 "미게시 후보 리뷰 (B2)"(판정은 코드가 하고 모델 문장은 공개 경로에 닿지 않음)
  - 안내 댓글 게시: 봇 DECISIONS "D-16 PR 리뷰 방식"(리뷰 App, `COMMENT`만)과 그 "리뷰 App 권한과 구독 이벤트", ARCHITECTURE §6 "보안 경계"의 리뷰 행(`event=COMMENT`, `commit_id`는 검토한 head SHA) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md)
  - `migrations/`: 봇 ARCHITECTURE §14 "마이그레이션 실행"
  - 결정: 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 14(확인할 것을 미리보기와 PR 설명에), 17(안내 댓글, 자체 리뷰 전체 비게시)

## 목표

봇이 만든 변경 PR을 owner가 GitHub에서 열면, PR 설명에 봇이 가정한 "확인할 것" 목록과 남은 위험이 있고, 그중 바뀐 줄 위에 있는 항목은 그 줄에 짧은 리뷰 댓글로 달려 있다. 그래서 owner는 어디를 먼저 봐야 할지 바로 안다. 같은 목록이 게시 전 미리보기 글에도 보이고 승인 digest에 묶인다. 자체 리뷰 전문은 게시되지 않는다. 이 동작은 스위치와 상관없이 병합하면 바로 운영에 나간다(변경 PR을 새로 게시할 때부터).

## 할 일

1. PR 설명: `PublicationInputSchema`에 C25의 확인할 것·남은 위험 항목(글, 선택 위치)을 받는 칸을 더하고, `renderBody`가 "확인할 것"·"남은 위험" 절을 그린다. 모든 항목 글은 `neutralizePublicText`를 거치고, 렌더 결과 전체가 지금처럼 `scanPublicPayload`를 지난다. 걸리면 고쳐서 내보내지 않고 게시를 막는다(지금 규칙). 기존 "사전 리뷰" 절(판정과 고정 enum 위험 건수)은 그대로 둔다. 길이 상한(본문 16,000자) 안에 들도록 항목 수·글 길이 상한을 C25 계약과 맞춘다.
2. 승인 묶음: 확인할 것이 PR 본문에 들어가므로 `prepareApproval`의 승인 digest가 그 목록까지 묶는다. 목록이 바뀌면 새 승인 대상이라는 규칙(§16 digest 문단)을 시험으로 고정한다.
3. 미리보기: `preview`에 확인할 것 줄(항목 글과 위치)을 더한다. 고정 코드·SHA·경로만 싣던 미리보기에 모델 글이 처음 들어가므로, 같은 공개 검사를 지난 글만 싣는다.
4. 안내 댓글: 게시가 확정된 뒤(`proposed`, `pull` effect 확정) 한 번, 확인할 것·남은 위험 중 위치가 PR diff 안(오른쪽 줄이 hunk 안)인 항목만 C26 포트로 `COMMENT` 리뷰의 인라인 댓글로 단다. `commit_id`는 확정된 head SHA다. diff 밖 위치와 위치 없는 항목은 PR 설명에만 있다. diff 안 판단은 게시한 artifact의 patch로 하고 GitHub에 다시 묻지 않는다. 댓글 수 상한은 리뷰 정책 `publish.maxInlineComments`(운영 5)와 같은 값으로 두고, 넘는 항목은 PR 설명에만 있다.
5. 한 번만: 안내 댓글 전송은 의도 저장 → 전송 → 응답 대조 순서로 기록해, 재시작·응답 유실 뒤에도 같은 차례에 두 번 달리지 않는다. 대조는 C26 포트가 쓰는 기존 리뷰 대조 표식 규칙을 따른다. 전송이 끝내 실패해도 PR과 변경 상태는 되돌리지 않고 봇 로그에 사유 코드만 남긴다.
6. 수정 차례용 진입점: 같은 함수가 "변경 ID·generation·수정 차례·새 head SHA·그 차례의 확인할 것·남은 위험·그 차례 diff"를 받아 같은 규칙으로 댓글을 단다. 부르는 쪽은 C27이다. 수정 차례의 diff 밖 항목은 PR 설명을 고칠 경로가 없으므로(`PATCH pulls` 없음, §16.3) Discord 결과 요약에 싣는 것으로 C27과 맞춘다.
7. 자체 리뷰: 지금 코드는 자체 리뷰가 P0·P1을 내면 고치지 않고 그 변경을 막고(`review_blocked`), P2·P3만 남으면 위험 건수만 싣고 게시한다. 이 티켓은 이 흐름을 바꾸지 않고 자체 리뷰 `findings` 자유문을 PR·댓글에 싣지 않는다. 명세의 "자체 리뷰에서 찾은 문제는 게시 전에 고친다"를 고치는 반복으로 만드는 일은 이 티켓 범위 밖이다(lead에 보고함).
8. 전제 확인: 안내 댓글은 리뷰 App이 변경 대상 저장소에 설치돼 있어야 달린다. 구현 시작 때 변경 정책 저장소에 리뷰 App이 설치됐는지 owner에게 확인하고, 없으면 C30의 설치 범위 넓히기(사람 작업) 뒤로 운영 확인을 미룬다. 설치가 없으면 안내 댓글만 건너뛰고(사유 코드) 게시는 막지 않는다.
9. 시험: PR 설명에 확인할 것 절, 공개 검사에 걸린 항목이 든 게시 거부, 승인 digest가 목록을 묶음, 미리보기 줄, diff 안 위치만 인라인 댓글(가짜 GitHub), diff 밖·위치 없는 항목은 댓글 0건, 자체 리뷰 `findings` 글이 PR·댓글 어디에도 없음, 같은 차례 두 번 호출에 댓글 한 번, 상한 초과 항목은 PR 설명에만.
10. 기록: 봇 `docs/ai-bot/ARCHITECTURE.md` §16.3에 공개 텍스트 계약 변경(확인할 것·남은 위험 칸)과 안내 댓글 경로, `docs/ai-bot/DECISIONS.md`에 자체 리뷰 흐름 판단과 리뷰 App 설치 전제, `docs/ai-bot/VERIFICATION.md`에 "C29 안내 댓글과 확인할 것" 절을 더한다. 이 계획 폴더 `README.md`의 C29 상태 줄을 갱신한다.

## 완료 조건

- [x] 변경 작업이 가정해서 진행하면 미리보기와 PR 설명에 확인할 것 목록이 있고, 승인 digest가 그 목록을 묶는다.
- [x] 처음 게시 뒤 봇 PR에 확인할 것·남은 위험 중 diff 안 위치가 있는 것만 `COMMENT` 리뷰 인라인 댓글로 달린다. 위치가 diff 밖이면 PR 설명에만 있다.
- [x] 자체 리뷰 전체(모델 `findings` 글)는 PR 설명과 댓글 어디에도 게시되지 않는다.
- [x] 확인할 것·남은 위험 글은 공개 검사를 지나고, 걸리면 게시하지 않는다.
- [x] C27이 수정 차례 뒤 같은 함수로 안내 댓글을 달 수 있고, 같은 차례에 두 번 달리지 않는다.

## 검증

- 경계: S1(게시 렌더, 가짜 GitHub `test/change-github-fake.ts`, PGlite). 앞선 시험 예: `change-publication`, `change-assembly`, `publisher-review`, `github-review-app`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 `npm test` 대상(전체는 C24 통합).
- 잡는 실패: 자체 리뷰 전문 게시, diff 밖 인라인 시도, 공개 검사 누락, 확인할 것 누락, 승인 뒤 목록 바꿔치기, 중복 댓글. 못 잡는 범위: 실제 GitHub 표시와 리뷰 App 설치 상태(C24 S5).

## 결과

- 봇 PR #134, 병합 `83b2de6`(2026-11-10). PR 설명·미리보기의 확인할 것·남은 위험, 게시 뒤 diff 안 항목의 `COMMENT` 줄 댓글 한 번, 목록의 7일 원문 정리, 마이그레이션 025(`change_notes`·`change_guidance`). 스위치 밖.
- 완료 조건 5개 충족(S1): `test/change-guidance.test.ts`와 `change-publication`·`change-assembly`·`change-purge-race` 시험.
- 검사: 결과 `74cf7cc`(뒤 커밋은 문서만)에서 전체 2,487개 중 통과 2,464, 실패 1, skip 22. 실패 1은 기존 경합 EVENT-02(원인 확정, C33)이고 그 파일 단독 3회 중 2회 통과. CI `build / test` 통과.
- Codex: 1차 P2 1(목록 원문 7일 정리) 수정, 재리뷰 지적 없음.
- 전제: 리뷰 App `ukyi-review` 설치 범위를 2026-11-10 조직 All repositories로 넓혔다(approvals.md).
- 한계: 안내 댓글은 변경 저장소가 리뷰 정책 저장소 목록(지금 `homelab-smoke`)에 있을 때만 달린다(목록 밖은 `repository_denied`로 건너뜀, 넓힐지는 owner 결정 대기). GitHub hunk와 artifact patch의 문맥 줄 차이, main 배선의 기동 경로는 C24 S5.
