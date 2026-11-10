# C34 수정 요청 후속(스위치 켜기 전)

- 단계: 6 PR 수정
- 상태: 대기 (선행: C27)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.10 "수정 요청", §5 AC-28 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C27
- 연결 AC: AC-28(재시작 복구, 닫힌 PR 거절)
- 수행: 에이전트
- 저장소·PR: 봇 PR
- 파일 소유:
  - 연결 파일, 소유 C07: 봇 `src/change-runtime.ts`의 수정 차례 자리(`amendLane`·`amendVerify`·`proposed`의 차례 열기 순서)
  - 연결 파일, 소유 C17: 봇 `src/change-commands.ts`의 `prepareAmendment`(확인 글 준비)
  - 연결 파일, 소유 C26: 봇 `src/github-writer.ts`·`src/github-review-io.ts`의 PR 상태 읽기를 쓰기만(읽기 포트가 없으면 가장 작은 읽기 하나)
  - 시험: `test/change-assembly.test.ts`, `test/c27-change-amend.test.ts`
  - 봇 `docs/ai-bot/VERIFICATION.md`·`DECISIONS.md`·`ARCHITECTURE.md`는 추가만
- 설계 계약: 봇 ARCHITECTURE §16 "게시 뒤 수정 차례(C27)", "끝 상태와 재시작", §16.1 "배포 읽기 (B4)"(병합 읽기), §16.4(작성 세션 정리), DECISIONS "동료 봇 전환 16 수정 요청 구현 선택 (C27…)".

## 목표

수정 차례가 재시작에도 작업 레인을 붙잡지 않고, 이미 병합되거나 닫힌 PR에는 수정 요청을 받지 않는다. 봇 #138(C27)의 Codex 3차 리뷰 P2 둘을 넘겨받았다(2026-11-10, P1 없음). 둘 다 동료 기능 스위치 뒤 경로라 C24에서 스위치를 켜기 전에 끝낸다.

## 할 일

1. 통과 receipt 뒤 정리(`src/change-runtime.ts` 760줄 근처): 필수 시험의 마지막 `passed` receipt를 저장한 직후 프로세스가 죽거나 `author.finalize()`가 끝 상태를 기록하기 전에 실패하면, 재시작 뒤 작성 세션 정리를 다시 하지 않는다. 작성 job이 `running`이나 lease 만료 뒤 `unknown`으로 남고, `childrenTick()`이 진행 중 차례의 자식을 빼므로 자체 리뷰·게시가 늦어지는 동안 `Store.laneBusy()`·`syncTaskLane()`이 다른 작업까지 막는다. 시험 통과 여부와 따로 작성 job이 끝났는지 보고, 정리가 안 끝났으면 finalize를 이어서 한다(실패 receipt 경로는 C27에서 고쳤다).
2. 닫힌 PR 거절(`src/change-commands.ts` 335줄 근처): 마지막 병합 읽기 직후 GitHub에서 PR이 병합되거나 닫히면 DB phase가 `proposed`라 검사를 지나고, `discussion.read()`는 리뷰·댓글만 읽어 닫힌 PR에 확인 버튼을 내고 수정 횟수까지 쓴다. `proposed()`가 병합 읽기보다 차례 열기를 먼저 하고 `amendPublish()`가 5분 읽기 주기를 지켜, 닫힘을 알기 전에 작성 모델과 시험까지 돌 수 있다. 확인 글을 준비할 때 실제 PR 상태를 읽어 병합·닫힌 대상은 거절하고, 차례를 열기 전에도 한 번 본다.
3. 시험: (1) 통과 receipt 저장 직후 끊김 → 재시작 뒤 작성 job이 끝 상태가 되고 레인이 풀림, (2) 확인 직전에 닫힌 PR → 거절 한 줄·차례 0·횟수 그대로, 차례를 열기 직전에 병합된 PR → 작성 0.
4. 기록: 봇 문서의 C27 절 뒤에 "C34" 절, 이 계획 폴더 `README.md`의 C34 상태 줄 갱신.

## 완료 조건

- [ ] 시험이 모두 통과한 뒤 재시작해도 수정 차례의 작성 job이 끝 상태가 되고 작업 레인이 풀린다.
- [ ] 이미 병합되거나 닫힌 PR의 수정 요청은 확인 버튼 없이 거절되고 수정 횟수를 쓰지 않는다.

## 검증

- 경계: S1(변경 런타임·수정 요청, 가짜 GitHub, PGlite). 앞선 시험 예: `change-assembly`, `c27-change-amend`.
- 명령: 봇 `npm run check`, 바뀐 파일 관련 시험. 전체는 통합 담당.
- 잡는 실패: 재시작 뒤 레인 막힘, 닫힌 PR에 수정 시작. 못 잡는 범위: 실제 GitHub의 상태 지연(C24 S5).

## 결과

(구현 뒤 채운다)
