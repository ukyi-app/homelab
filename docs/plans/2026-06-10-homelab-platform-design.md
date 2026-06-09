# Homelab Platform — Design

**Date:** 2026-06-10
**Status:** Approved (brainstorming Phase A) — proceeds to detailed implementation plan + adversarial review.
**Hardware:** Mac mini M4, 16 GiB unified RAM, 512 GB internal SSD + 1 TB external SSD. macOS host (Darwin arm64). Single physical node.

---

## 1. Goal & Priorities

A single-node, GitOps-driven homelab platform that hosts polyglot application services (backend API, worker, frontend SPA + SSR) plus a future media/image service, with first-class developer experience.

Priorities, in strict order:

1. **DX** — paramount.
2. **SSOT** — single source of truth (one monorepo drives everything declared).
3. **Extensibility** — adding an app or an environment is cheap.
4. **Maintainability** — easy to reason about and recover.
5. **16 GiB memory efficiency** — ruthless, but never at the cost of 1–4.

The adversarial review of this design surfaced a key insight: the design must **not over-optimize priority #5 at the expense of #1**. The two things most likely to hurt in 6 months are (a) an unverified DB restore path and (b) memory pressure during real concurrent development — neither is a config-tuning problem. Both are addressed as first-class hardening (§9).

---

## 2. Confirmed Decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| D1 | Repo topology | **Monorepo, app-of-apps** | SSOT + DX; adding an app = adding one directory. |
| D2 | Secrets | **SOPS + age (KSOPS in ArgoCD repo-server)** | Encrypted secrets committed to the monorepo; near-zero steady-state RAM; no vault sidecar. |
| D3 | "Image server" meaning | **Media/image storage service** (future), backed by 1 TB SSD; container registry = **GHCR**. | Disambiguated. |
| D4 | Backup | **3-2-1: live PVC + local 1 TB base-backup + Cloudflare R2 offsite** | Offsite safety + fast local restore. |
| D5 | Cloudflare domain | **Zone already on Cloudflare** | Terraform manages DNS/Tunnel/WAF/Cache directly. |
| D6 | App stack | **Server/worker: polyglot (any language); frontend: TypeScript** (SPA = Vite, SSR = Next/SvelteKit) | Platform treats apps as opaque containers via a uniform contract. |
| D7 | Environments | **Single `prod` deployed, but the env-axis is baked into the structure now** | Adding staging/preview later is a directory/generator dimension, zero refactor. |
| D8 | Inner-loop dev | **Local `pnpm dev` + GitOps only** (no Tilt/Skaffold); local **containerized Postgres** for dev, not prod port-forward. | Simple, low-RAM, data-safe. |
| D9 | VM/host RAM split | **OrbStack VM = 11 GiB / macOS = 5 GiB** (server-primary; dev happens on another device via Tailscale) | Maximizes platform headroom. |
| D10 | DB migrations | **App-native tools** (Prisma/Drizzle/golang-migrate/Alembic…); platform contract is "image exposes a `migrate` command". | Uniform contract, native DX per language. |
| D11 | SPA hosting | **In-cluster static serving via `static-web-server` (SWS, Rust)** | ~5–10 MiB RSS, SPA fallback built-in; keeps SSOT single-pane in ArgoCD (closes the split-deploy-surface gap). Abstracted behind chart value `spa.server` so Caddy can replace it later if edge logic is needed. |

---

## 3. Architecture Overview

