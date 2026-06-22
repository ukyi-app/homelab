# Memory Ledger (SSOT, CI-gated)

VM 상한 = 11 GiB. 커널 페이지 캐시 + 버스트용 여유분을 떼어두므로, pod LIMITS에
강제되는 **allocatable** 예산은 8704 MiB (8.5 GiB)다.
limit 합계가 이를 초과하면 새 앱 온보딩은 CI에서 실패한다 (설계 §10, R2).
원장 포맷/검증기는 이것 하나뿐이다. M6의 온보딩 게이트도 이 파일에 대해
`bun run verify:ledger`를 재사용하며, 제2의 원장을 정의하지 않는다.

<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->

| component                          | namespace      | req_mi | limit_mi |
|------------------------------------|----------------|-------:|---------:|
| <!-- ledger:row --> k3s+os+coredns | kube-system    |   1075 |     1740 |
| <!-- ledger:row --> argocd         | argocd         |    576 |     1280 |
| <!-- ledger:row --> cnpg           | database       |    900 |     1288 |
| <!-- ledger:row --> cert-manager   | cert-manager   |     60 |      180 |
| <!-- ledger:row --> observability  | observability  |   1312 |     2560 |
| <!-- ledger:row --> edge           | edge           |    240 |      544 |
| <!-- ledger:row --> whoami         | gateway        |     16 |       16 |
| <!-- ledger:row --> sealed-secrets | sealed-secrets |     32 |      128 |
| <!-- ledger:row --> homepage       | homepage       |    128 |      192 |
| <!-- ledger:row --> glances        | observability  |     64 |      192 |

**합계:** req ≈ 4403 Mi · limit ≈ 8120 Mi (반드시 ≤ 8704 Mi 유지).
(`pg-tools`는 CronJob용 ops 이미지 — 일시적이므로 상주 워크로드 행이 없다. worker/web/console
values-only 예시는 외부 앱 레포 체제 전환과 함께 제거 — 새 앱은 온보딩 PR이 행을 추가한다.)

## 갱신 방법
컴포넌트 추가/크기 조정: 해당 행의 `req_mi`/`limit_mi`를 수정하고(또는 행 마커
주석을 단 새 표 행을 추가하고) `bun run verify:ledger`를 실행한다.
CI가 모든 PR에서 같은 검사를 돌린다. OOM이 아니라 예산 경계에서 시끄럽게
실패한다.
