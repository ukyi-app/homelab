# homelab

k3s 단일 노드(Mac mini · OrbStack VM · arm64) **GitOps 모노레포**. ArgoCD가 이 레포의 `main`을
싱크해 전 스택을 운영한다 — 클러스터에서 손으로 바꾸는 것은 없다(**SSOT는 git**). 앱 코드는
별도 레포(`ukyi-app/<app>`)에 살고 GHCR로 이미지를 올리며, 이 레포에는 **배포 설정만** 둔다.
모든 `main` 변경은 PR-first + 게이트 통과 후 머지, 인프라는 Terraform·k3s 부트스트랩으로 코드화한다.

## 아키텍처

```
   ukyi-app/<app> ──image(GHCR)──┐        ┌── git(main) ──▶ ArgoCD ──sync──▶ 전 스택
   (앱 코드 · 별도 레포)          │        │                 (SSOT — 클러스터 수동변경 0)
                                 ▼        │
   ══════════════════  k3s 단일 노드 · OrbStack VM (arm64 · 11GiB · 6 vCPU)  ══════════════════

     공개 경로                                     내부 경로 (tailscale 전용)
     ─────────                                     ─────────────────────────
     Internet                                      tailscale 기기
        │ HTTPS                                       │
        ▼                                             ▼
     Cloudflare                                    AdGuard
     DNS · WAF · rate-limit · HSTS                 DNS 광고차단 + split-horizon
        │ cloudflared Tunnel (outbound only)          │  *.home.ukyi.app → tailscale IP
        └─────────────────────┬────────────────────────┘
                              ▼
                    Traefik · Gateway API
     web-public(*.ukyi.app)   │   web-internal-tls(*.home.ukyi.app · Let's Encrypt 와일드카드)
                              ▼
                    prod 앱 (공유 Helm 차트)
     NetworkPolicy: 네임스페이스별 default-deny + 최소 allow (east-west 격리)
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
        CNPG               Valkey            victoria-stack
        Postgres·PgBouncer  cache(Redis 호환)  메트릭·로그·알림·Grafana
          │ barman-cloud / rclone
          ▼
     Cloudflare R2  (CNPG 백업 + Terraform state)
```

**계층 요약**

- **GitOps** — ArgoCD가 `main`의 `platform/*`를 app-of-apps + ApplicationSet으로 자동 발견·동기화. 드리프트는 selfHeal로 수렴.
- **공개 경로** — Cloudflare가 DNS·WAF·rate-limit·엣지 TLS를 담당하고, `cloudflared` 터널이 **아웃바운드 전용**으로 Traefik에 연결(오리진 포트 미노출).
- **내부 경로** — `tailscale-operator`가 `*.home.ukyi.app`를 tailnet에만 노출하고, AdGuard가 split-horizon DNS로 그 호스트를 tailscale IP로 리졸브한다(내부 전용 admin UI는 공개되지 않음).
- **인그레스 · TLS** — Traefik이 Gateway API(`Gateway`/`HTTPRoute`)로 라우팅, cert-manager가 Let's Encrypt DNS-01로 `*.home.ukyi.app` 와일드카드 인증서를 발급.
- **데이터** — CloudNativePG(Postgres + PgBouncer), Valkey 캐시. 백업은 barman-cloud로 R2에 적재(DR 드릴 검증).
- **관측성** — VictoriaMetrics/VictoriaLogs로 수집, Vector가 로그 적재, Alertmanager가 텔레그램 알림, Grafana 대시보드.
- **시크릿** — SOPS(age 2-recipient) + KSOPS + SealedSecrets 하이브리드, 평문은 git·디스크에 닿지 않는다.

## 기술 스택

