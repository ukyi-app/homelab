# AGENTS.md — 에이전트/개발자 작업 가이드

k3s 단일 노드(Mac mini, OrbStack VM) 홈랩의 GitOps 모노레포. ArgoCD가 이 레포의 `main`을
싱크해 전 스택을 운영한다. 앱 코드는 **별도 레포**(`ukyi-app/<app>`, 템플릿:
`ukyi-app/homelab-app-template`)에 살고, 이 레포에는 배포 설정만 둔다.

## 디렉토리 지도

| 경로 | 역할 |
|---|---|
| `infra/` | Terraform 3 루트(cloudflare/tailscale/github) + `k3s-bootstrap/`(VM·k3s·스토리지) |
| `platform/` | ArgoCD가 싱크하는 GitOps 컴포넌트 (argocd, traefik, cnpg, victoria-stack, sealed-secrets, edge 3종, cache, namespaces, network-policies, data-conn) |
| `platform/charts/app` | 모든 앱이 쓰는 공유 Helm 차트 (SSOT) |
| `apps/<name>/deploy/prod/` | 앱별 values + SealedSecret + `.bindings.json`(db/redis·autoDeploy SSOT) + `source-repo`(외부 레포 바인딩) |
| `tools/` | 앱 플랫폼 DX **Bun/TS CLI** (`create-app`/`activate-app`·`audit-orphans` 등 — 변이 디스패처·`bump-poll`이 호출) + 단위 테스트(`tools/tests/`). 17개 `.ts`(bun 전용) + app-shared 2개 `.mts`(bun + node≥22.18 strip-types 양립) |
| `scripts/` | 클러스터/DR 운영·시크릿 **셸 스크립트** (bootstrap·seed/seal·dr-drill·`check-*` 게이트·run-bats — `make`/CI 게이트가 호출). cf. `infra/k3s-bootstrap/*.sh` = VM·k3s·스토리지 substrate 부트스트랩 |
| `policy/` | 메모리 원장 OPA 정책 (`bun run verify:ledger` 게이트) |
| `docs/memory-ledger.md` | 메모리 예산 SSOT — limit 합계 ≤ 8704Mi, CI 강제 |
| `docs/runbooks/` | **로컬 전용**(gitignored) 운영 런북 — 아래 인덱스 참고 |
| `tests/` | 전역 테스트 (sops 라운드트립, posture 라이브 스위트) |

## 핵심 명령

```bash
make verify        # 기반 게이트: skeleton + 원장(conftest) + sops 라운드트립
make chart-test    # 공유 차트: 3 kind(service/worker/static) 렌더 + kubeconform + bats
make tf-validate   # terraform fmt+validate (3 루트)
bats tools/tests/ infra/k3s-bootstrap/tests/          # 툴링/부트스트랩 테스트
make verify-posture   # [live] posture 스위트(internal-by-default·netpol·e2e) — KUBECONFIG 필요(없으면 skip)
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/<comp>/prod  # KSOPS 풀 렌더
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig   # 라이브 클러스터 접근
```

## 컨벤션 (필수)

- **커밋**: 한국어 conventional(`feat:`/`fix:`/…), AI 마커 금지. Claude는 `/commit` 스킬 사용.
- **주석**: 한국어로 통일. 기술 고유명사(ArgoCD, KSOPS, sync-wave, Deployment 등)는 영문 유지.
- **bats `@test` 이름은 영어** — 디렉토리 단위 실행 시 한글 이름이 인코딩 깨짐(검증된 버그).
- **`*.enc.yaml`은 직접 수정 금지** — 평문 메타데이터도 SOPS MAC에 포함된다. 수정은
  복호화→편집→재암호화(`sops`)로만. 시크릿 값은 채팅/로그에 절대 출력하지 않는다.
- 시크릿 공급: 로컬 `.env.secrets`(gitignored, 템플릿 `.env.secrets.example`) + SOPS 시드만.
- 내부 호스트 접미사는 `home.<도메인>` (Gateway `web-internal` 리스너 규약).
- 벤더 파일 수정 금지: `platform/*/prod/charts/`(helm 캐시, untracked), barman-plugin manifest,
  gateway-api CRD. `Chart.yaml`의 파스칼케이스는 Helm 고정 규약이다.
- `docs/plans/`는 역사 기록 — 수정하지 않는다.
- **네이밍 규약**: 워크플로는 전부 `.yaml`(reusable 포함). `_*.yaml`=내부 reusable(동명 변이 디스패처가
  호출) vs `<action>.yaml`=공개 변이 디스패처(workflow_dispatch) vs `reusable-*.yaml`=cross-repo 공개 계약(외부 앱 레포가 `@main`으로 호출 — 파일명·입력이 계약).
  스키마 `*-schema.json`=tools 계약(`app-config`/`app-deploy`/`homelab-app`) vs `values.schema.json`=Helm 고정.
  bats는 `test_` 접두 통일, SealedSecret은 `*.sealed.yaml`.

