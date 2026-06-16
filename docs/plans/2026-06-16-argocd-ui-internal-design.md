# ArgoCD UI를 인터널 앱으로 — 설계

- 날짜: 2026-06-16
- 상태: 설계 확정 (어드버서리얼 설계 검증 통과 — `sound-with-fixes`)
- 범위: ArgoCD 웹 UI를 `argocd.home.ukyi.app`(tailnet/LAN 내부 전용)로 노출 +
  커스텀 로컬 계정 `ukkiee`(풀 어드민) 로그인. 공개 노출·SSO 비목표.

## 1. 목표와 비목표

- **목표**: ArgoCD UI를 기존 인터널 노출 경로(`web-internal-tls`)로 띄우고,
  `ukkiee` 계정(풀 어드민)으로 로그인. 비밀번호는 `.env.secrets`에서 공급해 봉인.
- **비목표**: 공개(`*.ukyi.app`) 노출, SSO/dex, ArgoCD CLI 전용 배선(아래 §8 노트만),
  KSOPS→SealedSecrets 마이그레이션, admin 계정 제거.

## 2. 이미 준비된 자산 (변경 없음)

- `platform/argocd/bootstrap-values.yaml`: `global.domain: argocd.home.ukyi.app`,
  `configs.params.server.insecure: true` — TLS는 Traefik/Tailscale에서 종단, argocd는
  평문 HTTP(:8080) 서빙. (라이브 확인: `argocd-cm`의 `url=https://argocd.home.ukyi.app`)
- Gateway `homelab`(ns gateway) 리스너 `web-internal-tls`: HTTPS:8443, TLS Terminate,
  certRef `home-wildcard-tls`(`*.home.ukyi.app`), `allowedRoutes: from All`.
- AdGuard split-horizon: 와일드카드 `*.home.ukyi.app → traefik-ts tailscale IP` →
  `argocd.home.ukyi.app` 자동 해석. **DNS/TLS cert 변경 불필요.**
- `argocd` 네임스페이스엔 default-deny NetworkPolicy 없음(default-deny는 prod/database/cache만).
  Grafana(observability)/AdGuard(edge)와 동일 → **NetworkPolicy 변경 불필요.**
- 라이브 확인: Service `argocd-server`는 `80→8080(http)`, `443→8080(https)` 노출.
  `server.insecure=true`라 80(http)이 평문 HTTP로 연결됨 → backendRef는 **80**(443 아님).
- `root-app`(`platform/argocd/root`, `directory.recurse: true`)이 `root/apps/*.yaml`
  Application을 자동 포착. argocd 자신은 platform-components appset에서 제외(self-managed).

## 3. 설계 개요

세 갈래 변경. **비밀(시크릿)은 봉인, 비밀 아닌 설정은 차트 values**로 분리한다.

### 3.1 인증 — 로컬 계정 `ukkiee` (풀 어드민), admin은 break-glass 존치

`bootstrap-values.yaml`(차트가 `argocd-cm`/`argocd-rbac-cm` 단독 소유 — single-writer):

```yaml
configs:
  cm:
    "accounts.ukkiee": login        # UI+CLI 로그인 capability (apiKey 미부여 = token 발급 불가, 의도)
  rbac:
    "policy.default": role:readonly  # 라이브 현재 미설정이며 내장 기본과 동일 — 명시화(narrowing 아님)
    "policy.csv": |
      g, ukkiee, role:admin          # 내장 슈퍼유저 롤 부여 (SSO 비활성이라 scope 충돌 없음)
```

- `admin` 계정은 **그대로 enabled**(break-glass). `admin.enabled:false` 미설정.
- 비밀번호: `.env.secrets`의 `ARGOCD_PASSWORD`(평문, **8–32자**) →
  `argocd account bcrypt --password "$ARGOCD_PASSWORD"`($2a$ 출력 — htpasswd $2y$ 금지) →
  **patch-mode SealedSecret**로 기존 차트 관리 Secret `argocd-secret`(ns argocd)에
  `accounts.ukkiee.password` 키만 **머지**.
