# C15 세션 연결 키 버튼

- 단계: 4 말로 실행
- 상태: 대기 (선행: C13)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.3 "세션 연결 키", §4.9 스위치와 배포 순서 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C13
- 연결 AC: AC-9
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 소유(연결 파일, 뒤에 C18이 세션 연결 문구를 고침): 봇 `src/external-task-commands.ts`(세션 연결 확정·키 전달·전달 실패 폐기·두 번 보기 거부)
  - 쓰기만 함: 봇 `src/external-task-links.ts`(`OneTimeSeed`·`attach`·`revoke`를 그대로 씀. 바꿔야 하면 README 5절에 반영)
  - 연결 파일, 소유 C13: 봇 제안 모듈(세션 연결 동작 줄)
  - 연결 파일, 소유 C04: 봇 `src/discord-protocol.ts`(custom_id 표에 "키 보기" 줄), `src/discord.ts`("키 보기" 상호작용 분기와 본인만 보이는 응답 전달 `deliverPrivate` 사용)
  - 시험: `test/external-task-assembly.test.ts`, `test/external-task-helper.test.ts`, `test/external-task-pg.test.ts`의 연결 경로와 새 버튼 경로
- 설계 계약:
  - `src/external-task-commands.ts`, `src/external-task-links.ts`: 봇 ARCHITECTURE §15 "R08 읽기 전용 알림 (2026-11-05)"의 "seed 경계"(평문은 한 곳, 본인만 보이는 응답으로만, 전달 실패면 폐기, 다시 보내지 않음, 남는 틈), "수명"(`OneTimeSeed` 한 번만 공개), "저장"(개인 seed 열 없음), "켜는 순서"(R08 스위치) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md)
  - 버튼·상호작용: 봇 ARCHITECTURE §11 "REVIEW-8: 마감 기준점·owner 재개·확정된 원격 응답"(상호작용 마감 진입 + 2500ms), §11 "저장·권한·게시"(상호작용 응답 전 철회 확인), C13이 더하는 제안·실행 확인 계약 절
  - 결정: 봇 DECISIONS "R08 명시적 Codex 연결 (결정 ID 없음)", "동료 봇 전환 (사용자 2026-11-09)" 2 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md)

## 목표

스위치가 켜져 있을 때 owner가 말로 세션 연결을 요청하고 실행 확인으로 확정하면 "키 보기" 버튼이 붙는다. 그 버튼을 누른 owner에게만 보이는 응답으로 키가 한 번 나오고, 스레드 공개 글과 이벤트 원문에는 키가 없다. 응답에 실패하면 지금처럼 그 연결을 폐기하고, 두 번째 누름은 거부된다. 병합해도 스위치가 꺼져 있으면 '/' `attach` 경로 그대로다.

## 할 일

1. 세션 연결(`attach`) 동작 줄을 C13 동작 표에 더한다. 대상은 외부 세션 ID와 실행기(`claude`·`codex`), 요약 동의이고, 확인 글에 그대로 보인다. R08 스위치가 꺼져 있으면 제안을 버린다.
2. 키를 언제 만드는지 정한다. 지금 seed는 DB·outbox·감사·로그 어디에도 남지 않고 상호작용 응답 한 번으로만 나간다. 그래서 "할게요"에서는 연결 대상만 확정하고, "키 보기" 상호작용 안에서 연결을 만들고 그 응답으로 키를 보내는 방식을 먼저 검토한다(키를 상호작용 사이에 보관하지 않음). 다른 방식을 고르면 seed가 영속 저장소에 남지 않음을 증명하는 시험과 이유를 ARCHITECTURE에 적는다.
3. "키 보기" 버튼 검사: 누른 사람이 owner, 같은 제안, 아직 보지 않음. 두 번째 누름은 거부하고 이미 보여 줬다고만 답한다(키를 다시 만들거나 보여 주지 않음).
4. 전달 실패(상호작용 만료, 전송 실패, 일시 정지, 권한 변경)면 기존 규칙대로 그 연결을 폐기하고 고정 안내만 남긴다. 폐기까지 실패하면 기존 안내와 감사를 그대로 쓴다.
5. 버튼이 달린 확인 글, 처리 뒤 갱신된 글, 감사·로그에 seed가 없는지 시험한다(기존 seed 노출 검사 방식).
6. 기록: 봇 `docs/ai-bot/ARCHITECTURE.md` §15 "seed 경계"에 버튼 경로 문단, `docs/ai-bot/VERIFICATION.md`에 "C15 세션 연결 키 버튼" 절, 이 계획 폴더 `README.md`의 C15 상태 줄 갱신.

## 완료 조건

- [ ] 세션 연결 확정 뒤 "키 보기"를 누른 owner에게만 보이는 응답으로 키가 한 번 나온다.
- [ ] 스레드 공개 글, 이벤트 원문, outbox, 감사·로그에 키가 없다.
- [ ] 응답 실패면 키가 폐기되고, 두 번째 누름은 거부된다.
- [ ] 스위치가 꺼져 있으면 버튼이 없고 '/' `attach`가 지금처럼 동작한다.

## 검증

- 경계: S1(PGlite, 가짜 Discord REST). 앞선 시험 예: `external-task-assembly`, `external-task-pg`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 `npm test` 대상(전체는 C24 통합).
- 잡는 실패: 공개 글에 키 노출, 두 번 보기, 실패 시 키 잔존, 비 owner의 키 보기. 못 잡는 범위: Discord 클라이언트의 실제 본인만 보이는 표시(C24 S5).

## 결과

(구현 뒤 채운다)
