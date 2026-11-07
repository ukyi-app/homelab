# T31 봇 원문 칸의 보존 기간 정리 (T27에서 넘김)

- 단계: P4 후속
- 상태: 대기 (보존 기간 사용자 결정 먼저)
- 명세: [../spec.md](../spec.md)
- Blocked by: T27
- 선행 결정: 할 일 1 (사용자 결정, 미정. T21 재실행을 막을지도 그때 정한다)
- 연결 AC: AC-B8 (F04, DATA-02)
- 수행: 에이전트 + 사람(보존 기간 결정)

## 목표

T27은 사용자 결정대로 작업 레인 질문의 답(`codex_questions.answer`)과 변경 요청 원문(`change_request_inputs.text`)만 7일 뒤 지운다. 같은 원문이나 그 사본이 정리 경로 없이 남는 칸이 더 있다. 칸마다 보존 기간을 정하고 집행한다. 출처는 봇 저장소 `docs/ai-bot/DECISIONS.md` "T27" 절의 "정리 경로가 없는 다른 원문 칸(사용자 결정 대기)"이다.

## 메모

| 칸 | 담긴 것 | 지금 |
|---|---|---|
| `events.payload.text` | 모든 Discord 입력 원문: `/task` 요청, CHANGE가 아닌 `/answer` 답의 사본, 일반 대화 | 정리 경로 없음. 보존 기간 `retention.event_days`는 T20부터 미정. T27로 답을 지워도 이 사본이 남는다 |
| `codex_questions.prompt` | 모델이 낸 질문 | 정리 경로 없음 |
| `results.result` | 작업 완료 요약 등 모델 출력 | 정리 경로 없음 |
| `outbox.payload.content` | Discord로 보낸 질문·요약 본문 | 정리 경로 없음 |
| `change_requests.brief` | 요청 원문에서 뽑은 summary·goal·acceptance | 정리 경로 없음. 원문을 지워도 요청 내용 대부분이 남는다 |

- CHANGE의 `/answer`는 수신 때 `events`에 빈 글로 저장해 사본이 없다(`sealsAnswer`).
- `events`는 중복 판정(`semantic_key`)과 history 복구에도 쓰인다. 원문만 비우고 행은 남기는 방식이 맞는지 먼저 본다.
- 기억 삭제(T20)는 원본 `events`를 지우지 않는다. 기억 원장과의 관계도 함께 본다.
- 백업 속 원문은 백업 보존 기간(14일) 동안 남는다.

## 할 일

1. 칸마다 보존 기간과 기준 시각, 진행 중 예외를 정한다(사용자 결정). T21 재실행을 막을지도 정한다.
2. T27과 같은 방식(시각 기준 정리, digest 유지, 레인 스위치와 무관하게 도는 정리)으로 구현하고 시험한다.
3. 봇 저장소 PR, 운영 배포, 봇 `DECISIONS.md`·`ARCHITECTURE.md`·`VERIFICATION.md` 기록.

## 완료 조건

- 위 칸마다 보존 기간이 정해져 있고, 기간이 지나면 원문이 지워진다(또는 사람이 정한 예외와 이유가 기록돼 있다).
- 결정이 [../approvals.md](../approvals.md)와 봇 `DECISIONS.md`에 있다.

## 검증

`04` §4 DATA-02(원문 수명 하위 사례).