## 라이브에서 검증된 함정 (재발 주의)

> 이 절이 함정의 SSOT다. 그중 **실행 가능한 가드로 강제된 것**의 enforcement 현황은
> `docs/traps.md` 원장이 추적하며 `make verify-traps`가 가드 파일 소실 드리프트를 차단한다.

- **ArgoCD sync-wave는 "이전 wave가 healthy"를 기다린다** — 한 Application 안에서 워크로드(-6)가
  Secret(기본 0)보다 빠르면 영구 교착. `generatorOptions.annotations`는 KSOPS(exec) 출력에
  **적용되지 않는다**. 내부 wave는 꼭 필요할 때만.
- ArgoCD는 retry 소진 후 실패 리소스를 재시도하지 않는다 — 명시 sync:
  `kubectl -n argocd patch app <x> --type merge -p '{"operation":{"sync":{}}}'`,
  멈춘 op 종료는 `status.operationState.phase=Terminating` patch.
- k8s SSA는 중복 env 키/스키마 밖 필드를 거부한다 (argo-helm `ARGOCD_CONTROLLER_REPLICAS`,
  barman ObjectStore `spec.env` 사례).
- ArgoCD에서 `chart:` 필드를 쓰면 repoURL은 Helm 레지스트리, targetRevision은 차트 semver여야 한다.
- Traefik 차트는 `serviceAccount.name`을 지정하면 SA를 생성하지 않는다.
- appset 컴포넌트의 대상 네임스페이스는 `platform/namespaces`가 소유한다
  (appset에 `destination.namespace`가 없어 CreateNamespace 무효).
- R2 Object R&W 토큰은 ListBuckets/HeadBucket 불가 — rclone은 `no_check_bucket=true` 필요.
  terraform s3 백엔드는 무관.
- GHCR org 패키지는 첫 push 시 private + org 정책이 public 전환을 막을 수 있다
  (org Settings→Packages에서 Public 허용 후 패키지별 전환 — UI 전용).
- fine-grained PAT의 능력은 **실제 push 테스트로만** 확인 가능 — repo GET의 `permissions`
  필드는 사용자 역할을 보여줄 뿐이다. Resource owner를 org로 지정해야 org 리포에 쓴다.
- `runAsUser`가 이미지 `/etc/passwd`에 없으면 libpq가 기본 사용자명을 못 정해
  `pg_isready`가 'no attempt'로 실패 — `PGUSER` env로 우회.
- AdGuard처럼 setcap 바이너리는 `allowPrivilegeEscalation: false`와 양립 불가(exec EPERM).
- VictoriaMetrics `-retention.maxDiskSpaceUsageBytes`는 엔터프라이즈 전용(VictoriaLogs는 지원).
- `envFrom` 시크릿 변경은 파드 재시작이 있어야 반영된다.
- build 워크플로의 paths/diff 감지는 신규 브랜치·workflow_dispatch에서 무력 — fetch-depth: 0 +
  dispatch는 전체 빌드.
- GitHub Actions에서 `client_payload`는 비신뢰 입력 — env 경유 + regex 검증만 (인라인 보간 금지).
- CNPG Pooler의 `spec.pgbouncer.parameters`에 예약 파라미터(`pool_mode` 등)를 넣으면 webhook이
  생성 자체를 거부 — sync가 영구 실패 루프에 빠진다. `poolMode` 필드를 쓸 것.
- SSA + atomic 리스트(HTTPRoute `parentRefs`/`backendRefs`, STS `volumeClaimTemplates`)는 서버 주입
  기본값이 영구 OutOfSync를 만든다 — manifest에 기본값(group/kind/weight)을 명시하거나, status까지
  주입되는 vCT는 `ignoreDifferences`(+`RespectIgnoreDifferences=true`)로 제외.
- Application spec의 zero-value(예: `directory.recurse: false`)는 컨트롤러 정규화가 매번 삭제 →
  selfHeal과 플립플롭(generation 폭주). zero-value 필드는 기재하지 않는다.
- PSA는 `baseline`도 hostPath/hostPID를 금지한다(privileged 전용) — node-exporter/Vector류 DS는
  enforce=privileged 네임스페이스 필요.
- CNPG 기본 pg_hba는 replication을 streaming_replica(cert)만 허용 — pg_basebackup을 쓰려면
  `spec.postgresql.pg_hba`에 postgres replication 항목을 추가해야 한다.
