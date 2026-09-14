# AIOps 구현 전 계획 — 2차 적대적 리뷰

Round 2 re-review, with the adversarial lens. Round 1's findings in full (titles, bodies,
file:line, quoted code) are in `docs/reviews/aiops-codex/plan-r1.json` — read it FIRST, and
read `docs/reviews/aiops-codex/plan-r1.a.json` and `docs/reviews/aiops-codex/plan-r1.b.json`
too; these are the two panel members' own answers. The sibling `decisions.md` carries one
line per row plus the human's decision, not the finding bodies. Findings a2, b3, a3, b2,
a1, b1 were Accepted and addressed in the current working tree. The pre-fix input and
round 1 decisions are committed at `826b0d3`.

Do exactly TWO things, in order:

1. Re-verify those specific findings against the fix. For each, state resolved or
   still-open, with file:line evidence from the plan as it now stands, not a restatement
   of the original finding.
2. Report what the fixes BROKE: any new critical or high issue they introduced, including
   a fix that is wrong, scoped wider than its finding, or passes by weakening, skipping
   or deleting a test. Do not expand scope beyond these two tasks.

Do not re-open findings the human rejected or deferred in `decisions.md` without new
evidence. The user deferred a4's remaining observation-exit criteria until before actual
observation starts. Its original claim that the design lacks a startup diagnosis gate
was retracted by its author; read `a4-clarification.md` for the exact follow-up.

## 대상과 판정 근거

대상은 `docs/reviews/aiops-codex/input/implementation.md`, `input/design.md`, `input/spec.md`,
`input/issues/01-incident-queue.md`부터 `05-nuc-pilot-acceptance.md`까지다. 구현 전 계획이므로
아직 코드가 없다는 사실을 결함으로 보고하지 않는다. 현행 frozen repository의 코드와 대조해
이 보완 계약이 수용한 세 문제를 해결할 수 있는지 검증한다.

- a2·b3: worker 밖의 단계/전체 deadline, cgroup 종료 확인과 lease, 검증 무한 대기·출력 폭주 대조군.
- a3·b2: Telegram과 독립된 GHA 결과, 같은 SHA에서 무통지 정상 복귀, 미완료/누락/부분 실패 구별.
- a1·b1: 고정 코드/의존성과 후보 데이터·manifest 분리, 기준 정상/후보 위반과 약화 후보 대조군.

보고는 한국어이며 launcher의 envelope/schema를 따른다. 해결된 항목의 재검증 결과와 근거는
summary에 기록하고, findings에는 아직 열려 있는 문제와 수정이 새로 만든 critical/high 문제를
넣는다. 승인 여부는 확인한 근거로 결정한다.

읽기는 frozen repository에 한정한다. 원본 `.scratch`, 개인 홈, 운영 자격, 외부 Polyrelay 작업트리,
실제 클러스터/GitHub API를 조회하지 않는다. 추가 에이전트·파일 수정·명령 송신을 하지 않는다.