```
                    Internet
                       │
              Cloudflare edge (WAF + Cache Rules + TLS)
                       │  (cloudflared outbound tunnel — 0 inbound ports)
   ┌───────────────────┼──────────────────────────────────────────────┐
   │  macOS host (M4, 16 GiB)                                          │
   │   OrbStack helper (~150–400 MiB, host-side)                       │
   │   ┌──────────────── ONE OrbStack Linux VM (Debian arm64, 11 GiB)──┴───┐
   │   │  k3s single-node (SQLite/kine; servicelb kept; traefik/local-     │
   │   │  storage/metrics-server/helm-controller disabled)                 │
   │   │                                                                   │
   │   │  Traefik v3 (Gateway API)  ◄── cloudflared (public)               │
   │   │        ▲                    ◄── Tailscale operator (internal)     │
   │   │        │ HTTPRoute                                                │
   │   │   ┌────┴─────┬──────────┬──────────┬──────────┐                   │
   │   │  api      worker      ssr        spa(SWS)   media(future)         │
   │   │   │          │                                                    │
   │   │   └──► CloudNativePG (1 instance) ──► WAL/base ──► R2 + local 1TB  │
   │   │                                                                   │
   │   │  ArgoCD (app-of-apps, HA off, KSOPS)  ◄── monorepo (GitHub)       │
   │   │  Observability: vmsingle+vmagent+VictoriaLogs+Vector+Grafana      │
   │   │                 +vmalert+Alertmanager(→Telegram)+node-exp+ksm     │
   │   │  AdGuard Home (LAN DNS, split-horizon)                            │
   │   └───────────────────────────────────────────────────────────────┘ │
   │  Storage: internal 512GB SSD = 'standard' SC (Postgres/config)        │
   │           external 1TB SSD = 'bulk-ssd' SC (media + local backups)    │
   └───────────────────────────────────────────────────────────────────────┘

External (off-node): dead-man's-switch (healthchecks.io) ◄── Alertmanager Watchdog
CI: GitHub-hosted arm64 runners → buildx → GHCR(:sha) → commit tag → ArgoCD sync
```

**Control-plane boundary (SSOT seam):**
- **Terraform** owns everything *outside* the cluster: Cloudflare (DNS, Tunnel, WAF, Cache Rules, R2 buckets + creds, Pages project if used), GitHub (repo, branch protection, Actions secrets), Tailscale (ACLs, tags, split-DNS, OAuth client), and the **one-time** ArgoCD install (via `make bootstrap`).
- **ArgoCD** owns everything *inside* the cluster, including its own upgrades.
- No live runtime coupling: Terraform emits outputs (R2 keys, tunnel token) that are SOPS-encrypted into seed secrets in the monorepo.

---

## 4. Layer 1 — Runtime Foundation (OrbStack VM + k3s + storage)

- **One** OrbStack Linux VM (Debian bookworm arm64), provisioned via **cloud-init committed to the repo** (closes the biggest SSOT leak: host substrate as code). Memory ceiling **11 GiB**, 6 vCPU. OrbStack returns idle RAM to macOS, so 11 is a ceiling not a reservation.
- **Hard rule:** this OrbStack instance runs **exactly one machine** (the k3s VM) — no stray `docker run`, no OrbStack-bundled k8s. The OrbStack memory cap is **global** to the whole OrbStack environment, so a second machine/containers would silently contend. `orb list` showing a single machine is part of the health check.
- **k3s** single-node, all-in-one server. Disable what we replace or don't need:
  `--disable=traefik` (own Traefik via Gateway API), `--disable=local-storage` (own dual local-path), `--disable=metrics-server` (vmagent scrapes kubelet/cAdvisor), `--disable-helm-controller` (ArgoCD is sole renderer). **Keep `servicelb`** (on a single node it simply publishes Traefik on the VM node IP at :80/:443 — simpler than hostPort, no MetalLB). Keep CoreDNS and default flannel/VXLAN CNI (no Cilium — would burn 300–600 MiB for zero benefit here).
- **Datastore:** default **SQLite (kine)**, *not* embedded etcd (single node; ~250–400 MiB lighter; one-file backup).
- **Node protection:** `--kube-reserved`/`--system-reserved` (cpu=250m,memory=512Mi each) + `--eviction-hard=memory.available<250Mi,nodefs.available<10%` so a runaway pod can't OOM the kubelet. Image GC thresholds 80/70.
- **Secrets at rest:** enable `--secrets-encryption` from day one (SOPS-decrypted secrets land in the datastore).
- **Storage — two local-path StorageClasses:**
  - `standard` (default): VM-internal path on the **512 GB SSD** — Postgres (PGDATA + separate `walStorage` PVC), configs. `reclaimPolicy: Retain` for DB PVs.
  - `bulk-ssd` (not default, `WaitForFirstConsumer`): the **1 TB external SSD** bind-mounted via OrbStack — media service + local backup staging **only**. **Never Postgres** (VirtioFS fsync/random-IO is unsafe for WAL).
