# C17 게시 승인 버튼

- 단계: 4 말로 실행
- 상태: 대기 (선행: C13. 외부 선행 homelab T33(봇 PR #108)은 2026-11-09 병합·배포로 충족)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.3 "게시 승인", §4.9, §5 AC-10 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C13, homelab T33(외부 선행, 봇 PR #108: A05 승인 digest 페이지)
- 연결 AC: AC-10
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 봇 `src/change-runtime.ts`: 소유(연결 파일. 뒤에 C18이 변경 알림 문구를 고친다). 자리: 미리보기 글(`preview`)과 그 게시(`notifyPhase`의 `awaiting_publish_approval` 줄, `send`).
  - 봇 `src/change-commands.ts`: 게시 승인 경로(`publish`)를 버튼에서도 부를 수 있게 하는 자리. 연결 표에 없는 공유 파일이다(C18이 문구를, C14가 변경 요청·취소 연결에서 같은 파일을 쓴다. README 5절에 반영).
  - 봇 `src/discord.ts`, `src/discord-protocol.ts`: 연결 파일, 소유 C04. 이 티켓은 게시 버튼 줄(C13이 만든 custom_id 허용 목록 표에 한 줄)과 버튼 수신 분기만 고친다.
  - 봇 `src/store.ts`(outbox 게시 payload에 버튼을 싣는 자리): 연결 파일, 소유 C04. 버튼을 실은 글의 outbox 모양은 C13이 만든 것을 쓰기만 한다.
  - 봇 `migrations/`: 버튼과 승인 대상(변경 ID·generation·digest)을 묶는 행이 필요하면 순번 공유로 하나 더한다.
  - 봇 시험: `test/change-assembly.test.ts`, `test/change-pg.test.ts` 등 미리보기·승인 시험의 해당 줄.
- 설계 계약:
  - `src/change-runtime.ts`, `src/change-commands.ts`: 봇 ARCHITECTURE "16. T19 CHANGE_PR 계약"의 상태 전이 표(`awaiting_publish_approval`, `prepareApproval`)와 digest 문단, "16.5 조립과 꺼짐 배포 (B5)"의 `/change-publish` 행 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). 봇 DECISIONS "D-24 봇 변경 PR 작성 신원"의 "T19 세부 결정"·"T19 운영 결정" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - `src/discord.ts`, `src/discord-protocol.ts`: 봇 ARCHITECTURE "6. 보안 경계"의 Discord 입력 문단(버튼은 누른 사람 ID 대조), "14. 운영 세부"의 "사용 계약 보충"(버튼 custom ID 허용 목록), "13. 개선안 v2 적용"의 "수신·진행 신호"(상호작용 응답).
  - `src/store.ts` outbox: 봇 ARCHITECTURE "11. T16a 확정 계약과 로컬 구현"의 "저장·권한·게시".
  - 결정: 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 2·9.

## 목표

owner가 변경 미리보기 글에 붙은 "게시해 주세요" 버튼 하나로, 본 미리보기 그대로 게시를 승인한다. 64자 digest를 옮겨 적지 않는다. 미리보기가 새로 나오면 옛 버튼은 듣지 않는다. digest를 입력하는 '/' 승인은 예비로 그대로 된다.

이 버튼은 동료 기능 스위치(C01)가 켜졌을 때만 붙는다. 스위치가 꺼져 있으면 미리보기 글과 승인 경로가 지금과 같으므로, 병합하면 바로 적용되는 동작 변화는 없다.

## 할 일

1. homelab T33(봇 PR #108)이 병합된 main 위에서 시작한다. 미리보기 글은 outbox에서 1,800자 페이지로 나뉘므로(`messagePages`, T33 뒤에는 1,800자 안의 마지막 줄바꿈에서 자른다) 버튼은 미리보기의 마지막 페이지에 단다. 버튼이 실린 페이지가 미리보기 전체에 묶인 digest를 가리키는지 시험으로 고정한다.
2. 스위치가 켜져 있으면 `awaiting_publish_approval` 미리보기 글(`src/change-runtime.ts`)에 그 generation의 승인 digest에 묶인 버튼을 단다. 미리보기 글은 owner 호출 대상이다(호출 자체는 C07이 만든다). 스위치가 꺼져 있으면 지금 글 그대로다.
3. 버튼을 그 digest에 묶는다. Discord custom_id는 100자 상한이라(구현 때 Discord 문서로 재확인) 변경 ID(최대 32자)와 digest(64자)를 그대로 다 담지 못할 수 있다. 담지 못하면 묶음 행(변경 ID, generation, digest, 만든 시각)을 저장하고 custom_id에는 그 행의 짧은 ID만 넣는다. 저장이 필요하면 마이그레이션을 더한다(순번 공유, 병합 때 다음 번호).
4. C13이 만든 custom_id 허용 목록 표에 게시 버튼 한 줄을 더하고, 버튼 수신 분기를 `src/discord.ts`에 더한다. 지금 버튼 분기는 `kind: 'command'`인 변경 명령만 변경 처리기로 보내므로(`isChange`), 게시 버튼도 같은 처리기(`ChangeCommands.publish`)로 가게 한다.
5. 버튼을 누르면 digest를 직접 입력한 승인과 같은 경로를 탄다: 누른 사람 = 변경 owner, 지금 generation이 `awaiting_publish_approval`, digest 일치, `writerAccepted` 확인, 이벤트 멱등(`duplicate_event`), 게시 직전 live 재확인(기존 publisher). 새 미리보기(새 generation이나 무효화) 뒤의 옛 버튼은 digest·generation 불일치로 거부하고 아무것도 바꾸지 않는다.
6. 처리한 뒤 버튼을 없앤다(C13의 메시지 갱신 응답 방식). 거부·만료는 누른 owner에게만 보이는 응답으로 알린다. 응답 문구는 C18이 다듬으므로 여기서는 동료 말투로 짧게 두고 상수로 둔다.
7. digest 입력 '/' 승인(`/change-publish`)은 그대로 둔다. 스위치가 켜져도 등록과 동작이 같다(안내만 C18이 바꾼다).
8. 기록: 봇 `docs/ai-bot/VERIFICATION.md`에 "C17 게시 승인 버튼" 절, `docs/ai-bot/DECISIONS.md`에 custom_id 묶음 방식(3번)을 정한 문단을 더한다. 이 계획 폴더 `README.md`의 C17 상태 줄을 갱신한다.

## 완료 조건

- [ ] 스위치가 켜져 있으면 변경 미리보기 글(마지막 페이지)에 그 미리보기 digest에 묶인 게시 버튼이 붙고, 꺼져 있으면 붙지 않는다.
- [ ] 버튼을 누르면 그 digest로 승인되고 승인 기록이 남으며, 게시는 기존 경로대로 게시 직전 재확인을 거친다.
- [ ] 새 미리보기가 나온 뒤 옛 버튼은 거부되고 상태가 바뀌지 않는다.
- [ ] owner가 아닌 사람이 누르면 거부된다. 같은 버튼을 두 번 눌러도 승인은 한 번이다.
- [ ] digest 입력 '/' 승인이 계속 된다.

## 검증

- 경계: S1(변경 승인 경로, PGlite. 상호작용은 가짜 Discord). 앞선 예: `change-assembly`, `change-pg`, `change-freshness`, `foundation` 시험.
- 명령: 봇 `npm run check`, `npm test`(작업자 완료 검사는 바뀐 파일 관련 시험만, 전체는 통합 담당 C24).
- 잡는 실패: 다른 미리보기의 게시, 옛 버튼 수용, 승인 기록 누락, 비 owner 승인, 중복 승인, 스위치 무시. 못 잡는 범위: GitHub 실제 게시(기존 T19 경로와 S5, C24), Discord 클라이언트의 실제 버튼 표시(S5).

## 결과

(구현 뒤 채운다)
