# C27 수정 요청

- 단계: 6 PR 수정
- 상태: integrated (봇 #138 병합 `07fd6d0`, 2026-11-10)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.3 동작 목록("변경 PR 수정" 줄), §4.9(스위치가 수정 요청을 막음), §4.10 "수정 요청"·"PR 댓글 경계(D-16 변경)"·"변경 상태"·"GitHub 쓰기", §5 AC-28, AC-29, §8 "PR 댓글 자료" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C06, C13, C17, C25, C26, C29, C31
- 연결 AC: AC-28, AC-29, AC-27(수정 뒤 diff 밖 항목의 Discord 요약)
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 봇 `src/change-contracts.ts`: 연결 파일, 소유 C25. 자리: 단계 목록과 전이 표(`CHANGE_PHASES`·`CHANGE_PHASE_TRANSITIONS`에 수정 차례 단계와 `proposed` ↔ 수정 차례 전이), 수정 차례 키(change·generation·차례 번호), 차례별 증거 묶음 digest의 새 domain, `ChangeWriterPort`에 C26의 fast-forward 갱신 메서드를 올리는 한 줄, `ChangeAuthorPort`·`ChangeReviewPort`·`ChangeVerificationPort`의 차례 키 입력.
  - 봇 `src/change-store.ts`: 연결 파일, 소유 C17(분해 표 기준. README 5절 표에는 아직 없음). 자리: 수정 차례 시작·결과 기록·`proposed` 복귀 전용 저장 메서드, 차례 대기열, 상한 10번 검사, 차례별 effect intent·claim.
  - 봇 `src/change-runtime.ts`: 연결 파일, 소유 C07. 자리: 수정 차례 단계 처리(작성 → 시험 → 자체 리뷰 → 공개 검사 → 커밋 → 안내 댓글 → Discord 알림), 수정 중 병합·닫힘 감시, 결과·실패 owner 호출 글.
  - 봇 `src/change-publication.ts`: 연결 파일, 소유 C29. 자리: 수정 커밋 뒤 C29의 안내 댓글 함수를 부르는 것과 수정 커밋 메시지 렌더. 공개 검사(`scanPublicPayload`·`scanPublicText`)는 부르기만 한다.
  - 봇 `src/change-review.ts`: 연결 파일, 소유 C31(C31이 만든 차례 키 자리를 수정 차례에도 쓴다). 자리: 차례 키 입력과 receipt 저장 키.
  - 봇 `src/change-publisher.ts`: 수정 커밋 게시 경로(blob → tree → commit → ref 갱신. PR 생성 없음). 연결 파일, 소유 C29(README 5절).
  - 봇 `src/change-artifact.ts`(`ChangeStoreArtifacts` 저장 키), `src/change-verifier.ts`(차례별 시험 receipt 키): 이 티켓만 고치는 파일.
  - 봇 `src/change-commands.ts`: 연결 파일, 소유 C17. 자리: 수정 요청 처리기(제안 실행이 부르는 진입점)와 변경 상태 보기의 차례 줄. 문구는 C18 상수 자리를 따른다.
  - 봇 제안 모듈(C13이 만든 파일, 예: `src/proposals.ts`): 연결 파일, 소유 C13. 자리: 동작 표에 "변경 PR 수정" 한 줄, 허용 대상 대조(봇 변경 PR, 이 owner의 change), 확인 글 문구.
  - 봇 `src/github-writer.ts`, `src/github-review-io.ts`: 연결 파일, 소유 C26. 쓰기만 한다(fast-forward 갱신, PR 리뷰·댓글 읽기).
  - 봇 `src/claude-task-bridge.ts`: 연결 파일, 소유 C09. 자리: `ClaudeChangeAuthor.start`가 C25의 수정 차례 입력을 작업자 요청으로 옮기는 줄과 차례 키 receipt.
  - 봇 `migrations/`: 순번 공유. 수정 차례 표(차례 번호, 상태, 지시 event·label, 읽은 PR 리뷰·댓글 ID 묶음, 결과 커밋, 실패 사유), 차례별 artifact·시험·리뷰·effect 키, 단계 CHECK와 `change_phase_transition_allowed` 함수 교체, effect intent 조건(살아 있는 승인 대신 확정된 수정 요청) 트리거 교체. 병합 때 다음 번호로 다시 매긴다.
  - 시험: `test/change-store.test.ts`·`test/change-store-pg.test.ts`(전이와 PostgreSQL 두 연결), `test/change-assembly.test.ts`, `test/change-freshness.test.ts`, `test/change-recovery.test.ts`, `test/change-contracts.test.ts`(전이 표와 migration 대조), `test/change-review-pg.test.ts`, `test/change-github-fake.ts`, 웹훅 경계는 `test/pr-review.test.ts`·`test/review-*.test.ts` 중 웹훅 수신 시험.
  - 봇 `docs/ai-bot/ARCHITECTURE.md`·`VERIFICATION.md`·`DECISIONS.md`: 추가만.
- 설계 계약:
  - `src/change-contracts.ts`, `src/change-store.ts`, `migrations/`: 봇 ARCHITECTURE "16. T19 CHANGE_PR 계약"의 흐름·전이 표(전이마다 전용 저장 메서드), "끝 상태와 재시작", "표", "DB가 직접 막는 것"(전이 표·단계 진입 조건·effect intent는 부모가 `publishing`이고 살아 있는 승인일 때만), "effect 상태", "digest"(승인 대상은 generation마다 하나), "출처" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md).
  - `src/change-publisher.ts`, `src/github-writer.ts`: 봇 ARCHITECTURE "16.3 T19 B3 writer·공개 경계"의 "첫 blob 전 검사 순서"(보호 경로, `scanPublicPayload`, CI 판정, 브랜치 head 대조), "유실 지점별 복구" 표, "최신성"(다른 SHA의 브랜치는 `head_changed`로 막고 덮지 않음), "commit SHA".
  - `src/change-runtime.ts`, `src/change-review.ts`, `src/change-verifier.ts`, `src/change-artifact.ts`, `src/claude-task-bridge.ts`: 봇 ARCHITECTURE "16.2 미게시 후보 리뷰 (B2)", "16.4 작업 레인 v2: artifact와 무자격 검증 (B1)", "16.5 조립과 꺼짐 배포 (B5)", "16.1 배포 읽기 (B4)"(병합 읽기).
  - `src/change-commands.ts`, 제안 모듈: 봇 ARCHITECTURE "16.5"의 명령 표와 C13의 제안 계약. 봇 ARCHITECTURE "6. 보안 경계"의 Discord 입력 문단.
  - 웹훅 경계: 봇 ARCHITECTURE "6. 보안 경계"의 리뷰 행(REVIEW-04)과 DECISIONS "D-16 PR 리뷰 방식" 머리의 "변경(사용자 2026-11-09…)" 문단.
  - 결정: 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 2·9·16·17, "D-24 봇 변경 PR 작성 신원"의 "T19 세부 결정 (사용자 2026-11-05)"·"T19 운영 결정 (사용자 2026-11-06~07)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).