| 영역 | 기술 |
|---|---|
| 호스트 · 오케스트레이션 | OrbStack VM(Debian 12 · arm64) · **k3s** v1.36 · local-path-provisioner(내장 btrfs SSD + 외장 bulk SSD via virtiofs) |
| GitOps · CD | **ArgoCD** v3.4 — app-of-apps + ApplicationSet |
| IaC | **Terraform** ≥1.9 — `cloudflare` · `github` · `tailscale` provider · **R2**(S3 호환) state backend |
| 엣지 · 네트워크 | **Cloudflare**(DNS · Tunnel · WAF · zone hardening) · **cloudflared** · **tailscale-operator** v1.98 · **AdGuard Home** · kube-router NetworkPolicy |
| 인그레스 · TLS | **Traefik** v3 (Gateway API) · **cert-manager** v1.20 (Let's Encrypt DNS-01 와일드카드) |
| 데이터 | **CloudNativePG**(PostgreSQL 18 · PgBouncer · barman-cloud → R2) · **Valkey** 9 (Redis 호환) |
| 관측성 | **VictoriaMetrics** v1.145 · **VictoriaLogs** · vmagent/vmalert · **Alertmanager**(텔레그램) · **Grafana** · **Vector** · node-exporter · kube-state-metrics · Glances |
| 시크릿 | **SOPS** + age(2-recipient) · **KSOPS** · **SealedSecrets** (하이브리드) |
| 대시보드 · DX | **Homepage** 운영자 대시보드 · **Bun** + TypeScript CLI(`tools/`) · skopeo(이미지 digest 검증) |
| CI · 품질 | **GitHub Actions**(gate) · **bats** · **conftest/OPA**(메모리 원장) · **Renovate** · pre-commit |

> 버전은 전부 핀 고정(Renovate가 digest·차트·provider를 PR-first로 갱신). 정확한 핀은 각 컴포넌트의
> `helmrelease.yaml`·`deployment.yaml`·`infra/*/versions.tf`·`infra/k3s-bootstrap/versions.env` 참조.

## 디렉토리

| 경로 | 역할 |
|---|---|
| `infra/` | Terraform(cloudflare · tailscale · github) + `k3s-bootstrap/`(VM · k3s · 스토리지) |
| `platform/` | ArgoCD가 싱크하는 GitOps 컴포넌트 (아래 표) |
| `platform/charts/app` | 모든 앱이 쓰는 공유 Helm 차트 (SSOT) |
| `apps/<name>/deploy/prod/` | 앱별 values + SealedSecret + 바인딩(`.bindings.json` / `source-repo`) |
| `tools/` · `tests/` · `policy/` | Bun/TS DX CLI · 전역 테스트 · 메모리 원장 OPA 정책 |

### platform 컴포넌트

| 컴포넌트 | 역할 |
|---|---|
| `argocd` | GitOps 컨트롤러 (app-of-apps · self-managed) |
| `traefik` | Gateway API 인그레스 + cert-manager Let's Encrypt 와일드카드 cert |
| `cloudflared` | Cloudflare Tunnel — 공개 경로 종단점(아웃바운드 전용) |
| `tailscale` | tailscale-operator — 내부 전용 노출(`*.home.ukyi.app`) |
| `adguard` | LAN/tailnet DNS — 광고차단 + split-horizon |
| `cnpg` | CloudNativePG — Postgres + PgBouncer + barman-cloud(R2) 백업 |
| `cache` | Valkey — Redis 호환 앱별 캐시 |
| `victoria-stack` | 관측성 — VictoriaMetrics/Logs · Grafana · Alertmanager · Vector |
| `sealed-secrets` | SealedSecrets 컨트롤러(controller-독립 DR 자산) |
| `data-conn` | 앱 소비용 conn SealedSecret — create-database/create-cache 산출물 |
| `ghcr-pull` | private GHCR pull용 imagePullSecret (prod NS dockerconfigjson SealedSecret) |
| `network-policies` | prod east-west 격리 — default-deny + 최소 allow |
| `cert-manager-netpol` | cert-manager ns egress 격리 — remote-helm이라 별도 컴포넌트로 분리 |
| `namespaces` | 네임스페이스 소유 + PSA(Pod Security Admission) enforce 라벨 |
| `homepage` | 운영자 진입점 대시보드 |
| `files` | 자기-호스팅 파일 스토어 — internal API 업로드 + public 다운로드/카탈로그(bulk-ssd) |

## 명령

```bash
make verify       # 기반 게이트: skeleton + 메모리 원장(conftest) + sops 라운드트립
make chart-test   # 공유 차트: 3 kind(web/worker/site) 렌더 + kubeconform + bats
make tf-validate  # terraform fmt + validate (3 루트)
make bootstrap    # 멱등 DR 진입점: ArgoCD + sops-age + root app
make ci           # push 전 단일 진입점 — CI 'gate' job을 로컬에서 그대로 재현
```

## 더 보기

- **[AGENTS.md](AGENTS.md)** — 디렉토리 지도, 명령, 컨벤션, 라이브에서 검증된 함정
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — 황금률(검증 우선 · 평문 시크릿 금지 · env는 경로에)
- `docs/runbooks/` — 운영 런북 (로컬 전용, **gitignored** — 신규 체크아웃엔 부재. 디스크 유실 대비 별도 백업)
- `docs/runbooks-public/toolchain-setup.md` — 호스트 툴체인 최소 설치 가이드 (tracked — gitignored 런북 대체본)