- CronJob은 k3s VM의 TZ(Asia/Seoul)로 발화한다 — UTC로 읽지 말 것.
- **NetworkPolicy ipBlock에 pod CIDR(10.42.0.0/16)을 넣으면 "전체 파드 허용"** — default-deny가
  무력화된다. kubelet probe 소스는 노드(cni0=10.42.0.1)뿐이며, kube-router는 노드발 트래픽을
  POD-FW 내장 `fib saddr type local accept`로 정책 평가 **전에** 이미 허용한다.
- kube-router는 새 파드의 방화벽 룰을 생성 후 수 초 지나 설치한다 — 파드 첫 명령으로 즉시
  연결하는 NP 테스트는 그 공백을 통과한다(`sleep 8` 후 연결). kube-router v2는 sync마다
  체인 이름을 바꾸므로 라이브 디버깅은 원자 스냅샷(nft list 1회) 안에서 카운터를 읽을 것.
- **NetworkPolicy egress로 apiserver(ClusterIP) 접근은 ClusterIP ipBlock으로 안 된다** — kube-router가
  `kubernetes.default.svc`(10.43.0.1:443)를 apiserver endpoint(노드 InternalIP:6443)로 DNAT하고, netpol
  egress는 **DNAT 후 dest**를 평가한다. ClusterIP `10.43.0.1/32`를 ipBlock에 넣으면 API 호출이 Connection
  refused(default-deny REJECT)로 막힌다 — **노드 서브넷:6443**을 허용해야 한다(homepage 자동발견이
  "Error getting namespaces"로 전체 실패하며 검증). selfHeal 있는 Application엔 임시 patch가 reconcile에 곧
  원복돼 라이브 디버그가 어렵다 — PR로 수정.
- OrbStack은 VM에서 **LISTEN 중인 포트만** Mac으로 포워딩한다(바인드는 Mac 전 인터페이스).
  servicelb/hostPort는 iptables DNAT뿐이라 트리거가 안 된다 — `dns-forward-trigger.service`
  (cloud-init) 참고. VM IP(192.168.139.x)는 Mac에서 직접 라우팅되지 않는다.
- AdGuard ConfigMap은 첫 부팅 시드 전용(initContainer `cp -n`) — 갱신 시 PVC 안의
  AdGuardHome.yaml도 함께 고치고 재시작해야 반영된다.
- **AdGuard split-horizon rewrite(`*.home.ukyi.app → <traefik-ts tailscale IP>`)는 DR 재구축 시 stale이 된다.**
  DR로 traefik-ts 디바이스가 재등록되면(예: homelab→homelab-1) tailscale IP가 바뀌는데 rewrite는 옛 IP를
  가리킨 채라, tailscale·LAN 양쪽에서 모든 `*.home.ukyi.app`이 죽은 IP로 연결돼 실패한다(`.ts.net` MagicDNS
  경로엔 안 드러나 한참 뒤에 발견). 재구축 후 `kubectl -n gateway get svc traefik-ts`의 tailscale IP로 seed +
  라이브 PVC 둘 다 갱신할 것. (tailnet 전역 nameserver=맥미니 tailscale IP:53→AdGuard는 디바이스명이 안정적이라 무관.)
- tailscale operator의 Ingress reconcile은 metadata-only 변경(annotation nudge)을 무시한다 —
  재처리는 operator 재시작으로.
- **vector는 root로 실행해야 한다** — k3s `/var/log/pods/**/*.log`는 root:root 0640이라
  nobody(65534)는 못 읽어 수집이 조용히 0이 된다(healthcheck disabled라 에러도 안 뜸).
  진단은 VL `vl_rows_ingested_total{type="elasticsearch_bulk"}`로(0이면 경로 단절).
- **busybox 1.36 nc에는 `-q` 옵션이 없다** — `nc -l -p PORT -q 1`은 invalid option으로 즉시
  죽는다. deadmanswitch relay가 이 때문에 webhook을 영구 거부하고 healthchecks를 과도 ping해
  dead-man switch를 무력화했다.
- VictoriaLogs/일부 VM 컴포넌트는 distroless(wget/sh 없음) — 라이브 질의는 vmagent 등
  다른 파드에서 service DNS로. vmalert 그룹 조회는 `/api/v1/rules`(신버전, groups는 400).
- Alertmanager telegram 전송 검증은 로그가 아니라 `alertmanager_notifications_total{integration="telegram"}`
  과 `..._failed_total`으로. 봇 토큰은 메인 컨테이너 env가 아니라 init이 렌더한
  alertmanager.yml의 `bot_token_file`에 있다(직접 전송 테스트는 secret을 envFrom한 임시 파드로).
