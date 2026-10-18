# T17 봇 PR_REVIEW

- 단계: P4 봇 V1
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: T16
- 선행 결정: D-16, D-18 (의존성 업데이트 PR의 출처. 확정(사용자 2026-10-18, T05): 호스팅형 Renovate App 저장소별 설치, 자동 병합 모두 끔)
- 연결 AC: AC-B4
- 수행: 개발 에이전트 (`STAGE=PR_REVIEW`) + 사람 (리뷰 전용 App 생성·설치와 그 키의 Infisical 등록, 시험 PR 게시 승인)

## 목표

`01` §5: 전용 GitHub App으로 PR을 자동 리뷰하고 `COMMENT`만 게시한다 (R11, R12, R14).

## 제약

- App 설치는 시험 저장소부터 시작한다. 승인은 [../approvals.md](../approvals.md)에 남긴다 (AC-X2).
- `APPROVE`, `REQUEST_CHANGES`, merge, auto-merge는 게시 서버가 코드로 거부한다.
- 리뷰는 참고용이다. 자동 병합 범위(D-07) 안의 PR은 리뷰보다 먼저 병합될 수 있다.
- 한 저장소에 두 기본 리뷰를 동시에 켜지 않는다(`01` §3). Codex Connector는 org 전체 저장소에 설치돼 PR마다 자동 리뷰한다(spec §4.5, D-26). 시험 저장소에서 두 리뷰가 겹치는지 확인한다.
- D-16이 Codex Connector 같은 외부 자동 리뷰를 고르면 리뷰가 봇의 제한 게시 서버를 거치지 않는다. 그러면 REVIEW-04(게시 서버가 코드로 거부)와 DATA-01(내부 자료가 외부로 나감)이 검증하는 대상이 달라진다. 두 시험의 경계를 HANDOFF 추적 표의 "검증 경계" 칸에 다시 정의한다(`04` §7).

## 완료 조건

- `04` §4 시험 REVIEW-01~05, SEC-01·02, DATA-01, EVENT-02와 PR 경로의 AUTH-01·EVENT-01·EVENT-03 결과가 있다 (spec §7 AC-B4).
- spec §7 "단계 AC 공통 완료 규칙"을 따른다. 배정된 시험에 `fail`이 없다. `blocked`·`not_run`은 사유와 해소 티켓을 함께 적는다. 이 단계의 보안 경계 시험(AUTH-01, SEC-01·02, DATA-01, REVIEW-04)은 이 경로에서 최소 `mock` 또는 `local_integration`으로 `pass`다.
- 의존성 갱신 PR(D-18, Renovate PR)의 리뷰 결과가 1건 이상 있다.
- `04` §6 리뷰 품질 표가 있다.
- D-16이 외부 자동 리뷰면 REVIEW-04·DATA-01의 다시 정의한 검증 경계가 HANDOFF에 있다.
- HANDOFF가 있다.

## 검증

`04` §4 시험과 §6 품질 측정.
