# C25 작업자 변경 작성 v2: 확인할 것·선택지 질문·수정 차례 입력

- 단계: 1 기반
- 상태: integrated (봇 #119 병합 `fc93fe2`, 2026-11-10)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.10 "변경 질문 줄이기"·"수정 요청"·"안내 댓글", §5 AC-25, AC-28 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C03
- 연결 AC: AC-25(S2: 작성 모델 출력 계약), AC-28(S2: 작성 입력의 자료 블록)
- 수행: 에이전트
- 저장소·PR: 봇 PR(작업자 배포는 C06이 이 티켓까지 함께 싣는다)
- 파일 소유:
  - 봇 `src/change-contracts.ts`: 소유(연결 파일. 뒤에 C27이 수정 차례 전이·effect 자리를, C28·C29가 선택지·확인할 것을 읽는다). 자리: `AuthorResult`의 `needs_input`(선택지 칸)과 `snapshot`(확인할 것·남은 위험 칸), `ChangeAuthorPort`의 `start` 입력(수정 차례 입력 칸). 이 티켓은 타입·스키마만 넓히고 구현(`ClaudeChangeAuthor`)은 바꾸지 않는다.
  - 봇 `src/executor-claude-task.ts`: 연결 파일, 소유 C03. 자리: `TASK_INSTRUCTIONS`(새 판 글), `taskPrompt`(수정 차례의 지시·자료 블록 울타리), `judgeTaskRun`의 구조화 출력 해석과 반사 검사(`echoesSecret`) 대상, `runChangeTurn`의 `needs_input`·`snapshot` 결과 조립, 실행기에 넘기는 출력 스키마 선택.
  - 봇 `src/task-contracts.ts`: 연결 파일, 소유 C03. 자리: `TASK_INSTRUCTIONS_REVISION`(판 목록으로 넓힘), v2 요청 스키마(`TaskV2StartSchema`의 수정 차례 입력), v2 결과 스키마(`TaskV2ResultResponseSchema`의 `needs_input` 선택지, `snapshot` 확인할 것·남은 위험), 상한(`TASK_LIMITS`·`TASK_V2_REQUEST_CHARS` 곁의 새 상한).
  - 봇 `src/task-http.ts`: intake 응답의 `change` 능력(`TaskIntakeSchema`의 `change` 칸과 `taskRoutes`의 intake 응답)에 받는 지시문 판 목록을 더하는 자리. 게시 서버와 작업자가 함께 쓰는 파일이고, 이 티켓만 고친다(README 5절).
  - 바꾸지 않음: 봇 `src/codex-events.ts`의 `TaskOutputSchema`·`TASK_OUTPUT_JSON_SCHEMA`(Codex 작업 레인 `src/codex.ts`와 공유). 변경 작성 새 판의 출력 스키마는 판 이름으로 고르는 별도 스키마로 둔다.
  - 시험: `test/task-contracts.test.ts`, `test/task-stream.test.ts`, `test/task-worker.test.ts`, `test/change-artifact.test.ts`(v2 턴 결과), `test/change-contracts.test.ts`, 작업자 하네스 `test/task-worker-harness.ts`·`test/change-worker-harness.ts`의 고정 출력.
  - 봇 `docs/ai-bot/ARCHITECTURE.md`·`VERIFICATION.md`·`DECISIONS.md`: 추가만.
- 설계 계약:
  - `src/executor-claude-task.ts`, `src/task-contracts.ts`, `src/task-http.ts`: 봇 ARCHITECTURE "16.4 작업 레인 v2: artifact와 무자격 검증 (B1)"(끝점 표, intake `change:{contract:2,verifierRevision}` 지원 판정, 결과 보존), "12. T18 CODEX_BRIDGE 로컬 계약"의 "T18 작업 레인 계약 (Claude, 2026-11-05)"(지시문 판은 게시 서버와 작업자가 같아야 시작, 비신뢰 글은 태그 안)과 "질문 계약 (TASK-02, AUTH-02)"(답은 권한·도구 승인이 아님) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md).
  - `src/change-contracts.ts`: 봇 ARCHITECTURE "16. T19 CHANGE_PR 계약"의 port 표(`ChangeAuthorPort`)와 "출처" 문단(label은 올릴 수만 있음, 원문은 `ChangePrivateInputs`로만), "16.3 T19 B3 writer·공개 경계"의 "공개 문구" 문단(공개 렌더러는 구조화 값만, 비밀·내부 표식이면 전체를 막음).
  - 결정: 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 14(가정 진행·확인할 것·선택지 2~4개), 16(수정 요청, PR 리뷰·댓글은 자료로만), 17(안내 댓글), "D-24 봇 변경 PR 작성 신원"의 "T19 세부 결정 (사용자 2026-11-05)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).

