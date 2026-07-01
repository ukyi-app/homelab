# files 배포 — 홈랩 플랫폼 컴포넌트 (설계)

- 날짜: 2026-07-01
- 상태: 승인됨 (brainstorming HARD-GATE 통과) + 적대적 설계 리뷰(5 챌린저 + 판정) 반영
- 다음 단계: writing-plans → codex 적대적 리뷰(Phase C) → executing-plans
- 대상 앱: `ukyi-app/files` (별도 레포, 완성됨) — Rust/axum, stateful, 단일 파드 2리스너

## 1. 배경 / 동기

완성된 Rust 파일스토어 앱 `files`를 **현 구조 그대로**(stateful `bulk-ssd` PVC + 단일 파드 2리스너:
internal `:8080` = 전체 `/api` write/admin, public `:8081` = 읽기전용 다운로드/카탈로그) 홈랩에 배포한다.

골든패스(공유 차트 `platform/charts/app` + `apps/` + create-app)는 이 앱을 **5축에서 표현 불가**하다:
PVC 볼륨 · 2번째 컨테이너 포트 · 2번째 Service · 2번째 HTTPRoute(sectionName·host 상이) · secret 파일마운트.
또한 `apps` AppProject는 `namespaceResourceWhitelist`에 `PersistentVolumeClaim`이 없고 `clusterResourceWhitelist`가
비어 stateful 앱을 거부한다. 따라서 **베스포크 플랫폼 컴포넌트 `platform/files/prod/`** 로 배포한다(원본 files
설계 §7·§11과 일치). 저작은 **`platform/adguard/prod` 스켈레톤을 그대로 복제**해 net-new를 최소화한다.

## 2. 목표 / 비목표

**목표**
- 앱 리팩터 0으로 배포. 2리스너 표면 분리 유지(라우팅 비의존, 앱이 강제).
- `bulk-ssd`(2TB 외장 SSD) 영속. GitOps 자동 싱크(platform-components ApplicationSet 자동발견).
- 서비스별 키 봉인(SealedSecret 파일마운트) + private GHCR pull.
- restricted PSA 하드닝(비루트·RO루트·drop ALL·seccomp RuntimeDefault).
- 무료 티어 durability 가드(PV-Retain + Prune=false), 스테이징 롤아웃(internal → public).

**비목표 (YAGNI)**
- 골든패스 편입 / 공유 차트 확장 / thin per-app 차트 / 공유 kustomize base(3번째 stateful 앱 등장 전까지 보류).
- bump-poll 자동 이미지 배포(수동 kustomize `images:` 핀).
- **R2 오프사이트 백업**(R2 무료 티어 저장 ~10GB 상한 + CNPG가 이미 R2 사용 → v1 제외, §5 미래 옵션).
- StatefulSet(§13 기각 근거).
- 앱 로직 변경(SIGTERM 핸들은 files 레포 fast-follow, 배포 비차단).

## 3. 아키텍처 개요

- `platform/files/prod/` 평범한 kustomize 디렉토리 → `platform-components` ApplicationSet가 glob
  `platform/*/prod`로 **자동 발견** → Application `files-prod`(project `platform`, group/kind `*`,
  syncPolicy automated prune+selfHeal, ServerSideApply, CreateNamespace, sync-wave 0). 중앙 목록 편집 0.
- 단일 Deployment(replicas 1, `strategy: Recreate` — RWO PVC 단일노드 교착 회피), 컨테이너 포트 2개(8080/8081).
- **Service 2개**(adguard 패턴): `files-internal`(ClusterIP 8080) · `files-public`(ClusterIP 8081), 같은 파드.
- **HTTPRoute 2개**(같은 공유 Gateway `homelab`/`gateway`, parentRefs/backendRefs group·kind·weight 명시로 SSA
  atomic-list OutOfSync 회피):
  - internal: `files.home.ukyi.app` → `web-internal-tls`(8443, `*.home.ukyi.app` 와일드카드 cert) → 8080.
    tailscale TCP-passthrough, **Cloudflare 무관**.
  - public: `files.ukyi.app` → `web-public`(8000, plaintext, edge-TLS) → 8081. 경로는 앱이 강제(§6).
- 전용 `files` 네임스페이스(PSA enforce=restricted).

## 4. 컴포넌트 (파일별 — adguard/trip-mate 복제)

