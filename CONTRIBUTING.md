# Contributing — Homelab Platform

This is a GitOps monorepo (SSOT): git is the literal source of truth, ArgoCD
reconciles the cluster. Nothing is changed by hand on the cluster.

## Golden rules
1. **Verification-first.** Every change ships with a check that failed before
   and passes after. Run `make verify` locally before pushing.
2. **No plaintext secrets, ever.** Secrets are `*.enc.yaml`, SOPS-encrypted to
   two age recipients (cluster + recovery, see `docs/runbooks/age-keys.md`).
   The pre-commit guard + gitleaks block accidents. Private keys are never
   committed (`.gitignore` covers `*.agekey`, `keys.txt`, `.env*`).
3. **Env lives in the path.** `<env>` (`prod`, later `staging`) is a directory
   segment: `platform/<svc>/<env>/...`, `apps/<name>/deploy/<env>/values.yaml`.
   Add an env by adding a directory + a `.sops.yaml` rule block — no refactor.
4. **Respect the memory ledger.** Any new/resized workload updates
   `docs/memory-ledger.md`; CI fails (`pnpm verify:ledger`) if total limits
   exceed the budget. Fix the budget at the boundary, not at OOM.
5. **Apps are opaque containers.** Onboarding = `values.yaml` for the shared
   `platform/charts/app` chart. Image contract: `/healthz`, `/readyz`, :8080
   http, :9090 metrics, non-root, a `migrate` command. Per-runtime memory is a
   hard onboarding gate.

## Commit messages (Korean conventional commits)
`type: 설명` — type ∈ `feat | fix | refactor | style | docs | test | chore`.
No AI markers, no Co-Authored-By. One logical change per commit.

## Local setup
- Install host tools: `docs/runbooks/toolchain.md`.
- `pnpm -w install`
- `pre-commit install`
- Decrypt locally: `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`

## Before you push
```
make verify          # skeleton + ledger + sops round-trip
pnpm verify:ledger   # memory budget gate
pre-commit run -a    # secret guard + gitleaks
```
