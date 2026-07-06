# Memory Ledger (SSOT, CI-gated)

VM 상한 = 11 GiB. 커널 페이지 캐시 + 버스트용 여유분을 떼어두므로, pod LIMITS에
강제되는 **allocatable** 예산은 9216 MiB (9 GiB)다.
limit 합계가 이를 초과하면 새 앱 온보딩은 CI에서 실패한다 (설계 §10, R2).
원장 포맷/검증기는 이것 하나뿐이다. M6의 온보딩 게이트도 이 파일에 대해
`bun run verify:ledger`를 재사용하며, 제2의 원장을 정의하지 않는다.

## 모델 주석 — 명목 잔여 ≠ 실 헤드룸 (의도적 보수성)

이 합계는 **limit-합 가드(cap)**이지 실제 RAM 예약이 아니다. k8s는 requests만 스케줄에 강제하고
limit over-commit을 허용하므로, limit 합(현재 9020)은 *동시-peak 상한*일 뿐 실사용이 아니다.
실측(2026-06-22): 전 파드 working_set ≈ 2244Mi · 동시 peak(라이브 limit합) ≈ 6586Mi · MemAvailable
≈ 7925Mi(66%) — 물리 RAM은 막대히 여유다. 9216 cap은 의도적 보수치(VM ~12GiB에서 page-cache/burst·
OS reserve를 떼어둠)로 "OOM 전에 예산 경계에서 시끄럽게 실패"시키는 가드다. (원래 8704였으나 명목
헤드룸 확보를 위해 +512 상향 — 아래 옵션 (b) 적용분. 동시 peak 6586 ≪ allocatable 10724라 노드-OOM 안전.)
2026-07-06: cnpg-operator를 예산에 편입(+160) — operator values가 umbrella용 네스팅으로 조용히
무시돼 BestEffort로 구동되던 버그 수정과 함께 원장 행 추가(14일 peak 88Mi 실측 기반 160Mi).

한 행은 라이브 pod limit보다 **의도적으로 크다**: `k3s+os+coredns`(OS/커널 비-pod reserve — 실 coredns
pod만 ~170Mi). (`edge`·`cnpg` 보수 버퍼는 2026-06-22 right-size에서 라이브 정합 회수; `cert-manager`·
tailscale proxy는 무제한이었으나 같은 날 거버넌스 캡 신설해 예산에 편입.) 따라서 명목 잔여(9216−9020 = 196)는
실 헤드룸을 과소표현한다(여전히 동시 peak ≈ 6586 ≪ allocatable 10724).
더 많은 명목 헤드룸이 필요하면 (a) 상주 워크로드를 라이브 peak 실측에 맞게 right-size해 limit을 회수한다
(2026-06-22 observability/argocd/edge/cnpg 808Mi 회수; postgres·최근 OOM 수정분은 보호. 2026-07 B10에서
sealed-secrets 128→96·vmsingle 1Gi→896으로 −160Mi 추가 회수, 명목 잔여 196→356(≥256 온보딩 차단 해소). repo-server는
라이브 peak 271.75Mi(렌더 버스트, 앱 수에 비례 증가)로 288 축소가 1.06x라 UNSAFE → 보류(384 유지)).
(b) cap 상향은 이미 9216까지 적용됨 — page-cache/burst reserve 보호 위해 9216 초과는 금지. 그 이상의
물리 헤드룸은 VM RAM 증설(VM_ALLOCATABLE_MIB 동반 상향) 외엔 없다 — 모두 노드-OOM 안전(동시 peak ≪ allocatable).
주의: 행은 라이브 manifest와 자동 교차검증되지 않는다(verify:ledger는 마크다운만; local-helm traefik 등은
check-resource-limits 스캔 밖이라 여기 수기 계상). 신규/변경 상주 워크로드는 반드시 행+산문 동반 갱신.

<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=9216 -->

| component                          | namespace      | req_mi | limit_mi |
|------------------------------------|----------------|-------:|---------:|
| <!-- ledger:row --> k3s+os+coredns | kube-system    |   1075 |     1740 |
| <!-- ledger:row --> argocd         | argocd         |    640 |     1472 |
| <!-- ledger:row --> cnpg           | database       |    900 |     1152 |
| <!-- ledger:row --> cnpg-operator  | cnpg-system    |    100 |      160 |
| <!-- ledger:row --> cert-manager   | cert-manager   |     88 |      384 |
| <!-- ledger:row --> observability  | observability  |   1152 |     2080 |
| <!-- ledger:row --> edge           | edge           |    176 |      288 |
| <!-- ledger:row --> tailscale      | tailscale      |    128 |      320 |
| <!-- ledger:row --> whoami         | gateway        |     16 |       16 |
| <!-- ledger:row --> traefik        | gateway        |     64 |      192 |
| <!-- ledger:row --> sealed-secrets | sealed-secrets |     32 |       96 |
| <!-- ledger:row --> homepage       | homepage       |    128 |      192 |
| <!-- ledger:row --> glances        | observability  |     64 |      128 |
| <!-- ledger:row --> page           | prod           |     96 |      256 |
| <!-- ledger:row --> cache-trip-mate | cache          |     96 |      160 |
| <!-- ledger:row --> trip-mate-api  | prod           |    128 |      256 |
| <!-- ledger:row --> files          | files          |     32 |      128 |

**합계:** req ≈ 4915 Mi · limit ≈ 9020 Mi (반드시 ≤ 9216 Mi 유지).
(`pg-tools`는 CronJob용 ops 이미지 — 일시적이므로 상주 워크로드 행이 없다. worker/web/console
values-only 예시는 외부 앱 레포 체제 전환과 함께 제거 — 새 앱은 온보딩 PR이 행을 추가한다.)

## 갱신 방법
컴포넌트 추가/크기 조정: 해당 행의 `req_mi`/`limit_mi`를 수정하고(또는 행 마커
주석을 단 새 표 행을 추가하고) `bun run verify:ledger`를 실행한다.
CI가 모든 PR에서 같은 검사를 돌린다. OOM이 아니라 예산 경계에서 시끄럽게
실패한다.
