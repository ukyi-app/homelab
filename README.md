# homelab

k3s 단일 노드(Mac mini · OrbStack VM) GitOps 모노레포. ArgoCD가 이 레포의 `main`을
싱크해 전 스택을 운영한다 — 클러스터에서 손으로 바꾸는 것은 없다(SSOT는 git).
앱 코드는 별도 레포(`ukyi-app/<app>`)에 살고, 이 레포에는 배포 설정만 둔다.

## 경로

```
공개   인터넷 → Cloudflare(DNS·Tunnel) → Traefik Gateway(web-public) → 앱
내부   tailscale 기기 → AdGuard(전역 DNS: 광고차단 + split-horizon)
                       → *.home.ukyi.app → Traefik(web-internal) → 내부 앱
```

## 디렉토리

| 경로 | 역할 |
|---|---|
| `infra/` | Terraform(cloudflare·tailscale·github) + `k3s-bootstrap/`(VM·k3s·스토리지) |
| `platform/` | ArgoCD가 싱크하는 GitOps 컴포넌트 (argocd·traefik·cnpg·victoria-stack·edge·network-policies) |
| `platform/charts/app` | 모든 앱이 쓰는 공유 Helm 차트 (SSOT) |
| `apps/<name>/deploy/prod/` | 앱별 values + SealedSecret + 바인딩(`.bindings.json`/`source-repo`) |
| `tools/` · `tests/` · `policy/` | DX 스크립트 · 전역 테스트 · 메모리 원장 OPA 정책 |

## 명령

```bash
make verify       # 기반 게이트: skeleton + 메모리 원장 + sops 라운드트립
make chart-test   # 공유 차트: 4 kind 렌더 + kubeconform + bats
make tf-validate  # terraform fmt + validate (3 루트)
make bootstrap    # 멱등 DR 진입점: ArgoCD + sops-age + root app
```

## 더 보기

- **[AGENTS.md](AGENTS.md)** — 디렉토리 지도, 명령, 컨벤션, 라이브에서 검증된 함정
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — 황금률(검증 우선·평문 시크릿 금지·env는 경로에)
- `docs/runbooks/` — 운영 런북 (로컬 전용, gitignored)
