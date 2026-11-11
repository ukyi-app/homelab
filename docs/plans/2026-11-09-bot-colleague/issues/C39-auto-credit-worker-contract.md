# C39 실행마다 방식 고르기: 작업자 계약과 자격

- 단계: 8 한도 뒤 API 크레딧
- 상태: 대기 (선행: C38)
- 명세: 봇 `docs/ai-bot/COLLEAGUE_SPEC.md`의 C38이 더한 절·AC(실행 env와 서명 경계, 구/신 판 호환)
- Blocked by: C38
- 연결 AC: C38이 정한 번호(조사 AC-A02, A03의 작업자 쪽, A11)
- 수행: 에이전트
- 저장소·PR: 봇 PR 하나. 작업자 이미지 배포는 C43
- 파일 소유: 봇 `src/credentials.ts`, `executor-profiles.ts`, `executor.ts`, `run-control.ts`, `worker-main.ts`, `chat-lane.ts`, `review-lane.ts`, `executor-claude.ts`, `executor-claude-task.ts`(자격 선택·분류), `worker.ts`, `contracts.ts`, `worker-http.ts`, `review-input.ts`, `review-http.ts`, `change-review.ts`, `task-contracts.ts`, `task-http.ts`, `task-worker.ts`(요청·응답 판). 문서는 파일 끝에 추가
- 설계 계약: 조사 2.A(계약, strict 응답, 보안 변화, 계정 일치), 6.2 1·2단계.

## 목표

작업자가 서명된 요청에 적힌 방식(구독 또는 API) 하나만 실행 env에 넣어 돌리고, 실제로 쓴 방식을 모델 출력 밖의 응답 칸으로 돌려준다. 옛 요청은 지금과 똑같이 돈다.

## 할 일

1. 대화, PR 리뷰, 변경 자체 리뷰, 작업(v1·v2)에 방식 선택을 싣는 새 요청 판 또는 명시적 협상을 만든다. 선택 칸(계정, 묶음 revision, 방식, runId)은 본문 digest와 capability에 들어간다. 옛 판의 직렬화 순서는 그대로다.
2. 작업자는 설치된 계정 묶음(이름·revision·기대 지문)을 한 볼륨 세대의 일관된 스냅샷으로 읽어 요청과 대조한다. 어긋남, 자격 누락, `unset`, 섞인 조합이면 모델 호출 없이 거부하고, 게시 서버가 실행 안 됨으로 구분할 수 있는 응답을 낸다.
3. 실행 env에는 고른 방식의 변수 하나만 넣는다. 두 값 모두 출력 반사 검사와 작업 sandbox 가림 대상이다.
4. 새 판 요청에만 새 응답 칸(실제 방식·revision·runId)을 낸다. unknown에서도 실행이 시작됐다면 이 칸을 채운다. 모델이 쓰는 출력 스키마에는 방식 칸을 넣지 않는다.
5. 구독 한도 실패를 넘어갈 근거로 쓸 수 있게 정규화한다(허용 목록과 fixture 표). 한도 경고·Usage credits로 성공한 실행·인증·과부하는 넘어갈 근거가 아니다. API의 429·결제 오류 분류는 지금처럼 보수적으로 둔다.
6. 작업자가 새 판을 받을 수 있음을 게시 서버가 확인할 수 있는 자리(작업 접수의 지원 표시, 대화·리뷰 쪽 확인)를 만든다.

## 완료 조건

- [ ] 구독 실행에는 구독 토큰만, API 실행에는 API 키만 env에 있다(S2).
- [ ] 방식·계정·revision을 바꾼 요청, 누락·섞인 묶음은 모델 호출 0건으로 거부된다(S2).
- [ ] 옛 요청은 옛 응답만 받고 동작이 같다. 새 응답 칸이 옛 strict 스키마로 새지 않는다(S2).
- [ ] 스위치 꺼짐 판과 지금 운영 경로의 동작이 바뀌지 않는다.

## 검증

- 경계: S2(작업자 HTTP → 가짜 CLI → 응답). 명령: 봇 `npm run check`, 바뀐 파일 관련 시험. 전체는 통합 담당.
- 잡는 실패: env에 자격 둘, 변조 통과, 옛 판 깨짐. 못 잡는 범위: 실제 API 키 init·egress, 실제 한도 응답 모양(C45 S5).

## 결과

(구현 뒤 채운다)