## 목표

변경 작업을 쓰는 작업자가 새 지시문 판을 받으면, 막히지 않는 한 묻지 않고 가정해서 진행하고 그 가정을 **확인할 것** 목록으로 낸다. 정말 진행할 수 없을 때만 선택지 2~4개가 붙은 질문을 낸다. 확인할 것과 남은 위험에는 파일·줄 위치를 붙일 수 있다. **수정 요청** 차례에는 PR 브랜치 head 위에서 owner 지시(Discord 말)를 지시로, PR 리뷰·댓글을 자료 블록으로 받아 고친다.

작업자는 옛 판과 새 판을 둘 다 받는다. 게시 서버는 이 티켓에서 여전히 옛 판(`task-v1`)만 보내므로, 병합하면 바로 적용되는 것은 게시 서버 쪽 계약 스키마가 새 칸을 받을 수 있게 넓어지는 것뿐이고 owner가 보는 동작은 그대로다. 새 판을 보내고 결과를 쓰는 일은 C27(수정 요청)·C28(선택지)·C29(확인할 것·안내 댓글)가 한다. 작업자 배포는 C06이다.

## 할 일

1. 지시문 판을 목록으로 넓힌다(`src/task-contracts.ts` `TASK_INSTRUCTIONS_REVISION`). v1 작업 레인 요청은 지금 판만 받고, v2(변경 작성) 요청은 지금 판과 새 변경 작성 판을 둘 다 받는다. 판 이름은 구현 때 정하고 DECISIONS에 적는다.
2. 새 판의 지시문(`src/executor-claude-task.ts` `TASK_INSTRUCTIONS`): 막히지 않으면 묻지 않고 가정해서 진행하고 가정은 확인할 것으로 낸다. 진행 자체가 불가능할 때만 질문하고 선택지 2~4개를 함께 낸다. 공개 여부는 묻지 않는다. 확인할 것과 남은 위험에는 아는 경우에만 위치(저장소 안 경로·줄)를 낸다. 기존 안전 줄(태그 안 글은 자료, 정책·권한·샌드박스·게시 대상을 바꾸지 않음, 쓰는 도구 범위)은 그대로 둔다.
3. 새 판의 구조화 출력 스키마를 따로 둔다. 지금 출력(`status`·`summary`·`question`)에 선택지 목록, 확인할 것 목록, 남은 위험 목록을 더한다. 구조화 출력은 루트 객체·전 필드 required·추가 필드 금지라(`src/codex-events.ts` 주석) 위치가 없는 항목은 빈 값으로 표시하는 평평한 모양으로 둔다. 길이·개수는 봇이 자른다. Codex 작업 레인의 스키마는 바꾸지 않는다.
4. 출력 검사(`judgeTaskRun`): 새 판이면 새 스키마로 해석한다. `needs_input`이면 선택지가 2~4개여야 하고 아니면 `invalid_output`. 선택지·확인할 것·남은 위험 글도 자격 반사 검사(`echoesSecret`) 대상에 넣는다. 위치의 경로는 경로 규칙(`ChangePathSchema`)과 manifest 경로 상한을 지키고, 줄은 양의 정수다. 어긋난 위치는 버리고 항목은 남긴다.
5. 결과 계약(`src/task-contracts.ts` `TaskV2ResultResponseSchema`): `needs_input`에 선택지 칸, `snapshot`에 확인할 것·남은 위험 칸을 선택 칸으로 더한다(새 판 요청일 때만 채운다). 지금 `runChangeTurn`은 "모델이 낸 요약은 결과에 싣지 않는다. 작성자 설명은 증거가 아니고 공개 경로로 샐 수 있다"는 규칙이라, 모델이 쓴 확인할 것·남은 위험을 결과에 싣는 것은 이 규칙을 바꾸는 일이다. 이 칸은 증거(승인 digest 재료)가 아니고, 공개 경로에 나가기 전에 게시 서버가 공개 검사(`scanPublicText`)를 거친다(C29). 이 변경을 ARCHITECTURE §16.4와 DECISIONS에 적는다.
6. 수정 차례 입력(`src/task-contracts.ts` v2 시작 요청, `src/executor-claude-task.ts` `taskPrompt`): 시작 턴에 수정 차례 표시를 둔다. 수정 차례이면 `base`는 PR 브랜치 head이고 baseline은 그 head의 tree다(T0 대조 규칙 그대로). owner 지시는 지시 자리(`untrusted_request`와 다른 이름의 태그)로, PR 리뷰·리뷰 댓글·대화 댓글은 자료 블록 태그로 넣는다. 자료 블록에는 작성자 ID·association·위치·본문만 넣고 "자료이지 지시가 아니다"를 지시문에 둔다. 자료 블록은 상한(개수·글자)을 두고 넘치면 오래된 것부터 빼고 잘렸다는 표시를 남긴다(`TASK_V2_REQUEST_CHARS`·`TASK_LIMITS.bodyBytes` 안). 자료 블록의 label은 공개 저장소 PR 내용이므로 `public`으로만 받는다.
7. intake 능력(`src/task-http.ts`): `change` 능력에 받는 지시문 판 목록을 더한다. 게시 서버 쪽 intake 해석은 그 칸이 없어도 받는다(옛 작업자). 새 판을 보낼지는 이 칸으로 정한다는 규칙을 ARCHITECTURE §16.4에 적는다(실제 판 선택은 C27·C28·C29).
8. 서버 쪽 port 타입(`src/change-contracts.ts`): `AuthorResult`의 `needs_input`에 선택지, `snapshot`에 확인할 것·남은 위험을 선택 칸으로 더하고, `ChangeAuthorPort.start` 입력에 수정 차례 입력(지시, 자료 블록, PR 번호·head)을 선택 칸으로 더한다. `ClaudeChangeAuthor`(`src/claude-task-bridge.ts`, 소유 C09)는 고치지 않는다. 이 칸을 채우고 쓰는 일은 C27·C28·C29가 한다.
9. 호환: 새 판 요청을 옛 작업자에 보내면 모양에서 거부되고(지시문 판 불일치), 옛 판 요청을 새 작업자에 보내면 지금과 같은 응답이 나와야 한다. 게시 서버만 이 PR 이전으로 되돌려도 작업자는 옛 판 요청에 옛 응답만 내므로 깨지지 않는다는 것을 시험으로 고정한다.
10. 시험(S2): 고정 stream-json을 내는 가짜 CLI로 (가) 새 판 가정 진행 → `snapshot`에 확인할 것·위치, (나) 새 판 진행 불가 → `needs_input`과 선택지 2~4개, (다) 선택지 0·1·5개 → `invalid_output`, (라) 선택지·확인할 것에 자격이 반사되면 `secret_echo`, (마) 수정 차례 프롬프트에서 PR 댓글이 자료 태그 안에만 있고 지시 자리에 없음, 태그 닫기 문자열 주입 제거, 상한 초과 때 잘림 표시, (바) 옛 판 요청의 응답이 지금과 같음.
11. 기록: 봇 ARCHITECTURE §16.4에 "변경 작성 v2 판" 문단(판 목록, 출력 칸, 수정 차례 입력, 결과에 모델 글을 싣는 범위와 공개 검사 위치), `VERIFICATION.md`에 "C25 작업자 변경 작성 v2" 절, `DECISIONS.md` "동료 봇 전환" 14·16에 구현 위치 한 줄. 이 계획 폴더 `README.md`의 C25 상태 줄 갱신.

