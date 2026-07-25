# Triage 결정 — sealed-wiring (봉인 계약 커널)

### design r1

R-1 accept (high) — The wiring gate validates only one direction of the state invariant. 최초안은 "봉인본이 존재할 때만 검사"라 봉인본·kustomization 항목만 지우고 `envFrom`·`checksum`을 남긴 부분 상태가 통과했다(ArgoCD prune → 파드가 낡은 환경값으로 생존하다 재시작에서 사망 / dangling `resources` 항목 → kustomize 렌더 파손). → 게이트를 **쌍조건 `S ⟺ E ∧ K ∧ C`**(sealed 파일 · envFrom `<app>-secrets` · kustomization 등재 · checksum 정합)로 재작성하고 양방향 red-green 픽스처로 태운다. 파일명 규약 검사는 최소 범위(규약 외 `*.sealed.yaml` 거부)로 한정 — 값이 "kustomize 렌더가 죽기 전에 CI에서 잡는 것"이지 별도 설계 축이 아니라서.

R-2 accept (medium) — Metadata equality does not enforce strict SealedSecrets scope. `namespace === "prod"` 등호를 `strict-scope`라 부르고 에러 문구까지 그렇게 적었지만, kubeseal은 `sealedsecrets.bitnami.com/namespace-wide`·`cluster-wide` 어노테이션으로 scope를 넓힌다 — 기대 namespace·name 그대로 cluster-wide만 붙인 봉인본이 5검증을 전부 통과하면서 이름/네임스페이스 격리를 무너뜨린다(암호문 재사용). → scope를 봉인 계약의 6번째 조항으로 승격해 거부한다. **PR 배치 변경**: Codex 권고대로 "행위 보존이 아니라 의도적 정책 강화"로 분류하고, PR-B(순수 행위 보존)에 섞지 않는다 — 게이트 쪽 절반은 PR-A, `readSealed` 쪽은 신설 **PR-C**. born-green 실측: `tools/lib/seal.ts:7`·`tools/seal-secret.mts:77` 모두 `--scope` 없이 kubeseal 호출(strict 기본), 라이브 봉인본 scope 어노테이션 0건. 음성 회귀 필수 — `sealedsecrets.bitnami.com/patch`는 scope가 아닌 patch 모드라 통과해야 한다(argocd extras 선례).

**설계 반영** — PR 슬라이싱이 2개 → **3개**(A 게이트 / B 순수 리팩터 / C 정책 강화)로 바뀌었다. 유일한 실제 의존은 C → B(`readSealed`가 있어야 얹는다). A ↔ B는 무의존(게이트는 커밋된 `apps/`를 보지 툴 출력을 보지 않는다).

### design r2

R-2 resolved — Codex 재검증: strict scope가 두 adapter(게이트 PR-A · `readSealed` PR-C) 양쪽에서 강제되고, broad-scope·`patch` 케이스가 테스트로 덮이며, 정책 변경이 PR-C로 격리됐음을 확인. 신규 critical/high 없음.

R-3 accept (high) — R-1 remains open because the biconditional permits partial states. r1 수정에서 불변식을 `S ⟺ E ∧ K ∧ C`로 적었는데 이는 all-or-none이 아니다 — 반례 `S=0 E=1 K=0 C=0`은 양변이 모두 거짓이라 통과하지만, 같은 문서의 픽스처 표가 FAIL이라 적은 부분 삭제 상태다(봉인본 삭제 후 `envFrom` 잔존). 수식을 따라 구현하면 R-1이 되살아난다. → **네 사실의 명시적 동치**로 교체: `① (S ∧ E ∧ K ∧ C_present) ∨ (¬S ∧ ¬E ∧ ¬K ∧ ¬C_present)` + `② S → C_match`. 함께 **C축을 `C_present`/`C_match`로 분해** — ¬S 분기에는 해시할 봉인본이 없어 "일치"가 무의미하므로 상태 판정에는 존재 여부만 쓴다(이 분해가 없으면 진리표 열거가 구현 단계에서 다시 모호해진다). 게이트 테스트는 손 나열이 아니라 **4비트 진리표 루프 전수**(0000·1111만 PASS, 혼합 14 전부 FAIL)로 재작성.

### design r3

R-3 resolved (핵심) / R-4 accept (high) — Codex 재검증: 교정된 불변식(①②)이 반례 `S=0 E=1 K=0 C=0` 포함 혼합 14상태를 전부 거부하고, C_present/C_match 분해와 진리표 루프 설계가 건전함을 확인. **다만** PR 슬라이싱 표의 PR-A 행(:322)이 옛 수식 `S ⟺ E ∧ K ∧ C`를 **지시 문구로** 그대로 남겨둬, 권위 있는 구현 슬라이스를 따르면 R-3가 되살아난다는 잔여 결함(R-4)을 지적. → PR-A 행을 불변식 ①②(C_present/C_match) 참조로 교체. `:174`·`:272`의 옛 수식은 "틀렸다"는 **반례 인용**이라 유지(전수 grep 확인). 신규 critical/high 없음.

**게이트 상태** — r3에서 R-4를 Accept·수정했다. R-4는 순수 문서 정합(지시 문구 ↔ 불변식 절 동기화)이라 새 설계 결정이 아니다.

WAIVED by user: R-4는 문서 정합 수정(PR-A 지시 문구를 불변식 ①② 절에 동기화)으로 설계 실질 무변경이며, 그 내용은 r3가 이미 "sound"로 재검증한 것을 가리킨다. 설계는 r2에서 수렴했고 r3·r4는 문서 일관성만 다뤘다. 라운드 4 재검증 없이 게이트 통과 처리.