- **zram** (zstd, ~1–2 GiB) via cloud-init as an OS-level OOM cushion; k3s kubelet stays swap-unaware.
- VM is **cattle**: cloud-init + k3s install scripted in the monorepo → a full rebuild is a ~5-minute scripted operation, and ArgoCD + R2 restore repopulate all state.

## 5. Layer 2 — GitOps / SSOT / CD

- **ArgoCD** with all HA disabled (single node): controller/repo-server/server/applicationset/redis each `replicas=1`, `redis-ha.enabled=false`. Tune `--status-processors 4 --operation-processors 2` (vs default 20), `repo-server --parallelismlimit=2`, and `resource.exclusions` for events/endpoints/EndpointSlice (cuts diff churn ~20–30%). ArgoCD self-manages via its own Application (pinned chart).
- **app-of-apps + ApplicationSet** (git-directory generator) over `apps/*` and `platform/*`, **with the env-axis as a generator dimension** (D7) so the path encodes `…/<env>/values.yaml`. New app = new directory; new env = new generator dimension, no structural rewrite.
- **SOPS + age via KSOPS** as a Kustomize exec plugin inside the repo-server (decrypt at render time; **no always-on pod**). `.sops.yaml` has **env-scoped** creation rules keyed by path. The age **private key** is delivered out-of-band as a Secret during bootstrap and **never committed**; every secret is encrypted to **two recipients** (cluster key + an offline recovery key in a password manager) so losing the in-cluster key is not game-over.
- **Image flow (CI is pull-based, git is literal SSOT):** GitHub-hosted **arm64** runners (`ubuntu-24.04-arm`, native — no QEMU) → `docker buildx` → push GHCR as immutable `:sha-<gitsha>` → a **serialized** (concurrency-grouped) bot commit bumps `deploy/<env>/values.yaml` (only that file) → GitHub webhook → ArgoCD sync. No argocd-image-updater. Staleness is made observable cluster-side (ArgoCD `OutOfSync > N min` alert + a recording rule comparing running digest vs latest GHCR digest).
- **Bootstrap = one idempotent `make bootstrap`** (collapses the chicken-and-egg chain: R2 state bucket bootstrapped manually once with a committed backend config; ArgoCD installed; age Secret created; root app applied). The quarterly **rebuild drill doubles as the DR drill**.

## 6. Layer 3 — Networking / Gateway / DNS / Edge

- **Traefik v3** as the single **Gateway API** controller (own deploy under ArgoCD, not the k3s bundle). One `GatewayClass=traefik`, one `Gateway`, every app attaches an `HTTPRoute`. Includes the explicit Gateway-API RBAC ClusterRole (known k3s gap). Access logs JSON→stdout for VictoriaLogs.
- **Public path:** `cloudflared` (1 replica) outbound tunnel → Traefik ClusterIP over plaintext in-cluster. Cloudflare edge terminates TLS, applies **WAF + Cache Rules**. **Zero inbound ports** on the Mac. Cache Rules scoped to static asset paths only (`/assets/*`, `/_next/static/*`) and **bypass for API + SSR HTML** (else per-user content leaks).
- **Internal path:** **Tailscale Operator** exposes **Traefik once** via a Tailscale Ingress; all `*.int` hostnames route through that single proxy pod (HTTPRoute), keeping proxy count to one. MagicDNS + Tailscale-issued TLS — no internal cert-manager.
- **Default posture: internal-by-default; apps opt into public explicitly.** Frontends (SPA/SSR) + backend API are public; ArgoCD, Grafana, AdGuard UI, Traefik dashboard, VictoriaMetrics/Logs, and the media service are internal-only.
- **AdGuard Home** = LAN DNS (ad-blocking + split-horizon `*.int.<domain>` rewrites pointed at the **stable Tailscale IP**, not the unstable VM IP). **Router must have a secondary upstream DNS (1.1.1.1)** so the household degrades to "no ad-block" instead of "no internet" when the VM is down. AdGuard does **DNS only** (router keeps DHCP). CoreDNS stays cluster-internal.
- All Cloudflare + Tailscale resources are **Terraform-managed**.