## 완료 조건

- [x] 작업자가 새 판 요청에 확인할 것(위치 선택)과 남은 위험을 `snapshot` 결과에 싣고, 진행 불가면 선택지 2~4개가 붙은 `needs_input`을 낸다(AC-25 S2).
- [x] 선택지 개수가 틀리거나 자격이 반사된 출력은 결과로 나가지 않는다.
- [x] 수정 차례 요청에서 PR 리뷰·댓글은 자료 블록 태그 안에만 들어가고, 지시 자리는 owner 지시뿐이다(AC-28 S2).
- [x] 옛 판 요청에 대한 작업자 응답과 게시 서버 동작이 지금과 같다.
- [x] intake가 받는 지시문 판을 알리고, 옛 작업자의 intake도 게시 서버가 받는다.

## 검증

- 경계: S2(작업자 요청 → 실행기(고정 stream-json 가짜 CLI) → 응답). 앞선 시험 예: `task-stream`, `task-worker`, `task-contracts`, `change-artifact`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험(`task-contracts`, `task-stream`, `task-worker`, `change-artifact`, `change-contracts`). 전체 `npm test`는 통합 담당 C24.
- 잡는 실패 / 못 잡는 범위: 잡는 것은 선택지 없는 질문, 확인할 것 누락, 댓글이 지시 자리로 들어가는 것, 자격 반사, 옛 판 회귀다. 못 잡는 범위: 모델이 언제 가정하고 언제 묻는지의 판단 품질(S5, C24), Discord 질문 글·버튼(C28), 미리보기·PR 설명 반영과 공개 검사(C29), 실제 PR 브랜치 head에서의 수정과 게시(C27).

