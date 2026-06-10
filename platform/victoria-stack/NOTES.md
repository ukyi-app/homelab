# victoria-stack operational notes

## metrics-server stays DISABLED (k3s `--disable=metrics-server`)
We deliberately do NOT run metrics-server (saves ~40–60 MiB, §14). Consequences:
- `kubectl top nodes` / `kubectl top pods` will NOT work — this is expected, not a bug.
- **Replacement:** the Grafana dashboard `Homelab — Node & Pod Memory (uid: homelab-resources)`
  is the canonical `kubectl top` substitute. The "Pod memory vs limit" table is the live
  view of the §10 memory ledger.
- Re-enable metrics-server ONLY if/when HPA is adopted (out of scope, §14); it would also
  require dropping `--disable=metrics-server` in `infra/k3s-bootstrap`.

## Internal-only posture
Grafana, vmsingle, VictoriaLogs, vmalert, Alertmanager have NO public HTTPRoute and NO
cloudflared route. They are reachable ONLY via `*.int.<DOMAIN>` through the single
Tailscale-exposed `homelab` Gateway's `web-internal` listener (M3). Default posture =
internal-by-default (§6).

## Dead-man's-switch bootstrap dependency
The off-node detector lives at healthchecks.io (external account, see Task 5.16 / Makefile
bootstrap step). If the node dies, the relay stops pinging and healthchecks.io pages you.
This is the ONE observability signal that cannot be self-hosted on the monitored node (R8).
