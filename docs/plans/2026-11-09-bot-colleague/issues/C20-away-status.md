# C20 자리 비움

- 단계: 5 멈춤과 계정
- 상태: 대기 (선행: C04, C09, C12, C19, C21)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.5 "모델 멈춤 중"·"자리 비움", §4.7 "지금 안내문 교체", §5 AC-14·AC-15 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C04, C09, C12, C19, C21
- 연결 AC: AC-15, AC-14(💤)
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 봇 `src/gateway.ts`: Gateway 상태(presence) 보내기와 재연결 때 복원. 소유(연결 표에 없고 다른 티켓이 고치지 않는다).
  - 봇 `src/discord.ts`, `src/discord-protocol.ts`: 연결 파일, 소유 C04. 이 티켓은 C04의 반응 훅에 💤 상태를 더하는 자리만 고친다.
  - 봇 `src/store.ts`: 연결 파일, 소유 C04. 대화 레인 한도·인증 대기 안내(`waitForUser`의 `waiting:<job>:<attempt>` 글)를 자리 비움으로 바꾸는 자리만.
  - 봇 `src/claude-task-bridge.ts`, `src/codex.ts`: 연결 파일, 소유 C09. 작업 레인 한도·인증 대기 안내 자리만.
  - 봇 `src/review.ts`: 연결 파일, 소유 C12. 리뷰 대기 안내(`review-waiting`) 자리만.
  - 봇 `src/change-assembly.ts`: 변경 리뷰 자식의 한도·인증 대기 안내. 연결 표에 없는 파일이다(README 5절에 반영). 이 안내 한 자리만 고친다.
  - 봇 `src/runtime.ts`, `src/main.ts`: 멈춤 시작·해제를 Gateway 상태와 반응으로 잇는 배선. 연결 표에 없는 공유 파일이다(C11·C19·C21과 겹친다. README 5절에 반영).
  - 봇 시험: 가짜 Gateway(`test/fake-gateway.ts`)를 쓰는 상태 시험(새 파일), `test/chat-ack.test.ts`, `test/status-notice*.test.ts`, `test/task-lane-pg.test.ts`, `test/review-*.test.ts`, `test/change-assembly.test.ts`의 해당 줄.
- 설계 계약:
  - `src/gateway.ts`: 봇 ARCHITECTURE "3. 도구·런타임"의 Discord intents 행과 "8. 봇 중단 경보 연결"(Gateway를 readiness에 묶지 않음) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). Gateway 상태(presence) 계약은 없음(확인한 곳: ARCHITECTURE 절 목록, `src/gateway.ts`의 identify payload에 상태 칸 없음. 미확인). 이 티켓이 ARCHITECTURE에 절을 더한다.
  - `src/discord.ts`, `src/discord-protocol.ts`: 봇 ARCHITECTURE "13. 개선안 v2 적용"의 "수신·진행 신호"(👀, 403/404 대체 텍스트, 상호작용은 ephemeral)와 C04가 더한 반응 수명 절.
  - 대기 안내(`src/store.ts`, `src/claude-task-bridge.ts`, `src/codex.ts`, `src/review.ts`, `src/change-assembly.ts`): 봇 ARCHITECTURE "13"의 "상태 안내 (멘션 없음)"(멱등 키 표), "12"의 "T18 게시 서버 스케줄링과 질문 (2026-11-05)", 봇 DECISIONS "T17 결정 (사용자 2026-11-04)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - 결정: 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 5·7, 저장소 루트 `GLOSSARY.md`의 자리 비움·모델 멈춤.

## 목표

모델 멈춤 동안 Discord에서는 봇이 잠깐 자리를 비운 것으로만 보인다. 봇 상태가 자리 비움(idle)이 되고, 기다리는 메시지의 👀·⏳가 💤로 바뀌며, 멈춘 동안 스레드마다 처음 부를 때 한 번 "지금은 잠깐 자리를 비웠어요. 돌아오면 이어서 할게요."라고 답한다. 원인과 시각은 Discord에 적지 않는다(원인은 C21 운영 알림). 풀리면 온라인으로 돌아가고 답한 뒤 💤를 지운다.

자리 비움은 스위치 밖이라 병합하면 바로 운영에 나간다. 이 병합부터 한도·인증 대기 때 Discord에 원인과 '/' 재개 명령이 더는 나가지 않는다. C21(운영 알림)을 선행으로 두어, 그때는 이미 원인이 Telegram으로 간다.

