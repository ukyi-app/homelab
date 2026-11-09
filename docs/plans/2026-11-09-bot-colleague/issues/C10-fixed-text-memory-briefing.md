# C10 고정 문구 2: 기억·브리핑

- 단계: 2 배포와 표면
- 상태: integrated (봇 #117 병합 `fb7d693`, 2026-11-10)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.4 고정 문구와 말투, §4.3 "기억 원문", §4.6 기억과 원문 보존, §4.9 스위치와 배포 순서 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C01, C04
- 연결 AC: AC-11(기억·브리핑 범위), AC-23(문구 두 판)
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 소유(연결 파일, 뒤에 C19 미룬 리뷰 건수 줄, C22 토큰 만료 줄이 줄 단위로 더함): 봇 `src/briefing.ts`(브리핑 본문·모델 호출 중지 줄의 '/' 안내)
  - 소유(표 밖, 이 티켓만 고침): 봇 `src/memory-commands.ts`(기억 명령 응답·오류·충돌 안내, 삭제 대기 안내), `src/memory.ts`(삭제 응답, 기억을 쓸 수 없을 때 안내), `src/briefing-observations.ts`(관측 칸 문구)
  - 연결 파일, 소유 C04: 봇 `src/discord.ts`의 기억 명령 응답 유실 안내(`MEMORY_ACK_NOTICE`)와 기억 명령 일시 오류 줄만
  - 시험: `test/memory-briefing.test.ts`, `test/memory-briefing-pg.test.ts`, `test/briefing-observations.test.ts`, `test/briefing-task-lane.test.ts`, `test/memory-commands.test.ts`, `test/memory-commands-pg.test.ts`, `test/t20-memory-commands.test.ts`의 해당 줄
- 설계 계약:
  - `src/memory-commands.ts`, `src/memory.ts`: 봇 DECISIONS "T20 기억·삭제 원장·브리핑 (로컬·mock, 2026-10-29)"의 "기억 명령 처리"(응답은 ephemeral, 입력값을 되풀이하지 않음, 삭제 응답의 `deleted`/`pending`과 "이미 게시된 사본은 지우지 않는다"), "DB의 삭제 표현", "파생 요약(브리핑)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md)
  - `src/briefing.ts`, `src/briefing-observations.ts`: 같은 절의 "일일 브리핑"·"브리핑 내용의 경계"("정상"은 신선한 관측이 있을 때만, 확인 못 하면 "미확인"), 봇 ARCHITECTURE §12 "T18 작업 레인 조립"의 브리핑 칸 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md)
  - 원문 7일 안내: 봇 DECISIONS "T31 원문 칸 보존 (사용자 2026-11-09)", "동료 봇 전환 (사용자 2026-11-09)" 6
  - `src/discord.ts`(두 줄): 봇 DECISIONS "T20 …" "기억 명령 처리"(응답 유실 때 내용 없는 고정 안내만)

## 목표

기억 명령 응답, 일일 브리핑, 브리핑 관측 칸이 해요체 동료 말투로 나온다. 기억을 지우면 "이 스레드의 원래 메시지는 7일 뒤에 지워져요"를 함께 알려 owner가 원문 수명을 안다. '/' 이름을 안내하는 줄은 스위치에 따라 두 판이다. 병합하면 말투가 바뀐 문구와 7일 안내는 바로 운영에 나간다.

## 할 일

1. 소유 파일의 고정 문구를 동료 말투로 다시 쓴다. 기억 저장·검색·정정·저장 제외·삭제 응답, 오류·서식 안내, 충돌 안내, "지금 기억을 쓸 수 없음", 삭제 대기 안내, 브리핑 머리말과 칸, 관측 칸의 "정상"·"미확인"·누락·지연 표시가 대상이다.
2. 안전 문장은 뜻을 그대로 둔다: 오류 응답이 입력값을 되풀이하지 않음, 삭제 응답의 완료/대기 구분, 백업 최대 14일, 이미 Discord에 게시된 사본은 지우지 않음, "정상"은 신선한 관측이 있을 때만.
3. 기억 삭제 응답(완료·대기 모두)에 이 스레드의 원래 메시지가 7일 뒤 지워진다는 문장을 더한다. 원문을 지금 지우거나 지운다고 약속하지 않는다(T31 정리 그대로).
4. '/' 이름이나 명령 이름(`memory-search`, `memory-correct`, `memory-delete`, `/model-status` 등)을 안내하는 줄은 C01 스위치 값으로 두 판을 고른다. 켜짐 판은 말로 하는 안내(예: "그 기억 지워 줘")이고, 모델 상태 확인은 `homelab bot` CLI로 한다고만 말한다(C05 명령 이름).
5. 브리핑 줄 구성은 C19·C22가 줄 단위로 더할 수 있게 둔다(이 티켓은 그 줄을 만들지 않는다).
6. 리터럴 비교 시험을 상수 참조로 옮기고, 켜짐 판 소유 문구에 '/' 명령 이름과 기억 명령 이름이 없음을 검사하는 시험을 더한다. 삭제 응답에 7일 안내가 있는지 시험한다.
7. 기록: 봇 `docs/ai-bot/VERIFICATION.md`에 "C10 고정 문구 2" 절, 문구 판단이 있으면 `docs/ai-bot/DECISIONS.md`에 그 절, 이 계획 폴더 `README.md`의 C10 상태 줄 갱신.