`platform/files/prod/`:
| 파일 | 역할 |
|---|---|
| `kustomization.yaml` | `namespace: files`; resources 순서(pvc→sealed→deployment→service→route×2→netpol) + `images:` 핀 |
| `pvc.yaml` | `files-data`, RWO, `storageClassName: bulk-ssd`(**명시 필수** — opt-in, 누락 시 `standard`), 100Gi, ArgoCD `Prune=false` |
| `deployment.yaml` | Recreate·replicas 1·포트 2개·env(FILES_*)·restricted securityContext·fsGroup 65532·volumes(data/keys/tmp)·probes(/healthz·/readyz@8080)·`automountServiceAccountToken:false`·imagePullSecrets ghcr-pull·resources(request+limit)·`images:` 핀 대상 |
| `service.yaml` | `files-internal`(8080) · `files-public`(8081) |
| `httproute-internal.yaml` | web-internal-tls, `files.home.ukyi.app` → files-internal:8080 |
| `httproute-public.yaml` | web-public, `files.ukyi.app` → files-public:8081, `GET`만 |
| `files-keys.sealed.yaml` | keys 레지스트리 JSON SealedSecret(파일마운트) |
| `ghcr-pull.sealed.yaml` | files-ns dockerconfigjson SealedSecret(private GHCR pull) |
| `networkpolicy.yaml` | 자기격리(default-deny egress + DNS만 + gateway ingress 8080·8081) |
| `test_files_*.bats` | 매니페스트 grep 검증(영어 @test명) |

**컴포넌트 밖(별도 편집)**:
| 대상 | 변경 |
|---|---|
| `platform/namespaces/prod/namespaces.yaml` | `files` ns(enforce=restricted, Argo Prune=false) 추가 — appset이 destination.namespace 미제공→CreateNamespace no-op |
| `docs/memory-ledger.md` | files 메모리 limit 행 추가(CI 강제) |
| `infra/cloudflare/apps.json` | **(PR-B)** `{"name":"files","host":"files.ukyi.app","public":true,"active":true}` |
| `scripts/seal-files-keys.sh` + `make` 타겟 | keys 봉인(owner-local) |
| `make seal-ghcr-pull`(files-ns 변형) | ghcr-pull 봉인(owner-local) |

## 5. 스토리지 & durability (R2 없음, 무료 티어)

- `bulk-ssd`(2TB 외장 SSD, virtiofs `/mnt/mac/Volumes/homelab/k3s-bulk`), RWO, `Recreate`,
  `WaitForFirstConsumer`, `allowVolumeExpansion:true`(온라인 확장). 100Gi. `readOnlyRootFilesystem:true` →
  쓰기는 `/data`(PVC) + `/tmp`(emptyDir)만.
- **/data 쓰기 보장 — fsGroup 65532만(사다리 삭제)**: 레포가 이미 실증 — `cnpg-local-basebackup`이 restricted
  비루트(fsGroup 26)로 bulk-ssd/virtiofs PVC에 100Gi write, 프로비저너가 `mkdir -m 0777`(fsGroup 무관 world-writable).
  폴백 사다리(provisioner chown·root initContainer)는 삭제 — root init은 enforce=restricted에서 admission 거부,
  provisioner chown은 host-shell 공유 인프라라 부적절. **첫 배포 검증은 /readyz가 아니라 `files.home.ukyi.app`로
  실제 PUT→GET 왕복**(/readyz는 /data 쓰기 실패에도 green 가능).
- **durability 모델(R2 없이)**:
  - 데이터는 **물리 외장 SSD**에 있음 → **VM 재구축·파드 교체·노드 재부팅에 생존**(VM은 cattle, SSD는 아님).
    "VM 재구축 시 소실"은 `BULK_ALLOW_VM_DISK=1` 폴백에만 해당(비영속) — 실제 external-SSD 경로 아님.
  - 손실 벡터 ① **클러스터 내 실수 PVC 삭제** → 프로비저너 `rm -rf`. `reclaimPolicy: Delete`는 StorageClass
    속성이라 PVC별 override 불가. **가드(무료)**: PVC에 ArgoCD `Prune=false`(git-prune 차단) + **바인딩된 PV를
    `persistentVolumeReclaimPolicy: Retain`으로 post-provision 패치**(런북·DR 단계 — PVC 삭제돼도 PV/데이터 보존).
    ⚠️ Prune=false 단독은 appset `resources-finalizer` app-delete 캐스케이드를 못 막음 → PV-Retain 패치가 실질 방어.
  - 손실 벡터 ② **물리 SSD 고장**(오프사이트 없음) = **v1 수용 잔여 리스크**. 근거: 의도 데이터 상당수가
    재생성 가능(스킬 ZIP·공개 배포·아티팩트) + 무료 티어 제약. 소중 데이터는 owner가 수동 백업.
  - **DR re-link(런북)**: VM 재구축 후 새 PVC는 새 디렉토리를 받아 옛 데이터가 SSD에 orphan으로 남음(소실 아님)
    → 새 PVC를 옛 디렉토리에 수동 re-link하는 복구 단계 필요.
- **미래 옵션(지금 미구현)**: ⓐ 외장 SSD가 Mac Time Machine 대상이면 이미 무료 오프디바이스 백업 존재(확인).
  ⓑ 데이터가 소중해지면 작은 버킷만 R2 무료 10GB 내 selective sync. ⓒ 로컬 2차 디스크 rsync(owner-local).

