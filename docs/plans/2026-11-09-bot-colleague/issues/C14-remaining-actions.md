# C14 나머지 동작 연결

- 단계: 4 말로 실행
- 상태: integrated (봇 #130 병합 `4e6d423`, 2026-11-10)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.3 제안과 실행 확인(동작 목록, 제안 값의 출처, "리뷰 제어 장소", "변경 요청 확인 문구", 기억 원문), §5 AC-26 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C13
- 연결 AC: AC-6, AC-7, AC-26
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 연결 파일, 소유 C13: 봇 제안 모듈(C13이 만든 동작 표에 읽기 요청 6줄(작업 목록은 C13)과 실행 요청 줄을 더하고 각 동작의 허용 대상 대조를 채움)
  - 연결 파일, 소유 C04: 봇 `src/discord.ts`(확인 버튼 실행을 기존 처리기 분기, 즉 제어·작업 취소·기억·세션 연결·변경 명령 분기로 넘기는 자리)
  - 연결 파일, `src/store.ts`는 소유 C04·`src/task-bridge.ts`는 소유 C09: 봇 `src/store.ts`의 `control`(취소·재시도·리뷰 재개·취소)과 `src/task-bridge.ts`의 작업 취소를 부르기만
  - 쓰기만 함(처리기를 고치지 않고 부름): 봇 `src/memory-commands.ts`·`src/memory.ts`(기억 검색·저장·정정·제외·삭제), `src/change-commands.ts`(변경 요청·취소·상태), `src/external-task-commands.ts`(세션 연결 해제·목록, 파일 소유는 C15), `src/task-commands.ts`(작업 상태), `src/read.ts`·`src/catalog.ts`(읽기 템플릿)
  - 순번 공유: 봇 `migrations/`는 C13 표에 칸이 더 필요할 때만 다음 번호
  - 시험: C13 제안 시험에 동작별 줄을 더하고, 기존 처리기 시험(`memory-commands`, `change-assembly`, `external-task-assembly`, `read-lane`, `review-9`)과 같은 권한 결과를 내는지 비교
- 설계 계약:
  - 동작 표·허용 대상: C13이 봇 ARCHITECTURE에 더하는 제안·실행 확인 계약 절, 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 2·11 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md)
  - 기억 동작: 봇 DECISIONS "T20 기억·삭제 원장·브리핑 (로컬·mock, 2026-10-29)"의 "기억 명령 모양"·"기억 명령 처리"(출처, 응답 방식, 진술을 `events`에 넣지 않는 규칙)·"근거와 상태"
  - 변경 동작: 봇 ARCHITECTURE §16 "T19 CHANGE_PR 계약", §16.5 "조립과 꺼짐 배포 (B5)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md)
  - 세션 연결 해제·목록: 봇 ARCHITECTURE §15 "R08 읽기 전용 알림 (2026-11-05)"의 명령 표
  - 작업·리뷰 제어와 장소 규칙: 봇 ARCHITECTURE §12 "T18 작업 레인 조립"(명령 표), §13 "read 레인", 봇 `src/discord.ts` 수신 분기의 '/' 리뷰 제어 권한(알림 채널 부모의 owner만, '/' 예비에 그대로 남음). 말로 하는 리뷰 제어의 장소는 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 13(허용 채널과 그 아래 스레드에서 owner면 받음)
  - 변경 요청 확인 문구: 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 15("<저장소>에 이 변경 PR을 준비할까요?", 누르면 `label=public`로 접수, 공개 여부를 따로 묻지 않음), ARCHITECTURE §16.5 "조립과 꺼짐 배포 (B5)"의 `/change` 행(출처 label 규칙)
  - `src/discord.ts`: 봇 ARCHITECTURE §11 "저장·권한·게시"

## 목표

스위치가 켜져 있을 때 owner가 말로 하는 읽기 요청(작업·변경·리뷰 상태, 읽기 템플릿, 기억 검색, 세션 연결 목록)은 확인 없이 일반 답으로 받고, 실행 요청(작업 취소·재시도, 기억 저장·정정·제외·삭제, 세션 연결 해제, 변경 요청·취소, 리뷰 재개·취소)은 실행 확인을 거친다. 어느 동작이든 같은 '/' 명령과 같은 권한 검사를 지나므로 말로 해서 더 할 수 있는 일이 없다. 장소 규칙도 같고, 예외는 말로 하는 리뷰 재개·취소가 허용 채널 아래 스레드에서도 받아진다는 것 하나다. 말로 한 변경 요청은 "<저장소>에 이 변경 PR을 준비할까요?"로 되묻고 공개 여부는 묻지 않는다. 기억 저장·정정은 저장될 내용이 확인 글에 그대로 보이고 owner가 본 값만 저장된다. 병합해도 스위치가 꺼져 있으면 운영 동작은 그대로다.

## 할 일

