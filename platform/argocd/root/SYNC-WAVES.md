# ArgoCD sync-wave 원장 (전역 순서) — M3 소유

낮은 wave가 먼저 sync된다. CD(-10/-9)와 gateway(traefik·sealed-secrets, -9/-8)가 가장 먼저
올라오고, 그 다음 stateful 계층(cert-manager -3 → cnpg -2/-1)이며, edge(cloudflared/
tailscale/adguard, sync-wave 미지정 = 기본 0)와 observability(+2)는 그 뒤에 온다.

⚠️ **ArgoCD는 wave N의 전 리소스가 Healthy가 될 때까지 wave N+1로 넘어가지 않는다.** 그래서
"health가 늦은 wave의 무언가를 기다리는 리소스"를 앞 wave에 두면 **자기 자신을 기다리는 교착**이 된다
(콜드스타트에서만 드러난다 — 라이브에서는 전부 이미 존재해 순서가 무의미하다). 2026-08-14 NUC
콜드스타트에서 이 클래스로 4건이 나왔다: `#460`(ObjectStore) · `#461`(KSOPS Secret) ·
`#462`(Gateway API CRD) · Gateway↔traefik 컨트롤러. **음수 wave를 새로 붙일 때는 그 리소스의
health를 세워 주는 주체가 더 앞 wave에 있는지 반드시 확인할 것.**

| Wave | 컴포넌트                                                      | 담당 마일스톤   |
|------|--------------------------------------------------------------|-----------------|
| -10  | argocd (자기 관리 Application)                                | M3              |
|  -9  | root (ApplicationSet을 소유하는 app-of-apps)                  | M3              |
|  -9  | traefik: Gateway-API CRD 8개 (`kustomization.yaml`의 patch가 붙인다 — 번들은 upstream 그대로) | M3 |
|  -8  | traefik: gateway ns RBAC(ServiceAccount + ClusterRole/Binding — 컨트롤러 파드의 전제); sealed-secrets (controller) | M3 |
|  -3  | cert-manager: barman-plugin webhook 인증서 발급(plugin -2보다 먼저) | M4         |
|  -2  | cnpg-operator (cnpg-system) + cnpg-barman-plugin             | M4              |
|  -1  | cnpg Cluster (cnpg-data, database)                           | M4              |
|  —   | CNPG-Ready = cnpg-data Application Healthy (sync-wave는 Application 경계를 넘어 게이트하지 못함). 앱은 부팅 시 멱등 self-migrate + readiness 재시도로 DB 미준비를 흡수 | M4/M6 |
|  0   | edge + 앱-지원: cloudflared, tailscale-operator, adguard, cache, data-conn, ghcr-pull, network-policies, cert-manager-netpol, homepage, files (sync-wave 미지정 → platform-components ApplicationSet이 기본 wave 0로 발견; appset 제외 = argocd/cnpg/victoria-stack/charts/sealed-secrets/namespaces) | M3 |
|   1  | argocd-extras: ukkiee 계정 패치 SealedSecret (PR2: argocd UI HTTPRoute web-internal-tls) | (argocd-ui) |
|  +2  | observability: victoria-stack (vmsingle/vmagent/VictoriaLogs/Vector/Grafana/vmalert/Alertmanager/node-exp/ksm) | M5 |

## traefik 내부 wave (`platform/traefik/prod`) — 콜드스타트 순서의 SSOT

Gateway API 리소스는 **그것을 Healthy로 만들어 주는 컨트롤러보다 뒤**에 와야 한다.
가드: `platform/traefik/prod/test_gateway_sync_wave.bats`

| Wave | 리소스                                                        | 왜 여기인가 |
|------|---------------------------------------------------------------|-------------|
|  -9  | Gateway API CRD 8개 (kustomization patch)                      | 모든 Gateway API 리소스의 전제 |
|  -8  | ServiceAccount + ClusterRole/Binding (`rbac-gateway.yaml`)     | 컨트롤러 파드가 뜨려면 SA가 먼저 있어야 한다 |
|   0  | Helm 차트(traefik Deployment/Service) + Issuer/Certificate + KSOPS Secret | 컨트롤러와 `home-wildcard-tls`가 여기서 생긴다 |
|   1  | GatewayClass                                                   | Accepted는 컨트롤러가 붙어야 선다 |
|   2  | Gateway                                                        | Programmed는 컨트롤러 + cert Secret 둘 다 필요 |
|   3  | whoami 스모크 Deployment/Service/HTTPRoute                      | Programmed된 Gateway에 attach된다 |

## 앱별 내부 wave (공유 차트, M6)
| Wave | 리소스                                     |
|------|--------------------------------------------|
|   0  | ConfigMap / Secret (앱 설정)               |
|   2  | Deployment / Service / HTTPRoute           |

migration Job은 폐기됐다(`migrate-job.yaml`·`migrate.cmd` 제거) — 앱이 부팅 시 멱등 self-migrate한다(wave 1 없음).
네트워킹이 앱보다 앞선다: 앱의 HTTPRoute(앱별 wave 2)는 이미 Programmed 상태인
Gateway에 attach된다 — 앱 Application과 traefik Application은 별개라 traefik이 Healthy가 된
뒤에야 앱의 라우트가 붙는다(Gateway 자체의 내부 wave는 위 표대로 2다). cnpg Cluster(-1)가 앱별 설정(0)보다 앞서므로
앱이 프로비저닝되지 않은 데이터베이스를 상대로 기동하는 일이 없다(부팅 self-migrate + readiness 재시도가 잔여 레이스를 흡수).
CNPG-Ready 게이트(cnpg-data Application이 Healthy인 상태)는 M6가 의존하는
명시적 준비(readiness) 계약이다.
