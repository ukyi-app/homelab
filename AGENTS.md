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
- OrbStack은 VM에서 **LISTEN 중인 포트만** Mac으로 포워딩한다(바인드는 Mac 전 인터페이스).
  servicelb/hostPort는 iptables DNAT뿐이라 트리거가 안 된다 — `dns-forward-trigger.service`
  (cloud-init) 참고. VM IP(192.168.139.x)는 Mac에서 직접 라우팅되지 않는다.
- AdGuard ConfigMap은 첫 부팅 시드 전용(initContainer `cp -n`) — 갱신 시 PVC 안의
  AdGuardHome.yaml도 함께 고치고 재시작해야 반영된다.
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