## 7. Layer 4 — Data / Storage / Backup

- **CloudNativePG**, single instance (`instances: 1`). `shared_buffers=256MB` **tied to the pod limit (1 GiB), not host RAM** (the 25%-of-host trap = 4 GB = instant OOM). `effective_cache_size=512MB`, `work_mem=8MB`, `maintenance_work_mem=128MB`, `max_connections=50`. PGDATA + **separate `walStorage` PVC** both on the internal 512 GB SSD.
- **PgBouncer (CNPG Pooler)** now — all polyglot apps pool through it so `max_connections` stays low (~10 MiB/backend saved as apps multiply).
- **3-2-1 backup:**
  - copy 1 = live PVC (internal SSD).
  - copy 2 (local) = nightly **`pg_basebackup` CronJob → PVC on the 1 TB external SSD** (chosen over a MinIO/SeaweedFS S3 gateway to save ~80–150 MiB idle).
  - copy 3 (offsite) = barman-cloud CNPG-I plugin → **Cloudflare R2** (`endpointURL=https://<acct>.r2.cloudflarestorage.com`, `AWS_REGION=auto`), continuous WAL archiving + daily `ScheduledBackup`, retention 14d offsite / 7d local. `archive_timeout=5min` (RPO ≈ 5 min).
- **No Velero** (cluster state = git; the only stateful tier = Postgres is covered).
- **Media service:** PVC (RWO) on `bulk-ssd`, with **R2 as durable origin and the local SSD as hot cache** so its RSS stays ~128–384 MiB regardless of dataset size. Never hostPath.
- **R2 lifecycle** managed by Terraform; backups bucket separate from media bucket.

## 8. Layer 5 — Observability & Alerting

- **No VictoriaMetrics operator** (avoids ~100 MiB controller + enterprise default sizes). Plain Helm charts + **static scrape configs** (single static node — CRD service discovery buys nothing).
- Components: **vmsingle** (`-retentionPeriod=30d`, byte-capped), **vmagent** (one replica, `-promscrape.noStaleMarkers`), **VictoriaLogs** (14d, byte-capped), **Vector** daemonset (log shipper → VictoriaLogs ES-bulk endpoint), **Grafana** (datasources + dashboards **provisioned from git** = SSOT; SQLite on emptyDir, ephemeral by design), **vmalert** (rules-as-code), **Alertmanager** (native `telegram_configs`, gossip disabled), **node-exporter**, **kube-state-metrics**.
- **Retention uses byte caps (`-retention.maxDiskSpaceUsageBytes`), not percent** — the 1 TB SSD is shared with media/backups, so a percent threshold would evict recent metrics exactly when an incident fills the disk.
- **GOMEMLIMIT** set to ~90% of pod limit on all Go components (vmsingle/vmagent/VictoriaLogs/Vector/cloudflared/ksm) — cleanest knob against burst OOM.
- **Alerting → Telegram** two independent paths: (a) cluster alerts via Alertmanager; (b) **CI/deploy notifications via a direct `curl` to the Bot API from GitHub Actions** (survives cluster outages).
- **Off-node dead-man's-switch** (healthchecks.io cron pinged by an always-firing Alertmanager `Watchdog`) — the one observability gap that cannot be self-hosted on the thing being monitored.
- New apps are auto-scraped via `prometheus.io/scrape` pod annotations (no central scrape-config edit) — keeps onboarding DX high.

## 9. Layer 6 — App Platform & DX