1. 읽기 요청 줄: 작업 상태(`task-status`), 변경 상태(`change-status`), 리뷰 상태(`review-status`), 읽기 템플릿(`read`, 대상은 템플릿 카탈로그 대조), 기억 검색(`memory-search`), 세션 연결 목록(`attach-list`). 결과는 '/' 응답 대신 일반 답(동료 말투)으로 게시한다. 이벤트 원문 규칙(기억 검색어를 `events`에 넣지 않음)은 owner가 이미 말로 보낸 메시지에는 해당하지 않음을 DECISIONS에 적는다.
2. 실행 요청 줄: 작업 취소(`cancel`·`task-cancel`), 재시도(`retry`), 기억 저장·정정·제외·삭제, 세션 연결 해제(`detach`), 변경 요청·취소(`change`·`change-cancel`), 리뷰 재개·취소(`review-resume`·`review-cancel`). 대상(작업·변경·기억·연결 ID, 프로젝트)은 이 대화에서 볼 수 있는 것만 허용한다.
3. 값의 출처: 변경 요청 내용은 owner 원문(멘션 표기 제거)이고 모델은 대상과 동작만 고른다. 기억 저장·정정 내용은 모델이 골라낸 글이지만 확인 글에 그대로 보이고, 버튼을 누르면 그 글(digest 일치)만 저장된다. 기억의 출처는 owner가 말한 원 메시지 이벤트로 둔다(근거 판정이 "owner 대화"로 같게).
4. 변경 요청 확인 글: 말로 한 변경 요청의 실행 확인은 "<저장소>에 이 변경 PR을 준비할까요?"로 묻는다(저장소는 정책 대조를 지난 이름, 문구는 동료 말투 고정 문구 상수). 공개 여부를 묻는 글이나 버튼은 없다. "할게요"를 누르면 owner 원문을 지금 규칙의 공개 표시 `label=public`로 '/' `change`와 같은 접수 경로에 넘긴다. 접수 때의 공개 검사(`scanBrief`)와 출처 label 규칙은 그대로라 걸리면 지금처럼 막힌다. 실제 게시는 뒤의 게시 승인(C17) 때다. '/' `change` 예비 경로는 지금처럼 owner가 적은 `label`을 쓴다.
5. 장소 규칙과 권한은 '/' 처리기와 같다. 예외는 리뷰 제어 하나다(DECISIONS "동료 봇 전환" 13): 말로 하는 리뷰 재개·취소는 owner가 허용 채널(대화·알림)이나 그 아래 스레드 어디서 말해도 받는다. '/' `review-resume`·`review-cancel`의 "알림 채널 본문" 제한은 '/' 예비에만 남긴다. 허용 채널 밖이나 owner가 아니면 '/'와 같이 거부한다.
6. 기억 저장·정정 제안 값은 처리·거절·만료 뒤 비워지는지(C13 규칙) 시험으로 확인한다. 기억 삭제 응답의 7일 안내(C10)가 버튼 경로에도 나오는지 본다.
7. 시험: 동작마다 버튼 전 실행 0건, '/' 처리기와 같은 권한 결과(비 owner·다른 대화·허용 밖 대상 거부), 읽기 동작이 상태를 바꾸지 않음, 기억 저장 내용이 확인 글과 같음, 변경 요청 내용이 owner 원문과 같음, 변경 요청 확인 글이 "<저장소>에 이 변경 PR을 준비할까요?"이고 누르면 공개 표시 `public`로 접수(누르기 전 접수 0건, 공개 여부를 묻는 글 0), 말로 하는 리뷰 재개·취소가 대화 채널·알림 채널과 그 아래 스레드에서 owner면 받아지고 허용 채널 밖·비 owner는 거부, '/' 리뷰 제어는 지금처럼 알림 채널 본문에서만.
8. 기록: 봇 `docs/ai-bot/ARCHITECTURE.md`의 C13 계약 절에 동작 줄과 리뷰 제어 장소·변경 요청 확인 문구 추가, `docs/ai-bot/DECISIONS.md`에 값의 출처 판단, `docs/ai-bot/VERIFICATION.md`에 "C14 나머지 동작 연결" 절, 이 계획 폴더 `README.md`의 C14 상태 줄 갱신.

