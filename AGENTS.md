# AGENTS.md — 에이전트/개발자 작업 가이드

k3s 단일 노드(Mac mini, OrbStack VM) 홈랩의 GitOps 모노레포. ArgoCD가 이 레포의 `main`을
싱크해 전 스택을 운영한다. 앱 코드는 **별도 레포**(`ukyi-app/<app>`, 템플릿:
`ukyi-app/homelab-app-template`)에 살고, 이 레포에는 배포 설정만 둔다.

## 디렉토리 지도

| 경로 | 역할 |
|---|---|
| `infra/` | Terraform 3 루트(cloudflare/tailscale/github) + `k3s-bootstrap/`(VM·k3s·스토리지) |
| `platform/` | ArgoCD가 싱크하는 GitOps 컴포넌트 — **전체 목록은 README 디렉토리 지도**(check-skeleton 강제) |
| `platform/charts/app` | 모든 앱이 쓰는 공유 Helm 차트 (SSOT) |
| `apps/<name>/deploy/prod/` | 앱별 values + SealedSecret + `.bindings.json`(db/redis·autoDeploy SSOT) + `source-repo`(외부 레포 바인딩) |
| `tools/` | 앱 플랫폼 DX **Bun/TS CLI** (`create-app`/`activate-app`·`audit-orphans` 등 — 변이 디스패처·`bump-poll`이 호출) + 단위 테스트(`tools/tests/`). top-level 19개 + `lib/` 8개 `.ts`(bun 전용) + app-shared 2개 `.mts`(bun + node≥22.18 strip-types 양립) |
| `scripts/` | 클러스터/DR 운영·시크릿 **셸 스크립트** (bootstrap·seed/seal·dr-drill·`check-*` 게이트·run-bats — `make`/CI 게이트가 호출). cf. `infra/k3s-bootstrap/*.sh` = VM·k3s·스토리지 substrate 부트스트랩 |
| `policy/` | 메모리 원장 OPA 정책 (`bun run verify:ledger` 게이트) |
| `docs/memory-ledger.md` | 메모리 예산 SSOT — limit 합계 ≤ 9216Mi, CI 강제 |
| `docs/runbooks/` | **로컬 전용**(gitignored) 운영 런북 — 아래 인덱스 참고 |
| `tests/` | 전역 테스트 (sops 라운드트립, posture 라이브 스위트) |

## 핵심 명령

