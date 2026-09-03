# 라이브에서 검증된 함정 — 상세 (SSOT)

> 이 파일이 함정의 **단일 SSOT**다(AGENTS.md '라이브에서 검증된 함정'절에서 이전, progressive disclosure).
> AGENTS.md에는 한줄 인덱스만 둔다. enforced 함정의 가드 현황은 `docs/traps.md` 원장(`make verify-traps`).
> 컴포넌트 작업 전 해당 항목을 확인할 것.

### ArgoCD sync-wave 순서/교착
- **ArgoCD sync-wave는 "이전 wave가 healthy"를 기다린다** — 한 Application 안에서 워크로드(-6)가
  Secret(기본 0)보다 빠르면 영구 교착. `generatorOptions.annotations`는 KSOPS(exec) 출력에
  **적용되지 않는다**. 내부 wave는 꼭 필요할 때만.
- ⚠️ **"의존"은 apply 순서만이 아니다 — health를 세워 주는 주체도 의존 대상이다.** 어떤 CR의
  health가 컨트롤러/오퍼레이터가 붙어야 서는 종류라면, 그 컨트롤러가 **더 앞 wave**에 있어야 한다.
  아니면 ArgoCD가 그 CR의 health를 기다리며 멈추고 → 컨트롤러는 영원히 apply되지 않는다.
  2026-08-14 NUC 콜드스타트 실측: `Gateway/homelab`(wave -8)이 traefik 컨트롤러(Helm 차트
  Deployment, wave 0)를 기다려 **17시간** `waiting for healthy state of
  gateway.networking.k8s.io/Gateway/homelab`에 머물렀다. `Gateway`는 `Accepted=Unknown
  Pending: Waiting for controller` 상태였다. 같은 이유로 TLS 리스너의 cert Secret(Certificate
  발급물)도 Gateway보다 앞 wave여야 한다.
  ⇒ 처방: gateway ns의 순서를 CRD(-9) → RBAC(-8) → 컨트롤러/cert(0) → GatewayClass(1) →
  Gateway(2) → HTTPRoute(3)로 뒤집었다. **음수 wave를 새로 붙일 때 반드시 이 질문을 할 것:
  "이 리소스를 Healthy로 만들어 주는 것이 더 앞 wave에 있는가?"**
- ⚠️ **이 클래스는 라이브에서 원리적으로 안 보인다** — 리소스가 이미 전부 존재해 순서가 무의미하기
  때문이다. 점진 구축으로 만든 레포는 콜드스타트를 한 번도 통과하지 않은 채 초록일 수 있다.
> 가드: `platform/cnpg/prod/test_sync_wave_ordering.bats`, `platform/argocd/root/test_sync_wave_ledger.bats`, `platform/traefik/prod/test_gateway_sync_wave.bats`

### ArgoCD retry 소진 후 명시 sync
- ArgoCD는 retry 소진 후 실패 리소스를 재시도하지 않는다 — 명시 sync:
  `kubectl -n argocd patch app <x> --type merge -p '{"operation":{"sync":{}}}'`,
  멈춘 op 종료는 `status.operationState.phase=Terminating` patch.
- ⚠️ **그 patch에 `--subresource status`를 붙이면 안 된다.** ArgoCD의 Application CRD는 status
  서브리소스를 선언하지 않는다(`.spec.versions[*].subresources` = `{}` — NUC v3.4.4·라이브 Mac
  양쪽 실측). 없는 서브리소스에 patch하면 kubectl이 **`Error from server (NotFound):
  applications.argoproj.io "<app>" not found`** 를 낸다 — 바로 앞의 `get`은 성공하므로
  "Application이 사라졌다"로 오독하게 된다. status는 본체의 일부라 서브리소스 지정 없이 patch한다.
- ⚠️ **좀비 operation은 진단을 통째로 오도한다.** `phase=Running`인 채 몇 시간씩 남은 operation은
  이후의 모든 sync를 삼키고, `syncResult`는 **그 operation이 시작된 시점의 revision** 기준 결과를
  계속 보여준다. 그래서 "수정을 머지했는데 라이브가 그대로다"가 된다 — 실은 수정본이 한 번도
  실행되지 않은 것이다. `hard refresh`·`force sync`·controller 재시작은 듣지 않는다.
  ⇒ **진단 첫 줄에서 `startedAt`을 커밋 시각과 비교할 것**:
  `kubectl -n argocd get app <x> -o jsonpath='{.status.operationState.phase} {.status.operationState.startedAt}'`
  (2026-08-14 실측: operation `startedAt`이 수정 커밋보다 **8시간 31분 빨랐다**.)
  처방은 위 Terminating patch(= `make argo-terminate APP=<x>`), 그래도 안 되면
  `kubectl delete application` → root 재생성.

### k8s SSA 중복 env 키/스키마 밖 필드 거부
- k8s SSA는 중복 env 키/스키마 밖 필드를 거부한다 (argo-helm `ARGOCD_CONTROLLER_REPLICAS`,
  barman ObjectStore `spec.env` 사례).

### ArgoCD chart: 필드 repoURL/targetRevision
- ArgoCD에서 `chart:` 필드를 쓰면 repoURL은 Helm 레지스트리, targetRevision은 차트 semver여야 한다.

### Traefik serviceAccount.name 지정 시 SA 미생성
- Traefik 차트는 `serviceAccount.name`을 지정하면 SA를 생성하지 않는다.

### appset 대상 네임스페이스는 platform/namespaces 소유
- appset 컴포넌트의 대상 네임스페이스는 `platform/namespaces`가 소유한다
  (appset에 `destination.namespace`가 없어 CreateNamespace 무효).

### R2 Object R&W 토큰 ListBuckets 불가
- R2 Object R&W 토큰은 ListBuckets/HeadBucket 불가 — rclone은 `no_check_bucket=true` 필요.
  terraform s3 백엔드는 무관.

### GHCR org 패키지 첫 push private
- GHCR org 패키지는 첫 push 시 private + org 정책이 public 전환을 막을 수 있다
  (org Settings→Packages에서 Public 허용 후 패키지별 전환 — UI 전용).

### fine-grained PAT 능력은 실제 push 테스트로만
- fine-grained PAT의 능력은 **실제 push 테스트로만** 확인 가능 — repo GET의 `permissions`
  필드는 사용자 역할을 보여줄 뿐이다. Resource owner를 org로 지정해야 org 리포에 쓴다.
- ⚠️ **읽기 능력도 같다 — fine-grained PAT는 "공개" App 엔드포인트 `GET /apps/{slug}`조차 404로 막는다.**
  terraform `data.github_app`이 그 위에 서 있으면 데이터 소스가 죽고 그것을 참조하는 리소스가 계획에서
  통째로 빠져, `plan`이 에러가 아니라 조용히 **`0 to add`(=무변경)**를 낸다 — 룰셋이 안 걸렸는데 초록으로 보인다.
  해법은 slug 해석을 없애고 **App ID를 리터럴로 핀**하는 것(`infra/github/rulesets.tf`). App ID는 리네임에도
  불변이고, tf-reconcile 토큰이 fine-grained여도 plan이 매 주기 깨지지 않는다.

### runAsUser /etc/passwd 부재 시 libpq PGUSER
- `runAsUser`가 이미지 `/etc/passwd`에 없으면 libpq가 기본 사용자명을 못 정해
  `pg_isready`가 'no attempt'로 실패 — `PGUSER` env로 우회.

### AdGuard setcap ↔ allowPrivilegeEscalation 양립불가
- AdGuard처럼 setcap 바이너리는 `allowPrivilegeEscalation: false`와 양립 불가(exec EPERM).
> 가드: `platform/adguard/prod/test_adguard_auth.bats`

### VictoriaMetrics retention.maxDiskSpaceUsageBytes 엔터프라이즈
- VictoriaMetrics `-retention.maxDiskSpaceUsageBytes`는 엔터프라이즈 전용(VictoriaLogs는 지원).

### envFrom 시크릿 변경은 파드 재시작 필요
- `envFrom` 시크릿 변경은 파드 재시작이 있어야 반영된다.

### build 워크플로 paths/diff 신규 브랜치 무력
- build 워크플로의 paths/diff 감지는 신규 브랜치·workflow_dispatch에서 무력 — fetch-depth: 0 +
  dispatch는 전체 빌드.

### GitHub Actions client_payload 비신뢰 입력
- GitHub Actions에서 `client_payload`는 비신뢰 입력 — env 경유 + regex 검증만 (인라인 보간 금지).
> 가드: `tools/tests/test_mutation-dispatch.bats`, `tools/tests/test_validate-mutation.bats`

### CNPG Pooler 예약 파라미터 pool_mode → poolMode
- CNPG Pooler의 `spec.pgbouncer.parameters`에 예약 파라미터(`pool_mode` 등)를 넣으면 webhook이
  생성 자체를 거부 — sync가 영구 실패 루프에 빠진다. `poolMode` 필드를 쓸 것.
> 가드: `platform/cnpg/prod/test_pooler.bats`

### SSA atomic 리스트 영구 OutOfSync
- SSA + atomic 리스트(HTTPRoute `parentRefs`/`backendRefs`, STS `volumeClaimTemplates`)는 서버 주입
  기본값이 영구 OutOfSync를 만든다 — manifest에 기본값(group/kind/weight)을 명시하거나, status까지
  주입되는 vCT는 `ignoreDifferences`(+`RespectIgnoreDifferences=true`)로 제외.
- ⚠️ **형제 자리를 함께 고칠 것 — 한 곳만 고치면 나머지가 조용히 남는다.** CNPG Cluster의
  `spec.plugins[]`에는 webhook 주입 기본값(`enabled`·`isWALArchiver`)을 명시해 뒀는데 **같은 클래스인
  `spec.externalClusters[].plugin`만 빠져 있었다**(2026-08-14 NUC 실측: cnpg-data가 Healthy인 채로
  5분마다 partial sync를 반복했고 라이브 diff는 그 두 필드뿐이었다). 한 kind에서 이 함정을 만나면
  같은 파일의 **모든 atomic 리스트**를 훑을 것.
- ⚠️ "미기재로 막는다"는 반대 방향의 가드가 이 함정과 충돌한다. `isWALArchiver`는 *켜면* 안 되는
  필드라 원래 가드가 "존재하면 red"였는데, 그 규칙이 곧 OutOfSync의 원인이었다. 올바른 불변식은
  **명시적 `false`**다 — 위험은 값이지 존재가 아니다.
- ⚠️ **2026-08-17 컷오버 이후 `cluster.yaml`에 `externalClusters`가 없다**(감사 9 / ADR 0006 —
  복구 원본을 걷어내고 initdb로 되돌렸다). 따라서 위 externalClusters 사례는 **역사이고, 현재
  강제되는 실행체가 없다** — 그 자리를 재던 @test 2건이 같은 커밋으로 삭제됐다. 남아 있는 강제는
  `spec.plugins[]` 쪽뿐이다(`test_cluster_params.bats`의 webhook 기본값 @test).
  ⇒ **복구 원본을 되살릴 때는 `enabled: true`와 `isWALArchiver: false`를 반드시 함께 명시하고,
  그것을 재는 @test도 같은 커밋에 되살려라.** 지금은 빠뜨려도 CI가 초록이다(`verify-traps.sh`는
  가드 **파일의 존재**만 보지 @test 이름까지 보지 않는다 — 그래서 이 문단이 그 구멍을 메운다).
> 가드: `platform/adguard/prod/test_adguard_route.bats`, `platform/cnpg/prod/test_cluster_params.bats`

### 상주 워크로드 OOM 진단 — 코어 수는 그럴듯한 오답이다 (D-e) · 처방 후 같은 지표를 다시 재라
- 2026-08-14 NUC 콜드스타트에서 `vector`·`victorialogs`가 OOM 루프를 돌았다(2시간에 22회·16회).
  **1차 진단은 "노드 코어 수(6→14)가 늘어 런타임이 워커/P를 더 띄운 탓"이었고, 틀렸다.**
  핀(`--threads 6`·`GOMAXPROCS=6`)을 넣어 vector 워커를 15→8로 줄였는데 커널 OOM 기록의
  `anon-rss`는 **325324 kB로 핀 전(325080·325136·325160·325056)과 동일**했다. 그럴듯한 인과였지만
  숫자가 안 움직였다. ⇒ **처방을 넣은 뒤 같은 지표를 다시 재라. 안 움직이면 원인이 아니다.**
- 실제 원인 둘:
  1. **victorialogs는 128Mi 안에 인제스션 작업집합이 안 들어갔다.** 오감지가 아니다 — 기동 로그가
     `system memory limit 134217728 bytes`(=128Mi)를 정확히 감지하고 `-memory.allowedPercent=60`으로
     캐시를 80530636 bytes(80.5MB)로 제한한다. 남는 47.5MB에 Go 힙 + 인제스션 버퍼 + 비-힙(mmap된
     part·스택)이 다 들어가야 하는데 안 된다. 저장량 문제도 아니었다(smallPartRows 110427 / 1.9MB).
  2. **vector는 sink 백프레셔로 끌려 죽었다.** vlogs가 죽어 있으면 elasticsearch sink가
     `Endpoint is unhealthy` + 무한 재시도로 미전송 배치를 메모리에 쌓는다 — **결합 루프**다.
     로그량이 원인이라 오해하기 쉬운데 `/var/log/pods` 총량은 69MB에 불과했다.
- ⚠️ **`GOMEMLIMIT`은 이것을 못 막는다** — 힙 소프트 리밋이라 캐시·비-힙이 그 밖에서 자란다.
  victorialogs는 `GOMEMLIMIT=115MiB`가 걸린 채로 129MiB에서 죽었다.
- ⚠️ **RSS가 매번 같은 값에서 죽으면 누수가 아니라 작업집합이다.** 커널 OOM 기록을 보면 즉시 갈린다.
  `kubectl top`은 metrics-server가 없으면 안 나오지만 `dmesg -T | grep 'Memory cgroup out of memory'`는
  항상 있고 `anon-rss`/`file-rss`를 정확히 준다. **`kubectl describe`의 OOMKilled보다 훨씬 정보량이 많다.**
- ⚠️ **방아쇠는 장애 자체였다 — 장애가 길수록 복구 부하가 커진다.** traefik이 17시간 막혀 있는 동안
  쌓인 로그가 복구 순간 **백로그 버스트**가 됐다. 실측: 기동 2분 된 vector가 이미 151,135 이벤트를
  전송했고 `vector_source_lag_time_seconds_sum / _count` = 평균 지연 **27,000초(7.5시간)**였다 —
  실시간 로그가 아니라 과거를 읽고 있었다는 뜻이다. 그 버스트가 vlogs 힙을 밀어올리고
  (`go_memstats_heap_alloc_bytes` 116MB, 저장 데이터는 1.9MB뿐), vlogs가 죽으면 vector가
  미전송 배치를 쌓다 죽는 결합 루프가 됐다.
  **백로그를 다 소화한 뒤 정상 유입은 3 KiB/s · 약 1.7 events/s에 불과했고 OOM은 즉시 멈췄다**
  (재시작 간격 5분 → 0). ⇒ 상향한 limit은 **버스트 흡수용 여유**이지 정상 부하 기준이 아니다.
- ⚠️ **판별법**: `vector_source_lag_time_seconds_sum ÷ _count`가 크면(수천 초 이상) 그것은
  "로그가 많다"가 아니라 **"과거를 읽고 있다"**는 신호다. `du /var/log/pods`로 잰 *생산량*은
  정상인데 파이프라인만 터지는 모순이 여기서 풀린다(이번에 그 모순으로 두 번 오진했다).
- ⇒ 처방: limit 상향(vlogs 128→256Mi·vector 320→512Mi) + `docs/memory-ledger.md` 행 동반.
  핀은 **위생 조치로 유지**한다(코어 많은 노드에서 워커 수를 기준선에 묶는다) — 다만 OOM 처방이
  아니라는 것을 주석에 남겼다. 두 limit은 "OOM을 멈추는 안전한 상한"이지 right-size가 아니다 —
  부하가 걷힌 뒤 재측정해 회수할 것.
> 가드: `platform/victoria-stack/prod/test_concurrency_pin.bats`

### PCIe correctable RxErr 폭주는 ASPM L1이다 — 유휴에서만 나고, 하드웨어 열화가 아니다
- NUC의 부팅 NVMe(`0000:01:00.0`)에서 `PCIe Bus Error: severity=Correctable, type=Physical Layer,
  (Receiver ID)`가 대량으로 났다. AER 카운터 기준 부팅 후 **`RxErr` 3만 건대**(dmesg는 rate-limit돼
  수백 줄만 보이므로 **`/sys/bus/pci/devices/<addr>/aer_dev_correctable`을 볼 것** — dmesg 줄 수로
  규모를 판단하면 ~85배 과소평가한다).
- ⚠️ **열화로 오독하기 쉽다.** 판별 3종:
  `aer_dev_fatal`/`aer_dev_nonfatal`이 **0**이고 · `LnkCap`=`LnkSta`(속도·폭 강등 없음)이며 ·
  `LnkCtl: ASPM L1 Enabled`이면 링크 마진이 아니라 **전력 상태 전이**를 보고 있는 것이다.
- ⭐ **결정적 A/B (2026-08-15 실측)** — per-device 노브 `/sys/bus/pci/devices/<addr>/link/l1_aspm`을
  껐다 켜며 같은 창에서 카운터를 쟀다:

  | | 유휴 60초 | 부하(8GiB direct read) | 처리량 |
  |---|---|---|---|
  | ASPM L1 ON | **+9** | +0 | 1.2~1.3 GB/s |
  | ASPM L1 OFF | **+0** | +0 | 1.2 GB/s |

  ⇒ **에러는 부하가 아니라 유휴에서만 난다**(L1 진입→기상 시 발생). **처리량 손실은 0**이고
  대가는 유휴 전력뿐이다. "I/O가 많아서 링크가 힘들다"는 정반대의 직관이 틀린 자리다.
- ⚠️ **장애가 카운터를 튀게 한다.** 2026-08-14 콜드스타트 OOM 루프가 만든 잦은 유휴↔활성 전환이
  버스트를 만들었다 — 카운터 급증을 보고 디스크를 의심하기 전에 **그 시간대에 무슨 장애가 있었는지**
  먼저 볼 것.
- ⇒ 처방: `etc/tmpfiles.d/10-k3s-node.conf`의 `w /sys/bus/pci/drivers/nvme/*/link/l1_aspm - - - - 0`.
  **PCI 주소가 아니라 드라이버 경유 글롭**을 쓴다 — 슬롯이 바뀌거나 두 번째 M.2를 달아도 따라간다.
  ⚠️ `host-config.sh`의 트리 열거는 **확장자 화이트리스트**다 — 2026-08-19 현재
  `.conf`·`.service`·`.timer`. 그 밖(udev `.rules`, grub `.cfg`)으로 두면 설치도 드리프트 검사도
  안 된 채 **조용히 무시된다**(레포의 "열거 붕괴 → vacuous green" 클래스). 그래서 `.conf`로 표현
  가능한 tmpfiles를 골랐다. 트리에 파일을 더하면 `TREE_MIN`도 같이 올릴 것.
  ⇒ 같은 날 이 클래스를 **닫았다**: 화이트리스트 밖 파일이 트리에 존재하는 것 자체가 fail-loud다
  (`TREE_N -eq TREE_ALL_N`). 이제 새 확장자는 조용히 빠지는 대신 글롭을 넓히라고 요란하게 운다.
> 가드: `infra/k3s-bootstrap/tests/test_03-host-config.bats`

### hostPath 백엔드 PV에는 fsGroup이 적용되지 않는다 — root가 만든 파일을 non-root가 못 연다(빈 PVC 전용)
- Pod `securityContext.fsGroup`은 kubelet이 소유권을 관리하는 볼륨에만 걸린다. **local-path류의
  hostPath 백엔드 PV는 대상이 아니다** — 2026-08-14 NUC 실측: `fsGroup: 65532`인데 PVC 디렉토리가
  `root:root 0777`이었다. 디렉토리가 0777이라 non-root도 **생성**은 되므로 문제가 없어 보이지만,
  **root로 도는 컨테이너가 만든 파일은 `0644 root:root`**라 뒤따르는 non-root 컨테이너가 열지 못한다.
  AdGuard의 `seed-config`(root) → `inject-auth`(65532)가 `permission denied`로 죽어 파드가
  Init:CrashLoopBackOff에 빠졌다.
- ⚠️ **빈 PVC에서만 드러난다.** 라이브에서는 파일이 이미 있어 `cp -n`이 건너뛰므로 소유권이 문제될
  일이 없다. sync-wave 교착과 같은 부류의 "콜드스타트 전용" 결함이다.
  ⇒ 처방: **PVC에 파일을 만드는 컨테이너를 최종 소비자와 같은 uid로 돌린다**(fsGroup에 기대지 말 것).
> 가드: `platform/adguard/prod/test_adguard_auth.bats`

### yq -e는 값이 false면 exit 1이다 — 키 부재(null)와 구별하지 않아 올바른 매니페스트에서 red가 난다
- `yq -e`의 종료코드는 "출력이 truthy인가"다 — **키가 없을 때(`null`)와 값이 `false`일 때를 구별하지
  않는다.** 그래서 올바른 매니페스트(`isWALArchiver: false`)에서 bats가 red가 된다.
  `-e` 없이 읽고 `printf '%s' "$v" | grep -qxF -- 'false'`로 정확 일치를 단언하면 미기재(`null`)와
  `false`가 갈린다. 불리언을 읽는 모든 단언에 해당한다.
> 가드: `platform/cnpg/prod/test_cluster_params.bats`

### Application zero-value selfHeal 플립플롭
- Application spec의 zero-value(예: `directory.recurse: false`)는 컨트롤러 정규화가 매번 삭제 →
  selfHeal과 플립플롭(generation 폭주). zero-value 필드는 기재하지 않는다.

### selfHeal이 라이브 실험을 무력화한다 — 끄는 레버는 git뿐
- `kubectl scale`·`patch`로 만든 상태는 **약 5초 만에 되돌아간다**(argocd v3.4 기본
  `--self-heal-timeout-seconds=5`, 컨트롤러 args에 오버라이드 없음 — 실측 2026-08-18).
  그래서 "죽여 보고 관찰한다" 류의 런북은 **거짓 PASS**를 낸다.
- 실측 사례: AdGuard 폴백 drill(`scale deploy/adguard --replicas=0` → `dig` → `--replicas=1`).
  파드 기동이 created→Ready **5초**라 실질 공백이 10~15초인데 SSH 왕복이 그보다 길다 →
  측정되는 것은 "폴백이 동작했다"가 아니라 **"서비스가 살아 있었다"**다.
- **임시 해제도 안 된다.** 대부분의 Application이 ApplicationSet `platform-components` 산물이라
  (`ownerReferences`로 확인) `kubectl patch app`은 appset 컨트롤러가, appset을 patch하면 그 소유자인
  `root` app(역시 selfHeal=true)이 되돌린다. 실제 레버는 git 변경뿐이다
  (appset에 `ignoreApplicationDifferences`, `applicationsSync: create-only`, 또는 git에서 replicas:0).
- ⚠️ 덧붙여 selfHeal은 **안전망**이기도 하다 — 세션이 끊기거나 에이전트가 죽어도 서비스가 자동
  복구된다. 끈 채로 replicas=0을 두는 것은 그 안전망을 스스로 제거하는 것이다.
- ✅ **대신 쓸 수 있는 것**: 파드 **삭제**는 스펙 드리프트가 아니라 selfHeal과 무관하고 Deployment가
  재생성하므로, 자동 복구되는 짧은 창(실측 약 5초)을 안전하게 만든다. 더 긴 창이 필요하면
  클러스터를 안 건드리는 대체 검증(클라이언트 측 조작 등)이나 git 경유 절차로 설계를 바꾼다.
- **설계 단계에서 확인할 것**: 라이브 장애 주입 절차를 쓰기 전에 대상의 `.spec.syncPolicy`와
  `.metadata.ownerReferences`를 먼저 읽어라. `selfHeal: true`면 그 절차는 이미 틀렸다.
  (실례: `docs/runbooks/lan-dns.md` §4가 이 이유로 폐기·재작성됐다.)

### PSA baseline hostPath/hostPID 금지
- PSA는 `baseline`도 hostPath/hostPID를 금지한다(privileged 전용) — node-exporter/Vector류 DS는
  enforce=privileged 네임스페이스 필요.
> 가드: `platform/namespaces/prod/test_psa.bats`

### CNPG pg_hba replication pg_basebackup
- CNPG 기본 pg_hba는 replication을 streaming_replica(cert)만 허용 — pg_basebackup을 쓰려면
  `spec.postgresql.pg_hba`에 postgres replication 항목을 추가해야 한다.
> 가드: `platform/cnpg/prod/test_basebackup.bats`

### CronJob k3s VM TZ(Asia/Seoul)
- CronJob은 k3s VM의 TZ(Asia/Seoul)로 발화한다 — UTC로 읽지 말 것.
- **CNPG ScheduledBackup은 이 규약 밖이다** — operator 파드가 발화하고 그 TZ는 UTC라 `0 0 3 * * *`은
  03:00Z=**12:00 KST**다(실측 2026-09-02 `status.lastScheduleTime`). 두 시계를 같은 축에 놓고
  '먼저/겹치지 않게' 같은 순서 근거를 세우면 그 근거가 거짓이 된다.

### NetworkPolicy ipBlock pod-CIDR → 전체 허용
- **NetworkPolicy ipBlock에 pod CIDR(10.42.0.0/16)을 넣으면 "전체 파드 허용"** — default-deny가
  무력화된다. kubelet probe 소스는 노드(cni0=10.42.0.1)뿐이며, kube-router는 노드발 트래픽을
  POD-FW 내장 `fib saddr type local accept`로 정책 평가 **전에** 이미 허용한다.
> 가드: `platform/network-policies/prod/test_netpol.bats`, `platform/cnpg/prod/test_networkpolicy.bats`

### kube-router 룰 설치 갭/v2 체인명 변경
- kube-router는 새 파드의 방화벽 룰을 생성 후 수 초 지나 설치한다 — 파드 첫 명령으로 즉시
  연결하는 NP 테스트는 그 공백을 통과한다(`sleep 8` 후 연결). kube-router v2는 sync마다
  체인 이름을 바꾸므로 라이브 디버깅은 원자 스냅샷(nft list 1회) 안에서 카운터를 읽을 것.

### NetworkPolicy egress apiserver ClusterIP 불가
- **NetworkPolicy egress로 apiserver(ClusterIP) 접근은 ClusterIP ipBlock으로 안 된다** — kube-router가
  `kubernetes.default.svc`(10.43.0.1:443)를 apiserver endpoint(노드 InternalIP:6443)로 DNAT하고, netpol
  egress는 **DNAT 후 dest**를 평가한다. ClusterIP `10.43.0.1/32`를 ipBlock에 넣으면 API 호출이 Connection
  refused(default-deny REJECT)로 막힌다 — **노드 서브넷:6443**을 허용해야 한다(homepage 자동발견이
  "Error getting namespaces"로 전체 실패하며 검증). selfHeal 있는 Application엔 임시 patch가 reconcile에 곧
  원복돼 라이브 디버그가 어렵다 — PR로 수정.
- ⇒ (2026-08-27 실측 보강) 반대 방향도 같은 뿌리로 막힌다 — **default-deny egress가 노드 자신
  IP:6443(= ClusterIP DNAT 후 apiserver)을 차단하지 못한다**: pvc-du-exporter 라벨의 프로브가
  kubernetes.default.svc:443에 도달했다(HTTP 401 = 연결 성립). kube-router의 FORWARD 기반 netpol은
  노드 로컬 트래픽(INPUT 경로)에 미적용이라, "netpol로 apiserver를 봉쇄했다"는 완화 주장은 이
  CNI에서 성립하지 않는다 — F8류 격리 계약은 이 잔여를 명시 수용으로 적어야 한다.

### OrbStack LISTEN 포트만 포워딩
- OrbStack은 VM에서 **LISTEN 중인 포트만** Mac으로 포워딩한다(바인드는 Mac 전 인터페이스).
  servicelb/hostPort는 iptables DNAT뿐이라 트리거가 안 된다 — 그래서 `:53`을 점유하기만 하는
  더미 유닛(`dns-forward-trigger.service`)이 있었다. VM IP(192.168.139.x)는 Mac에서 직접
  라우팅되지 않는다.
- ⚠️ **베어메탈에서는 이 함정도, 그 우회도 없다.** 노드가 곧 호스트라 svclb hostPort가 노드
  실주소에 직접 걸린다. 그 유닛은 `infra/k3s-bootstrap/cloud-init.yaml`에 살았고 NUC 이식
  브랜치에서 삭제됐다(후계는 `host-config/` 트리 — 담지 않는다). `main`(라이브 Mac)에는 남아 있다.

### AdGuard ConfigMap 첫 부팅 시드 전용
- AdGuard ConfigMap은 첫 부팅 시드 전용(initContainer `cp -n`) — 갱신 시 PVC 안의
  AdGuardHome.yaml도 함께 고치고 재시작해야 반영된다.

### AdGuard split-horizon rewrite DR stale
- **AdGuard split-horizon rewrite(`*.home.ukyi.app → <traefik-ts tailscale IP>`)는 DR 재구축 시 stale이 된다.**
  DR로 traefik-ts 디바이스가 재등록되면(예: homelab→homelab-1) tailscale IP가 바뀌는데 rewrite는 옛 IP를
  가리킨 채라, tailscale·LAN 양쪽에서 모든 `*.home.ukyi.app`이 죽은 IP로 연결돼 실패한다(`.ts.net` MagicDNS
  경로엔 안 드러나 한참 뒤에 발견). 재구축 후 `kubectl -n gateway get svc traefik-ts`의 tailscale IP로 seed +
  라이브 PVC 둘 다 갱신할 것. (tailnet 전역 nameserver=NUC tailscale IP:53→AdGuard는 노드 IP가 안정적이라 무관.)

### tailscale operator Ingress reconcile metadata-only 무시
- tailscale operator의 Ingress reconcile은 metadata-only 변경(annotation nudge)을 무시한다 —
  재처리는 operator 재시작으로.

### vector는 root로 실행
- **vector는 root로 실행해야 한다** — k3s `/var/log/pods/**/*.log`는 root:root 0640이라
  nobody(65534)는 못 읽어 수집이 조용히 0이 된다(healthcheck disabled라 에러도 안 뜸).
  진단은 VL `vl_rows_ingested_total{type="elasticsearch_bulk"}`로(0이면 경로 단절).

### busybox nc -q 없음
- **busybox nc에는 `-q` 옵션이 없다**(1.36~1.38 전 버전 — 실측 확인) — `nc -l -p PORT -q 1`은 invalid option으로 즉시
  죽는다. deadmanswitch relay가 이 때문에 webhook을 영구 거부하고 healthchecks를 과도 ping해
  dead-man switch를 무력화했다.
> 가드: `platform/victoria-stack/prod/test_relay.bats`

### VictoriaLogs distroless 라이브 질의
- VictoriaLogs/일부 VM 컴포넌트는 distroless(wget/sh 없음) — 라이브 질의는 vmagent 등
  다른 파드에서 service DNS로. vmalert 그룹 조회는 `/api/v1/rules`(신버전, groups는 400).
- ⚠️ **`vmalert`도 distroless라 `kubectl exec ... sh -c` 가 조용히 빈 출력을 낸다**(2026-08-16 실측).
  `vmsingle`은 셸이 있어 되는데 vmalert는 안 된다 — 한쪽이 됐다고 다른 쪽도 될 것으로 넘기지 말 것.
  룰 상태는 vmsingle에 `ALERTS` / `ALERTS_FOR_STATE` 시계열로 물으면 exec 없이 얻는다.

### VM 질의 URL에서 `[...]`를 인코딩하지 않으면 조용히 빈 결과가 온다
- ⚠️ **`{"status":"success", ... "result":[]}`가 돌아온다 — 에러가 아니라 성공이다.**
  그래서 "메트릭이 없다"로 읽히고, 그 위에 서 있던 알림 판단이 통째로 뒤집힌다.
  2026-08-16 실측: `files_backup_last_success_timestamp[10d]`를 인코딩 없이 물어 0건을 받고
  **"라이브 Mac의 files 백업이 죽었다"는 결론까지 갔다.** `%5B10d%5D`로 다시 물으니 6.3시간 전
  값이 정상으로 있었다 — 라이브는 멀쩡했다.
- ⇒ range selector가 든 질의는 **항상 `%5B`/`%5D`로 인코딩**한다:
  `curl "http://<vmsingle>:8428/api/v1/query?query=last_over_time(metric%5B10d%5D)"`
- ⚠️ **`/api/v1/label/__name__/values`로 "메트릭 존재"를 판정하지 말 것** — 기본 조회창 밖의
  **하루 1회 push 같은 단발 시리즈는 목록에 안 나온다.** 존재 판정은 반드시
  `last_over_time(<metric>[<충분한 창>])`으로 한다(알림 룰들이 `[10d]`를 쓰는 것과 같은 이유).
- ⚠️ 같은 성질이 **알림에도 그대로 있다** — 단발 push 메트릭에 bare `absent()`를 걸면 영구 오발화한다.
  `r4-storage-backup.yaml`의 주석이 그 실측을 이미 적어 두었다.

### Alertmanager telegram 전송 검증 메트릭
- Alertmanager telegram 전송 검증은 로그가 아니라 `alertmanager_notifications_total{integration="telegram"}`
  과 `..._failed_total`으로. 봇 토큰은 메인 컨테이너 env가 아니라 init이 렌더한
  alertmanager.yml의 `bot_token_file`에 있다(직접 전송 테스트는 secret을 envFrom한 임시 파드로).
