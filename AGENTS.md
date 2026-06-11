# AGENTS.md — 에이전트/개발자 작업 가이드

k3s 단일 노드(Mac mini, OrbStack VM) 홈랩의 GitOps 모노레포. ArgoCD가 이 레포의 `main`을
싱크해 전 스택을 운영한다. 앱 코드는 **별도 레포**(`ukyi-app/<app>`, 템플릿:
`ukyi-app/homelab-app-template`)에 살고, 이 레포에는 배포 설정만 둔다.

## 디렉토리 지도

| 경로 | 역할 |
|---|---|
| `infra/` | Terraform 3 루트(cloudflare/tailscale/github) + `k3s-bootstrap/`(VM·k3s·스토리지) |
| `platform/` | ArgoCD가 싱크하는 GitOps 컴포넌트 (argocd, traefik, cnpg, victoria-stack, edge 3종, namespaces, network-policies) |
| `platform/charts/app` | 모든 앱이 쓰는 공유 Helm 차트 (SSOT) |
| `apps/<name>/deploy/prod/` | 앱별 values + KSOPS 시크릿 (`source-repo` = 외부 레포 바인딩) |
| `tools/` | DX 스크립트 (`gen:app`, `verify:*`, `onboard-app.mjs` 등) + 테스트 |
| `policy/` | 메모리 원장 OPA 정책 (`pnpm verify:ledger` 게이트) |
| `docs/memory-ledger.md` | 메모리 예산 SSOT — limit 합계 ≤ 8704Mi, CI 강제 |
| `docs/runbooks/` | **로컬 전용**(gitignored) 운영 런북 — 아래 인덱스 참고 |
| `tests/` | 전역 테스트 (sops 라운드트립, posture 라이브 스위트) |

## 핵심 명령

```bash
make verify        # 기반 게이트: skeleton + 원장(conftest) + sops 라운드트립
make chart-test    # 공유 차트: 4 kind 렌더 + kubeconform + bats
make tf-validate   # terraform fmt+validate (3 루트)
bats tools/test/ infra/k3s-bootstrap/test/          # 툴링/부트스트랩 테스트
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

## 라이브에서 검증된 함정 (재발 주의)

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

## 멀티레포 앱 플로우 (요약)

템플릿으로 레포 생성 → `.homelab.yaml` 작성(계약: `tools/homelab-app-schema.json`) → main push
→ `reusable-app-build.yaml`(arm64→GHCR→dispatch) → 신규면 온보딩 PR 자동 생성(머지=첫 배포 승인,
GHCR public 전환 체크리스트 포함) / 기존이면 `bump.yaml`이 직렬 write-back(source-repo 바인딩
+ digest 검증) → ArgoCD 싱크. 머지→라이브 약 4–7분.

## 런북 (로컬 전용 — `docs/runbooks/`, git에 없음)

운영 절차 상세는 비공개 유지를 위해 로컬에만 둔다. 디스크 유실 대비 별도 백업 권장.

| 런북 | 내용 |
|---|---|
| `02-cloud-iac-bootstrap.md` | R2 상태 버킷·terraform·bootstrap 절차 |
| `age-keys.md` | age 2-recipient 키 모델/보관 |
| `app-onboarding.md` | 앱 온보딩 체인(외부 레포 + 인레포) |
| `external-ssd.md` | 외장 SSD APFS 볼륨 + bulk-ssd 게이트 |
| `host-substrate.md` | OrbStack VM/k3s 호스트 계층 |
| `lan-dns.md` | AdGuard split-horizon + 라우터 DNS(R7) |
| `observability-bootstrap.md` / `observability-verify.md` | 관측성 셋업/검증 스윕 |
| `restore.md` | CNPG 복구(R1) — DR 핵심 |
| `storage-verify.md` | 스토리지 라이브 e2e 검증 |
| `toolchain.md` | 호스트 도구 핀 |