- C13에서 넘어옴(봇 PR #125 Codex 2차 P2, 댓글 4521043281): 실행 확인 글이 대화 답보다 먼저 게시될 수 있다. `Store.claimDelivery`는 같은 `message_key`의 쪽 사이에서만 선행 게시 완료를 보므로, 확인 글은 `result:<job>`의 모든 쪽이 `sent`가 된 뒤에만 집히도록 명시적 게시 의존(선행 키)을 둔다. 긴 답의 남은 쪽보다 버튼이 먼저 보이거나, 확인 뒤에야 모델 설명이 오는 일을 시험으로 막는다(`src/store.ts`는 C04 소유 연결 파일, 그 자리만).

## 완료 조건

- [x] 읽기 요청 여섯 동작(작업·변경·리뷰 상태, 읽기 템플릿, 기억 검색, 세션 연결 목록)이 확인 없이 실행되고 결과가 일반 답으로 달린다.
- [x] 실행 요청 동작은 버튼을 누르기 전 실행 0건이고, 누르면 같은 '/' 처리기 경로로 한 번 실행된다.
- [x] 각 동작의 권한·장소 검사 결과가 같은 '/' 명령과 같다.
- [x] 기억 저장·정정은 확인 글에 보인 내용만 저장되고, 변경 요청 내용은 owner 원문이다.
- [x] 말로 하는 리뷰 재개·취소는 허용 채널(대화·알림)과 그 아래 스레드에서 owner면 받고, '/' 리뷰 제어의 알림 채널 본문 제한은 '/' 예비에만 남는다.
- [x] 말로 한 변경 요청의 실행 확인 글이 "<저장소>에 이 변경 PR을 준비할까요?"이고, 누르면 공개 표시와 함께 접수된다. 누르기 전 접수는 0건이고 '/' 예비 경로의 공개 표시 규칙은 그대로다.

## 검증

- 경계: S1(PGlite, 가짜 Discord REST). 앞선 시험 예: `memory-commands`, `change-assembly`, `external-task-assembly`, `read-lane`, `review-9`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 `npm test` 대상(전체는 C24 통합).
- 잡는 실패: 읽기 요청이 다른 권한 경로를 타는 것, 읽기로 분류된 동작이 상태를 바꾸는 것, 확인 우회, 허용 밖 대상 실행, 확인 글과 저장 값의 불일치, 변경 요청이 공개 표시 없이 접수돼 막히는 것, 확인 전 접수, 리뷰 제어 장소 규칙이 '/' 경로까지 넓어지는 것. 못 잡는 범위: 모델이 읽기와 실행을 헷갈리는 비율과 요청 오독(C24 S5 표본).

## 결과

- 봇 PR #130(`feat/colleague-c14-remaining-actions`, head `e66a463`), 병합 `4e6d423`. 마이그레이션 없음.
- 구현: `src/proposals.ts` `ACTIONS`의 이 티켓 몫 18줄(C13이 키로 만들어 둔 줄이라 제자리에서 처리기를 닮)에 처리기, 읽기 건너뛰기(`ReadSkip`), 확인 글·읽기 결과의 `after` 칸, `pressProposal`의 `later`(버튼 트랜잭션 커밋 뒤 '/' 처리기 한 번). `src/discord.ts` 생성자의 `bindProposalHandlers`(처리기를 같은 `Store`에 묶음)와 `proposalButton`. `src/store.ts` `Delivery.payload.after`(선행 글이 `pending`·`sending`·`unknown`이면 `claimDelivery`가 집지 않음, C13 Codex 2차 P2 넘김분).
- 완료 조건 근거: 새 `test/c14-remaining-actions.test.ts`(16개, S1). 읽기 여섯은 '/' 결과와 비교·버튼 0, 실행은 누르기 전 0·누른 뒤 한 번, 비 owner·허용 채널 밖 거부와 볼 수 없는 대상 버림(감사 `target_denied`), 기억 저장 출처 `conversation:<원 메시지 ID>`·값 바꾸면 거부, 변경 접수 입력 요약이 owner 원문·`label=public`, 리뷰 재개·취소 장소, 게시 순서(고치기 전 `1 !== 0` 실패 확인).
- 검사: 작업자 관련 22개 파일 391개 통과(main C15·C17 병합 뒤). 통합 담당 전체 검사(`e66a463`, main C19 병합 뒤): 2400 / 2378 pass / 0 fail / 22 skip. Codex 지적 없음, CI 통과.
- 분해 불일치: 처리기 배선을 `Runtime`(C11) 생성 인수 대신 수신 생성자가 같은 `Store`에 묶는 방식(WeakMap)으로 했다. 말로 한 변경 요청은 '/change' 서식의 인수 조건을 서버 고정 문구 `SPOKEN_CHANGE_ACCEPTANCE`로 채우고, 서식 글자(` | `, `goal=`)가 있거나 상한에 걸리면 버린다. 말로 한 연결 해제는 그 스레드의 열린 연결만 받는다('/detach'는 owner 연결이면 어느 스레드든).
- 남은 것: 말로 한 기억 검색이 스레드 일반 글로 internal 기억까지 보인다(스위치 켜기 전 owner 결정, C24 할 일 1a). 기억·변경·연결 처리기는 커밋 뒤 불러 그 사이 죽으면 `confirmed`인데 실행 없음. 누르지 않은 기억 진술은 다음 제안이나 누를 때까지 `proposals.value`에 남는다(주기 정리 없음). `retry`·`memory_correct`·`memory_exclude` 따로 시험 없음.
