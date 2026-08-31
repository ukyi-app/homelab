# 진단: ContainerMemoryNearLimit이 glances에서 위양성 발화

- 슬러그: `glances-memory-limit`
- 증상(사용자 보고): 텔레그램 알림 `ContainerMemoryNearLimit` —
  `observability/glances-9b7dbc8cc-vbzpj/glances`, "working_set이 메모리 limit의 85%를 10분 초과 — OOM 임박"
- 진단 일시: 2026-08-31 (라이브 클러스터 `nuc-15-pro` 실측)

## 근본 원인

`platform/victoria-stack/prod/rules/core.yaml`의 `ContainerMemoryNearLimit`은 분자로
`container_memory_working_set_bytes`를 쓴다. 그런데 커널의 정의는

```
working_set = memory.current − inactive_file
```

이므로 **`active_file`(활성 상태의 clean page cache)이 그대로 분자에 실린다.** 룰 바로 위 주석은

> `working_set 기준 — page cache를 포함하는 max_usage는 hostPath 로그수집 파드에서 limit까지 차므로 금지(라이브 검증된 함정).`

라고 근거를 남겨 두었는데, 이 전제가 **틀렸다.** `max_usage`를 배제하면 page cache가 빠진다고 보았지만
working_set도 page cache의 active 절반을 포함한다. 회수 가능한 캐시가 활성 상태로 남아 있기만 하면
실제 메모리 요구량이 전혀 늘지 않아도 지표가 임계를 넘는다.

glances에서 그 조건이 정확히 성립했다. 회수 불가 메모리(`anon`)는 20일간 76.61 → 76.68Mi로 **사실상 불변**인데,
2026-08-26 12:35~13:30 구간에 file page cache가 0.01 → 40.94Mi로 이 cgroup에 charge되면서
working_set만 81.27 → 113.08Mi로 계단 상승해 128Mi limit의 88.3%가 되었고, `for: 10m`을 채워 발화했다.
그 캐시는 **전량 clean**(`file_dirty=0`·`file_writeback=0`)이라 커널이 I/O 없이 즉시 회수할 수 있고,
cgroup은 limit에 **단 한 번도 닿은 적이 없다**(`memory.events`의 `max=0`·`oom_kill=0`).
즉 알림이 주장하는 "OOM 임박"은 성립하지 않는다.

파급은 이 알림 하나에 그치지 않는다. 같은 지표로 잰 전 컨테이너 순위에서 traefik은 working_set 62.4%인데
회수 불가 메모리는 11.9%에 불과해 **50%p가 벌어진다.** `docs/memory-ledger.md`가 "traefik(168/192)은 타이트 —
축소 금지"로 기록한 right-size 판단도 같은 오염된 지표 위에 서 있다(이번 수정의 범위 밖이며, 아래 후속 참고).

### 왜 하필 08-26이었나

08-26 13:41:13Z에 노드가 재부팅됐다(전 파드 `exit=255`, `uptime -s` = 2026-08-26 22:41:06 KST와 일치).
다만 캐시 charge는 재부팅보다 **앞선** 12:35~13:30 구간에 일어났고(13:30 샘플에서 이미 `cache=39.46Mi`),
알림 `activeAt`은 13:27:00Z다. page cache의 cgroup charge는 "그 페이지를 처음 메모리로 올린 cgroup"에
귀속되므로, 동일 워크로드라도 재시작·재부팅 타이밍에 따라 귀속이 달라진다. 요구량은 그대로인데 지표만
32Mi 뛰는 **비결정적 계단**이 이렇게 만들어진다.

## 증거

피드백 루프(단일 명령, 배포 매니페스트에서 expr을 바이트 그대로 추출해 라이브 평가):

