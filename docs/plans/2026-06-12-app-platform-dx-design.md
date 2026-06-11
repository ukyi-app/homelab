# App Platform DX — 설계 문서

**작성일:** 2026-06-12
**상태:** 승인됨 (사용자 확정, hardened-planning Phase A)

## 목표

homelab을 **"앱 코드 0개 + 선언적 멀티레포 앱 플랫폼"**으로 만든다. 앱 개발자는
외부 레포(`ukyi-app/<app>`)에서 `.app-config.yml`을 선언하고 push만 하면, 인프라
(공개 DNS·tunnel·DB·캐시·시크릿·k8s 매니페스트·ArgoCD 등록)가 전부 자동으로 처리된다.
인프라 자격(Cloudflare/R2/Terraform)은 homelab에만 중앙화되고, 앱 레포는 GitHub App
설치 자격만 보유한다.

참조: `ukkiee-dev/homelab` + `ukkiee-dev/app-starter`의 패턴을 가져오되, 더 개선한다.
- 차용: GitHub App 인증, 중앙 직렬화 dispatcher, 데이터 기반 terraform, SealedSecrets,
  CNPG 공유 클러스터+앱별 Database CR, mutation 라이프사이클 API.
- 개선: DB/캐시를 **리소스 중심**으로(앱이 소유하지 않고 독립 리소스, 핸들로 참조),
  로컬 개발 모델 명시(docker 시드 / tailscale URL 직결), env 이름 규칙 통일.

## 아키텍처 개요

```
앱 레포(ukyi-app/<app>)                    homelab(ukyi-app/homelab)
  .app-config.yml (선언적 SSOT)             dispatch-mutation.yml (중앙 직렬화)
  .env (gitignored, 로컬값+봉인소스)          ├─ _create-app   → 매니페스트+ArgoCD+(공개)DNS
  <app>-secrets.sealed.yaml (공개 cert 봉인)  ├─ _update-image → values 태그 bump
  GitHub App 설치(APP_ID/KEY만)             ├─ _create-database / _create-cache → 리소스+핸들
       │ workflow_dispatch                  └─ _teardown / audit-orphans
       │ → repository_dispatch(App 토큰)
       ▼                                   terraform/ (apps registry SSOT → dns/tunnel for_each)
  homelab dispatcher가 인프라 자격 보유      manifests/ (ArgoCD가 싱크) + SealedSecrets 컨트롤러
```

## 현재 상태(출발점) vs 목표

| 영역 | 현재 (ukyi-app/homelab) | 목표 |
|---|---|---|
| 인증 | `DEPLOY_BOT_PAT`(개인 fine-grained PAT) | org GitHub App(짧은 토큰, 중앙 자격) |
| 앱 생성 | 템플릿 push → 온보딩 PR(수동 머지), 공개 DNS 수동 terraform | 원-버튼 dispatch → 전 인프라 자동 |
| 인프라 시크릿 | 로컬 `.env.secrets`(CI에 없음) | homelab Actions secrets(중앙) |
| 시크릿 모델 | KSOPS+age(개인키 필요, 손으로 enc.yaml) | SealedSecrets(공개 cert, `.env`→`secret:seal`) |
| DB | 단일 CNPG `pg` 클러스터/단일 `app` DB | 공유 클러스터 + 앱별 Database CR, 리소스 중심 |
| 캐시 | 없음 | Valkey, DB와 대칭 패턴 |
| mutation | onboard + bump | create-app/update-image/create-database/create-cache/teardown + audit |
| 로컬 개발 | dev-postgres(부분) | docker 시드 / tailscale URL 직결, 명시적 2모드 |

