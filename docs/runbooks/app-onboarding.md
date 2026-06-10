# Runbook — App onboarding (the deploy chain)

Onboarding a service is a `values.yaml` for the shared chart `platform/charts/app`.
Nothing else is hand-written.

## The chain
```
pnpm gen:app <name> --kind api|worker|ssr|spa     # scaffolds apps/<name>/{src,Dockerfile,deploy/prod/values.yaml} + CI matrix entry
# add the app's own SOPS secret: apps/<name>/deploy/prod/<name>-secrets.enc.yaml
#   + a co-located secret-generator.yaml (KSOPS) + kustomization.yaml (M3 appset source #3)
pnpm gen:env <name>                               # regenerate apps/<name>/.env.example (CI drift-checks it)
git push origin main
#  → build.yaml: native arm64 buildx → ghcr.io/<owner>/<name>:sha-<gitsha>  (only changed apps)
#  → bump.yaml (serialized): verifies the :sha digest exists, write-backs apps/<name>/deploy/prod/values.yaml
#  → ArgoCD `apps` ApplicationSet (M3) renders the shared chart with the app values → syncs to ns prod
pnpm verify:app <name>                            # build→push→tag→sync→probe→route→secret; stops at the FIRST red link
```

## Wave ordering (canonical registry: platform/argocd/root/SYNC-WAVES.md)
```
CNPG-Ready gate  (cnpg-data Application Healthy; enforced per-app by the chart's wait-for-db initContainer)
  → wave 0   ConfigMap / Secret (app config)
  → wave 1   migration Job  (argocd.argoproj.io/hook: Sync — runs in the Sync phase, AFTER wave-0 config)
  → wave 2   Deployment / Service / HTTPRoute (attaches to the shared homelab Gateway)
```
ArgoCD sync-waves order resources WITHIN one Application; cross-Application DB readiness is
NOT a sync-wave — the migration Job's `wait-for-db` initContainer (`pg_isready`) is the gate.

## R6 staleness / failure path
- A push that builds but whose write-back fails → `bump.yaml`'s `if: always()` Telegram step pages.
- An app stuck OutOfSync >15m → M5's `ArgoCDOutOfSync` alert; running-digest != latest-GHCR-digest →
  M5's `ImageDigestDrift`. `pnpm verify:app` catches the placeholder-tag (`sha-0000000`) case locally.

## Memory gate
Per-runtime memory limit is a hard onboarding gate: the chart `values.schema.json` rejects an
empty `resources.*.memory` at render time, and `pnpm verify:ledger` (M0) fails if the summed
limits in `docs/memory-ledger.md` exceed the budget.