- **One shared Helm chart `platform/charts/app`** is the deploy SSOT. A polyglot service sets only `values.yaml`: `{image, kind: api|worker|ssr|spa, replicas, resources, env, secretRefs, route, db.migrate, probes, spa.server}`.
- **Language-agnostic OCI contract:** distroless/static, non-root, multi-arch arm64; `/healthz` (liveness, no deps) + `/readyz` (readiness, checks DB/queue) on :8080, metrics on :9090; SIGTERM drain (flip `/readyz`→503, finish in-flight, exit <30s) + `terminationGracePeriodSeconds: 30` + `preStop: sleep 3`. Per-runtime memory is a **hard onboarding gate** (Go/Rust 32–64Mi, Node/Python 128Mi, JVM `-XX:MaxRAMPercentage=75` limit≥384Mi, Node SSR `--max-old-space-size=200`).
- **SPA:** in-cluster `static-web-server` (D11) with SPA fallback, behind Traefik — keeps ArgoCD as the single deploy pane.
- **SSR:** lean Node pod (`output: standalone` / `adapter-node`).
- **Migrations:** Helm `pre-install,pre-upgrade` hook Job running the app image's `migrate` command, ArgoCD **sync-wave** ordered (wave 0 = ConfigMap/Secret + CNPG-Ready gate, wave 1 = migration Job, wave 2 = Deployment/Service/HTTPRoute) so the app never starts against an un-migrated schema. Migrations must be backward-compatible (expand/contract).
- **Inner loop:** root `pnpm dev`; the default dev DB is a **local containerized Postgres seeded from a sanitized snapshot** (not prod port-forward). `.env.example` is **generated from / CI-validated against** the chart's ConfigMap schema so local and cluster env can't silently diverge.
- **Onboarding:** `pnpm gen:app` scaffolds `apps/<name>/` (src skeleton, Dockerfile, `deploy/<env>/values.yaml`, CI matrix entry). `pnpm verify:app <name>` walks the build→push→tag→sync→probe→route→secret chain and reports exactly which link is red.

## 10. Memory Budget (the enforced ledger)

VM cap **11 GiB**; macOS **~5 GiB**. Numbers are realistic small-homelab steady state.

| Group | req | limit |
|---|---|---|
| k3s server+agent + VM OS + CoreDNS/storage/servicelb | ~1.05 GiB | ~1.7 GiB |
| ArgoCD (6 pods, HA off) | 0.58 GiB | 1.44 GiB |
| CloudNativePG (operator + pg + pooler + barman) | 0.93 GiB | 1.45 GiB |
| Observability (9 pods) | 0.83 GiB | 1.92 GiB |
| Edge (Traefik + cloudflared + tailscale + AdGuard) | ~0.23 GiB | ~0.58 GiB |
| Apps (api + worker + ssr + spa) | ~0.36 GiB | 0.72 GiB |
| Media service (future) | 0.13 GiB | 0.38 GiB |
| **Total (incl. media)** | **~4.1 GiB** | **~8.2 GiB** |

- Limit-overcommit ratio ≈ **0.62× → not overcommitted**; every pod can hit its limit at once without node OOM.
- Steady-state RSS ≈ **3.5 GiB**; remaining ~7.5 GiB is kernel page cache (Postgres/VM rely on it) + burst headroom.
- **The ledger is committed to git and CI-gates new-app onboarding** — onboarding fails loudly at the budget boundary rather than at OOM. The binding constraint is the macOS side during native dev, which is why dev happens on another device (D9).

## 11. Repository Layout

```
infra/
  cloudflare/        # dns, tunnel, waf, cache-rules, r2, (pages if used)
  github/            # repo, branch protection, actions secrets
  tailscale/         # acls, tags, split-dns, oauth client
  k3s-bootstrap/     # cloud-init, k3s install script, orb config
platform/
  argocd/
    root/            # root app-of-apps + ApplicationSet (env-axis generator)
    argocd-app.yaml  # ArgoCD self-management (pinned chart)
  charts/app/        # the shared deploy chart (SSOT)
  traefik/  cnpg/  victoria-stack/  adguard/  cloudflared/  tailscale/
  **/<env>/*.enc.yaml  # SOPS+age, env-scoped
apps/
  <name>/
    src/             # polyglot source (pnpm workspace member if TS)
    Dockerfile
    deploy/<env>/values.yaml
.sops.yaml           # env-scoped age recipient rules
pnpm-workspace.yaml
Makefile             # make bootstrap (idempotent entry point = DR path)
docs/plans/          # this design + the implementation plan
```

## 12. Risk Register & Hardening