## 6. 보안 & 표면 분리

- **표면 분리(라우팅 비의존)**: `/api`(write/delete/admin)는 internal 리스너에만 바인딩. public 리스너엔 `/api`
  핸들러가 물리적으로 부재(public.rs가 `/api/*`·`/healthz`·`/readyz`를 명시 404). 라우팅 드리프트에도 도달 불가.
- **:8081이 유일한 read-only 경계**: Gateway API core는 `/{bucket}/{key}` 경로 템플릿 불가(Exact/PathPrefix/
  RegularExpression만) → 공개 경계는 **앱 :8081 프로세스가 유일**. **가드 테스트**: 공개 HTTPRoute
  `backendRef.port==8081` 且 `method==GET`(8080 오배선 시 write/admin API 인터넷 노출 방지).
- **서비스별 API 키**: keys 레지스트리 JSON(`{sha256, service, writeBuckets[], readBuckets[], admin?}`)을
  bitnami SealedSecret `encryptedData.keys.json`으로 → secret 볼륨 `items:[{key:keys.json,path:keys.json}]` RO
  마운트 `/etc/files-keys` → `FILES_KEYS_PATH=/etc/files-keys/keys.json`(trip-mate 파일마운트 패턴).
  `--scope strict`(name+ns 고정). `scripts/seal-files-keys.sh` + `make secret-cert-check` 선행.
- **ghcr-pull**: first-party 이미지 `ghcr.io/ukyi-app/files`는 첫 push private → files ns dockerconfigjson
  SealedSecret 필요(prod 것 재사용 불가 — imagePullSecrets는 ns-local, strict scope는 name+ns 고정).
- **NetworkPolicy(자기격리, adguard 패턴)**: default-deny egress + DNS egress(kube-system `k8s-app:kube-dns`
  UDP/TCP 53)만. ingress는 **gateway ns namespaceSelector에서 8080·8081만**(intra-ns :8080 allow 없음 — write/
  admin을 형제 앱에서 도달 불가). **DB/cache egress 절대 미포함**(전용 ns의 보안 페이오프 — additive union이라
  prod ns에선 불가능). **pod-CIDR ipBlock 금지**(default-deny 무력화 트랩).

## 7. 라우팅 & 공개 노출

- internal(`files.home.ukyi.app`): tailscale TCP-passthrough → web-internal-tls(8443, `*.home.ukyi.app` 와일드카드
  cert). AdGuard split-horizon가 `*.home.ukyi.app` 와일드카드 rewrite라 files 서브도메인 자동 해결(dash/adguard 선례).
  Cloudflare 무관 → PR-A에서 즉시 동작.
- public(`files.ukyi.app`): **PR-B** — `infra/cloudflare/apps.json` 1줄 → Terraform이 proxied CNAME +
  tunnel ingress(`→ traefik.gateway.svc:80`) 자동 배선. cloudflared ConfigMap 편집 불요.

## 8. 네임스페이스 & PSA

전용 `files` ns, `enforce/warn/audit=restricted`(files는 비루트·RO루트·drop ALL·seccomp RuntimeDefault·
포트>1024·setcap 불요 → 완전 적합). `namespaces.yaml`에 Namespace 오브젝트 명시(appset destination.namespace
미제공 → CreateNamespace no-op) + Argo Prune=false. **순서 함정**: files ns PR이 files-prod보다 **먼저 머지·싱크**
(appset app은 wave·destination.namespace 없어 'namespace not found' 레이스).

## 9. 이미지 업데이트

bump-poll(`apps/` 전용, `bump-tag.ts`가 `apps/` 밖 쓰기 fail-close)·Renovate(불변 `sha-<gitsha>` 태그라 no-op)
미적용 → **kustomize `images:` 트랜스포머로 tag+digest 수동 핀**, 릴리스마다 PR(리뷰어가 descendant+digest 확인).
빈도 아프면 `apps/` 공유 파이프라인 불변경, **files 전용 격리 미니워크플로** 추가(미래).

## 10. 롤아웃 (스테이징)

- **PR-A(internal)**: `platform/namespaces` files ns + `platform/files/prod/` 전체(internal Service/HTTPRoute +
  public Service/HTTPRoute도 포함하되 `apps.json` 미변경이라 인터넷 미노출) + 봉인 시크릿 + memory-ledger 행.
  라이브 검증: PVC bound, **실제 PUT→GET 왕복(files.home.ukyi.app)**, readyz 200, PV-Retain 패치.
- **PR-B(public)**: `apps.json` 추가 → terraform apply → `files.ukyi.app` 다운로드 라이브 검증 + 공개 표면
  `/api` 404 증명.

## 11. 테스트 전략 (TDD)

