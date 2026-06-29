# 홈랩 의존성 전면 업그레이드 캠페인 — 구현 계획

> **For Claude:** REQUIRED SUB-SKILL: `superpowers:executing-plans`로 이 계획을 배치별로 실행하라.

**Goal:** 단일노드 k3s·PR-first·ArgoCD GitOps 홈랩의 전 스택 의존성을 의존성 순서·배치간 라이브 검증 게이트로 안전하게 최신화한다.

**Architecture:** 코드 작성이 아니라 **pre-merge 게이트 → PR → required `gate` 통과 → 머지 → ArgoCD 싱크 → post-merge 라이브 검증 게이트 → 다음 배치**의 연속이다. 14개 배치(B0~B13)를 8 wave로 그룹화. Renovate 하이브리드(단순 bump은 대시보드 #92 rate-limited PR, 결합·수동핀은 직접 PR).

**Tech Stack:** k3s·ArgoCD·Helm(kustomize HelmChartInflationGenerator)·CNPG·Traefik+Gateway API·VictoriaMetrics 스택·KSOPS/SOPS·Renovate.

**설계 SSOT:** `docs/plans/2026-06-29-homelab-upgrade-campaign-design.md` (A.5 적대 리뷰 3건 반영본).

---

## 실행 규약 (모든 배치 공통)

- **라이브 접근:** `export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig` (post-merge 검증 전 설정).
- **★Canonical 순서(C-pass1-F2 — 전 라이브 배치 불변):**
  1. **Pre-merge 게이트**(머지 전, PR diff/로컬로 검증 가능): baseline 캡처 · static/render 검사(`make chart-test`·`kustomize build`) · (위험 배치) 백업/복구지점 확보·증명. CI 전용 배치(B0·B2)는 여기서 끝(required `gate`가 검증).
  2. **PR → required `gate` green → 머지.**
  3. **Post-merge 라이브 게이트**(머지+ArgoCD 싱크 **후에만**): 라이브 health·기능 검증.
  - **수동 라이브 apply 금지** — 라이브 상태 변경은 오직 GitOps(머지→싱크) 경로로. 유일 예외 = 문서화된 롤백.
- **브랜치/PR:** 각 배치 = 전용 브랜치 `chore/upg-Bxx-<slug>` → PR → `gate` green → 머지. 직접 main push 금지(보호).
- **커밋:** 한국어 conventional(`chore`/`fix`/…), AI 마커 금지.
- **Renovate force-create:** 대시보드 #92 해당 rate-limited 체크박스 체크해 PR 생성 → 리뷰 → 머지. **중복 생성 금지** — 기존 PR(#90 digests·#91 adguard·#130 local-path·#131 valkey) 재사용.
- **STOP 규칙(executing-plans):** pre-merge 증명 실패·post-merge 검증 실패·dr-drill 실패·`/readyz` 미응답·모호한 상태 = genuine blocker → 정지하고 owner 확인. 배치 검증 통과 전 다음 배치 금지.
- **메모리 원장:** limit 변동 시 `docs/memory-ledger.md`(≤9216Mi) 산문+행 동반 갱신(`bun run verify:ledger`).
- **롤백 기본:** PR revert → ArgoCD 재싱크. 단 B5/B6/B7/B8/B9/B13은 배치별 **롤백 예외**(A.5) 따름.

---

## Wave 0 — 게이트 안전 선행

### Task B0: conftest 0.56.0 → 0.68.2 (+ Rego v1 마이그레이션 선행)

**이유:** conftest 0.68은 OPA v1/Rego v1 기본. `policy/`가 구 구문이면 bump 즉시 `make verify` conftest 게이트 + `verify:ledger` 즉사 → 이후 전 PR이 gate 통과 불가. 최우선. (CI 전용 — 라이브 무영향, 검증=required gate.)

**Files:** Modify `policy/*.rego` · `.github/actions/setup-toolchain/action.yml:52-58`. Test: `make verify`·`bun run verify:ledger`.

**Step 1 (pre-merge — 현 구문 파악):** `ls policy/ && cat policy/*.rego` — `import rego.v1`/`if`/`contains` 유무. `make verify` 현 PASS 기록(green 출발).

**Step 2 (apply — Rego v1):** 각 `policy/*.rego`에 `import rego.v1` + `if`/`contains` 구문(`deny[msg]{…}`→`deny contains msg if {…}`). `conftest verify --policy policy/`로 양립 확인(안 되면 `--rego-version v0` 단계 분리).

**Step 3 (apply — conftest 핀):** URL `v0.68.2/conftest_0.68.2_Linux_arm64.tar.gz`. sha256 재산출: `curl -fsSL <URL> | sha256sum` → 매니페스트 라인 갱신.

**Step 4 (pre-merge 검증):** conftest 0.68 로컬 설치 후 `make verify`+`verify:ledger`+`test_toolchain-checksums.bats` PASS. (CI `gate`가 동일 검증 — 머지 전 통과.)

**Step 5 (PR+머지):** `chore/upg-B0-conftest-rego-v1`.

**롤백:** CI 도구(라이브 무영향) → PR revert.

---

## Wave 1 — 저위험 이미지/차트 패치 (Renovate 활용)

### Task B1: 저위험 image/chart 마이너 + 보안 패치 배치

**대상(각 PR, force-create/기존 재사용):** 관측 마이너(VM/vmagent/vmalert `v1.145.0`·victoria-logs `v0.42.0`*마이너만*·node-exporter `v1.11.1`·kube-state-metrics `v2.19.1`·alertmanager `v0.33.0`·grafana 마이너) · skopeo `v1.22.2`·whoami `v1.11.0`·yq image `v4.53.3`·busybox `v1.38`·adguard(#91)·digests(#90) · **CNPG postgresql `16.4→16.14`**(CVE, 동일 메이저 — cluster.yaml·basebackup-cronjob.yaml·restore-drill-script.sh 일관) · cloudflared·**local-path #130**·valkey #131. (cloudflare TF provider는 B1T로 분리.)

**Step 1 (pre-merge baseline):** `export KUBECONFIG=…` → `kubectl get applications -n argocd` 전 앱 Synced/Healthy 기록.

**Step 2 (apply):** 대시보드 force-create / 기존 PR 리뷰.

**Step 3 (머지):** 각 PR `gate` green 후 머지(image 다수 묶기 가능).

**Step 4 (post-merge 라이브 검증):** ArgoCD 싱크 후 ① 전 앱 Synced+Healthy ② VM 타겟 up·VictoriaLogs 질의·vmalert 룰 로드·`bash tests/gates/alertmanager-render-e2e.sh`·telegram 실송 1회 ③ CNPG 파드 Running+로그인.

**롤백:** image 태그 revert → 재싱크(상태 무변경).

### Task B1T: Terraform cloudflare provider 5.20.0 → 5.21 (IaC 별도 게이트, C-pass2-F2)

**이유:** Terraform은 ArgoCD 밖 — provider bump은 k8s health로 검증 불가. 스키마/lock 회귀가 머지 후 `iac`/`tf-reconcile`에서야 발각되면 public-exposure 자동화가 깨진다. 별도 배치 + IaC 수용 게이트.

**Files:** Modify `infra/cloudflare/.terraform.lock.hcl`(provider 5.21). 제약 `~> 5.0`은 이미 커버 → lock만.

**Step 1 (pre-merge IaC 게이트):** `make tf-validate`(fmt+validate 3 루트) PASS. R2 백엔드로 `infra/cloudflare` `terraform init -upgrade` + **`terraform plan`** → diff가 provider-only(리소스 변경 0)인지 + **destroy-guard 리뷰**(예상치 못한 destroy 0) 확인.

**Step 2 (머지):** `chore/upg-B1T-tf-cloudflare` `gate` green 후. (github/cloudflare 루트는 신뢰앵커 — CI는 plan-only, 무인 apply 금지.)

**Step 3 (post-merge 확인):** `iac.yaml`(push apply) 또는 `tf-reconcile.yaml`(30분 드리프트 수렴) 완료 + Cloudflare state 정합(`terraform plan` clean — DNS/tunnel/R2 무드리프트) 확인.

**롤백:** lock revert → `terraform plan`으로 복귀 확인.

---

## Wave 2 — CI 툴체인 수동 재핀

### Task B2: setup-toolchain 수동 핀 + KSOPS (CI 전용 — 라이브 무영향)

**Files:** Modify `.github/actions/setup-toolchain/action.yml`(helm/kustomize/sops/age/yq-CLI/actionlint/shellcheck URL+sha256) · KSOPS 이미지 핀. Test: `make chart-test`·sops 라운드트립·KSOPS 풀렌더.

**Step 1 (pre-merge baseline):** 현 `make chart-test` green + `kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/<comp>/prod` 1개 성공 기록.

**Step 2 (apply, 항목별 sha256 재산출):** helm `v3.21.2`·kustomize `v5.8.1`(5.8.0 회피)·sops `v3.13.1`·age `v1.3.1`·yq CLI `v4.53.2`·actionlint·shellcheck 최신. 각 `curl|sha256sum` 재산출. KSOPS `v4.5.1`.

**Step 3 (pre-merge 검증):** `make chart-test` PASS · **sops 라운드트립 + 실 `*.enc.yaml` 1개 복호화**(DR 자산, 값 미출력) · 전 KSOPS 컴포넌트 `kustomize build` 렌더 회귀 0 · `test_toolchain-checksums.bats` PASS. (CI `gate`가 동일 검증.)

**Step 4 (PR+머지):** `chore/upg-B2-ci-toolchain`.

**롤백:** CI 도구(라이브 무영향) → revert. sops는 머지 전 라운드트립 필수.

---

## Wave 3 — 시크릿/인증서

### Task B3: sealed-secrets 2.19.0 + kubeseal 0.38.1 (lockstep)

**Files:** Modify `platform/sealed-secrets/prod/helmrelease.yaml:9`(`2.18.6→2.19.0`) · `.github/actions/setup-toolchain/action.yml:84-92`(kubeseal `0.37.0→0.38.1` URL+sha256). 한 PR(controller↔CLI lockstep).

**Step 1 (pre-merge):** `kubectl get applications -n argocd sealed-secrets-prod` Healthy + 기존 SealedSecret 1개 정상 복호화 기록. `image.registry` bitnami-labs→bitnami 경로 변동·prometheusRule 중복 점검. `make chart-test` 렌더.

**Step 2 (apply):** version + kubeseal 핀+sha256(한 PR).

**Step 3 (머지):** `gate` green 후.

**Step 4 (post-merge 라이브 검증):** 싱크 후 ① controller v0.38.1 Running ② 새 테스트 시크릿 `kubeseal` 봉인→적용→복호화 성공 ③ 기존 SealedSecret 재복호화 정상(restricted PSA 무해).

**롤백:** 차트 version revert. **kubeseal 단독 bump 금지**(lockstep).

### Task B4: cert-manager v1.16.5 → v1.20.3

**Files:** Modify `platform/argocd/root/apps/cert-manager.yaml:15`(`v1.16.5→v1.20.3`).

**Step 1 (pre-merge):** `kubectl get certificate -A` 상태·만료일 기록. ★1.18 RotationPolicy Never→Always·1.20 UID 65532·CRD 변경 동반 가능 → `installCRDs`/CRD 경로 확인(1.19.0 재발급 버그 → 1.20.3 직행 통과).

**Step 2 (apply):** targetRevision 갱신.

**Step 3 (머지):** `gate` green 후.

**Step 4 (post-merge 라이브 검증):** 싱크 후 ① cert-manager v1.20.3 Running ② 테스트 Certificate 발급·갱신 동작 ③ 기존 인증서 유효성 유지.

**롤백 예외(A.5):** RotationPolicy 상태 변경 → revert 후 인증서 상태 수동 확인.

---

## Wave 4 — 데이터/DR (crown-jewel ★)

> **추적된 dr-drill 실행체(C-pass1-F1):** `platform/cnpg/prod/restore-drill-script.sh`가 **git-추적**된다 — fresh executor가 읽고 실행 가능. (`docs/runbooks/restore.md`는 보충 내러티브로 로컬 전용이므로 검증 게이트로 의존하지 않는다.)
> **공통 pre-merge(A.5-F2):** B5/B6/B7 각 전에 CRD export(`kubectl get crd <cnpg-crds> -o yaml > /backup/cnpg-crds-$(date +%s).yaml`)·백업 검증 ID 확보.

### Task B5: CNPG operator 0.26.0 → 0.28.3 (1.27→1.29)

**Files:** Modify `platform/argocd/root/apps/cnpg-operator.yaml:19`(`0.26.0→0.28.3`).

**Step 1 (pre-merge):** `kubectl cnpg status <cluster>` 정상·managed-role 로그인 성공·CRD storedVersion 기록. CRD export. `make chart-test` 렌더.

**Step 2 (apply):** targetRevision 갱신.

**Step 3 (머지):** `gate` green 후.

**Step 4 (post-merge 라이브 검증):** 싱크 후 ① operator 1.29 Running ② **managed-role 로그인**(과거 anomaly — 실패 시 클러스터 annotate로 reconcile 트리거) ③ Pooler TLS status ④ CRD storedVersion 정상 전환.

**롤백 예외(A.5-F2):** CRD storedVersion/변환객체 git revert 복구 불가 → 사전 CRD export + downgrade 가부 판정 + out-of-band `kubectl apply`.

### Task B6: barman-cloud plugin 0.12.0 → 0.13.0

**Files (re-vendor — 문서화된 예외, C-pass3-F3):** Replace `platform/cnpg/barman-plugin/manifest.yaml`. ⚠️ AGENTS.md:44상 **벤더 파일이라 직접 편집 금지**(이미지 태그만 손대면 CRD/RBAC/cert가 v0.13.0과 어긋남) — **전체 re-vendor만 허용**. (Renovate ignorePaths라 자동 추적 안 됨.)

**Step 1 (pre-merge):** 최근 백업 성공 시각·`barman_cloud_*` 메트릭 기록. **dr-drill 실행체 존재 가드**: `test -f platform/cnpg/prod/restore-drill-script.sh || STOP`. 스크립트 헤더를 읽어 전제(objectStore·자격) 확인.

**Step 2 (apply — re-vendor 절차):** ① 상류 `cloudnative-pg/plugin-barman-cloud` **v0.13.0 전체 manifest** fetch(`curl -sL <v0.13.0 release manifest URL> -o platform/cnpg/barman-plugin/manifest.yaml`) ② provenance 기록(release URL + sha256를 PR 본문/커밋에) ③ **diff 체크**: `git diff`로 image 태그뿐 아니라 **CRD·RBAC·cert material이 모두 v0.13.0 동일 릴리스에서 교체**됐는지 확인(부분 편집 금지). `make chart-test` 렌더.

**Step 3 (머지):** `gate` green 후.

**Step 4 (post-merge 라이브 검증 — DR 게이트):** 싱크 후 ① plugin 파드 Running ② **dr-drill**: `bash platform/cnpg/prod/restore-drill-script.sh`(추적 스크립트) 실행 → **pass/fail 기준**: throwaway 복구 클러스터가 Healthy 도달 + 샘플 쿼리 행수 일치 + 스크립트 exit 0. ③ 새 백업 생성 확인. (실패 = STOP.)

**롤백 예외(A.5-F2):** plugin CRD(ObjectStore 등) storedVersion 점검 후 revert.

### Task B7: CNPG PostgreSQL 16 → 18 메이저 (in-place) ★CRITICAL

**Files (원자적 — 한 PR, A.5-F1):** Modify `platform/cnpg/prod/cluster.yaml`(`imageName 16.x→18.x`) · `platform/cnpg/prod/basebackup-cronjob.yaml` · `platform/cnpg/prod/restore-drill-script.sh`(imageName). 잔존 검사 스코프는 **런타임 매니페스트만**(C-pass3-F2): `grep -rn "postgresql:16" platform/cnpg/prod/`로 잔존 0. ⚠️ `docs/plans/`(역사 기록 — 수정 금지, 계획 자체가 "postgresql:16"을 언급)·`docs/runbooks/restore.md`(로컬 내러티브 — owner 별도 동기화)는 **게이트에서 제외**.

**▶ Pre-merge 게이트 (머지 전 — 비가역 변경의 안전망, C-pass1-F2 / C-pass2-F1):**
- **Step 1 (백업 증명 + write-freeze + RPO, C-pass4-F1):** ① **유지보수/write-freeze** — 머지 직전 앱 쓰기 중단(maintenance 모드로 라이브 트래픽 차단). ② **WAL/archive 캐치업 검증**(freeze 시점까지 아카이브 완료 확인). ③ 그 시점 **전체 백업 + 백업 검증 ID** 확보 = RPO=freeze 시점 복구 타깃. ④ **쓰기는 PG18 post-merge 검증(health·데이터·새 PG18 백업·PG18 복구 드릴) 전부 통과까지 차단 유지** → 롤백 시 백업 이후 유실 쓰기 0.
- **Step 2 (★올바른 major-upgrade 리허설 — 필수):** ⚠️ 물리 백업은 **동일 메이저 전용** — PG16 물리 백업을 PG18로 직접 부트스트랩 불가(cross-major physical restore 금지). 따라서 지원되는 경로를 리허설한다: ① `platform/cnpg/prod/restore-drill-script.sh`로 백업을 **throwaway PG16 클러스터**에 복구 → ② 그 throwaway에서 **CNPG가 지원하는 major-upgrade(declarative imageCatalog major upgrade / pg_upgrade, CNPG 1.29 문서 절차)로 PG18 리허설** → ③ 데이터 무결성(행수·체크섬) 검증. **pass/fail**: PG18 리허설 클러스터 Healthy + 데이터 일치 → 통과해야만 진행. **실패 시 STOP**(머지 금지). **PG16 복구본은 롤백 경로로 보존.**
- **Step 3 (static):** 모든 PG 이미지 소비자 18 일관 — `grep -rn "16\.\(4\|14\)" platform/cnpg/` 잔존 0. `make chart-test` 렌더. CNPG declarative major upgrade 방식(imageCatalog/major) 확인(CNPG 1.29 문서).

**▶ 머지:** `chore/upg-B7-postgres-18` PR → `gate` green 후 머지. **수동 라이브 apply 금지** — PG18 전환은 오직 머지→ArgoCD 싱크로.

**▶ Post-merge 라이브 게이트 (머지+싱크 후에만):**
- **Step 4:** ArgoCD 싱크 완료 → 클러스터 PG18 Running.
- **Step 5:** 로그인·쿼리(데이터 무결성) · 백업 생성 · **PG18 백업에서 throwaway 복구 검증**까지 통과해야 **완료 선언**.

**롤백 예외(A.5-F1/C-pass4-F1):** in-place라 **revert 불가**. 유일 안전망 = pre-merge Step 1~2의 **write-freeze 시점 백업(RPO)** + PG18 복구 증명. 쓰기가 freeze로 차단된 상태라 백업 복원 시 유실 0. 실패 시 그 백업으로 PG16 복원.

---

## Wave 5 — GitOps 컨트롤플레인 ★

### Task B8: argo-cd 7.7.11 → 10.0.0 (단계적 7→8→9→10)

**Files (메이저별, C-pass3-F1):** Modify `platform/argocd/argocd-app.yaml:15`(**라이브 self-managed 핀 `targetRevision: 7.7.11`→메이저 — ArgoCD가 *실제 싱크*하는 버전. CHART_VERSION만 바꾸면 라이브는 7.7.11에 머물러 게이트가 일어나지 않을 업글을 대기**) · `platform/argocd/bootstrap-values.yaml`(values: `global.networkPolicy.create:false`·`configs.params` 재작성·RBAC) · `platform/argocd/CHART_VERSION`(bootstrap 메타·Renovate 추적 — 라이브 핀과 동기화).

**Step 1 (pre-merge — A.5-F2 / C-pass4-F2 필수):** **hop별 known-good 렌더**(7.7.11 하드코딩 금지 — values가 hop마다 재작성됨): 각 메이저 hop 직전 **현재 라이브 차트 버전 + 현 values**로 렌더 `helm template argo-cd --repo https://argoproj.github.io/argo-helm --version <현-라이브-버전> -f platform/argocd/bootstrap-values.yaml > /backup/argocd-known-good-<현버전>.yaml` → dry-run(`kubectl apply --dry-run=server -f …`)로 유효성 확인. **롤백 타깃 = 직전 검증된 메이저**(7.7.11 전체 복귀 아님 — 9/10 실패 시 이미 적용된 CRD/리소스 마이그레이션 충돌 회피). out-of-band 복구·ArgoCD 부재 시 수동 bootstrap 문서화. **★렌더 가드(F1):** ArgoCD 싱크 버전이 목표 메이저인지 `argocd-app.yaml` targetRevision 기준 확인. `make chart-test`·`test_argocd_values.bats`.

**Step 2 (apply, 메이저당 1 PR):** 7→**8**(상류 v2.14→v3.0: RBAC 상속·`logs` 리소스·server-side diff 기본) → 8→**9**(`configs.params` 하위키 제거 → params 재작성·`applicationsetcontroller.policy` 기본 변경) → 9→**10**(★`global.networkPolicy.create` 기본 false→true → **명시 `false`**).

**Step 3 (머지):** 메이저별 `gate` green 후.

**Step 4 (post-merge 라이브 검증, 각 메이저 후):** 싱크 후 ① ArgoCD 자체 Healthy·자기-sync 정상 ② RBAC(로그인·권한) ③ UI(`argocd.home.ukyi.app`) ④ 전 앱 Synced 유지.

**롤백 예외(A.5-F2/C-pass4-F2):** ArgoCD self-managed → 실패 시 revert sync 주체 부재 → **out-of-band `kubectl apply -f /backup/argocd-known-good-<직전 검증 메이저>.yaml`**(hop별 아티팩트 — 7.7.11 아님).

---

## Wave 6 — 엣지/라우팅 ★

### Task B9: traefik 33 → 41 + gateway-api CRD v1.2 → v1.5.1 (동반, 한 PR)

**Files:** Modify `platform/traefik/prod/helmrelease.yaml:7`(`33.0.0→41.0.0`) · `values-traefik.yaml`(리네임) · `gateway-api-crds.yaml`(v1.5.1 재벤더링) · `kustomization.yaml` 주석.

**Step 1 (pre-merge):** gateway-api CRD storedVersion·현 Gateway/HTTPRoute 라우팅(내부/외부) 기록. CRD 재벤더링: `curl -sL https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml -o platform/traefik/prod/gateway-api-crds.yaml`. values 리네임(`logs.general`→`log`·`logs.access`→`accessLog`·필터 camelCase·`providers.file.content` object). v40.2+ 차트 GW CRD 미제공 → 벤더링 CRD SSOT 정합. `make chart-test` 렌더.

**Step 2 (머지):** `chore/upg-B9-traefik-gatewayapi` `gate` green 후.

**Step 3 (post-merge 라이브 검증):** 싱크 후 ① traefik v3.7 Running ② Gateway/HTTPRoute Programmed ③ 내부(`*.home.ukyi.app`)·외부 노출 e2e(실 HTTP) ④ `make verify-posture`.

**롤백 예외(A.5-F2):** gateway-api CRD storedVersion 전환 → git revert가 변환객체 복구 못함 → out-of-band CRD apply.

---

## Wave 7 — 관측 메이저

### Task B10: VictoriaLogs 0.x → 1.x

**Files:** Modify victoria-logs 이미지(`platform/victoria-stack/prod/*.yaml`) `v0.42.0→v1.x`.

**Step 1 (pre-merge):** 현 LogsQL 쿼리(Grafana 패널·vmalert 룰) 목록·동작 기록. ★LogsQL filter-pipe 구문 변경(`foo | bar`→`foo bar`) → 쿼리 점검·수정(같은 PR). **★영속 데이터 롤백 준비(C-pass4-F3):** VictoriaLogs는 영속 StatefulSet(hostPath/PVC) — 0.x↔1.x 온디스크 포맷 비호환 시 PR revert 무력. 머지 전 ① 데이터 디렉토리(hostPath `/var/lib/...` 또는 PVC) **스냅샷/export** ② 0.x↔1.x 스토리지 호환 문서 확인 **또는** throwaway downgrade 리허설 ③ 로그 이력 유실 허용 여부 owner 결정. `make chart-test`.

**Step 2 (머지):** `gate` green 후.

**Step 3 (post-merge 라이브 검증):** 싱크 후 VictoriaLogs v1 Running·로그 수집·질의·Grafana 로그 패널·vmalert 룰 정상.

**롤백(F3):** 온디스크 비호환 가능 → PR revert만으론 불충분. Step 1 스냅샷 복원, 또는 (유실 허용 시) 데이터 디렉토리 초기화 후 0.x 복귀.

### Task B11: Grafana 11 → 12 → 13 (단계적)

**Files:** Modify grafana 이미지(`platform/victoria-stack/prod/*.yaml`)(메이저별).

**Step 1 (pre-merge):** 대시보드·플러그인 목록 기록. 11→12 Angular 플러그인 기본 비활성 → 사용 플러그인 점검.

**Step 2 (머지):** 메이저별 `gate` green 후.

**Step 3 (post-merge 라이브 검증):** 싱크 후 대시보드 렌더·데이터소스·로그인 정상.

### Task B12: vector 0.41 → 0.55

**Files:** Modify vector 이미지(`platform/victoria-stack/prod/*.yaml`) + 필요 시 `docs/memory-ledger.md`.

**Step 1 (pre-merge):** vector working_set·로그 흐름 기록(OOM 이력). pre-1.0 14단계 — upgrade guide 경유 config 호환 점검. `bash tests/gates/vector-validate.sh`.

**Step 2 (머지):** `gate` green 후.

**Step 3 (post-merge 라이브 검증):** 싱크 후 ① vector Running ② 로그 수집 정상 ③ **working_set 재측정** → limit 대비 → 원장 갱신(필요 시 별도 PR).

---

## Wave 8 — k3s 마이너 (owner-local ★ 최고 위험)

### Task B13: k3s 1.31 → 1.36.1 (단계적, 마이너별)

**Files:** Modify `infra/k3s-bootstrap/versions.env:6`(`K3S_VERSION`, 마이너별).

> ★owner-local(ArgoCD 아님). k3s control-plane은 GitOps 밖 — versions.env PR 머지 후 owner가 인스톨러 재실행이 실제 라이브 변경. **executing-plans는 각 마이너에서 정지**(owner 수행 필요).

**마이너별 반복(1.32→1.33→1.34→1.35→1.36.1):**

**Step 1 (사전 복구지점 — A.5-F3 필수, 머지/재시작 전):** ① k3s sqlite/state 백업 **또는** OrbStack VM 스냅샷 ② 이전 버전 재설치 경로(현 값 보존) ③ API 제거 점검(예: 1.32 `flowcontrol.apiserver.k8s.io/v1beta3`) 사용처 grep.

**Step 2 (apply+머지):** `versions.env` K3S_VERSION을 다음 마이너 최신 패치로 → PR → `gate` green → 머지.

**Step 3 (owner 인스톨러 재실행):** owner-local `k3s-install.sh` 재실행(control-plane 짧은 재시작).

**Step 4 (검증 — stop-rule):** 재시작 후 `/readyz` 기대 시간 내 200 확인. **미응답 시 즉시 Step 1 스냅샷/이전버전 복원(STOP).** 전 워크로드 Healthy: `kubectl get nodes`(Ready)·`kubectl get applications -n argocd`(전 Synced/Healthy)·핵심 파드 Running.

**Step 5:** 다음 마이너로(전체 검증 통과 후에만).

**롤백 예외(A.5-F3):** host-state 실패는 PR revert 무력 → Step 1 복구지점 복원.

---

## 완료 기준

- B0~B13 전 배치 머지 + post-merge 라이브 검증 게이트 통과
- 전 ArgoCD Application Synced/Healthy · dr-drill PASS(B6/B7 후) · 원장 정합 · #92 해당 항목 소진

## 메모

- node24(#143)·tailscale(#144)는 범위 밖(분리 PR).
- 라이브 상태 변경은 GitOps 경로만(수동 apply 금지, 롤백 예외). 단일노드라 동시 다발 머지 금지.

---

## Adversarial review dispositions (감사 기록 — post-approval, 재리뷰 안 함)

hardened-planning Phase C: working-tree 모드, 총 **4 pass**(3 캡 + 사용자 승인 1). 설계는 A.5에서 별도 1 pass. **총 12 발견 전부 Accepted·반영.**

**A.5 설계 리뷰 (codex, needs-attention):**
- F1 (CRITICAL) PG18 백업 안전망 비원자적 → **Accepted** — B7 원자적 경계 + PG18 복구 증명
- F2 (HIGH) ArgoCD/CRD revert 무력 → **Accepted** — B5/B6/B8/B9 out-of-band·storedVersion
- F3 (HIGH) k3s host-state 복구지점 부재 → **Accepted** — B13 사전 스냅샷 + `/readyz` stop-rule

**C pass 1 (needs-attention):**
- HIGH DR 로컬 런북 의존 → **Accepted** — 추적 `restore-drill-script.sh` 참조 + 인라인 pass/fail
- HIGH 라이브 검증이 머지 전 → **Accepted** — canonical pre/post-merge 분리

**C pass 2 (needs-attention):**
- CRITICAL B7 cross-major 물리복구 오류 → **Accepted** — PG16 복구→pg_upgrade 리허설로 교정
- HIGH cloudflare TF IaC 게이트 부재 → **Accepted** — B1T 분리 + tf-validate/plan

**C pass 3 (needs-attention):**
- HIGH B8 라이브 핀 아닌 bootstrap 수정 → **Accepted** — `argocd-app.yaml` targetRevision
- HIGH B7 grep 역사문서 스코프 → **Accepted** — 런타임 경로 한정
- HIGH B6 금지 벤더 manifest 편집 → **Accepted** — re-vendor 절차

**C pass 4 (needs-attention — 최종 pass):**
- HIGH PG18 write-freeze/RPO 부재 → **Accepted** — write-freeze + WAL 캐치업 + RPO
- HIGH ArgoCD 롤백 7.7.11 하드코딩 → **Accepted** — hop별 known-good 렌더
- MED VictoriaLogs PVC 롤백 부재 → **Accepted** — PVC 스냅샷 + 호환 게이트

**최종 상태:** 최종 pass(4) verdict=`needs-attention`, summary="unsafe rollback gaps for highest-risk stateful/control-plane upgrades". 그 3건도 반영했으나 **재리뷰 없이** 사용자가 Phase D 확정(한계효용 감소·correctness 버그는 pass2에서 수렴·실행 배치 게이트가 추가 방어). 잔여 리스크는 실행 시 각 배치 라이브 게이트가 흡수.

## Execution directives

- **Skill:** `superpowers:executing-plans`로 **별도 세션, 이 워크트리(`worktree-upgrade-campaign`)에서** 구현.
- **연속 실행:** 배치 사이 루틴 리뷰로 멈추지 말 것. 단 **genuine blocker**에서만 정지 — 누락 의존성·반복 실패 검증·모호/모순 지시·critical 계획 갭, 그리고 **이 계획의 STOP 규칙**(라이브 검증/dr-drill 실패·`/readyz` 미응답·write-freeze 미해제·증명 실패).
- **커밋 — 직접 적용, `Skill(commit)` 호출 금지**(대화형 확인이 연속 실행을 깸):
  - **언어:** 한국어 메시지. **AI 마커 금지**(`🤖`·`Co-Authored-By` 등).
  - **형식:** `<type>(<scope>): 한국어 설명` (+ `- 상세` 본문).
  - **type:** `feat`/`fix`/`refactor`/`docs`/`style`/`test`/`chore`만(`perf`/`build`/`ci` 등 금지).
  - **그룹:** 같은 배치/목적 함께, 독립 설명 가능한 변경은 분리.
  - **위치:** 현 워크트리 브랜치에 직접(이미 main 밖).
- **PR-first:** 각 배치 = 별도 브랜치+PR(계획 규약). 단일노드 라이브라 배치 간 라이브 검증 게이트 통과 후 다음 — 동시 다발 머지 금지.
