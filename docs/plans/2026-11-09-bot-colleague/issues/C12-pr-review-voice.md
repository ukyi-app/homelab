# C12 PR 리뷰 말투

- 단계: 3 새 형식 켜기
- 상태: 대기 (선행: C06)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.4 "PR 리뷰(GitHub)"·"리뷰 지시문 변경의 대가" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C06
- 연결 AC: AC-13
- 수행: 에이전트
- 저장소·PR: 봇 PR(C06 운영 확인이 homelab `approvals.md`에 기록된 뒤 병합)
- 파일 소유:
  - 소유(연결 파일, 뒤에 C18 Discord 리뷰 안내 문구, C20 리뷰 대기 안내가 고침): 봇 `src/review.ts`의 GitHub 렌더러(`render`: 머리말·통계 줄·지적 문단·인라인 댓글 본문), 서버가 작업자에 보내는 리뷰 요청의 지시문, 리뷰 세대 revision 재료. Discord 리뷰 요약·미게시 안내 문구 자리는 C18 몫이라 이 티켓은 문장을 바꾸지 않는다
  - 연결 파일, 소유 C02: 봇 `src/review-input.ts`(`REVIEW_INSTRUCTIONS` v2 상수와 요청 스키마의 literal 수용은 C02가 만든다. 이 티켓은 서버가 v2 값을 쓰게만 바꾼다)
  - 쓰기만 함: 봇 `src/review-lane.ts`(작업자 프롬프트는 받은 지시문을 그대로 앞에 둔다. 코드 변경 없음, 시험 기대만)
  - 시험: `test/pr-review.test.ts`(렌더 기대 약 8곳), `test/publisher-review.test.ts`(1곳), `test/review-lane.test.ts`(프롬프트 줄 구성), 리뷰 세대 revision을 고정하는 시험이 있으면 그 줄
- 설계 계약:
  - `src/review.ts` 렌더·게시: 봇 DECISIONS "T17 PR_REVIEW 구현 선택과 결정 대기 (2026-10-29, 로컬·mock)" 8(게시 대조 marker), 9(공개 범위: Discord 요약에 모델 문장 없음), 11(게시 직전 현재 정책으로 다시 렌더, 게시 상한), 16(같은 세대 결과 재사용), "T17 결정 (사용자 2026-11-04)", "D-16 PR 리뷰 방식" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md)
  - 리뷰 세대 revision과 `policy_changed`: 같은 DECISIONS T17 절 16, 명세 §4.4 "리뷰 지시문 변경의 대가"
  - `src/review-input.ts`, `src/review-lane.ts`: 봇 ARCHITECTURE §12 "T16b 실행기 프로필"(리뷰 레인 무도구 실행), 명세 §4.2 "계약 배포 순서" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md)

## 목표

GitHub PR 리뷰 본문과 인라인 댓글이 동료가 쓴 글처럼 읽힌다. 심각도(P0~P3)는 그대로 보이고, 지적마다 조건·영향·근거·개선이 네 줄 양식이 아니라 한 문단의 문장으로 이어진다. 머리말과 통계는 한두 줄로 줄되 "승인·병합 판단이 아니다"는 남는다. 리뷰 대조 표식과 Discord 요약의 모델 문장 금지는 그대로다. 병합하면 바로 운영에 나가고, 그 순간 진행 중 리뷰는 `policy_changed`로 닫히고 새 세대가 생긴다.

## 할 일

1. 시작 전에 C06 운영 확인(작업자가 v2 리뷰 지시문을 받음)이 homelab `docs/plans/2026-10-17-homelab-rebuild/approvals.md`에 있는지 본다. 없으면 병합하지 않는다(지시문은 literal이라 v1 작업자는 요청을 거부한다).
2. 서버가 리뷰 요청에 `REVIEW_INSTRUCTIONS` v2(C02)를 보낸다. 출력 스키마는 그대로다(조건·영향·근거·개선 빈 칸 금지 유지).
3. 렌더러: 지적마다 심각도 표시와 제목을 두고, 조건·영향·근거·개선을 한 문단의 해요체 문장으로 잇는다. 모델 글은 지금처럼 무력화(`inert`) 처리 뒤에만 싣는다. 위치 줄, 미검토 파일, 상한 생략 건수, 확인 질문 칸은 정보를 잃지 않게 말투만 바꾼다.
4. 머리말·통계 줄을 동료 말투 한두 줄로 줄이고 "승인·병합 판단이 아니다"는 남긴다. 리뷰 대조 표식(HTML 주석)은 첫 줄 그대로 둔다.
5. 게시 상한(지적 수·인라인 수·본문 길이) 회귀가 없게 한다. 저장된 결과는 게시 직전 현재 정책으로 다시 렌더되므로, 배포 전에 저장돼 게시를 기다리는 결과도 새 렌더로 나간다는 점을 시험으로 고정한다.
6. 재리뷰 몰림 확인: 지시문이 바뀌면 리뷰 세대 revision이 바뀐다. 웹훅·재조정(`reconcile`, 한 바퀴 상한 `maxReviewsPerRun` ≤ 20)이 열린 PR마다 새 세대를 만드는지 코드와 시험으로 확인한다(지금은 미확인). 몰리면 막는 방법(예: 같은 head에 게시된 결과가 있으면 지시문 변경만으로는 재리뷰하지 않음)을 정하고 구현하거나, 받아들일 경우 그 이유와 예상 건수를 DECISIONS에 적는다.
7. 시험 갱신: `pr-review` 렌더 기대, `publisher-review` 1곳, `review-lane` 줄 구성. 심각도 표시·대조 표식·"승인·병합 판단이 아니다" 문장·Discord 요약에 모델 문장 없음은 리터럴로 고정한다(명세 §6 안전 규칙).
8. 기록: 봇 `docs/ai-bot/DECISIONS.md`에 렌더 형식과 재리뷰 몰림 판단 절, `docs/ai-bot/VERIFICATION.md`에 "C12 PR 리뷰 말투" 절, 이 계획 폴더 `README.md`의 C12 상태 줄 갱신.

## 완료 조건

- [ ] GitHub 리뷰 본문과 인라인 댓글에 심각도 표시가 남고, 지적마다 조건·영향·근거·개선이 한 문단으로 나온다.
- [ ] "승인·병합 판단이 아니다"가 남고, 리뷰 대조 표식이 그대로라 응답 유실 뒤 대조가 깨지지 않는다.
- [ ] Discord 리뷰 요약에 모델 문장이 없다.
- [ ] 게시 상한(지적·인라인·본문 길이) 동작이 그대로다.
- [ ] 지시문 변경 배포 때 재리뷰가 몰리는지 확인한 결과와 대응이 기록돼 있다.

## 검증

- 경계: S1(리뷰 렌더, 앞선 예 `pr-review`, `publisher-review`)과 S2(리뷰 지시문 계약, 앞선 예 `review-lane`).
- 명령: 봇 `npm run check`, 바뀐 파일 관련 `npm test` 대상(전체는 C24 통합).
- 잡는 실패: 심각도 누락, 대조 표식 깨짐, 모델 문장의 Discord 유출, 렌더 상한 회귀, 지시문 literal 불일치. 못 잡는 범위: 리뷰 글의 말투 품질(C24 `homelab-smoke` PR, S5), 운영의 실제 재리뷰 건수(할 일 6의 확인과 배포 뒤 관찰).

## 결과

(구현 뒤 채운다)