> 가드: `tests/gates/alertmanager-render-e2e.sh`, `tests/gates/test_telegram-notify.bats`, `tests/gates/test_telegram-alert-korean.bats`, `tests/gates/test_telegram-callsites.bats`

### ConfigMap 변경 파드 자동 재시작 없음
- ConfigMap(relay 스크립트 등) 변경은 파드 자동 재시작이 없다 — `rollout restart` 필요.
- **실측 사고(2026-09-03)**: alertmanager는 이 함정을 실제로 밟았다. 설정 ConfigMap을 고친 PR이
  머지돼 ArgoCD가 적용했지만 Deployment spec이 무변경이라 롤아웃이 안 났고, 라이브 파드는
  2026-08-27 렌더본을 쓰고 있어 새 제목 매핑 2건이 도달하지 않았다(red가 아니라 조용한 품질 저하).
- **처방은 kustomize `configMapGenerator`다** — 내용 해시가 이름에 붙으므로 설정을 고치면 ConfigMap
  이름이 바뀌고, nameReference 변환이 pod template의 volume 참조를 다시 써 롤아웃이 **구조로** 난다.
  현재 이 형태를 쓰는 곳: `platform/homepage/prod`(config·assets) ·
  `platform/victoria-stack/prod`(alertmanager — `alertmanager-config/alertmanager.yml`).
  ⚠️ `options.disableNameSuffixHash: true`를 켜면 그 보장이 사라져 이 함정으로 그대로 복귀한다.
- 남아 있는 자리(수동 `rollout restart`가 여전히 유일한 보장): 위 둘 밖의 ConfigMap 소비자
  — 예: `deadmanswitch-relay`(스크립트 ConfigMap) · adguard 시드 ConfigMap(첫 부팅 전용, 별도 함정).

### bats bash 3.2 중간 [[ ]] 침묵 통과
- **bats가 bash 3.2(macOS 기본)로 돌면 테스트 중간의 `[[ ]]` 실패가 침묵 통과된다**(set -e가
  compound command 실패를 무시 — 마지막 명령 status만으로 ok). 중간 단언은 `[ ]`(단순 명령)로.
- 실측: `[[ "$x" == *ABSENT* ]]`는 거짓인데 `ok`, 같은 자리를 `printf '%s' "$x" | grep -qF -- 'ABSENT'`로
  바꾸면 정확히 `not ok`. 레포에 이 형태가 53건 있었고 **전부 죽은 단언이었다**(0으로 수렴, 이제 hard-zero).
- ⚠️ `grep -qF`에는 **`--` 종결자**를 붙여라 — `--kubelet-arg=…`처럼 `-`로 시작하는 패턴을 grep이
  옵션으로 해석해 status 2로 죽는다(변환 직후 6개 스위트가 그렇게 깨졌다).
> 가드: `scripts/check-bats-style.sh`

### 셸 문자열의 `$VAR한글` — bash 3.2가 멀티바이트를 변수명에 삼킨다
- `$VAR` 바로 뒤에 비-ASCII가 붙으면 **bash 3.2(macOS 기본)가 그 바이트를 변수명에 포함**시킨다.
  실측(`V=7; echo "평가($V회)"`):

  | 인터프리터 | `LC_ALL=C` | UTF-8 로케일(C.UTF-8·en_US·ko_KR) |
  |---|---|---|
  | bash 3.2 (macOS `/bin/bash`) | `평가(7회)` | **`V<byte>: unbound variable`, exit 127** |
  | bash 5.2 (CI 러너 ubuntu-24.04) | `평가(7회)` | `평가(7회)` |

- **그래서 CI가 원리적으로 못 잡는다.** 게이트는 bash 5.2라 영원히 초록이고, 터지는 것은 오너의
  macOS 로컬뿐이다. `shellcheck`도 못 잡는다(파서는 `$VAR` + 리터럴로 읽고 경고 0).
- `set -u`가 없으면 더 나쁘다: 죽지 않고 **`평가(??)`로 숫자와 한글이 함께 깨진 채 통과**한다.
- 이 레포는 진단 메시지가 전부 한국어라 발현 밀도가 높은데 대부분 실패 경로(`|| fault …`)에 있어
  **휴면**한다 — 정작 진단이 필요한 순간에 진단 대신 unbound variable을 본다(DR 스크립트
  `scripts/reset-pg-r2-archive.sh`의 FATAL 경로가 실례였다).
- **규약: 셸 문자열 안의 변수는 항상 `${VAR}`로 감싼다.**
- ⚠️ 가드의 검출은 **`LC_ALL=C grep -E '[^ -~]'`**로 쓴다. `grep -P`를 쓰면 macOS BSD grep이 `-P`를
  지원하지 않아 **가드가 조용히 0건을 찾는다**(첫 구현이 그랬고, 버그를 되돌려 넣어도 초록이었다).
> 가드: `tests/gates/test_shell-bash32-traps.bats`

### helm 차트 CRD includeCRDs
- helm 차트 CRD가 `crds/` 디렉토리에 있으면 kustomize HelmChartInflationGenerator 기본 렌더에서
  빠진다 — `includeCRDs: true` 필수(sealed-secrets에서 검증).

### sealed-secrets patch-mode 대상 Secret 어노테이션
- **sealed-secrets patch-mode로 기존(타 도구 생성) Secret에 키를 머지하려면 `sealedsecrets.bitnami.com/patch:
  "true"`를 대상 live Secret에 둬야 한다** — 컨트롤러(0.37.0)는 SealedSecret 템플릿이 아니라 **대상 Secret의
  어노테이션**에서 patch 여부를 읽는다. 템플릿에만 두면 `failed update: Resource "<name>" already exists and is
  not managed by SealedSecret`로 거부돼 Application이 Degraded(argocd ukkiee 비밀번호를 argocd-secret에 머지하다
  발견). argo-helm은 `configs.secret.annotations`로 data 블록 없이 이 어노테이션을 차트 생성 시점에 부여할 수
  있다(data 필드 미설정 시 data 블록 미렌더 → 머지 키 prune 없음, DR-durable). `patch` 단독이면 ownerRef 없이
  additive 머지(기존 키 보존). **`managed: "true"`는 controller ownerRef를 만들어 SealedSecret 삭제 시 대상 Secret
  전체가 cascade delete되므로 쓰지 말 것**(patch 단독으로 충분).
- **(다른 축, 같은 컴포넌트) 키 자동 회전은 상시 정지다** — `keyrenewperiod: "0"`
  (`platform/sealed-secrets/prod/values-sealed-secrets.yaml`)는 한시 조치가 아니라 항구 결정이다. 회전은
  **옛 키를 지우지도, 이미 커밋된 봉인본을 재봉인하지도 않아** 노출 창을 줄이지 못하는 반면,
  `scripts/backup-sealed-secrets-key.sh --verify`·committed cert(`tools/sealed-secrets-cert.pem`)·복구 드릴을
  30일마다 조용히 stale로 만든다(자동화 없음). 회전이 필요하면 런북 `restore.md` 「회전 절차」로 **수동**.
  재검토 트리거는 그 셋 중 하나라도 **자동 실행 venue(systemd timer·CronJob·워크플로 스케줄)에 배선**됐을 때다.
  owner 손 호출 스위트로의 편입은 트리거가 아니다 — 옛 문언의 예시(`--verify`가 `make verify-posture`에 편입)가
  #594로 문자 그대로 발화했고, 2026-09-03 재검토 결론은 **결정 유지**다(posture는 손 호출이라 회전이 부르는
  수동 의무 4개를 자동으로 재는 것이 없다).

### gh pr merge --auto clean PR 에러
- `gh pr merge --auto`는 이미 clean(체크 완료)인 PR에 에러를 낸다 — `|| gh pr merge` 폴백 필요.

### create-github-app-token repositories owner 없는 레포명
- `create-github-app-token`의 `repositories` 입력은 **owner 없는 레포명**만 받는다
  (`owner/repo` 형태를 넣으면 스코프 실패). cross-repo read는 `owner:` 명시 필수(비우면 현재
  레포로만 제한). 액션은 full commit SHA로 핀(mutable 태그는 private key를 변조 액션에 넘김).

### concurrency.queue: max ↔ cancel-in-progress 병용 불가
- `concurrency.queue: max`(2026-05 GA)는 `cancel-in-progress: true`와 병용 불가(워크플로 검증
  에러로 전체 불능) — 기본(single)은 pending 1건만 유지해 동시 3번째가 대기 건을 취소한다.
> 가드: `tools/tests/test_mutation-dispatch.bats`

### terraform provider lock 첫 커밋 라이브 state writer 이상
- **terraform provider lock을 처음 커밋할 땐 라이브 state writer 버전 이상으로 핀해야 한다.** lock
  미커밋 시절 CI `init`은 `~>` 제약의 최신을 자동 설치해 그 버전으로 state를 기록한다 — 이후 더 낮은
  버전을 핀한 lock + `-lockfile=readonly`는 "Resource instance managed by newer provider version"으로
  apply 영구 실패. `terraform providers lock`은 기존 lock 버전을 보존(해시만 추가)하므로 업그레이드는
  `rm lock && terraform providers lock -platform=...`로 최신 재생성해야 한다(레지스트리 버전 단조증가).

### tf 루트 관리 모델 CI vs 로컬
- **tf 루트 관리 모델(CI vs 로컬):** cloudflare만 CI apply(iac.yaml push + tf-reconcile 수렴) — DNS/tunnel
  좁은 스코프라 안전. github/tailscale은 **owner 로컬 apply 전용 신뢰 앵커**: github 루트가 CI Actions
  시크릿(secrets.tf)·branch protection(repo.tf `contexts=["gate"]`)을, tailscale 루트가 ACL/auth-key를
  관리한다. CI 무인 apply는 광범위 admin PAT/OAuth를 CI에 저장해야 해 보안 모델 위반 → 금지. CI는 이 둘에
  대해 tf-reconcile에서 **plan-only 드리프트 알림**만 한다(신규 `TF_GITHUB_*`/`TF_TAILSCALE_*` 시크릿 있을
  때만, 없으면 preflight skip). Cloudflare 무료 플랜 rate-limit entitlement(period·mitigation_timeout 둘 다
  10초 고정 등)는 plan 통과해도 apply에서만 400으로 드러난다(cache.tf matches 함정과 동일 계열).
- ⚠️ **그 모델에 state 잠금이 없다.** 1.9.x S3 backend는 `dynamodb_table` 없이 잠그지 않고
  `use_lockfile`은 1.10+라, `-lock-timeout=120s`는 no-op이고 직렬화는 CI `homelab-mutation` 그룹뿐이다 —
  그 그룹은 **설계된 owner 로컬 apply 경로**(cloudflare guard=blocked-delete)를 덮지 못한다. 로컬 apply
  전에 `gh run list -w tf-reconcile.yaml --status in_progress`가 비어 있는지 확인할 것(근치는 followup).