현재 사실(플랜 작성 기준):
- `DEPLOY_BOT_PAT` 사용: `.github/workflows/bump.yaml`, `onboard.yaml`.
- KSOPS 마이그레이션 대상: `*.enc.yaml` 7개, `secret-generator.yaml` 5개.
- CNPG: `platform/cnpg/prod/`(cluster.yaml=단일 `pg`, object-store=R2 barman 백업).
- cert-manager v1.16.5 설치됨(Let's Encrypt Issuer + `home-wildcard-tls` 와일드카드 cert 가동).
- tailscale operator 가동(LoadBalancerClass=tailscale로 :443/:53 노출 패턴 검증됨).
- 인-레포 앱 0개(api 제거 완료). 외부 앱 플로우: 템플릿→onboard→bump.

## 컴포넌트 설계

### 1. GitHub App 인증 토대
- org `ukyi-app`에 GitHub App 생성(사용자 액션). 권한: Contents RW, Pull requests RW,
  Actions(dispatch). homelab + 앱 레포에 설치.
- 앱 레포 Actions secret: `HOMELAB_APP_ID`, `HOMELAB_APP_PRIVATE_KEY`만.
- homelab: `actions/create-github-app-token`(또는 composite `homelab-token`)으로 설치 토큰 발급.
- `DEPLOY_BOT_PAT` → App 토큰으로 교체(onboard.yaml/bump.yaml). 교체 후 PAT 폐기.
- 인프라 시크릿을 homelab Actions secrets로: `TF_CLOUDFLARE_TOKEN`, `TF_ZONE_ID`,
  `TF_ACCOUNT_ID`, `TF_TUNNEL_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `TF_DOMAIN`.

### 2. 중앙 직렬화 dispatcher
- `dispatch-mutation.yml`: `repository_dispatch` types =
  `create-app|update-image|create-database|create-cache|teardown`.
- `concurrency: { group: homelab-mutation, cancel-in-progress: false }` — cross-repo 전역 직렬화
  (R2 tfstate / apps registry / tunnel / kustomization race 차단).
- `validate` job: 모든 `client_payload` 필드를 **env 경유로만** 받아(인라인 `${{ }}` 금지)
  RFC1123/형식 검증 + action 화이트리스트. 라우팅 job은 `needs: validate`.
- 라우팅 job이 해당 reusable(`_create-app` 등)을 호출하며 homelab의 인프라 시크릿 주입.

### 3. 데이터 기반 terraform (공개 DNS 자동)
- 앱 레지스트리 SSOT: `infra/cloudflare/apps.json`(또는 `apps/*/deploy/prod/values.yaml`에서
  `route.public==true` 파생). 결정: **명시적 `apps.json`**(terraform이 직접 읽기 단순, 드리프트 적음).
- `dns.tf`: `for_each = apps.json의 공개 host` → CNAME→tunnel. `tunnel.tf`: ingress를
  `for_each`로 동적 생성. 기존 apex/www는 유지.
- 공개 앱 생성/제거 → registry 갱신 → CI에서 `terraform apply`(homelab Actions 시크릿).
- **내부 앱은 terraform 불필요**(와일드카드 cert + AdGuard split-horizon로 `*.home.<domain>` 자동).

### 4. 원-버튼 create-app
- 앱 레포 `create-app` workflow_dispatch(템플릿 동봉, self-build 가드 패턴) → `.app-config.yml`
  읽어 App 토큰으로 homelab에 `create-app` dispatch.
- homelab `_create-app` reusable: repo/중복/GHCR 이미지 pre-flight(없으면 replicas=0) →
  매니페스트 생성(공유 차트 기반 overlay) → 공개면 registry+terraform → ArgoCD 등록 → Telegram.

### 5. DB/캐시 — 리소스 중심(핸들, 옵션 A)
- `create-database`/`create-cache`: homelab workflow_dispatch, **풀 스펙** 입력.
  - postgres: `name, version, storage, cpu/mem, extensions[]`.
  - valkey: `name, version, maxmemory, eviction, persist, cpu/mem`.
- postgres: 공유 CNPG 클러스터에 **Database CR**(`spec.owner/name`) + 관리 롤 생성(클러스터를
  앱마다 만들지 않음). valkey: 인스턴스(공유+ACL 유저 또는 경량 Deployment — 구현 시 결정).
- 자격 → **SealedSecret 핸들**(`db-<name>-conn` / `cache-<name>-conn`). **raw URL 절대 비노출**
  (워크플로 출력/로그에 안 찍음 — 반환은 핸들 이름만).
- GitOps: 리소스/핸들을 git에 기록 → ArgoCD 싱크 → DR 시 자동 재생성.
- 라이브 검증된 함정 반영: CNPG pg_hba(replication), pooler 예약 파라미터, SSA atomic-list 기본값.

### 6. 앱 소비 — 선언적 참조
```yaml
# .app-config.yml
db:    [orders]      # 이름 = create-database로 만든 리소스
redis: [sessions]
```
- 플랫폼이 해당 SealedSecret을 `envFrom`으로 앱 Deployment에 연결.
- env 이름 규칙(확정): **항상 `<NAME>_DATABASE_URL` / `<NAME>_REDIS_URL`**(단일/다중 무관, 별칭 없음).
  `<NAME>` = 리소스명 대문자·`-`→`_`.
- 미생성 리소스 참조 → sync 실패(명확한 에러: `db '<name>' 미생성 — create-database 먼저`).

### 7. 환경변수 3계층
- **평문** `.app-config.yml`의 `env:{K:V}` → ConfigMap → `envFrom`. push로 동기화.
- **시크릿** `.app-config.yml`의 `secrets:[KEY]`(allowlist) → **SealedSecrets**.
  - 로컬 `.env`(gitignored)에 값 → `pnpm secret:seal`이 **`secrets:`에 선언된 키만** `.env`에서
    읽어 공개 cert(app-starter 동봉)로 봉인 → `<app>-secrets.sealed.yaml` 커밋(암호화돼 안전) →
    컨트롤러가 클러스터에서 복호화 → `envFrom`.
  - 선언했는데 `.env`에 값 없으면 에러.
- **DB/캐시** → 자동 주입(§6).
- **SealedSecrets 전환**: bitnami sealed-secrets 컨트롤러를 ArgoCD로 배포(infra wave) +
  공개 cert를 app-starter에 동봉 + 기존 KSOPS enc.yaml 7개를 SealedSecret으로 마이그레이션
  (복호화→reseal→KSOPS generator 제거). age 키는 백업/복구 폴백으로 유지하되 신규는 SealedSecrets.

### 8. 로컬 개발 (2모드)
- **깨끗한 개발(기본)**: `pnpm db:up` → 로컬 docker postgres/valkey 기동 + 마이그레이션 + 시드.
  `.env`의 `DATABASE_URL`=localhost. 마음껏 깨고 `db:reset`로 초기화.
- **실데이터 디버깅**: docker 없이 클러스터 DB/캐시 **URL 직결**.
  - DB/캐시를 tailscale LoadBalancer로 노출(ACL `autogroup:self` — 본인 tailnet 기기만).
  - `pnpm db:url <name>`/`cache:url <name>`: SealedSecret에서 자격 꺼내(kubectl) `.env.local`
    (gitignored)에 `<NAME>_DATABASE_URL`(host=리소스 tailscale IP) 기록. tailscale 켜면 바로.
  - **단방향만**(prod write 역방향 없음). 파괴적 작업(reset/대량삭제)은 docker 모드에서만.
- 스키마는 마이그레이션으로 양쪽 일치, 데이터는 격리(시드) 또는 단방향 직결.
- `.env.example`은 `.app-config.yml`(env+secrets+db+redis)에서 자동 생성(`pnpm env:example`) — 로컬 패리티.

### 9. 라이프사이클
- `teardown`: 앱/DB/캐시 깔끔 제거(매니페스트+registry+DNS+SealedSecret), idempotent.
- `audit-orphans`: registry vs 실제 리소스 드리프트 감지(고아 DNS/DB/매니페스트 리포트).

## 보안 불변식
- 인프라 자격은 homelab에만(앱 레포는 App 자격만). 사용자 제공 시크릿은 **클라이언트 봉인**
  (워크플로 입력으로 안 받음 — 입력 노출 방지). DB 비밀번호는 워크플로가 **생성**(입력 안 받음).
- `client_payload`는 비신뢰 → env 경유 + 화이트리스트 검증. raw 자격은 git/로그에 평문 없음.
- 내부 서비스(DB/캐시)는 tailscale ACL `autogroup:self`로 본인 기기만. 공개 노출은 Cloudflare tunnel만.

## 비목표 (YAGNI)
- 모노레포 services(앱 1레포 다서비스) — 1차 범위 제외(필요 시 추후).
- 홈페이지 대시보드 타일 — 제외.
- 양방향/연속 데이터 동기화 — 제외(단방향 pull/직결만).
- External Secrets Operator/Vault — 제외(SealedSecrets로 충분).

## 단계(개략 — 상세는 구현 플랜)
- Phase 0: 사용자 액션(GitHub App 생성·설치, homelab Actions secrets 등록).
- Phase 1: GitHub App 인증 교체(PAT 제거).
- Phase 2: SealedSecrets 컨트롤러 + KSOPS 마이그레이션.
- Phase 3: 데이터 기반 terraform(apps.json) + 중앙 dispatcher + CI apply.
- Phase 4: create-app 원-버튼 + 매니페스트/ArgoCD.
- Phase 5: DB/캐시 리소스 프로비저닝 + `db:`/`redis:` 소비 + env 주입 + tailscale 노출 + 로컬 CLI.
- Phase 6: teardown + audit-orphans + `.app-config.yml` 스키마/문서.

각 Phase는 점진적으로 가치 전달(독립 머지 가능), "사용자 할 일/내 할 일" 분리.
