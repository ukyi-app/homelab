# C11 대화 v2 전환

- 단계: 3 새 형식 켜기
- 상태: integrated (봇 #124 병합 `860b591`, 2026-11-10)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.2 대화 답과 작업자 계약 v2, §4.5 반응과 봇 상태(`ack_only`의 👍) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C01, C04, C06, C08
- 연결 AC: AC-3, AC-4(서버), AC-5, AC-14(👍)
- 수행: 에이전트
- 저장소·PR: 봇 PR(C06 운영 확인이 homelab `approvals.md`에 기록된 뒤 병합)
- 파일 소유:
  - 소유(표 밖, 이 티켓만 고침): 봇 `src/chat-format.ts`(라벨 렌더 대신 `reply` 그대로, 대화 빈 답 문구, 공개 검사에 걸린 답의 고정 문구)
  - 공유 파일(README 5절에 반영): 봇 `src/runtime.ts`의 대화 성공 분기(`reply`·`ack_only`·공개 검사로 게시 내용을 정하는 자리). C13이 같은 분기에 제안 처리를, C19·C20이 한도 대기 분기를 더한다
  - 연결 파일, 소유 C02: 봇 `src/worker.ts`(서버 쪽 요청 조립을 v2로), `src/contracts.ts`(v2 답 스키마와 대화 기록 상한 상수를 쓰기만), `src/bot-facts.ts`(surface 값 선택만, 변형 내용은 C02)
  - 연결 파일, 소유 C08: 봇 `src/chat-context.ts`(상한 50개·80KiB, 정리돼 빠진 앞부분 표시)
  - 연결 파일, 소유 C04: 봇 `src/store.ts`의 `context()`·`finish()` 호출 자리(C09도 이 파일의 문구 자리를 고치므로 시그니처는 C09가 통합된 main 위에서 맞춘다)
  - 연결 파일, 소유 C04: 봇 `src/discord.ts`·`src/discord-protocol.ts`의 반응 훅을 불러 👍를 단다(훅 자체는 고치지 않음)
  - 시험: `test/chat-format.test.ts`, `test/s16-display.test.ts`, `test/chat-ack.test.ts`, `test/chat-context.test.ts`, `test/foundation.test.ts`의 대화 게시 줄
- 설계 계약:
  - `src/chat-format.ts`, `src/runtime.ts`: 봇 ARCHITECTURE §13 "대화 답 형식 (출력 스키마는 그대로)"(이 티켓이 v2 형식으로 고쳐 쓴다), §11 "호출 경로·직렬 대기·측정", §13 "불확실한 결과와 chat unknown"(성공 판정 뒤에만 게시), §12 "T18 게시 서버 스케줄링과 질문"의 "출력 공개 검사(T25)"(`scanPublicText` 기준) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md)
  - `src/worker.ts`, `src/contracts.ts`, `src/bot-facts.ts`: 봇 ARCHITECTURE §12 "T16b 작업자 진입점", §13 "봇 답 문맥 (`untrusted`)"의 신뢰 문맥 문단, 명세 §4.2 "계약 배포 순서"
  - `src/chat-context.ts`: 봇 ARCHITECTURE §13 "봇 답 문맥 (`untrusted`)"(현재 메시지 마지막, 직전 봇 답, 최신부터 채움, 비운 원문 처리), §11 "저장·권한·게시"(대화 맥락 범위 문장)
  - 반응: 봇 ARCHITECTURE §13 "수신·진행 신호"
  - 결정: 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 2·5·6 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md)

## 목표

owner의 멘션 요청에 대한 답이 라벨 목록이 아니라 결론부터 말하는 해요체 문장으로 달린다. 답할 필요가 없는 말에는 글 없이 👍만 남는다. 긴 스레드에서도 앞 대화 50개까지 맥락에 들어가고, 원문이 7일 정리로 빠진 앞부분이 있으면 모델이 아는 척하지 않도록 그 사실이 신뢰 문맥에 표시된다. 모델 답이 공개 검사에 걸리면 모델 글 대신 고정 문구만 나간다. 병합하면 스위치와 무관하게 바로 운영에 나간다(스위치 켜짐이면 surface가 speech가 되는 것만 다르다).

## 할 일

