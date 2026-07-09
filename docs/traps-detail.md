# 라이브에서 검증된 함정 — 상세 (SSOT)

> 이 파일이 함정의 **단일 SSOT**다(AGENTS.md '라이브에서 검증된 함정'절에서 이전, progressive disclosure).
> AGENTS.md에는 한줄 인덱스만 둔다. enforced 함정의 가드 현황은 `docs/traps.md` 원장(`make verify-traps`).
> 컴포넌트 작업 전 해당 항목을 확인할 것.

### ArgoCD sync-wave 순서/교착
- **ArgoCD sync-wave는 "이전 wave가 healthy"를 기다린다** — 한 Application 안에서 워크로드(-6)가
  Secret(기본 0)보다 빠르면 영구 교착. `generatorOptions.annotations`는 KSOPS(exec) 출력에
  **적용되지 않는다**. 내부 wave는 꼭 필요할 때만.
> 가드: `platform/cnpg/prod/test_sync_wave_ordering.bats`, `platform/argocd/root/test_sync_wave_ledger.bats`

### ArgoCD retry 소진 후 명시 sync
- ArgoCD는 retry 소진 후 실패 리소스를 재시도하지 않는다 — 명시 sync:
  `kubectl -n argocd patch app <x> --type merge -p '{"operation":{"sync":{}}}'`,
  멈춘 op 종료는 `status.operationState.phase=Terminating` patch.

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
> 가드: `platform/adguard/prod/test_adguard_route.bats`

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
  servicelb/hostPort는 iptables DNAT뿐이라 트리거가 안 된다 — `dns-forward-trigger.service`
  (cloud-init) 참고. VM IP(192.168.139.x)는 Mac에서 직접 라우팅되지 않는다.

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