- ConfigMap(relay 스크립트 등) 변경은 파드 자동 재시작이 없다 — `rollout restart` 필요.
- **bats가 bash 3.2(macOS 기본)로 돌면 테스트 중간의 `[[ ]]` 실패가 침묵 통과된다**(set -e가
  compound command 실패를 무시 — 마지막 명령 status만으로 ok). 중간 단언은 `[ ]`(단순 명령)로.
- helm 차트 CRD가 `crds/` 디렉토리에 있으면 kustomize HelmChartInflationGenerator 기본 렌더에서
  빠진다 — `includeCRDs: true` 필수(sealed-secrets에서 검증).
- **sealed-secrets patch-mode로 기존(타 도구 생성) Secret에 키를 머지하려면 `sealedsecrets.bitnami.com/patch:
  "true"`를 대상 live Secret에 둬야 한다** — 컨트롤러(0.37.0)는 SealedSecret 템플릿이 아니라 **대상 Secret의
  어노테이션**에서 patch 여부를 읽는다. 템플릿에만 두면 `failed update: Resource "<name>" already exists and is
  not managed by SealedSecret`로 거부돼 Application이 Degraded(argocd ukkiee 비밀번호를 argocd-secret에 머지하다
  발견). argo-helm은 `configs.secret.annotations`로 data 블록 없이 이 어노테이션을 차트 생성 시점에 부여할 수
  있다(data 필드 미설정 시 data 블록 미렌더 → 머지 키 prune 없음, DR-durable). `patch` 단독이면 ownerRef 없이
  additive 머지(기존 키 보존). **`managed: "true"`는 controller ownerRef를 만들어 SealedSecret 삭제 시 대상 Secret
  전체가 cascade delete되므로 쓰지 말 것**(patch 단독으로 충분).
- `gh pr merge --auto`는 이미 clean(체크 완료)인 PR에 에러를 낸다 — `|| gh pr merge` 폴백 필요.
- `create-github-app-token`의 `repositories` 입력은 **owner 없는 레포명**만 받는다
  (`owner/repo` 형태를 넣으면 스코프 실패). cross-repo read는 `owner:` 명시 필수(비우면 현재
  레포로만 제한). 액션은 full commit SHA로 핀(mutable 태그는 private key를 변조 액션에 넘김).
- `concurrency.queue: max`(2026-05 GA)는 `cancel-in-progress: true`와 병용 불가(워크플로 검증
  에러로 전체 불능) — 기본(single)은 pending 1건만 유지해 동시 3번째가 대기 건을 취소한다.
- **terraform provider lock을 처음 커밋할 땐 라이브 state writer 버전 이상으로 핀해야 한다.** lock
  미커밋 시절 CI `init`은 `~>` 제약의 최신을 자동 설치해 그 버전으로 state를 기록한다 — 이후 더 낮은
  버전을 핀한 lock + `-lockfile=readonly`는 "Resource instance managed by newer provider version"으로
  apply 영구 실패. `terraform providers lock`은 기존 lock 버전을 보존(해시만 추가)하므로 업그레이드는
  `rm lock && terraform providers lock -platform=...`로 최신 재생성해야 한다(레지스트리 버전 단조증가).
- **tf 루트 관리 모델(CI vs 로컬):** cloudflare만 CI apply(iac.yaml push + tf-reconcile 수렴) — DNS/tunnel
  좁은 스코프라 안전. github/tailscale은 **owner 로컬 apply 전용 신뢰 앵커**: github 루트가 CI Actions
  시크릿(secrets.tf)·branch protection(repo.tf `contexts=["gate"]`)을, tailscale 루트가 ACL/auth-key를
  관리한다. CI 무인 apply는 광범위 admin PAT/OAuth를 CI에 저장해야 해 보안 모델 위반 → 금지. CI는 이 둘에
  대해 tf-reconcile에서 **plan-only 드리프트 알림**만 한다(신규 `TF_GITHUB_*`/`TF_TAILSCALE_*` 시크릿 있을
  때만, 없으면 preflight skip). Cloudflare 무료 플랜 rate-limit entitlement(period·mitigation_timeout 둘 다
  10초 고정 등)는 plan 통과해도 apply에서만 400으로 드러난다(cache.tf matches 함정과 동일 계열).

## 멀티레포 앱 플로우 (App Platform DX — 요약)