1. 시작 전에 C06 배포 뒤 운영 확인(v1 서버 + v2 작업자 대화·리뷰·작업 성공)이 homelab `docs/plans/2026-10-17-homelab-rebuild/approvals.md`에 있는지 본다. 없으면 병합하지 않는다.
2. 게시 서버가 대화 작업자 요청을 v2로 보낸다. surface는 C01 스위치가 켜져 있으면 speech, 꺼져 있으면 slash다. v1 요청을 만드는 경로는 남기지 않는다(작업자 쪽 v1 수용은 시범 뒤 정리, 명세 §4.2).
3. 성공 응답의 `reply`를 라벨 없이 게시한다. 기존 1,800자 페이지 분할과 대조 표식 규칙은 그대로 쓴다. `reply`가 비었으면 동료 말투의 빈 답 문구를 낸다.
4. `ack_only`가 참이면 글을 게시하지 않고 C04 반응 훅으로 👀를 지우고 👍를 단다. 결과는 지금처럼 저장하고, 대화 기록의 봇 항목에는 넣지 않는다(게시 본문이 없음).
5. `reply`를 게시 전에 작업 레인과 같은 공개 검사로 본다. 걸리면 모델 글 대신 고정 문구만 게시하고, 결과에 사유 코드만 남긴다(모델 글을 감사·로그에 싣지 않음). 자격 반사 검사는 그대로다.
6. 대화 기록 상한을 50개·80KiB로 올린다(현재 owner 메시지 마지막, 오래된 것부터 뺌, 넘치는 봇 답의 `partial` 규칙 그대로). 7일 정리로 비어 빠진 owner 메시지나 봇 페이지가 있으면 C02가 만든 요청 칸에 "기억나지 않는 앞부분 있음"을 싣는다.
7. v2 응답의 `proposal`은 이 티켓에서 버린다(저장·게시하지 않음). 감사에 제안이 있었다는 사실과 동작 이름만 남길지는 C13과 맞춘다.
8. 시험: 라벨 없는 게시, `ack_only` 👍(가짜 Discord REST 호출 순서), 공개 검사 걸림 → 고정 문구, 50개·80KiB 경계와 현재 메시지 보존, 정리 표시 칸, 스위치 두 상태의 surface, v2 서버 + v1 작업자 조합이 요청 거부로 닫히고 성공으로 보이지 않음.
8a. C04에서 넘어온 반응 정리(봇 PR #114 Codex 3차 P2, 댓글 4515364186): 모델 실행 중 `/stop`으로 대화가 비활성이 되면 `Runtime.execute()`(`src/runtime.ts` 170행 근처)와 `Store.finish()`의 비활성 경로가 작업을 `superseded`로 끝내고 답을 게시하지 않는데, 이 경로에 `settleReactions()`가 없어 👀·⏳와 `reaction:` 행이 남는다. 그 종료 전이와 함께 반응을 지움 상태로 옮기고, 실행 중 `/stop` → 성공 → 반응 정리를 시험으로 고정한다(`src/store.ts`는 C04 소유 연결 파일이라 그 자리만 고친다).
8b. C08에서 넘어옴: 작업자 대화 프롬프트(`src/chat-lane.ts` `chatPrompt`)가 대화 기록의 `owner`·`bot` 항목만 설명한다. C08이 더한 `replied_bot_post`(owner가 답장한 봇 글 본문, 자료) 항목을 v2 프롬프트에 한 줄로 설명한다.
9. 기록: 봇 `docs/ai-bot/ARCHITECTURE.md` §13 "대화 답 형식"과 "봇 답 문맥" 문단을 v2로 고치고, `docs/ai-bot/VERIFICATION.md`에 "C11 대화 v2 전환" 절, 이 계획 폴더 `README.md`의 C11 상태 줄 갱신.

## 완료 조건

- [x] 대화 답이 `사실:`·`가설:` 같은 라벨 없이 `reply` 문장으로 게시된다(스위치 두 상태 모두).
- [x] `ack_only`면 글 없이 👍만 남고 👀는 지워진다.
- [x] 공개 검사에 걸리는 답은 모델 글 없이 고정 문구만 나간다.
- [x] 대화 기록이 50개·80KiB까지 들어가고, 넘치면 현재 owner 메시지가 마지막에 남고 오래된 것부터 빠진다. 정리돼 빠진 앞부분이 있으면 신뢰 문맥 표시 칸이 채워진다.
- [x] v2 서버 + v2 작업자 대화가 성공하고, v2 서버 + v1 작업자는 요청 거부로 닫힌다.

## 검증

- 경계: S1(서버 렌더·검사·기록 조립, 앞선 예 `chat-format`, `s16-display`, `chat-ack`, `chat-context`)과 S2(작업자 v2 계약, 앞선 예 `worker-entry`, `worker-server`).
- 명령: 봇 `npm run check`, 바뀐 파일 관련 `npm test` 대상(전체는 C24 통합).
- 잡는 실패: 라벨 렌더 잔존, 공개 검사 누락, `ack_only` 처리 오류, 스키마·상한 불일치로 인한 요청 거부, 현재 메시지 누락, 정리 표시 누락. 못 잡는 범위: 모델 말투의 실제 품질과 모델이 표시를 보고 "기억나지 않는다"고 말하는지(C24 S5 표본), 실제 사람 배포 순서 준수(할 일 1이 맡음).

## 결과

- 봇 PR #124(`feat/colleague-c11-chat-v2-switchover`, 결과 head `de20e41`), 병합 `860b591`(2026-11-10). 스위치와 무관하게 병합과 함께 운영 대화 답 모양이 바뀐다(라벨 목록 → `reply` 문장, 짧은 인사는 👍).
- 구현: `src/runtime.ts` 대화 성공 분기(v2 요청 조립, surface = `store.colleague`, `ChatReplySchema`, ack_only·공개 검사·일반 답 세 갈래, proposal은 버림 → C13), `src/chat-format.ts`(`chatReplyContent`·`EMPTY_REPLY_NOTICE`·`WITHHELD_REPLY_NOTICE`·`ACK_ONLY_NOTICE`·`chatReplyRisk`), `src/worker.ts` `workerRequest` v2만·`WorkerClient` v2(칸 순서 그대로), `src/chat-context.ts` 50개·80KiB와 `earlierPurged()`, `src/store.ts` `finish()`의 ack_only(반응 행 있으면 👍, 없으면 고정 완료 글 "알겠어요." — Codex P2 반영), `complete(superseded)`의 반응 정리(할 일 8a), `src/reactions.ts` 표에 `acked: ['👍']`, `src/chat-lane.ts` v2 프롬프트에 `replied_bot_post` 설명(할 일 8b, 작업자 재배포 때 효과).
- 완료 조건 근거: `chat-format` 스위치 두 상태 라벨 없는 reply·공개 검사 고정 문구, `chat-ack` ack_only REST 순서(👀 PUT → 👍 PUT → 👀 DELETE)·outbox 0·`/chat` 명령은 고정 완료 글·실행 중 `/stop` 뒤 정리, `chat-context` 50개·80KiB·정리 표시, `foundation` v2 서버 + v1 작업자 `worker_rejected`, `s16-display` 프롬프트.
- 검사: 작업자 관련 42개 파일 1,201개 중 실패 0(+PG 122/122), 수정 뒤 관련 132/132. 통합 담당 전체 검사(`de20e41`, node 24.22.0, 실제 PG, 잠금): 2331 / 2309 pass / 0 fail / 22 skip. Codex 1차 P2 1 수정 뒤 지적 없음, `build / test` 통과.
- 운영 영향: 대화 답에도 `scanPublicText` metadata 패턴(17~20자리 숫자, 이메일, `/home/` 경로, 사설 IP)이 걸려 그런 답은 고정 문구로 바뀐다(명세대로). 롤백은 게시 서버 이미지만.
- 분해 불일치: 👍 순서는 C04 동기화 훅이 정해 "👀 지우고 👍" 대신 👍 PUT → 👀 DELETE. `src/reactions.ts`(C04) 표에 이름만 더함. 소유 밖 시험 8개 파일·`test/helpers.ts`의 v1 기대를 v2로.
- 운영 확인(2026-11-10 13:0x, 작업용 Mac의 Discord): 질문 → 메시지 스레드, 20초 안에 라벨 없는 해요체 한 문단 답과 `ref:` 줄(스위치 꺼짐이라 '/read' 안내 포함). 스레드의 `고마워` → 👀 뒤 👍만, 글 없음.
- 뒤 티켓: C13은 proposal을 받고 감사 기록 여부를 정함, C19는 `rateLimit`을 읽음. `DEFAULTS.contextMessages`(20)는 쓰는 곳이 없음(C02 소유, 정리 후보).