```bash
make verify        # 기반 게이트: skeleton + 원장(conftest) + sops 라운드트립
make chart-test    # 공유 차트: 3 kind(web/worker/site) 렌더 + kubeconform + bats
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
  스키마 `*-schema.json`=tools 계약(`app-config`/`app-deploy`) vs `values.schema.json`=Helm 고정.
  bats는 `test_` 접두 통일, SealedSecret은 `*.sealed.yaml`.

## 라이브에서 검증된 함정 (재발 주의)

> 전문·근거는 **`docs/traps-detail.md`(SSOT)** — 컴포넌트 작업 전 해당 항목 확인. enforced 가드 현황은
> `docs/traps.md` 원장(`make verify-traps`). 아래는 한줄 인덱스(헤드라인 = traps-detail.md 섹션과 동일).

- ArgoCD sync-wave 순서/교착
- ArgoCD retry 소진 후 명시 sync
- k8s SSA 중복 env 키/스키마 밖 필드 거부
- ArgoCD chart: 필드 repoURL/targetRevision
- Traefik serviceAccount.name 지정 시 SA 미생성
- appset 대상 네임스페이스는 platform/namespaces 소유
- R2 Object R&W 토큰 ListBuckets 불가
- GHCR org 패키지 첫 push private
- fine-grained PAT 능력은 실제 push 테스트로만
- runAsUser /etc/passwd 부재 시 libpq PGUSER
- AdGuard setcap ↔ allowPrivilegeEscalation 양립불가
- VictoriaMetrics retention.maxDiskSpaceUsageBytes 엔터프라이즈
- envFrom 시크릿 변경은 파드 재시작 필요
- build 워크플로 paths/diff 신규 브랜치 무력
- GitHub Actions client_payload 비신뢰 입력
- CNPG Pooler 예약 파라미터 pool_mode → poolMode
- SSA atomic 리스트 영구 OutOfSync
- Application zero-value selfHeal 플립플롭
- PSA baseline hostPath/hostPID 금지
- CNPG pg_hba replication pg_basebackup
- CronJob k3s VM TZ(Asia/Seoul)
- NetworkPolicy ipBlock pod-CIDR → 전체 허용
- kube-router 룰 설치 갭/v2 체인명 변경
- NetworkPolicy egress apiserver ClusterIP 불가
- OrbStack LISTEN 포트만 포워딩
- AdGuard ConfigMap 첫 부팅 시드 전용
- AdGuard split-horizon rewrite DR stale
- tailscale operator Ingress reconcile metadata-only 무시
- vector는 root로 실행
- busybox nc -q 없음
- VictoriaLogs distroless 라이브 질의
- Alertmanager telegram 전송 검증 메트릭
- ConfigMap 변경 파드 자동 재시작 없음
- bats bash 3.2 중간 [[ ]] 침묵 통과
- helm 차트 CRD includeCRDs
- sealed-secrets patch-mode 대상 Secret 어노테이션
- gh pr merge --auto clean PR 에러
- create-github-app-token repositories owner 없는 레포명
- concurrency.queue: max ↔ cancel-in-progress 병용 불가
- terraform provider lock 첫 커밋 라이브 state writer 이상
- tf 루트 관리 모델 CI vs 로컬
- 상주 워크로드 자원 limit 블라인드스팟
- GHA run 기본 셸 pipefail 부재(bash -e {0})

## 멀티레포 앱 플로우 (App Platform DX — 요약)

**트리거 경계:** 앱 레포는 homelab-write 자격 0 (자기 `GITHUB_TOKEN`으로 GHCR push만).
인증은 GitHub App 2개 — reader(앱 레포 Contents:read 전용)/writer(homelab Contents+PR write
전용), 키는 homelab Actions secret에만. **모든 homelab main 쓰기는 PR-first + auto-merge**
(App 토큰은 branch protection 우회 불가; required check `gate` 통과 시 자동 머지).

- **빌드:** 템플릿으로 레포 생성 → `.app-config.yml` 작성(계약: `tools/app-config-schema.json`)
  → main push → `reusable-app-build.yaml`(v1: arm64→GHCR push만, dispatch 없음).
- **생성 변이:** owner가 homelab에서 액션별 디스패처(workflow_dispatch) 실행 (변이 디스패처는 `vars.HOMELAB_OWNER` actor 가드로 owner 전용 — bump-poll/audit reconciler는 비대상) —
  `create-app`/`update-secrets`/`create-database`/`create-cache`/`teardown-app`(각 전용 워크플로). **파괴: `teardown-app`은
  디스패처(`🗑️ teardown-app` — confirm===app 가드 + **수동 머지**, reusable이 파괴 경계에서 confirm 재검증) + owner-local CLI(`make teardown-app`) 공존.
  `teardown-resource`·`activate-app`은 owner-local**(`make teardown-resource`·런북 — 데이터 파괴·attestation·purge 상태머신), **audit은 스케줄 reconciler**(`audit.yaml`).
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
- **공개(DNS):** create-app은 `infra/cloudflare/apps.json`에 `active:true`로 등록(PR 머지가 곧 공개 승인)
  → `iac.yaml`(push apply)/`tf-reconcile.yaml`(30분 드리프트 수렴)이 DNS/tunnel 노출.
  `tools/activate-app.ts` 게이트(descendant+표면 무변경+행 고정)는 host/public 변경 시 재노출 재승인 전용(owner-local CLI).
- **시크릿:** SealedSecrets(컨트롤러 `platform/sealed-secrets`, cert 공개) — 앱 레포에서
  `pnpm secret:seal`(.env→`<app>-secrets.sealed.yaml`) → create-app/update-secrets가 봉인본 키를 검증·배선.
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
| `teardown-resource.md` | DB/캐시 리소스 철거 — `--refs-verified` attestation·삭제 전 수동 확인·purge 상태머신(F1) |
| `db-cache-access.md` | DB/캐시 로컬·GUI 접속 — tailscale 직결·admin superuser·port-forward·롤백/자격 회수(F3) |
| `toolchain.md` | 호스트 도구 핀 |
