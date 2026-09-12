# AIOps 구현 전 설계 리뷰 완료

상태: **approve** — 2026-09-12, 사용자 요청 추가 리뷰(plan r3) 완료.
검토 대상은 설계와 구현 계획이다. 실제 AIOps 코드·설치·운영 검증은 아직 수행하지 않았다.

| 라운드 | 결과 | 처리 |
|---|---|---|
| [plan r1](plan-r1.json) | needs-attention, 7건 | 공통 6건 수용·수정, a4는 관찰 시작 전까지 보류 |
| [plan r2](plan-r2.json) | needs-attention, 새 high 1건 | 기존 6건 resolved, 예산 상한 신뢰 입력 지적 수용 |
| [plan r3](plan-r3.json) | approve, 0건 | r2 a1 resolved, 보완에서 새 critical/high 지적 없음 |

## 확정된 보완

1. 수집·Codex·검증·게시를 worker 밖에서 감독하고 시간·자원·출력 상한과 자식 종료 확인을 적용한다.
2. GHA는 Telegram과 독립된 정상/경고/관측 불가 결과를 생산한다. 같은 SHA의 정상 복귀와 누락을 구별한다.
3. 고정 검사 코드·의존성과 후보 입력을 분리한다. 원장 행은 후보에서, 예산 상한은 신뢰된 기준 revision에서 읽는다.

[설계](input/design.md), [구현 순서](input/implementation.md), [판정 원장](decisions.md)에 계약과 수용 시험을 기록했다.
[보완 전 반례](ledger-proof.md)와 [기준 상한 입력 대조](ledger-fixed-input-proof.md)를 실제 로컬 도구로 확인했다.
후자는 수동으로 구성한 정책 입력의 대조이며 운영 어댑터의 구현/격리 검증을 대신하지 않는다.
문서 링크 36개·원본/사본 hash 18개·git diff 검사·문서 인덱스 게이트가 통과했다.

## 남은 단계

첫 구현은 [01 사건 계약·영속 큐](input/issues/01-incident-queue.md)다. 기존 Q13 전체 설계 공유 이해
확인 상태와 실제 파일럿 활성화 조건은 리뷰 통과만으로 완료 처리하지 않았다. a4의 최소 사건 수·
수동 대응 비교·관찰 종료 기준은 [05 NUC 수용](input/issues/05-nuc-pilot-acceptance.md)에서 실제 관찰 전에 확정한다.

## 실행 기록의 한계

3차 첫 실행은 응답 JSON의 `$schema`·`$comment`가 계약 밖 필드여서 `schema-invalid`로 무효였다.
실패 기록은 로컬 `.scratch/aiops-codex/reviews/plan-r3-attempt1-failed.json`에 보존했다. 응답 형식을
명시해 같은 라운드를 새 리뷰어로 재실행했다. 최종 artifact는 세션 기록에서 답변을 수집했고
finding 선언 0건/복구 0건이 일치한다. 최종 결과는 1/1 reviewer, 입력 drift 없음이다.
