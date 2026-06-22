# Memory Ledger (SSOT, CI-gated)

VM 상한 = 11 GiB. 커널 페이지 캐시 + 버스트용 여유분을 떼어두므로, pod LIMITS에
강제되는 **allocatable** 예산은 8704 MiB (8.5 GiB)다.
limit 합계가 이를 초과하면 새 앱 온보딩은 CI에서 실패한다 (설계 §10, R2).
원장 포맷/검증기는 이것 하나뿐이다. M6의 온보딩 게이트도 이 파일에 대해
`bun run verify:ledger`를 재사용하며, 제2의 원장을 정의하지 않는다.

## 모델 주석 — 명목 잔여 ≠ 실 헤드룸 (의도적 보수성)

이 합계는 **limit-합 가드(cap)**이지 실제 RAM 예약이 아니다. k8s는 requests만 스케줄에 강제하고
limit over-commit을 허용하므로, limit 합(현재 8440)은 *동시-peak 상한*일 뿐 실사용이 아니다.
실측(2026-06): 전 파드 working_set ≈ 1948Mi · 동시 peak(라이브 limit합) ≈ 6714Mi · MemAvailable
≈ 7751Mi(65%) — 물리 RAM은 막대히 여유다. 8704 cap은 의도적 보수치(VM ~12GiB에서 page-cache/burst·
OS reserve를 떼어둠)로 "OOM 전에 예산 경계에서 시끄럽게 실패"시키는 가드다.

일부 행은 라이브 pod limit보다 **의도적으로 크다**: `k3s+os+coredns`(OS/커널 비-pod reserve — 실 coredns
pod만 ~170Mi)·`cert-manager`(unlimited operator reserve)·`edge`/`cnpg`(보수 버퍼 ~160/200Mi). 따라서
명목 잔여(8704−8440 = 264)는 실 헤드룸을 과소표현한다 — 앱이 0개여도 잔여가 작아 *보이는* 이유다.
나중에 명목 헤드룸이 필요하면 (a) 위 보수 버퍼 행을 라이브에 맞게 축소하거나 (b) cap을 9216으로
상향(단 page-cache/burst reserve 보호 위해 그 이상 금지)한다 — 둘 다 노드-OOM 안전(동시 peak ≪ allocatable).
주의: 행은 라이브 manifest와 자동 교차검증되지 않는다(verify:ledger는 마크다운만; local-helm traefik 등은
check-resource-limits 스캔 밖이라 여기 수기 계상). 신규/변경 상주 워크로드는 반드시 행+산문 동반 갱신.

<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->

| component                          | namespace      | req_mi | limit_mi |
|------------------------------------|----------------|-------:|---------:|
| <!-- ledger:row --> k3s+os+coredns | kube-system    |   1075 |     1740 |
| <!-- ledger:row --> argocd         | argocd         |    576 |     1408 |
| <!-- ledger:row --> cnpg           | database       |    900 |     1288 |
| <!-- ledger:row --> cert-manager   | cert-manager   |     60 |      180 |
| <!-- ledger:row --> observability  | observability  |   1312 |     2560 |
| <!-- ledger:row --> edge           | edge           |    240 |      544 |
| <!-- ledger:row --> whoami         | gateway        |     16 |       16 |
| <!-- ledger:row --> traefik        | gateway        |     64 |      192 |
| <!-- ledger:row --> sealed-secrets | sealed-secrets |     32 |      128 |
| <!-- ledger:row --> homepage       | homepage       |    128 |      192 |
| <!-- ledger:row --> glances        | observability  |     64 |      192 |

**합계:** req ≈ 4467 Mi · limit ≈ 8440 Mi (반드시 ≤ 8704 Mi 유지).
(`pg-tools`는 CronJob용 ops 이미지 — 일시적이므로 상주 워크로드 행이 없다. worker/web/console
values-only 예시는 외부 앱 레포 체제 전환과 함께 제거 — 새 앱은 온보딩 PR이 행을 추가한다.)

## 갱신 방법
컴포넌트 추가/크기 조정: 해당 행의 `req_mi`/`limit_mi`를 수정하고(또는 행 마커
주석을 단 새 표 행을 추가하고) `bun run verify:ledger`를 실행한다.
CI가 모든 PR에서 같은 검사를 돌린다. OOM이 아니라 예산 경계에서 시끄럽게
실패한다.