## 목표

owner가 Discord에서 "이 PR에 리뷰 반영해 줘"처럼 말하면, 봇이 "PR #n에 리뷰 댓글 k개를 반영해서 수정 커밋을 올릴까요?"라고 되묻고, owner가 확정하면 그 PR의 리뷰·댓글을 자료로 읽어 같은 PR 브랜치에 수정 커밋을 올린다. 시험·자체 리뷰·공개 검사를 모두 통과해야 미리보기 없이 fast-forward로 올라가고, 결과 요약은 owner 호출로 Discord에 온다. 실패하면 커밋 없이 이유만 온다. PR 댓글·리뷰만으로는 어떤 수정도 시작되지 않는다.

수정 요청은 동료 기능 스위치(C01)가 켜져 있을 때만 동작 표에 있다. 스위치가 꺼져 있으면 동작이 그대로이므로, 병합하면 바로 적용되는 것은 마이그레이션(새 표, 단계·전이 함수 교체)과 웹훅 경계 시험뿐이다. 마이그레이션은 기존 행을 바꾸지 않는다.

## 할 일

1. 차례 모델을 먼저 정해 ARCHITECTURE §16에 적는다. 지금 계약은 브랜치 이름·artifact·시험·리뷰·승인·effect가 모두 (change, generation)에 묶이고, 새 generation은 새 브랜치(`bot/change/<id>/g<n>`)에서 처음부터라 같은 PR 브랜치를 쓸 수 없다. 그래서 수정 차례는 generation을 올리지 않고 (change, generation, 차례 번호)로 키를 하나 더 둔다. 브랜치는 그 generation의 것 그대로이고, 처음 게시의 승인 digest 규칙(generation마다 승인 대상 하나)은 바꾸지 않는다.
2. 단계와 전이(`src/change-contracts.ts`, `migrations/`): 수정 차례 단계를 더하고 `proposed → 수정 차례 → proposed` 전이를 연다. 수정 중 PR이 병합·닫히면 커밋하지 않고 `merged`·`cancelled(closed_unmerged)`로 나갈 수 있게 하고, 차례 effect가 해소되지 않으면 `blocked`로 둔다. 코드 전이 표와 migration의 `change_phase_transition_allowed`를 같은 변경에서 고치고, 기존 대조 시험(모든 쌍)을 늘린다.
3. 저장(`src/change-store.ts`, `migrations/`): 수정 차례 표와 전용 메서드(차례 시작, 결과 기록, `proposed` 복귀). 한 change의 차례는 최대 10번이고 11번째 요청은 거부한다. 수정 중에 확정된 요청은 다음 차례로 대기열에 넣는다(병렬 실행 없음). 차례마다 증거(artifact, 시험 receipt, 리뷰 receipt)를 새로 만들고 이전 차례의 것을 재사용하지 않는다. DB 쪽 effect intent 조건을 "부모가 수정 차례이고 그 차례의 확정된 요청이 있음"으로 넓히되 처음 게시의 조건은 그대로 둔다. 동시에 두 요청이 확정돼도 차례 하나만 시작되는지 PostgreSQL 두 연결 시험으로 고정한다.
4. 동작 연결(제안 모듈, `src/change-commands.ts`): C13 동작 표에 "변경 PR 수정"(실행 요청, 스위치 뒤)을 더한다. 대상은 이 owner의 change이고 `proposed` 단계이거나 수정 차례가 진행 중인 봇 PR이어야 한다. 수정 차례 중에 확정된 요청은 3번의 대기열에 들어간다(명세 4.10 "수정 중에 온 새 수정 요청은 다음 차례로 받는다"). 병합·닫힌 PR, 남의 change, 상한(대기열에 든 요청 포함)에 닿은 change는 확인 글을 만들지 않고 동료 말투로 거절한다. 확인 글을 만들 때 C26 읽기 포트로 리뷰·댓글을 읽어 k를 세고, 그 ID 묶음과 PR head를 제안 값 digest에 넣는다. 실행은 그 ID 묶음까지의 댓글만 쓰고, 그 뒤에 달린 댓글은 다음 차례 몫이다. 지시는 owner가 보낸 원문(멘션 표기 제거)이고, label은 DECISIONS 15(변경 요청은 확인을 누르면 `label=public`으로 접수)와 같게 기록한다[판단: 명세에 수정 요청의 label 문장이 없어 DECISIONS에 적는다].
5. 작성(`src/claude-task-bridge.ts`, `src/change-runtime.ts`): 차례가 시작되면 지금 PR 브랜치 head와 그 tree를 다시 읽는다. head가 확인 때의 head와 같거나, 확인 뒤 head까지의 커밋이 모두 이 change의 앞선 수정 차례가 올려 확정된 커밋(차례 effect 기록과 대조)이면 그 head 위에서 작성한다. 그 밖의 head 변경(사람 push 등)이면 커밋 없이 `head_changed`로 실패하고 Discord에 다시 요청해 달라고 알린다. 대기열의 요청은 이 규칙으로 앞 차례의 커밋 위에서 이어진다. C25의 수정 차례 입력(지시 + PR 리뷰·댓글 자료 블록)과 새 지시문 판으로 작성 실행을 시작한다. 작업자가 새 판을 받는지는 C25의 intake 능력으로 확인하고, 아니면 차례를 실패로 닫는다. 작성 질문이 나오면 지금의 변경 질문 경로(작업 질문, `ChangeAnswerGuard`)를 그대로 쓴다. C28이 병합된 뒤에는 그 경로에 선택지 버튼이 붙는다. 이 티켓은 질문 경로를 새로 만들지 않는다.
6. 검사: 차례 결과 artifact에 처음 게시와 같은 검사(보호 경로·허용 경로 `inspectCandidate`, 필수 시험 전부 통과, 새 세션의 자체 리뷰 `pass`·`pass_with_warnings`이고 커버리지 완전, `scanPublicPayload`, CI 판정)를 거친다. 하나라도 실패하면 커밋하지 않는다.
7. 게시(`src/change-publisher.ts`, `src/github-writer.ts`): 검사를 통과하면 미리보기·승인 없이 blob → tree → 커밋(부모는 확인한 PR head 하나, 고정 author·committer·시각, 커밋 메시지는 코드가 만든 고정 문구와 차례 번호. 모델 글 없음) → C26 fast-forward 갱신 순서로 올린다. effect는 차례 키로 기록하고 유실 지점별 복구 규칙(unknown은 대조만, 재전송 없음)을 그대로 따른다. 보내기 직전에 PR이 열려 있고 head가 그대로인지 다시 본다. 강제 갱신 경로는 없다.
8. 뒤처리(`src/change-publication.ts`, `src/change-runtime.ts`): 커밋이 확정되면 C29의 안내 댓글 함수를 그 커밋 기준으로 부르고, Discord에 결과 요약(차례 번호, 바뀐 파일 수, 시험 결과, 확인할 것 건수, 그리고 확인할 것·남은 위험 중 diff 밖이거나 위치가 없는 항목. 모델 문장은 공개 검사를 거친 이 항목들만)을 owner 호출로 보낸다. PR 설명은 고치지 않는다(AC-27). 실패면 커밋 없이 이유(고정 사유 코드를 동료 말투로)를 owner 호출로 보낸다. 결과·실패 알림은 owner 호출 대상에 더하는 두 종류다(C07의 호출 표에 줄 추가). 그다음 `proposed`로 돌아가 대기열의 다음 요청을 본다.
9. PR 댓글 경계(AC-29): PR 리뷰·리뷰 댓글·대화 댓글 웹훅(owner 것 포함)은 수정·작업을 시작하지 않는다. `/homelab-review` 댓글은 지금처럼 리뷰만 다시 부른다. 웹훅 수신(`src/review.ts`의 `issue_comment` 분기 등)은 고치지 않고 시험으로 고정한다. 댓글 내용은 수정 요청 때 그 PR에서만 읽히고 다른 PR의 댓글이 섞이지 않는 것도 시험으로 고정한다.
10. 스위치: 스위치가 꺼져 있으면 동작 표에 줄이 없고, 진행 중인 차례가 있어도 새 차례를 열지 않는다(진행 중인 것은 끝까지 간다).
11. 시험(S1, S2): 전이(정상 한 차례, 실패 뒤 `proposed` 복귀, 11번째 거부, 병합·닫힌 PR 거부, 수정 중 병합 감지 뒤 커밋 없음, 수정 중 요청은 다음 차례이고 앞 차례 커밋 위에서 `head_changed` 없이 이어짐, 사람 push 뒤에는 `head_changed`), PostgreSQL 두 연결로 동시 확정, 검사 실패 커밋 없음, fast-forward만 쓰고 강제 갱신 없음, effect 유실 뒤 재전송 없음, 자료 블록이 지시 자리에 들어가지 않음(S2는 C25 시험을 부름), 웹훅이 아무것도 시작하지 않음.
12. 기록: 봇 ARCHITECTURE §16 전이 표·흐름도·표 목록과 "DB가 직접 막는 것"에 수정 차례, §16.3 유실 표에 ref 갱신 줄, `VERIFICATION.md`에 "C27 수정 요청" 절, `DECISIONS.md` "동료 봇 전환" 16에 차례 모델(1번)과 label 판단(4번). 이 계획 폴더 `README.md`의 C27 상태 줄 갱신.

