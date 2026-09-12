plan r2 · codex · 1/1 members · 1 findings (0 consensus, 0 solo, 1 unpaired) · verdict needs-attention

Status: 2차 새 지적 1건 수용 확정. 기존 6건은 계획 수준에서 resolved.

[a] 계획 승인 보류. 정적 재검증 2/2 완료: 원래 6건의 공백은 해소됐으나, 보완한 원장 어댑터에 high 1건이 있습니다.
1. a2 resolved, b3 resolved — docs/reviews/aiops-codex/input/implementation.md:34·37·51에 단계/전체 상한과 외부 감독이 추가됐습니다. input/design.md:125–131·152–167은 cgroup 종료 확인 후 lease 해제, cleanup-unknown 차단, 스트리밍 출력 제한을 명시하며 input/issues/04-validation-publication.md:57–58은 무한 대기·출력 폭주 후 다음 사건 처리를 요구합니다.
2. a3 resolved, b2 resolved — docs/reviews/aiops-codex/input/implementation.md:52와 input/issues/02-notification-sources.md:30–36·45–49는 Telegram 독립 결과, 같은 SHA의 정상 복귀, 누락·부분 실패·역순 attempt 대조를 실제 생산 경로의 수용 조건으로 지정합니다.
3. a1 resolved, b1 resolved — docs/reviews/aiops-codex/input/implementation.md:53과 input/issues/04-validation-publication.md:14–16·30–39·53–56은 코드/후보 루트 분리, 전체 후보 manifest, helper·정책 고정과 정상/위반 대조군을 요구합니다. 다만 새로 명시한 원장 입력 방식이 후보의 예산 상한까지 신뢰하는 문제는 아래와 같습니다. a4의 보류 범위는 재개하지 않았습니다.

| ID | Finding (title + full body) | Severity | file:line | Code | Quotation | Recommendation | Proposed decision |
|---|---|---|---|---|---|---|---|
| a1 | **고정 검사의 예산 상한도 기준 revision에서 가져오세요**<br>새 어댑터는 후보 원장 전체를 고정 파서에 전달합니다. 그런데 tools/ledger-to-json.ts:10·29는 해당 파일의 LIMIT_BUDGET_MIB를 input.budget으로 내보내고, policy/ledger.rego:23–25는 그 값을 상한으로 사용합니다. 소스에서 도출되는 반례는 기준 원장(합계 9148Mi, 상한 10240Mi)을 유지하면서 후보에 9000Mi 행을 추가하고 LIMIT_BUDGET_MIB를 20000으로 올리는 것입니다. 파서/helper/rego를 전혀 변경하지 않아도 후보 합계 18148Mi가 후보 상한보다 작아 고정 원장 검사는 통과합니다. 따라서 코드와 루트를 고정해도 기존 예산 위반을 검출한다는 보장은 성립하지 않습니다. 이 티켓 53–56행의 약화 대조군에도 예산 메타데이터 변경은 명시되지 않았습니다. 결과적으로 기존 상한을 넘긴 초안에 고정 검사 통과 결과를 붙일 수 있습니다. | high | [04-validation-publication.md:31](/home/ukyi/workspace/homelab/docs/reviews/aiops-codex/input/issues/04-validation-publication.md:31) | <code>바꾸지 않는다. 진입점·helper·파서·정책·도구 버전은 고정 기준에서 읽고, 원장/매니페스트 등<br>검사 데이터와 파일 열거는 신규·삭제까지 반영한 후보 manifest에서 읽는다. 원장은 고정<br>`ledger-to-json.ts`와 그 helper·`policy/ledger.rego`로 후보 `docs/memory-ledger.md`를 검사한다.</code> | matches | 고정 검사에서는 기준 revision의 LIMIT_BUDGET_MIB를 신뢰 입력으로 고정하고 후보 행을 그 상한에 대조하세요. 상한 변경 초안은 계속 허용하되 기존 기준과의 충돌 및 후보 기준 결과를 분리해 보고하세요. 후보가 행과 예산 메타데이터를 함께 늘려도 기존 기준 검사가 실패하는 대조군을 추가하세요. | 수용 — 후보 행은 검사 대상으로 읽고 예산 상한은 신뢰 기준에서 주입. 후보 상한 변경은 별도 보고. [로컬 재현](ledger-proof.md)으로 확인. |

사용자가 새 지적 수용·설계 보완·추가 리뷰 1회를 선택했다. [decisions.md](decisions.md)에 판정과 plan r3 요청을 기록했다.
