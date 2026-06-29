# 홈랩 의존성 전면 업그레이드 캠페인 — 설계

- **날짜**: 2026-06-29
- **상태**: 설계 승인됨 (Phase A) + A.5 적대 리뷰 3건 수용·반영(CRITICAL 1·HIGH 2) → Phase B(계획) 대기
- **방법론**: hardened-planning (brainstorming → 적대 리뷰 → executing-plans 핸드오프)

## 1. 목표 & 범위

단일노드 k3s·PR-first·ArgoCD GitOps 홈랩의 **전 스택 의존성을 안전하게 최신화**한다. 2026-06-29 의존성 검토(웹 검증 워크플로 7 에이전트 + 컨테이너 이미지 리서치 + Renovate Dependency Dashboard #92)에서 식별된 모든 업그레이드를 대상으로 한다.

**범위 내**: 검토의 🟢(저위험 패치/보안) + 🟡(메이저/파괴위험) 전부 + 사용자 추가 지정 gateway-api CRD·CNPG PostgreSQL 메이저.

**범위 밖(이미 별도 PR)**:
- GitHub Actions node20→node24 런타임 전환 + node 24.14.0 — **PR #143**
- tailscale operator 차트 1.78.1→1.98.4 — **PR #144**
- `homelab` 호스트 tailscale 클라이언트 1.98.5 — owner-local(repo IaC 밖)

## 2. 핵심 결정 (사용자 승인)

| 결정 | 선택 | 근거 |
|---|---|---|
| **k3s 타깃** | 단계적 → **v1.36.1** | 1.31 업스트림 EOL. 5 마이너를 한 번에 스킵 불가 → 마이너별 단계 업글 + API 제거 점검 |
| **CNPG PostgreSQL** | **18** (operator 1.29 페어링) | CNPG 1.29 기본 PG가 18 → operator·PG 정렬, 미래 작업 최소화. in-place major upgrade |
| **실행 모델** | **단계적 배치 + 배치간 라이브 검증 체크포인트** | 단일노드 라이브 안전. 각 배치 머지 후 검증 통과해야 다음 |
| **Renovate 경계** | **하이브리드** | 단순 image/chart는 Renovate rate-limited PR 활용, 결합·복잡·수동핀은 직접 PR |

## 3. 실행 모델 (GitOps PR-머지-검증 사이클)

이 캠페인은 코드 작성이 아니라 **라이브 GitOps 클러스터에 대한 PR-머지-검증 사이클의 연속**이다. 각 배치:

```
파일 편집(또는 Renovate PR force-create) → PR → required `gate` 통과 → 머지 → ArgoCD 싱크 → 라이브 검증 게이트 통과 → 다음 배치
```

executing-plans는 각 **라이브 검증 체크포인트에서 정지**한다(owner가 KUBECONFIG로 클러스터 health/기능을 확인). 검증 실패 = genuine blocker → 정지. 이는 단일노드 안전을 위한 의도된 stop-point다.

`export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig` 로 라이브 접근.

## 4. Renovate 하이브리드 경계

- **Renovate 활용(force-create 또는 기존 PR 재사용)**: 단순 image 태그·차트 마이너·TF lock·k3s/local-path/busybox. 대시보드 #92의 rate-limited 체크박스로 생성. **중복 생성 금지** — 이미 열린 PR(#130 local-path, #131 valkey, #90 digests, #91 adguard)은 재사용.
- **직접 PR(수동 편집)**: ① setup-toolchain 수동 핀(conftest/helm/kustomize/sops/age/kubeseal/yq-CLI/actionlint/shellcheck — Renovate 미관리, sha256 재산출 필요) ② 결합 항목(traefik+gateway-api, sealed-secrets+kubeseal, CNPG operator+PG18+barman) ③ values 리네임/RBAC 재작성 동반(traefik 41, argo-cd 10) ④ Rego v1 마이그레이션.

## 5. 배치 시퀀스 (8 wave · 14 배치)

> 원칙: **게이트 안전 선행 → 저위험 신뢰 구축 → 의존성 순서 메이저(시크릿→인증서→데이터/DR→컨트롤플레인→엣지→관측메이저→k3s 마지막)**.

### Wave 0 — 게이트 안전 선행
- **B0**: `policy/` Rego를 v1 구문(`if`/`contains`)으로 마이그레이션 **선행**(OPA v0/v1 양립 확인) → conftest 0.56.0→0.68.2 + sha256 재산출. **이유**: conftest 0.68이 Rego v1 기본 → 마이그레이션 없이 bump하면 `make verify` conftest 게이트 + `verify:ledger` 즉사. 이후 모든 PR이 gate를 통과해야 하므로 최우선.
  - 검증: `make verify`·`verify:ledger` green.

### Wave 1 — 저위험 이미지/차트 패치 (Renovate 활용)
- **B1**: 관측 마이너(victoria-metrics/vmagent/vmalert 1.145·victoria-logs 0.42 *마이너만*·node-exporter 1.11.1·kube-state-metrics 2.19.1·alertmanager 0.33.0·grafana *마이너만*)·skopeo 1.22.2·whoami 1.11.0·yq image 4.53.3·busybox 1.38 pin·adguard(#91 digest)·**CNPG postgresql 16.4→16.14**(보안 CVE 11건, 동일 메이저)·cloudflare TF 5.21·cloudflared·**local-path #130**·**valkey #131**·image digests(#90).
  - 검증: ArgoCD 전 앱 Healthy + 관측 메트릭/로그/알림 흐름 + `alertmanager-render-e2e`(telegram).

### Wave 2 — CI 툴체인 수동 재핀
- **B2**: setup-toolchain helm 3.21.2·kustomize 5.8.1(5.8.0 회귀 회피)·sops 3.13.1·age 1.3.1·yq CLI 4.53.2·actionlint·shellcheck + **sha256 재산출**(`test_toolchain-checksums.bats` 강제) · KSOPS 이미지 4.5.1.
  - 검증: `make chart-test`(helm/kustomize 렌더)·**sops 라운드트립(DR 자산)**·KSOPS `kustomize build --enable-helm --enable-alpha-plugins --enable-exec` 전 컴포넌트 풀렌더 + 실 `*.enc.yaml` 복호화.

### Wave 3 — 시크릿/인증서
- **B3**: sealed-secrets 차트 2.18.6→2.19.0 **+ kubeseal CLI 0.37.0→0.38.1 lockstep**(한 PR). 검증: 실 seal/unseal 호환 + restricted PSA securityContext 무해 + prometheusRule 중복 확인.
- **B4**: cert-manager v1.16.5→v1.20.3(최소 1.20.3 — HIGH CVE GHSA-8rvj-mm4h-c258). ★RotationPolicy Never→Always·UID 65532 변경. 검증: 인증서 재발급/갱신 동작.

### Wave 4 — 데이터/DR (crown-jewel ★)
- **B5**: CNPG operator 0.26.0→0.28.3(1.27→1.29). 검증: **managed-role 로그인**(과거 비번 미적용 anomaly 이력)·Pooler TLS. ★롤백 예외(A.5-F2): CRD `storedVersion`/변환객체는 git revert로 안전 복구 불가 → 사전 CRD export + downgrade 가부 판정 + out-of-band `kubectl` apply 경로.
- **B6**: barman-cloud plugin 0.12.0→0.13.0. 검증: **dr-drill 백업/복구**. ★롤백 예외(A.5-F2): plugin CRD(ObjectStore 등) storedVersion 점검.
- **B7**: **CNPG PostgreSQL 16→18 메이저**(declarative in-place). ★**원자적 경계(A.5-F1, CRITICAL)**: `postgresql:16.4`를 핀한 *모든* 소비자를 한 PR에서 18로 — `platform/cnpg/prod/cluster.yaml`·`basebackup-cronjob.yaml`·`restore-drill-script.sh`·`docs/runbooks/restore.md` 예시까지 누락 없이. 사전 dr-drill + 백업 검증 ID 확보 → 업글 후 로그인·쿼리·백업 + **PG18 백업에서 throwaway 복구 검증**까지 통과해야 완료. ★revert 불가 → 사전 백업이 유일 안전망이며 **그 백업이 PG18로 복구 가능함을 증명한 뒤에만** 진행.

### Wave 5 — GitOps 컨트롤플레인 (★)
- **B8**: argo-cd 차트 7.7.11→10.0.0 **단계적**(7→8→9→10). ★`global.networkPolicy.create` 기본 false→true → **명시 false**(kube-router/netpol 트랩 이력). v3.0 RBAC 상속·`configs.params` 재작성. 검증: ArgoCD 자체 sync/RBAC/UI. ★**롤백 예외(A.5-F2, HIGH)**: ArgoCD는 self-managed → 차트/RBAC/params 실패 시 revert sync를 수행할 컨트롤러 자체가 사라질 수 있음. **사전 렌더된 known-good 매니페스트 + out-of-band `kubectl`/`helm` 복구 경로 + ArgoCD 부재 시 수동 bootstrap 절차**를 배치 전에 준비.

### Wave 6 — 엣지/라우팅 (결합 ★)
- **B9**: traefik 차트 33.0.0→41.0.0 **+ gateway-api CRD v1.2.0→v1.5.1 동반**(traefik 3.7=GW 1.5.1 요구). values 리네임(`logs.general`→`log`·`logs.access`→`accessLog`·필터 camelCase·`providers.file.content` object). 검증: Gateway/HTTPRoute 라우팅 + 내부(`home.<도메인>`)/외부 노출 e2e. ★롤백 예외(A.5-F2): gateway-api CRD `storedVersion` 전환(v1.2→v1.5.1) 점검 + out-of-band CRD apply 경로(git revert가 변환객체 복구 못함).

### Wave 7 — 관측 메이저
- **B10**: VictoriaLogs 0.x→1.x. ★LogsQL filter-pipe 구문 변경 → Grafana/vmalert 쿼리 점검. 검증: 로그 질의·룰.
- **B11**: Grafana 11→12→13 **단계적**(Angular 플러그인 기본 비활성). 검증: 대시보드 렌더.
- **B12**: vector 0.41→0.55(pre-1.0 14단계 — upgrade guide 경유). ★OOM 이력 → config 검증 + working_set 재측정 + 메모리 원장 갱신.

### Wave 8 — k3s 마이너 (owner-local ★ 최고 위험)
- **B13**: k3s 1.31→1.32→1.33→1.34→1.35→1.36.1 **단계적**. 각 마이너: `infra/k3s-bootstrap/versions.env` 갱신 + owner-local 인스톨러 재실행(control-plane 짧은 재시작) + **API 제거 점검**(예: `flowcontrol.apiserver.k8s.io/v1beta3` 1.32 제거) + 전 워크로드 Healthy. 단일노드 sqlite라 etcd 선업글 경고 비해당. ★**마이너별 사전 복구지점(A.5-F3, HIGH)**: 단일 VM·k3s sqlite/kine 실패는 host-state 실패라 PR revert/GitOps로 복구 불가 → 각 마이너 **이전에** ① k3s sqlite/state 백업 또는 OrbStack VM 스냅샷 ② 이전버전 재설치 경로 확보. **stop-rule**: 재시작 후 `/readyz`가 기대 시간 내 미응답 시 즉시 스냅샷/이전버전으로 복원(검증조차 못 도는 상태 방지).

## 6. 롤백 전략

> ★A.5 적대 리뷰 핵심 교정: 기본 GitOps 롤백은 **정확히 최고위험 배치에서 실패**한다(ArgoCD/CRD/PG/k3s). 이들은 롤백 예외로 승격 — 배치별 사전 복구지점·out-of-band 경로 필수.

- **기본**: GitOps → PR revert → ArgoCD 재싱크. (단순 image/chart 마이너 배치 B1·B11 등에만 충분.)
- **예외 1 — ArgoCD/CRD/operator (B5·B6·B8·B9)**: git revert가 CRD `storedVersion`·변환객체·웹훅·컨트롤러 status를 안전 복구하지 못함. 배치별로 **사전 CRD export + storedVersion 점검 + downgrade 가부 판정 + out-of-band `kubectl`/`helm` 복구 경로** 명시. 특히 **B8(ArgoCD self-managed)**은 실패 시 revert sync 주체가 사라지므로 **사전 렌더된 known-good 매니페스트 + ArgoCD 부재 시 수동 bootstrap 절차** 필수.
- **예외 2 — B7(PG 메이저)**: in-place라 revert 불가 → 사전 백업 + **그 백업이 PG18로 복구 가능함을 증명**한 것이 유일 안전망. 전 PG 이미지 소비자/DR 스크립트와 **원자적**(F1).
- **예외 3 — B13(k3s host-state)**: 단일 VM·sqlite/kine 실패는 PR revert/GitOps로 복구 불가 → **마이너별 사전 sqlite/VM 스냅샷 + 이전버전 재설치 경로 + `/readyz` stop-rule**(미응답 시 스냅샷 복원).
- **예외 4 — B4(cert-manager RotationPolicy)**: 상태 변경 → revert 후 수동 정리 필요.

## 7. 메모리 원장 영향

신규/변경 limit(vector 재측정·관측 right-size 등)은 `docs/memory-ledger.md`(limit 합계 ≤ 9216Mi) 동반 갱신 — `verify:ledger` 게이트 강제. 산문 + 행 둘 다 갱신(과거 false-green 함정).

## 8. 리스크 & 라이브 검증 매트릭스 (Phase B에서 단계별 상세화)

| 배치 | 주 리스크 | 핵심 검증 |
|---|---|---|
| B0 | Rego v1 미마이그레이션 시 게이트 즉사 | make verify 양립 확인 |
| B5–B7 | crown-jewel DB·DR | dr-drill 전후·managed-role 로그인 |
| B8 | ArgoCD 자기-sync·netpol 기본 변경 | networkPolicy=false·RBAC |
| B9 | Gateway API CRD 결합·노출 단절 | 내부/외부 e2e |
| B12 | vector OOM 재발 | working_set 재측정 |
| B13 | 단일노드 control-plane 재시작·API 제거 | 마이너별 전 워크로드 Healthy |

## 8.5 A.5 설계 적대 리뷰 반영 (codex, 2026-06-29)

`verdict: needs-attention` — 3건 전부 수용. "기본 롤백/DR 가정이 정확히 최고위험 배치에서 실패한다"는 지적.

| # | 심각도 | 발견 | 반영 |
|---|---|---|---|
| F1 | CRITICAL | PG18 업글이 백업 안전망 무력화(16.4 핀 소비자 다수) | B7 원자적 경계 + PG18 복구 증명(§5 B7·§6 예외2) |
| F2 | HIGH | 롤백이 ArgoCD/CRD 깨짐에 무력 | B5/B6/B8/B9 out-of-band 복구·storedVersion(§5·§6 예외1) |
| F3 | HIGH | k3s host-state 손실 전 복구지점 부재 | B13 사전 스냅샷 + `/readyz` stop-rule(§5 B13·§6 예외3) |

## 9. Phase B 산출물

`docs/plans/2026-06-29-homelab-upgrade-campaign.md` — 각 배치(B0~B13)를 bite-sized TDD 단계로: 정확한 파일 경로·편집·PR·머지·라이브 검증 명령(KUBECONFIG)·롤백. Phase C 적대 리뷰로 하드닝 후 executing-plans 핸드오프.