**트리거 경계:** 앱 레포는 homelab-write 자격 0 (자기 `GITHUB_TOKEN`으로 GHCR push만).
인증은 GitHub App 2개 — reader(앱 레포 Contents:read 전용)/writer(homelab Contents+PR write
전용), 키는 homelab Actions secret에만. **모든 homelab main 쓰기는 PR-first + auto-merge**
(App 토큰은 branch protection 우회 불가; required check `gate` 통과 시 자동 머지).

- **빌드:** 템플릿으로 레포 생성 → `.app-config.yml` 작성(계약: `tools/app-config-schema.json`)
  → main push → `reusable-app-build.yaml`(v1: arm64→GHCR push만, dispatch 없음).
- **생성 변이:** owner가 homelab에서 액션별 디스패처(workflow_dispatch) 실행 —
  `create-app`/`update-secrets`/`create-database`/`create-cache`(각 전용 워크플로). **파괴(teardown-app/
  teardown-resource)·activate-app은 owner-local**(`make teardown-*`·런북), **audit은 스케줄 reconciler**(`audit.yaml`).
  validator(`tools/validate-mutation.ts`)가 계약표 강제. 전역 직렬화: `concurrency: homelab-mutation` + `queue: max`.
- **update-image:** `bump-poll.yaml`(10분 주기 GHCR 폴링)이 권위 — main reachable + 배포 SHA
  descendant + digest 핀 검증 후 autoDeploy면 자동 PR+머지, 아니면 승인 PR(.bindings.json이
  autoDeploy SSOT, 누락=fail-closed). (인-레포 **앱 이미지** 전용.)
- **인프라/플랫폼 의존:** self-hosted Renovate(`renovate.json` + `renovate.yaml`, 주 1회, writer App
  토큰 PR-first, automerge 금지 → 리뷰 후 머지)가 서드파티 이미지 digest·terraform provider·
  k3s/local-path(versions.env)·helm 차트(Chart.yaml/CHART_VERSION/helmrelease)·npm을 갱신. **github-actions
  manager는 비활성** — `uses:` 핀 갱신은 토큰에 `workflows: write`가 필요한데 writer App은 Contents+PR
  write 전용이다. 켜려면: writer App에 workflows:write 부여 → renovate.yaml 토큰에 `permission-workflows: write`
  추가 → `renovate.json`의 `"github-actions".enabled=true`. (벤더 `charts/`·barman-plugin은 ignorePaths.)
- **공개(DNS):** create-app은 `infra/cloudflare/apps.json`에 `active:false`로 등록(DNS 미생성)
  → 배포 Healthy 확인 후 `tools/activate-app.ts` 게이트(descendant+표면 무변경+행 고정)가
  `active:true` 플립 → `iac.yaml`(push apply)/`tf-reconcile.yaml`(30분 드리프트 수렴)이 노출.
- **시크릿:** SealedSecrets(컨트롤러 `platform/sealed-secrets`, cert 공개) — 앱 레포에서
  `pnpm secret:seal`(.env→`<app>-secrets.sealed.yaml`) → create-app/update-secrets가 검증 복사.
  sealing key는 `scripts/backup-sealed-secrets-key.sh`로 out-of-band 백업(복구 드릴 게이트).
- **teardown:** 앱(`teardown-app`)과 리소스(`teardown-resource`)는 분리 — 리소스는
  `.bindings.json` 참조 0 강제, retain(보존+tombstone) 기본, purge(--delete-data)는
  백업 검증 ID + 4단계 상태머신(owner 로컬 전용). `audit-orphans`가 드리프트 감시.

## 런북 (로컬 전용 — `docs/runbooks/`, git에 없음)

운영 절차 상세는 비공개 유지를 위해 로컬에만 둔다. 디스크 유실 대비 별도 백업 권장.

| 런북 | 내용 |
|---|---|
| `02-cloud-iac-bootstrap.md` | R2 상태 버킷·terraform·bootstrap 절차 |
| `age-keys.md` | age 2-recipient 키 모델/보관 |
| `app-platform.md` | App Platform 트리거 경계·Phase 0 체크리스트·activate-app/purge 절차 |
| `app-onboarding.md` | 앱 온보딩 체인(외부 레포 + 인레포) |
| `external-ssd.md` | 외장 SSD APFS 볼륨 + bulk-ssd 게이트 |
| `host-substrate.md` | OrbStack VM/k3s 호스트 계층 |
| `lan-dns.md` | AdGuard split-horizon + 라우터 DNS(R7) |
| `observability-bootstrap.md` / `observability-verify.md` | 관측성 셋업/검증 스윕 |
| `restore.md` | CNPG 복구(R1) — DR 핵심 |
| `storage-verify.md` | 스토리지 라이브 e2e 검증 |
| `toolchain.md` | 호스트 도구 핀 |