| # | Risk | Sev | Hardening (baked into the design) |
|---|---|---|---|
| R1 | **CNPG restore-from-R2 unverified** (barman-cloud + R2 S3-compat has documented restore failures); R2 is the only offsite copy of the only stateful tier. | 🔴 Critical | Mandatory **restore drill** (stand up → backup → destroy → restore into a fresh Cluster CR), made a **recurring monitored job** with a Telegram pass/fail gate. **Hedge:** a second offsite path (`pg_dump \| rclone → R2`, `AWS_REGION=auto`). Treat "backup green" and "restore works" as two independent monitored facts. |
| R2 | **16 GiB pressure silently kills DX** during real dev. | 🟠 High | Git-committed **memory ledger** + CI onboarding gate; VM=11 GiB with dev offloaded to another device (D9); per-runtime memory hard gate. |
| R3 | **OrbStack memory cap is global**, shared across all OrbStack machines/containers. | 🟠 High | Hard rule: exactly one OrbStack machine; `orb list` single-machine health check; VM is reproducible cattle. |
| R4 | **External 1 TB SSD (VirtioFS) on 3 critical paths** (backup, retention, media); shared-disk percent caps evict recent telemetry during incidents. | 🟠 High | No co-mingling: VM/VLogs use **byte caps**; external SSD = media + backup staging only; disk-fill Telegram alerts; backup-job liveness alert (so a silently-unmounted drive pages you). |
| R5 | **Bootstrap chicken-and-egg chain** is the least-exercised, DR-critical path. | 🟡 Med | One idempotent `make bootstrap`; quarterly rebuild drill = DR drill; two age recipients; R2 state bucket bootstrapped once. |
| R6 | **CI tag write-back silent failure** → app runs yesterday's image. | 🟡 Med | Cluster-side staleness alerts (OutOfSync > N min + digest-compare rule); serialized write-back; fail loudly on non-zero exit. |
| R7 | **AdGuard as sole LAN DNS = household SPOF** inside the most resettable component. | 🟡 Med | Router secondary upstream DNS; split-horizon → stable Tailscale IP; ad-block is best-effort, never load-bearing. |
| R8 | **Single-replica everything** → every reboot is a full-stack outage; no external failure detector. | 🟢 Low | **Off-node dead-man's-switch** now; scheduled maintenance windows; ArgoCD self-heal; documented RTO. |

## 13. Extensibility & SSOT Notes (carried into the plan)

- **Env-axis baked in now** (D7): staging/preview = a generator dimension + env-scoped `.sops.yaml` + env in the values path. Retrofitting later would touch everything, so it is structural from day one even though only `prod` deploys.
- **Preview environments** (PR-per-env) are realistically a **"spill to a cloud node"** feature, not same-box — the resource model can't host more than ~1–2 preview stacks. Named explicitly as out-of-scope for this hardware.
- **Shared-chart escape hatch:** watch the *first* app that needs a sidecar/second-port/PVC — `extraManifests` passthrough exists but is where value-only onboarding can erode. A conscious review gate, not silent bloat.
- **Polyglot tax:** each new *language* (not just app) adds a small tax in migration tooling + scaffolding templates + metrics/log conventions — acknowledged, not hidden.

## 14. Out of Scope (for now)

- Multi-node / HA (single node is the deliberate tradeoff).
- HPA / metrics-server (re-enable ~40–60 MiB only if HPA is adopted; until then a Grafana node/pod-memory dashboard is the `kubectl top` replacement).
- PR-preview environments on this hardware (see §13).
- An internal CA for pretty `*.int` HTTPS (Tailscale `*.ts.net` TLS is sufficient).

## 15. Open Items Deferred to the Implementation Plan

- Exact OrbStack memory/CPU config mechanism (GUI vs `orb config`) and cloud-init contents.
- Postgres major version + whether a custom image with extensions (e.g. pgvector) is needed.
- SSR framework choice (Next.js vs SvelteKit) — affects only the chart's SSR sizing default.
- Scaffold engine (`turbo gen` vs plop/hygen vs custom `pnpm gen:app`) given non-TS skeletons.
- Whether to keep metrics-server during initial stabilization for `kubectl top` muscle memory.
- Second age-recovery-recipient custody location.
