# C18 고정 문구 3: 변경·리뷰 알림·경보·세션 연결

- 단계: 4 말로 실행
- 상태: 대기 (선행: C01, C12, C15, C17)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.4 "고정 문구", §4.9, §5 AC-11·AC-23 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C01, C12, C15, C17
- 연결 AC: AC-11(일부: 변경·리뷰 알림·경보·세션 연결 문구), AC-23(문구 두 판)
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 봇 `src/change-commands.ts`: 변경 명령 응답 문구. 연결 표에 없는 공유 파일이다(C17이 게시 승인 경로를, C14가 변경 요청·취소 연결을 고친다. README 5절에 반영). 이 티켓은 문구만 고친다.
  - 봇 `src/change-runtime.ts`: 연결 파일, 소유 C17. 이 티켓은 변경 알림 문구 자리(`notifyPhase`, `preview`의 안내 줄, 배포 알림)만 고친다.
  - 봇 `src/change-deployment.ts`: 배포 관측 알림 문구(`describeDeployment` 등). 소유(다른 티켓이 고치지 않음).
  - 봇 `src/change-advice.ts`: 변경 실패 안내 꼬리(`CHANGE_RESTART`, `changeNextGeneration`, `changeChildFailed`). 소유. 연결 표에 없고 `src/store.ts`(소유 C04)도 이 상수를 가져다 쓴다. C09는 이 파일을 고치지 않는다는 전제다(README 5절에 반영).
  - 봇 `src/review.ts`: 연결 파일, 소유 C12. 이 티켓은 Discord 리뷰 안내 문구 자리(미게시 안내 `review-unpublished`, Discord 요약 `review-summary`, 리뷰 상태 안내)만 고친다. GitHub 리뷰 렌더러는 C12, 리뷰 대기(한도·인증) 안내는 C20 몫이다.
  - 봇 `src/alerts.ts`: 경보 중계 문구. 소유.
  - 봇 `src/external-task-commands.ts`: 연결 파일, 소유 C15. 이 티켓은 세션 연결 명령 응답 문구만 고친다.
  - 봇 `src/external-task-links.ts`, `src/external-task-receiver.ts`: 세션 연결 목록·R08 턴 완료 알림 문구. 소유.
  - 봇 `src/chat-lane.ts` `CHAT_REPLY_JSON_SCHEMA`(소유 C02): 할 일 3a의 `content` 설명 자리만.
  - 봇 시험: 위 문구를 리터럴로 비교하는 시험(`test/change-assembly.test.ts`, `test/change-pg.test.ts`, `test/change-recovery.test.ts`, `test/change-freshness.test.ts`, `test/change-review.test.ts`, `test/change-deployment.test.ts`, `test/external-task-*.test.ts`, `test/review-2.test.ts`, `test/publisher-main.test.ts` 등 해당 줄).
- 설계 계약:
  - 변경 알림(`src/change-commands.ts`, `src/change-runtime.ts`, `src/change-deployment.ts`, `src/change-advice.ts`): 봇 ARCHITECTURE "16. T19 CHANGE_PR 계약", "16.1 배포 읽기 (B4)", "16.5 조립과 꺼짐 배포 (B5)"의 명령 표 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). 미리보기에 리뷰 자유문·시험 로그·요청 원문을 싣지 않는 규칙은 `preview` 머리 주석과 "16.3 T19 B3 writer·공개 경계".
  - Discord 리뷰 안내(`src/review.ts`): 봇 DECISIONS "D-16 PR 리뷰 방식", "T17 결정 (사용자 2026-11-04)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md). 리뷰 요약에 모델 문장을 넣지 않는 규칙은 `review.ts` Discord 요약 자리 주석.
  - 경보 중계(`src/alerts.ts`): 봇 ARCHITECTURE "11. T16a 확정 계약과 로컬 구현"의 "저장·권한·게시"(경보 원문 비게시)와 "8. 봇 중단 경보 연결".
  - 세션 연결(`src/external-task-*.ts`): 봇 ARCHITECTURE "15. R08 읽기 전용 알림 (2026-11-05)", 봇 DECISIONS "R08 명시적 Codex 연결 (결정 ID 없음)".
  - 문구 원칙: 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 4·9, 저장소 루트 `GLOSSARY.md`의 동료 말투·고정 문구.

## 목표

변경 요청·미리보기·게시·배포 알림, Discord에 나가는 PR 리뷰 안내, 경보 중계, 세션 연결 명령과 R08 턴 완료 알림이 동료 말투로 나온다. '/' 명령 이름을 안내하는 줄은 스위치가 꺼지면 지금처럼 '/'를, 켜지면 말로 하는 안내를 보인다. 경보 원문 비게시, 리뷰 요약에 모델 문장 없음 같은 안전 규칙은 그대로다.

'/' 안내가 없는 문구의 말투 변화는 스위치 밖이라 병합하면 바로 운영에 나간다. '/' 안내 줄의 새 판은 스위치를 켤 때만 나간다.

## 할 일

