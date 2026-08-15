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
> 가드: `platform/adguard/prod/test_adguard_route.bats`, `platform/cnpg/prod/test_cluster_params.bats`

### 상주 워크로드 OOM 진단 — 코어 수는 그럴듯한 오답이다 (D-e)
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
  ⚠️ `host-config.sh`의 트리 열거는 `find . -type f -name '*.conf'`다. udev 룰(`.rules`)이나
  grub 조각(`.cfg`)으로 두면 **조용히 무시된다**(레포의 "열거 붕괴 → vacuous green" 클래스).
  그래서 `.conf`로 표현 가능한 tmpfiles를 골랐다. 트리에 파일을 더하면 `TREE_MIN`도 같이 올릴 것.
> 가드: `infra/k3s-bootstrap/tests/test_03-host-config.bats`

### hostPath 백엔드 PV에는 fsGroup이 적용되지 않는다
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

### yq -e는 값이 false면 exit 1이다
- `yq -e`의 종료코드는 "출력이 truthy인가"다 — **키가 없을 때(`null`)와 값이 `false`일 때를 구별하지
  않는다.** 그래서 올바른 매니페스트(`isWALArchiver: false`)에서 bats가 red가 된다.
  `-e` 없이 읽고 `printf '%s' "$v" | grep -qxF -- 'false'`로 정확 일치를 단언하면 미기재(`null`)와
  `false`가 갈린다. 불리언을 읽는 모든 단언에 해당한다.
> 가드: `platform/cnpg/prod/test_cluster_params.bats`

### Application zero-value selfHeal 플립플롭
- Application spec의 zero-value(예: `directory.recurse: false`)는 컨트롤러 정규화가 매번 삭제 →
  selfHeal과 플립플롭(generation 폭주). zero-value 필드는 기재하지 않는다.

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
  라이브 PVC 둘 다 갱신할 것. (tailnet 전역 nameserver=맥미니 tailscale IP:53→AdGuard는 디바이스명이 안정적이라 무관.)

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

### Alertmanager telegram 전송 검증 메트릭
- Alertmanager telegram 전송 검증은 로그가 아니라 `alertmanager_notifications_total{integration="telegram"}`
  과 `..._failed_total`으로. 봇 토큰은 메인 컨테이너 env가 아니라 init이 렌더한
  alertmanager.yml의 `bot_token_file`에 있다(직접 전송 테스트는 secret을 envFrom한 임시 파드로).
> 가드: `tests/gates/alertmanager-render-e2e.sh`, `tests/gates/test_telegram-notify.bats`, `tests/gates/test_telegram-alert-korean.bats`, `tests/gates/test_telegram-callsites.bats`

### ConfigMap 변경 파드 자동 재시작 없음
- ConfigMap(relay 스크립트 등) 변경은 파드 자동 재시작이 없다 — `rollout restart` 필요.

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
  승격 시 chatId가 바뀐다(전송 조용히 실패).

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
- 런북 13종은 gitignored 로컬 전용 — 단일 Mac 디스크 단일 사본은 매체 유실에 무방비다(age-keys.md가 recovery
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
  (릴리스 게이트에서 의식적으로 defer한 항목이다).
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

**처방** — 열거를 **변수로** 받아 rc를 캡처하고(`scripts/lib/scan-floor.sh`의 `scan_enumerate`),
건수 바닥값을 건다(`scan_floor`). 바닥값 **수치는 소비자가 소유한다** — 열거자는 "글롭이 깨져 0건"과
"정당하게 0건"을 구별할 도메인 지식이 없다. 부정 카운트=0 형태에는 바닥값만으론 부족하고
**양성 대조**(같은 술어가 어딘가에서는 매치한다)가 함께 필요하다. 셀 때 `grep -c .`는 0건에서 rc=1이라
`set -e` 콜사이트의 함정이다 — `scan_count`가 그걸 흡수한다.

⚠️ **이건 skip 규약과 다른 채널이다.** 저긴 "검사할 도메인이 정당하게 없음"(exit 4 + `SKIP:`)이고
여긴 "열거를 못 했다"는 검증 실패(**exit 1**)다. 마커를 내면 사람이 정반대 뜻으로 읽는다.
⚠️ 바닥값은 **기본 모드에만** 적용한다. 픽스처 모드(`--root`/`--min-*`)는 정당하게 1~2건이라
무조건 적용하면 음성 테스트가 전부 red가 된다(실측). ⚠️ 바닥값은 래칫이 아니다 — 도메인이 줄지
않는 한 손댈 일이 없다.

> 가드: `tests/gates/test_scan-floor.bats`, `scripts/lib/scan-floor.sh`, `policy/ledger.rego`, `tests/test_ledger.bats`

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

### 이미지 핀의 *존재* ≠ *일치* ≠ *소유자*

세 가지 서로 다른 질문이 하나로 뭉뚱그려져 있었다.

1. **핀이 있는가** — `scripts/check-image-pins.sh`가 본다. `@sha256:`이 붙어 있으면 통과다.
2. **핀이 일치하는가** — 아무도 안 봤다. 같은 `repo:tag`가 서로 다른 digest로 갈려 있어도 ①은 통과한다.
3. **그 digest를 누가 갱신하는가** — 아무도 안 봤다.

라이브 실측(2026-07-28): `pg-tools:18-rclone`이 두 digest로 갈려 있었다. `tools/repin-pgtools.ts`의
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
`infra/tailscale/acl.tf`의 `tailscale_dns_nameservers` = **맥미니**, 즉 라이브 클러스터의 AdGuard다.

즉 노드의 이름해석이 **클러스터를 경유한다** — Mac을 끄는 순간 노드가 `github.com`조차 못 풀고,
이미지 pull이 불가능해진다. 콜드스타트 교착의 두 번째 얼굴이며, `DNSStubListener=no` 하나로는
닫히지 않는다.

⚠️ `100.100.100.100`은 **LOCAL 주소가 아니다**(실측: `ip route get` → `dev tailscale0 table 52`,
local 테이블에는 노드 자신의 `/32`만). 그래서 CNI hostPort DNAT(`--dst-type LOCAL`)는 **피한다** —
그 교착과는 다른 경로다. "routable하니까 안전하다"는 판정이 정확히 여기서 틀린다.

✅ 처방은 `tailscale set --accept-dns=false`(디바이스 로컬, tailnet 전역 설정 무변경). 검사는
resolv.conf의 nameserver가 tailnet 대역(CGNAT `100.64.0.0/10` · tailscale ULA
`fd7a:115c:a1e0::/48`)에 있으면 거부한다. tailscaled 자신의 동작에는 영향이 없다(자기 내부
리졸버를 쓴다).

⚠️ 남은 절반: tailnet 전역 nameserver가 컷오버 후에도 맥미니를 가리키면 **tailscale을 켠 모든
기기**의 이름해석이 죽는다. 그 값은 gitignored `terraform.tfvars`에 있어 diff에 보이지 않고,
`terraform apply`는 성공한다.

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