## 할 일

1. Gateway 상태를 보낸다(`src/gateway.ts`). 멈춤 시작이면 자리 비움(idle), 풀리면 온라인. 지금은 상태를 전혀 보내지 않는다(코드 검색, 미확인). 재연결(새 identify, RESUME) 뒤에는 그때의 멈춤 기록(C19)을 다시 읽어 상태를 복원한다. 상태 보내기 형식과 rate limit은 구현 때 Discord Gateway 문서로 확인한다.
2. 멈춤 시작·해제 신호는 C19의 멈춤 기록에서 읽는다. 비상 정지는 모델 멈춤이 아니므로 자리 비움으로 바꾸지 않는다(용어집). 어떻게 보일지는 지금 동작 그대로 둔다.
3. 반응: C04의 반응 훅에 💤를 더한다. 멈춤이 시작되면 이미 기다리던 메시지까지 👀·⏳를 💤로 바꾸고, 멈춘 동안 새로 받은 메시지에도 💤를 단다. 답을 게시하면(재개 뒤) 💤를 지운다. 봇 자신의 반응만 지운다. 403/404 대체 텍스트 규칙은 C04 그대로다.
4. 자리 비움 한 줄: 멈춘 동안 스레드마다 처음 부를 때 한 번만 단다. 같은 멈춤 동안 같은 스레드에는 다시 달지 않고, 새 멈춤이 시작되면 다시 한 번 단다. 중복 방지는 outbox 멱등 키(스레드와 멈춤 회차)처럼 기존 장치로 하고, 새 저장이 필요하면 마이그레이션(순번 공유)을 더한다. 문구는 고정 문구 상수로 둔다.
5. 지금의 한도·인증 대기 Discord 안내를 원인 없는 자리 비움으로 바꾼다: 대화(`src/store.ts` `waitForUser`), 작업 레인(`src/claude-task-bridge.ts`, `src/codex.ts`), PR 리뷰(`src/review.ts` `review-waiting`), 변경 리뷰 자식(`src/change-assembly.ts`). 이 글들에서 원인(한도·인증), 시각, '/' 재개 명령을 뺀다. 결제 멈춤도 Discord에서는 같은 자리 비움이다.
6. 입력 중 표시는 그대로 둔다(명세 4.5).
7. 시험: 가짜 Gateway로 멈춤 시작 → idle, 해제 → online, 재연결 뒤 복원. 가짜 Discord REST로 👀·⏳ → 💤 → 답 뒤 지움 순서, 남의 반응을 지우지 않음. 같은 스레드 반복 안내 0, 안내 글에 원인·시각·'/' 이름 없음(리터럴 검사).
8. 기록: 봇 `docs/ai-bot/VERIFICATION.md`에 "C20 자리 비움" 절, `docs/ai-bot/ARCHITECTURE.md`에 Gateway 상태 절과 "상태 안내" 표 갱신, `docs/ai-bot/DECISIONS.md`에 자리 비움 구현 위치 한 줄을 더한다. 이 계획 폴더 `README.md`의 C20 상태 줄을 갱신한다.

## 완료 조건

- [ ] 모델 멈춤이 시작되면 Gateway 상태가 자리 비움이 되고, 풀리면 온라인이 된다. 재연결 뒤에도 그때 상태로 돌아온다.
- [ ] 멈춤 중 기다리는 메시지에는 💤가 달리고 답한 뒤 지워진다. 남의 반응은 지우지 않는다.
- [ ] 멈춘 동안 스레드마다 처음 부를 때 한 번 자리 비움 문장이 달리고, 그 문장과 대기 안내 어디에도 원인·시각·'/' 재개 명령이 없다.

## 검증

- 경계: S1(가짜 Gateway와 저장소, 가짜 Discord REST의 반응 호출 순서). 앞선 예: `publisher-gateway`, `chat-ack`, `status-notice`, `foundation` 시험.
- 명령: 봇 `npm run check`, `npm test`(작업자 완료 검사는 바뀐 파일 관련 시험만, 전체는 통합 담당 C24).
- 잡는 실패: 상태 미전환, 재연결 뒤 상태 유실, 같은 스레드 반복 안내, 원인 노출, 💤 잔존·남의 반응 삭제. 못 잡는 범위: 실제 Discord 클라이언트 표시와 반응 rate limit 영향(S5, C24).

## 결과

(구현 뒤 채운다)