- **bats**(매니페스트 grep, 클러스터 무): ① 2 라우트·sectionName ② public HTTPRoute backendRef.port==8081·GET
  (never 8080) ③ secret 파일마운트(envFrom 아님) ④ Recreate·readOnlyRootFilesystem ⑤ storageClassName bulk-ssd·
  PVC Prune=false ⑥ sealed 평문 부재 ⑦ netpol deny+allow·pod-CIDR 부재·DB/cache egress 부재.
- **kustomize 렌더**: `kustomize build --enable-helm platform/files/prod` + kubeconform.
- **게이트**: `check-resource-limits.sh`(resources) + memory-ledger conftest.
- **라이브**(스테이징 각 단계): §10.

## 12. 리스크 & 완화

| 리스크 | 완화 |
|---|---|
| 물리 SSD 고장(오프사이트 없음) | v1 수용 잔여 리스크(데이터 상당수 재생성 가능·무료 티어). 소중 데이터 owner 수동 백업. 미래 R2 selective |
| 실수 PVC 삭제 → rm -rf | PV-Retain 패치(런북) + Prune=false + 가드 테스트 |
| virtiofs fsGroup 미존중 | 레포 실증(basebackup fsGroup 26·mkdir 0777) → 저위험. 첫 배포 **실제 write** 검증 |
| SSA atomic 리스트 OutOfSync | parentRefs/backendRefs group·kind·weight 명시 |
| public 표면 드리프트 | 앱이 8081에 `/api` 부재 + :8081 포트 가드 테스트 |
| SIGTERM 미처리(SIGINT만) | 손상 없음(atomic+reconciliation) — 롤아웃 시 업로드 중단(가용성)뿐. files 레포 fast-follow |
| ns 순서 레이스 | files ns PR 선머지 |
| CI 게이트 미충족 | resources+limit·memory-ledger 행을 PR-A에 동반 |
| private GHCR pull 실패 | files ns ghcr-pull SealedSecret |

## 13. 결정 로그 (확정)

- **베스포크 플랫폼 컴포넌트**(골든패스 5축 불가 + apps AppProject PVC 금지). adguard 스켈레톤 복제.
- **Deployment + 분리 PVC + Recreate**(StatefulSet 아님). Service 2 · HTTPRoute 2 · 전용 files ns restricted.
- PVC `bulk-ssd` 100Gi RWO. **durability = 로컬 SSD + PV-Retain 가드(R2 없음, 무료 티어)**.
- keys + ghcr-pull SealedSecret 파일마운트. 이미지 kustomize `images:` 수동 핀.
- **스테이징 롤아웃(internal → public)**. fsGroup 65532만(사다리 삭제) + 실제 write 검증.

## 부록 A — 적대적 설계 리뷰 dispositions (5 챌린저 + 판정, 2026-07-01)

판정: `yes-with-adjustments`(아키텍처 최선 확정, confidence high). 대안 5개 기각, 조정 7건 수용.

| 대안/발견 | 판정 | 반영 |
|---|---|---|
| StatefulSet+vCT | 기각 | 데이터안전은 PV-Retain+(미래)백업이 더 완전 + appset 자동발견·온라인 리사이즈 유지. vCT=SSA 트랩·크기 불변 |
| prod ns 재사용 | 기각 | prod ns-wide podSelector:{} egress(→5432/6379) additive union 제거 불가 = 인터넷 노출 파드 측방이동. §6 전용 ns |
| 공유 차트/thin/base | 기각 | fail-closed 계약 폭발반경 + apps AppProject PVC 금지 + appset path-only + YAGNI |
| R2 직접 서빙 public | 기각(미래) | v1 아님(Worker/커스텀도메인 net-new). §5 미래 옵션 |
| hostPath | 기각 | restricted PSA 금지 + 도트린 "Never hostPath" |
| **R2 백업 계층** | **범위조정** | 무료 티어(~10GB) + CNPG 기존 사용 → v1 제외. durability=로컬 SSD+PV-Retain(§5), 미래 옵션 명시 |
| PVC 가드 부족 | 수용 | PV-Retain 패치 + Prune=false + 가드 테스트(§5) |
| fsGroup 사다리 과설계 | 수용 | 사다리 삭제, fsGroup만 + 실제 write 검증(§5) |
| :8081 경계 = 앱뿐 | 수용 | 포트 가드 테스트(§6·§11) |
| resources 누락 → CI 실패 | 수용 | resources+limit + memory-ledger 행(§4·§11) |
| netpol 정밀화 | 수용 | gateway-only 8080·intra-ns 금지·DB/cache egress 미포함(§6) |
| SIGTERM 손상(과대평가) | 수용(교정) | atomic+reconciliation이라 손상 0, 가용성뿐. 잔여 리스크(§12) |
| 저작 방식 | 수용 | adguard 스켈레톤 복제(§4) |
