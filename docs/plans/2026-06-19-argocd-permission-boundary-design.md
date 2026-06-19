# ArgoCD 컨트롤플레인 권한경계 + 라이프사이클 정합성 (테마1 / plan 1)

> 2026-06-19 심층 검토(10차원 적대적 감사, 47발굴→34검증)의 8테마 로드맵 중 **1번째 plan**.
> 후속: 테마2(공유차트 fail-closed)·테마3~8. 본 plan은 테마1의 **항목 1~4**만 다룬다
> (항목 5=데이터 per-app appset 전환, 항목 6=targetRevision 롤백SSOT는 별도 후속 plan).

## 문제 (감사 발견)

이 레포의 핵심 아키텍처는 "멀티레포 앱 플랫폼"(`apps` ApplicationSet이 `apps/*/deploy/prod`를
무인 자동발견)인데, ArgoCD **런타임에 선언적 권한 경계가 0**이다. 동시에 ApplicationSet에
라이프사이클 정합성 갭 3건이 잠복한다.

1. **AppProject 0개** — 전 Application/appset이 내장 `default`(sourceRepos/destinations/
   clusterResource 전부 무제한). main 쓰기 방어선은 GitHub required check `gate`뿐이고, 그건
   ArgoCD가 임의 namespace·cluster-scoped 리소스(ClusterRole/CRD)를 적용하는 것을 막지 못한다.
   PSA는 파드 보안만, NetworkPolicy는 네트워크만 막는다.
2. **appset 템플릿에 resources-finalizer 부재** — teardown(`apps/<app>/` 디렉토리 삭제)으로
   appset이 Application 생성을 멈추면 ArgoCD가 Application CR을 **non-cascading delete** →
   Deployment/Service/HTTPRoute/SealedSecret이 prod ns에 고아로 남는다. 수동 Application 9개는
   전부 finalizer를 가지나, appset 생성분은 0.
3. **exclude 경계가 주석 규율만** — platform-components appset은 수동 관리 컴포넌트(argocd·cnpg·
   victoria-stack·charts·sealed-secrets)를 `exclude: true`로 빼야 이중소유를 막는데, 이를 강제하는
   가드가 없다(누락 시 appset+수동 Application 이중소유 → prune 플립플롭 영구 교착).
4. **namespaces가 wave 제어 밖** — `namespaces-prod`는 appset이 wave 0로 발견하나, 6개 ns의 유일
   생성자다. sealed-secrets(-8)·traefik(-8)이 먼저 떠 CreateNamespace로 **PSA 라벨 없는 bare ns**를
   만들고 namespaces-prod(wave 0)가 나중에 라벨을 patch → admission 방어선 윈도우 + 콜드스타트/DR
   sync 노이즈.

## 제약

기존 기능·동작 비파괴. AppProject·finalizer·가드는 전부 **가산적** — 화이트리스트가 라이브
리소스를 전수 커버하면 OutOfSync 0. 라이브 워크로드 매니페스트는 무변경(`platform/argocd/root/` +
appset + bats만 수정).

## 설계

### A. AppProject 2개 (`platform/argocd/root/projects.yaml`, sync-wave `-9`)

`-9`는 프로젝트를 참조하는 가장 이른 컴포넌트(sealed-secrets/traefik wave -8)보다 먼저 생성되게
한다. AppProject CRD는 argocd self-manage(-10) 설치분이라 이미 존재.

**`apps` (엄격 — 멀티레포 위협 표면, 인레포 앱 0개라 위험 0)**
- `sourceRepos: [https://github.com/ukyi-app/homelab.git]`
- `destinations: [{server: https://kubernetes.default.svc, namespace: prod}]`
- `clusterResourceWhitelist: []` — cluster-scoped 전면 금지(앱은 namespaced만)
- `namespaceResourceWhitelist` — 공유 차트(deployment/service/httproute/configmap/migrate-job
  템플릿) + source#3 kustomize(SealedSecret)가 방출하는 kind만:
  `Deployment`(apps), `Service`·`ConfigMap`(core), `Job`(batch),
  `HTTPRoute`(gateway.networking.k8s.io), `SealedSecret`(bitnami.com).
  (extraManifests로 다른 kind 주입 시 거부 — 테마2의 escape hatch와 맞물리는 2차 방어선.)

