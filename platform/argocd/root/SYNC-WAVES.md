# ArgoCD sync-wave ledger (global ordering) — OWNED BY M3

Lower waves sync first. The whole platform is ordered so that CD, gateway, and
the DNS/edge come up before the stateful and app tiers.

| Wave | Component(s)                                                  | Owner milestone |
|------|--------------------------------------------------------------|-----------------|
| -10  | argocd (self-management Application)                          | M3              |
|  -9  | root (app-of-apps owning the ApplicationSet)                 | M3              |
|  -8  | traefik (gateway): Gateway-API CRDs + RBAC + GatewayClass + Gateway | M3        |
|  -6  | edge: cloudflared, tailscale-operator, adguard               | M3              |
|  -2  | cnpg-operator (cnpg-system)                                  | M4              |
|  -1  | cnpg Cluster (database)                                      | M4              |
|  —   | CNPG-Ready = cnpg-data Application Healthy, ENFORCED per-app by the chart's `wait-for-db` initContainer (sync-waves don't gate across Applications) | M4/M6 |
|  +2  | observability: victoria-stack (vmsingle/vmagent/VictoriaLogs/Vector/Grafana/vmalert/Alertmanager/node-exp/ksm) | M5 |

## Per-app internal waves (the shared chart, M6)
| Wave | Resource                                   |
|------|--------------------------------------------|
|   0  | ConfigMap / Secret (app config)            |
|   1  | migration Job (`migrate`, ArgoCD `Sync` hook — runs in the Sync phase AFTER wave-0 config, not a Helm PreSync hook) |
|   2  | Deployment / Service / HTTPRoute           |

Networking precedes apps: an app's HTTPRoute (per-app wave 2) attaches to a
Gateway that is already Programmed (wave -8). The cnpg Cluster (-1) precedes
the per-app config (0) so apps never start against an un-provisioned database;
the CNPG-Ready gate (the cnpg-data Application being Healthy) is the explicit
readiness contract M6 depends on.