## 완료 조건

- [x] owner가 Discord에서 봇 PR 수정을 요청하면 "PR #n에 리뷰 댓글 k개를 반영해서 수정 커밋을 올릴까요?" 확인 뒤, 그 PR의 리뷰·댓글을 자료로 읽고 고친다(AC-28).
- [x] 시험·자체 리뷰·공개 검사를 통과하면 미리보기 없이 같은 브랜치에 수정 커밋이 fast-forward로 올라가고 Discord에 owner 호출로 결과가 온다. diff 밖 확인할 것·남은 위험은 그 결과 요약에 있다(AC-27). 실패하면 커밋 없이 이유가 온다.
- [x] 한 PR의 11번째 수정, 병합·닫힌 PR 수정은 거부되고, 수정 중에 온 요청은 다음 차례가 된다. 동시 확정에도 차례는 하나씩만 돈다.
- [x] PR 리뷰·댓글 웹훅만으로는 어떤 수정·작업도 시작되지 않고, `/homelab-review`는 리뷰만 다시 부른다(AC-29).
- [x] 스위치가 꺼져 있으면 수정 요청 동작이 없다.

## 검증

- 경계: S1(변경 상태 전이, PGlite + PostgreSQL 두 연결, 가짜 GitHub writer·리뷰 App, 웹훅 수신), S2(작성 입력의 자료 블록, C25 시험). 앞선 예: `change-store-pg`, `change-assembly`, `change-freshness`, `change-recovery`, `change-purge-race`, `pr-review`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험. 전체 `npm test`는 통합 담당 C24.
- 잡는 실패 / 못 잡는 범위: 잡는 것은 검사 실패 커밋 게시, 강제 갱신, 상한 무시, 병합된 PR 수정, 댓글이 지시 자리로 들어가는 것, 댓글이 작업을 일으키는 것, 다른 PR 댓글 혼입, 중복 차례다. 못 잡는 범위: 실제 GitHub push·CI와 ruleset E 아래 fast-forward(S5, C24 "수정 요청 한 차례"), 자료 안 프롬프트 주입이 작성 모델을 속이는 경우(실행 확인·검사·owner의 병합 전 리뷰가 방어).

