# NetworkPolicy — east-west isolation (Pass-5 Open Item #3)

k3s enforces NetworkPolicy through its bundled **kube-router** controller (the install never passes
`--disable-network-policy`). "Internal-only" was previously enforced only as "no public HTTPRoute";
these policies add real east-west isolation so a compromised public `api`/`ssr` pod cannot move
laterally to the database/admin tier.

## What is enforced

| Namespace | Direction | Default | Allows |
|-----------|-----------|---------|--------|
| `prod` (apps) | Ingress | **deny** | gateway→:8080, observability→:9090, intra-prod app→app :8080, kubelet probes (pod CIDR) |
| `prod` (apps) | Egress  | **deny** | DNS (kube-system CoreDNS), database:5432, intra-prod app→app :8080 |
| `database` (CNPG) | Ingress | **deny** | prod→:5432, cnpg-system (operator), observability→:9187, intra-ns, kubelet probes |
| `database` (CNPG) | Egress | *open* (see below) | — |

The "compromised app must not reach the database" boundary is enforced **in depth** from both sides:
prod can only egress to `database:5432`, and `database` only accepts ingress from prod on 5432
(plus the operator/metrics/intra). Apps get **no general internet egress** by default — an app that
needs it ships its own additive `NetworkPolicy`.

Placement: `prod` policies are this component (auto-discovered by the `platform-components`
ApplicationSet at `platform/*/prod`); `database` policies live with their tier in
`platform/cnpg/prod/networkpolicy.yaml` (synced by the `cnpg-data` Application).

## Deliberate scoping (future hardening)

- **`database` egress is intentionally left open.** CNPG instances must reach the Kubernetes API,
  the R2 object store (barman/rclone), Telegram/healthchecks, and each other for streaming
  replication. Mapping that egress set precisely needs a live cluster; locking it down is tracked as
  follow-up hardening (do it with the live egress in front of you + a connectivity test).
- **Only `prod` and `database` are covered.** They are the public attack surface and the crown
  jewel. Extending default-deny to `gateway`/`edge`/`observability`/etc. is additive future work and
  must avoid `kube-system`/`argocd` (denying those breaks DNS/CD).
- **Intra-prod app→app (`:8080`) is intentionally allowed** (`allow-intra-prod-http`) so server-side
  calls between co-tenant apps in the same trust tier (e.g. SSR/web→api) work. Full app-to-app
  isolation is a stricter posture we deliberately did not take; it would require per-app allow pairs
  and break SSR→API by default. The prod→`database` boundary is unaffected.

## LIVE verification (deferred — `tests/posture/network-policy.bats`)

NetworkPolicy enforcement can only be tested against a live cluster (the namespaces don't exist
until ArgoCD syncs M3/M4). At bring-up, run the posture suite to confirm:

1. **Probes survive default-deny.** The `allow-ingress-kubelet-probes` policies allow the k3s pod/
   cluster CIDR (`10.42.0.0/16`) to the probe ports. If k3s' `cluster-cidr` was customized, or the
   probe source turns out to be the node's primary IP outside that range, app/CNPG pods will go
   `NotReady` — widen the `ipBlock` to the observed probe source. **Verify pods stay Ready first.**
2. **Negative:** a pod in `default` (an unlisted namespace) cannot reach `pg-rw.database.svc:5432`.
3. **Positive:** a `prod` pod can reach `pg-rw.database.svc:5432`, and a `prod` pod cannot open an
   arbitrary external `:443` (egress default-deny).