1. 위 파일들의 Discord 고정 문구를 모아 동료 말투(해요체, 결론부터, 자기를 "봇"이라 부르지 않음)로 다시 쓴다. 문구는 상수로 모아 시험이 상수를 참조하게 한다(명세 6절). 단, 사람이 다듬는다는 결정(명세 4.4)에 맞춰 PR 설명에 바뀐 문구 표를 붙여 owner가 검토하게 한다.
2. '/' 명령 이름이 들어간 줄(예: `/change-publish`, `/change-status`, `/change project:… text:next`, `/review-resume`, `/attach`, `/resume`)은 스위치(C01)에 따라 두 판을 둔다. 켜짐 판에는 '/' 이름이 없고 말로 하는 안내다(예: "게시하려면 위 버튼을 눌러 주세요", "다시 하려면 이 스레드에서 말해 주세요"). 미리보기 글의 켜짐 판은 C17 버튼을 가리킨다.
3. 안전 규칙을 지킨다: 경보 중계는 원문을 싣지 않는다. Discord 리뷰 요약은 코드가 만든 숫자·리비전만 싣는다. 미리보기에 리뷰 자유문·시험 로그·요청 원문을 싣지 않는다. 세션 연결 키는 공개 글에 없다(C15). R08 알림의 사용자 값은 코드 스팬에 둔다.
3a. C15 넘김(2026-11-10): 대화 출력 스키마 `CHAT_REPLY_JSON_SCHEMA`의 `content` 설명이 세션 연결(`attach`) 제안의 꼴(`claude`·`codex`, 동의하면 뒤에 `summary=on`)을 말하지 않아, 모델이 `content`를 null로 내면 제안이 `target_denied`로 버려진다. 설명에 그 꼴을 더한다. 스키마 문자열이 작업자 계약 digest나 작업자 쪽 대조에 들어가는지 먼저 코드로 확인하고, 들어가면 작업자 이미지 교체(C23 sandbox PR)와 순서를 맞춘다.
3b. C30 넘김(봇 #132 Codex 2차 P2, 2026-11-10): 대화 신뢰 문맥 `src/bot-facts.ts`의 `SPEECH_ACTIONS`("할 수 있는 일은 아래뿐")에 PR 리뷰 요청이 없어, 출력 enum에 `review_request`가 있어도 모델이 리뷰 부탁을 못 하는 일로 거절할 수 있다. 목록에 PR 리뷰 요청(확인 없이 바로 시작, 대상은 PR 링크 또는 `owner/repo#번호`)을 더하고, `chat-lane.ts`의 `target` 설명에도 그 꼴을 적는다. 실제 `chatPrompt()`에 그 안내가 들어가는지 시험한다. 작업자 이미지 교체와 순서는 3a와 같다.
3c. C30 넘김(같은 리뷰): 리뷰 요청은 읽기 처리기 경로라 `ProposalDesk.consider()`의 처음 `current()` 검사만 거친다. GitHub 조회(설치·저장소·PR·merge base) 동안 owner가 같은 대화에서 요청을 고치거나 거두면 옛 요청의 리뷰 작업이 그대로 생긴다. GitHub 조회가 끝난 뒤 대화 행을 잠그고 최신성을 다시 본 다음 같은 트랜잭션에서 리뷰를 접수한다(`src/review.ts` `ReviewRequests`, `src/proposals.ts`의 리뷰 요청 줄). 스위치 뒤 경로라 C24 스위치 켜기 전에 끝낸다.
3d. C28 넘김(봇 #133 Codex 3차 P2, 2026-11-10): 변경 질문의 "직접 답하기" 버튼(`src/change-question.ts` `pressChangeQuestion`)이 질문 기한과 답 대기 상태를 보지 않는다. 기한이 지났지만 만료 정리 전이라 `state='open'`인 질문에서 누르면 "다음 말이 답"이라고 안내하지만, `openTaskQuestions()`는 기한 전 질문만 돌려줘 그 말이 봉인 없이 일반 대화 작업으로 들어간다. 다음 답 대상을 적기 전에 선택지 버튼과 같은 검사(기한 전, 답 대기)를 하고, 지났으면 기한이 지났다는 고정 글로 답한다. 스위치 뒤 경로라 C24 스위치 켜기 전에 끝낸다.
4. 손대지 않는 자리를 지킨다: 리뷰 대기(한도·인증) 안내(`src/review.ts`의 `review-waiting`, `src/change-assembly.ts`의 변경 리뷰 대기 안내)는 C20이 자리 비움으로 바꾸므로 여기서 고치지 않는다. GitHub 리뷰 본문 렌더러는 C12 몫이다.
5. 리터럴 비교 시험을 고치고, "스위치 켜짐 판의 이 파일들 문구에 '/' 명령 이름 0" 시험과 "꺼짐 판은 지금 '/' 안내 유지" 시험을 더한다. '/' 이름 목록은 등록 명령 표(`src/commands.ts`의 정의)에서 읽어 비교한다.
6. 기록: 봇 `docs/ai-bot/VERIFICATION.md`에 "C18 고정 문구 3" 절, `docs/ai-bot/DECISIONS.md`에 문구를 둔 자리와 두 판 규칙 문단을 더한다. 이 계획 폴더 `README.md`의 C18 상태 줄을 갱신한다.

## 완료 조건

- [ ] 변경·Discord 리뷰 안내·경보·세션 연결 고정 문구가 해요체다.
- [ ] 스위치가 켜지면 이 문구들 어디에도 '/' 명령 이름이 없고, 꺼지면 지금처럼 '/'를 안내한다.
- [ ] 경보 원문은 게시되지 않고, Discord 리뷰 요약에 모델 문장이 없으며, 공개 글에 세션 연결 키가 없다.
- [ ] 바뀐 문구의 리터럴 시험이 상수 참조로 통과한다.

## 검증

- 경계: S1(문구 표 단위 시험과 '/' 이름 검사 시험, 스위치 두 상태). 앞선 예: `change-assembly`, `external-task-assembly`, `publisher-review`, `pr-review` 시험.
- 명령: 봇 `npm run check`, `npm test`(작업자 완료 검사는 바뀐 파일 관련 시험만, 전체는 통합 담당 C24).
- 잡는 실패: 새로 쓴 문구의 '/' 이름 잔존, 스위치 분기 누락, 경보 원문·모델 문장의 Discord 유출 회귀. 못 잡는 범위: 문구의 자연스러움(owner 검토, C24 말투 표본).

## 결과

(구현 뒤 채운다)