- **`accounts.ukkiee.passwordMtime`는 생략**한다. 비밀번호 로그인에 불필요하며
  (`VerifyUsernamePassword`는 mtime 미참조), 잘못된 RFC3339 값이면 `parseAccounts`가
  에러를 던져 **argocd-server 전체 settings 로드가 실패**(전역 장애)한다. repo의
  Asia/Seoul TZ 함정(`date +%FT%T%Z`→`...KST`)이 이를 쉬운 자해로 만든다.

### 3.2 노출 — HTTPRoute (Grafana/AdGuard 선례 그대로)

`platform/argocd/extras/httproute.yaml` (ns argocd):

- name `argocd-server`, parentRef Gateway `homelab`/`gateway` `sectionName: web-internal-tls`
- hostname `argocd.home.ukyi.app`
- backendRef Service `argocd-server` **port 80**, `group: ""` `kind: Service` `weight: 1`
- `parentRefs`/`backendRefs`에 group/kind/weight **명시** — SSA atomic-list 영구 OutOfSync 함정 회피.

### 3.3 배선 — 별도 Application + kustomize 디렉토리

- `platform/argocd/extras/kustomization.yaml`: `namespace: argocd`,
  resources: `httproute.yaml`, `argocd-accounts.sealed.yaml`. (KSOPS generator 미사용 — 일반 CR)
- `platform/argocd/root/apps/argocd-extras.yaml`: Application,
  `path: platform/argocd/extras`, dest ns argocd, `CreateNamespace=false`(ns는 -10 차트 app이 생성),
  `ServerSideApply=true`(atomic-list 함정), sync-wave는 **SYNC-WAVES.md 원장에 행이 있는 값**으로
  지정(gateway/-8·sealed-secrets/-8·argocd/-10 이후면 됨). root-app recurse가 자동 포착.

**Q2(extraObjects vs 별도 Application) 결정 = 별도 Application.** 봉인 시크릿은 helm values
문자열보다 kustomize 디렉토리 + 표준 `kubeseal` 워크플로에 속하고 `kustomize build`로 검증
가능하며, 라우트를 같은 디렉토리에 두면 응집도가 높다. victoria-stack/cnpg의 "수동 Application" idiom.

## 4. argocd-secret 2-writer 안전성 (근거 — 라이브 입증)

`argocd-secret`에 세 writer가 공존한다: ① 차트 app(ArgoCD SSA Apply) ② argocd-server 런타임
(server.secretkey 등, client-go Update) ③ sealed-secrets 컨트롤러(patch, client-go Update).

**안전한 진짜 이유(검증):**
- 이 repo values엔 `configs.secret` 블록이 **전혀 없어** 차트의 `argocd-secret`은
  metadata+`type:Opaque`만 렌더하고 **data 블록을 내지 않는다**. 따라서 ArgoCD SSA Apply가
  소유/prune할 data 필드가 없다.
- sealed-secrets 컨트롤러 patch는 **additive merge**(기존 secret을 읽어 자기 키만 set,
  기존 키 미삭제, `managed:true` 없으면 ownerRef도 안 잡음).
- **라이브 증거**: argocd app이 지금도 `Synced/Healthy`인데 `argocd-secret`엔 이미
  `admin.password`/`admin.passwordMtime`/`server.secretkey`(매니저 `argocd-server`/Update)가
  desired에 없이 존재한다. 4번째 매니저(sealed-secrets)로 `accounts.ukkiee.*`를 추가하는 것은
  동일 패턴 → 동일하게 무해.