## 완료 조건

- [x] 기억 명령 응답·브리핑·관측 칸 문구가 해요체이고 "봇" 자기 지칭이 없다.
- [x] 기억을 지우면 원래 메시지가 7일 뒤 지워진다는 안내가 나온다.
- [x] 스위치 꺼짐이면 지금처럼 '/'·명령 이름을 안내하고, 켜짐이면 소유 문구에 '/' 명령 이름이 없다.
- [x] 입력값 비반복, 완료/대기 구분, 게시된 사본 비삭제 안내, "정상"/"미확인" 규칙이 그대로다.
- [x] `memory-briefing`, `briefing-observations`, `memory-commands` 시험이 통과한다.

## 검증

- 경계: S1(게시 서버). 앞선 시험 예: `memory-commands`, `memory-briefing`, `briefing-observations`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 `npm test` 대상(전체는 C24 통합).
- 잡는 실패: 새로 쓴 문구의 '/' 이름 잔존, 스위치 분기 누락, 7일 안내 누락, 안전 문장 손실. 못 잡는 범위: 문구의 자연스러움(owner 검토, C24 말투 표본).

## 결과

- 봇 PR #117(`feat/colleague-c10-fixed-text-memory-briefing`, 결과 head `4993017`), 병합 `fb7d693`(2026-11-10).
- 구현: `src/memory-commands.ts` 문구 해요체(`MEMORY_TEXT`·`INPUT_ERROR`·`REJECTED`), 스위치 두 판 `MEMORY_GUIDE {slash | colleague}`, 7일 안내 `RAW_TEXT_NOTICE`. `src/memory.ts` `DELETION_MESSAGE`. `src/briefing.ts` `BRIEFING_TEXT`, 모델 중지 줄 두 판(켜짐: `homelab bot` CLI). `src/discord.ts` 기억 응답 유실·일시 오류 안내가 처리기의 판을 쓴다. `src/main.ts` 스위치 배선 두 줄(작업자가 연결 파일 표에 자리가 없어 남긴 것을 주 진행자가 넣음, 표에 "C19보다 앞 티켓은 스위치 전달 줄만" 규칙 추가). 브리핑 칸 이름·상태 표시·관측 요약(`briefing-observations.ts`)은 문장이 아니라 그대로.
- 완료 조건 근거: "C10 말투"(문구 표 전체에 `습니다|합니다|입니다|하세요|봇` 없음), "C10 기억 삭제"(7일 안내 리터럴, 끝에 "Discord에 올라간 메시지는 그대로 남아요"), "C10 스위치 두 판"(기억 명령·수신 안내·브리핑 모델 중지 줄), "C10 조립: 스위치 켜짐·꺼짐"(조립을 거친 판 선택, 배선을 빼면 켜짐 시험 실패를 확인), 기존 안전 문장 시험 통과.
- 검사: 작업자 관련 7개 파일 139/139(실제 PG), 조립 포함 119/119. 통합 담당 전체 검사(`4993017`, node 24.22.0, 실제 PG, 잠금): 2239 tests / 2217 pass / 0 fail / 22 skip(SEC02_IMAGE). Codex 코드·보안 지적 없음, `build / test` 통과.
- 남은 것: 브리핑 쪽 배선(`colleague` 칸)은 조립 시험이 없다(기억 쪽만 조립 시험). 켜짐 판 모델 상태 안내는 `homelab bot` CLI의 하위 명령 이름 없이 적었다. 문구 자연스러움은 C24 말투 표본.
