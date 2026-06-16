# ArgoCD sync-wave 원장 (전역 순서) — M3 소유

낮은 wave가 먼저 sync된다. 플랫폼 전체는 CD, gateway, DNS/edge가
stateful 계층과 앱 계층보다 먼저 올라오도록 순서가 잡혀 있다.

| Wave | 컴포넌트                                                      | 담당 마일스톤   |
|------|--------------------------------------------------------------|-----------------|
| -10  | argocd (자기 관리 Application)                                | M3              |
|  -9  | root (ApplicationSet을 소유하는 app-of-apps)                  | M3              |
|  -8  | traefik (gateway): Gateway-API CRDs + RBAC + GatewayClass + Gateway; sealed-secrets (controller) | M3 |
|  -6  | edge: cloudflared, tailscale-operator, adguard               | M3              |
|  -3  | cert-manager: barman-plugin webhook 인증서 발급(plugin -2보다 먼저) | M4         |
|  -2  | cnpg-operator (cnpg-system) + cnpg-barman-plugin             | M4              |
|  -1  | cnpg Cluster (cnpg-data, database)                           | M4              |
|  —   | CNPG-Ready = cnpg-data Application Healthy, 차트의 `wait-for-db` initContainer가 앱별로 강제 (sync-wave는 Application 경계를 넘어 게이트하지 못함) | M4/M6 |
|  +2  | observability: victoria-stack (vmsingle/vmagent/VictoriaLogs/Vector/Grafana/vmalert/Alertmanager/node-exp/ksm) | M5 |

## 앱별 내부 wave (공유 차트, M6)
| Wave | 리소스                                     |
|------|--------------------------------------------|
|   0  | ConfigMap / Secret (앱 설정)               |
|   1  | migration Job (`migrate`, ArgoCD `Sync` hook — Helm PreSync hook이 아니라 wave-0 설정 이후 Sync 단계에서 실행) |
|   2  | Deployment / Service / HTTPRoute           |

네트워킹이 앱보다 앞선다: 앱의 HTTPRoute(앱별 wave 2)는 이미 Programmed 상태인
Gateway(wave -8)에 attach된다. cnpg Cluster(-1)가 앱별 설정(0)보다 앞서므로
앱이 프로비저닝되지 않은 데이터베이스를 상대로 기동하는 일이 없다.
CNPG-Ready 게이트(cnpg-data Application이 Healthy인 상태)는 M6가 의존하는
명시적 준비(readiness) 계약이다.
