# C37 말로 한 기억 검색에서 internal 기억 빼기

- 단계: 7 통합
- 상태: integrated (봇 #152 병합 `c5baa40`, 2026-11-11)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.3(읽기 요청 줄), §5 AC-7의 읽기 요청 관측 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C14, C36(코드 통합 기준)
- 연결 AC: AC-7(읽기 요청). 명세 질문 Q1(전체 리뷰 1차, C24 할 일 1a)의 owner 결정을 반영한다
- 결정: owner 2026-11-11 "좋아 그렇게해"(제안한 1번: 말로 한 검색에서 internal을 뺀다. internal은 `/memory-search`로 본다). 본인에게만 보이는 응답으로 바꾸는 안과 그대로 두는 안은 고르지 않았다
- 수행: 에이전트
- 저장소·PR: 봇 PR 하나. 게시 서버 쪽 변경이라 작업자 이미지 배포는 필요 없다(작업자가 코드로 확인한다)
- 파일 소유:
  - 봇 `src/memory-commands.ts`(검색 결과 본문 자리 `searchText`와 `memory-search` 분기), 필요하면 `src/memory.ts`(`search`가 돌려주는 보기에 분류가 없을 때만)
  - 연결 파일, 소유 C14: 봇 `src/proposals.ts`의 `memorySearchHandler`(읽기 줄만)
  - 시험: 기억 명령·제안 읽기 경계의 기존 시험, 새 시험
  - 봇 `docs/ai-bot/COLLEAGUE_SPEC.md`(§4.3·AC-7에 한 줄씩), `DECISIONS.md`·`VERIFICATION.md`·`ARCHITECTURE.md`는 파일 끝에 추가
  - 봇 `docs/ai-bot/DECISIONS.md` "C36 묶음 G"·"C36 묶음 H"의 "owner 수용 대기" 문구(수용으로 고친다. 사용자 2026-11-11 "너의 추천대로 진행")
- 설계 계약: 위 명세 줄, 봇 ARCHITECTURE §13의 제안·읽기 요청 문단, DECISIONS "C14" 구현 절과 "C36 묶음 E"(출처 ID 가림), GLOSSARY "동료 말투".

## 목표

스레드에 일반 글로 나가는 말로 한 기억 검색 결과에는 공개해도 되는 기억(`safe_summary`)만 실린다. internal 기억은 본인에게만 보이는 `/memory-search` 응답에서만 보인다.

## 할 일

1. 지금 동작을 빨간 시험으로 먼저 고정한다: internal과 `safe_summary` 기억이 함께 맞는 검색어로 `memory_search` 제안을 실행하면 스레드 글에 internal 진술이 실린다.
2. 말로 한 검색(`threadReply`)의 결과에서 internal 기억을 뺀다. 거르는 자리는 본문을 만들기 전이다(공개 검사에 기대지 않는다).
3. 빠진 internal 기억이 있으면 건수만 알리는 한 줄을 붙인다(진술·주제·출처 없음). 맞는 기억이 internal뿐이면 그 한 줄만 답한다. 문구는 동료 말투와 명세 §4.9의 켜짐 판 규칙을 따르고, '/' 이름을 쓸 수 있는지 판단한 근거를 최종 답에 적는다.
4. `/memory-search`의 본인 전용 응답은 바꾸지 않는다(internal 포함, 시험으로 고정).
5. 다른 읽기 제안과 기억 저장·정정의 결과 글이 internal 진술을 스레드에 내는 경로가 있는지 확인한다. 있으면 고치지 말고 근거와 함께 반환한다(범위 결정은 주 진행자).
6. 명세 §4.3·AC-7에 "말로 한 기억 검색 결과에는 internal 기억이 실리지 않는다"를 더하고, DECISIONS·VERIFICATION·ARCHITECTURE 끝에 "C37" 절을 더한다. DECISIONS의 "owner 수용 대기" 문구 둘을 수용으로 고친다.

## 완료 조건

- [x] 말로 한 기억 검색의 스레드 글에 internal 기억의 진술·주제·출처가 실리지 않는다.
- [x] 빠진 internal 기억이 있으면 건수 한 줄이 나가고, 없으면 지금과 같은 글이다.
- [x] `/memory-search` 응답은 지금과 같다(internal 포함).
- [x] 스위치 꺼짐 판 동작은 바뀌지 않는다.

## 검증

- 경계: S1(수신 → 제안 읽기 → 기억 명령 → 게시, PGlite). 앞선 시험 예: C14의 읽기 요청 시험, C36 묶음 E의 출처 ID 가림 시험.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험. 전체는 통합 담당.
- 잡는 실패: internal 진술이 스레드 글로 나감, `/memory-search`에서 internal이 빠짐. 못 잡는 범위: 실제 모델이 검색 제안을 내는지와 실제 Discord 표시(C24 S5).

## 결과

- 봇 PR #152, 병합 `c5baa40`(2026-11-11). 말로 한 검색(`threadReply`)은 본문을 만들기 전에 `safe_summary`만 남기고, 뺀 internal이 있으면 "공개하지 않는 기억 N건은 여기에 싣지 않았어요." 한 줄을 붙인다. internal뿐이면 그 한 줄만 답한다. 켜짐 판 글이라 '/' 이름은 쓰지 않았다.
- 완료 조건 4개 충족(S1, `test/c14-remaining-actions.test.ts`의 "C37" 시험 넷). 고치기 전 빨강: 기준 `36c96b6`에서 새 시험 2건 실패(internal 진술이 스레드 글에 실림).
- 재검토(phase=re-review 5차, `36c96b6..ae58821`, Codex 작업자 하나): internal 차단·`/memory-search`·꺼짐 판·`MemoryView` 사용처 통과. 신규 RR6-N1(P2: 실린 본문이 공개 검사에 걸리면 internal 건수 줄도 사라짐) 수용 → `1fb0586`에서 본문과 건수를 나눠 넘기고 공개 검사는 본문만 본다(고치기 전 빨강 1건).
- 검사: 결과 `1fb0586`에서 `FPB_TEST_TIMEOUT=2400 .fpb/test.sh wt-c37 c37-full2 --pg -- full` 2,649개 중 통과 2,627, 실패 0, skip 22. `build / test` 통과. GitHub Codex 리뷰·보안 리뷰 지적 없음(`1fb0586`).
- 함께 실은 문서(코드 변화 없음): 명세 질문 Q2(§4.10·AC-30, 말로 부탁한 리뷰는 정책 목록 밖이면 공개 저장소만)와 Q3(AC-5 보존 순서)의 owner 결정, DECISIONS "C36 묶음 G·H"의 알려진 한계 수용 문구.
- 작업자 프로세스 동작은 바뀌지 않는다(작업자 이미지 배포 없음).
- 알려진 한계: 검색은 분류와 상관없이 최근 갱신순 20건을 가져온 뒤 거른다. 맞는 internal이 많으면 20건 밖의 `safe_summary` 기억이 말로 한 검색에 실리지 않을 수 있고, 건수도 그 20건 안에서만 센다. 기억 저장·정정의 실행 확인 글이 저장할 진술을 싣는 것은 명세 §4.3대로다.
- 못 본 것: 실제 모델이 검색 제안을 내는지, 실제 Discord 표시(C24 S5).