> ⚠️ 이 안전성은 "차트가 `argocd-secret`에 data 블록을 안 낸다"에 의존한다.
> **향후 `configs.secret.*`(예: `argocdServerAdminPassword`)를 추가하면** 차트 SSA가 `data.*`를
> 소유해 외부 머지 키를 prune할 수 있다 — `bootstrap-values.yaml`에 금지 주석을 단다.
> (설계가 처음에 적었던 "SSA가 타 매니저 필드를 안 지운다"는 컨트롤러 write가 Update라 정확한
> 기전이 아니다 — 근거는 위 두 가지다.)

**OutOfSync 폴백(필요시에만):** 라이브상 churn 없음. 만약 발생하면 `IgnoreExtraneous`(리소스
레벨 orphan 전용, data-key엔 부적합)가 **아니라** `diffing.managedFieldsManagers`(매니저
sealed-secrets-controller 무시) 또는 argocd app `ignoreDifferences` + jqPathExpression `.data`
(+ `RespectIgnoreDifferences=true`, 이미 활성)를 쓴다.

## 5. patch-mode SealedSecret 봉인 규약 (실패 표면)

- **patch 주석 위치**: `sealedsecrets.bitnami.com/patch: "true"`는 **`spec.template.metadata.annotations`**에
  있어야 한다(컨트롤러는 복호화된 Secret=template metadata에서 읽음). SealedSecret 자체
  metadata에 두면 **조용히 무시→full-replace 시도→"argocd-secret already exists and is not
  managed" 거부→extras Application sync 차단**. → **평문 Secret(metadata에 주석)을 만들어
  `kubeseal`로 봉인**하면 주석이 `spec.template.metadata.annotations`로 자동 운반된다.
  AdGuard 선례(`auth-sealed.yaml`)는 patch 주석이 없는 full-replace라 이 부분 가이드를 주지 않음.
- **strict scope**: 기본 strict는 name+namespace를 암호문에 바인딩. 평문 Secret의
  `metadata.name=argocd-secret`, `metadata.namespace=argocd`여야 하고, SealedSecret 파일도
  같은 name/namespace를 명시(kustomize `namespace: argocd` overstamp가 no-op이 되도록).
  오타(예: `argocd-secrets`)면 라벨 불일치로 **조용히 복호화 실패**.
- **cert staleness preflight**: hand-author는 `tools/seal-secret.mjs`(및 거기 묶인 cert 검사)를
  우회하므로, 봉인 전 **라이브 컨트롤러 cert fingerprint를 확인**(`kubeseal --fetch-cert` 또는
  `make secret-cert-check`). stale cert로 봉인하면 복호화가 조용히 실패해 ukkiee 로그인이 영영 안 됨.
- **인코딩 검증**: 적용 후 `kubectl -n argocd get secret argocd-secret -o jsonpath` 로
  `accounts.ukkiee.password`가 `$2a$...`로 디코드되고, 매니저에 `sealed-secrets-controller`가
  추가됐는지, 기존 키(server.secretkey/admin.*)가 살아있는지 확인.

## 6. 기각한 대안

- **extraObjects(라우트를 helm values에)**: 봉인 시크릿이 values 문자열에 부적합 + 검증성↓ → 탈락.
- **비밀번호를 `configs.secret.extra`로 bcrypt 커밋**: bcrypt 해시를 git에 남김 — repo 봉인 규율 +
  AdGuard 선례 위배 → 탈락.
- **`configs.secret.createSecret:false` + `managed:true`(argocd-secret 단독 소유)**: 2-writer를
  원천 제거하나 server.secretkey·admin seeding 등 core 시크릿을 직접 관리해야 해 표면 과다·취약.
  라이브상 patch-mode가 안전 입증 → patch-mode 채택(덜 침습적, 차트의 admin break-glass seeding 유지).
- **SSO/dex, `admin.enabled:false`**: 단일 사용자 홈랩엔 YAGNI(후자는 DR 안전상 admin 존치 선호).

## 7. 검증 전략 (CI는 argocd/extras를 자동 렌더하지 않음 — bats glob만)