**`platform` (스코프 — 동작보존 우선)**
- `sourceRepos` = homelab repo + 각 매니페스트의 helm repoURL (**파생**)
- `destinations` = in-cluster server + 플랫폼이 실제 배포하는 **렌더된 namespace 집합**
  (argocd·cert-manager·cnpg-system·database·sealed-secrets·gateway·edge·prod·cache·homepage·observability).
  ⚠️ **설계 리뷰 #2**: appset-생성 platform 컴포넌트는 Application `.spec.destination.namespace`가
  **비어있다**(appset 템플릿은 `destination.server`만; ns는 각 kustomization의 `namespace:` 트랜스포머가
  렌더 — appset.yaml:40-41 확인). 따라서 destination.namespace 파생은 무의미·잘못된 레이어 →
  **rendered manifest의 리소스 namespace**에서 파생해야 한다(ArgoCD는 리소스 ns를 project destinations로
  검증). 정확 목록은 plan이 `kustomize build`로 enumerate.
- `clusterResourceWhitelist: ['*']` — 플랫폼은 CRD/ClusterRole/GatewayClass/Namespace를 정당하게
  설치하므로 좁히면 동작파괴. 와일드카드 유지(가치=server+repo+namespace 경계; cluster-scoped는
  소유자-PR 경로라 §D default-lockdown 가드가 보완).

**파생값 안전장치**: sourceRepos/destinations는 추측하지 않고 enumerate하며, bats 가드는
**`kustomize build` 렌더 산출물의 리소스 namespace**(Application `.spec.destination.namespace`가 아니라)와
helm repoURL이 각각 project destinations·sourceRepos에 포함되는지 강제(드리프트 차단). 렌더 ns가 project에
없으면 ArgoCD가 그 리소스를 거부하므로, 이 렌더-기준 가드가 동작보존의 핵심이다.

### B. 프로젝트 재배정

| Application | 현재 | 신규 |
|---|---|---|
| argocd(self, -10) · root(-9) | default | **default 유지** (부트스트랩 앵커 — 자신이 프로젝트를 생성하므로 chicken-egg 회피) |
| cert-manager·cnpg-operator·cnpg-barman-plugin·cnpg-data·sealed-secrets·victoria-stack·argocd-extras | default | **platform** |
| platform-components appset 템플릿 `spec.project` | default | **platform** |
| apps appset 템플릿 `spec.project` | default | **apps** |

`test_root_app.bats`의 root·argocd `project: default` 단언은 유지(둘은 잔류). 나머지는 신규 가드가 검증.

### C. namespaces wave 승격 — ⚠️ cascade 함정 안전 시퀀스

namespaces를 wave 0(appset) → 수동 Application(wave **-9**, sealed-secrets보다 먼저)로 이전.
**위험**: appset 템플릿에 finalizer가 있는 상태에서 namespaces를 exclude하면 appset이 namespaces-prod를
**cascade 삭제**(전 네임스페이스+워크로드 소멸). 안전 순서:
1. appset에 `platform/namespaces/*` exclude 추가 (이때 appset **finalizer 없음** → 제거는
   non-cascading → 네임스페이스 리소스 보존).
2. `root/apps/namespaces.yaml` 수동 Application 추가(project=platform, sync-wave -9, **resources-finalizer
   없음**, SSA, destination=in-cluster server) → 동일 매니페스트라 기존 네임스페이스를 **adopt**(OutOfSync 0).
   ⚠️ **설계 리뷰 #1**: namespaces app에 finalizer를 주면 안 된다 — 롤백/삭제 시 finalizer가 Namespace를
   prune해 **전 네임스페이스+워크로드를 cascade 삭제**(appset 경로에서 막은 함정의 재도입). Namespace는
   cascade가 절대 금지라 Application 삭제 시 **orphan-retain**(네임스페이스 보존)이 안전. 이 불변식은 §D
   가드가 강제.
3. **그 다음 sync에서야** appset에 finalizer 추가(§D).

### D. appset resources-finalizer + exclude 가드

- 두 appset 템플릿 `template.metadata`에 `finalizers: [resources-finalizer.argocd.argoproj.io]` —
  teardown 시 워크로드 cascade prune. **namespaces가 appset에서 빠진 뒤에만**(§C 이후).
- 신규 bats: root/apps의 각 `platform/*/prod` 경로가 appset `exclude`로 커버되는지(이중소유 차단) +
  `docs/traps.md` 원장 1행(`make verify-traps`가 가드 소실 차단).
