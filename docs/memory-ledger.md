# Memory Ledger (SSOT, CI-gated)

VM 상한 = 12 GiB. 커널 페이지 캐시 + 버스트용 여유분을 떼어두므로, pod LIMITS에
강제되는 **allocatable** 예산(cap)은 10240 MiB (10 GiB)다.
limit 합계가 이를 초과하면 새 앱 온보딩은 CI에서 실패한다 (설계 §10, R2).
원장 포맷/검증기는 이것 하나뿐이다. M6의 온보딩 게이트도 이 파일에 대해
`bun run verify:ledger`를 재사용하며, 제2의 원장을 정의하지 않는다.

## 모델 주석 — 명목 잔여 ≠ 실 헤드룸 (의도적 보수성)

이 합계는 **limit-합 가드(cap)**이지 실제 RAM 예약이 아니다. k8s는 requests만 스케줄에 강제하고
limit over-commit을 허용하므로, limit 합(현재 8700)은 *동시-peak 상한*일 뿐 실사용이 아니다.
실측(2026-06-22): 전 파드 working_set ≈ 2244Mi · 동시 peak(라이브 limit합) ≈ 6586Mi · MemAvailable
≈ 7925Mi(66%) — 물리 RAM은 막대히 여유다. 10240 cap은 의도적 보수치(VM 12GiB에서 page-cache/burst·
OS reserve를 떼어둠)로 "OOM 전에 예산 경계에서 시끄럽게 실패"시키는 가드다. (원래 8704였으나 명목
헤드룸 확보를 위해 +512 상향 — 아래 옵션 (b) 적용분. 동시 peak 6586 ≪ allocatable 10724라 노드-OOM 안전.)
2026-07-06: cnpg-operator를 예산에 편입(+160) — operator values가 umbrella용 네스팅으로 조용히
무시돼 BestEffort로 구동되던 버그 수정과 함께 원장 행 추가(14일 peak 88Mi 실측 기반 160Mi).
2026-07-06: tailscale 행이 proxy 1대만 계상하던 미계상 정정(limit 320→512·+192, req 128→192·+64) —
`loadBalancerClass: tailscale` 서비스가 2개(traefik-ts + pg-rw#114)라 operator가 proxy StatefulSet을
2대 생성하고 defaultProxyClass(`resource-capped`)가 각 192Mi limit/64Mi req를 부여한다(라이브 확인:
ts-traefik-ts·ts-pg-rw-tailscale 2대). 새 값 = operator(128/64) + proxy(192/64)×2 = limit 512·req 192.
이로써 명목 잔여가 196→4Mi로 붕괴 — **신규 온보딩은 실질 차단 상태**다. 추가 여력은 상주 워크로드
right-size 회수(옵션 a) 또는 VM RAM 증설(cap은 이미 9216에서 소진 — 옵션 b 너머, VM_ALLOCATABLE_MIB
동반 상향)이 유일하다.

2026-07-06 (메타갭 ⑥ Task 5.5 — right-size 스윕 실측 결과, **≥256 회수 불가 판정**): 14일 peak
working_set을 파드-세대 붕괴(`max by (container)`)로 실측한 결과, right-size만으로는 명목 잔여 ≥256
달성이 **불가능**함이 확정됐다. 근거(측정 2026-07-06):
- **cert-manager**(플랜이 지목한 1차 레버): 3컨테이너 peak 합 = 267Mi(cainjector 101·controller 96·
  webhook 69) vs cap 384 = **1.44x**. F24의 peak×2.0x 마진 미달이라 축소 불가(오히려 타이트) — 레버 무효.
- **whoami**(+16 후보): posture 라이브 e2e(`tests/posture/test_networking-e2e.bats` — internal gateway
  smoke·`whoami.home` dig)가 참조하는 **load-bearing** 컴포넌트라 철거 불가(존치).
- 실제 slack 보유(≥1.5x) 후보 = files(6/128=21x, ~64 회수)·page(88/256=2.9x, ~80)·trip-mate-api
  (149/256=1.72x, ~32)·sealed-secrets(56/96=1.71x, ~16) 합 ≈ **192**. 4+192 = 196 **< 256** — 안전 후보를
  전부 회수해도 온보딩 1앱분(256)에 미달. 게다가 각 후보는 F25의 24h 관찰 윈도(다중일) 필요.
- 오히려 **cnpg-operator(153/160=1.05x)·homepage(162/192=1.19x)·glances(112/128)·traefik(168/192)**은
  타이트(≥1.3x 미달) — 축소 금지, cnpg-operator는 near-OOM이라 관찰 필요(ContainerMemoryNearLimit이 backstop).
  ⚠️ **이 네 판정은 무효다(2026-08-31).** 측정 지표인 working_set이 커널 정의상
  `memory.current − inactive_file`이라 **active_file(활성 clean page cache)을 분자에 싣는다** — 회수 가능한
  캐시가 실사용으로 계상된다(PR #564: 같은 결함이 ContainerMemoryNearLimit을 위양성 발화시켰고, 알림 분자는
  `usage − total_inactive_file − total_active_file`로 교체됐다). 같은 분자로 14일 peak를 소급 재측정한 결과
  (vmsingle retention 30d + cadvisor keep-list 부재로 과거 구간이 그대로 남아 있다):

  | 워크로드 | 원장 판정 | limit | WS peak 14d | **A′ peak 14d** | **A′ 마진** |
  |---|---|---|---|---|---|
  | cnpg-operator | 1.05x "near-OOM" | 160 | 36.2 | **36.2** | **4.42x** |
  | homepage | 1.19x | 192 | 159.4 | **95.4** | **2.01x** |
  | glances | 1.14x | 128 | 113.6 | **86.3** | **1.48x** |
  | traefik | 1.14x | 192 | 126.0 | **31.5** | **6.10x** |

  ⇒ traefik·cnpg-operator는 판정이 **완전히 뒤집힌다**. homepage만 2.0x에서 간신히 살아남고, glances는
  방향이 반대로 뒤집혀 오히려 **마진 부족**이다(1.48x — 축소 금지는 유지되나 근거가 "캐시 오염"이 아니라
  "실제 여유 부족"으로 바뀐다).
  ⚠️ **cnpg-operator는 지표 결함으로 설명되지 않는다** — WS와 A′가 36.2로 동일해 캐시 charge가 0이다.
  2026-07-06의 153Mi는 오늘 working_set으로도 재현되지 않는다. 그 사이 기판이 OrbStack VM(6코어)에서
  베어메탈 NUC(14코어)으로 통째로 바뀌었고, `infra/k3s-bootstrap/versions.env`가 "GOMAXPROCS 미핀 →
  Go 프로세스 RSS 기준선이 조용히 달라진다. 핀할지 원장을 재기준선할지는 **미결정(D-e)**"을 기록해 뒀다.
  ⚠️ **이 표의 A′도 `[14d:5m]`으로 잰 값이라 과소평가다**(2026-09-01 3차 정정 — 규약 절 「서브쿼리 step」).
  `[14d:30s]`로 다시 재면 cnpg-operator 36.2 → 41.1 · homepage 95.4 → **96.6** · glances 86.3(동일) ·
  traefik 31.5 → 32.5다. homepage는 이로써 **2.01x → 1.99x로 다시 뒤집혀** 규약 미달이 되었고,
  이번에 192 → 208Mi로 올렸다. 나머지 셋은 판정 방향이 바뀌지 않는다.
  ⇒ **이 표는 정정 근거일 뿐 새 limit이 아니다.** 행 값 회수는 (i) 마진 규약 확정과 (ii) 기판 재기준선(D-e)이
  선행해야 한다 — 아래 「마진 규약 미정」 참조.
- ⚠️ **마진 규약(2026-08-31 확인 → 2026-09-01 owner 확정).** 위 판정이 인용하던 `F23`·`F24`·`F25`는
  **정의가 레포 어디에도 없었다** — 전수 검색의 실 히트가 이 파일의 인용 3곳뿐이었고, 같은 블록 안에서
  임계가 2.0x·1.5x·1.3x로 갈려 있었다. owner가 **2.0x**로 확정했다. 이제 이 파일이 그 정의의 SSOT다.

  ### 마진 규약 (SSOT — 2026-09-01 owner 확정)

  **`limit ≥ A′ peak(14일, 파드-세대 붕괴, 서브쿼리 step ≤ 스크레이프 간격) × 2.0`**, 16Mi 단위 올림.

  ⚠️ **2026-09-01 정정**: 이 규약의 최초 측정은 `[14d:5m]`을 썼는데 cadvisor 스크레이프가 **30초**라
  샘플 10개 중 9개를 버렸다. 아래 「서브쿼리 step」 항목이 그 결과를 계상한다 — 현행 측정은
  **`[14d:30s]`**다. 아래 마커가 그 step의 기계 판독 SSOT이고,
  `tests/gates/test_verify-ledger-ssot.bats`가 스크레이프 간격과의 정합을 강제한다.

  <!-- ledger:subquery-step=30s -->

  - **A′ 분자** = `container_memory_usage_bytes − container_memory_total_inactive_file_bytes
    − container_memory_total_active_file_bytes`. working_set을 쓰지 않는 이유는 위 무효 표시 항목과
    `platform/victoria-stack/prod/rules/core.yaml`의 `ContainerMemoryNearLimit` 주석이 논증한다.
  - **파드-세대 붕괴**(`max by (namespace, container)`)가 필수다. 없이 `sum by (namespace)`를 하면 14일간
    생성된 모든 파드 세대가 합산된다 — CronJob은 10분마다 새 파드라 수천 개가 더해져 합계가 limit을
    넘는 무의미한 수가 나온다(2026-09-01 실측: observability 1348 → 3427).
  - **`max_over_time`은 전체 식에 한 번** 건다. 세 메트릭에 따로 걸면 서로 다른 시점의 peak를 빼게 된다.
  - ⚠️ **서브쿼리 step은 스크레이프 간격 이하여야 한다.** `[14d:5m]`은 5분 격자의 각 점에서 lookbehind
    마지막 값 하나만 취하므로, 30초 스크레이프에서는 **샘플의 90%를 버린다**. peak는 정의상 격자에
    걸릴 확률이 낮은 점이라 이 손실이 곧바로 과소평가가 된다(2026-09-01 실측, 5m → 30s):
    repo-server 70.2 → **112.5Mi(+60.3%)** · adguard 79.0 → **124.4Mi(+57.5%)** ·
    plugin-barman-cloud 107.5 → **152.5Mi(+41.9%)** · application-controller 461.5 → **488.2Mi(+5.8%)**.
    짧은 버스트를 가진 워크로드일수록 손실이 크다 — repo-server의 렌더 버스트와 adguard의 블록리스트
    갱신은 5분 격자에 **한 점도 걸리지 않았다**. 현행 스크레이프 간격은 30초이므로
    (`platform/victoria-stack/prod/vmagent-scrape-config.yaml`, job override 없음) **`[14d:30s]`**를 쓴다.
    `15s`로 낮춰도 결과가 같음을 확인했다 — 즉 30s가 전 샘플을 포착한다. 스크레이프 간격을 바꾸면
    이 step도 함께 바꿔야 한다.
  - ⚠️ **`limit == req`로 착지하지 않는다.** peak×2.0이 `req`보다 작으면 목표를 고른 것은 마진이 아니라
    `policy/ledger.rego`의 `limit ≥ req` 하한이다. 그대로 두면 버스트 헤드룸이 0이 되고 QoS가
    Burstable → Guaranteed로 바뀐다 — 회수의 의도가 아닌 부수효과다. 그런 행은 `req` 위에 헤드룸을
    남기거나(권장), `req`를 함께 재산정하는 별도 결정으로 넘긴다.
  - ⚠️ **행이 여러 컨테이너를 묶으면 행 마진이 컨테이너 안전을 함의하지 않는다.** OOMKill은 cgroup 단위,
    즉 컨테이너별로 난다. 행 전체가 2.0x여도 그 안의 하나가 1.0x일 수 있고, `ledger.rego`는 행 합계만
    보므로 잘못된 배분을 잡아주지 못한다. 다중 컨테이너 행은 **컨테이너별 A′ peak 없이 회수하지 않는다.**
  - **peak는 "지금 살아남고 있는 값"이지 "충분한 값"이 아니다.** 아래 vector/vlogs 항목이 논증하듯
    버스트 크기는 장애 지속시간에 비례하고, 14일 창에 그 장애가 없었다면 그 창은 버스트에 무증인이다.
    간헐적으로만 밟히는 경로(업로드·복구·재색인)를 가진 워크로드는 창이 그 경로를 대표하는지 먼저 물을 것.

  ### 관측 스택 마진 규약 (자기조절 클래스 — 2026-09-01 확정)

  **`limit ≥ RSS peak(현 기판 창, 30초 해상도, 파드-세대 붕괴) × 1.5`**, 16Mi 단위 올림.

  **적용 대상**: `observability`의 `vmagent`·`vmsingle`·`grafana`·`glances`·`victorialogs` 5개.
  **적용 조건**: ⭐ **`shmem == 0`을 cgroup `memory.stat` 직독으로 확인한 경우에만.**

  #### 왜 A′ × 2.0을 쓰지 않는가

  A′는 `usage − inactive_file − active_file`이라 **회수 가능한 커널 slab을 분자에 싣는다.**
  그 비중이 이 다섯에서 100배 넘게 갈린다(2026-09-01 cgroup 직독):

  | | vmagent | vmsingle | grafana | glances | victorialogs |
  |---|---|---|---|---|---|
  | `slab_reclaimable` / A′ | **0.2%** | 3.8% | 20.2% | 9.1% | **27.1%** |
  | 회수 불가 / limit | 75.2% | 70.8% | 61.2% | 64.2% | **27.8%** |

  ⇒ **같은 배수가 서로 다른 안전을 뜻한다.** vmagent의 A′는 사실상 순수 anon이고(slab 0.3Mi),
  victorialogs의 A′는 27%가 커널이 언제든 내놓을 수 있는 캐시다. 그리고 결정적으로
  ⚠️ **peak 시점의 slab 비중은 소급 측정이 원리적으로 불가능하다** — cadvisor는 cgroup v2 +
  containerd에서 커널/slab 계열을 채우지 않는다(`container_memory_kernel_usage`가 5개 전부
  `max_over_time([14d:30s]) = 0`). 즉 "A′에서 slab을 빼자"는 처방은 라이브 스냅샷으로만 가능하고
  시계열이 없어 규약이 될 수 없다.

  #### 왜 RSS가 여기서는 안전한가 (그리고 언제 안전하지 않은가)

  ⚠️ 원장은 「분자를 `container_memory_rss`(anon)로 내리는 처방은 금지」를 명시한다 — cgroup v2의
  anon은 **shmem을 제외**하므로 `shared_buffers`로 limit을 채우는 cnpg 행이 무성 지대에 들어가기
  때문이다(PR #564가 설계로 배제, `rules/core.yaml:70-75`가 실측으로 논증).
  **그 금지는 유효하며 이 규약이 뒤집지 않는다.** 다만 그 위험은 `shmem > 0`일 때만 성립하고,
  이 다섯은 **전부 `shmem = 0`**이다(`memory.stat` 직독: `shmem 0`·`shmem_thp 0`·`zswapped 0`).
  게다가 이 노드는 `node_memory_SwapTotal_bytes = 0`이라 **anon은 전량 회수 불가**다.
  검산: A′ ≈ anon + kernel (vmagent 169.6 ≈ 166.3+2.5 · grafana 197.3 ≈ 152.7+43.8 · vlogs 99.3 ≈ 69.0+29.1).

  ⇒ 그래서 **`shmem == 0` 확인이 적용 조건**이다. 이 규약을 다른 워크로드로 넓히려면 그 컨테이너의
  `shmem`을 먼저 재야 한다. 조건 없이 복사하면 그것이 곧 #564가 막은 함정의 재발이다.

  #### 왜 배수가 1.5인가

  RSS는 회수 불가분만 재므로, 회수 가능분까지 포함한 A′와 같은 안전을 얻는 데 더 작은 배수로 충분하다
  (실측 A′/rss = 1.02~1.41). 1.5의 근거는 **이 레포에서 실제로 일어난 OOM에서 역산**한다:
  2026-08-14 victorialogs가 `limit 128Mi`에서 **anon-rss ~129MiB**로 OOMKill 루프를 돌았다(원장 상단
  기록). 그 시점 peak에 1.5를 적용하면 129 × 1.5 = 193.5 → 208Mi로, 실제 처방(256Mi)보다 작지만
  **그 사고를 막았을 값**이다. 관측된 steady→peak 버스트 폭이 최대 1.74x(vlogs)인 것과도 정합한다.

  #### ⚠️ limit에 비례하는 설정을 **둘 다** 끊는다 — 자기참조의 두 경로

  자기참조는 **두 경로**로 산다. 하나만 끊으면 나머지로 되살아난다.

  **① 힙 — `GOMEMLIMIT`을 연동하지 않는다.** 원장의 다른 규약(「대형 Go 컨트롤러는 GOMEMLIMIT을
  limit의 90%로 연동」)을 이 클래스에 적용하면 limit 상향이 곧 힙 예산 상향이 된다.
  ⇒ **고정한다**(vmagent 200MiB · vmsingle 800MiB 유지). 사용률이 75.0%·73.4%로 상한에 닿지 않았고,
  `tools/check-resource-limits.ts`의 `≤ limit × 0.95`는 넉넉히 통과한다.

  **② 캐시 — `--memory.allowedPercent`를 `--memory.allowedBytes`로 바꾼다.** ⭐ 이것이 처음에
  놓쳤던 절반이다. `allowedPercent=60`은 **limit에 비례**하므로 vmsingle을 896 → 1056Mi로 올리면
  캐시 예산이 537.6 → 633.6Mi로 96Mi 따라 커진다. 그리고 ⚠️ **`GOMEMLIMIT`은 이것을 막지 못한다** —
  VictoriaMetrics의 fastcache는 mmap 할당이라 **Go 힙 밖**에 살기 때문이다(원장 상단 victorialogs
  항목이 실측으로 논증: "GOMEMLIMIT은 힙 소프트 리밋이라 이것을 못 막는다 — 115MiB가 걸린 채 죽었다").
  ⇒ 종전 예산을 **절대값으로 못박는다**: vmagent `141033472`(=134.4Mi) · vmsingle `563714457`(=537.6Mi).
  플래그 존재는 라이브에서 확인했다(`flag{name="memory.allowedBytes"}` — 종전 `is_set=false`, 값 0).

  ⚠️ **두 경로를 다 끊어도 산술적으로는 여전히 초과 가능하다**: vmsingle의 힙 상한(800MiB) + 캐시
  예산(537.6Mi) = 1337.6Mi > limit 1056Mi. 둘 다 최대에 닿으면 OOM이다. 실측은 힙 73.4% · 캐시
  33.8%로 동시 최대가 관측된 적이 없고, 캐시 "사용량" 181.8Mi 중 128Mi는 fastcache의 32Mi 바닥값
  4개(tsid·metricIDs·metricName·tagFiltersLoops가 **정확히** 32.00Mi)라 실 내용물은 ~54Mi다.
  이 초과는 **오버서브스크립션을 의도적으로 허용한 것**이며, 그 사실을 여기 계상한다 —
  두 상한의 합을 limit 아래로 눌러 담으려면 캐시 예산을 크게 깎아야 하고 그것은 질의 지연으로
  전가된다(`promql/rollupResult`가 대시보드·vmalert 질의 결과 캐시다).

  #### ⚠️ 창은 기판 변경을 가로지르지 않는다

  `node_boot_time_seconds = 2026-08-26T13:41:06Z`. 그 재부팅에서 다섯 전부 계단이 있었고
  (vmagent A′ 일별 peak 200~213 → 159~171, vmsingle rss 552 → 350), 14일 창은 **두 체제를 한 숫자에
  섞는다.** 원장이 적었던 `vmagent 1.05x`가 정확히 그 산물이다 — 그 값은 재부팅 전 세대의 것이고
  현 기판에서는 1.33x다. 기판이 바뀌면(노드 재부팅·커널·런타임 메이저) 창을 그 이후로 자른다.

  #### 적용 결과 (2026-09-01)

  | 워크로드 | RSS peak(현 기판) | ×1.5 | 종전 | 현행 | 판정 |
  |---|---|---|---|---|---|
  | `vmagent` | 168.5Mi | 252.8 | 224Mi | **256Mi** | 상향(1.33x → 1.52x) |
  | `vmsingle` | 694.9Mi | 1042.3 | 896Mi | **1056Mi** | 상향(1.29x → 1.52x) |
  | `grafana` | 149.5Mi | 224.2 | 256Mi | 256Mi | 유지(1.71x) |
  | `glances` | 76.7Mi | 115.1 | 128Mi | 128Mi | 유지(1.67x) |
  | `victorialogs` | 107.6Mi | 161.4 | 256Mi | 256Mi | 유지(2.38x) |

  ⚠️ **이 규약은 하한이다 — 만족하는 행을 깎는 근거가 아니다.** 특히 `grafana`는 knob이 하나도 없어
  (allowedPercent도 GOMEMLIMIT도 없는 Go 기본 GOGC) limit을 낮추면 자기조절로 흡수되지 않고 그대로
  OOM 위험으로 전가된다. `victorialogs`는 2.38x로 여유가 커 보이지만 **14일 rss peak 119.8Mi가
  2026-08-14 OOM 지점(129MiB)의 93%**다 — 지금 사는 이유는 워크로드가 줄어서가 아니라 limit이
  128 → 256Mi로 두 배가 됐기 때문이다. 둘 다 회수 대상이 아니다.

  #### 남은 관측 (침묵시키지 않는다)

  - **`grafana`가 limit에 붙어 있는 것은 고장이 아니라 평형이다.** `memory.current/max = 99.3%`이고
    `memory.peak == memory.max`, `memory.events max=8`이지만 `oom_kill = 0`이고 회수 가능분이
    96.8Mi(file 57.0 + slab_reclaimable 39.8)다. 커널이 그것으로 limit을 채워 두고 필요할 때 뺏는다
    (138시간 동안 `pgsteal_direct` 240215 페이지 ≈ 938Mi 회수). PSI `full total = 129,815µs`는 가동
    시간의 **0.000026%**이고 카운터는 현재 동결 상태다 — 압력은 에피소드성이지 진행형이 아니다.
  - ⚠️ **그 압력은 현재 수집되는 어느 메트릭에도 보이지 않는다.** cadvisor `container_memory_failcnt`는
    cgroup v1 전용 필드라 5개 전부 0이고, v2의 `memory.events.max`를 반영하지 않는다. 압력을 알림으로
    쓰려면 별도 공급원이 필요하다(미착수).
  - **압력 순서는 배수 순서와 어긋난다**: PSI 누적으로 grafana 129,815µs ≫ glances 1,956 > vlogs 288 >
    vmsingle 72 > **vmagent 0**. 배수가 가장 나빴던 vmagent는 메모리 압력을 한 번도 겪지 않았다.
    이 어긋남이 "배수는 대리 지표일 뿐"이라는 이 절 전체의 논거다.
  - **`vm_cache_size_bytes`를 노출하는 것은 vmsingle 하나뿐이다**(vmagent·victorialogs는 0건).
    즉 `allowedPercent` 예산 대비 실제 캐시 사용량을 잴 수 있는 워크로드가 셋 중 하나다 —
    예산 기반 모델을 세우려면 이 계측 공백부터 메워야 한다.
  - **측정 창의 구멍**: 2026-08-31 08:30Z~13:00Z 약 4.5시간 cadvisor 샘플이 없다
    (`count_over_time(...[1h])`가 120 → 28 → 결측 → 103). 그 구간의 peak는 관측되지 않았다.

  ### 회수 보류 행 (2026-09-01 조사 — 침묵시키지 않고 계상한다)

  2.0x 확정 직후 10개 행을 조사한 결과 **6행이 보류**다. 각 사유는 "나중에 하자"가 아니라 **무엇이
  갖춰져야 할 수 있는지**를 적는다. 근거 없이 숫자를 넣으면 그 숫자가 곧 CI가 묶인 SSOT가 된다.

  | 행 | 보류 사유 | 풀리는 조건 |
  |---|---|---|
  | `cnpg` | 목표가 **산술적으로 불가능**하다. Cluster limit을 772Mi로 만들어야 하는데 requests가 768Mi이고, `platform/cnpg/prod/test_cluster_params.bats`가 계약으로 고정한 `shared_buffers(244.1Mi) ≤ limit/4`가 깨진다. 불변식을 지키는 하한은 977Mi라 **실제 회수 상한은 32Mi**다. 원장이 두 번 보호를 명시한 행이기도 하다 | PostgreSQL 튜닝 변경(= 회수가 아닌 별개 작업)이거나, 32Mi만 회수 |
  | `tailscale` | 행이 operator + proxy×2 **세 컨테이너**다. 목표대로면 각 64Mi인데 `proxyclass.yaml:5`가 기록한 proxy peak 116Mi 하나로 1.8배 초과다. `ts-traefik-ts`는 **내부 인입의 유일 경로**라(AGENTS.md 규약) 죽으면 `*.home` 전체가 tailscale·LAN 양쪽에서 끊긴다 | 컨테이너별 A′ peak + proxy 대수 변동(현재 `loadBalancerClass: tailscale` 서비스 2개에 연동) 반영 |
  | `edge` | adguard의 192Mi는 **OOM 대응 상향**이다(`peak 123/128(96%)·블록리스트 성장 → 선제 상향`, 커밋 f1f23e8). 목표 208을 맞추려 −80을 adguard에서 빼면 112가 되어 **그 OOM을 유발했던 128보다 낮다**. cloudflared는 자기 주석이 이미 2.0x 미달(`peak 51Mi × 2.0 = 102 > 96`)이라고 말한다 | 블록리스트 성장을 반영한 adguard 단독 A′ 재측정 |
  | `argocd` | 컨테이너 **6개** 집계. OOMKill은 cgroup 단위인데 −112Mi를 어디서 뗄지 근거가 없다. 옛 비율로 나누는 우회는 그 비율의 출처가 바로 무효화된 working_set이라 성립하지 않는다 | controller/repoServer/server/applicationSet/notifications/redis **각각**의 A′ peak. GOMEMLIMIT 4곳이 limit의 90%로 걸려 있어 함께 움직여야 한다 |
  | `cert-manager` | 컨테이너 **3개** 집계, 같은 배분 근거 부재. 옛 비율(cainjector 101 : controller 96 : webhook 69)은 컨테이너마다 캐시 charge가 달라(controller는 WS의 약 2/3가 캐시) 왜곡돼 있다 | controller/cainjector/webhook 각각의 A′ peak |
  | ~~**관측 스택 5개**~~ | ✅ **해소(2026-09-01 4차)** — 위 「관측 스택 마진 규약」이 이 클래스의 SSOT다. A′가 회수 가능 slab을 분자에 싣는데 그 비중이 0.2~27.1%로 100배 갈리고 peak 시점 값은 소급 측정이 불가능하다 ⇒ 분자를 RSS(=anon, 이 다섯은 `shmem = 0`·스왑 0이라 전량 회수 불가)로 바꾸고 배수를 1.5로 낮췄다. 자기참조는 **GOMEMLIMIT을 limit에 연동하지 않는 것**으로 끊었다. vmagent 224→256 · vmsingle 896→1056 상향, 나머지 셋은 규약 충족으로 유지 | — |
  | `cache-trip-mate` | A′ 22.4Mi는 작업집합이 아니라 **트래픽 부재**를 잰 값이다 — 소비처 `trip-mate-api`가 2026-08-12(#456)에 철거돼 키스페이스가 비어 있다. 게다가 이 행의 limit은 애초에 working_set이 아니라 `maxmemory 64mb + BGSAVE fork COW + 단편화 + 클라이언트 버퍼` **유도값**이라 이번 지표 정정의 대상이 아니다 | 소비처가 다시 붙어 LRU가 채워진 뒤의 재측정. 또는 리소스 자체의 존치 판단 |

  ⇒ 공통 갭이 하나 보인다: **다중 컨테이너 행에 컨테이너별 A′가 없다.** 4행(`argocd`·`cert-manager`·
  `edge`·`tailscale`)이 같은 이유로 막혔다. 이 원장이 행 단위인 것은 예산 회계로는 옳지만, OOM은
  컨테이너에서 나므로 회수 판단에는 한 단계 더 낮은 해상도가 필요하다.
- **owner 결정(2026-07-07, F23 게이트): (b) VM RAM 증설 확정** — right-size로 ≥256 불가 확정에 따라 VM
  증설이 온보딩 차단의 유일 실효 해소책으로 채택. 착수 = W2 병행 owner-local 태스크(VM 재시작 필요):
  ~~`infra/k3s-bootstrap/versions.env` ORB_MEMORY_MIB~~(베어메탈 이전으로 삭제) 11264→12288 + 이 원장 meta VM_ALLOCATABLE_MIB
  11264→12288·LIMIT_BUDGET_MIB 9216→10240(reserve 2048 유지). 반영 후 명목 잔여 ≈ 1028Mi(온보딩 차단 해소).
  ⚠️ config 변경은 VM resize와 **커플링** — VM 재시작 전 cap 선행 상향 시 page-cache/burst 리저브 침식이라,
  cap 상향은 VM 재시작 후에만 적용했다(resize와 동일 커밋). 동시 peak ≪ allocatable라 노드-OOM 안전.
- **적용(2026-07-08): VM 12 GiB 증설 완료·라이브 검증.** ⚠️ **아래 문단은 OrbStack VM 시절의 역사 기록이다 — 2026-08 베어메탈 NUC 이전으로 `orb config set`·"호스트 Mac RAM 16 GiB" 제약은 더 이상 적용되지 않는다(현행 기판은 `infra/k3s-bootstrap/`).** `orb config set memory_mib 12288` + OrbStack 재기동 →
  노드 capacity 11→12 GiB(12306288Ki)·allocatable 9738→10744 Mi 확인, 23/23 앱 Synced/Healthy 회복(root health
  롤업 지연 ~100s 후 자가 해소), 파드 낙오 0. cap 9216→10240 동반 상향(reserve 2048 유지) → 명목 잔여
  10240−9212 = 1028Mi(온보딩 차단 해소). ⚠️ **호스트 Mac RAM 16 GiB** — 12 GiB 할당은 macOS에 4 GiB만 남겨
  타이트하다(`orb start`가 한 번 타임아웃 후 정상 기동, 부하 시 스왑 주의). 추가 VM 증설은 호스트 16 GiB가
  상한 — VM 12 GiB가 실질 최대(그 이상은 하드웨어 교체).

(디스크 위치 참고, 2026-07-08 W3: vmsingle TSDB·victorialogs 데이터는 내장 standard VCT → **외장 bulk-ssd
standalone PVC `vmsingle-data-bulk`·`vlogs-bulk`**로 이전 — 메모리 예산과 무관하며 이 원장의 계상 대상 아님.
디스크 가드는 r4 `BulkStorageLow`(in-cluster)와 호스트 백업 유닛의 df push(2026-08-19 리눅스 재작성 —
`files-data-backup.timer` → scripts/backup-files-data.sh, 국면 A 동안은 미-enable)가 담당, 절차는
runbooks/observability-bootstrap.md §5.)

한 행은 라이브 pod limit보다 **의도적으로 크다**: `k3s+os+coredns`(OS/커널 비-pod reserve — 실 coredns
pod만 ~170Mi). (`edge`·`cnpg` limit 보수 버퍼는 2026-06-22 right-size에서 라이브 정합 회수 — 단 `edge`
req는 176으로 stale하게 남아 있어 2026-07-06 실측(adguard 48 + cloudflared 48 = 96)으로 정정(−80 req);
`cert-manager`· tailscale proxy는 무제한이었으나 같은 날 거버넌스 캡 신설해 예산에 편입.) 따라서 명목
잔여(10240−9020 = 1220)는 실 헤드룸을 과소표현한다
(2026-06-22 실측 동시 peak ≈ 6586 ≪ allocatable ~10744 — 그 뒤 앱 철거로 더 내려갔다).
더 많은 명목 헤드룸이 필요하면 (a) 상주 워크로드를 라이브 peak 실측에 맞게 right-size해 limit을 회수한다
(2026-06-22 observability/argocd/edge/cnpg 808Mi 회수; postgres·최근 OOM 수정분은 보호. 2026-07 B10에서
sealed-secrets 128→96·vmsingle 1Gi→896으로 −160Mi 추가 회수, 명목 잔여 196→356(당시 ≥256 온보딩 차단 해소 —
이후 2026-07-06 cnpg-operator +160·tailscale +192로 4Mi까지 재소진, 위 2026-07-06 항목 참조). repo-server는
라이브 peak 271.75Mi(렌더 버스트, 앱 수에 비례 증가)로 288 축소가 1.06x라 UNSAFE → 보류(384 유지)).
(b) cap 상향은 10240까지 적용됨(VM 12 GiB, 2026-07-08) — page-cache/burst reserve 2048 보호 위해 10240 초과는 금지.
그 이상의 물리 헤드룸은 VM RAM 증설(VM_ALLOCATABLE_MIB 동반 상향)뿐이나 호스트 Mac RAM 16 GiB가 상한이라 VM
12 GiB가 실질 최대다(그 이상은 하드웨어 교체). 모두 노드-OOM 안전(동시 peak ≪ allocatable).
주의: 행은 라이브 manifest와 자동 교차검증되지 **않는다 — 단 하나, `homepage`만 예외다**
(`platform/homepage/prod/test_homepage_deployment.bats`가 이 표에서 limit을 읽어 매니페스트와 대조한다.
2026-09-01 3차에서 그 @test가 상수 192Mi를 박고 있어 원장 정정에 red를 냈고, 이름값(`matching the
ledger`)을 하도록 원장 파서 대조로 고쳤다. 다른 행에 같은 대조는 없다). verify:ledger는 마크다운만; local-helm traefik 등은
check-resource-limits 스캔 밖이라 여기 수기 계상). 신규/변경 상주 워크로드는 반드시 행+산문 동반 갱신.

2026-08-14: observability 행 상향(limit 2080→2400 **+320**, req 1152→1184 **+32**) — NUC 콜드스타트에서
`victorialogs`(128→256Mi)와 `vector`(320→512Mi)가 실제로 OOMKilled 루프를 돌았다(2시간에 각 16회·22회).
근거는 커널 OOM 기록의 anon-rss(vlogs ~129MiB · vector ~325MiB)이고, 두 값 모두 limit에 정확히 붙어
있었다 — 누수가 아니라 작업집합이다. **코어 수(GOMAXPROCS/--threads)를 원인으로 본 최초 진단은
반증됐다**: 핀을 넣어 vector 워커를 15→8로 줄였는데 OOM anon-rss는 그대로였다(핀 자체는 위생 조치로
유지). vlogs 쪽이 1차 원인이고 vector는 sink 백프레셔로 끌려 죽는 결합 루프였다.
✅ **2026-08-15 재기준선 완료 — 회수하지 않기로 했다.** 버스트가 걷힌 뒤 **27시간 steady** 구간을
NUC에서 cgroup으로 실측했다(`memory.current`/`memory.peak`, 컨테이너 시작 2026-08-14T05:34Z):

| | steady(current) | **peak** | limit | peak/limit |
|---|---|---|---|---|
| `vector` | 71 Mi | **418 Mi** | 512 Mi | 82% |
| `victorialogs` | 75 Mi | **181 Mi** | 256 Mi | 71% |

steady만 보면 7배 과다로 보이지만 **peak가 판단 기준이다.** 이 원장은 스스로 적었듯 limit 합이
*동시-peak 상한*이고, 위 peak는 **현재 limit으로 실제 백로그 버스트를 겪으며 살아남은 값**이다.
⚠️ 그리고 **버스트 크기는 장애 지속시간에 비례한다** — 418 Mi는 17시간 장애가 만든 것이고 더 긴
장애면 더 크다. peak 위 여유(vector 94 Mi · vlogs 75 Mi)는 낭비가 아니라 **더 나쁜 장애에 대한
보험**이며, steady에 맞춰 깎으면 관측이 가장 필요한 순간에 파이프라인이 죽는다.
⚠️ vlogs는 깎으면 **캐시 예산도 같이 준다**(`-memory.allowedPercent=60`이 limit에 비례).
⚠️ `go_memstats_heap_sys`(166 MB)를 RSS로 읽지 말 것 — Go가 예약만 하고 반납 안 한 주소공간이다
(실제 RSS 66.8 MB).

명목 잔여 = 10240 − 9164 = **1076 Mi(11%)** — 신규 온보딩을 막는 수준이 아니다.
(2026-09-01: 2.0x 규약 확정 후 4행 회수 −256Mi로 1220 → 1476. traefik 192→96 · sealed-secrets 96→48 ·
files 128→64 · cnpg-operator 160→112.
2026-09-01 2차: **컨테이너별 A′ 측정**으로 보류가 풀린 2행 −384Mi로 1476 → 1860. cert-manager 384→224
(controller 80 · cainjector 96 · webhook 48) · argocd 1472→1248. ⚠️ argocd는 순 회수가 아니라 **재배분**이다 —
application-controller는 A′ 450.4Mi 대비 640Mi가 **1.42x로 규약 미달**이라 768Mi(1.70x)로 상향했고,
repo-server 384→144 등 나머지 회수가 그것을 상쇄한다. 행 마진 2.19x 안에 1.42x가 숨어 있던 것이
「행 마진은 컨테이너 안전을 함의하지 않는다」의 실증이다. edge·tailscale도 컨테이너별 측정으로
보류가 풀렸고 각각 별도 PR로 착지했다 — edge 288→224(#572) · tailscale 512→304(operator 80 + proxy 112×2).
2026-09-01 3차 — **측정 해상도 결함 정정(+496Mi)**: 위 회수 전부가 `[14d:5m]` 서브쿼리로 잰 peak
위에 서 있었는데, 그 step이 30초 스크레이프의 90%를 버린다(규약 절 「서브쿼리 step」 참조).
`[14d:30s]`로 재측정하니 **12개 컨테이너가 2.0x 미달**이었고, 그중 둘은 같은 날 회수가 만든
**회귀**였다 — adguard 160(1.29x·#572) · repo-server 144(1.28x·#571). 자기조절 워크로드 5개
(vmagent·vmsingle·grafana·glances·victorialogs — `--memory.allowedPercent`/`GOMEMLIMIT`이 limit에
비례해 peak도 따라 오르므로 배수 규약이 자기참조가 된다)를 제외한 **7개를 2.0x로 맞췄다**:
adguard 160→256 · repo-server 144→240 · application-controller 768→992 · tailscale proxy 112→128(×2대) ·
cert-manager-webhook 48→64 · homepage 192→208 · kube-state-metrics 64→80.
application-controller는 이로써 **단계적 상향이 완성**됐다(1.57x → 2.03x) — 30초로 재면 14일 일별
peak가 376~488Mi로 **전 구간 규약 미달**이었고, 재시작 종료 스파이크가 아니라 정상 진동 상단이다.
최종: 9020 → 8108 → **8604**, 명목 잔여 1220 → 2132 → **1636**. 남은 보류는 cnpg(계약상 회수 상한 32Mi)와
cache-trip-mate(A′가 트래픽 부재를 잰 값), 그리고 자기조절 5개(D-e 재기준선 대상)다.)
✅ **미계상 상주 컨테이너 2개 — 해소(2026-09-01 4차, +368Mi).** 3차 조사에서 이 원장 어느 행에도
잡히지 않으면서 limit·request가 아예 없던 상주 컨테이너 둘을 캡하고 행에 편입했다.

| 컨테이너 | A′ peak(30s) | 캡 | 선언 위치 | 행 |
|---|---|---|---|---|
| `database/pg-1/plugin-barman-cloud` (네이티브 사이드카) | 152.5Mi | **320Mi**(2.10x) / req 32Mi | `platform/cnpg/prod/object-store.yaml` — `spec.instanceSidecarConfiguration.resources` | cnpg 1152→**1472** |
| `cnpg-system/barman-cloud` (Deployment) | 19.3Mi | **48Mi**(2.49x) / req 24Mi | `platform/cnpg/barman-plugin/kustomization.yaml` (patch — 벤더 manifest 무수정) | cnpg-operator 112→**160** |

**세 가지가 함께 필요했다**(어느 하나만 하면 무의미하거나 해롭다):
1. **1급 필드 경로.** 사이드카는 `Cluster.spec.plugins[]`가 주입하지만 그 리스트에는 resources 필드가
   없다(`kubectl explain cluster.spec.plugins` → enabled/isWALArchiver/name/parameters뿐). 캡의 경로는
   plugin v0.13.0의 `ObjectStore.spec.instanceSidecarConfiguration.resources`뿐이고, 그 소비 파일은
   **레포 소유**다 — 3차가 "벤더 파일이라 patch 경로 선행"이라 적은 것은 이 절반에서 틀렸다.
2. **알림 분모.** 네이티브 사이드카(`restartPolicy: Always`인 initContainer)의 limit을 KSM은
   `kube_pod_init_container_resource_limits`로 내보낸다. `ContainerMemoryNearLimit`의 분모를 두 계열의
   `or`로 넓히지 않으면 캡은 **"무캡·무알림"을 "캡·무알림·조용한 OOMKill"로 바꾼다.**
3. **게이트의 프리필터.** `tools/check-resource-limits.ts`는 `KINDS` 조회 **전에** `KIND_RE`로 파일을
   거른다. `KINDS`에만 ObjectStore를 더하면 그 파일은 열리지도 않고 스캔 카운트도 안 늘어 게이트가
   0건을 검사하고 초록을 낸다 — 뮤테이션으로 재현했다(스캔 21 → 20, 초록). 둘을 함께 넓혔다.

⚠️ **캡 값의 창 의존성.** 사이드카 peak는 매일 03:00Z 베이스백업이 만들고, 같은 연산이 62~152Mi로
2.5배 흔들린다. 그리고 그 창이 대표하는 것은 **PGDATA 49MB짜리 현재 데이터량**이다 — DB가 자라면
재측정이 필요하다. 2.0x가 이 행에서는 넉넉한 값이 아니다.
⚠️ **`args`는 kustomize patch로 건드리지 않는다.** core/v1 `Container.args`는 patchMergeKey 없는
atomic []string이라 strategic-merge가 리스트를 통째로 교체한다(실측: `operator` 서브커맨드와 TLS 경로가
전부 사라져 기동 불가). 그 이유가 `platform/cnpg/barman-plugin/kustomization.yaml` 헤더에 있다.

**회수를 다시 검토할 조건**: 잔여가 수십 Mi까지 떨어질 때. 그때도 limit을 깎기 전에 **버스트 자체를
줄이는 쪽**(vector sink `request.concurrency` 고정)을 먼저 볼 것 — 미검증이므로 넣으면 반드시
같은 지표를 다시 재라(`docs/traps-detail.md`의 "상주 워크로드 OOM 진단").

<!-- ledger:meta VM_ALLOCATABLE_MIB=12288 LIMIT_BUDGET_MIB=10240 -->

| component                          | namespace      | req_mi | limit_mi |
|------------------------------------|----------------|-------:|---------:|
| <!-- ledger:row --> k3s+os+coredns | kube-system    |   1075 |     1740 |
| <!-- ledger:row --> argocd         | argocd         |    640 |     1568 |
| <!-- ledger:row --> cnpg           | database       |    932 |     1472 |
| <!-- ledger:row --> cnpg-operator  | cnpg-system    |    124 |      160 |
| <!-- ledger:row --> cert-manager   | cert-manager   |     88 |      240 |
| <!-- ledger:row --> observability  | observability  |   1184 |     2608 |
| <!-- ledger:row --> edge           | edge           |     96 |      320 |
| <!-- ledger:row --> tailscale      | tailscale      |    192 |      336 |
| <!-- ledger:row --> whoami         | gateway        |     16 |       16 |
| <!-- ledger:row --> traefik        | gateway        |     64 |      96 |
| <!-- ledger:row --> sealed-secrets | sealed-secrets |     32 |       48 |
| <!-- ledger:row --> homepage       | homepage       |    128 |      208 |
| <!-- ledger:row --> glances        | observability  |     64 |      128 |
| <!-- ledger:row --> cache-trip-mate | cache          |     96 |      160 |
| <!-- ledger:row --> files          | files          |     32 |      64 |

**합계:** req 4707 Mi · limit 8108 Mi (반드시 ≤ 10240 Mi 유지).
(⚠️ 이 줄은 쓰기 경로(`tools/lib/ledger-totals.ts`의 `replaceTotals` — create-app/provision-cache/teardown-app)
만 갱신하고 **읽기 게이트는 검사하지 않는다**. 그래서 2026-08-14 observability 상향분이 반영되지 않은 채
`4675/8700`으로 남아 CI가 계속 초록이었다(2026-08-31 정정). 손으로 행을 고치면 이 줄도 함께 고칠 것.)
(`pg-tools`는 CronJob용 ops 이미지 — 일시적이므로 상주 워크로드 행이 없다. worker/web/console
values-only 예시는 외부 앱 레포 체제 전환과 함께 제거 — 새 앱은 온보딩 PR이 행을 추가한다.)

> **tailscale 행 = operator + proxy N대** — `loadBalancerClass: tailscale` 서비스 1개마다 operator가
> proxy StatefulSet(ts-*)을 1대 생성하고 defaultProxyClass(`resource-capped`)가 각 192Mi limit/64Mi req를
> 부여한다. 현재 LB 서비스 2개(traefik-ts=gateway·pg-rw-tailscale=database → proxy 2대). tailscale
> LoadBalancer 서비스를 추가/제거하면 **반드시** 이 행을 `operator(req 64/limit 128) + proxy(req 64/limit 192)×N`으로
> 재계산해 원장을 동반 갱신하라(proxy는 ProxyClass 생성 StatefulSet이라 check-resource-limits 스캔 밖 — 수기 계상).

## 갱신 방법
컴포넌트 추가/크기 조정: 해당 행의 `req_mi`/`limit_mi`를 수정하고(또는 행 마커
주석을 단 새 표 행을 추가하고) `bun run verify:ledger`를 실행한다.
CI가 모든 PR에서 같은 검사를 돌린다. OOM이 아니라 예산 경계에서 시끄럽게
실패한다.