```
$ ROOT=$PWD scratchpad/repro.sh
추출된 expr: max by (namespace, pod, container) (container_memory_working_set_bytes{container!="", namespace!~"kube-system|kube-public|kube-node-lease"}) / max by (namespace, pod, container) (kube_pod_container_resource_limits{resource="memory"}) > 0.85

── L1: 배포 룰 expr을 라이브 평가 (RED 조건) ──
  RED: glances가 발화 대상 — observability/glances=88.3%

── L2: 같은 컨테이너의 회수 불가 메모리(anon) 비율 (위양성 판정 대조) ──
  anon/limit = 59.9%  (임계 85%)

── L3: cgroup 실측 — limit 도달·OOM 이력 ──
  low              0
  high             0
  max              0
  oom              0
  oom_kill         0
  oom_group_kill   0
  sock_throttled   0
  anon                76.68 Mi
  file                40.94 Mi
  file_dirty           0.00 Mi
  inactive_file       13.64 Mi
  active_file         27.30 Mi
```

보조 실측:

- **cgroup이 권위임을 확인** — `memory.current` 126.72Mi·`anon` 76.68Mi·`file` 40.94Mi가
  cAdvisor의 `container_memory_usage_bytes`·`_rss`·`_cache`와 소수점까지 일치. 메트릭은 stale이 아니다
  (초기에 "5일간 값 불변 = stale" 가설을 세웠으나 cgroup 대조로 기각).
- **누수가 아니다** — `anon` 20일 추이 76.61 → 76.68Mi. `workingset_refault_file`은 124뿐이라 thrashing도 없다.
- **세 지표 괴리(limit 대비 %)**:

  | 컨테이너 | working_set | anon | usage−cache |
  |---|---|---|---|
  | observability/glances | 88.3% | 59.9% | 67.0% |
  | homepage/homepage | 82.5% | 43.2% | 49.2% |
  | gateway/traefik | 62.4% | 11.9% | 13.0% |
  | cert-manager/cert-manager-controller | 67.5% | 22.2% | 23.5% |

- **이 룰의 30일 이력** — firing: glances 13108샘플·grafana 256샘플 / pending: vmagent 1875샘플.
  vmagent의 만성 진동은 `rules/r7-meta.yaml` 주석이 이미 실증으로 기록한 "195리셋/24h"와 같은 현상이다.

## 처방 후보

| | 내용 | glances 판정 | 평가 |
|---|---|---|---|
| A | 분자를 `container_memory_usage_bytes − container_memory_cache`(회수 불가 메모리)로 교체 | 67% → 미발화 | anon+slab+커널 스택까지 포괄해 "OOM 임박"의 정의에 정확히 대응. 권장 |
| B | 분자를 `container_memory_rss`로 교체 | 59.9% → 미발화 | slab 8.78Mi 등 커널 메모리를 놓친다 |
| C | glances limit만 128 → 160Mi 상향 | 70.7% → 미발화 | 증상 억제. grafana·vmagent에서 이미 재발 이력이 있고 원장 예산만 소모한다 |

A를 권장한다. 임계 0.85와 `for: 10m`은 유지하며, 사후 알림 `PodOOMKilled`와의 선행/사후 짝 구조도 그대로다.

### ⚠️ A는 r1 리뷰에서 정정됐다 — 실제 처방은 A′다

r1 적대적 리뷰(F1)가 A의 결함을 잡았다. `container_memory_cache`는 cgroup v2의 `memory.stat:file`이고
**tmpfs·shared memory를 포함**한다. 이 호스트는 swap이 0이라 shmem은 회수될 수 없는데도 통째로 빠진다.
라이브 실측: `database/pg-1`의 postgres가 `file 120.19Mi` 중 **shmem 38.00Mi**를 보유해, A로는 3.9%로
보고되지만 실제 회수 불가는 7.6%다. shared memory로 limit을 채우는 컨테이너는 0%에 가깝게 평가돼
`PodOOMKilled`(사후) 전까지 무성이 된다.

**A′ (실제 적용):** 분자를 `usage − total_inactive_file − total_active_file`로 한다. cAdvisor가
`container_memory_total_{active,inactive}_file_bytes`를 실제로 노출하고(라이브 확인), 그 값은 cgroup
`memory.stat`과 일치한다. 파일 LRU의 회수 가능분만 빠지므로 **anon + shmem + slab + kernel_stack**이 남는다.

