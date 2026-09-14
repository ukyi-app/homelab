# AIOps 구현 전 계획 — 사용자 요청 추가 리뷰 1회

The user explicitly selected “수용·설계 보완·추가 리뷰 1회 (추천)” after plan r2. This is
that one requested additional review, recorded in `docs/reviews/aiops-codex/decisions.md`.
It is not an automatic extension or a waiver. Use the cold adversarial re-review lens.

Read `docs/reviews/aiops-codex/plan-r2.json` FIRST, then `plan-r2.a.json` and `decisions.md`.
Round 2 a1 was accepted: “고정 검사의 예산 상한도 기준 revision에서 가져오세요”. The pre-fix
plan and round 2 decision are committed at `c52ae4d`; the fix is in the current working tree.
For context, round 1's complete findings are in `plan-r1.json`, `plan-r1.a.json` and
`plan-r1.b.json`. Round 2 confirmed all six accepted round 1 findings resolved.

Do exactly TWO things, in order:

1. Re-verify round 2 a1 against this fix. State resolved or still-open with evidence from
   the current plan and repository code, not a restatement of the old finding.
2. Report any new critical or high issue this fix introduced, including an incorrect or
   overbroad fix, or one that weakens/skips/deletes a required check. Do not expand scope.

The user deferred round 1 a4's remaining observation-exit criteria until before actual
observation starts. Do not reopen that decision without new evidence; the original
startup-gate claim was retracted in `a4-clarification.md`.

## 확인할 계약

대상은 `docs/reviews/aiops-codex/input/design.md`, `input/implementation.md`,
`input/issues/04-validation-publication.md`, `input/issues/05-nuc-pilot-acceptance.md`다.
구현 전 설계이므로 코드가 아직 없다는 사실을 결함으로 보고하지 않는다.

- 신뢰된 coordinator가 고정한 기준 revision에서 budget을 읽고 후보 rows와 구별하는가.
- 후보 JSON의 budget이 고정 정책 입력을 덮지 못하고 후보 메타데이터 변경이 표시되는가.
- 기존 상한/후보 제안 상한의 평가가 분리되고 전체 파일의 초안 범위가 유지되는가.
- 기준 상한 누락/중복/기형, 후보 상한 삭제/기형, 행과 상한 동시 증가 대조군이 거짓 통과를 막는가.

`ledger-proof.md`는 보완 전 실제 반례다. `ledger-fixed-input-proof.md`는 기존 파서/정책에
수동 구성한 입력을 준 대조 실험이며 어댑터 구현이나 운영 검증이 아니다. 실제 코드와 함께
읽되 그 실험 하나만으로 계획이 옳다고 결론 내리지 않는다.

보고는 한국어이며 launcher의 envelope/schema를 따른다. 해결된 재검증 결과와 근거는 summary에,
아직 열린 문제와 수정이 새로 만든 critical/high 문제만 findings에 넣는다. 승인 여부는 근거로 결정한다.
최종 JSON은 schema 문서 자체가 아니라 응답 인스턴스다. 최상위 키는 `verdict`, `summary`,
`findings`, `next_steps`, `readback_token` 다섯 개만 사용한다. `$schema`나 `$comment` 등
schema 설명 메타데이터를 응답에 복제하지 않는다. 실제 검토를 마친 뒤 지정된 envelope로 반환한다.
읽기는 frozen repository에 한정한다. 원본 `.scratch`, 개인 홈, 운영 자격, 외부 Polyrelay 작업트리,
클러스터/GitHub API를 조회하지 않는다. 추가 에이전트·파일 수정·송신은 하지 않는다.