### 상주 워크로드 자원 limit 블라인드스팟
- **자원 limit 블라인드스팟:** 메모리 원장 게이트(`verify:ledger`/`ledger.rego`)는 docs/memory-ledger.md의
  **마크다운 행만** 검증하고 라이브/소스 manifest와 교차하지 않는다 — 워크로드에 메모리 소비자를 추가하며
  limit/행을 안 올려도 GREEN, OOM으로만 발현(vector OOM PR #85 포스트모템). 대칭으로 CPU도 starvation 축
  (cpu request 없으면 점유율 보장 0 → 이웃 굶김). `tools/check-resource-limits.ts`가 상주 워크로드
  (Deployment/DaemonSet/StatefulSet) main 컨테이너에 **cpu·memory request + memory limit**을 강제한다
  (cpu limit은 CFS quota라 유휴서도 throttling → 비요구; starvation은 request로, OOM은 memory limit으로).
  grep 셀렉터 붕괴 시 0매치 침묵통과(false-green)는 scan-floor로 차단. operator/원격-helm 런타임 생성처럼
  의도적 미설정은 `policy/memory-limit-allowlist.txt`에 사유와 함께 등재(블라인드스팟 가시화).
> 가드: `tools/check-resource-limits.ts`, `tests/test_resource_limits.bats`

### GHA run 기본 셸 pipefail 부재(bash -e {0})
- GitHub Actions run 스텝의 기본 셸은 `bash -e {0}` — **pipefail이 없다**. `bun 도구 | tee 로그` 류
  파이프는 좌변(도구) 실패가 tee의 exit 0에 삼켜져 스텝이 green — 변이 reusable에선 부분 산출물이
  PR·auto-merge로 샐 수 있다(fail-open). 명시 `shell: bash`는 `bash --noprofile --norc -eo pipefail {0}`로
  실행되므로 워크플로 `defaults.run.shell: bash`가 구조적 해법(신규 스텝 자동 커버). 스텝별
  `set -euo pipefail` 삽입 규율은 이 결함의 발생 기전 그 자체(_teardown-app만 있고 형제 5개 누락)라
  비채택. 과거 _teardown-app 주석의 "GHA 기본 -eo pipefail"은 **반대 오해**였다 — 기본(-e만)과
  명시 bash(-eo pipefail)를 혼동하지 말 것. 명령치환 인라인(`echo "x=$(jq …)"`)도 동류 fail-open —
  대입으로 분리해야 -e가 잡는다.
> 가드: `tests/gates/test_workflow-pipefail.bats`

### ArgoCD Notifications telegram native 함정
- ArgoCD Notifications v3.4.x telegram은 함정이 겹친다(#213→#217→#224 라이브 확정): **webhook 방식은 봇
  토큰을 retryablehttp DEBUG 로그로 URL에 실어 VictoriaLogs로 유출**한다 → native(tgbotapi, 미로깅)로 회피.
  native recipient는 **음수 그룹 chatId만** 유효(양수 DM은 @channel로 오해석→전송 실패), **parseMode가
  Markdown 하드코딩**(HTML 무시 → `*bold*` 리터럴), recipient에 `$secret` 확장 없음(chatId 리터럴). oncePer는
  관측 HEAD(`sync.revision`)가 아니라 **실제 sync 작업 revision(`operationState.syncResult.revision(s)`)**에 걸어야
  한다 — 모노레포는 main 머지마다 구독 앱 전부가 같은 HEAD를 관측해 거짓 "배포 완료" 버스트(#224). supergroup
  승격 시 chatId가 바뀐다(전송 조용히 실패). parseMode 하드코딩의 두 번째 얼굴: **템플릿에 임의 문자열
  (`operationState.message` 등)을 그대로 실으면 안 된다** — 짝이 안 맞는 `_`·`*`·백틱·`[`에 Telegram이 400
  (can't parse entities)으로 **메시지 전체를 거부**해 실패 알림이 실패로 사라진다. app 이름(DNS명)만 이스케이프
  면제이고, 그 외에는 sprig `replace`로 중화한다(sprig는 notifications-engine이 등록 — `pkg/templates/service.go`,
  `env`/`expandenv`만 제외). 트리거 축의 공백도 같은 자리다: `on-deployed`/`on-health-degraded`만으로는
  **sync phase Error/Failed**(hook 실패 포함)가 어느 채널에도 안 잡힌다 — health는 Healthy, sync_status는
  Synced로 남을 수 있어 vmalert `ArgoCDOutOfSync`까지 함께 침묵한다(`trigger.on-sync-failed`가 그 유일한 채널).
> 가드: `platform/argocd/test_argocd_values.bats`

### PG 메이저 업그레이드 3-이미지 동시 갱신
- PG 메이저 업그레이드는 **서버(CNPG Cluster) + basebackup(barman) + pg-tools(ops 이미지)를 한꺼번에** 올려야
  한다 — `pg_dump`는 서버보다 낮은 major를 거부한다(ops/pg-tools Dockerfile). 라이브 2회 발현: PgDumpHedgeStale
  (pg_dump16 vs 서버18, #178/#180)·dr-drill 이미지 16.4 잔류(#206). pg-tools digest는 5개 소비처(cache
  backup-cronjob ×2·cnpg ensure-role-password/restore-drill/pgdump-hedge)에 인라인 핀돼 부분 갱신이 skew를
  만든다 — 전 소비처 단일 digest 일관성을 게이트로 강제하고 bump.yaml이 빌드 시 자동 재핀한다.
> 가드: `tests/gates/test_pgtools-digest.bats`, `tests/test_dr-drill.bats`

### 베스포크 공개 노출은 platform_hosts
- 골든패스 앱의 공개 DNS는 `infra/cloudflare/apps.json`(active&&public)이 SSOT지만(apps.json 아님이 함정), **베스포크 플랫폼
  컴포넌트(files·argocd-webhook 등)의 공개 노출은 `infra/cloudflare/dns.tf`의 `platform_hosts`(= `reserved-hosts.json` SSOT)**가 권위다
  — apps.json에 넣으면 audit-orphans가 apps/ 매니페스트 부재로 차단한다(files 온보딩서 실증). 예약 host 검사·
  dns-drift·create-app 예약어가 apps.json만 인지해 platform_hosts를 모르던 갭은 예약 host SSOT 통합(B9)으로 해소.

### 로컬 자산 백업 체인
- 런북(docs/runbooks/*.md — 건수는 `ls`가 SSOT)은 gitignored 로컬 전용 — 단일 디스크 단일 사본은 매체 유실에 무방비다(age-keys.md가 recovery
  키 보관처 포인터인데 그 문서 자체가 로컬 전용인 순환 의존). sealing key 백업(`backup-sealed-secrets-key.sh
  --verify`)과 대칭으로 런북 tarball을 age 암호화해 git 밖 매체에 버전드 보관하고(`backup-local-asset.sh`),
  `--verify`로 신선도를 게이트한다. verify-runbook-index는 owner 머신(런북 실재)에서 **양방향 fail-closed**
  (런북↔AGENTS 인덱스)로 드리프트를 차단한다.
> 가드: `scripts/backup-local-asset.sh`, `scripts/verify-runbook-index.sh`, `tests/test_backup-local-asset.bats`

### 재부팅 IP churn — instance 라벨 불안정
- 호스트 재부팅이면 파드 오브젝트가 그대로여도 CNI가 파드 IP를 재할당한다 → 스크레이프 타깃의 `instance`
  라벨이 바뀌어 **시계열 정체성이 갈린다**(KSM `10.42.0.208:8080`→`10.42.0.80:8080` 라이브 실측). 두 파괴 모드:
- **모드 A(increase 누적 누출)**: VM `increase()`는 새 시계열의 첫 샘플을 "0에서 증가"로 간주한다.
  `kube_pod_container_status_restarts_total`은 KSM이 k8s API `restartCount`에서 재파생하는 **상태-파생
  카운터**라 exporter 재시작에도 값이 0으로 리셋되지 않는다 → 누적 재시작수가 통째로 "15분간 N회"로 읽혀
  `PodCrashLooping`이 재시작>3인 파드 전부에 오발화했다(07-02·07-07·07-08·07-09 4회). 15분 뒤 자동 해소라
  사후 조사가 어렵다. **`alertmanager_*`·`vmagent_*`·`vmalert_*`는 프로세스-로컬이라 재시작 시 0 리셋 → 무해**
  — 판정 기준은 "rollup을 썼는가"가 아니라 "상태-파생 카운터인가"다. 해법: rollup **이전에** 집계로 instance
  제거(`increase(max by (namespace,pod,container,uid) (m)[15m:1m])`). `uid` 보존 필수(파드 재생성 리셋 처리).
- **모드 B(벡터 매칭 422)**: 구 instance 시계열이 staleness(~5분) 동안 살아 `on(namespace,pod)` 산술 조인의
  한쪽에 그룹당 2 시계열이 생긴다 → `duplicate time series on the left side of /` HTTP 422 → 룰 평가 실패 →
  `VmalertUnhealthy` 발화(`WALVolumeFilling`에서 실측). 양변을 `max by(...)`로 사전 집계해 1:1 매칭을 강제한다.
  집합 연산자(`and`/`or`/`unless`)는 중복에 422를 내지 않으므로 대상이 아니다.
- **왜 게이트를 4번 뚫었나**: required `vmalert -dryRun`은 파싱만 한다(두 모드 다 문법상 유효). 라이브 eval
  게이트도 무력 — 정상상태 데이터엔 결함이 부재하고 재부팅 과도구간에서만 발현해 merge-time 재현이 불가하다.
  유일한 형태가 expr 안티패턴 정적 lint다. 집계자는 반드시 `max` — `sum without(instance)`는 중첩 구간에 배가.
> 가드: `tools/check-alert-rules.ts`, `tests/test_alert_rules.bats`

### push 주기 > instant 룩백 → 룰 시리즈 구멍 → 무발화
- **push(스크레이프 아닌) 메트릭을 rollup 없이 맨 참조하면 그 룰은 발화하지 못한다.** vmalert의 instant 질의
  룩백은 `-datasource.queryStep`(**미지정 시 기본 5m** — 문서화되지 않은 상수)인데, push 주기가 그보다 길면
  매 주기 후반에 메트릭이 vmalert 눈에서 **사라진다** → 기록룰/알림 시리즈에 구멍 → `for:` pending이 매 주기
  **리셋** → 임계 시간을 영원히 누적하지 못한다. `ImageDigestDrift`가 이 형태로 **라이브 60일간 발화 0**이었다
  (기록룰이 10분 크론 push 메트릭 `ghcr_latest_digest`를 맨 참조 · 룩백 5m · `for: 20m`). 감시견이 fail-open으로
  죽어 있어도 **아무 신호가 없다**는 것이 이 함정의 본질이다.
- **해법**: 읽는 쪽에서 `last_over_time(m[W])`로 감싸 의미 불일치를 해소한다(`W ≥ push 주기`). r4가 같은 함정을
  이미 6번 방어하고 있었고 r6만 규약을 안 지켰다. cron을 조밀하게(`*/2`) 만드는 우회는 알림 생존을 vmalert의
  **기본 상수**에 의존시키는 fail-open by construction이라 기각했다.
- **왜 게이트를 통과했나**: required `vmalert -dryRun`은 **파싱만** 한다 — 이 죽은 식은 문법상 유효한 MetricsQL이다.
  실효 방어는 hermetic replay e2e(발화를 실제로 관측)뿐. 룰 작성자가 주석에 "라이브 미검증 → 발화 검증 필수"라고
  스스로 적어뒀으나 그 검증이 수행되지 않았다 — **미검증 주석은 가드가 아니다.**
- **레포 전역 가드(모드 C)**: e2e는 룰 2건만 증명한다 → 나머지 룰은 `tools/check-alert-rules.ts` 모드 C가 정적으로
  막는다(push 메트릭을 rollup 없이 맨 참조 / 윈도 < 주기 = FAIL). 주기는 생산자 CronJob의 cron에서 파생하고,
  `api/v1/import` 호출부가 레지스트리(`PUSH_METRICS`)에 없으면 FAIL한다 — **새 push exporter를 추가하고 메트릭
  등록을 잊는 경로**가 이 함정의 재발로다.
- **2차 실명(감시견의 감시견)**: 이 함정을 고쳐도 **exporter 자신이 죽으면** 룰은 다시 실명한다 —
  `ghcr_latest_digest`가 끊기면 기록 룰의 `[15m]` 윈도가 만료되며 좌변이 빈 벡터가 되고, exporter의 조용한
  실패 3모드(크론 미실행·push 실패·파드 기동 실패)는 **전부 초록 Job(exit 0)** 이라 `KubeJobFailed`가 원리적으로
  못 잡는다. → exporter가 **같은 push 페이로드에 하트비트**(`digest_exporter_last_success_timestamp`, bare
  타임스탬프-값)를 실어 보내고 `DigestExporterStale`(r4)이 그 침묵을 페이징한다(fail-closed: curl이 실패하면
  하트비트도 미적재). ⚠️ 하트비트 의미론은 **"push 경로 생존"이지 "수집 성공"이 아니다** — skopeo 전건 실패에도
  하트비트는 나가야 GHCR 장애가 "push 사망"으로 **오귀속**되지 않는다(producer 행위 테스트가 실행으로 강제).
  ⚠️ 신규 하트비트 룰은 **부트스트랩 경주**를 낳는다(최초 배포 시 이력이 없어 `absent(...)`가 즉시 pending) →
  `for:`를 **강제된** 최악 첫 하트비트 지연보다 크게 잡아야 한다. 그 상한은 추정이 아니라 매니페스트가 강제한다:
  `concurrencyPolicy: Replace`(⚠️ `activeDeadlineSeconds`는 **이미 실행 중인 Job에 소급 적용되지 않아** Forbid이면
  레거시 무제한 Job이 상한을 빠져나간다) + `activeDeadlineSeconds` + skopeo/curl 타임아웃 → `cron + 파드예산 +
  ADS < for:`. e2e preflight가 이 부등식을 매니페스트에서 파생해 강제한다(위반 = exit 2).
> 가드: `tests/gates/vmalert-drift-firing-e2e.sh`, `tests/gates/vmalert-bulkssd-firing-e2e.sh`, `tests/gates/vmalert-digest-stale-firing-e2e.sh`, `tests/gates/test_digest-exporter.bats`, `tests/gates/test_digest-exporter-producer.bats`, `tests/gates/skopeo-timeout-smoke.sh`, `tools/check-alert-rules.ts`, `tests/test_alert_rules.bats`

### rollup 윈도 상한 — 상태 게이지 vs 하트비트 비대칭
- 위 함정의 해법(rollup)에는 **상한**이 있다. rollup 윈도는 "최근 W 안에 본 값을 지금의 값으로 되살리는
  **상태 래치**"다 → 상태가 바뀐 뒤에도 구 상태가 W 동안 부활한다. 그 잔존이 `for:`를 넘기면 **상태 전이마다
  오발화**한다(`ImageDigestDrift`: 이미지 bump 후 구 digest가 좌변에서 부활 → phantom 드리프트 페이지).
- **산술**: `phantom 지속 = W − 룩백` → 발화 임계는 `W > for + 룩백`. 즉 `for=20m`·룩백 `5m`이면 W=30m은
  phantom 25m > 20m으로 **관측 가능하게 오발화**하지만 W=20~25m 구간은 **관측 레그가 구조적으로 못 본다** →
  경계는 관측이 아니라 **산술 단언**(`push ≤ W < for` preflight)으로만 닫힌다. 음성 레그·양성 레그·산술 단언
  셋이 상보적이다.
- **★ 비대칭(핵심)**: 같은 `last_over_time(m[W])`라도 윈도 상한의 유무가 갈린다.
  - **타임스탬프-값 하트비트(staleness)** — `time() - last_over_time(m[W]) > 임계`(r4의 `[2h]`/`[3d]`). **값이
    타임스탬프**이고 판정도 값으로 한다 → 윈도는 "마지막 하트비트를 어디까지 뒤질까"라는 **탐색 지평**일 뿐 →
    **상한 없음**(넓혀도 판정이 바뀌지 않는다).
  - **라벨-값 상태 게이지(identity)** — 값은 무의미한 1이고 **시리즈의 존재와 라벨 자체가 상태**다(r6의 `digest`).
    넓은 윈도는 구·신 상태를 **동시에** 현재라고 주장한다 → **윈도 < `for:`**.
  - 한 줄 규칙: **타임스탬프-값 하트비트 → 윈도 상한 없음 / 라벨-값 상태 게이지 → 윈도 < `for:`.**
  - ⚠️ **상한이 없다는 것이 하한도 없다는 뜻은 아니다.** 위 문장은 공급원이 **단조**일 때(값을 잡 자신이
    `date +%s`로 만들 때) 참이다. 값이 클러스터 **밖**에서 오면 공급원이 역행 샘플을 줄 수 있고, 그때는
    rollup 함수를 `max_over_time`으로 바꿔야 하며 윈도에 **하한**(`W ≥ 흡수할 폴 수 × push`)이 생긴다.
    ⇒ 「GitHub API는 낡은 스냅샷을 200으로 돌려준다 …」가 그 세 번째 축의 SSOT다.
- **동반 함정**: 좌변에 rollup을 걸면 시리즈가 **연속**이 되므로, `unless` 조인의 **우변(KSM 텔레메트리)이 사라질 때**
  아무것도 제거되지 않아 **전 대상이 거짓 사유로 발화**한다(원인 오귀속 — 진실은 "KSM이 죽었다"이고 그건
  `TargetDown` 소관). rollup에는 **우변 존재 가드**(`and on (key) (<우변 존재>)`)를 동반시켜라. 반대로 **우변
  셀렉터 자체에는 rollup 금지** — 구 상태가 부활해 진짜 드리프트를 억제하는 fail-open의 거울상이다.
> 가드: `tests/gates/vmalert-drift-firing-e2e.sh`

### bump-poll/** 예약 룰셋 — 인터록≠인증·정적 가드는 변경 감지기
- `tools/ensure-bump-pr.ts`의 force-push 소유권 검증은 **안전 인터록이지 인증이 아니다**: 워크플로 `git commit`은
  미서명이라(GitHub은 API로 만든 커밋만 서명) 적대적 `contents:write`가 author/committer/메시지를 위조할 수 있다.
  강제 가능한 유일 불변식은 서버측 ruleset(`infra/github`의 `github_repository_ruleset` — writer App 전용
  bump-poll/** 생성·push 예약). 신뢰 앵커라 **owner-local apply 전용**(CI 무인 apply 금지 — plan-only 드리프트).
- ⚠️ **R-46은 좁혀진 채 수용된 잔여**: ruleset은 ref 생성/push를 writer 전용으로 닫지만, 이미 존재하는 writer-생성
  head에 다른 base PR을 **여는 행위 자체(동시 PR 생성)는 못 막는다** — ruleset은 PR 생성을 게이트하지 않는다(git
  ref lease가 못 막는 것과 동일). 도구의 ③-b2 force-push 직전 재조회가 창을 마이크로초로 좁힐 뿐이다.
- ⚠️ **정적 CI 가드는 terraform resolved 의미를 완전 검증 불가**: 완전 검증은 `terraform plan`(GitHub API+백엔드
  자격)이 필요한데 신뢰 앵커 모델이 CI에서 그 자격을 배제한다. 개별 grep 단언은 red-team 8각도(간접화+decoy·
  meta-arg count/for_each·주석 카운트 회피·identity redirect·cross-file)에 전부 우회됐고, canonical freeze조차 리소스
  `/* */` wrap·추적 `*_override.tf` 병합으로 우회됐다. 그래서 가드는 **best-effort 3층 변경 감지기**(canonical freeze
  + no-block-comments + no-override; `.gitignore`가 `*_override.tf` 이중화)이고, **완전 보증은 owner-local 라이브
  검증**(apply 후 적대 push 거부 실측 + `gh api /repos/{o}/{r}/rulesets` 관측). 절차는
  `docs/runbooks-public/github-ruleset-verify.md`(tracked).
- ⚠️ **ruleset 거부 코드는 `GH006`이 아니라 `GH013`이다** — 실측 문구는 `GH013: Repository rule violations …
  Cannot create ref due to creations being restricted` / `… Cannot update this protected ref`(GH006은 구 분기보호 계열).
  GH006만 매칭하는 프로브·로그 파서는 룰셋 거부를 못 알아보고 **auth 실패와 구분하지 못해 거짓 인증**한다
  ("거부됐다"가 아니라 "ruleset 때문에 거부됐다"를 확증해야 한다). 매처는 GH013·`repository rule`·
  `cannot create`를 함께 커버하라. **org owner/repo admin에도 암묵 bypass는 없다** — 선언된 `bypass_actors`가
  유일한 경로다(owner PAT push가 실제로 GH013으로 거부됨을 실측).
> 가드: `tests/gates/test_bump_poll_ruleset.bats`

### emptyDir sizeLimit vs 런타임 다운로드 페이로드
- 컨테이너가 **부팅할 때마다 볼륨으로 받아오는** 페이로드(플러그인·모델·데이터셋)는 이미지 digest를 핀해도
  고정되지 않는다 — 업스트림이 키우면 그대로 커진다. `emptyDir.sizeLimit`을 실측치에 바짝 붙여 잡으면
  업스트림 릴리스 하나에 kubelet이 파드를 evict하고, Deployment가 즉시 새 파드를 만들어 **부팅↔evict 무한
  루프**가 된다. 노드 압박이 아니라 볼륨 단위 초과라 `DiskPressure`는 False로 남는다 — 노드 지표만 보면 원인을
  놓친다. 종료 사유도 OOMKill이 아니라 `Evicted`(+SIGTERM 정상종료 시 exit 0/`Succeeded`)라 OOM 알림에도 안 잡힌다.
- 라이브 사례(2026-07-25 grafana): 선언 256Mi(262,144 KiB) vs 실측 262,844 KiB — **0.27%(700 KiB) 초과**.
  18일간 잠복하다 VM 재부팅으로 emptyDir이 소멸하며 커진 세트를 재다운로드해 터졌다(도화선은 코드 변경이
  아니라 재부팅). 60초 주기로 파드 오브젝트가 400개 넘게 쌓였고, 파드마다 새 로그 스트림이 생겨 VictoriaLogs
  인제스트가 5.1배(28.5k→145k rows/h)·스트림 생성 18배로 뛰며 **victorialogs OOMKill 연쇄**까지 갔다.
  즉 이 함정은 단일 파드가 아니라 로그 파이프라인을 함께 무너뜨린다.
- ⚠️ **페이로드 축소가 항상 가능하진 않다**: grafana 13.1.0은 기본 preinstall 목록이 바이너리에 컴파일돼
  `GF_PLUGINS_PREINSTALL=""`로는 안 사라지고, 유일한 킬스위치 `GF_PLUGINS_PREINSTALL_DISABLED=true`는 명시
  요청한 데이터소스까지 함께 제거한다(프로브 3종 실측). 그런 경우 방어 수단은 **용량 마진뿐**이다.
- 대응: 선언값은 실측 페이로드의 **1.5배 이상**. cf. `vmagent`는 앱 내부 상한(`maxDiskUsagePerURL=450MiB`)을
  sizeLimit(512Mi) 아래에 둬 앱 쪽에서 같은 함정을 막는다 — 그 대응물이 없는 워크로드가 무방비다.
- ⚠️ **가드는 정적이다**: 선언값이 *기록된* 실측치 대비 마진을 지키는지만 본다. 미래 업스트림 증가 자체는
  못 잡으므로 페이로드 불변화(플러그인을 구운 핀 이미지)나 emptyDir 사용률 관측이 후속 과제로 남아 있다
  (릴리스 게이트에서 의식적으로 defer한 항목이다). 단 **태그 bump 시점**의 성장은 2026-08-27부터 앵커
  태그 대조(`MEASURED_AT_TAG` — 측정 앵커와 배포 태그의 불일치 = red)가 잡는다: 실측 13.1.0→13.1.3에서
  +10.5%(preinstall에 zipkin 신규)가 커밋 0건으로 지나간 것이 계기다. 남은 갭은 태그 고정 상태에서의
  preinstall 자동갱신 성장이다(emptyDir 사용률 관측 후속의 몫).
> 가드: `platform/victoria-stack/prod/test_grafana_plugin_budget.bats`

### GNU make가 recipe 종료코드를 자기 Error 2로 뭉갠다

가드 진입점이 도메인 부재를 `SKIP: <가드>: <이유>` 마커 + **exit 4**로 신호하는 규약을 세웠는데
(CONTRIBUTING '가드 skip 신호'), **make 타깃은 그 코드를 그대로 전달하지 못한다.**

```
$ make verify-posture KUBECONFIG_LIVE=/nonexistent
SKIP: verify-posture: /nonexistent 부재 — 라이브 posture 미평가. 먼저 make up
make: *** [verify-posture] Error 4     ← 메시지엔 4가 남는다
$ echo $?
2                                       ← 그러나 프로세스 종료코드는 2다
```

GNU make는 recipe 실패를 자기 규약(2 = errors)으로 보고한다. 따라서:

- **make 계층에서 관측 가능한 skip 신호는 `SKIP:` 마커 + 비-0까지다.** 종료코드 4는 스크립트를
  직접 부를 때만 보인다.
- 새 make 가드 타깃의 bats 래퍼에 `[ "$status" -eq 4 ]`를 쓰면 **반드시 실패한다** — `-ne 0` + 마커 grep으로 쓸 것.
- 2는 tools 규약에서 "사용법/파싱 오류"라 의미가 겹친다. make 계층에서 2를 원인으로 읽지 말 것.

> 가드: `tests/gates/test_guard-skip-signalling.bats`

### 열거 붕괴 → vacuous green (프로세스 치환·커맨드 치환·부정 카운트)

가드가 **열거 단계에서 조용히 0건을 받고 끝까지 떨어져 성공 메시지를 출력한다.** 명시적 skip 분기가
없으므로 skip 신호 규약(exit 4 + `SKIP:` 마커)으로는 안 잡힌다 — 루프가 0회 돌고 OK가 찍힐 뿐이다.
셋 다 라이브 재현했다.

**① 프로세스 치환은 열거자 실패를 전파하지 않는다.** `set -euo pipefail`이어도 `done < <(cmd)`의
`cmd` 종료코드는 셸에 보이지 않는다.

```
$ printf '#!/bin/sh\nexit 1\n' > shim/bun          # 워커를 실패시킨다
$ PATH=shim:$PATH bash scripts/check-app-netpol.sh
check-app-netpol OK (0 app-owned NetworkPolicy 검사, 위반 0)      rc=0
```

**② 커맨드 치환은 stdout만 캡처한다.** `bad=$(grep -r … dir/ || true)`에서 디렉토리가 사라지면 grep은
rc=2 + stderr로 죽는데, `|| true`가 rc를, 치환이 stderr를 삼켜 `bad=""`가 된다 → `[ -z "$bad" ]` 무조건 참.
`.github/workflows`를 리네임했을 때 `test_action-pinning`의 출력이 **baseline과 바이트 단위로 동일**했다.
⚠️ 같은 파일의 형제 단언이 `run bash -c`를 쓰면 bats가 stderr를 `$output`에 병합해 **우연히** fail-loud가
된다 — 한 스위트에서 일부만 무너지는 비대칭은 대개 이 차이다. 우연에 기대지 말 것.

**③ 부정 카운트는 "매치 0"과 "대상 0"을 구별하지 못한다.** `run grep -r … dir/; [ "$status" -ne 0 ]`은
grep rc=1(매치 없음)뿐 아니라 rc=2(디렉토리 부재)도 통과시킨다. 매치 없음은 정확히 rc=1이다.

**③-a `-eq 1`은 파일 피연산자만 닫는다 — 디렉토리는 못 닫는다.** ③의 처방(`-ne 0` → `-eq 1`)이
리네임·삭제를 탐지하는 것은 grep이 **에러 채널을 가진 경로 피연산자**를 들 때뿐이다.
2026-08-29 실측(GNU grep 3.12 / `ls`는 uutils coreutils 0.8.0 · GNU coreutils 9.10 / bash 5.3):

| 형태 | rc |
|---|---|
| `grep PAT <없는 파일>` · `grep -q PAT <없는 파일>` | **2** |
| `grep PAT <없는 파일> <있는 파일>`(다중 피연산자·무매치) | **2** |
| `grep -q PAT <없는 파일> <매치되는 파일>` | **0** — `-q`는 매치를 만나면 에러를 덮는다 |
| `grep -q PAT <디렉토리>`(`-r` 없이) | **2** |
| `grep -r PAT <없는/리네임된 디렉토리>` | **2** |
| `grep -r PAT <존재하되 비어 있는 디렉토리>` | **1** ← 무매치와 **구별 불가** |
| `ls <없는 경로>` · `ls <없는 경로> <있는 파일>`(다중 피연산자) | **2** |
| `ls <있는 디렉토리>/<무매치 글롭>`(셸이 리터럴을 그대로 넘김) | **2** ← 부재와 **구별 불가** |
| `ls <있는 디렉토리>` · `ls <있는 파일>` · `ls -A <빈 디렉토리>` | **0** |
| `ls <무매치 글롭>` + `shopt -s nullglob`(피연산자 0개) | **0** — **cwd를 나열한다** |
| `ls -R <읽을 수 없는 하위 디렉토리 포함>` | **1** ← ls가 1을 내는 **유일한** 경우(부분 실패) |

즉 디렉토리 피연산자에서 `-eq 1`이 잡는 것은 **경로가 사라지는 것**뿐이고, **도메인이 비는 것**은
원리적으로 못 잡는다. 재귀 열거·루프 구동 자리는 rc 하나로 닫히지 않는다.
⚠️ **측정 자체가 셸에 의존한다** — 대화형 셸이 `grep`을 ugrep 셰임으로 감싸는 환경이 있고, 거기선
`grep -q PAT <없는 파일> <매치되는 파일>`이 0이 아니라 **2**다(ugrep 7.8.4 실측). bats는 PATH의
GNU grep을 쓰므로 rc를 잴 땐 `/usr/bin/grep`으로 재라. 두 구현이 갈리는 곳은 이 한 행뿐이었다.

**같은 표의 `ls` 행은 한 칸 더 나쁘다 — 무매치와 부재가 같은 rc 2로 합쳐져 `-eq 1` 전환이 원리적으로
불가능하다.** grep과 달리 `ls`의 rc 1에는 "무매치"라는 뜻이 **아예 없다**(1은 재귀 중 하위 디렉토리
접근 실패 = 부분 실패 전용). 글롭이 안 맞으면 bash 기본값에서 셸이 **리터럴을 그대로 넘기므로** ls가
"그런 경로 없음"으로 2를 낸다 — 즉 `ls` 자리의 비-0 단언은 상수로 좁혀도 "매치 0"과 "디렉토리째
사라짐"을 가르지 못한다. 더 나쁜 쪽은 `nullglob`이다: 글롭이 지워져 피연산자가 0개가 되면 ls는
**cwd를 나열하고 rc 0**을 내므로 부재 단언이 조용히 뒤집힌다(`failglob`은 셸이 먼저 rc 1로 죽는
것이라 ls가 낸 1이 아니다).
⇒ 처방은 **rc를 버리는 것**이다 — 출력을 재거나(`run bash -c 'ls -A <dir>'` + `[ -z "$output" ]`, 아래
「처방(bats 부재 단언)」의 비공허 바닥값·양성 대조와 한 쌍으로), `find <dir> -maxdepth 1 -name '<pat>'`
로 바꾼다. `find`는 극성이 반대라 **경로 부재=rc 1 / 무매치=rc 0 + 빈 stdout**으로 둘을 가른다
(GNU findutils 4.10.0 실측).
⚠️ **여기서도 측정이 구현에 의존한다** — 호스트 grep이 ugrep인 것과 같은 이유로, Ubuntu 26.04의
`/usr/bin/ls`는 GNU가 아니라 **uutils coreutils 0.8.0**(패키지 `coreutils-from-uutils`)이다. 위 `ls`
다섯 행은 uutils 0.8.0과 GNU coreutils 9.10에서 **전부 일치**했다(부재·리터럴 글롭·nullglob·부분 실패).

**③-b 파이프 끝의 grep은 stdin을 읽는다 — 대상 부재의 rc 2가 rc 1로 눌린다.**
`sed … "$F" | grep -q PAT`에서 `$F`가 사라지면 sed만 rc 2로 죽고, grep은 **빈 stdin**에 무매치
rc=**1**을 낸다 → `-eq 1`이 그대로 통과한다. ⚠️ **`pipefail`도 이걸 고치지 못한다**: pipefail은
*가장 오른쪽*의 비-0을 취하는데 grep의 1이 sed의 2보다 오른쪽이다(실측: `set -o pipefail` 유무
양쪽 모두 rc=1). 반대로 grep이 **자기 경로 피연산자**를 들면 stdin과 무관하게 rc=2다
(`echo x | grep PAT <없는 파일>` = 2) — 위험한 것은 **피연산자 없는 파이프 종단 grep**이다.

**③-c `git grep`에는 "대상 부재" 채널이 아예 없다.** 레포 안에서는 무매치도, **존재하지 않는
pathspec**도 똑같이 rc=**1**이다(실측: 매치되는 파일이 레포에 있어도
`git grep -q hello -- <없는 경로>` = 1). 비-레포 디렉토리에서만 rc=**128**이다. 따라서 `git grep`
부재 단언에서 `-eq 1`은 리네임을 **전혀** 탐지하지 못한다 — pathspec 실재를 세는 양성 대조가
유일한 닫는 수단이다.

**처방(가드 스크립트의 열거)** — 열거를 **변수로** 받아 rc를 캡처하고(`scripts/lib/scan-floor.sh`의 `scan_enumerate`),
건수 바닥값을 건다(`scan_floor`). 바닥값 **수치는 소비자가 소유한다** — 열거자는 "글롭이 깨져 0건"과
"정당하게 0건"을 구별할 도메인 지식이 없다. 부정 카운트=0 형태에는 바닥값만으론 부족하고
**양성 대조**(같은 술어가 어딘가에서는 매치한다)가 함께 필요하다. 셀 때 `grep -c .`는 0건에서 rc=1이라
`set -e` 콜사이트의 함정이다 — `scan_count`가 그걸 흡수한다.

⚠️ **이건 skip 규약과 다른 채널이다.** 저긴 "검사할 도메인이 정당하게 없음"(exit 4 + `SKIP:`)이고
여긴 "열거를 못 했다"는 검증 실패(**exit 1**)다. 마커를 내면 사람이 정반대 뜻으로 읽는다.
⚠️ 바닥값은 **기본 모드에만** 적용한다. 픽스처 모드(`--root`/`--min-*`)는 정당하게 1~2건이라
무조건 적용하면 음성 테스트가 전부 red가 된다(실측). ⚠️ 바닥값은 래칫이 아니다 — 도메인이 줄지
않는 한 손댈 일이 없다.

**처방(bats 부재 단언)** — 부재는 `[ "$status" -ne 0 ]`이 아니라 **`[ "$status" -eq 1 ]`**로 쓴다
(선례: `tests/gates/test_app-token-sha-ssot.bats:28,35` — 주석이 이 함정을 명명한다). 그것으로
닫히는 것은 **파일 피연산자**뿐이다. 디렉토리·재귀·파이프 종단·루프 구동 자리는 `-eq 1`에 더해
둘을 **한 쌍으로** 건다 — **비공허 바닥값**(열거 도메인이 실재하고 비어 있지 않음을 setup에서
못 박는다: `tests/gates/test_app-token-sha-ssot.bats:8`)과 **양성 대조**(같은 술어·같은 피연산자가
어딘가에서는 매치한다: `tests/test_dr-drill.bats:161-163`). 하나만으론 부족하다 — 바닥값만 있으면
술어가 죽은 것을, 양성 대조만 있으면 도메인이 빈 것을 못 본다. 히어스트링(`<<<`)처럼 **경로
피연산자가 없는** 자리는 부재할 대상이 없어 이 함정의 대상이 아니다 — 다만 그 자리에서 `grep -qv`로
쓰면 **다른** 함정이다(아래 「`grep -qv`는 부재를 재지 않는다」).
⇒ **이 처방은 이제 정적으로 강제된다** — `scripts/check-bats-style.sh`의 `[ABS]` 레인이 철자(`-ne 0`)를
거부하고, `[ABS-REC]`/`[ABS-LOOP]`가 재귀·디렉토리·루프 자리에 비공허 바닥값과 양성 대조를 **접속사로**
요구한다(둘 중 하나만 지워도 red). 잔액은 `ABS_BASELINE` 래칫이 잰다(2026-08-30 hard-zero 수렴 — 그 뒤로는 새 자리가 곧 red다). ⚠️ 분모는 **grep 계열 + 경로
피연산자**뿐이다 — 히어스트링과 `run bash|bun|make`는 rc 알파벳이 달라 하나의 형태 규칙으로 말할 수 없다.
⚠️ `git grep`은 양성 대조만 요구한다 — ③-c대로 pathspec 부재 채널이 아예 없어서 파일시스템 바닥값이
닫을 수 있는 것이 없다.

> 가드: `tests/gates/test_scan-floor.bats`, `scripts/lib/scan-floor.sh`, `tools/lib/scan-floor.ts`, `scripts/check-scan-producers.sh`, `policy/ledger.rego`, `tests/test_ledger.bats`, `scripts/check-bats-style.sh`, `tests/gates/test_bats-style.bats`

### `grep -qv`는 부재를 재지 않는다 — 줄 단위 반전이 전칭을 존재로 바꾼다

- **병**: `-v`는 **줄 단위** 반전이다. 따라서 `grep -qv TOKEN`이 답하는 질문은 "TOKEN이 없다"(∀¬)가
  아니라 **"TOKEN이 없는 줄이 하나라도 있다"(∃¬)**다. 피연산자가 두 줄 이상이면 TOKEN이 출력에
  **있어도** rc 0이라, 부재 단언 자리에서 이 관용구는 사실상 항진명제다.
  2026-08-29 실측(GNU grep 3.12 · bash 5.3 — 이 호스트는 `/usr/bin/ls`가 uutils인 사례가 있어 판본을
  적는다. 측정은 `/usr/bin/grep`으로):

  | stdin | `grep -qv 'a'` rc | 부재 단언으로서 |
  |---|---|---|
  | `a\nb`(토큰이 **있고** 다른 줄도 있다) | **0** | **거짓 통과** — 항진의 자리 |
  | `a\na`(모든 줄이 매치) | 1 | 옳다 |
  | `a`(1줄, 매치) | 1 | 우발적으로 옳다 |
  | `x`(1줄, 무매치) | 0 | 옳다 |
  | 빈 입력 | 1 | **거짓 실패** — 대상이 통째로 사라지면 부재인데 red다 |

  마지막 행이 두 번째 얼굴이다: 같은 한 줄이 **진짜 존재에서 green, 진짜 부재에서 red**를 낼 수 있다.
- **「열거 붕괴 → vacuous green」과 다른 축이다.** 저긴 **도메인이 비는 것**(열거가 0건)이고 여긴
  **술어의 양화사가 뒤집히는 것**이다. 도메인이 완전히 정상이어도 — 줄이 여럿이기만 하면 — 발생한다.
  겹치는 지점은 하나뿐이다: 둘 다 rc 하나를 곧이곧대로 읽어서 생긴다.
- **인-레포 실측 — 「처방 도달」 축 그 자체**(한 자리에서 실증된 처방이 형제에 안 닿았다):
  - `infra/tailscale/test_provider_scopes.bats:75` — 2026-08-19 적대 검증이 `grep -qvF`를 항진으로
    적발했다. 고쳤고 근거 주석까지 남겼는데 **SSOT에는 안 올렸다.** 이 등재가 그 부채다.
  - `tests/gates/test_host-ports.bats:11-20` — 같은 관용구 **6곳**. 5곳이 실측 항진이었고 남은 1곳은
    진단 문구가 마침 1줄이라 우발적으로만 옳았다. 전건 전환 + 파일 머리에 규약 고정.
  - `tests/gates/test_ops-repin.bats`(적발 시점 :34) — `echo "$output" | grep -qv "$OLD"`.
    바로 윗줄이 NEW digest의 실재를 단언하므로 OLD가 남아도 "OLD 없는 줄"이 항상 존재한다 → rc 0
    (재현: OLD·NEW 두 줄을 만들어 넣으면 OLD가 **있는데** rc 0).
  - 우발적으로 옳은 표본: `platform/cnpg/prod/test_restore_drill.bats:87-88`의
    `printf '%s' "$cpu" | grep -qv '^null$'` — 피연산자가 yq 스칼라 **1줄**이라 오늘은 맞다.
    그 값이 여러 줄이 되는 날 아무 신호 없이 항진이 된다.
- ⇒ **처방은 셋이고 각각 무엇을 재는지가 다르다.**
  - ① **히어스트링 + `-eq 1`**(기본형): `run grep -qF -- TOKEN <<<"$out"` + `[ "$status" -eq 1 ]`.
    `<<<`는 경로 피연산자가 없어 rc 2 채널이 아예 없으므로 1이 **정확한 상수**다(빈 문자열·미설정
    변수도 1 — 실측). 그 대가로 "출력이 통째로 비었다"가 이 rc에는 안 보이니, 위
    「처방(bats 부재 단언)」의 **비공허 바닥값 + 양성 대조**와 한 쌍으로 건다.
  - ② **건수 재기**: `run grep -cF -- TOKEN <<<"$out"` + `[ "$output" -eq 0 ]`. 값을 보므로 "몇 개
    남았나"를 진단에 실을 수 있다. ⚠️ `grep -c`는 0건에서 **rc 1**이다(실측) — `$status`로 닫으면
    ①과 같아지고, `set -e` 콜사이트에서는 그 1이 스크립트를 죽인다(`scan_count`가 흡수하는 함정).
  - ③ **1줄 보장**: 피연산자가 정확히 1줄임을 같은 자리에서 못 박은 뒤에만 `-qv`가 옳다. ①·②가 더
    짧으니 새로 쓸 이유는 없다 — 남아 있는 `-qv`를 살릴지 판정할 때만 쓰는 기준이다.
  - ⚠️ 부정을 중간 `!`로 쓰지 마라(「bats bash 3.2 중간 [[ ]] 침묵 통과」) — `run` + `[ ]`뿐이다.
- ⇒ **정적으로 강제된다(hard-zero).** `scripts/check-bats-style.sh`의 `[QV]` 레인이 `-q`와 `-v`가 같은
  옵션 클러스터에 있는 자리를 거부한다(파이프 종단 또는 문장 선두). 라이브 0건이라 래칫할 부채가 없다 —
  잔존 표기 4곳은 전부 이 함정을 **설명하는** 주석이고 검출기가 주석 줄을 먼저 건너뛴다.
  ⚠️ 필터로 쓰는 `| grep -v '^---'` 류는 `-q`가 없어 대상이 아니다 — rc를 판정으로 쓰지 않기 때문이다
  (이 레포에 20곳 넘게 있는 정당한 관용구다). `[ABS]`와 **같은 숫자로 접지 않는다**: 저건 run/status
  짝의 rc 철자 문제고 이건 술어의 양화사가 뒤집히는 문제라, 한 잔액으로 합치면 그 수가 무엇의 부채인지
  말할 수 없게 된다.

> 가드: `scripts/check-bats-style.sh`, `tests/gates/test_bats-style.bats`

### PreToolUse 훅 종료코드 — fail-closed는 exit 2뿐

Claude Code PreToolUse 훅의 종료코드 어휘는 다른 가드 계층과 **다르다**: 0=허용 · 2=차단(stderr가
Claude에 전달) · **그 외 비-0 = 비차단 에러**(사용자에게 stderr만 보이고 도구는 그대로 실행된다).

따라서 레포 종료코드 규약(1=검증 실패 · 4=skip)을 이 계층에 복사하면 **경고만 찍히고 편집이 통과한다.**
`set -e`도 같은 이유로 위험하다 — 무엇이든 -e로 죽으면 rc=1(=비차단)이 되어 조용히 통과한다.
`manifest-guard.sh`가 실제로 그랬다: jq 부재/실패 시 `*.enc.yaml` 직접 편집이 rc=0으로 허용됐고
(stderr 0줄), 그건 AGENTS.md 최상위 금칙의 **유일한 자동 차단선**이었다.

- 훅 안의 파서 붕괴는 "도메인 밖"이 아니라 **차단 사유**다. matcher가 `Edit|Write|MultiEdit` 전용이면
  그 도구들은 항상 `file_path`를 가지므로, 키는 있는데 값이 없으면 언제나 파서가 죽은 것이다.
- 외부 명령 의존을 0으로 줄인다(bash 내장 파싱 폴백). `input="$(cat)"`조차 cat이 PATH에 없으면
  비차단 rc가 된다.
- blanket `command -v jq || exit 2` 프리플라이트는 쓰지 않는다 — 도구 없는 환경에서 모든 편집을
  막아 세션을 못 쓰게 만든다. 오탐 0 원칙과 fail-closed는 **폴백**으로 양립시킨다.

> 가드: `tests/gates/test_manifest-guard.bats`

### GHA job-level skip은 run conclusion에 안 보인다 — 스텝 전부 skip이어도 job은 success

GHA job conclusion 어휘는 `success|failure|cancelled|skipped`뿐이고, 여기엔 **"자격이 없어 아무것도
안 했다"가 없다.** 두 게이트 계층이 서로 다른 흔적을 남긴다:

- **job-level 게이트**(`if: needs.preflight.outputs.configured == 'true'`) → job이 `skipped`로 남는다.
  `needs.<job>.result`로 **관측 가능**하다.
- **스텝-레벨 게이트**(각 스텝의 `if: steps.pf.outputs.configured == 'true'`) → job이 뜨고, 스텝을
  전부 skip한 뒤 **`success`로 끝난다.** run conclusion·job conclusion 어디에도 흔적이 없다.

라이브 실측(2026-07-27, `gh run view <id> --json jobs`): `tf-reconcile`의 `drift-github`·`drift-tailscale`은
`TF_GITHUB_TOKEN`·`TF_TAILSCALE_OAUTH_ID`가 Actions 시크릿에 **없어서** 스텝 1(preflight) 외 전부
skipped인데 job conclusion은 둘 다 `success`였다. 즉 신뢰 앵커(branch protection `contexts=["gate"]` ·
CI Actions 시크릿 · tailscale ACL/auth-key)의 드리프트 감시가 **한 번도 실행된 적 없이** 매 30분
초록을 보고하고 있었다. 앞선 세션의 감사는 job conclusion만 봐서 이걸 "잠복 경로"로 오판했다 —
**스텝 conclusion까지 봐야 한다.**

⚠️ **알림을 감시 대상 job 안에 두면 함께 죽는다.** skip된 job은 스텝을 **0개** 실행한다 —
`if: always()`도 예외가 아니다(그 job이 아예 스케줄되지 않는다). 그래서 실패 알림을 그 job에 얹어
두면 정확히 신호가 필요한 순간에 0이 된다.

⚠️ **이 계층엔 `exit 4`(skip) 채널이 없다.** 규약을 쓸 스텝 자체가 실행되지 않기 때문이다. 관측은
게이트 **밖의 별도 job**에서만 가능하다:

- 게이트 밖 `accounting` job + `if: ${{ !cancelled() }}`. 상태함수를 빼면 기본 `success()`가 걸려
  **감시자가 감시 대상과 같은 운명에 묶인다**(needs 중 하나가 skip되면 회계도 skip).
- 스텝-레벨 게이트는 `outputs.executed` 승격이 필수다 — 없으면 회계가 볼 수 있는 값이 존재하지 않는다.
- 판정 기준은 원장(`policy/workflow-readiness.json`)이고, **선언되지 않은 미설정은 통과할 수 없다**.
  선언된 갭은 면제가 아니라 **계상**이다(매 run 로그·job summary에 남고 원장이 이유를 진다).
- **실패는 미실행으로 세지 않는다** — 이미 run을 빨갛게 만들고 자기 알림을 낸다. 회계가 잡는 것은
  *조용한* 미실행뿐이고, 실패를 겹쳐 세면 원인이 두 번 오귀속된다.

⚠️ **자격 게이트 ≠ 도메인-크기 게이트.** "검사 대상이 0건이라 skip"은 열거 붕괴 클래스라 처방이
바닥값이다(위 「열거 붕괴 → vacuous green」). 탐지기가 둘을 가르는 선은 **자격 변수의 공백 검사**다 —
`secrets.*`/`vars.*`에서 온 env를 `[ -n "$X" ]`로 재는 형태만 준비상태 게이트로 센다. 이 선이 없으면
terraform `drift=false` 같은 **결과 플래그**가 전부 준비상태로 오탐된다(실측: 한 워크플로에 3곳).

> 가드: `tools/check-workflow-readiness.ts`, `policy/workflow-readiness.json`, `tests/gates/test_workflow-readiness.bats`, `infra/_tests/test_tf_reconcile.bats`

### 이미지 핀의 *존재* ≠ *일치* ≠ *소유자* — 하드코딩 소비처 목록은 자기 자신에게만 정확하다

세 가지 서로 다른 질문이 하나로 뭉뚱그려져 있었다.

1. **핀이 있는가** — `scripts/check-image-pins.sh`가 본다. `@sha256:`이 붙어 있으면 통과다.
2. **핀이 일치하는가** — 아무도 안 봤다. 같은 `repo:tag`가 서로 다른 digest로 갈려 있어도 ①은 통과한다.
3. **그 digest를 누가 갱신하는가** — 아무도 안 봤다.

라이브 실측(2026-07-28): `pg-tools:18-rclone`이 두 digest로 갈려 있었다. `tools/repin-ops-image.ts`(당시 `repin-pgtools.ts`)의
`CONSUMERS`에 등록된 4파일은 GHCR 현재값이었고, 등록 안 된 2파일
(`platform/adguard/prod/rewrite-reconciler.yaml` · `platform/victoria-stack/prod/pvc-du-exporter.yaml`)은
**낡은 digest에 영구히 묶여** 있었다 — 재핀 대상이 아니므로 새 빌드가 나와도 영원히 그 상태다.

⚠️ **하드코딩 목록은 자기 자신에 대해서만 정확하다.** 이 사례에서 산출물 **세 개**가 서로는 일치하고
레포와는 어긋났다: 재핀 도구의 `CONSUMERS` 4파일 · 그 4파일을 다시 하드코딩한 `test_pgtools-digest.bats`의
`FILES` · "5개 소비처(4파일)"이라는 헤더 주석. 가드는 **이미 일치하도록 갱신된 닫힌 집합 안에서** 일치를
확인했고, 재핀은 `changed/CONSUMERS.length`로 성공을 보고했다. 두 번째 @test는 이름이
"registry drift guard"였지만 목록에 **없는** 사이트가 새로 생기는 것을 원리적으로 탐지할 수 없었다.
⇒ 목록을 **계산하면**(레포 열거) 그 드리프트가 원리적으로 불가능해진다. 남는 위험은 열거 붕괴뿐이고
그건 바닥값이 막는다.

⚠️ **freshness 소유자 ≠ digest 소유자.** helm 차트 내부 기본 이미지는 차트 **버전**이 Renovate 소유라
freshness는 있지만, 렌더 시점에 mutable tag로 해석되므로 **digest 소유자가 없다**. `check-image-pins.sh`
헤더는 이를 "Renovate pinDigests 관할"이라고만 적었는데 그건 절반만 참이다 — 차트 tarball은
`platform/*/prod/charts/`에 캐시되고 그 경로는 **gitignored**이며 `renovate.json`의 `ignorePaths`에도
`**/charts/**`로 들어 있다. Renovate는 **없는 파일을 핀할 수 없다**. 라이브 실측: 구동 컨테이너 22개가
mutable tag였다(argocd ×5 · cert-manager ×3 · tailscale ×3 · sealed-secrets · cnpg-operator · traefik 등).

⚠️ **base64 안의 이미지 참조는 어떤 스캐너에도 안 걸린다.** `platform/cnpg/barman-plugin/manifest.yaml`의
`SIDECAR_IMAGE`는 Secret의 `data:`에 base64로 들어 있어 (a) `image:` grep에 안 걸리고 (b) Secret이라
스캐너가 안 보고 (c) 벤더 경로라 핀 게이트·Renovate 양쪽에서 배제됐다 — **커버리지가 정확히 0**이었고
디코드하면 tag-only(`plugin-barman-cloud-sidecar:v0.13.0`)다. CNPG가 이 값을 읽어 Cluster 파드에
사이드카로 주입하므로 WAL 아카이빙 경로 자체다.
⚠️ 디코드는 **줄바꿈 조각을 이어 붙여야** 한다. YAML 블록 스칼라라 둘째 줄이 10자였고, 줄 길이 하한을
16으로 두면 첫 줄만 디코드돼 `…sidecar:v`로 **잘린 값**이 나온다(참조는 잡되 값이 틀리면 태그 일치
검사·원장 대조가 전부 어긋난다). 판정은 길이가 아니라 디코드 결과의 **모양**이 해야 한다.

⚠️ **소유자 없음은 결함이 아니라 선언 대상이다.** 벤더 파일·차트 내부 이미지는 정당하게 무소유일 수
있다. 원장(`policy/image-ownership.json`)에 why·freshness·since·owner_action과 함께 적고, **선언되지
않은 무소유는 통과할 수 없다**. 매치되지 않는 선언(죽은 선언)도 red다 — 아무도 대조하지 않는 주장은
원장이 아니다.

> 가드: `tools/check-image-ownership.ts`, `policy/image-ownership.json`, `tests/gates/test_image-ownership.bats`, `tests/gates/test_pgtools-digest.bats`

### vmalert replay rulesDelay — 비율 아닌 절대 지연·체인 없으면 순수 낭비

`--replay.rulesDelay`는 vmalert replay가 **룰마다 한 번씩** 자는 값이라, 이 계열 게이트(발화 e2e)의
벽시계는 사실상 그 sleep의 총합이다:

    벽시계 ≈ (룰 파일의 룰 수) × rulesDelay × (레그 수)

라이브 실측이 이 모델과 1~3% 안에서 맞는다 — drift = r6(6룰) × 8레그 × 4s → **192s 예측 / 194s 실측**,
digest-stale = r4(18룰) × 7레그 × 4s → 504s 예측 / 459s 실측. 즉 이 게이트들이 느린 이유는 계산량도
네트워크도 아니고 **전부 대기**다. 그래서 이 값은 "CI가 느리다"는 압력을 상시로 받는다.

⚠️ **비율(rulesDelay ÷ flushInterval)을 지키면 낮춰도 된다 — 는 틀렸다. 실측으로 기각됐다.**
4s→1s로 내리면서 `--remoteWrite.flushInterval`을 500ms→100ms로 함께 줄여 비율을 8×에서 **10×로 키웠는데도**
drift 하네스가 죽었다: `HARNESS FAULT (L1): app:image_digest_drift record produced 0 samples`. 이유는
방지선이 지키려는 대상이 비율이 아니기 때문이다 — alert 룰은 record 룰이 remoteWrite한 시리즈를
query_range **1회**로 읽고, 그 사이에 필요한 것은 "flush가 몇 번 일어났나"가 아니라 **적재→질의 가능까지의
절대 시간**이다(HTTP + vmsingle 인입 지연이 지배한다). flushInterval은 이미 rulesDelay보다 훨씬 작아
제약이 아니었다.

⚠️ 이 실패는 **조용한 오답이 아니라 간헐적 거짓 RED**다. 그래서 더 나쁘다 — 무발화는 아무도 못 보지만,
가끔 빨개지는 게이트는 사람이 "또 그거네" 하고 재실행하다가 결국 끈다. 속도를 위해 이 값을 만지는
변경은 **1회 통과로 검증됐다고 말할 수 없다**(반복 실행이 필요하다).

✅ **속도는 값을 깎아서가 아니라 대기가 불필요한 곳을 찾아서 얻는다.** rulesDelay가 존재하는 이유는
오직 record→alert 체이닝뿐이므로, **체인이 없는 룰 파일에서는 그 대기가 순수 낭비다**. 실측: `r4`는
record 룰이 **0개**라 체인이 성립할 수 없고(digest-stale·bulkssd), `r6`만 `app:image_digest_drift` 체인을
가진다(drift·gha-liveness). 그래서 지연을 룰 파일에서 **파생**한다(`vme_rules_delay` — 체인 4s / 무체인 1s /
파싱 실패 4s fail-closed). 결과: 병렬 e2e 459s → **195s**(3회 반복 194/195/196s, 실패 0), 레그 판정은 동일.

⚠️ 파생기는 **양방향 대조**가 없으면 무력하다 — 항상 보수값을 돌려주면 속도 이득이 조용히 사라지고
(red가 나지 않는다), 항상 빠른 값을 돌려주면 레이스가 돌아온다. 그래서 게이트는 실제 배포 룰
r6(체인 있음)·r4(체인 없음) 양쪽을 대조군으로 쓴다. 또한 파생값을 **계산만 하고 플래그엔 리터럴을 넘기는**
변이가 통과했었다(mutation으로 발견) — 단언은 대입문이 아니라 **소비 지점**에 걸어야 한다.

> 가드: `tests/gates/test_vmalert-e2e-replay-timing.bats`, `tests/gates/lib/vmalert-e2e.sh`

### make -n은 드라이런이 아니다 — 레시피의 $(MAKE)는 -n에서도 실행된다

GNU make는 레시피 줄에 `$(MAKE)`(또는 `${MAKE}`)가 있으면 `-n`·`-t`·`-q`에서도 **그 줄을 실제로 실행한다**.
문서화된 동작이다 — 재귀 make에 플래그를 전파해 서브-make가 자기 몫을 출력하게 하려는 것이다. 그래서
`$(MAKE)`가 붙은 줄만은 "출력"이 아니라 "실행"이 된다.

⚠️ 이 레포에서 그게 위험한 이유는 `make -n <target>` 출력을 **데이터로 읽기 때문**이다:
`tools/check-ci-parity.ts`(mirrored 스텝이 실제로 `make ci`에 있는지 대조)와
`tools/check-guard-authority.ts`(venue 수집 — Makefile 텍스트 파싱 대신 make 자신에게 해소를 맡긴다)가
둘 다 그 출력을 파싱한다. 즉 정적 검사여야 할 것이 갑자기 부수효과를 갖는다.

라이브 실측(2026-07-28): 게이트 스텝을 가독성 때문에 `ci-containerized`/`ci-firing-e2e` 서브 타깃으로
묶고 `@$(MAKE) --no-print-directory ci-containerized`로 호출했더니, **`make -n ci` 한 번에** telegram
render e2e·vector validate·vmalert validate가 통째로 실행되고 vector 이미지 pull까지 일어났다.
`bun tools/check-ci-parity.ts`(내부에서 `make -n ci` 호출)를 돌린 것뿐인데 docker가 움직였다.

✅ 처방: 게이트 스텝은 **각자 자기 레시피 줄에** 둔다. 장황해지지만 (a) 드라이런이 안전하고
(b) 패리티 대조가 래퍼가 아니라 **스텝 단위로 구체적**이 된다(`local: "vector-validate.sh"`가
`make -n ci` 출력에 실재하는지 볼 수 있다 — 래퍼 하나로 묶으면 "래퍼가 호출된다"까지밖에 증명 못 한다).
가드는 레시피 줄(탭 시작)에 `$(MAKE)`가 없음을 강제한다 — 주석의 설명 문구는 대상이 아니다.

> 가드: `tests/gates/test_make-ci-parity.bats`, `tools/check-ci-parity.ts`, `policy/ci-parity.json`

### tracked 열거 게이트는 untracked 파일을 아예 안 본다 — 로컬 초록이 CI를 예고하지 못한다

이 레포의 게이트는 대부분 `git ls-files`로 대상을 열거한다. 하드코딩 글롭이 리네임에 조용히 0매치되는
것을 피하려는 **의도적 선택**이고 그 자체는 옳다. 부작용이 하나 있다: **untracked 파일은 측정 대상이
아니다.** 그런데 커밋하는 순간 CI에서는 측정된다 — 즉 `make ci` 초록과 `gate` red가 양립한다.

라이브 실측(2026-07-28): 새 `tools/check-ci-parity.ts`를 `git add` 전에 `make ci`로 검증해
**1671건 전건 초록**을 받고 커밋했는데, 직후 CI가 `tools/*.ts` shebang 금지 규약 위반으로 red를 냈다.
로컬이 그 파일을 **아예 보지 않은** 것이지 검사가 느슨했던 게 아니다. 하필 그 PR이 "make ci가 gate를
재현한다"를 강제하는 PR이었다.

⚠️ 이건 "재현했는데 실패"가 아니라 **"재현하지 못했다"**이다. 그래서 실패가 아니라 **skip 신호**
(마커 + exit 4)가 맞다 — CONTRIBUTING '가드 skip 신호' 규약 그대로다.

✅ `make ci`의 **첫 전제**(`ci-guard-tracked`)가 게이트 대상 디렉토리의 untracked 파일을 찾아 마커 + exit 4를
낸다. 첫 전제인 이유는 1분짜리 `chart-test` 앞에서 끊기 위해서다. 가드에는 양성 대조가 붙어 있다 —
깨끗한 트리에서 통과해야 한다(항상 죽는 가드는 아무도 안 쓰고 곧 제거된다).

> 가드: `tests/gates/test_make-ci-parity.bats`, `Makefile`

### 체이닝 레이스의 두 번째 얼굴 — record는 있는데 ALERTS가 전무(병렬화가 깨운 flake)

vmalert replay에서 alert 룰은 record 룰이 remoteWrite한 시리즈를 `query_range` **1회**로 읽는다. record가
아직 질의 가능하지 않으면 결과가 통째로 비어 **버그가 아닌데 RED**가 된다. 그래서 `--replay.rulesDelay`를
넉넉히(4s) 준다 — 여기까지는 기존 항목(「vmalert replay rulesDelay」)과 같다.

⚠️ 그런데 하네스의 fail-closed 가드는 **`record == 0`만** 보고 있었다. 라이브 CI 실패(2026-07-28,
run 30340280961)는 정확히 그 반대편이었다:

| | record 샘플 | firing | pending |
|---|---:|---:|---:|
| 로컬 | 58 | 19 | 40 |
| CI(실패) | **58** | **0** | **0** |

record 데이터는 **완전히 동일**한데 alert이 그걸 하나도 못 읽었다. `pending=0`이라 "발화 창이 좁았다"가
아니라 **한 번도 참이 안 됐다**는 뜻이다.

⚠️ **대조 알림이 이 축을 못 막는다.** 이 하네스의 생존 대조군(`ArgoCDOutOfSync`)은 **체이닝되지 않은**
룰이라 레이스에 걸려도 정상 발화한다 — "vmalert가 아무것도 안 썼다"는 잡지만 "체인의 하류만 비었다"는
못 잡는다.

⚠️ **왜 지금 나타났나: 병렬화가 깨웠다.** 발화 e2e 4종을 병렬로 돌리기 시작하면서(gate 시간의 77%였다)
러너 경합이 커졌고, 4s가 덮던 적재 지연을 가끔 초과하게 됐다. 병렬 도입 이후 약 6회 중 1회(~17%).
값을 올리는 대안(4s→6s)은 drift를 196s→292s로 만들어 방금 줄인 gate 시간을 그만큼 되돌린다.

✅ 처방: `require_engaged <leg> <alert>` — engage를 기대하는 레그에서 **ALERTS 시리즈가 통째로 0**이면
replay를 **1회 재시도**하고, 그래도 0이면 HARNESS FAULT(exit 2)로 죽는다.
★ 이 서명이 실제 룰 결함과 **구별되기 때문에** 재시도가 정당하다: 룰이 rollup을 잃는 등 진짜로 깨지면
알림은 *engage는 한다*(결함 픽스처 L4가 `pending=132 / firing=0`을 낸다). "ALERTS가 통째로 0"은 룰이
아니라 **하네스가 아무것도 못 읽은 것**이다. 즉 재시도는 실패를 숨기는 장치가 아니라 **레이스인지
결함인지를 판별하는 장치**다 — 레이스면 재시도가 성공하고, 결함이면 두 번 다 0이라 죽는다.
재시도 발생 사실은 `RETRY (…)` 로그로 반드시 남긴다(조용한 재시도 금지).

⚠️ 재시도는 같은 레그를 다시 돌리므로 컨테이너 이름(`$label-$$`)이 충돌한다 → replay 진입 시
기존 컨테이너를 먼저 제거한다.

> 가드: `tests/gates/vmalert-drift-firing-e2e.sh`

### 소스의 리터럴 NUL 한 바이트가 그 파일을 모든 grep 가드에게 투명하게 만든다

`grep`은 NUL 바이트가 있는 파일을 **바이너리로 판정**하고 `Binary file … matches` 한 줄만 낸다 —
**내용은 한 줄도 출력하지 않는다.** 그래서 `grep -o`로 값을 뽑는 가드에게 그 파일은 존재하지만
**아무것도 들어 있지 않은 파일**이 된다. 매치 여부(`grep -c`)는 1을 돌려주므로 "파일은 스캔했다"는
착시까지 준다.

라이브 실측(2026-07-29): `tools/check-image-ownership.ts`가 맵 키 구분자로 **리터럴 NUL 바이트**를
소스에 박고 있었다 — `owners.set(\`${r.file}<NUL>${r.ref}\`, owner)`. join·split이 일관돼 **동작은
정상**이었고 typecheck·전 게이트가 초록이었다. 발견 경위는 우연에 가깝다: SCAN 마커의 파생 로스터를
만들자 정적 콜사이트 집합에서 이 파일의 라벨만 조용히 빠졌다(정적 8 vs 런타임 9). 파생 대조가 없었다면
"가드가 돌았고 초록인데 대상 하나를 아예 안 본" 상태가 그대로 남았다.

⚠️ 영향 범위는 이 레포에서 넓다 — venue 수집·마커 추출·핀 검사 등 **grep 기반 가드 전부**가 그 파일을
건너뛴다. 파일 하나가 조용히 회계 밖으로 나가는 것이고, 그건 이 캠페인이 지우려는 무측정의 전형이다.

✅ 처방: 구분자가 필요하면 **이스케이프**를 쓴다(TS `\u0000` · 셸 `$'\000'`). 런타임 값은 같고 파일은
텍스트로 남는다. 재발 가드는 `check-skeleton`이 소유한다 — 추적된 **소스 확장자** 파일에 NUL이 있으면
red(대상은 확장자로 파생한다. 손 관리 목록을 두면 그 목록이 다음 드리프트다. 이미지 등 정당한
바이너리 자산은 확장자로 자연히 빠진다).

⚠️ 검출을 `grep "$(printf '\000')"`로 짜면 안 된다 — **명령 치환이 NUL을 삼켜 빈 패턴**이 되고, 빈
패턴은 **모든 파일에 매치**한다(실측: 추적 878건 전건 red). 열거가 아니라 **패턴이 붕괴**하는 형태라
증상이 정반대(전건 통과가 아니라 전건 실패)이지만 뿌리는 같다. 검출은 `tr -d '\000'`으로 지운 스트림과
원본을 `cmp`하는 방식이 POSIX 범위에서 안전하다.

> 가드: `scripts/check-skeleton.sh`, `tests/gates/test_scan-floor.bats`

### 디스크 자기-상한이 자기 볼륨 선언보다 크다 — GB(10⁹) vs Gi(2³⁰)

워크로드가 **자기 데이터 크기 상한**을 바이트로 선언할 때(VictoriaLogs `-retention.maxDiskSpaceUsageBytes`,
vmagent `-remoteWrite.maxDiskUsagePerURL`), 그 값이 **자기가 쓰는 볼륨의 선언 용량보다 클 수 있다**.
그러면 같은 파일이 모순된 두 숫자를 말한다 — "이 볼륨은 10Gi다"와 "내 데이터가 15GB 될 때까지 축출하지
않는다". 라이브 실측(2026-07-29): `victorialogs.yaml`이 정확히 그 상태였다(**139.7%**).

⚠️ **단위 혼동이 핵심이다.** `GB`=10⁹ · `Gi`=2³⁰. 15GB(1.50e10) > 10Gi(1.074e10)인데, 접미사만 훑으면
"15 > 10"으로도 "GB < Gi"로도 잘못 읽힌다. 판정은 반드시 **바이트로 환산**해서 해야 한다.

⚠️ **"언젠가 터진다"가 아니라 지금 결함이다.** 그 상한은 한 번도 발동한 적이 없었다 — 축출은 전부
`retentionPeriod=14d`가 하고 실사용은 상한의 1/69였다. 그래도 결함인 이유는 셋이다: ① 용량 계획이
PVC 숫자를 읽으면 틀린 답을 얻는다 ② 쿼터를 강제하는 provisioner로 바뀌는 순간 앱은 15GB까지 쓸 수
있다고 믿는 채로 볼륨 한계에서 ENOSPC를 맞는다 ③ 형제 선언(vmagent 450MiB < 512Mi emptyDir)은 올바른
방향이라 **비대칭 자체가 갭의 증거**다.

⚠️ **PVC `requests.storage`는 축소 불가**(확장 전용)다. 그래서 "볼륨을 올려 맞추기"는 되돌릴 수 없는
방향이고, 이미 실사용의 49배인 선언을 더 부풀리는 순환 논리다. **상한 쪽을 내리는 것이 정답**이다.

⚠️ **존재 grep으로 만들면 안 된다.** `tests/gates/test_vmalert-config.bats`가 이미
`grep -q maxDiskUsagePerURL` 형태였는데 450MiB를 900MiB로 바꿔도 초록이고 victorialogs 위반도 못 잡았다.
규범은 이 문서에 **문장으로는 이미 있었다** — 빠진 것은 규범이 아니라 **강제**다.

> 가드: `tools/check-disk-caps.ts`, `tests/gates/test_disk-caps.bats`

### 고아 PVC는 Bound다 — `phase == Released`만 보는 감사는 원리적으로 못 잡는다

`kubectl delete sts --cascade=orphan`은 **PVC를 지우지 않는다**. 그래서 그렇게 생긴 고아는 PVC가 살아
있고 PV는 계속 `Bound`다. 그런데 `scripts/audit-orphan-pv.sh`는 `.status.phase == "Released"`만 봤다 —
그 술어의 전제는 "PVC를 지우면 PV가 Released로 남는다"이고, 이 발생 경로에는 해당되지 않는다.

라이브 실측(2026-07-29): 고아 2건(`storage-vmsingle-0` 20Gi 선언/1.0GiB 사용 · `vlogs-victorialogs-0`
10Gi 선언/118MiB 사용)이 **21일간** 남아 있는 상태에서 이 감사가 **"고아 없음(Released 0건)" + rc=0**을
냈다. 게이트가 없는 것보다 나쁘다 — **감사했다는 착각**을 만든다.

⚠️ ArgoCD도 이 클래스를 **구조적으로 prune 못 한다**: STS 컨트롤러가 `volumeClaimTemplates`로 만든
객체라 tracking 어노테이션이 없고, 앱은 Synced/Healthy 초록이다. GitOps 감시망 밖이다.

✅ 판정은 **phase가 아니라 소비 여부**로 한다 — "어떤 파드도 마운트하지 않는 PVC". 그리고 소비 집합은
**파드 기준**이어야 한다(STS/Deployment 스펙만 보면 스케일 0이나 삭제된 컨트롤러의 PVC를 '사용 중'으로
오판한다). 열거 바닥값도 함께 둔다 — PVC가 0건으로 읽히면 "고아 없음"과 구별할 수 없다.

⚠️ reclaim은 **PVC → PV → hostPath 디렉토리 3단계 전부** 완주해야 한다(두 storageClass 모두 Retain).
중간에 멈추면 PV 없는 디스크 잔재가 남고, 그건 어느 k8s 질의로도 안 보인다.

> 가드: `scripts/audit-orphan-pv.sh`


### sshd_config.d는 먼저 읽힌 값이 이긴다 — systemd 드롭인과 정반대다

systemd 드롭인(`*.conf.d/`)은 **마지막** 선언이 이긴다. `sshd_config.d`는 **반대**다 —
`man sshd_config`: *"for each keyword, the first obtained value will be used"* 이고
`Include /etc/ssh/sshd_config.d/*.conf`는 본 파일 **앞에** 놓인다. 즉 글롭 사전순으로 먼저 읽힌
파일이 이긴다. 하드닝 드롭인을 `60-`으로 지으면 `50-cloud-init.conf`에 **조용히 진다**.

⚠️ NUC 실측(2026-08-11): `/etc/ssh/sshd_config.d/`는 `755`라 열람되지만 그 안의
`50-cloud-init.conf`는 **`600 root:root`**다. 그래서 sudo 없이는 **실효 설정을 얻는 모든 경로가
EACCES로 죽는다** — `sshd -T`, `sshd -G`, 심지어 단순 `cat`까지. 디렉토리가 열린다고 내용을
비교할 수 있다고 착각하기 쉽다.

✅ 그러므로 sudo-free 드리프트 검사는 **이름만으로** 불변식을 건다: "우리 드롭인보다 사전순 앞선
`.conf`가 없다". 내용 열람이 필요 없다는 것이 이 설계의 요점이다.

> 가드: `infra/k3s-bootstrap/tests/test_03-host-config.bats`

### Ubuntu 26.04에 /etc/timezone이 없다 — 그 파일을 읽는 게이트는 출구가 없다

Debian 고유 파일인 `/etc/timezone`은 Ubuntu 26.04에 **존재하지 않는다**. 어떤 패키지도 소유하지
않는다(실측: `dpkg-query -S /etc/timezone` → `no path found`, `tzdata 2026c` 설치돼 있음에도).
타임존의 진실원은 `/etc/localtime` 심링크와 `timedatectl`뿐이다.

⚠️ 그 파일을 읽는 검사는 **정상 설정된 호스트에서도** "타임존을 읽지 못했다"로 죽는다. 그리고 그
진단이 제안하는 `timedatectl set-timezone`은 systemd-timedated가 `/etc/localtime`만 갱신하므로
**그 실패를 고치지 못한다** — fail-loud이지만 출구가 없는 게이트다. `host-preflight.sh`가 정확히 그
상태였고, `[1]`이 먼저 죽어서 `[2]`·`[3]`의 진짜 위험(콜드스타트 교착 경로가 열려 있음)이
**보고되지도 않았다**.

⚠️ 반대로 그 파일을 host-config 관리 대상으로 **만들면** 두 진실원이 갈린다 —
`timedatectl set-timezone`은 그 파일을 갱신하지 않으므로 드리프트 검사가 stale한 값을 보고 "일치"라
답한다.

> 가드: `infra/k3s-bootstrap/tests/test_02-host-preflight.bats`

### tailscale의 ~. 라우팅 도메인 — 노드 이름해석이 조용히 클러스터 의존이 된다

`DNSStubListener=no`로 스텁을 끄고 `/etc/resolv.conf`를 실업스트림 목록으로 돌려도, tailscale이
`~.`(모든 도메인) 라우팅 도메인을 선언하면 **1순위 nameserver가 `100.100.100.100`(MagicDNS)** 이
된다. 그 뒤의 실제 리졸버는 tailnet coordination server가 정하고, 이 tailnet에서 그 값은
`infra/tailscale/acl.tf`의 `tailscale_dns_nameservers` = **NUC**, 즉 라이브 클러스터의 AdGuard다
(2026-08-18 컷오버 전에는 맥미니였다).

즉 노드의 이름해석이 **클러스터를 경유한다** — AdGuard/클러스터가 내려간 순간 노드가 `github.com`조차
못 풀고, 이미지 pull이 불가능해진다. 콜드스타트 교착의 두 번째 얼굴이며, `DNSStubListener=no` 하나로는
닫히지 않는다.

⚠️ `100.100.100.100`은 **LOCAL 주소가 아니다**(실측: `ip route get` → `dev tailscale0 table 52`,
local 테이블에는 노드 자신의 `/32`만). 그래서 CNI hostPort DNAT(`--dst-type LOCAL`)는 **피한다** —
그 교착과는 다른 경로다. "routable하니까 안전하다"는 판정이 정확히 여기서 틀린다.

✅ 처방은 `tailscale set --accept-dns=false`(디바이스 로컬, tailnet 전역 설정 무변경). 검사는
resolv.conf의 nameserver가 tailnet 대역(CGNAT `100.64.0.0/10` · tailscale ULA
`fd7a:115c:a1e0::/48`)에 있으면 거부한다. tailscaled 자신의 동작에는 영향이 없다(자기 내부
리졸버를 쓴다).

⚠️ 남은 절반: tailnet 전역 nameserver는 컷오버에서 NUC으로 **함께 바꿨다**. 되돌리면(예:
`terraform.tfvars.pre-cutover.bak` 복원) **tailscale을 켠 모든 기기**의 이름해석이 죽는다 — 그 값은
gitignored `terraform.tfvars`에 있어 diff에 보이지 않고, `terraform apply`는 성공한다. `.bak` 복원 금지.

> 가드: `infra/k3s-bootstrap/tests/test_02-host-preflight.bats`

### findmnt -T는 마운트 여부를 증명하지 못한다 — 그리고 bind 마운트의 SOURCE엔 대괄호가 붙는다

"이 경로가 별도 스토리지 위에 있는가"를 `findmnt -T <path>`로 판정하면 **정확히 반대의 답**을 얻는다.
`-T`는 경로를 **감싸는** 마운트로 resolve하므로, `/mnt/bulk`가 마운트가 아니라 루트 위 평범한
디렉토리여도 `/`를 성공적으로 돌려준다 — 잡으려던 바로 그 상태가 통과한다. 마운트포인트 판정은
인자 없는 `findmnt <path>`(그것이 마운트포인트일 때만 매치)로 해야 한다.

⚠️ OrbStack 시절에는 **`-T`가 필수**였다(mac 공유의 하위 디렉토리는 자체 마운트포인트가 아니라
`findmnt <subdir>`가 빈 출력 + rc=1). 즉 이식에서 요구사항이 **뒤집혔다** — 옛 주석("-T를 반드시
쓸 것")을 그대로 옮기면 게이트가 조용히 무력화된다.

⚠️ 두 번째 함정: bind 마운트의 `SOURCE`는 `/dev/mapper/vg-root[/var/lib/rancher/...]`처럼 **서브패스가
대괄호로 붙는다.** 디바이스 동일성을 비교할 때 대괄호를 떼지 않으면 문자열이 달라져 "다른 디바이스"로
읽힌다 — 루트 LV의 bind 마운트를 별도 디스크로 오판하는 것이고, 그게 국면 A의 정확한 모양이다.

> 가드: `infra/k3s-bootstrap/tests/test_08-bulk-gate.bats`

### 한시 억제는 자기 만료를 품어야 한다 — 그리고 억제한 알림을 vacuity 대조군으로 쓰던 e2e가 함께 죽는다

**영구 발화하는 critical은 무음보다 나쁘다.** `FilesBackupStale`은 NUC 이식 직후 producer(레포 밖
launchd 배선 + macOS 전용 `backup-files-data.sh` — NUC엔 launchd도 diskutil도 없어 하드 실패)가
**실효적으로 존재하지 않아** absent 가지가 24/7 참이었다.
`severity=critical` 라우트의 `repeat_interval: 1h`를 타고 하루 24건이 나간다. 상시 소음은 채널 전체를
둔감화해 **진짜 페이지를 묻는다** — "알림이 있다"가 "감시가 있다"를 뜻하지 않게 된다.
(2026-08-19에 스크립트가 리눅스로 재작성되고 `files-data-backup.{service,timer}`로 **배선까지 끝났다**.
국면 A 동안은 타이머를 의도적으로 enable하지 않았으므로 시리즈가 absent였고 억제가 유효했다.
국면 B 진입에서 `systemctl enable --now` 한 줄과 **억제 절 제거가 함께 갔다** — `tests/gates/test_files-backup-phase-a.bats`가
그 동반을 양방향으로 강제한다. 현행 국면의 권위는 `infra/k3s-bootstrap/versions.env`다.)

**억제의 만료는 룰 자신이 들고 있어야 한다.** 사람이 기억해야 하는 억제는 영구 침묵이 된다.
expr에 `and on() (vector(time()) >= <재무장 unixtime>)`을 달면 만료가 자동이고 상한이 명시된다.

⚠️ **결합 순서를 거꾸로 알기 쉽다.** PromQL은 `and`가 `or`보다 **강하게** 결합하므로
`A or B and on() C`는 `A or (B and on() C)`로 파싱된다 — 즉 절을 expr **끝에 괄호 없이** 붙이면
정확히 뒤쪽(absent) 가지에만 걸린다. 위험한 것은 그 반대 형태 `(A or B) and on() C`(전체를 괄호로
묶는 것)로, 그러면 staleness 가지까지 함께 죽어 **producer가 되살아나도 감시가 안 돌아온다.**
**두 형태 모두 문법상 유효해 `-dryRun`이 구별하지 못한다** — 그래서 형태를 잠그는 가드가 필요하다.
실측(VictoriaMetrics v1.145.0): 끝에 붙인 형태에서 push 없음 → 무발화 / push 있음 + stale → **발화** /
push 있음 + fresh → 무발화 / 억제 없는 원본 + push 없음 → 발화.

**시각 상수는 SSOT의 파생값이다.** 창의 SSOT는 `versions.env`의 `BULK_MIGRATION_WINDOW_UNTIL`이고
룰은 YAML이라 런타임 파생이 불가능하다 → 하드코딩을 허용하되 **양방향 정합 가드**로 잠근다.
특히 "창을 비웠는데 억제 절이 남음"을 잡는 방향이 더 중요하다 — 그게 국면 전환에서 알림이 죽은 채
넘어가는 경로다. ⚠️ 그 가드는 **`yq`로 expr만 파싱해서** 봐야 한다. 같은 파일의 주석이 같은 리터럴을
담으므로 파일 전체 grep은 주석의 상수를 검증하고 배포되는 expr은 안 보는 거짓 초록을 만든다.

**★ 동반 파괴 — 억제된 알림을 vacuity 대조군으로 쓰던 하네스가 시끄럽게 죽는다.**
음성 레그("발화 없음"이 판정)는 vmalert가 애초에 아무것도 안 썼을 때도 통과하므로, 이 레포의 e2e들은
"확실히 발화하는 같은 그룹의 absent 가드 알림"을 대조군으로 세워 vacuity를 배제한다. 그 대조군에
시각 게이트를 걸면 replay(=현재 시각)에서 발화가 불가능해져 하네스가 HARNESS FAULT(exit 2)로 죽는다.
⇒ **대조군은 시각 게이트가 없는 알림이어야 한다**는 계약이 생겼다. 억제를 도입하는 커밋은 대조군
이동을 **같은 커밋에** 포함해야 한다(안 하면 required gate 2개가 동시에 RED).

> 가드: `tests/gates/test_files-backup-phase-a.bats`

### 드릴의 정리가 EXIT trap뿐이면 고아가 남고, pre-flight 없는 apply가 그 고아를 재사용해 '검증된 복원'이 거짓말한다

> 가드: `platform/cnpg/prod/test_restore_drill_behavior.bats`

**정리를 `trap … EXIT`에만 맡긴 배치 잡은 비정상 종료에서 정리하지 않는다.** 노드 재부팅·OOM·
evict·`activeDeadlineSeconds` 초과는 SIGTERM→SIGKILL이라 EXIT trap이 돌지 않는다. 남는 것은 고아
`Cluster`다.

**그 다음 실행의 `kubectl apply`는 복구를 다시 돌리지 않는다.** 힙독 텍스트가 매 실행 바이트
동일이면 클라이언트-사이드 3-way merge patch가 비어 진짜 no-op이 되고, 설령 patch가 나가도
CNPG는 `bootstrap`을 **초기화 시점에만** 읽고 이후 무시한다(`platform/cnpg/prod/cluster.yaml`의 bootstrap 주석).
그러면 phase 루프가 첫 시도에서 통과하고, 검증 대상 테이블의 행 수는 지난 회차 값 그대로라 비교도
통과한다 → **오브젝트 스토리지를 한 번도 만지지 않은 드릴이 '검증된 복원'을 보고한다.**

⚠️ **거짓 PASS의 서명을 정확히 알아야 한다 — 여기서 한 번 틀렸다.** 성공 경로의 정리가 그 고아를
**자기가 지우기 때문에** 거짓 PASS는 매주 반복되지 않는다. 실제 서명은 성공 간격이 7일 → 14일로
벌어지는 것이고, staleness 임계(8.1일)가 그 사이 약 5.9일간 발화한다 = **플랩**이지 영구 초록이
아니다. 영구 초록이 되는 경로는 둘로 좁다: (1) 고아가 **수동 out-of-band 실행**에서 생기면 자동
회차의 거짓 PASS가 주간 리듬을 깨지 않아 staleness가 한 번도 안 뜬다(조용한 단발 거짓 PASS),
(2) 잔여물 스윕이 눈이 멀어 PGDATA가 매주 살아남으면 매 회차가 그것을 재사용한다.
⇒ 처방을 "정리하고 **중단**"으로 잡으면 이미 울고 있는 알림에 정보를 더하지 못하면서 한 주기치
복원 증명을 버린다. **정리하고 계속**이 옳다 — 청소된 상태에서 그 회차가 진짜 복구를 수행해
알림을 정당하게 해소한다. 중단은 **정리 자체가 실패했을 때만** 건다(그때는 apply가 실제로 no-op이다).

⚠️ **Cluster CR만 지우면 반쪽이다.** CNPG는 Cluster 삭제 시 PVC를 남기므로 `<cluster>-<serial>`
PGDATA가 살아 있으면 새 Cluster가 그것을 재사용해 `bootstrap.recovery`가 생략될 수 있다 — 같은
거짓 PASS가 다른 문으로 재현된다. pre-flight는 Cluster + PVC를 함께 지우고 **0을 확인**해야 한다.

⚠️ **삭제의 rc는 정리를 증명하지 못한다.** `--ignore-not-found`는 없는 것도 성공이고, finalizer
때문에 반환 시점에 오브젝트가 살아 있을 수 있다. 그리고 `kubectl delete --wait=true`는 대상이 즉시
사라지지 않으면 소멸을 **watch로 추적**하므로 해당 리소스에 `watch` 동사가 없으면 실패한다 — 그
실패를 `|| true`로 덮으면 "정리했다"가 관측되지 않은 채 참으로 통과한다(실측: restore-drill SA는
clusters에 `watch`가 **없고**, CNPG Cluster CR에 finalizer가 없어 아직 안 터진 **잠재** 결함이었다).
판정은 `get` 폴링이 해야 하고, **삭제는 폴링마다 재발사**해야 한다(오퍼레이터가 삭제를 관측하기
전이면 자식 오브젝트가 재생성돼 1회 발사로는 수렴하지 않는다).

⚠️ **잔여물 열거의 실패를 0건으로 읽지 마라, 그리고 셀렉터를 믿지 마라.**
`n=$(kubectl get … 2>/dev/null | wc -l)` 형태는 API 접근이 죽어도 0을 내어 '잔여 없음'으로 읽힌다.
더 나쁜 것은 라벨 셀렉터다 — 빗나가도 rc 0 + 0줄이라 '잔여 없음'과 **원리적으로 구별되지 않는다**.
'0건=정상'인 검사는 그 자체로 셀렉터를 한 번도 양성 관측하지 않는다. 이름 접두로 열거하고,
**방금 만든 것이 열거에 잡히는지**를 정리 직전에 양성 대조하라.

⚠️ **'복구가 일어났다'는 양성 증인이 없으면 어떤 처방도 단층 방어다.** 상태 필드(`.status.phase`)는
생존자에게 즉시 참이었고, 시드되지 않는 canary의 행 수 비교도 항상 참이었다(2026-08-17 실측:
`restore_canary`는 1행 고정이고 레포에 INSERT 주체가 없었다) — 두 관측점 모두 진짜 복구와 생존자
재사용을 구별하지 못했다. ✅ 2026-08-18에 드릴이 **복구 전 마커를 쓰고 그 마커를 복구본에서 확인**하도록
바뀌어 행 수 축도 살아났지만, 그 마커 판정은 **아카이브 신선도**를 보는 것이지 생존자 판별이 아니다 —
첫-폴링 증인은 여전히 필요하다. 공짜 증인이 있다: 진짜 복구는 첫 폴링에 healthy가 될 수 없으므로(실측 로그는
`phase=<none>` → `Setting up primary` → … 순), **healthy 아닌 상태를 한 번도 못 봤다면 그것이 곧
생존자의 증거**다.

⚠️ **동시 실행이 pre-flight를 우회한다.** `concurrencyPolicy: Forbid`는 CronJob이 만든 Job에만
걸리고 `kubectl create job --from=cronjob/…`은 그 밖이다. 두 실행이 서로의 pre-flight를 통과한 뒤
apply하면 나중 apply가 no-op이 된다. **정기 실행 시각 근처에 수동 드릴을 돌리지 마라** — 런북은
gitignored라 그 규칙을 게이트가 못 보므로 여기(추적되는 SSOT)에 적는다. 위의 첫-폴링 증인이 이
경로의 최종 방어다.

⚠️ **grep 단언은 이 함정을 못 잡는다.** `delete` 문자열이 파일 어딘가에 있다는 것은 그것이
`apply` **앞에서** 실행된다는 것을 증명하지 않는다. 순서는 스텁 바이너리를 PATH 선두에 얹고
스크립트를 통짜 실행해 호출 로그의 줄 번호로 비교해야 하고, 폴링/갈래는 **호출 횟수와 실패 문구**로
물어야 한다(상태 코드만 보는 단언은 폴링을 통째로 지워도 초록이다 — 뮤테이션으로 실증할 것).

### `kubectl apply --dry-run=server`는 ArgoCD가 SSA로 관리하는 오브젝트에 대해 거짓 실패를 낸다

사람이 손으로 도는 dry-run은 **자기 field manager**(`kubectl`)로 apply한다. Server-Side Apply에서
필드 제거는 **그 필드를 소유한 매니저가** 그것을 더 이상 선언하지 않을 때만 일어나므로, 매니저가
다른 손 dry-run은 **제거를 재현하지 못하고 병합만 한다.** 그러면 "지우려던 필드"와 "새로 넣는 필드"가
동시에 존재하는 중간 상태가 만들어지고, CRD 웹훅이 그것을 거절한다.

실측 (2026-08-17, 컷오버에서 `Cluster/pg`의 `bootstrap.recovery` → `bootstrap.initdb` 전환):

```
# ① 사람의 client-side apply → 거짓 실패
kubectl apply --dry-run=server -f cluster.yaml
  The Cluster "pg" is invalid: spec.bootstrap: Forbidden: Only one bootstrap method can be specified at a time

# ② 사람의 SSA(기본 field manager) → 같은 거짓 실패 (이유는 다르다: 소유권이 없어 병합된다)
kubectl apply --server-side --dry-run=server -f cluster.yaml
  ... Only one bootstrap method can be specified at a time

# ③ ArgoCD의 field manager를 흉내 내면 → 통과
kubectl apply --server-side --field-manager=argocd-controller --force-conflicts \
  --dry-run=server -f cluster.yaml
  cluster.postgresql.cnpg.io/pg serverside-applied (server dry run)
```

⚠️ **거짓 실패를 믿고 매니페스트를 "고치면" 진짜 사고가 된다** — 이 경우 두 bootstrap 방법을
모두 남기거나 전환 자체를 포기하게 되는데, 둘 다 ArgoCD의 실제 apply에서는 필요 없던 일이다.

**올바른 검증 절차**: 라이브 오브젝트의 소유자를 먼저 확인하고 그 이름으로 dry-run한다.

```
kubectl -n <ns> get <kind> <name> -o jsonpath='{range .metadata.managedFields[*]}{.manager} {.operation}{"\n"}{end}'
```

⚠️ `--force-conflicts`는 **dry-run에서만** 안전하다. 실제 실행은 ArgoCD에 맡기고 사람이 apply하지 마라
— 손으로 apply하면 그 필드의 소유권이 `kubectl`로 넘어가 이후 ArgoCD sync가 conflict를 내거나
selfHeal과 플립플롭한다.

⚠️ 이 레포는 자기레포 Application 대부분이 `ServerSideApply=true`다(`platform/argocd/root/apps/*.yaml` ·
`appset.yaml` · `root-app.yaml` · `argocd-app.yaml`). 즉 이 함정은 예외가 아니라 **기본 경로**다.

### 권한 부족은 에러가 아니라 드리프트로 위장한다 — terraform은 못 읽은 리소스를 "삭제됨"으로 읽는다
- **읽기 권한이 없으면 terraform은 실패하지 않고 `# <resource> has been deleted` + `Plan: 1 to add`를
  낸다.** 라이브 실측(2026-08-19, tailscale 루트): CI용 읽기 전용 OAuth 클라이언트에서
  `oauth_keys:read`만 빼자 `tailscale_oauth_client.k8s_operator`가 **삭제된 것으로 판정**됐다.
  형제 스코프는 정직하게 죽는다 — `policy_file:read` 누락 → `Error: Failed to fetch ACL`,
  `dns:read` 누락 → `Error: Error fetching DNS name servers`. 즉 **같은 종류의 권한 부족이 리소스에
  따라 loud failure와 silent false-drift로 갈린다.**
- **왜 실패보다 나쁜가**: plan-only 드리프트 감시를 그 상태로 켜면 30분마다 "드리프트 발생" 알림이 오고,
  그걸 믿고 owner가 apply하면 **없어지지도 않은 리소스를 새로 만든다**(OAuth 클라이언트 중복 생성).
  경보가 그 자체로 사고의 원인이 되는 구조다.
- **일반형**: `refresh`가 리소스를 읽지 못하는 모든 이유(권한·네트워크·API 변경)가 이 모양을 띨 수 있다.
  자격을 좁힐 때 "plan이 통과했다"는 **불충분한 수용 기준**이다 — `No changes`까지 봐야 한다.
  `Plan: N to add`가 나오면 자격을 의심하라(선언이 틀렸다고 먼저 결론짓지 말 것).
- 처방: CI 자격을 최소화할 때 **스코프를 하나씩 빼 보고 각각의 증상을 기록**한다. 확정된 집합은
  코드 주석 + 원장 양쪽에 박고, 주입 자리를 정적 가드로 잠근다(주입이 사라져도 같은 403이 난다).
> 가드: `infra/tailscale/test_provider_scopes.bats`

### owner 로컬 apply 루트는 CI가 plan만 해도 terraform 코어 버전이 state writer 이상이어야 한다
- **terraform은 state를 쓴 버전보다 낮은 바이너리로 그 state를 읽지도 못한다**
  (`state snapshot was created by Terraform vX, which is newer than current vY`). apply가 아니라
  **plan-only여도 마찬가지다** — refresh가 state를 읽어야 하기 때문이다.
- **왜 이 레포에서 물리는가**: 루트마다 state writer가 다르다.
  - **github·tailscale은 owner 로컬 apply 전용**이라 writer가 owner 머신의 terraform이 된다.
    owner가 brew/mise로 terraform을 올리고 한 번 apply하면, 그 순간부터 CI의 plan-only 감시가
    죽는다 — 그 job이 `required/error`면 **매 30분 red**다.
  - ⚠️ **cloudflare는 "CI 전용"이 아니다.** CI가 apply하지만(iac.yaml plan/apply · tf-reconcile
    apply) blocked-delete 복구 경로는 **owner 로컬 apply**다 — 즉 writer 집합이 CI ∪ owner이고,
    "CI가 apply하므로 writer가 CI 핀에 고정"은 절반만 참이었다. 이 루트의 CI 핀과 owner 바이너리는
    한 값이어야 하는 **등식**이다.
- ⚠️ **핀 통일이 오히려 고장이다.** 워크플로의 `terraform_version` 핀들을 "일관성" 명목으로 맞추면
  로컬-apply 루트가 깨진다. 핀은 루트마다 독립이며, 그 의도를 주석에 박아 두지 않으면 다음 사람이
  통일한다(실제로 그 방향의 리팩터가 자연스러워 보인다).
- ✅ **등식은 이제 terraform 자신이 진다**(가드 신설 0): `infra/cloudflare/versions.tf`와
  `infra/github/versions.tf`의 `required_version = "= 1.9.8"`이 CI 핀·owner 바이너리 어느 한 변만
  올라가도 `init`/`validate` 단계에서 fail-closed로 죽인다 — state를 쓰기 **전에**, 그리고
  `init -backend=false`인 PR gate에서도 걸린다. `infra/tailscale/versions.tf`만 `>= 1.9.0`이다
  (그 루트의 drift 잡은 일부러 1.15.5 헤드룸으로 돈다).
- ⚠️ **Renovate가 이 값을 안 본다** — `renovate.json`에 `terraform_version` customManager가 없고
  github-actions manager도 비활성이다. 즉 자동 갱신 경로가 0이고, 로컬 apply 후 손으로 올려야 한다.
> 가드: `infra/tailscale/test_provider_scopes.bats`

### GitHub API는 낡은 스냅샷을 200으로 돌려준다 — `last_over_time`은 그 역행 샘플 하나를 그대로 페이지로 바꾼다
- **같은 URL을 몇 초 간격으로 두 번 부르면 다른 세계가 온다.** 2026-08-19 실측:
  `GET /repos/ukyi-app/homelab/actions/workflows/bump-poll.yaml/runs?status=success&per_page=1`이 첫 호출에
  `total_count=319` + 최신 run이 **2026-07-29**(21.5일 낡음)를 돌려줬고, 몇 초 뒤 같은 URL이
  `total_count=1137` + 신선한 run을 돌려줬다. 에러가 아니라 **200이다** — GitHub 백엔드의 read-replica/인덱스
  불일치이고 클라이언트가 할 수 있는 것이 없다(exporter의 추출 정규식은 정상이었다).
- **왜 그것이 곧 페이지가 되나**: `gha-liveness-exporter`는 **상태가 없다**(CronJob `*/30` · 자기 과거를 읽지
  않는다) → 낡은 응답을 그대로 `gha_workflow_last_success_timestamp`에 싣는데, **값**은 API가 준 EPOCH이고
  **샘플 타임스탬프**는 push 시각이라 역행 값이 "가장 최근 샘플" 자리에 앉는다. 좌변이 `last_over_time(…[3h])`
  이면 그 한 샘플이 판정의 전부다.
- **형제 알림 둘은 원리적으로 못 본다**: 낡은 스냅샷도 200 + 파싱 성공이라 `SCRAPED`가 정상 증가한다 →
  `GHALivenessScrapeIncomplete`(부분 고장 축)는 침묵하고, push 경로는 멀쩡하니 하트비트
  (`GHALivenessExporterStale`)도 침묵한다. 셋 중 **정확히 이 알림만** 반응한다.
- **라이브 시계열**(vmsingle raw export, 7일 · 워크플로당 263샘플 — running max 대비 **역행**한 샘플):
  `bump-poll.yaml` 4회(−1.9h · −92.9h · −2.4h · −515.3h) · `tf-reconcile.yaml` 1회(−18.0h) ·
  나머지 6종 **0회**. 최장 연속은 **2폴(1시간)**이고 그 직후 샘플은 매번 신선한 값으로 복귀했다 = **단발 잡음**.
  역행은 run 수가 많은 워크플로에 몰렸다(bump-poll 1145 · tf-reconcile 996 · pr-sweeper 957).
  ⚠️ pr-sweeper가 그 창에서 0회였던 것은 **표본이 작아 그렇게 보이는 것**이지 구조적 면역이 아니다
  (공통 비율 가정 시 0회일 확률 ≈ 3%). 대상을 "역행을 본 워크플로"로 좁히지 마라.
- **반사실 대조**(같은 라이브 데이터에 두 expr을 나란히 평가): `last_over_time`은 24시간 창에서 22격자
  (bump-poll 17 · tf-reconcile 5)가 참이었고, `max_over_time`은 **0격자**였다. 반대 방향도 쟀다 — 예산을
  인위로 21600s까지 낮추면 두 함수가 **진짜로 정지한 5종을 격자 수까지 동일하게**(218/218 · 289/289 · 19/19)
  잡았다. ⇒ **오탐만 사라지고 감지 능력은 그대로다.**
- ⇒ **처방: 좌변만 `last_over_time` → `max_over_time`.** 이 값은 "마지막 성공 run의 시각"이라 **단조
  비감소여야 하는 양**이고 역행은 사실이 아니라 관측 잡음이다. 정상 데이터에서 두 함수는 **같은 값을 낸다** —
  차이는 잡음이 들어왔을 때뿐이라 교체 비용이 0이다.
- ⚠️ **우변(`gha_workflow_max_age_seconds`)에는 쓰지 마라.** 그것은 예산(설정)이라 **내려가는 것이 사실**이다 —
  max를 씌우면 예산을 낮춘 뒤 옛 큰 값이 윈도만큼 부활해 새 예산이 늦게 먹는다. 판정 기준은 "타임스탬프인가"가
  아니라 **"그 값이 내려가는 것이 사실일 수 있는가"**다.
- **★ 세 번째 축**: 「rollup 윈도 상한 — 상태 게이지 vs 하트비트 비대칭」이 값의 종류로 **윈도 크기**를 갈랐다면,
  여기선 같은 축이 **rollup 함수 선택**을 가른다. 판별에는 **두 질문이 필요하다**:
  - **① 값의 신선도가 클러스터 밖 읽기에 의존하는가**(그 읽기가 낡은 뷰를 줄 수 있는가) —
    **`external` + 단조량 → `max_over_time`**. 공급원 잡음이 실재하고 max가 그것을 유계 흡수한다.
  - **② 그 외 전부 → `last_over_time`**(뒤집힌 `X - time()` 만료 모양이면 `min_over_time`).
    ⚠️ **in-cluster 단조량에 `max_over_time`을 쓰지 마라** — 흡수할 잡음이 없어 이득이 0인데, 대신 값의
    **전진** 점프를 윈도만큼 래치해 알림을 억제한다(r4의 윈도는 `[2h]`~`[10d]`라 억제 상한이 최대 10일이다).
    **인하가 사실인 값**(예산·게이지·purge로 작아지는 백업 시각)도 마찬가지로 `last_over_time`이다.
  - **라벨-값 상태 게이지 → `last_over_time` + 윈도 < `for:`**(위 형제 섹션 소관).
  ⚠️ **화이트리스트로 강제한다** — "max만 금지"로 두면 `avg_over_time`·`sum_over_time`이 통과하는데,
  `sum_over_time(타임스탬프[W])`는 `time() - 거대값`이 영구 음수라 **조용한 무발화**다.
  ⇒ 이 판별은 `policy/alert-supply-monotonicity.json`(메트릭별 `supply`/`decreasing` 선언 + 근거 필수)과
  `tools/check-alert-rules.ts`의 **모드 D**가 레포 전역에서 강제한다. 미등재 = FAIL(기본값 없음). 예외 하나(linter-mode-d 01):
  샘플-시각 rollup `tlast_over_time`은 값이 아니라 시각을 내므로 등재·요구 대조 면제다(tfirst/tmin은
  무조건 red·tmax는 argmax 시각이라 예외 밖 — 정책 _readme가 SSOT).
- ⚠️ **`max_over_time`은 면역이 아니라 유계 흡수다.** 창 안에 역행하지 **않은** 샘플이 최소 1개 남아야 흡수하므로
  내성은 `floor(W / push)`폴이고, 침묵 조건은 `n×push ≤ W` **그리고** `(n+1)×push ≤ 예산`이다. W=3h·push=30m에서는
  **앞 항이 먼저 물어 연속 6폴(3.0h)**이 상한이다(hermetic replay 실측: n=6 무발화 / n=7 pending / n=8 발화 —
  예산 항이 주는 n≤11은 **도달조차 하지 않는다**). 라이브 최장 2폴 대비 3배 여유다.
  ⇒ **윈도를 좁히거나 크론을 늘리면 그 여유가 곧바로 줄어든다** — 셋(윈도·크론·예산)은 함께 판단하라.
- ⚠️ **거울상 잔여 위험**: max는 **뒤로** 튄 잡음만 거른다. 앞으로 튄 값(미래 타임스탬프)은 윈도 동안 붙잡혀
  알림을 **억제**한다(fail-open 거울상). 낡은 replica는 원리적으로 **과거만** 낸다는 관측에 기댄 선택이고
  억제 상한이 W로 유계라 수용했다 — 값의 출처(필드·API)가 바뀌면 이 전제를 다시 판단하라.
- **왜 생산자에서 안 고치나**: exporter에 단조 클램프를 넣으려면 자기 과거를 vmsingle에서 **읽어와야** 하고
  (현재는 순수 push · 상태 0), 그 읽기의 실패 모드에 "그럼 무엇을 push하나"라는 새 결정이 붙는다. 소비자 쪽
  한 단어가 같은 불변식을 더 싸게 산다. `per_page`를 올려 응답 안에서 최대값을 고르는 변종도 듣지 않는다 —
  낡은 것은 **인덱스 스냅샷 전체**라 같은 응답 안의 최대값도 같은 세대다(`total_count`가 함께 낡는다).
- **왜 게이트를 통과했나**: `-dryRun`은 파싱만 본다. 발화 e2e의 합성 시계열은 **모든 샘플이 같은 age**라 역행
  샘플이 존재하지 않았고, 정적 bats는 메트릭명+윈도만 grep해 **함수 이름을 보지 않았으며**, 모드 C 린터의
  `ROLLUP_OK`에는 `last_over_time`과 `max_over_time`이 **둘 다** 들어 있다. ⇒ 좌변을 되돌려도 전 게이트가
  초록이었다(실측). 함수 선택 축에 가드가 **0건**이었다.
- **스코프**: 이 레포의 타임스탬프-값 push 메트릭 중 `restore_drill_*`·`files_backup_*`·`pvc_du_*`·
  `adguard_rewrite_*`·`gha_liveness_last_success_timestamp`는 전부 잡 자신이 `date +%s`로 만들어 **구조적으로
  단조**다. **제3자 API에서 값이 오는 것은 `gha_workflow_last_success_timestamp` 하나뿐**이라 이 클래스의
  현재 원소는 1개다. ⚠️ 다만 판별 기준은 "push인가"가 아니라 **"값이 클러스터 밖에서 왔는가"**이므로,
  스크레이프 경로에도 외부 공급원이 있다 — `barman_cloud_…_last_available_backup_timestamp`(R2 조회,
  `R2BackupStale`)가 그렇다. 거기에 `max_over_time`을 쓰면 **안 된다**(`reset-pg-r2-archive.sh --purge`가
  정당한 역행을 만든다). ✅ **레포 전역 강제(2026-08-20 배선)**: `tools/check-alert-rules.ts` **모드 D**가 룰의 `time()` 비교
  피연산자를 열거해 `policy/alert-supply-monotonicity.json`의 선언과 대조한다 — 미등재 = FAIL이고,
  요구는 화이트리스트다. 도입 시 원장 15건 / 판정 29참조.
> 가드: `tests/gates/vmalert-gha-liveness-firing-e2e.sh`, `tests/gates/test_gha-liveness-exporter.bats`, `tests/gates/fixtures/r6-gha-lastovertime.yaml`, `tools/check-alert-rules.ts`, `policy/alert-supply-monotonicity.json`, `tests/test_alert_rules.bats`

### 로케일 콜레이션이 게이트를 뒤집는다 — en_US의 `sort -u`는 `-1`과 `1`을 같다고 보고 하나를 버린다
- glibc의 `en_US.UTF-8`(그리고 대부분의 UTF-8 언어 로케일)은 **구두점·공백을 1차 가중에서 무시**한다.
  그래서 `sort`는 `-1`과 `1`, `_create-app.yaml`과 `create-app.yaml`을 **같다고 본다** — `sort -u`가
  그중 하나를 **조용히 버린다**. `C`/`C.UTF-8`은 바이트 순서라 전부 남는다.

  | 입력 | `LC_ALL=en_US.UTF-8 sort -u` | `LC_ALL=C sort -u` |
  |---|---|---|
  | `-1 1 -2 2 -9 9` | `-1 -2 -9` (3줄) | 6줄 전부 |
  | `git ls-files .github/workflows` | 19 | 24 |

- **이건 거짓 red가 아니라 fail-open이다.** `platform/argocd/root/test_sync_wave_ledger.bats`가 원장의
  `-1` 행 삭제(= 실제 드리프트)를 en_US에서 **초록**으로 통과시켰다(C에서만 red). 매니페스트 쪽 `sort -u`가
  `-1`을 삼켜 그 wave가 루프에 **아예 안 들어갔기** 때문이다 — 가드가 존재 이유로 삼는 바로 그 드리프트다.
- **이 레포의 네이밍 규약이 정확히 이 모양이다**: `_*.yaml`(내부 reusable) ↔ `*.yaml`(공개 디스패처).
  워크플로 파일명을 `sort -u`로 훑는 게이트는 공개 디스패처 5개(`create-app`·`create-cache`·
  `create-database`·`teardown-app`·`update-secrets`)를 **보지 못한다**. 오늘 그 도메인을 쓰는 가드가
  없을 뿐, 데이터는 이미 붕괴 모양이다.
- **`sort -u`만 데이터를 잃는다.** `sort | uniq`는 uniq가 바이트 비교라 안전하고 `sort -nu`는 정수에
  안전하다. 중복 제거가 **최적화일 뿐**이면(멱등 루프의 건초더미) **아예 빼는 것**이 가장 안전하다 —
  콜레이션에 물릴 자리 자체를 없앤다. 붕괴 감지는 열거 바닥값이 맡는다.
- **두 번째 얼굴: 정렬 키가 줄 전체면 설명이 키로 샌다.** `make help`는 `  <이름 22폭 패딩> <한국어 설명>`
  줄을 정렬하는데, C에서는 패딩 공백(0x20)이 모든 이름 문자보다 작아 "줄 정렬 == 이름 정렬"이 **우연히**
  성립하지만 en_US에서는 성립하지 않는다(실측: `bootstrap-deadmanswitch`가 `bootstrap`보다 앞,
  `verify`가 맨 끝). 즉 테스트의 red가 아니라 **산출물의 결함**이었다.
- **자기참조 기대값을 쓰지 마라.** 그 테스트의 기대값이 `"$(echo "$names" | sort)"`였다 — 호출 로케일이
  질문과 답을 **함께** 바꾸므로 무엇이 계약인지 말할 수 없다. 기대값은 절대 계약(`LC_ALL=C sort`)이어야 한다.
- **가드 자신도 로케일 의존이면 안 된다**: 정규식 브래킷 범위(`[a-z]`)도 콜레이션 의존이라 en_US에서
  악센트 소문자를 추가로 매치한다. 탐지·비교는 전부 `LC_ALL=C`로 감싼다.
- **교차도구 축**: JS `localeCompare`(ICU — **`LANG`/`LC_ALL`에 반응하지 않는다**) · glibc `en_US` ·
  바이트 순서가 **셋 다 다르다**(`ab a-c` vs `a-c ab`). 한쪽이 쓰고 다른 쪽이 대조하면 갈린다.
  ⇒ 산출물 정렬은 **코드유닛 비교**로 한다(`LC_ALL=C sort`와 동형).
- **규약: 게이트의 모든 `sort`는 `LC_ALL=C` 접두이거나 숫자 정렬(`-n`)이다.** 이 레포에 로케일 콜레이션이
  필요한 정렬은 하나도 없다(도입 시 위반 54곳 → 0).
- ⚠️ **런너 고정은 대체가 아니라 짝이다.** `LC_ALL=C.UTF-8`을 두 venue에 박으면 "로컬 초록이 CI를
  예고한다"가 성립하지만, **개별 결함의 뮤테이션 감도가 죽는다**(실측: `make help`의 `LC_ALL=C`를
  되돌려도 C.UTF-8에서는 초록 — 오직 en_US에서만 red다). 그래서 고정 **전에** 원인을 고치고, 재발은
  정적 스캐너가 막는다. 순서를 뒤집으면 fail-open이 영구히 안 보이게 된다(실측: 고정만 하면 전 스위트 초록).
- ⚠️ 스캐너가 덮지 않는 인접 클래스: **셸 glob 확장 순서**(`for f in *.md`)도 콜레이션 의존이다.
  오늘 레포의 glob 소비처는 전부 집계이거나 뒤에서 재정렬하므로 라이브 결함은 없지만, `for f in *.yaml;
  do …; done | head -1` 류가 들어오면 스캐너가 못 잡는다.
> 가드: `scripts/check-locale-collation.sh`, `tests/gates/test_locale-collation.bats`, `tests/gates/test_make-help.bats`, `platform/argocd/root/test_sync_wave_ledger.bats`

### systemd 유닛 파일은 push 생산자 열거 밖이다 — 유닛에 인라인한 curl은 완전성 가드를 통째로 지나간다
- `check-alert-rules.ts`의 생산자 완전성 가드는 "레포에서 메트릭을 push하는 파일을 **전부** 찾는다"고
  주장한다. 실제 열거는 `tools/lib/repo-walk.ts`의 `producers` 스코프이고 그 include는
  `\.(ya?ml|sh|m?[jt]s|py)$`다 — **`.service`·`.timer`·`Makefile`·`.conf`는 확장자에서 탈락한다.**
- **실측(2026-08-20)**: `files-data-backup.service`에
  `ExecStopPost=/bin/sh -c '… | curl --data-binary @- …/api/v1/import/prometheus'`로 **레지스트리에 없는**
  메트릭을 push하게 하고 린터를 돌렸더니 `check-alert-rules OK (… 모드 A/B/C 위반 0)`으로 통과했다.
  **같은 push를 `scripts/*.sh`에 두면 즉시 FAIL이다** — 차이는 확장자 하나뿐이다.
- **무엇이 무너지는가**: 그 메트릭은 push 주기가 vmalert instant 룩백(300s)보다 길어도 **모드 C 검사를
  못 받는다**. 즉 rollup 없이 참조하는 룰이 배포돼도 아무도 막지 않는다 — **죽은 알림이 초록으로 태어난다.**
  이 레포가 반복해 밟은 「열거 붕괴 → vacuous green」의 새 얼굴이고, 위험한 이유는 열거 대상이 0건이
  아니라 **원래 있어야 할 파일 종류가 도메인 밖**이라는 점이다. 바닥값으로는 못 잡는다 — 바닥값과
  열거 수가 **같은 글롭에서 나오기** 때문이다(`host-config.sh`의 확장자 화이트리스트가 같은 자리에서
  배운 것과 정확히 같은 비대칭).
- ⇒ **처방: push는 생산자 확장자를 가진 파일에만 둔다.** 유닛은 그 파일을 `ExecStart=`로 부르기만 한다.
  호스트 계층에서 메트릭을 내보낼 때 "유닛에 curl 한 줄"이 가장 짧은 길처럼 보이지만, 그 한 줄이
  가드 도메인 밖으로 나가는 문이다.
- ⚠️ **스코프 include를 넓히는 것은 답이 아니다** — 그러면 `.conf`·`.network`·`Dockerfile` 같은 다음
  확장자가 똑같이 조용히 빠진다. 대신 **보형(complement)** 을 단언한다: 추적 파일 중 생산자 확장자에
  매치하지 **않는** 것들(문서·테스트 하네스 제외 — 그 둘은 정당하게 그 문자열을 담는다)에 쓰기 동사가
  0건임을 강제한다. 열거 바닥값과 양성 대조를 함께 건다.
- ⚠️ 이 함정의 사촌: **호스트 계층 신호는 애초에 push가 아니어도 된다.** node-exporter가 이미 `/`를
  마운트하고 있으므로 textfile collector(`.prom` 파일)를 쓰면 신호가 **스크레이프**가 되어 모드 C·
  rollup 윈도·생산자 레지스트리 문제가 전부 사라진다. 게다가 push 경로는 kubectl/port-forward에
  의존해 **자기 트리거와 함께 죽는다**(kubectl 불가가 백업 유닛 실패의 주요 원인이다).
> 가드: `tests/gates/test_unit-failure-notify.bats`

### bats는 stdin을 만지지 않는다 — 스텁이 피연산자 없이 `cat`을 부르면 호출자의 fd 0에서 영구 블록한다
- **bats는 fd 0을 전혀 건드리지 않는다**(1.14.0 libexec 전체에 `0<`/`</dev/null` 0건 — 실측). `run`도
  커맨드 치환이라 stdin을 그대로 상속한다. 그래서 @test 안의 스텁이 피연산자 없이 `cat`을 부르면
  그 `cat`은 **bats를 부른 셸의 stdin**에서 EOF를 기다린다.
- **실측(2026-08-20)**: `tests/test_sealed-secrets-restore.bats`의 `sops` 스텁이
  `printf '#!/bin/sh\ncat\n'`이었다. 피시험 코드(`scripts/sealing-key-dr-gate.sh:121`)는
  `sops -d … "$latest" | sanitize_backup_yaml`로 **파일 인자를 주고 파이프로 먹이지 않는다** —
  그 `sops`는 파이프의 **첫** 명령이라 먹일 stdin이 없다. never-EOF stdin을 물리면 TAP이 `1..1`에서
  정지하고 rc=124(`timeout`)다. `</dev/null`이면 같은 파일 22건이 1초에 통과한다.
  이전 세션은 이 모양으로 **1시간 39분**을 태웠다(자식 프로세스 없이 블록).
- **왜 red가 아니라 hang인가**: 실패도 출력도 없이 멈춘다. 스위트가 `not ok`를 내면 사람이 읽지만,
  멈추면 **관측되는 것이 아무것도 없다.** "느린 테스트"와 구별되지 않으므로 CI 타임아웃까지 간다.
- ⚠️ **venue가 갈리는 자리다.** CI가 이걸 안 밟는 것은 러너의 성질이 아니라 `ci.yaml:245`가 러너를
  `&`로 띄우기 때문이다(비대화형 bash의 async 명령은 fd 0이 `/dev/null`). `make ci`는 포그라운드라
  호출자의 fd 0을 그대로 물려받는다. 즉 **로컬만 밟고 CI는 영원히 초록**이다 — 「tracked 열거 게이트는
  untracked 파일을 아예 안 본다」와 같은 클래스(로컬 초록이 CI를 예고하지 못하는 것의 거울상)다.
- ⇒ **처방은 3층이고 층마다 막는 것이 다르다.**
  1. **러너가 스스로 fd 0을 끊는다**(`scripts/run-bats.sh`의 `exec 0</dev/null`) — 클래스 전체를
     구조적으로 없앤다. 호출면 전량(`Makefile`·`iac.yaml`·`AGENTS.md`)도 `</dev/null`을 붙인다.
     ⚠️ `>/dev/null`은 stdout이라 격리가 **아니다**.
  2. **스텁의 입력원을 argv로 못박는다** — 파일 인자는 항상 마지막 위치라는 규약
     (`for f in "$@"; do :; done; exec cat "$f"`). 이게 결함 자체의 수정이다. 1층만 하면 스텁은
     여전히 계약을 어기고 있고, `</dev/null`을 빠뜨린 새 호출면에서 되살아난다.
  3. ⚠️ **per-@test 타임아웃 백스톱은 쓸 수 없다.** 1·2층이 못 덮는 잔여 블로킹(스텁이 스스로 여는
     fifo·`/dev/tty` 직접 열기)은 열거할 수 없고, 열거 없이 fail-loud하는 유일한 기전이
     `BATS_TEST_TIMEOUT`이다. 그런데 그 값이 설정돼 있으면 **실패하는 중첩 bats를 부르는 @test가
     거짓 타임아웃**을 낸다. 최소 재현(2026-08-20): `run bats <통과하는 파일>`은 1초에 끝나고,
     **같은 구조에서 안쪽 파일만 실패하게 바꾸면** 타임아웃을 꽉 채우고 죽는다. 라이브에서는
     `tests/gates/test_guard-skip-signalling.bats`의 "reports failure (not skip)…"가 그랬다 —
     백스톱 없이 0초 통과, `BATS_TEST_TIMEOUT=40`이면 40초 후 red이고 진단은 `echo '}'`라는
     **도달 불가능한 자리**를 가리킨다(그래서 원인을 코드에서 찾으면 영원히 못 찾는다).
     이 레포는 **fail-closed를 단언하는 게이트가 다수**라 그런 @test가 우연이 아니라 구조적으로
     존재한다 ⇒ 보험이 통과하던 게이트를 깨뜨리는 **순손실**이다. 넣지 마라.
- ⚠️ **정적 스캐너("스텁 본문에 bare `cat` 금지")는 만들지 않았다.** 이 레포의 스텁은 `printf`·
  heredoc·`cat >`로 제각각 쓰이고 정당한 `cat`(파이프 계약이 확실한 자리)이 다수라, 술어가 넓으면
  거짓 양성이 쏟아지고 좁히면 곧 vacuous해진다. 대신 **행동 증인**을 쓴다: 스텁 emitter를 헬퍼로
  묶고, stdin에 **다른 내용을 파이프로 흘린 채** 호출해 출력이 파일 내용인지 단언한다. 헬퍼가 bare
  `cat`으로 되돌아가면 hang이 아니라 **red**가 된다(파이프에는 EOF가 있다). 실측으로 감도를 확인했다.
> 가드: `scripts/run-bats.sh`, `tests/test_sealed-secrets-restore.bats`

### 호스트 포트 밴드는 ephemeral뿐 아니라 NodePort도 피해야 한다 — NodePort는 리스너가 아니라 nat 규칙이라 어떤 bind 프로브로도 안 보인다
- 임시 컨테이너에 호스트 포트를 붙이는 하네스는 "빈 포트"를 골라야 하는데, **무엇이 비었는지 묻는
  방법이 세 가지고 셋 다 다른 답을 준다.** 예전 구현은 20000-39999에서 뽑고 `/dev/tcp` connect로
  확인했다 — 범위와 프로브가 각각 틀렸다.
- **① 커널 ephemeral과 겹치면 자기 자신과 경합한다.** 이 NUC은 32768-60999라 예전 밴드와 7232포트가
  겹쳤다. 하네스 자신의 `curl`(health 폴 60회 + 매 질의)이 그 대역에 아웃바운드 소스 포트를 계속
  만들므로 **혼자 돌아도** 자기 포트를 빼앗긴다. 2026-08-19 실측 실패 포트 35704가 정확히 이 구간이다.
  ⇒ "병렬 실행의 TOCTOU"로 진단하면 처방이 빗나간다. 병렬도를 낮춰도 안 없어진다.
- **② NodePort는 어떤 bind 프로브로도 안 보인다.** k8s 기본 30000-32767이 예전 밴드에 통째로 들어
  있었다. NodePort는 리스너가 아니라 **nat 규칙**(KUBE-NODEPORTS DNAT)이라 프로세스가 그 포트를
  잡고 있지 않다. **실측(2026-08-20)**: 30953 = `gateway/traefik:443`인데 `ss -ltnp` 0건 ·
  connect 프로브 FREE · **plain bind도 FREE** · 그런데 `curl http://127.0.0.1:30953/health`는
  Traefik의 `404 page not found`를 받는다. ⇒ 컨테이너는 정상 기동하고 `docker port` 대조까지
  통과하는데 질의만 남의 서비스로 간다. 예전 코드는 그 상태를 60×0.5s 태운 뒤 **"not ready"로
  오진**했다 — 원인이 로그 어디에도 없다. **프로브를 아무리 고쳐도 못 잡는다. 밴드에서 빼는 것이
  유일한 처방이다.**
- **③ connect 프로브는 리스너만 본다.** `/dev/tcp`(그리고 `nc -z`)는 "지금 접속되는가"를 묻는데,
  bind가 실패하는 포트는 그보다 넓다. **실측**: 리스너를 닫고 남은 accepted 소켓이 붙든 포트와
  아웃바운드 연결의 로컬 소스 포트 — 둘 다 connect는 FREE라 답하고 plain bind는 EADDRINUSE(98)다.
  ⇒ **런타임이 실제로 던지는 질문(bind)을 그대로 던져야 한다.**
- **④ `127.0.0.1` bind 프로브는 특정 인터페이스에만 있는 리스너를 못 본다.** ③에서 프로브를 bind로
  고쳐도 **바인드 주소**라는 축이 하나 더 남는다. **실측(2026-08-21, 같은 포트)**: 점유가
  `127.0.0.1`이면 두 프로브 모두 BUSY(98), 점유가 `0.0.0.0`이어도 두 프로브 모두 BUSY, 그런데 점유가
  **글로벌 IP(192.168.x.x) 하나뿐**이면 `127.0.0.1` 프로브는 **FREE라고 오답**하고 `0.0.0.0` 프로브만
  BUSY다. `0.0.0.0` bind는 그 포트를 **어느 주소로든** 잡고 있으면 실패하므로 세 경우를 다 맞히는
  엄격한 상위집합이다. ⇒ 소비자가 루프백 전용으로만 바인드한다면 차이가 안 나지만, 컨테이너가
  host-gateway로 붙는 헬퍼(telegram mock·블랙홀 sink)는 **`0.0.0.0`에 바인드할 수밖에 없어** 그
  오답이 곧 EADDRINUSE 사고다. 엄격한 쪽으로 틀리는 대가는 "쓸 수 있는 포트를 가끔 건너뛰는 것"뿐이고
  재추첨이 흡수한다.
- ⚠️ **그 bind 프로브에 `SO_REUSEADDR`를 켜지 마라.** 실측: accepted 소켓이 잡은 포트에 대해
  `bind+SO_REUSEADDR`는 **성공**하고 plain bind는 EADDRINUSE다. REUSEADDR를 켜면 프로브가 런타임보다
  **관대**해져 못 쓰는 포트를 배정한다. plain bind는 어떤 런타임보다 같거나 엄격해 안전한 방향으로만
  틀린다(TIME_WAIT 포트를 가끔 건너뛸 뿐이다).
- ⇒ **처방은 세 겹이고 각각 다른 것을 막는다.** ①② 밴드를 두 예약 **밖**으로 옮기고 그 배타성을
  **라이브로** 검사한다(상수만 두면 호스트가 범위를 바꿀 때 조용히 회귀한다). ③ 프로브를 plain
  bind로 바꾼다. 그리고 프로브~`docker run` 사이의 **잔여 TOCTOU**만 재시도가 흡수한다 —
  재시도는 결함 제거가 아니라 잔여 흡수이므로, 밴드를 안 고치고 재시도만 넣으면 실패율만 낮아지고
  ②는 그대로 남는다.
- ⚠️ **재시도의 판별자를 메시지나 종료코드로 삼지 마라.** 같은 podman도 pasta/rootlessport로 문자열이
  갈리고 CI의 dockerd는 또 다르다 — venue 의존 판별자는 한 venue에서 조용히 무력해진다. 판별자는
  "**서로 다른 포트로 다시 하면 되는가**" 하나이고, 서로 다른 포트 N개에서 모두 실패하면 그때는
  포트 경합이 아니므로 원본 stderr 전량과 함께 fail-closed한다.
- ⚠️ **실패한 `docker run -d`는 컨테이너를 Created로 남긴다** → 같은 이름으로 재시도하면
  "name already in use"로 죽는다. 재시도 직전에 `docker rm -f`를 넣지 않으면 재시도가 있는데도
  회복하지 못한다(podman 전용 `--replace`는 docker 양립성이 없다).
- ⚠️ **health 확인은 2xx가 아니라 본문을 봐야 한다.** ②의 서명이 정확히 "HTTP는 200인데 남의 답"이다.
  본문이 기대값이 아니면 그것은 "아직 안 뜸"이 아니라 **라우팅이 우리 것이 아니라는 확정**이므로
  대기가 아니라 즉시 FAULT다.
- ⚠️ **처방을 한 소비자의 lib 안에 두면 형제 표면은 원리적으로 그 처방을 못 받는다.** 위 세 겹을
  `lib/vmalert-e2e.sh`에 넣고 완전성 가드를 `vmalert-*-firing-e2e.sh` 글롭으로 걸었는데, 그 글롭
  **밖**에 호스트 포트를 잡는 표면이 남아 있었다 — 하네스 둘(`alertmanager-render-e2e.sh` ·
  `skopeo-timeout-smoke.sh`)에 리터럴 포트 셋(AM publish `9093` · telegram mock `8089` ·
  블랙홀 sink `18443`). 열거가 붕괴한 것이 아니라 **열거 범위가 처음부터 좁았다** — 그래서 바닥값도
  want/got 대조도 이 갭에 대해 원리적으로 침묵한다. ⇒ 프리미티브는 소비자 중립 lib
  (`tests/gates/lib/host-port.sh`)이 소유하고, 완전성은 소비자 글롭이 아니라 **"호스트 포트를 잡는
  행위"** 를 도메인으로 삼는 가드(`scripts/check-host-ports.sh`)가 hard-zero로 강제한다.
> 가드: `tests/gates/test_vmalert-e2e-port-allocation.bats`, `tests/gates/lib/vmalert-e2e.sh`, `tests/gates/lib/host-port.sh`, `scripts/check-host-ports.sh`, `tests/gates/test_host-ports.bats`

### `&`로 띄운 헬퍼의 바인드 실패는 `set -e`에 안 걸린다 — readiness 줄이 없으면 30초 뒤 엉뚱한 곳을 가리키는 오진이 된다
- 하네스가 보조 서버를 `cmd … &`로 띄우면 **`set -euo pipefail`은 그 종료코드를 보지 않는다.**
  `wait`도 liveness 확인도 없으면, 그 프로세스가 즉사해도 하네스는 그대로 다음 단계로 간다.
- **실측(2026-08-21)**: `tests/gates/alertmanager-render-e2e.sh`가 telegram mock을 고정 포트 `8089`에
  `&`로 띄웠다. 그 포트를 미리 점유한 채 같은 argv로 돌리면 mock은 `OSError: [Errno 98] Address
  already in use` 트레이스백과 함께 rc=1로 죽는다. 그런데 하네스는 진행해서 → AM readiness 통과 →
  alert inject 8회 재시도 끝에 성공(AM은 실제로 받는다) → `wait_capture`가 60×0.5s를 소진 →
  `no telegram capture within timeout` + **AM 로그 tail**로 종료한다. 즉 **최종 진단이 포트가 아니라
  메시지 템플릿을 가리키고**, 진짜 원인인 트레이스백은 그 로그 60줄 위에 있다.
- ⇒ 처방은 **readiness 줄을 계약으로 만드는 것**이다: 헬퍼가 바인드 성공 직후 stderr에 한 줄을 쓰고,
  호출자가 그 줄(또는 프로세스 사망)을 기다린다. 형제 `tests/gates/tcp-blackhole-sink.py`가 이미
  `sink: listening on <port>`로 그렇게 하고 있었다 — **같은 레포 안에서 한쪽만 처방을 받은 상태**였다.
- ⚠️ 대기 루프는 `kill -0`로 **프로세스 사망도** 탈출 조건에 넣어야 한다. readiness 줄만 기다리면
  이미 죽은 헬퍼를 상대로 타임아웃을 꽉 채우고, 그러면 오진 시간이 줄어들 뿐 없어지지 않는다.
- ⚠️ 헬퍼에 **argc 가드**를 넣어라. 인자가 모자라면 `IndexError` 트레이스백이 background job의
  stderr로만 나가 호출자가 못 본다 — 같은 오진이 다른 입구로 돌아온다.
> 가드: `scripts/check-host-ports.sh`, `tests/gates/test_host-ports.bats`

### `Restart=always` 유닛은 failed 상태에 진입하지 않는다 — 시작 rate limit에 못 닿으면 영원히 activating이다
- `systemctl list-units`를 읽어 "failed인 유닛"을 감시하는 축을 만들면, **상시 재시작 서비스가 그
  축에 원리적으로 잡히지 않는다.** systemd는 `Restart=`가 붙은 유닛을 실패 시 `auto-restart`로
  돌리고, **시작 rate limit(`StartLimitBurst` 회를 `StartLimitIntervalUSec` 안에)에 도달했을 때만**
  `failed`로 확정한다. 그 한계에 못 닿으면 유닛은 영원히 `activating (auto-restart)`를 오간다.
- **실측(2026-08-20, 이 NUC)**: `k3s.service`는 `Restart=always` · `RestartUSec=5s` ·
  `StartLimitIntervalUSec=10s` · `StartLimitBurst=5`다. 10초 창에 5초 간격이면 시도가 **최대 3회**라
  burst 5에 **구조적으로 도달할 수 없다** ⇒ k3s가 크래시루프에 빠져도 `failed`가 되지 않는다.
  즉 전역 스윕이 그 장애를 **못 본다**.
- **무엇이 위험한가**: 위험은 못 보는 것 자체가 아니라 **"이제 전역을 덮었다"는 오해**다.
  스윕을 넣고 나면 호스트 실패가 전부 커버된 것처럼 읽히는데, 정작 가장 중요한 서비스가
  그 커버리지 밖이다. 「열거 붕괴 → vacuous green」의 사촌인데, 여기서는 열거가 아니라
  **상태 정의**가 구멍이다 — 유닛이 목록에 **있고** 상태도 정확한데, 그 상태가 `failed`가 아니다.
- ⇒ **처방: 축을 나눠 적고, 각 축이 못 보는 것을 그 축의 문서에 적는다.** 상시 재시작 서비스의
  생존은 systemd가 아니라 **그 서비스가 제공하는 것**으로 본다(k3s면 TargetDown·Watchdog·
  off-node deadman). 스윕이 커버하는 것은 `Restart=no` 유닛이다 — 이 호스트에서는 `apt-daily`·
  `apt-daily-upgrade`·`fstrim`·`logrotate`·`man-db`·`unattended-upgrades`·`e2scrub_all` 등이다.
- ⚠️ **`StartLimitBurst`를 낮춰 "failed에 도달하게 만드는" 것은 처방이 아니다.** 그러면 일시적
  장애에서 k3s가 재시작을 **포기**하고 죽은 채로 남는다 — 관측을 얻으려고 복원력을 파는 거래다.
  관측이 필요하면 관측 축을 따로 놓는다.
> 가드: `tests/gates/test_systemd-failed-sweep.bats`, `scripts/sweep-systemd-failures.sh`

### ERE의 leftmost-longest가 `^A|B.*$` 한 방을 토큰 전체 삭제로 바꾼다 — 검출기가 자기 도메인의 표기법에 눈이 먼다
- **병(2026-08-24 실측, `scripts/check-host-ports.sh` 도입판)**: publish 인자에서 따옴표를 벗기려고
  `gsub(/^["']|["'].*$/, "", cand)` 한 방을 썼다. 그런데 POSIX ERE는 **오프셋이 앞선 매치를 먼저**
  고르고, 같은 오프셋이면 **가장 긴 대안**을 고른다(leftmost-longest). `"9093:9093"`은 오프셋 0에서
  두 대안이 **동시에** 시작하므로 더 긴 `["'].*$`가 이겨 **토큰 전체**를 먹는다 ⇒ `cand=""`.
  `printf '%s' '-p "9093:9093"' | awk '{c=$2; gsub(/^["'"'"']|["'"'"'].*$/,"",c); print "["c"]"}'` → `[]`
  (gawk 5.3.2 · mawk 1.3.4 동일).
- **왜 침묵했는가**: 빈 `cand`는 `split(cand, part, ":")`가 0을 줘 `np < 2`에서 조용히 `continue`된다.
  그 `continue`가 `binds[FILENAME]=1`보다 **위**라, 레인 A(리터럴 호스트 포트)뿐 아니라
  레인 C(배정 lib 미사용)까지 **함께 꺼졌다**. 가드 헤더가 「A가 못 보면 C까지 함께 꺼진다」고
  스스로 적어 둔 그 자리를 정작 정규식이 밟았다.
- ⚠️ **하필 사각지대가 이 레포의 실제 표기였다.** 하네스는 `-p "127.0.0.1:${PORT}:9093"`처럼 따옴표로
  쓴다. 즉 가드가 초록인 채로, 그 가드가 없앴다고 선언한 사고를 그대로 되돌릴 수 있었다 —
  실측: 이 PR이 고친 두 자리를 따옴표를 **유지한 채** 리터럴로 되돌려도 `0곳 OK` rc=0.
- ⚠️ **bats 대조군이 함께 눈이 멀어 있었다.** dirty 픽스처는 전부 따옴표 **없이**, clean 픽스처만
  따옴표형이었다. 그래서 clean 레인은 변수를 리터럴로 바꿔도 통과하는 **vacuous 대조**였다.
  픽스처의 표기가 도메인의 표기와 다르면, 통과한 대조는 아무것도 증명하지 않는다.
- ⇒ **처방: 벗기기와 자르기를 두 `sub`로 나눠 순서를 강제한다.** `sub(/^["']/,"",c)`로 선두를 먼저
  벗기면, 남은 따옴표는 정의상 **닫는** 쪽이므로 `sub(/["'].*$/,"",c)`가 안전하다. 대안에 `.*`가
  들어가는 순간 그 대안은 나머지 전부를 먹을 수 있다고 읽어라. (`$` 앵커만 있고 `.*`가 없는
  `["'&;)]+$` 형태는 이 함정에 걸리지 않는다 — 같은 파일의 레인 D가 그 형태다.)
- ⇒ **그리고 픽스처는 도메인이 실제로 쓰는 표기로 적는다.** 양성 픽스처를 표기별로 전부 걸어라
  (`"…"` · `'…'` · `-p "host:c:h"` · `--publish="…"`). 하나만 걸면 다음 표기로 조용히 빠져나간다.
> 가드: `scripts/check-host-ports.sh`, `tests/gates/test_host-ports.bats`

### heredoc 상태 기계가 주석 규칙보다 먼저 돌면, `<<PY`를 인용한 주석 한 줄이 파일의 나머지를 통째로 지운다
- **병(2026-08-24 실측)**: awk 검출기가 heredoc 본문을 건너뛰려고 상태 기계를 `{ ... }` 무조건
  블록에 두었는데, 주석 스킵 규칙 `/^[ \t]*#/ { next }`가 그 **아래**에 있었다. awk는 규칙을 적힌
  순서로 평가하므로 **주석줄도 heredoc 시작 판정을 받는다**. `# 예전엔 \`python3 - <<PY\`로 …`
  한 줄이 `inhere=1`·`delim="PY"`를 세우고, 그 뒤 모든 줄이 `next`로 빠져 레인이 하나도 안 돈다.
- ⚠️ **[E](미종료 heredoc) 레인도 침묵한다.** 그 파일에 **진짜** `PY`/`EOF` 종료줄이 이미 있으면
  가짜 heredoc이 거기서 조용히 닫히기 때문이다. 실측: 추적 도메인 15파일 중 5파일이 그 조건을
  만족했다 — 즉 절반 가까이가 fail-open, 나머지만 fail-closed라는 **비대칭 침묵**이었다.
- ⚠️ **파일 수 축 회계로는 원리적으로 못 본다.** `SCAN:` 신호도 `READFILES` 대조도 **파일 개수**를
  세므로, 파일이 열리기는 했으나 그 안이 통째로 스킵된 붕괴에는 둘 다 정상값을 낸다. 열거 붕괴를
  파일 수로 막는 규율은 **줄 단위 붕괴에 대해서는 대조군이 아니다.**
- ⚠️ **AGENTS.md 컨벤션이 이 지뢰를 밟도록 유도한다.** 이 레포의 규율은 "고친 함정을 인용하며
  설명"하는 것이고, 하네스는 `<<PY`·`<<EOF` 투성이다. 도입 시점에는 히트가 0이었으니 초록이
  거짓은 아니었다 — **다음 편집 한 줄이 잠복을 깨우는** 형태다.
- ⇒ **처방(일반형): 주석 인식이 heredoc *시작* 판정보다 먼저 와야 한다.** 그 자리가 상태 기계
  **안인지 밖인지는 가드의 구조가 정한다** — 두 소비자가 서로 다른 자리에 두고 둘 다 옳다(2026-08-27 실측).
  - `scripts/check-bats-style.sh`는 `inhere` **닫힘 판정 뒤**에 둔다(원 처방 그대로).
  - `scripts/check-locale-collation.sh`는 상태 기계 **전체 위**에 둔다. 이 가드의 `//` 규칙은 TS 표면의
    주석 억제도 **겸하는데** 상태 기계가 `FILENAME !~ /\.m?ts$/`로 게이트돼 있어, 안으로 옮기면 TS 주석이
    억제를 잃고 `// localeCompare`가 위반으로 잡힌다(기존 회귀 테스트가 red가 된다 — 실측).
  - ⚠️ **"닫힘 판정보다 앞에 두면 본문의 `#` 줄이 종료 판정을 못 받는다"는 이 레포에서 도달 불가다** —
    시작 정규식이 `<<` 뒤에 `[A-Za-z_][A-Za-z0-9_]*`를 요구하므로 delimiter가 `#`로 시작할 수 없다.
    그 사실에 **기대는** 배치는 아래 음성 대조를 반드시 함께 둔다.
- ⇒ **음성 대조가 처방의 절반이다.** 재배치가 상태 기계 **자체를 없앤 것이 아님**을 픽스처로 고정한다 —
  진짜 heredoc 본문(안에 `#` 줄 포함)의 위반은 **안 잡히고**, 종료줄 **뒤**의 위반은 **잡힌다**를 한
  픽스처에서 "위반 정확히 1건"으로 단언하면 억제와 종료가 함께 증명된다. 실측: 상태 기계를 지우는
  뮤테이션에 이 대조만 red가 되고 양성 테스트는 초록으로 남는다 — 두 축이 갈린다는 증거다.
- ⇒ **같은 클래스의 네 번째다.** 앞의 셋은 `<<<` herestring(2번째 `<`부터 `<< "foo"`로 읽힌다),
  산술 좌시프트 `$(( a << b ))`, 그리고 **TS 문자열 속 `<<id>` 토큰**이다(2026-08-27 실측 —
  `tools/ensure-bump-pr.ts`의 봇 이메일 문구가 `id`를 delimiter로 세워 그 파일 **756줄**을 가렸다).
  네 번째의 처방은 열거가 아니라 **표면 종류 게이트**다: TS/MTS엔 heredoc 문법이 아예 없으므로
  상태 기계를 그 표면에서 끈다. **`<<`를 문자로 보는 상태 기계는 그것이 heredoc이 아닌 경우를
  전부 열거해야 하고, 그 열거는 계속 는다** — 새 오인원을 만나면 회귀 픽스처를 함께 남겨라.
- ⚠️ **줄 단위 붕괴는 척도를 섞기 쉽다.** 회복량을 잴 때 "미종료 heredoc 이후의 줄"을 pre/post 같은
  기준으로 세라. post에서만 주석 줄을 카운터 밖으로 빼면 회복량이 부풀려진다(2026-08-27 리뷰가 실측으로
  정정: 552 → 633, 회복 2,404 → **2,323**).
> 가드: `scripts/check-host-ports.sh`, `tests/gates/test_host-ports.bats`, `scripts/check-locale-collation.sh`, `tests/gates/test_locale-collation.bats`, `scripts/check-bats-style.sh`, `tests/gates/test_bats-style.bats`

### 면제 판정이 주석보다 먼저 돌면, 규약을 *설명한* 파일이 그 규약에서 면제된다 — 가드 자신부터
- **병(2026-08-24 실측, `scripts/check-bats-fd0.sh` 도입판)**: "이 파일이 스스로 `exec 0</dev/null`을
  하는가"로 면제를 판정하는 규칙(`/exec[ \t]+0<[ \t]*\/dev\/null/ { self = 1 }`)이 주석 스킵
  `/^[ \t]*#/ { next }`와 `name:` 스킵보다 **위**에 있었다. awk는 규칙을 적힌 순서로 평가하므로
  **그 문자열을 인용하기만 한 줄도 면제를 세운다.**
- **세 표면이 모두 걸렸다**(실측, 셋 다 `rc=0` + "전건 fd 0 격리 OK"): 셸 헤더 주석 한 줄 ·
  Makefile `##` 도움말 · 워크플로 스텝 `name:`. 각 경우 같은 파일에서 그 한 줄만 빼면 즉시 `[FD0]`가 난다.
- ⚠️ **가드 자신이 영구 면제 상태였다.** 헤더가 규약을 설명하며 `exec 0</dev/null`을 인용하기 때문이다.
  즉 그 파일에 위반을 넣어도 잡히지 않았다 — hard-zero를 선언한 가드가 자기 자신에게만은 waiver였다.
- **왜 이 클래스가 반복되는가**: 「면제는 파일 목록이 아니라 **사실**로 판정한다」는 규율은 옳다.
  그런데 그 "사실"을 **텍스트 매칭**으로 읽는 순간, 규약을 문서화한 산문이 규약 준수의 증거로 오인된다.
  이 레포는 "고친 함정을 인용하며 설명"하는 컨벤션을 갖고 있어 그 오인원이 도처에 있다.
- ⇒ **처방: 면제 판정을 주석·이름 스킵 **뒤**로, 그리고 `code()`로 행간 주석을 벗긴 텍스트에 대해 한다.**
  판정 대상은 "파일에 그 문자열이 있는가"가 아니라 "**코드에** 그 문장이 있는가"다.
- ⇒ **회귀 픽스처는 세 표면을 전부 건다**(셸 주석 · `##` 도움말 · YAML `name:`). 하나만 걸면 나머지
  표면으로 조용히 빠져나간다. 음성 대조(**진짜** exec 줄은 여전히 면제)를 함께 두어, 수정이 면제
  자체를 없앤 것이 아님을 증인으로 남긴다.
> 가드: `scripts/check-bats-fd0.sh`, `tests/gates/test_bats-fd0.bats`

### SKIP(exit 4)을 모르는 대조는 gitignored 자산이 있는 로컬에서만 초록이다 — venue가 갈리면 로컬은 CI를 예고하지 못한다
- **병(2026-08-24 실측)**: `tests/gates/test_scan-floor.bats`의 로스터 대조는 커널 가드를 **실제로 실행**해
  `SCAN:` 라벨을 모으고 정적 열거와 집합 비교한다. 그런데 `scripts/verify-credential-inventory.sh`는
  대상 런북이 **gitignored 로컬 전용**이라 CI에서 원리적으로 `exit 4`(SKIP)를 내고 SCAN 라벨을 0개 낸다.
  대조는 그 rc를 "가드가 비-0으로 죽었다"로 읽었다 ⇒ **로컬 `make ci` rc=0 · PR `gate` FAILURE.**
- **왜 사전에 안 보였는가**: 로컬에는 런북이 있어 같은 가드가 rc=0을 내고 라벨 2개를 낸다.
  즉 **로컬 초록이 CI를 예고하지 못하는 형태**다(「tracked 열거 게이트는 untracked 파일을 안 본다」의
  거울상 — 그쪽은 로컬에만 있는 파일을 CI가 못 보는 것이고, 이쪽은 로컬에만 있는 파일이 rc를 바꾼다).
  재현은 `git archive HEAD | tar -x -C <스크래치>`면 된다 — gitignored가 빠진 트리가 곧 CI 트리다.
- ⇒ **처방 ①: SKIP은 실패가 아니고, 대조에서 양쪽이 대칭으로 빠져야 한다.** SKIP한 가드의 라벨을
  런타임에서만 빼면 정적 쪽이 남아 반대 방향으로 red다. 그 가드의 라벨을 정적 집합에서도 뺀다.
- ⇒ **처방 ②: SKIP에는 상한을 둔다.** 없으면 "전부 SKIP → 양쪽 공집합 → 등식 성립"이라는 vacuous
  green이 열린다. SKIP 수는 venue에 따라 달라지므로(로컬 0 · CI 1) 바닥값이 아니라 **상한**이다.
  그리고 SKIP한 가드 이름을 항상 출력해 커버리지 축소가 diff와 로그에 보이게 한다.
- ⚠️ **`out="$(...)"; rc=$?`는 bats에서 못 쓴다.** bats는 `set -e` 아래라 **할당이 비-0이면 그 줄에서
  죽어** 다음 줄의 rc 판정에 도달하지 못한다(이 수정의 첫 판이 정확히 그래서 CI조건 재현에서
  `failed with status 4`로 깨졌다). `rc=0; out="$(...)" || rc=$?`로 써야 한다 — 형제 가드들이
  `|| arc=$?`를 쓰는 이유가 그것이다.
> 가드: `tests/gates/test_scan-floor.bats`, `scripts/verify-credential-inventory.sh`

### `findings="$(awk … || true)"` — 검출기가 죽어도 "0곳 OK"를 내는 가드 본체의 fail-open
- **병(라이브 실측 2026-08-24)**: awk 검출기를 쓰는 정적 가드들이 결과를 `findings="$(awk "$DETECT"
  "${FILES[@]}" || true)"`로 받았다. 그 `|| true`는 **awk가 fatal로 죽은 rc까지** 삼킨다. 그러면
  `findings`가 비고, 카운트가 0이 되어 가드는 `"0곳 OK" rc=0`을 낸다 — **검출기가 아무것도 안 봤는데
  통과**다. 뮤테이션 증인: `check-locale-collation.sh`·`check-bats-style.sh`의 awk 프로그램에
  syntax error를 한 글자 심으면(`gsub`→`gsub_TYPO`) red 없이 그대로 초록이었다.
- **왜 `|| true`가 거기 있었는가**: 정당한 이유가 있다 — `set -euo pipefail` 아래에서 awk가 매치 0건에
  비-0을 내는 구현이 있고(일부), 그걸 실패로 오인하지 않으려 붙였다. 그러나 그 관용구는 **매치 0건**과
  **검출기 사망**을 구별하지 못한다. 둘 다 rc≠0인데 뜻이 정반대다.
- ⇒ **처방은 세 겹이다**(형제 `check-host-ports.sh`가 먼저 채택, #525):
  ① awk rc를 `2>"$errlog"` + `|| arc=$?`로 **포착**하고, 0이 아니면 "판정 불가는 통과가 아니다"로 red.
  ② 인자를 awk에 넘기기 **전에** `[ -r "$f" ]`로 검증한다 — 읽을 수 없는 파일이 gawk를 fatal로 죽인다.
  ③ awk가 `END { printf "READFILES=%d\n", nfiles > "/dev/stderr" }`로 **실제로 읽은 파일 수**를 보고하고,
     셸이 그것을 열거 수와 대조한다. SCAN 신호(scan-floor)는 "열거한" 수라, 검출이 중간에 무너져도
     그 수는 그대로 나가므로 개수 축만으로는 이 붕괴를 원리적으로 못 본다.
- ⚠️ **이 처방을 한 가드에만 넣으면 형제가 남는다.** #525가 host-ports에 넣었을 때 핸드오프가
  "check-locale-collation·check-bats-style에 같은 `|| true`가 그대로다"라고 후속 후보로 남겼고,
  실측하니 그 두 줄이 문자 그대로 동일했다. 같은 lib(`scan-floor.sh`)를 쓰는 awk 가드는 전부 이
  패턴을 공유하므로, 새 awk 가드를 추가할 때 이 세 겹을 함께 넣어야 한다.
  실측(2026-08-25): 이 문단을 읽고 만든 새 awk 가드(`check-scan-producers.sh`)가 첫 판에서 세 겹을 빠뜨리고
  SCAN 마커를 검출 **전에** 냈다 — 리뷰가 잡았다. 처방은 읽는 것이 아니라 자매 가드의 **순서를 베끼는** 것이다.
> 가드: `scripts/check-host-ports.sh`, `scripts/check-locale-collation.sh`, `scripts/check-bats-style.sh`, `scripts/check-scan-producers.sh`, `tests/gates/test_host-ports.bats`, `tests/gates/test_locale-collation.bats`, `tests/gates/test_bats-style.bats`
### vmalert에 configCheckInterval이 없으면 룰 파일 변경을 감시하지 않는다 — ArgoCD가 갱신해도 옛 룰을 계속 평가한다
- **병**: vmalert(그리고 vmagent)는 마운트된 룰/스크래이프 설정 파일의 변경을 **기본으로 감시하지 않는다.**
  `-configCheckInterval`(vmagent는 `-promscrape.configCheckInterval`)이 설정돼야 그 주기로 파일을 다시
  읽는다. 이 플래그가 없으면 ArgoCD가 ConfigMap을 갱신하고 kubelet이 마운트를 새 내용으로 바꿔도,
  vmalert는 **메모리상 옛 룰을 계속 평가**한다 — 수동 `rollout restart`나 `-/reload`를 칠 때까지.
- **왜 위험한가**: 이것은 red가 아니라 **silent staleness**다. 룰을 고치는 커밋이 머지되고 ArgoCD가
  Synced/Healthy를 보고해도, 정작 발화 판정은 옛 룰로 돈다. "배포됐다"와 "평가에 반영됐다" 사이의
  간극이 관측되지 않는다 — 알림 룰이라면 그 간극 동안 진짜 사고를 놓칠 수 있다.
- ⇒ **처방: 두 컴포넌트 모두 configCheckInterval을 명시하고, 그 존재를 게이트로 강제한다.**
  값 자체보다 **존재**가 계약이다(없으면 감시가 통째로 꺼지므로). ConfigMap 변경이 파드 재시작을
  자동으로 일으키지 않는다는 인접 함정과 짝이다 — 그쪽은 envFrom 시크릿, 이쪽은 룰 파일이다.
> 가드: `tests/gates/test_vmalert-config.bats`

### 워크플로 YAML의 따옴표 없는 스텝 이름에 콜론이 들어가면 매핑으로 파싱돼 파일이 조용히 깨진다
- **병(실측)**: `bump-poll.yaml`의 스텝 `name: 신뢰 경계: ...`가 따옴표가 없어, YAML 파서가 `신뢰 경계`를
  키로 `...`를 값으로 하는 **중첩 매핑**으로 읽었다. 그 결과 `update-image` 권위 경로(bump-poll) 전체가
  불능이 됐는데 **CI 게이트가 못 잡았다** — 워크플로가 스스로를 트리거하는 경로라 문법이 깨져도
  다른 잡의 초록에 묻혔다.
- **왜 이 클래스가 반복되는가**: YAML에서 따옴표 없는 스칼라 안의 `:`(뒤에 공백이 오면)는 **항상**
  키-값 구분자다. 한국어 스텝 이름은 "신뢰 경계:", "포트 확인:"처럼 콜론+공백을 자연스럽게 쓰므로
  이 지뢰를 밟기 쉽다. 그리고 워크플로 파일은 자기 자신을 실행하는 주체라, 깨진 파일이 낸 증상이
  "그 워크플로가 안 도는 것"이라 사후에 인지하기 어렵다.
- ⇒ **처방: 전 워크플로 YAML을 파서에 통과시키는 게이트를 둔다.** 개별 문법 규칙을 열거하는 대신
  실제 YAML 파서(bun yaml)로 파싱해 예외가 나면 red — colon-in-unquoted-name뿐 아니라 모든 문법
  회귀를 한 그물로 잡는다.
> 가드: `tests/gates/test_workflow-yaml.bats`

### bats @test 이름에 한글/CJK가 있으면 디렉토리 단위 실행에서 침묵 스킵된다
- **병**: bats를 **디렉토리 단위**로 실행하면(`bats tests/`) @test 이름의 한글/CJK가 인코딩 처리에서
  깨져 그 테스트가 **조용히 스킵**된다(단일 파일 실행에서는 재현되지 않아 로컬에서 안 보인다).
  스킵은 실패가 아니라 "그 검증이 아예 안 돈 것"이라, 회귀 테스트가 CJK 이름을 갖는 순간 그 가드는
  침묵으로 무력화된다 — dead-green의 한 형태다.
- **경계**: 깨지는 것은 `@test "이름"`의 **이름**뿐이다. em-dash·트레일링 한국어 주석·본문의 한국어는
  bats가 정상 처리한다. 그래서 이 레포의 규약은 "@test 이름은 영어만"으로 좁게 고정되고, 본문·주석의
  한국어는 허용된다.
- ⇒ **처방: @test 이름에 CJK가 있으면 red를 내는 정적 가드.** CJK 판정은 하드코딩 유니코드 범위가
  아니라 **스크립트 속성**(`\p{Han}\p{Hangul}\p{Hiragana}\p{Katakana}`)으로 한다 — Ext-A(㐀 U+3400)·
  compat 이데오그래프·Hangul 확장까지 범위 누락 없이 덮기 위해서다. 검출기가 스스로 vacuous하지
  않음을 black-box 음성 픽스처(추적 CJK 이름을 넣으면 check-skeleton이 실제로 exit≠0)로 증명한다.
> 가드: `tests/gates/test_check-skeleton-cjk.bats`, `tests/gates/test_check-skeleton-gate.bats`

### homepage: config 마운트를 readOnly로 두면 EROFS · apiserver egress는 노드 CIDR:6443이지 ClusterIP가 아니다
- **병 ①(인시던트 #65, EROFS)**: homepage는 시작 시 config를 **써야** 하는데(seed→emptyDir), 그 마운트를
  `readOnly: true`로 두면 런타임이 `EROFS`(read-only file system)로 죽는다. grep-on-source로는 안 보인다 —
  kustomize가 조립한 **최종 출력**에서만 readOnly 값이 확정되기 때문이다.
- **병 ②(인시던트 #66, apiserver egress)**: homepage가 apiserver에 닿는 egress NetworkPolicy를 쓸 때,
  대상을 **ClusterIP(kubernetes 서비스의 가상 IP)로 적으면 막힌다** — NetworkPolicy egress는 ClusterIP를
  볼 수 없고(그건 iptables/IPVS DNAT 규칙이지 실제 엔드포인트가 아니다), **노드 서브넷의 실제 IP:6443**을
  허용해야 apiserver에 도달한다. 이것은 인접 함정 「NetworkPolicy egress는 apiserver ClusterIP 불가」의
  homepage 구체화다.
- ⇒ **처방: kustomize 렌더 출력을 yq로 객체-스코프 단언한다.** ① config 마운트가 writable(readOnly!=true)
  인지, ② `allow-egress-to-apiserver` 규칙 **하나**가 노드 CIDR과 (protocol=TCP, port=6443) 엔트리를
  **동시에** 묶는지(체인 select로 같은 규칙·같은 엔트리 결속 — 두 조건이 서로 다른 규칙에 흩어져
  vacuous하게 통과하는 것을 막는다). ⚠️ CI(required gate)에서는 kustomize/yq 부재 시 skip 금지 —
  fail-closed다(가드가 dead-green이 되면 이 두 인시던트가 그대로 재현된다).
> 가드: `platform/homepage/prod/test_homepage_render.bats`, `platform/homepage/prod/test_homepage_netpol.bats`

### 상류 레지스트리의 릴리스 태그가 불변이 아니다 — 재푸시가 옛 매니페스트를 GC해 모든 PR gate를 red로 만든다
- **병(라이브 실측)**: `quay.io/skopeo/stable:v1.22.2`를 digest로 핀했는데, 상류가 **같은 태그를 주기적으로
  재푸시**하고 옛 매니페스트를 GC했다 — 2026-08-18(#518) · 08-21(#528) · 08-24(#531)로 **6일에 세 번**,
  세 번째는 재핀 PR을 머지한 **같은 세션 안에서** 죽었다. `image-pin-liveness.sh`가 라이브 레지스트리를
  조회하므로, digest가 사라질 때마다 **브랜치와 무관하게 모든 PR의 `gate`가 red**가 된다.
- **왜 재핀이 증상 대응이었는가**: 새 digest로 핀을 갱신하면 그 순간은 초록이지만, 3일 뒤 또 재푸시되면
  다시 red다. Renovate가 서드파티 digest를 주 1회 갱신하는데 상류 재푸시가 그보다 잦아, 갱신 주기로도
  못 따라잡는다. 무성 실패는 아니지만(가드가 매번 잡는다) **모든 PR을 막는 형태**라 비용이 크다.
- ⚠️ **quay를 base로 미러해도 안 된다.** `image-pin-liveness`는 `git grep`으로 추적 파일 전체의 digest
  핀을 열거하므로 `ops/*/Dockerfile`의 `FROM` 핀도 검사 대상이다 — `FROM quay.io/skopeo/...`로 미러하면
  그 핀이 그대로 같은 GC에 노출된다.
- ⇒ **처방: GC하지 않는 레지스트리 기반의 자기 소유 이미지로 옮긴다.** Docker Hub는 옛 매니페스트를
  GC하지 않는다(같은 레포의 `ops/pg-tools`가 쓰는 `debian:bookworm-slim` 핀이 오래 살아 있는 것이 증거).
  `ops/skopeo/Dockerfile`을 `FROM alpine:3.22@digest` + `apk add skopeo`로 만들어 `ghcr.io/<owner>/skopeo:alpine`으로
  게시하고, 소비자(digest-exporter·gha-liveness-exporter)가 그것을 참조한다. build→bump write-back이
  `repin-ops-image`로 digest를 재핀한다(pg-tools와 같은 경로).
- ⚠️ **소비자가 이미지의 ENTRYPOINT에 기대지 않는지 확인하라.** quay skopeo 이미지는 `ENTRYPOINT ["skopeo"]`가
  있지만, 이 소비자들은 `command: ["/bin/sh", "/script/run.sh"]`로 셸을 직접 지정하고 그 안에서 `skopeo`를
  PATH로 부른다 — 그래서 ENTRYPOINT 없는 alpine 이미지로도 그대로 동작한다(실측). ENTRYPOINT에 기댔다면
  미러 이미지에 그것을 재현해야 했다. ⚠️ **소비자 매니페스트뿐 아니라 게이트도 확인하라** — 실측:
  `skopeo-timeout-smoke.sh`가 `docker run "$IMAGE" --command-timeout=…`로 ENTRYPOINT를 전제해,
  alpine 미러에서 그 플래그를 실행 파일로 오인해 죽었다(소비자는 멀쩡한데 게이트만 red). 게이트도
  소비자와 같은 호출 형태(`skopeo`를 명시)로 맞춰야 한다. cf. 게이트가 실 도메인과 다른 방식으로
  대상을 부르면, 그 게이트가 증명하는 것은 실 도메인의 동작이 아니다.
> 가드: `tests/gates/image-pin-liveness.sh`, `ops/skopeo/Dockerfile`, `tests/gates/skopeo-timeout-smoke.sh`, `tests/gates/test_pgtools-digest.bats`, `tests/gates/test_ci-build.bats`

### TS 바닥값은 coercion 뒤에서 조용히 꺼진다 — Number("abc")는 NaN이라 n < NaN이 항상 false이고, Number("")는 0이라 빈 입력과 의도적 0을 구별할 수 없다
- **병(2026-08-25 실측)**: 셸 콜사이트는 `[ "$got" -lt "$min" ]`이 수가 아닌 값에 **에러를 낸다**. TypeScript는
  `Number("abc")`가 NaN이고 `n < NaN`이 항상 false라 **바닥값이 통째로 꺼진 채 초록**이 된다.
  구 `DISK_CAP_MIN_FLAGS=abc bun tools/check-disk-caps.ts` → SCAN 마커 방출 + rc=0(현 재현: `bun tools/check-disk-caps.ts --floor caps=abc` → exit 2·마커 없음). 오타 하나가 열거 붕괴
  방어를 되살리지 않고 **끈다** — 「열거 붕괴 → vacuous green」의 TS 얼굴이다.
- ⚠️ **숫자 검증을 coercion 뒤에 두면 빈 입력을 못 거른다.** `Number("")`는 0이고, 0은 정당한 바닥값이라
  (셸 선례 check-app-deploy 기본 바닥값 0 — 앱이 0개인 동안 열거 0건은 정당) 금지로 피할 수도 없다. 설계 게이트
  r2가 실측: `--min-refs ""`는 자체 파서(`positiveInt`)가 거부하고 `--min-scan ""`는 `Number()` 직행이라
  통과했다 — **같은 처방을 복제하면 일부가 빠진다**(2벌 복제, 미적용 2곳).
- ⚠️ **테스트 편의로 바닥값에 env 주입을 열면 required gate의 방어가 꺼진다.** 붕괴 경로를 관측하려고
  `CI_PARITY_MIN_STEPS`를 열었더니 `=0` 한 줄로 방어가 통째로 꺼졌다(리뷰 실측 → 되돌림). 주입은 애초에
  필요 없다 — 도구가 cwd/`--root`를 읽으면 픽스처 디렉토리에서 열거가 자연히 붕괴한다.
- ⇒ **처방: 판정을 `Number()` 앞에 세운다(`tools/lib/scan-floor.ts`의 `parseFloor(raw, source)`) — 빈 문자열·
  `abc`·음수·소수는 exit 2(사용법 오류, 바닥값 붕괴 1과 다른 사고), 명시적 `"0"`은 통과.** 상수로 주입되는
  자리는 파서를 안 거치므로 `scanFloor` 안의 정수 검증이 안전망으로 남는다. 바닥값 자리는 상수 또는 CLI
  플래그이지 env가 아니다.
> 가드: `tools/lib/scan-floor.ts`, `tests/gates/test_scan-floor.bats`

### 스캔 신호를 콜사이트가 손으로 내면 순서가 드리프트한다 — 위반 exit이 신호보다 앞이면 마커 0건이 '미실행'으로 읽히고, 로스터 등식은 우회를 못 잡는다
- **병(2026-08-25 실측)**: 규약은 "바닥값을 통과한 실행만 `SCAN:` 마커를 내고, 위반 유무와 무관하게 낸다"인데,
  셸은 커널(`scan_floor`)이 바닥값 시점에 내므로 자동으로 그 순서이고 TS는 콜사이트가 `console.log`로
  직접 냈다. 주석으로만 둔 규약은 **7곳 중 4곳이 어긋났다** — 위반 exit이 신호보다 앞(위반 실행에서 마커
  0건 → "안 돌았다"로 오독), 바닥값 실패인데 신호 방출(붕괴한 건수가 "검사했다"로 읽힘), 신호 부재.
  소비자(check-guard-authority)는 마커 부재를 **미지**로 읽으므로 실행 경로 회계가 과다 계상으로 기운다.
- ⚠️ **바닥값 실패를 위반 배열에 합치면 두 사고가 섞인다.** `bad.push(바닥값 진단)` 뒤에 위반을 계속 모으면
  0건에 가까운 검사에서 나온 위반이 진짜 위반처럼 보고된다. 즉사 시 **앞에서** 모인 근본원인(yq 실패·
  YAML 파싱 실패)이 사라지는 문제는 손처방("먼저 흘린다")이 아니라 **구조**가 답이었다 — guardMain
  (lib-convergence 17)은 열거가 floor보다 앞에서 끝나므로 파생 실패가 "열거 실패" 진단에 원인을 담아
  직접 보고되고, floor 오진으로 위장되지 않는다(손처방 복제 금지 — 그 두 콜사이트는 이미 이관됐다).
- ⚠️ **로스터 등식(정적 콜사이트 집합 == 런타임 방출 집합)은 우회를 못 잡는다.** 정적 집합과 실행 파일
  목록이 같은 grep 패턴에서 파생되므로 한 가드가 직접 출력으로 되돌아가면 **양쪽에서 동시에 사라져** 등식이
  그대로 성립하고, 바닥값의 여유가 정확히 한 건의 손실을 덮는다(게이트 r1 F1 실측). 인식 제거는 "안 본다"이고
  필요한 것은 "있으면 red"다. 콜사이트 **삭제**(바닥값도 함께 사라짐)는 거부 가드도 못 보며 그 가드의
  도메인 테스트가 자기 바닥값·마커를 단언하는 자리다.
- ⇒ **처방: 바닥값과 신호를 한 함수 뒤에 둔다(`tools/lib/scan-floor.ts` — 셸 adapter와 마커 형태가 한 글자도
  다르지 않은 두 번째 adapter). 커널은 `ScanError`를 던지고 종료는 콜사이트가 소유한다(`tools/lib/` 규율).
  그리고 직접 생산자를 거부한다(`scripts/check-scan-producers.sh` — 출력 동사의 인자가 마커 리터럴로 시작하면
  red, 커널 파일은 경로 하나로 면제하되 건너뛰지 않고 히트 ≥1을 검출기 생존 증거로 요구).**
> 가드: `tools/lib/scan-floor.ts`, `scripts/check-scan-producers.sh`, `tests/gates/test_scan-floor.bats`

### 테스트 이름은 인터페이스가 아니다 — 뮤테이션이 전건 red여도 픽스처가 밟지 않는 판정 조건은 무증인이다
- **병(2026-08-25, 한 캠페인의 여섯 티켓에서 여섯 번 실측)**: 테스트 **이름**은 의도를 정확히 적는데 **단언**은
  다른 것을 본다. 다섯 번은 "존재·형태만 본다"였다 — 마커의 존재와 숫자꼴만 봐서 신호 대상을 바꿔도 45건
  green, "성공 요약 부재"는 어떤 실패 경로에서도 참이라 즉사와 수집을 구별 못 함, `run bash -c` 안의 지역
  변수가 비어 아무것도 읽지 않는 단언. 여섯째는 형태가 달랐다: 저자의 뮤테이션 6종이 **전부 red였는데도**
  판정 조건 다수(홑따옴표·출력 동사 4종·`.mts` 열거·주석 앵커·정확한 면제 경로)가 **어떤 픽스처에서도
  행사되지 않았다** — 픽스처가 `console.log` + 쌍따옴표 + `.ts`만 써서, 그 조건들은 지워도 전건 green이었다.
- **왜 뮤테이션이 못 잡는가**: 뮤테이션은 구현을 바꾸고 테스트가 red가 되는지 본다. 결함이 "테스트가 무엇을
  보는가"에 있으면 구현을 바꿔도 테스트가 보는 것은 그대로다. 그리고 뮤테이션은 **픽스처가 밟는 분기만**
  증명한다 — 밟지 않는 분기의 뮤테이션은 저자가 떠올리지 않는다.
- ⇒ **처방 ①: 모든 새 증인은 뮤테이션으로 red를 확인하고, vacuity 방지 단언(대상을 실제로 읽었다·집합이
  비지 않았다·마커가 먼저 존재한다)을 함께 건다.** 부정 단언("X가 없다")은 양성 대조 없이는 대상이 아예
  없어도 참이다.
- ⇒ **처방 ②: 판정 조건마다 그 조건을 행사하는 픽스처 줄이 하나씩 있는지 센다.** 정규식의 분기(`(a|b|c)`),
  문자 클래스(`["'\`]`), 글롭 목록, 경로 비교의 정확성 — 각각 한 줄. 문서의 "표면은 셋이다" 같은 완결 주장은
  그 수를 세는 순간 틀린다(별 없는 블록 주석 본문이 넷째였다) — 열거를 문서에 적지 말고 상태 기계에 적어라.
- ⇒ **처방 ③: 리뷰와 수정을 같은 트리에서 동시에 돌리지 않는다.** 리뷰어의 뮤테이션 하네스가 작업 트리를
  되돌려 저자의 조치 두 건이 사라진 채 다음 리뷰가 돌았다(티켓 04). 리뷰는 읽기 전용으로, 수정은 전부 도착한 뒤.

### 정적 증인의 두 함정 — `^[^/]*`는 `//`만 제외하고(JSDoc ` * ` 줄이 코드가 된다), `run bash -c` 안의 bats 지역 변수는 빈 문자열이라 grep이 0건으로 항상 통과한다
- **병 ①(2026-08-25 실측)**: "커널이 `process.exit`을 부르지 않는다"를 `grep -vE '^[^/]*process\.exit'`로
  단언했다. `^[^/]*`는 `//` 줄만 제외하므로 JSDoc의 ` * ` 연속줄은 코드로 읽힌다 — 커널 독스트링에 콜사이트
  관용구 예시 `process.exit(reportScanError(…))`를 적자 그 증인이 red가 됐다. 규약은 "그 단어를 적지 않는다"가
  아니라 "**부르지** 않는다"인데, 패턴이 산문을 코드로 오인했다. 같은 클래스: 거부 가드의 첫 판은 `//`·` * `·
  `/*` 세 줄 접두를 걷어냈는데 별 없는 블록 주석 본문이 넷째 표면이었다 — 줄 접두 열거가 아니라 **블록
  주석 상태 기계**여야 하고, 진입은 행 앞 `/*`로만 한다(줄 중간 `/*`는 `"tools/*.ts"` 글롭에 흔해 파일
  나머지를 삼킨다).
- **병 ②(같은 날 실측 — 위 ①을 고치다가 새로 만들었다)**: `run bash -c "grep … $ROOT/…"`에서 `ROOT`는
  export되지 않은 bats 지역 변수라 새 셸에서 **빈 문자열**이 되고, grep이 빈 경로를 읽어 0건 → rc=1 →
  부정 단언이 **항상 통과**했다. 그 판에서 커널 끝에 `process.exit`을 넣어도 red가 나지 않았다. 빈 인자를
  문자열로 조립하는 `bash -c "… '$ROOT' $args"`도 같은 함정 표면이다(큰따옴표라 동작해도 다음 편집자가
  그 형태를 복제한다).
- ⇒ **처방: 주석은 `grep -vE '^[[:space:]]*(//|\*|/\*)'`로 먼저 걷어내되 그것도 줄 접두 열거임을 알고,
  구조가 여러 줄이면 상태 기계로. 정적 증인에는 "대상을 실제로 읽었다"는 단언(`[ -n "$code" ]`)을 함께
  건다. `bash -c` 대신 `run <함수> "$flag" "$val"`로 직접 부르고, 부득이하면 변수를 인자(`_ "$ROOT"`)로 넘긴다.**
> 가드: `tests/gates/test_scan-floor.bats`, `scripts/check-scan-producers.sh`
### QEMU amd64 leg의 bun 1.4는 RSS 24MB에서 "메모리 고갈"로 죽는다 — Dockerfile을 안 돌리는 CI는 그 6시간을 초록으로 지나친다
- **병(라이브 실측)**: `ukyi-app/trip-mate-api`의 배포가 2026-08-24부터 멈춰 있었다. 부동 태그
  `oven/bun:1-alpine`이 상류에서 1.3.x → 1.4.0으로 넘어가자, amd64 leg(`reusable-app-build`가
  arm64 러너에서 도는 구조라 **amd64만 QEMU를 탄다**)의 `bun install`이 `@prisma/client` postinstall을
  실행하는 순간 abort했다:
  ```
  #14 [linux/amd64 4/6] RUN bun install --frozen-lockfile --production
  Args: "node" "scripts/postinstall.js"
  ASSERTION FAILED: MemoryExhaustion: Crash intentionally because memory is exhausted.
  JSC::LocalAllocator::allocateSlowCase(...)
  RSS: 24.52 MB | Peak: 71.47 MB          ← 실제로는 메모리가 남아돈다
  qemu: uncaught target signal 6 (Aborted) - core dumped
  ```
  **RSS 24MB에서 "고갈"은 실제 고갈이 아니다** — QEMU 아래서 JSC가 GC 힙 블록의 주소 공간 예약에
  실패하는 것이고, 80~90ms 만에 죽는다. bun은 그 뒤 재시도에 들어가 release가 **6시간
  타임아웃**까지 갔다(run 32722287190, `1h34m`~`6h0m` 다수).
- **digest 대조가 그대로 증거다**: 8/11 성공 빌드(**1m24s**)는 `oven/bun:1-alpine@sha256:5acc90a9…`(1.3.x),
  8/24 타임아웃 빌드는 같은 태그의 `@sha256:07235578…`(1.4.0)이다. 태그는 그대로인데 내용이 바뀌었다.
  cf. 상류 릴리스 태그 불변성 항목 — 거기선 옛 매니페스트가 **사라져** red가 됐고, 여기선 태그가
  **조용히 다른 것을 가리켜** 무한 재시도가 됐다. 둘 다 부동 태그의 같은 뿌리다.
- ⚠️ **`ci.yml`이 초록인 것은 아무것도 증명하지 않는다.** trip-mate의 CI는 ubuntu-latest에서 bun을
  직접 설치해 lint·fmt·typecheck·test·openapi-drift를 돌린다 — **Dockerfile을 한 줄도 실행하지 않는다.**
  그래서 베이스 이미지·멀티아치·설치 스크립트에서 나는 고장은 원리적으로 못 본다. 게이트는 머지 후,
  그것도 '이미 배포되는 중'인 release에서 처음 울렸고, 그 사이 의존성 PR 10건이 초록으로 머지됐다.
  page 레포엔 같은 성격의 `pr.yaml`(reusable을 `push:false`로 호출)이 있어 이 갭이 없었다 — 실제로
  같은 bun 1.4.0 범프가 page에선 **PR 단계에서 red**로 잡혔다. 같은 조직·같은 reusable인데 한쪽만
  6시간을 태운 차이가 그 게이트 하나다.
- ⚠️ **JSC 옵션으로는 못 막는다(실측).** 주소 공간 예약 자체가 실패하는 것이라 튜닝 대상이 아니다:

  | 시도 | 결과 |
  |---|---|
  | `BUN_JSC_useJIT=0` | 같은 자리에서 crash(JIT이 아니라 GC 힙이다) |
  | `BUN_JSC_forceRAMSize=2GiB` | 같은 자리에서 crash |

  참고로 `BUN_JSC_useGigacage`는 **존재하지 않는 옵션**이다(bun이 `invalid JSC environment variable`로 거부).
- ⇒ **처방: 에뮬레이션을 타는 자리를 없앤다. 어느 쪽인지는 그 스테이지 산출물이 아키텍처에 묶이는지로 갈린다.**
  - **산출물이 아키텍처 독립이면 `FROM --platform=$BUILDPLATFORM`** — 정적 자산 빌드가 여기다.
    `ukyi-app/page`의 web 스테이지(`tsc --noEmit && vite build` → `dist/index.html`)를 이렇게 고정하니
    호스트(arm64 네이티브)에서 한 번만 돌고 양쪽 leg가 그 결과를 복사한다. 통과했을 뿐 아니라
    **1m45s → 36초**로 빨라졌다(에뮬레이션 제거의 부수 효과). 선례: `ukyi-app/files`가 rust-lld
    크로스컴파일로 같은 회피를 한다.
  - **node_modules처럼 런타임 아키텍처에 묶이면 못 옮긴다 → 죽는 스크립트를 끈다.**
    trip-mate는 `bun install --frozen-lockfile --production --ignore-scripts`로 복구했다. 그 prod
    트리에서 설치 스크립트를 가진 패키지는 `@prisma/client`·`better-sqlite3`·`esbuild` 셋뿐이고
    **전부 better-auth의 optional peer로 딸려온 것이라 소스 참조가 0**이다 — 건너뛰어도 설치되는
    패키지 수는 그대로다(**134/134 실측**). ⚠️ 이 조건을 확인하지 않고 `--ignore-scripts`를 붙이면
    필요한 postinstall이 조용히 누락된다. 붙이기 전에 `--ignore-scripts` 유무로 트리를 실제로 비교하라.
  - 복구 결과: trip-mate release **6시간 타임아웃 → 56초**, page release **1m45s → 1m7s**.
- ⇒ **처방(블라스트 반경): `reusable-app-build`에 `timeout-minutes`를 건다.** 정상 빌드는 1~2분인데
  기본값은 platform max(6시간)라, 이번처럼 크래시-재시도 루프에 빠지면 러너를 6시간씩 잡고 그동안
  아무 신호도 주지 않는다. 상한을 걸면 같은 일이 재발해도 **분 단위로 red가 된다**(같은 이유로
  `contract-drift.yaml`이 이미 `timeout-minutes: 5`를 쓴다). 상한은 원인을 고치지 않는다 — 6시간을
  N분으로 바꿔 **드러나게** 할 뿐이다.
- ⇒ **같은 처방이 닿아야 할 두 번째 자리: `homelab-mutation` 직렬화 그룹**(2026-09-02). 이 그룹은
  `queue: max` + `cancel-in-progress: false`라 in-progress run이 끝날 때까지 나머지를 pending FIFO로
  붙든다 — 잡 하나가 네트워크에서 hang하면 owner 디스패치·DNS apply·이미지 bump·드리프트 수렴이
  **전부** platform max(6h)까지 선다. 실행기 쪽 하위 상한도 없다(`tools/lib/exec.ts`의 `timeoutMs: 0`가
  gh/docker/git 호출 전부에 걸린다). 유일한 런타임 신호인 GHAWorkflowStale은 예산이 21600s라 그 6h와
  사실상 같은 시각에야 울리고, platform-max 종료는 `cancelled`라 잡-레벨 `if: failure()` 알림도 침묵한다
  (라이브 실측: trip-mate-api run 32722287190이 6h0m46s 뒤 conclusion=cancelled).
  ⚠️ 디스패처의 route 잡(`uses: ./.github/workflows/_<self>.yaml`)에는 `timeout-minutes`를 둘 수 없다 —
  actionlint가 거부한다. 값은 그 reusable의 잡에 걸고, 가드도 `uses:`를 따라 내려가 검사해야 한다.
  값의 근거는 라이브 실측이다(최근 100 run 실행구간 max: bump-poll 352s · tf-reconcile 145s · iac 121s ·
  bump 337s) — 정상 소요가 분 단위라 15~30분 상한은 오탐 여지가 없고, 크론 멱등이라 거짓 타임아웃도
  다음 주기가 수렴시킨다.
- ⇒ **세 번째 자리: 직렬화 그룹 밖의 나머지 전 워크플로**(2026-09-03). 앞의 두 처방은 각각 한 파일과 한
  직렬화 그룹만 덮었다 — 남은 9 워크플로 13 잡(`ci` gate · `build` · `audit` · `dns-drift` ·
  `pr-sweeper` · `credential-expiry` · `renovate` 3잡 · `iac`의 PR 잡 3종 · `reusable-app-build`
  deploy-trigger)은 상한 없이 6시간에 노출돼 있었다. 그룹 밖이라 FIFO 교착 비용은 없지만 각자의
  비용이 있다: `gate`는 이 레포의 **유일한 required check**라 hang하면 PR 머지가(bump-poll·Renovate의
  auto-merge 포함) 통째로 서고, `build`는 그룹 안이 아닐 뿐 **같은 QEMU amd64 leg**를 탄다(원 사고와
  동형). ⇒ 전 워크플로의 전 잡(route 잡 제외)에 상한을 걸고, 가드의 분모를 `.github/workflows/*.yaml`
  전체로 넓힌다.
  ⚠️ **두 축을 섞지 마라.** `timeout-minutes`가 재는 것은 **잡 실행구간**(started_at→completed_at)이고
  `gh run list`의 createdAt→updatedAt은 **큐 대기를 포함**한다. `ci.yaml`에서 그 차이가 3배였다
  (2026-09-03 실측 최근 99 run: 잡 max 532s vs run max 1687s) — run 구간만 보고 값을 잡으면 과다
  산정되고, 잡 구간만 보고 아슬하게 잡으면 큐가 길 때 오탐으로 읽힌다. 두 값을 다 적고 큰 쪽을 넘겨 잡았다.
  ⚠️ **존재는 천장이 아니다** — `timeout-minutes: 360`은 platform 기본값과 같아 이름만 상한이다.
  가드는 값이 정수이고 360 미만인지까지 본다.
  ⚠️ **상한의 값어치를 알림에 걸지 마라.** 티켓 07이 남긴 미확인 축이 그대로다 — 잡-레벨 상한 초과의
  conclusion이 `cancelled`인지 `failure`인지, 그리고 그때 **같은 잡의** `if: always()` 알림 스텝이
  도달하는지를 라이브로 확인하지 못했다(라이브 실측이 있는 것은 platform max 종료가 `cancelled`라는
  것뿐이다 — trip-mate-api run 32722287190). 확실한 것은 run이 6시간이 아니라 분 단위에 끝난다는 것이고,
  그 위에 `GHAWorkflowStale`(r6)·GitHub의 스케줄 실패 통지·**별도 잡**의 회계 알림이 얹힌다. 후자
  (`iac`·`renovate`의 accounting)는 `if: !cancelled()`라 두 conclusion 어느 쪽이든 돈다 — 그래서
  이번에도 알림 조건은 한 곳도 바꾸지 않았다.
> 가드: `.github/workflows/reusable-app-build.yaml`, `tools/tests/test_mutation-dispatch.bats`
### 인용하지 않은 heredoc 안의 주석에 백틱을 쓰면 그 명령이 **실행되고** 주석이 잘려 나간다 — shellcheck는 그걸 "style"로 부른다
- **병(2026-08-27 실측)**: 가드가 awk 프로그램을 `read -r -d '' DETECT <<AWK`(인용하지 않은
  delimiter)로 조립한다 — 셸 변수를 본문에 끼워 넣어야 하기 때문이다. 그 안에 설명 주석을 달면서
  코드 조각을 백틱으로 감쌌더니(`` `scan_floor … quiet` ``), 그 백틱이 **명령 치환으로 실행**됐다.
  셰임으로 관측: `!!! scan_floor 가 호출됐다: … quiet`. 그리고 결과 문자열이 명령의 출력으로
  치환돼 **주석 본문이 조용히 잘렸다**("레인 Q: 는 판정만 한다").
- ⚠️ **shellcheck는 이것을 SC2006 "style"로 낸다** — "Use $(...) notation instead of legacy backticks".
  그 라벨만 보면 취향 문제로 읽고 넘기기 쉽다. 인용하지 않은 heredoc 안에서는 취향이 아니라
  **살아 있는 실행**이다. 다행히 이 레포는 전 추적 `*.sh`에 shellcheck를 required 게이트로 걸어
  두어 착지 전에 잡혔다.
- ⚠️ 실행되는 함수가 마침 그 가드의 커널 함수라 **부작용까지 갈 수 있었다**. 여기서는 인자가
  숫자가 아니라 조용히 실패했지만, 다른 조합이면 마커를 내거나 파일을 쓴다.
- ⇒ **처방: heredoc 본문의 주석에서는 코드를 백틱으로 감싸지 않는다.** 강조가 필요하면 따옴표나
  **볼드**를 쓴다. delimiter를 인용할 수 있으면(`<<'AWK'`) 그렇게 하되, 셸 변수를 끼워 넣어야 하는
  조립형에서는 그 선택지가 없다 — 그래서 규율이 주석 쪽에 있어야 한다.
- ⇒ 같은 파일의 기존 관용구가 이미 답을 갖고 있었다: 이 가드는 금지 패턴을 리터럴로 적지 않으려고
  `P_FLAG="${D2}min-[a-z]"`처럼 **조립**한다. 주석도 같은 규율을 따른다.

### `github.actor`는 재실행에서 보존된다 — 개시자는 `triggering_actor`이고, `actions:write`는 재실행 동사를 포함한다
- **정의(GitHub 문서)**: `github.actor`는 워크플로 run을 **최초로 트리거한** 사용자다.
  `github.triggering_actor`는 **이 run을 개시한** 사용자다. 재실행에서 둘은 갈리고,
  재실행은 `github.actor`의 권한으로 돈다. 즉 **`actor`는 재실행에서 보존된다.**
- **병(실측 2026-08-28)**: owner 경계 가드 15사본이 `[ "$ACTOR" = "$OWNER" ]` 하나만 봤고
  `github.triggering_actor`는 `.github/` 전체에서 **0건**이었다. 15사본 전건이
  `ACTOR=owner · TRIGGERING=타인` 케이스를 통과했다(실측 — 가드 본문을 그대로 실행해 확인).
- **라이브 실측 2026-08-28 (run 32814398310).** bot이 디스패치했던 run을 owner가 재실행하고 즉시
  취소한 뒤 run 객체를 읽었다:
  ```
  attempt=2  event=workflow_dispatch  actor=ukyi-homelab-dispatch[bot]  trig=ukkiee
  ```
  셋이 함께 확인된다 — `run_attempt`이 1→2로 **증가**하고, `event`가 **재생**되고,
  `actor`가 **최초 트리거 신원으로 보존**된 채 `triggering_actor`만 개시자로 바뀐다.
  관측 방향은 공격 방향의 역상이지만 성립하는 **규칙은 같다**: `actor` = 최초 트리거,
  `triggering_actor` = 재실행 개시자. 따라서 owner의 과거 디스패치를 다른 주체가 재실행하면
  `actor` 단독 비교는 통과한다.
- **왜 이것이 이 레포의 함정인가**: 트리거 경계가 "앱 레포는 dispatch만 할 수 있다"로 서술돼
  있는데, fine-grained **Actions: write**는 `gh workflow run`뿐 아니라 run 재실행
  (`POST /actions/runs/{id}/rerun`, `rerun-failed-jobs`, `jobs/{id}/rerun`)을 포함한다.
  그 자격은 실재한다 — `.github/workflows/reusable-app-build.yaml:159-167`이 앱 레포 키로
  `repositories: homelab` · `permission-actions: write` 토큰을 발급하고 `:173`에서 쓴다.
  히스토리에 그 신원(`ukyi-homelab-dispatch[bot]`)이 디스패치한 run이 15건 있다.
- **재실행은 이벤트도 재생한다.** 새 이벤트를 만들지 않고 원래 페이로드를 그대로 돌린다. 그래서
  두 가지가 함께 따라온다:
  1. `if: github.event_name == 'workflow_dispatch'`로 한정한 가드는 **스케줄 run의 재실행에서 skip**된다.
     skip은 실패가 아니므로 뒤 스텝은 그대로 돈다.
  2. `workflow_dispatch`가 없는 워크플로도 **재실행으로 도달 가능**하다 — 트리거 목록만 보고
     "이건 디스패치가 없으니 대상 밖"이라고 읽는 정적 분류는 그 자리에서 무너진다
     (실측: `iac.yaml`의 `terraform apply` 잡 4개와 `bump.yaml`의 `git push`+`gh pr create` 잡이
     그 방식으로 분류 우주 밖에 있었다).
- ⇒ **처방 ①: 가드 스텝에 `if:`를 두지 않는다.** 트리거로 한정하면 그 트리거가 아닌 run의
  재실행에서 **스텝 자체가 skip**되어 아래 처방 ②가 애초에 닿지 못한다. 트리거 판정은 본문이
  한다(`[ "$EVENT" = "workflow_dispatch" ] || exit 0`) — 의미론은 같고 스텝은 모든 이벤트에서 돈다.
  실측 2026-08-28: 이 형태 때문에 특권 잡 셋(`build.yaml#build` push · `pr-sweeper.yaml#sweep`
  schedule · `tf-reconcile.yaml#reconcile` schedule)이 재실행에 노출돼 있었다.
- ⇒ **처방 ②: 두 신원을 모두 요구한다.** `TRIGGERING: ${ github.triggering_actor }`를 바인딩하고
  `[ "$TRIGGERING" = "$OWNER" ]`를 `[ "$ACTOR" = "$OWNER" ]`와 **함께** 건다. 하나로 대체하지 않는다 —
  둘 다 요구하는 것이 어떤 경우에도 더 약해지지 않는다.
  ⚠️ **env 바인딩과 술어는 같은 수여야 한다.** 술어만 넣고 바인딩을 빠뜨리면 빈 문자열 비교가 되어
  **전 디스패치가 잠긴다**(가용성 사고). 증인이 두 수의 등식을 진다.
- ⇒ **처방 ③: 이벤트 구동 특권 잡에는 재실행 전용 가드를 첫 스텝으로 둔다.** actor 축은 그
  잡들에 모양이 맞지 않는다(출처는 잡 `if:`와 branch protection이 진다). 남는 축은 재실행뿐이고,
  그 축은 `[ "$ATTEMPT" = "1" ] || [ "$TRIGGERING" = "$OWNER" ]` 한 줄이다 — **이벤트를 보지 않으므로
  열거할 것이 없다.**
- ⚠️ **트리거 열거는 안전 판정이 될 수 없다.** 재실행이 트리거를 우회하므로, 워크플로를
  `on:` 키로 선별해 "밖은 안전"으로 읽으면 그것 자체가 「열거 붕괴 → vacuous green」의 한 사례다.
> 가드: `tools/tests/test_mutation-dispatch.bats`, `.github/workflows/create-app.yaml`
### 프로브는 호출이 아니다 — `command -v X`와 미평가 라벨이 X의 증인 노릇을 해서 mirrored 선언이 자기 자신을 증명한다
- **병(라이브 실측)**: `check-ci-parity`의 방향 ④는 "mirrored로 선언한 로컬 커맨드가 `make -n ci`
  출력에 있어야 한다"였고, 구현은 `makeOut.includes(local)` 한 줄이었다. 그런데 `make -n` 출력에는
  **호출이 아닌 텍스트**가 섞여 있다:
  ```make
  @if command -v actionlint >/dev/null 2>&1; then actionlint; \
    else echo "actionlint(워크플로 정적 검사)" >> $(CI_UNEVAL); fi
  ```
  한 줄에 `actionlint`가 **세 번** 나오는데 그중 실제 호출은 하나다. 나머지 둘은 **전제 프로브**
  (도구의 존재를 묻는다)와 **미평가 라벨**(부르지 *못했다*는 기록이다)이다.
  ⇒ `then actionlint;`를 `then :;`로 바꿔 실제 호출만 지워도 게이트는 **초록**이었다.
- **왜 이 클래스가 재발하는가**: 이 레포는 `make -n` 출력을 **데이터로 읽는다**(패리티 대조 ·
  check-guard-authority의 venue 수집). Makefile 텍스트를 파싱하지 않고 make 자신에게 해소를 맡기는
  것은 옳은 결정이지만(조건부·변수·전제 타깃의 재구현이 곧 다음 드리프트다), 그 대가로 출력에
  **실행되지 않을 분기까지 전부** 들어온다. `-n`은 "무엇이 실행될 것인가"가 아니라 "셸에 무엇이
  넘어갈 것인가"를 보여 준다 — 그 둘의 차이가 이 함정이다.
- ⇒ **처방: 대조 전에 호출이 아닌 형태를 지운다.** `command -v \S+`와 append-echo
  (`echo "…" >> <파일>`) 둘뿐이다. recipe의 append-echo는 구조상 게이트 호출일 수 없다.
  ⚠️ **변수명에 기대지 마라** — `$(CI_UNEVAL)`이 리네임되면 정제가 조용히 멎고 fail-open이 돌아온다.
  형태로 지운다.
  ⚠️ **정제본을 모든 검사에 쓰지 마라.** `--floor` 금지 검사는 원문을 봐야 한다: 프로브 안이든
  라벨 안이든 `--floor`가 보이면 위반이다. 정제는 ④ 하나의 국소 처방이다.
- **오탐 검증이 처방의 절반이다**: 정제가 정상 원장을 물면 아무도 안 켠다. 실측 2026-08-28로
  mirrored 22항목 · local 34문자열 전건이 정제 후에도 매치했다(사라진 것 0건). 이 수치를 재지
  않고 정제를 넣는 것은 다른 fail-open을 만드는 일이다.
> 가드: `tools/check-ci-parity.ts`, `tests/gates/test_make-ci-parity.bats`

### actor 가드는 대소문자를 구별한다 — GitHub login은 구별하지 않는데, 그 어긋남을 밟는 테스트가 0건이다
- **병**: 변이 디스패처의 actor 가드 15사본이 전부 `[ "$ACTOR" = "$OWNER" ]`, 즉 **정확 일치**로 비교한다.
  두 피연산자의 출처가 다르다 — `github.actor`는 GitHub이 정규 표기로 내려주고, `vars.HOMELAB_OWNER`는
  사람이 org 변수에 손으로 입력한다. GitHub의 login 매칭 자체는 대소문자를 구별하지 않으므로, 변수에
  한 글자만 다르게 적혀도 GitHub 쪽에서는 아무 신호가 없고 **모든 변이가 fail-closed로 잠긴다**.
- ⚠️ **오늘 이 축을 밟는 테스트가 0건이다.** `tools/tests/test_mutation-dispatch.bats`는 술어의 *텍스트 존재*만
  보므로 비교 의미론에 증인이 없다(같은 이유로 `=`를 `!=`로 뒤집는 뮤테이션이 GREEN이었다 — 별도 함정).
  즉 이 결함은 **라이브에서만 드러나고**, 드러나는 방식이 "owner가 자기 홈랩 변이에서 잠긴다"는 형태다.
- ⇒ **처방(의도적 무변경)**: 거동을 넓히지 않는다. 대소문자 무시로 바꾸면 우회 표면이 1비트 커지고
  셸 렌더가 정규화만큼 길어지며 라이브 워크플로 15사본을 전부 편집해야 한다. 대신 **진단이 이 경우를
  가리키게** 둔다 — `homelab doctor`의 gh-owner 체크가 실제 login과 `vars.HOMELAB_OWNER`를 대조하는
  자리다. 변수를 새로 설정하거나 회전할 때 그 체크를 먼저 돌린다.
- ⇒ 반대 선택(대소문자 무시)을 언젠가 고르면, 그 커밋은 **15사본 전부**를 함께 바꿔야 한다. 한 사본만
  넓히면 같은 org 변수에 대해 워크플로마다 판정이 갈린다.

### `grep -q`의 조기 종료가 pipefail 아래에서 writer를 SIGPIPE로 죽인다 — 매치가 있었는데 141이 거짓 FAIL이 된다
- 2026-08-31 PR #564의 CI에서 `tests/gates/test_traps-sync.bats`의 `reverse guard-path-tie`가 red였다가
  **같은 커밋 재실행으로 green**이 됐다. 결정적 단서는 같은 실패 로그 안에 있었다 — 동일한
  같은 가드를 인자 없이 부르는 `tests/gates/test_verify-traps.bats`의 레인은 **통과**했다.
- 기전: `printf '%s\n' "$list" | grep -Fqx -- "$x"`에서 `grep -q`는 **첫 매치에서 즉시 종료**한다. 그때
  writer(bash `printf` 빌트인)가 아직 쓸 것이 남아 있으면 SIGPIPE로 죽고, `set -o pipefail`이 그
  **141(=128+13)**을 파이프라인 rc로 채택한다. ⇒ **매치가 있었는데 FAIL**이다. 판정이 뒤집히는 것이
  아니라 판정 자체가 종료코드에 삼켜진다.
- ⚠️ **부하 의존이라 로컬이 CI를 예고하지 못한다.** writer가 몇 번 write()를 끝냈는지는 스케줄링에
  달려 있다. 실측(2026-08-31, 14코어): CPU 부하 아래 `verify-traps.sh` **30회 중 22회 red** ·
  무부하 **20회 전건 green**. CI가 이 창을 만든다 — `.github/workflows/ci.yaml`의 "무거운 스위트 동시
  실행" 스텝이 `run-bats.sh`와 발화 e2e 8건을 **한 스텝에서 병렬로** 띄운다(PR #564가 그 목록을 7→8로
  늘렸다). 깨끗한 worktree·전체 스위트·CI 로케일 어디서도 재현되지 않은 이유가 이것이다.
- ⭐ **최소 재현**(부하 불요): 줄 수를 키우고 매치를 맨 앞에 두면 결정적으로 관측된다 —
  `BIG=$(seq 1 10000); bash -c 'set -euo pipefail; printf "%s\n" "$1" | grep -Fqx -- "1"' _ "$BIG"`가
  **rc=141**을 낸다(3회 중 1회). 같은 입력에 `grep -Fqx -- "1" <<<"$BIG"`는 전건 rc=0.
- ⇒ 처방: **herestring**(`grep -Fqx -- "$x" <<<"$list"`). bash가 임시 파일을 seek 가능한 fd로 붙이므로
  파이프 자체가 없고 이 레이스가 **원리적으로** 사라진다. `|| true`나 재시도는 처방이 아니다 —
  SIGPIPE가 만든 거짓 FAIL과 진짜 SSOT 드리프트 FAIL이 **같은 문장을 내므로** 재시도는 판별 장치가
  아니라 은폐다(형제 항목 「체이닝 레이스의 두 번째 얼굴」이 재시도의 정당성 조건으로 "레이스 서명이
  결함과 구별될 것"을 세워 뒀는데, 여기선 그 조건이 성립하지 않는다).
- ⚠️ **도메인 경계**: bats는 `pipefail`을 켜지 않는다. 그래서 `.bats` 안의 같은 관용구는 141이 나도
  파이프라인 rc가 grep 쪽(0)이라 안전하다 — 이 함정은 **`set -o pipefail`을 켠 `.sh`에만** 적용된다.
- ⚠️ 단일 값(`printf '%s' "$one"` — 줄바꿈 없음)은 write가 1회라 사실상 안전하다. 위험한 것은
  **여러 줄 리스트를 멤버십 검사에 파이프하는 형태**다.
- ⇒ **부채는 닫혔다**(#574). 형제 **18곳**(host-preflight 2 · verify-cluster 7 · audit-orphan-pv 1 ·
  check-gh-secret-coverage 6 · verify-credential-inventory 2 — #565의 열거는 `echo "$var"` writer를
  빠뜨려 11곳으로 셌다)이 herestring으로 전환됐고, 전수 정적 가드 `scripts/check-sigpipe-writers.sh`
  (pipefail 파일 × 다중행 printf/echo writer, 주석 줄은 사후 제외)가 `make verify`·ci gate에서 강제한다.
  ⚠️ 이 문단은 #574가 갱신하지 않아 **닫힌 부채를 열린 것으로** 서술하고 있었다(SSOT가 코드와 다른
  사실을 말하는 이 레포의 반복 클래스). verify-traps는 `> 가드:` 줄과 헤드라인만 대조하므로 본문
  산문의 이 드리프트를 **원리적으로 못 본다** — 산문도 SSOT의 일부라는 것이 이 자리의 교훈이다.
- ⚠️ **가드 도메인 밖**: 판정 범위는 `printf '%s\n' "$var"`·`echo "$var"` 같은 **셸 빌트인 writer**다.
  외부 명령 writer(`sops -d …`·`kubectl get -o yaml …` → `grep -q`)는 같은 기전을 갖지만 가드가 보지
  않는다(헤더 ②의 축소 근거 — 패턴을 넓히면 오탐이 도메인을 삼킨다). 그 자리는 **소비-완료 형태**
  (`grep -c`/`grep -l`, 또는 herestring)를 손으로 지킨다. 실측 사례: `scripts/backup-sealed-secrets-key.sh`의
  복호 검증은 sops(Go)가 stdout에 단일 write를 하는데, 출력이 커지면(합성 페이로드 실측: ≈90KB부터
  10~20% 확률, ≈139KB=12키부터 결정적) `grep -q`의 조기 종료가 그 write를 EPIPE로 만들어 백업 생성이
  **141로 죽고 EXIT trap이 tmp를 지운다**. sealing key 회전 핀(`keyrenewperiod "0"`)이 풀리면 30일마다
  키가 하나씩 늘어 시한부로 도달하는 경로라 `grep -c`로 전환했다.
> 가드: `scripts/check-sigpipe-writers.sh`, `tests/gates/test_sigpipe-writers.bats`
### 서브쿼리 step이 스크레이프 간격보다 크면 peak가 조용히 과소평가된다 — 그 위에서 깎은 limit이 회귀가 된다
- 2026-09-01, 메모리 원장의 마진 규약(`limit ≥ A′ peak × 2.0`)이 A′를 `[14d:5m]` 서브쿼리로 쟀다.
  cadvisor 스크레이프는 **30초**다(`platform/victoria-stack/prod/vmagent-scrape-config.yaml`, job
  override 없음). 서브쿼리는 5분 격자의 각 점에서 lookbehind의 **마지막 값 하나**만 취하므로
  **샘플 10개 중 9개를 버린다**.
- ⚠️ 이 손실은 균등하지 않다. **peak는 정의상 격자에 걸릴 확률이 낮은 점**이라, 버려지는 90%에
  peak가 들어갈 공산이 크다. 짧은 버스트를 가진 워크로드일수록 과소평가가 커진다 —
  같은 14일 창을 5m와 30s로 재 비교한 실측:

  | 컨테이너 | `[14d:5m]` | `[14d:30s]` | 과소평가 |
  |---|---|---|---|
  | `argocd/repo-server` | 70.2Mi | **112.5Mi** | **+60.3%** |
  | `edge/adguard` | 79.0Mi | **124.4Mi** | **+57.5%** |
  | `database/plugin-barman-cloud` | 107.5Mi | **152.5Mi** | +41.9% |
  | `argocd/application-controller` | 461.5Mi | **488.2Mi** | +5.8% |

  repo-server의 렌더 버스트와 adguard의 블록리스트 갱신은 **5분 격자에 한 점도 걸리지 않았다** —
  adguard의 124.4Mi는 8/31 06:51Z의 한 시간짜리 스파이크인데, 5분 해상도로 그 시간대를 보면
  78.6 → 73.5Mi로 평온하다. **없는 것처럼 보인다.**
- ⇒ 결과: 그 과소평가 위에서 같은 날 회수한 limit 둘이 **곧바로 회귀**였다 — adguard 192→160(실제 1.29x) ·
  repo-server 384→144(실제 1.28x). 둘 다 "2.0x 규약을 만족한다"는 근거 주석을 달고 머지됐다.
  전수로 재면 **12개 컨테이너가 2.0x 미달**이었고 6개가 1.5x 미만이었다.
- ⭐ **처방: 서브쿼리 step ≤ 스크레이프 간격.** 현행은 `[14d:30s]`다. `15s`로 더 낮춰도 결과가
  동일함을 확인했다 — 즉 30s가 전 샘플을 포착하며, 그 아래는 계산량만 늘린다.
- ⚠️ **탐지의 비대칭**: 이 결함은 red를 내지 않는다. 쿼리는 성공하고, 값은 그럴듯하고, 게이트는
  초록이다. 「열거 붕괴 → vacuous green」의 시계열판이다 — 표본이 조용히 잘려도 통계는 답을 낸다.
- ⚠️ **자기조절 워크로드에는 배수 규약 자체가 정의되지 않는다**(같은 조사에서 드러난 형제 결함).
  `--memory.allowedPercent`(VictoriaMetrics 계열)나 `GOMEMLIMIT`을 쓰는 워크로드는 limit에 비례해
  캐시·힙을 늘리므로, limit을 올리면 peak도 따라 올라 `peak × 2.0`이 **자기참조**가 된다.
  vmagent·vmsingle·grafana·glances·victorialogs 5개가 이 클래스다 — 원장이 보류 행으로 계상한다.
> 가드: `tests/gates/test_verify-ledger-ssot.bats`, `docs/memory-ledger.md`
### 네이티브 사이드카의 limit은 KSM이 `init_container` 계열로 내보낸다 — 캡을 씌워도 near-limit 알림은 무성이다
- 2026-09-01. CNPG의 `Cluster.spec.plugins[]`가 주입하는 `plugin-barman-cloud`는 일반 컨테이너가 아니라
  **네이티브 사이드카**(`restartPolicy: Always`인 initContainer)다. 그래서 kube-state-metrics는 그
  컨테이너의 자원 선언을 `kube_pod_container_resource_limits`가 아니라
  **`kube_pod_init_container_resource_limits`** 로 내보낸다.
- `ContainerMemoryNearLimit`의 분모는 앞쪽 계열뿐이었다(`rules/core.yaml:85`). 라이브 확인(pg-1):
  container 계열에는 `postgres`만, init 계열에는 `bootstrap-controller`만 있다.
- ⇒ **캡을 씌우는 것이 상태를 악화시킬 수 있다.** limit이 없던 동안 그 컨테이너는 "무캡·무알림"이었다.
  캡만 주고 분모를 안 고치면 **"캡·무알림·조용한 OOMKill"** 이 된다 — cgroup이 프로세스를 죽이는데
  아무도 페이징되지 않는 상태가 새로 생긴다. 무캡보다 나쁠 수 있다.
- ⭐ 처방: 분모를 두 계열의 `or`로 넓힌다. `or`는 좌변에 없는 시리즈만 우변에서 채우므로 양쪽에 다 있는
  컨테이너는 container 계열이 이기고, 일반 컨테이너의 판정은 바뀌지 않는다.
- ⚠️ 같은 클래스가 더 있다: `restartPolicy: Always`인 initContainer를 쓰는 워크로드는 전부 이 경계에
  걸린다. 자원 캡을 새로 씌울 때는 **그 limit이 어느 메트릭 계열로 나가는지 먼저 확인**할 것.
- ⚠️ **pod 합산 표면은 per-container `or`로 못 푼다 — 실행 중 시리즈 결박이 필요하다**(2026-09-02,
  형제 표면인 Grafana "vs limit" 패널에서 드러남). 룰이 `or`만으로 무사한 이유는 usage 시리즈가 없는
  **종료된** init 컨테이너가 per-container 나눗셈 매칭에서 자연 탈락하기 때문이다. `sum by (namespace,pod)`로
  합산하는 표면에는 그 성질이 없어 종료 init의 limit(pg-1 `bootstrap-controller` 1Gi, argocd `copyutil`
  240Mi)까지 분모에 실린다 — 라이브 pg-1이 1344Mi가 아니라 2368Mi가 되어 **고치기 전(8.9%)보다 더 틀린
  4.0%** 가 된다. 처방은 `and on (namespace,pod,container) container_memory_usage_bytes{container!=""}`로
  cAdvisor의 실행 중 시리즈에 결박한 뒤 합산하는 것이다(교정 후 7.1%).
> 가드: `platform/victoria-stack/prod/rules/core.yaml`, `tools/check-resource-limits.ts`, `tests/gates/test_grafana-dashboards.bats`, `tests/gates/test_vmalert-config.bats`
### `Container.args`는 patchMergeKey 없는 atomic 리스트다 — strategic-merge patch가 통째로 교체한다
- 2026-09-01, 벤더 매니페스트에 kustomize patch로 자원 캡만 얹으면서 "이왕이면 로컬 편집한
  `--log-level=info`도 patch로 옮기자"는 부록이 제안됐다. 실행했으면 컨트롤러가 죽는다.
- core/v1의 `Container.args`는 `[]string`이고 `patchMergeKey`가 없다. strategic-merge는 병합 키가 없는
  리스트를 **atomic으로 취급해 통째로 교체**한다. 실측(kustomize v5.8.1): args만 담은 patch를 적용하니
  렌더된 Deployment의 args가 `--log-level=info` **한 줄만** 남고 `operator` 서브커맨드와
  `--server-cert`/`--server-key`/`--client-cert`/`--server-address`/`--leader-elect`가 전부 사라졌다.
  서브커맨드와 TLS 경로가 없으면 그 Deployment는 기동조차 못 한다.
- ⚠️ **resources 단언은 이 사고를 원리적으로 못 잡는다.** 같은 patch에서 `resources`는 map이라 정상
  병합되고, args만 조용히 잘린다. "캡이 들어갔는지"만 보는 증인은 전건 초록을 낸다 — 실제로 뮤테이션에서
  5개 @test 중 args 레그 하나만 red였다. 벤더 오버레이의 증인에는 **건드리지 않은 필드가 살아남았다**는
  단언이 함께 있어야 한다.
- ⇒ args를 정말 고쳐야 한다면 JSON6902 `replace`로 인덱스를 지정한다 — 다만 re-vendor 때 인덱스가
  어긋나므로 그 자체가 별개 부채다. 형제 항목: 「SSA atomic 리스트 영구 OutOfSync」(같은 원인, 다른 층).
> 가드: `platform/cnpg/barman-plugin/test_kustomize_cap.bats`
### 파일 프리필터를 함께 넓히지 않으면 kind 추가가 vacuous green으로 착지한다
- 2026-09-01. `tools/check-resource-limits.ts`에 `ObjectStore`를 가르치려고 `KINDS` 집합에만 더했다.
  그런데 그 파일은 `KINDS` 조회 **전에** `if (!KIND_RE.test(text)) continue`로 파일을 거른다(:91).
  `KIND_RE`는 별도 정규식이라 ObjectStore가 없었고, `object-store.yaml`은 열리지도 않았다.
- 증상이 없다는 것이 이 함정의 전부다: 게이트는 초록이고, 위반은 0이고, 스캔 카운트만 조용히
  그대로다(21 → 20). **스캔 수를 보지 않으면 "검사했다"와 구별되지 않는다.**
- ⇒ 처방은 둘을 같은 자리에 두고 주석으로 묶는 것이다. 그리고 새 kind를 가르칠 때는 뮤테이션 둘을
  함께 돌린다 — (a) 대상 필드를 지우면 red인가, (b) 프리필터만 되돌리면 스캔 카운트가 줄어드는가.
  (b)가 없으면 (a)의 red는 다음 리팩터에서 무증인이 된다.
- 형제: 「열거 붕괴 → vacuous green」(같은 클래스의 원형) · 「스캔 신호를 콜사이트가 손으로 내면
  순서가 드리프트한다」(scan_floor가 이 카운트를 지키는 이유).
> 가드: `tools/check-resource-limits.ts`
### A′는 회수 가능한 커널 slab을 분자에 싣는다 — 그 비중이 워크로드마다 100배 갈리고 peak 시점 값은 소급 측정이 불가능하다
- 2026-09-01. 메모리 원장의 A′(`usage − inactive_file − active_file`)는 회수 가능한 **파일 캐시**는
  빼지만 회수 가능한 **커널 slab**(`slab_reclaimable`)은 그대로 남긴다. cgroup `memory.stat` 직독
  결과 그 비중이 관측 스택 다섯에서 이렇게 갈렸다:
  vmagent **0.2%** · vmsingle 3.8% · glances 9.1% · grafana 20.2% · victorialogs **27.1%**.
- ⇒ **같은 배수가 서로 다른 안전을 뜻한다.** vmagent의 A′는 사실상 순수 anon이라 1.05x가 그대로
  1.05x지만, victorialogs의 A′는 27%가 커널이 언제든 내놓는 캐시라 실질은 2.09x다. 배수만 보면
  두 행이 같은 위험군으로 보인다.
- ⚠️ **"그럼 slab을 빼자"는 처방은 규약이 될 수 없다.** cadvisor가 cgroup v2 + containerd에서
  커널/slab 계열을 **채우지 않기** 때문이다 — `container_memory_kernel_usage`는 시리즈가 존재하는데
  다섯 컨테이너 모두 `max_over_time([14d:30s]) = 0`이다. 즉 slab-차감 A′는 라이브 `kubectl exec`
  스냅샷으로만 얻을 수 있고 **시계열이 없다.** peak 시점의 비중은 원리적으로 소급 불가다.
- ⭐ 처방(관측 스택 한정): 분자를 `container_memory_rss`(= anon)로 바꾼다. 단 **`shmem == 0`을
  `memory.stat` 직독으로 확인한 경우에만** — cgroup v2의 anon은 shmem을 제외하므로, shmem을 쓰는
  워크로드(cnpg의 `shared_buffers`)에서는 이것이 #564가 배제한 무성 지대를 되살린다.
  스왑이 0이면 anon은 전량 회수 불가라 OOM의 직접 원인과 정확히 일치한다.
- ⚠️ **배수 순서 · 압력 순서 · slab 비중 순서가 서로 다른 세 순서다.** PSI 누적으로 재면
  grafana 129,815µs ≫ glances 1,956 > vlogs 288 > vmsingle 72 > **vmagent 0**인데, 배수 최악은
  vmagent다. 압력이 가장 심한 grafana가 회수 불가/limit로는 뒤에서 두 번째로 여유롭다(61.2%).
  ⇒ 배수는 대리 지표이며, 그것 하나로 위험을 정렬하면 순서가 뒤집힌다.
> 가드: `docs/memory-ledger.md`, `tools/check-resource-limits.ts`
### 자기조절 워크로드의 자기참조는 두 경로로 산다 — GOMEMLIMIT(힙)과 allowedPercent(캐시), 하나만 끊으면 되살아난다
- 2026-09-01. 이 레포는 「대형 Go 컨트롤러는 `GOMEMLIMIT`을 limit의 90%로 연동한다」를 규약으로
  둔다(argocd 컨트롤러들이 그렇게 산다). 그런데 **관측 스택처럼 limit을 예산으로 소비하도록 설계된
  워크로드**에 그대로 적용하면, limit 상향이 곧 힙 예산 상향이 되어 peak가 따라 오른다.
  ⇒ `limit ≥ peak × K`가 영원히 자기 꼬리를 쫓는다 — 올릴 때마다 다시 미달이 된다.
- ⭐ 처방: 이 클래스에서는 **`GOMEMLIMIT`을 고정한다.** limit을 올리는 목적은 힙을 키우는 것이 아니라
  **비-힙 여유**(캐시 mmap·커널 slab·페이지 테이블)를 주는 것이기 때문이다. 실측이 그 구분을 지지한다:
  vmsingle의 anon 629.9Mi 중 힙이 `heap_inuse` 491.7Mi이고, 캐시는 예산 537.6Mi의 33.8%만 쓴다 —
  발열은 캐시가 아니라 힙인데, 그 힙은 `GOMEMLIMIT` 800MiB의 73.4%에서 멈춰 있다.
- ⚠️ **그런데 GOMEMLIMIT 고정만으로는 절반이다.** VictoriaMetrics의 `--memory.allowedPercent`도
  limit에 비례하므로, limit을 올리면 캐시 예산이 따라 커진다(vmsingle 896→1056Mi에서 537.6→633.6Mi).
  그리고 **`GOMEMLIMIT`은 그것을 막지 못한다** — fastcache는 mmap 할당이라 Go 힙 밖에 살기 때문이다
  (원장 victorialogs 항목의 실측: "GOMEMLIMIT은 힙 소프트 리밋이라 이것을 못 막는다 — 115MiB가
  걸린 채 죽었다"). ⇒ `--memory.allowedBytes`로 **절대값을 못박아** 두 번째 경로도 끊는다.
  플래그 존재는 `flag{name="memory.allowedBytes"}` 메트릭으로 확인할 수 있다.
- ⚠️ 두 경로를 끊어도 **산술적으로는 여전히 초과 가능**하다(힙 상한 + 캐시 예산 > limit). 실측상
  동시 최대가 관측된 적이 없어 의도적으로 허용한 오버서브스크립션이며, 그 사실을 원장에 계상한다.
  두 상한의 합을 limit 아래로 누르려면 캐시를 크게 깎아야 하고 그것은 질의 지연으로 전가된다.
- ⚠️ 연동을 끊어도 `tools/check-resource-limits.ts`의 `GOMEMLIMIT ≤ limit × 0.95`는 그대로 통과한다
  (한쪽 방향 상한만 보기 때문). 즉 **게이트는 이 결정을 강제하지도 막지도 않는다** — 근거는 주석과
  원장에만 산다. 다음 사람이 "90% 연동 규약을 안 지켰다"고 되돌리지 않도록 두 곳 모두에 적었다.
> 가드: `platform/victoria-stack/prod/vmsingle.yaml`, `docs/memory-ledger.md`
### 측정 창이 기판 변경을 가로지르면 두 체제가 한 숫자에 섞인다
- 2026-09-01. `node_boot_time_seconds = 2026-08-26T13:41:06Z`. 그 재부팅에서 관측 스택 다섯 전부
  계단이 있었다 — vmagent A′ 일별 peak 200~213 → 159~171 · vmsingle rss 552 → 350 ·
  victorialogs A′ 168 → 111~134. 14일 창은 그 경계를 가로지른다.
- ⇒ 원장이 「vmagent 1.05x」로 적었던 값이 정확히 그 산물이다. 그 peak(213.1Mi)는 **재부팅 전 세대**의
  것이고 현 기판에서는 1.33x다. 즉 **이미 존재하지 않는 체제의 숫자로 현재를 판정**하고 있었다.
- ⚠️ 방향도 일정하지 않다 — glances는 같은 재부팅에서 81 → 86Mi로 **올랐다**. "재부팅하면 내려간다"는
  경험칙으로 뭉개면 안 되고, 창을 자르는 것 말고는 답이 없다.
- ⭐ 처방: 기판이 바뀌면(노드 재부팅·커널·컨테이너 런타임 메이저) 측정 창을 **그 이후로 자른다.**
  창이 짧아 표본이 부족하면 그 사실을 적을 것 — 섞인 숫자보다 짧은 창이 낫다.
> 가드: `docs/memory-ledger.md`
### sed 주소 범위는 시작 줄에서 끝나지 않는다 — 한 줄짜리 `{{- /* … */ -}}` 주석이 그 뒤를 통째로 지운다
- **병(2026-09-03 실측)**: `sed '/{{- *\/\*/,/\*\/ *-}}/d'`처럼 여는·닫는 주소로 블록을 벗기는 관용구는
  시작 주소가 매치된 **그 줄에서 범위를 열고 종료 주소는 다음 줄부터** 찾는다. 그래서 한 줄에 여는
  표기와 닫는 표기가 함께 있는 주석(`{{- /* … */ -}}`)은 자기 줄에서 닫히지 못하고 **다음 종료
  매치(없으면 EOF)까지** 지운다. 구현 차이가 아니라 범위 주소의 정의다.
- ⚠️ **가설이 아니라 이미 현행이었다.** `platform/victoria-stack/prod/alertmanager.yaml`의 telegram
  message(3739B)에는 한 줄 주석이 **2건** 있어 서로 짝지어졌고, 1단 sed 결과(3115B)에서는 그 사이의
  **실코드 한 줄**(`{{- if and (eq $title $name) .CommonAnnotations.summary }}…`)이 사라져 있었다.
  짝수 개의 한 줄 주석은 조용히 "그 사이를 지우는 범위"가 된다.
- ⚠️ **부재 단언 위에 얹히면 fail-open이다.** 벗겨낸 텍스트에 「금지 토큰이 없다」를 묻는 가드는 붕괴
  후 **빈 것에 대한 참**이 된다. 실측(message에 한 줄 주석 + 그 뒤 `reReplaceAll`을 삽입 · 1단 sed):
  `range .Alerts` **앞**에 넣으면 2871B에 위반 0건, message **끝**에 넣으면 3115B에 위반 0건 —
  둘 다 「수동 escape 금지」 레인이 12/12 green이었다. 「열거 붕괴 → vacuous green」의 부재-단언 판이다.
- ⚠️ **크기 하한은 판별력이 없다.** 붕괴 폭이 주석의 **위치**에 달려 있다 — 같은 뮤테이션(3819B)에서
  1단 잔존이 head 3410B(89%) · mid 2871B(75%) · tail 3115B(81%)였다. `[ "${#stripped}" -ge 1000 ]`
  류의 바닥값은 셋을 전부 통과시킨다. **크기는 붕괴의 척도가 아니다.**
- ⚠️ **앵커 양성 대조 단독으로도 안 닫힌다.** 위 셋 중 앵커(`range .Alerts`)가 사라지는 것은 mid
  하나뿐이고, tail 배치는 앵커가 그대로 남아 **부재 단언도 앵커도 조용하다**(실측). 앵커는 보조
  증인이지 이 함정의 하중이 아니다.
- ⇒ **처방 ①(하중): 한 줄 형태를 먼저 지워 범위가 열리지 않게 한다(2단 strip).**
  `sed 's|{{- *//*\*.*\*/ *-}}||g' | sed '/{{- *\/\*/,/\*\/ *-}}/d'` — 1단이 한 줄 주석을 그 자리에서
  없애고 2단이 진짜 다중행 블록만 벗긴다. 실측: 위 세 배치 전건에서 위반 1건 이상 → red
  (tail 3283B·1건). 순서를 뒤집으면 1단이 할 일이 남지 않는다.
- ⇒ **처방 ②(보조): strip 결과에 앵커 양성 대조를 건다.** 미종결 `{{- /*` 하나처럼 **다른** 이유로
  과도해진 strip은 크기로는 안 보이고 앵커 부재로만 보인다. 부재 단언 앞에 "벗기고도 본문이 남아
  있다"를 한 줄로 증언시켜라.
- ⇒ **일반형**: 한 줄에 여는·닫는 표기가 함께 올 수 있는 문법(Go template `{{- /* */ -}}` · C `/* */` ·
  HTML `<!-- -->`)을 범위 주소로 벗기는 자리는 전부 같은 함정을 갖는다. 형제는
  「heredoc 상태 기계가 주석 규칙보다 먼저 돌면 …」 — 열림이 닫힘을 못 만나 파일의 나머지를 삼키는
  같은 계열이고, 처방도 같다(열림 판정 **앞**에서 한 줄 형태를 소거 + 대조를 함께 둔다).
> 가드: `tests/gates/test_alertmanager-template.bats`