## 결과

- 봇 PR #138, 병합 `07fd6d0`(2026-11-10). 단계 `amending`(proposed ⇄ amending), 상한 10번, 마이그레이션 027(차례 대기열과 차례별 artifact·시험·리뷰·effect), 제안 동작 `change_amend`, fast-forward 수정 커밋, 안내 댓글(C29)과 owner 호출 결과 글. 쓰기 허용은 `amending`이고 그 차례가 `change_amendment_may_send`일 때만.
- 완료 조건 충족(S1, 실제 `assembleChange` 경로와 실제 PostgreSQL 두 연결 포함): `test/c27-change-amend.test.ts`와 `change-assembly`·`change-store`·`change-store-pg`·`change-contracts`·`pr-review` 시험.
- 검사: 결과 `88e75ff`에서 전체 2,552개 중 통과 2,530, 실패 0, skip 22. CI `build / test` 통과.
- Codex: 1차 P2 5(재시작 뒤 실패 전이, PR 링크 저장소 대조, 미전송 effect 해소, 안내 실패 시 요약, 알림 커서), 2차 보안 P2 1(확인 시점 자료 digest 대조) 수정. 3차 P2 2(통과 receipt 뒤 작성 세션 정리, 닫힌 PR 거절)는 C34로 넘김.
- 주 진행자 결정: 조립 배선(`change-assembly.ts`·`main.ts`) 허용, 확인 뒤 새로 달린 댓글은 실패로 닫지 않음(모델에는 확인한 글만 간다).
- 함께 고친 시험 흔들림: C28 "다음 말"(멘션이 남긴 대화 job이 디바운스 뒤 리뷰 claim을 양보시킴), R08 변형 시험(시각을 변형마다 다시 읽음). 둘 다 시험만의 문제.
- 한계: 모델이 `change_amend`를 제안하려면 작업자 이미지 교체가 필요하다(게시 서버 먼저). PR 글 읽기는 리뷰 정책 저장소 목록(지금 `homelab-smoke`)을 거친다. 번호만 말하면 같은 스레드의 가장 최근 변경을 고른다(확인 글에 저장소 표시). 실제 push·CI·ruleset 아래 fast-forward는 C24 S5.