`make chart-test`는 `platform/charts/app`만, `make render`는 `platform/<COMP>/prod`만 대상이라
`platform/argocd/extras`(`/prod` 아님)를 못 친다. argocd 차트 app은 CI에서 helm-template되지
않는다. 따라서:

- **`platform/argocd/extras/test_*.bats`**(platform bats sweep가 자동 발견):
  1. `kustomize build platform/argocd/extras` 성공 + HTTPRoute 1개·SealedSecret 1개.
  2. HTTPRoute에 `argocd.home.ukyi.app`·`web-internal-tls`·backend `argocd-server`:80·
     `weight:1`·명시 group/kind (test_adguard_route.bats 미러).
  3. SealedSecret `metadata.name==argocd-secret`·`metadata.namespace==argocd`·patch 주석이
     `spec.template.metadata.annotations`에 존재.
- **SYNC-WAVES.md 원장 행 추가**(test_sync_wave_ledger.bats가 top 테이블 매칭 — 미등록 wave는
  hard-fail).
- (선택) 로컬/CI에서 `helm template argo-cd 7.7.11 -f bootstrap-values.yaml` 후 `argocd-cm`에
  `accounts.ukkiee`, `argocd-rbac-cm`에 policy.csv 라인 존재 단언(values 오타는 라이브 sync에서만
  드러나므로).
- **라이브 스모크**: HTTPRoute `Accepted=true`+`ResolvedRefs=true`; 브라우저로 ukkiee 로그인;
  `argocd account can-i`가 admin 해석; argocd app `Synced/Healthy` 유지 + argocd-secret 키 생존.

## 8. 운영 노트 (런북 반영)

- **CLI는 `--grpc-web` 필수**: native gRPC(HTTP/2)는 TLS-terminate 프록시가 HTTP/1.1로
  포워딩하는 경로를 통과 못 함. `argocd login argocd.home.ukyi.app --grpc-web`(이후 컨텍스트가
  grpc-web 상속). UI는 무관. (`ukkiee`엔 apiKey 미부여라 `argocd account generate-token` 불가 — 의도.)
- **break-glass(결정적)**: `argocd-initial-admin-secret`은 설치 시점 비밀번호만 반영(변경 시
  미갱신·삭제 가능). 라이브상 현재 존재(45h, DR 재구축분)하나, 결정적 복구는
  `argocd-secret`의 `admin.password`+`admin.passwordMtime` 삭제 후 `rollout restart`로 재생성.
- **DR cold-start 로그인 윈도우**: ukkiee 로그인은 ① 차트가 argocd-secret 생성 ② sealed-secrets
  컨트롤러가 patch 반영, 둘 다 필요. sync-wave는 Application 경계 health를 게이트하지 않으므로
  재구축 직후 컨트롤러 reconcile 전까지는 admin으로만 로그인 가능.
- **SSO 도입 시**: `g, ukkiee, role:admin`을 `p, ukkiee, *, *, *, allow`로 전환(scope-name 충돌
  에스컬레이션 방지) — values에 주석.
- 비밀번호 회전: `.env.secrets` 갱신 → bcrypt → 재봉인 → 커밋. additive patch가 키 갱신.

## 9. 어드버서리얼 설계 검증 요약

5개 독립 렌즈(ArgoCD 계정/RBAC, SealedSecrets patch-mode, argo-helm 차트, Traefik Gateway/gRPC,
GitOps 배선) + 종합 critic로 검증. 판정 **`sound-with-fixes`**, 사용자 노출 설계 표면 불변.
52 findings(38 verified, 14 refuted/uncertain) + 28 gaps. 반영한 핵심 수정:
mtime 생략(전역 장애 회피), patch 주석 위치 명시(평문→kubeseal), SYNC-WAVES 원장 행, extras bats
커버리지, pre-seal cert 검사, 안전 근거 교정(additive merge + data 블록 부재), IgnoreExtraneous
폴백 제거, CLI `--grpc-web`/break-grass/DR 노트. 상세 플랜은 후속 `writing-plans` 산출물 참조.