- 신규 bats(**설계 리뷰 #1**): **Namespace 리소스를 소유하는 Application은 resources-finalizer를
  갖지 않는다** — root/apps의 각 Application을 `kustomize build`해 산출물에 `kind: Namespace`가 있으면
  그 Application manifest에 `resources-finalizer.argocd.argoproj.io`가 없어야 함. appset finalizer 추가가
  Namespace 소유 경로에 cascade를 재도입하지 못하게 차단.
- 신규 bats(**설계 리뷰 #3**): default-project lockdown — ① **`project: default`는 오직 argocd·root만**
  (다른 root/apps Application·두 appset 템플릿이 default를 쓰면 실패) + ② projects.yaml의 `apps` 프로젝트가
  `clusterResourceWhitelist: []`(비움)·destinations namespace=prod·namespaceResourceWhitelist 존재를
  유지하는지 핀(AppProject 약화/광역화를 CI로 차단). default escape hatch + 프로젝트 약화 봉쇄.

## 배포 시퀀스 — 3개 순차 머지 + 라이브 게이트 (안전 핵심)

finalizer-vs-namespaces 레이스 때문에 **단일 PR 불가**. 각 머지 후 ArgoCD 전체 Synced/Healthy
확인 후 다음(이 레포의 검증된 "2-PR 하드닝 패턴" 계열):

1. **머지1**: AppProject 2개 + 프로젝트 재배정 + platform 파생-가드. → 전 Application Healthy.
2. **머지2**: namespaces exclude + 수동 namespaces Application adopt (appset 아직 finalizer 없음).
   → namespaces 소유 이전·전체 Healthy.
3. **머지3**: appset finalizer + exclude 가드 + traps 원장. → Healthy.

executing-plans는 워크트리 feature 브랜치에 3개 배치로 커밋하고, 라이브 게이트(머지 후 ArgoCD
Healthy 확인)는 각 배치 사이에 둔다.

## 테스트·검증

**정적(gate)**
- projects.yaml 렌더(kustomize/kubeconform) 통과.
- platform 파생-가드 bats(#2): 모든 platform 컴포넌트의 **렌더 리소스 namespace** ∈ project destinations,
  helm repoURL ∈ sourceRepos (`kustomize build` 기준, Application destination.namespace 아님).
- apps 프로젝트 namespaceResourceWhitelist가 차트 방출 kind를 전수 포함하는지 bats.
- exclude⊇root/apps bats.
- Namespace 소유 Application no-finalizer bats(#1).
- default-lockdown bats(#3): argocd·root만 default + apps 프로젝트 핵심 제약(빈 clusterResourceWhitelist·
  destinations=prod) 핀.
- test_root_app.bats 갱신(root·argocd만 default).

**라이브(머지별)**
- `kubectl get applications -A` 전부 Synced/Healthy.
- `kubectl get appproject -n argocd` 존재 + Application `.spec.project` 반영.
- 머지2: namespaces 소유가 namespaces-prod(appset) → 수동 namespaces app으로 이전, 네임스페이스
  무중단 유지 확인.

## 동작 비파괴·롤백

- AppProject·finalizer·가드 전부 가산 → 화이트리스트 전수커버 시 워크로드 무변경.
- 롤백: project 되돌림 1줄 / appset finalizer 제거 / 수동 namespaces app 되돌림(finalizer 없어
  **non-cascading** — 네임스페이스 retain, 안전) — 각 머지 독립 가역.
- 최대 위험점 = 머지2의 namespaces adopt(매니페스트 불일치 시 OutOfSync) → 머지 전 `kustomize build`
  render diff로 namespaces-prod와 수동 app 산출물 동일성 확인 게이트.

## 설계 리뷰 (Phase A.5, codex --kind design)

1회 적대적 설계 리뷰(`ok:true`·`planInDiff:true`·`needs-attention`, 3 plan finding) — 3건 모두 Accept·반영:
- **#1 (critical)**: namespaces 수동 Application의 finalizer가 롤백 시 cascade 삭제 → finalizer 제거 +
  Namespace-소유 Application no-finalizer 가드(§C-2·§D).
- **#2 (high)**: platform 경계가 잘못된 레이어(appset Application destination.namespace는 비어있음) →
  rendered-manifest namespace 기준 파생·가드(§A).
- **#3 (high)**: default 프로젝트 잔류가 steady-state escape hatch → "argocd·root만 default" +
  apps 프로젝트 약화 금지 가드(§D). (root를 별도 control-plane 프로젝트로 이전하는 무거운 안은
  부트스트랩 chicken-egg 회피 위해 보류 — 가드가 비례적 봉쇄.)

## 범위 밖 (후속 plan)

- 항목5: 데이터 리소스(data-conn/cnpg/cache) per-app ApplicationSet 전환 — provision-db/cache.ts
  출력 경로 변경 동반(L, 별도 표면).
- 항목6: targetRevision 롤백 SSOT — iac/bump-poll 자동화 가정과 충돌 가능성, 설계 검토 필요(L).
- 테마2~8.