| 컨테이너 | working_set(옛) | usage−cache(A) | **usage−inactive−active(A′)** |
|---|---|---|---|
| observability/glances | 88.3% | 67.0% | **67.0%** |
| database/postgres | 10.5% | 3.9% | **7.6%** |

A′는 A의 이점(캐시 오염 제거)을 그대로 두고 shmem 결함만 없앤다.

## Seam

**`tests/gates/vmalert-memory-nearlimit-firing-e2e.sh`** (신규) — 레포에 확립된 vmalert replay 하네스 패턴을
따른다(`tests/gates/lib/vmalert-e2e.sh`의 `vme_scenario`/`vme_leg`/`vme_firing` 프리미티브 재사용,
픽스처 생성기 `tests/gates/vmalert-memory-nearlimit-gen.py`, 룰은 배포 ConfigMap에서 매 실행 추출).

정적 lint(`tests/test_alert_rules.bats`)로는 이 결함을 잡을 수 없다 — expr 문법도 유효하고 안티패턴
목록에도 걸리지 않으며, 결함은 **지표 선택의 의미**에 있어 eval-time replay로만 드러난다.

판정 레그:

- **L1 (RED 락)** — glances 실측 형상 픽스처(anon 60%·cache 32%·전량 clean) → `ContainerMemoryNearLimit`
  **발화하면 안 된다**. 현행 expr에서는 발화하므로 이 레그가 red다.
- **L2 (참양성 보존)** — anon이 limit의 95.3%인 픽스처 → **발화해야 한다**. 수정이 알림을 죽이지 않았음을 증명.
- **L2b (shmem 참양성, r1 리뷰 F1의 회귀 앵커)** — anon은 작지만 shmem이 limit의 78%인 픽스처
  (postgres 계열 형상) → **발화해야 한다**. preflight가 이 픽스처는 `usage − cache` 판에서 15.6%로
  **침묵한다는 것까지 단언**하므로, 분자가 cache 차감으로 되돌아가면 이 레그가 반드시 red를 낸다.
- **L3 (하네스 이빨)** — 동결한 결함 expr(옛 working_set 판)에 L1 픽스처를 먹이면 **발화해야 한다**.
  하네스가 이 버그를 실제로 감지함을 매 실행 증명한다(vacuous green 차단).
- **계약 대조(r1 리뷰 F2)** — 임계 `0.85`와 `for: 10m`을 명시 상수와 대조한다. 파생만 두면 임계 하향은
  네 preflight 단언을 모두 통과하고 `for:` 연장은 replay 창이 따라 늘어나 아예 재지지 않는다.

신규 하네스는 `.github/workflows/ci.yaml`의 firing-e2e 목록에 등재해야 한다 —
`Makefile`의 완전성 가드가 `git ls-files 'tests/gates/vmalert-*-firing-e2e.sh'`와 CI 목록의 일치를 강제한다.

## 범위 밖(후속 제안)

1. **메모리 원장의 right-size 판단** — `docs/memory-ledger.md`가 traefik·homepage·cnpg-operator를 "타이트"로
   본 2026-07-06 스윕은 같은 working_set 지표로 측정됐다. 회수 불가 메모리 기준으로 재측정하면 회수 여력이
   상당히 달라질 수 있다(traefik만 놓고 보면 192Mi 중 실사용 22.8Mi). 원장은 CI 게이트(`verify:ledger`)가
   묶인 SSOT라 정정에 별도의 관찰 윈도와 근거가 필요하다.
2. **Grafana 대시보드** — `platform/victoria-stack/prod/grafana-dashboards.yaml`의 `homelab-resources`가
   같은 `working_set / limit` 비율을 패널로 보여준다(23·29행). 관찰 지표로서 working_set 자체는 유효하지만,
   그것을 "limit 근접도"로 제시하는 한 이번에 고친 것과 같은 오독을 사람에게 유발한다.

둘 다 페이징하지 않는 표면이라 이번 픽스가 뒤집는 단일 행동(위양성 알림)에 포함하지 않았다.