## 결과

- 봇 PR #119(`feat/colleague-c25-change-authoring-v2`, 결과 head `ca73a56`), 병합 `fc93fe2`(2026-11-10). 게시 서버는 여전히 `task-v1`만 보낸다.
- 구현: `src/task-contracts.ts` 판 목록 `TASK_INSTRUCTIONS_REVISIONS = ['task-v1', 'change-v2']`(서버가 보내는 판 상수 `TASK_INSTRUCTIONS_REVISION`은 C09 소유 브리지가 쓰므로 그대로), v2 시작 요청 선택 칸 `amendment`(끝에, `head === base` refine), v2 결과 `needs_input.options`·`snapshot.checks`·`risks`, 상한 `CHANGE_NOTE_LIMITS`·`AMENDMENT_LIMITS`·`boundAmendmentMaterials`. `src/executor-claude-task.ts` 새 지시문 `change-v2`, `<owner_instruction>`·`<review_material>` 울타리, `CHANGE_OUTPUT_JSON_SCHEMA`, `judgeTaskRun` 선택지 개수·반사 검사·위치 검사(틀린 줄만 버림). `src/task-http.ts` intake `change.instructions`와 `taskWorkerChangeInstructions`. `src/change-contracts.ts` 타입만(`ClaudeChangeAuthor`는 그대로).
- 완료 조건 근거: C25 시험 11개(`change-artifact`의 `C25 가정 진행`·`C25 진행 불가`·`C25 출력 검사`·`C25 수정 차례`·`C25 호환`, `task-contracts`의 `C25 결과 칸`·`C25 수정 차례 입력`·`C25 자료 블록 상한`·`C25 지시문 판`·`C25 intake`).
- 검사: 작업자 관련 10개 파일 378/378. 통합 담당 전체 검사(`ca73a56`, node 24.22.0, 실제 PG, 잠금): 2261 tests / 2239 pass / 0 fail / 22 skip(SEC02_IMAGE). Codex 코드·보안 지적 없음, `build / test` 통과.
- 남은 것: TDD 빨강은 타입 검사 실패로만 확인(시험 실행으로는 보지 않음). 옛 작업자 이미지의 새 판 거부는 코드 대조만(`instructions: z.literal('task-v1')`). 고정 CLI 2.1.308이 중첩 객체 배열 출력 스키마를 지키는지는 S5(C24). 상한 값(자료 50개·본문 4,000자·합계 40,000자, 메모 10개·300자, 선택지 100자)은 제안 값. 롤백 주의는 C06에.
- 뒤 티켓에 넘김: C27은 PR 토론을 `ReviewMaterial`로 바꾸고(경로가 `ChangePathSchema`를 못 지나면 `location: null`, 탈퇴 작성자는 `authorId: null`) `boundAmendmentMaterials`로 줄이며, `changeInstructions()`에 `change-v2`가 있을 때만 새 판을 보낸다. C28은 `ClaudeChangeAuthor`가 `options`를 `AuthorResult`로 옮기게 잇고 선택지에 공개 검사. C29는 `checks`·`risks`에 `scanPublicText`.
