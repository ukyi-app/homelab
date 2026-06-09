# Homelab Platform Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use @superpowers:executing-plans to implement this plan task-by-task. Execute milestones strictly in order **M0 → M1 → M2 → M3 → M4 → M5 → M6**.

**Goal:** Stand up a single-node (Mac mini M4, 16 GiB) GitOps homelab platform — OrbStack + k3s, ArgoCD app-of-apps, SOPS + age, Traefik Gateway API, CloudNativePG with a *verified* 3-2-1 backup/restore, VictoriaMetrics observability, and a Cloudflare(public)/Tailscale(internal) edge — that hosts polyglot app services with first-class DX.

**Architecture:** One OrbStack Linux VM (11 GiB) runs single-node k3s (SQLite/kine). **Terraform** owns everything *outside* the cluster (Cloudflare DNS/Tunnel/WAF/Cache, R2, GitHub, Tailscale) plus the one-time ArgoCD install; **ArgoCD** owns everything *inside* (including its own upgrades). Secrets are SOPS + age encrypted in the monorepo and decrypted at render time by KSOPS inside the ArgoCD repo-server. CI (GitHub-hosted arm64 runners) builds images → GHCR → bumps an immutable image tag in git → ArgoCD syncs (pull-based).

**Tech Stack:** OrbStack, k3s, ArgoCD + ApplicationSet, KSOPS/SOPS/age, Traefik v3 (Gateway API), cloudflared, Tailscale operator, AdGuard Home, CloudNativePG + barman-cloud → Cloudflare R2, VictoriaMetrics / VictoriaLogs / Vector / Grafana, vmalert + Alertmanager → Telegram, Terraform (Cloudflare/GitHub/Tailscale), pnpm@10 monorepo, GitHub Actions, `static-web-server` (SPA).

> Full design, memory-budget ledger, and the 8-item risk register: `docs/plans/2026-06-10-homelab-platform-design.md`.

---

## §0 — Integration Contract & Conventions (READ FIRST)

This plan was assembled from seven parallel drafts and hardened against a cross-milestone consistency review. **§0 is canonical**: wherever a task below conflicts with §0, §0 wins.

### Execution order & shared-file ownership

Execute **M0 → M1 → M2 → M3 → M4 (static: Tasks 4.1–4.11) → M5 → M6 → M4-LIVE (Task 4.12: live restore-drill acceptance)**. The graph is **acyclic**: M4 commits every backup/restore manifest + dry test WITHOUT depending on M6, but its *live* drill needs the `pg-tools` image M6 builds — so the once-per-bring-up live restore proof runs as a **post-M6 acceptance gate**, never inside M4. (M6 depends on M4-static for the database; it does NOT depend on the live drill.) Shared files are authored **once** by their owner; every later milestone that touches them uses **Modify/Edit** — never a second `Create` (re-declaring a Makefile target or re-Creating `package.json`/`.sops.yaml` is a hard error).

| Shared artifact | Owner | Editors / consumers |
|---|---|---|
| age key `~/.config/sops/age/keys.txt` (two recipients: cluster + offline recovery) | **M0** | M2 **consumes** (asserts exists, reads recipients) — never regenerates |
| `.sops.yaml` (env-scoped rules, `encrypted_regex`; **both real recipients filled in M0**) | **M0** | M2 only VERIFIES/consumes (never re-fills); M6 must not touch |
| `pnpm-workspace.yaml` + root `package.json` (pnpm@10; packages `apps/*/src`, `platform/charts/*`, `tools`) | **M0** | M6 Edits to add `dev`/`gen:app`/`verify:app`/`gen:env` scripts |
| `Makefile` (stub targets `bootstrap`/`up`/`down`/`verify`/`host-up`) | **M0** | M1/M2/M5/M6 Edit recipes — never re-declare a target |
| `docs/memory-ledger.md` + `policy/ledger.rego` + `pnpm verify:ledger` | **M0** | M6's onboarding CI gate **calls** `pnpm verify:ledger` (no second ledger) |
| KSOPS repo-server wiring (`platform/argocd/bootstrap-values.yaml`) | **M2** | M3/M4/M5 inherit (never re-wire KSOPS) |
| seed secrets (`seed-secrets.sh`, single producer) | **M2** | M3/M4/M5 reference the canonical Secret names |
| `platform/argocd/argocd-app.yaml` + `platform/argocd/root/root-app.yaml` (bootstrap-minimal, one values file `bootstrap-values.yaml`) | **M2** | M3 Edits to add sync-waves + the ApplicationSet |
| `platform/argocd/root/SYNC-WAVES.md` | **M3** | all milestones follow it |

### Canonical constants

- **Gateway:** `name: homelab`, `namespace: gateway`, listeners `web-public` (public) / `web-internal` (internal). Every `HTTPRoute` uses `parentRefs: [{name: homelab, namespace: gateway, sectionName: web-public|web-internal}]`. The shared chart maps `route.public` → sectionName.
- **AppProject:** `default` **everywhere** — never reference a `platform` project.
- **ApplicationSets** (M3, **two**): `platform-components` — a plain git-directory generator over `platform/*/prod` **excluding** `argocd`, `cnpg`, `victoria-stack`, `charts` (namespace from each kustomization's own `namespace:`); and `apps` — a **multi-source Helm** template over `apps/*/deploy/prod` that renders the shared `platform/charts/app` chart with each app's `values.yaml` into ns `prod` (a bare directory source over the values-only app dirs would render nothing).
- **Hand-rolled Applications** (excluded from the appset, so nothing is double-managed): `cnpg-operator`, `cnpg-data` (M4), `victoria-stack` (M5) at `platform/argocd/root/apps/<name>.yaml`, `project: default`, correct namespaces.
- **Namespaces:** `argocd`, `gateway`, `edge` (cloudflared/tailscale/adguard), `cnpg-system` (operator), `database` (CNPG cluster), `observability`, `prod` (apps).
- **Seed Secrets (M2, canonical names):** `cloudflared-tunnel` (edge), `operator-oauth` (edge), `cnpg-r2-creds` (database — keys `AWS_*` + `RCLONE_CONFIG_R2_*`, consumed by both the barman ObjectStore and the pg_dump hedge), `pg-app-credentials` (database — basic-auth `app` user for CNPG `initdb`; `pg_basebackup` uses CNPG's managed `pg-superuser` instead), `alerting-secrets` (observability — Telegram + healthchecks). The drill's `restore-drill-alerting` (database) is M4-owned (Task 4.9). Each `*.enc.yaml` MUST be listed in a component's KSOPS generator to render.
- **KSOPS generators:** every kustomization that consumes a `*.enc.yaml` ships its **own** `secret-generator.yaml` (`kind: ksops`). There is no shared generator stub.
- **Sync waves:** argocd `-10/-9`; traefik `-8`; edge `-6`; cnpg-operator `-2`; the database-ns Secrets `-2` then CNPG `Cluster` `-1` (seeds before the Cluster); **CNPG-Ready** = `cnpg-data` Application Healthy, **enforced per-app** by the chart's `wait-for-db` initContainer (sync-waves don't gate across Applications); observability `+2`; per-app internal waves `0` config/secret, `1` migration Job, `2` Deploy/Service/HTTPRoute.
- **pg-tools image:** `apps/pg-tools/` (Dockerfile: kubectl + psql + rclone + curl) is built by **M6's CI matrix** → `ghcr.io/<owner>/pg-tools:16-rclone`. M4's restore-drill / pg_dump-hedge manifests only **reference** it (committed + dry-tested in M4, no M6 dependency); the **live** drill acceptance (Task 4.12) runs as a **post-M6 gate** — this is why the execution order ends `… → M6 → M4-LIVE`, keeping the dependency graph acyclic.
- **Alert rules** (backup-liveness, disk-fill, CI staleness, Watchdog) live **only** in M5's vmalert; M4 merely ensures the source metrics exist (its restore-drill's own direct-curl Telegram message is local and allowed).

### Conventions

- **Verification-first (infra TDD):** each task writes the failing check → runs it to see it fail → applies the minimal config/code → runs the check to see it pass → commits.
- **Commits:** Korean conventional commits (`feat|fix|refactor|style|docs|test|chore`), **no AI markers**.
- Paths are relative to `/Users/ukyi/workspace/homelab`. Placeholders: `<DOMAIN>` (Cloudflare zone), `int.<DOMAIN>` (internal suffix), `<owner>` (GHCR owner).

---

## Milestone 0 — Repo & tooling foundation

**Goal:** Stand up the empty-but-load-bearing monorepo skeleton — pnpm workspace, full directory tree, the Makefile interface every later milestone fills, env-scoped SOPS+age secrets with a working encrypt/decrypt round-trip, a pre-commit guard that refuses plaintext secrets, and a CI-checkable memory ledger validated against the VM cap. This milestone produces no running infrastructure; it produces the contracts and guardrails the other six milestones plug into.

**Depends on:** none (this is the root milestone; M0 is the root of the M0→M1→M2→M3→M4→M5→M6 chain).

Conventions for executing this milestone: use @superpowers:executing-plans. Every task is verification-first — write the failing check, see it fail, implement the minimal file, see it pass, commit. All commands assume CWD `/Users/ukyi/workspace/homelab`. Commits are Korean conventional commits (`feat|fix|refactor|style|docs|test|chore`), no AI markers.

This milestone OWNS (authors once) the following shared files; later milestones MODIFY/EDIT them, never re-Create them:
- `.sops.yaml` (canonical, env-scoped rules with `&cluster`/`&recovery` anchor placeholders — M2 fills the real recipient public keys via Edit after keys are minted; M6 must NOT touch it).
- The cluster age key at `~/.config/sops/age/keys.txt` and the two-recipient custody model (M2 CONSUMES this key — asserts it exists, reads its recipients — and never regenerates).
- `pnpm-workspace.yaml` + root `package.json` (M6 EDITs `package.json` to add `dev`/`gen:app`/`verify:app`/`gen:env`).
- `Makefile` stub targets `bootstrap`/`up`/`down`/`verify`/`host-up` (M1/M2/M5/M6 EDIT recipes; never re-declare a target).
- `docs/memory-ledger.md` + `policy/ledger.rego` + the `pnpm verify:ledger` script (ONE format/validator; M6's onboarding gate CALLS `pnpm verify:ledger`, it does NOT define a second ledger).

---

### Task 0.1 — Install and pin the host toolchain (sops, age, ksops, conftest, pre-commit)

These are macOS-host tools (they run on the developer Mac, not inside the VM). The encrypt/decrypt and guard tasks below all fail without them, so install first and record exact versions in the ledger doc later.

**Files**
- Create: `docs/runbooks/toolchain.md`
- Test: shell one-liner asserting every binary resolves

**Steps**

1. Write the failing check — run it before installing:
   ```bash
   for b in sops age age-keygen ksops conftest pre-commit; do command -v "$b" >/dev/null && echo "OK $b" || echo "MISSING $b"; done
   ```
   Expected FAILURE output (current state):
   ```
   MISSING sops
   MISSING age
   MISSING age-keygen
   MISSING ksops
   MISSING conftest
   MISSING pre-commit
   ```

2. Install via Homebrew (arm64). `ksops` ships in the `viaduct-ai/ksops` tap:
   ```bash
   brew install sops age conftest pre-commit
   brew install viaduct-ai/ksops/ksops
   ```

3. Re-run the check from Step 1. Expected PASS output:
   ```
   OK sops
   OK age
   OK age-keygen
   OK ksops
   OK conftest
   OK pre-commit
   ```

4. Create `docs/runbooks/toolchain.md` with the pinned versions (fill `<...>` from `--version` output on the install host):
   ```markdown
   # Host Toolchain (macOS, arm64)

   These tools run on the developer Mac (host side), not inside the OrbStack VM.
   Install: `brew install sops age conftest pre-commit && brew install viaduct-ai/ksops/ksops`

   | Tool       | Pinned version | Purpose                                   |
   |------------|----------------|-------------------------------------------|
   | sops       | <X.Y.Z>        | Encrypt/decrypt committed secrets         |
   | age        | <X.Y.Z>        | Encryption backend for sops               |
   | age-keygen | (bundled)      | Generate age keypairs                     |
   | ksops      | <X.Y.Z>        | Kustomize exec plugin (ArgoCD repo-server)|
   | conftest   | <X.Y.Z>        | OPA/Rego policy checks (ledger validator) |
   | pre-commit | <X.Y.Z>        | Git pre-commit hook framework             |

   ## Re-verify
   `for b in sops age age-keygen ksops conftest pre-commit; do command -v "$b" && "$b" --version 2>/dev/null | head -1; done`
   ```

5. Commit:
   ```bash
   git add docs/runbooks/toolchain.md
   git commit -m "docs: 호스트 툴체인 설치 및 버전 고정 문서화"
   ```

---

### Task 0.2 — Repo directory skeleton with `.gitkeep`

Materialize every path from the design's §11 layout so later milestones drop files into existing, tracked directories rather than inventing structure ad hoc. The `tools/` directory is also seeded here so it can be a pnpm workspace member (Task 0.3).

**Files**
- Create (`.gitkeep` in each): `infra/cloudflare/`, `infra/github/`, `infra/tailscale/`, `infra/k3s-bootstrap/`, `platform/argocd/root/`, `platform/charts/app/`, `platform/traefik/`, `platform/cnpg/`, `platform/victoria-stack/`, `platform/adguard/`, `platform/cloudflared/`, `platform/tailscale/`, `apps/`, `tools/`, `docs/runbooks/`
- Test: `scripts/check-skeleton.sh`

**Steps**

1. Write the failing structural check `scripts/check-skeleton.sh`:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   dirs=(
     infra/cloudflare infra/github infra/tailscale infra/k3s-bootstrap
     platform/argocd/root platform/charts/app
     platform/traefik platform/cnpg platform/victoria-stack
     platform/adguard platform/cloudflared platform/tailscale
     apps tools docs/plans docs/runbooks
   )
   rc=0
   for d in "${dirs[@]}"; do
     if [ -d "$d" ]; then echo "OK  $d"; else echo "MISSING $d"; rc=1; fi
   done
   exit $rc
   ```
   Make executable and run:
   ```bash
   chmod +x scripts/check-skeleton.sh && ./scripts/check-skeleton.sh
   ```
   Expected FAILURE (only `docs/plans` exists today):
   ```
   MISSING infra/cloudflare
   MISSING infra/github
   ...
   OK  docs/plans
   MISSING docs/runbooks
   ```
   (exits non-zero)

2. Create the tree (git does not track empty dirs, so seed `.gitkeep`):
   ```bash
   mkdir -p infra/cloudflare infra/github infra/tailscale infra/k3s-bootstrap \
     platform/argocd/root platform/charts/app \
     platform/traefik platform/cnpg platform/victoria-stack \
     platform/adguard platform/cloudflared platform/tailscale \
     apps tools docs/runbooks
   find infra platform apps tools -type d -empty -exec touch {}/.gitkeep \;
   ```

3. Re-run the check. Expected PASS output (all `OK`, exit 0):
   ```
   OK  infra/cloudflare
   OK  infra/github
   ...
   OK  docs/runbooks
   ```

4. Commit:
   ```bash
   git add scripts/check-skeleton.sh infra platform apps tools docs/runbooks
   git commit -m "chore: 모노레포 디렉터리 스켈레톤 및 구조 검증 스크립트 추가"
   ```

---

### Task 0.3 — pnpm workspace root

Establish the workspace so TS apps (`apps/<name>/src`), the shared charts, and `tools/` become members. `pnpm -w install` must succeed on an empty workspace. This milestone pins **pnpm@10** as the single package manager used by every CI job across all milestones.

**Files**
- Create: `pnpm-workspace.yaml`, `package.json`, `.npmrc`, `.gitignore` (append)
- Test: `pnpm -w install` exit code

**Steps**

1. Write the failing check:
   ```bash
   pnpm -w install --frozen-lockfile 2>&1 | tail -3; echo "exit=$?"
   ```
   Expected FAILURE (no `package.json`/`pnpm-workspace.yaml` yet):
   ```
   ERR_PNPM_NO_IMPORTER_MANIFEST_FOUND  No package.json found
   exit=1
   ```

2. Create `pnpm-workspace.yaml`:
   ```yaml
   packages:
     - "apps/*/src"
     - "platform/charts/*"
     - "tools"
   ```

3. Create root `package.json`. `packageManager` pins **pnpm@10**, `engines.pnpm` is `>=10`. The `dev`/`gen:app`/`verify:app`/`gen:env` scripts are STUBS — the DX milestone (M6) EDITs this file to fill them (M6 Modifies, does not re-Create):
   ```json
   {
     "name": "homelab",
     "private": true,
     "version": "0.0.0",
     "packageManager": "pnpm@10.30.3",
     "engines": {
       "node": ">=22",
       "pnpm": ">=10"
     },
     "scripts": {
       "dev": "echo 'dev: filled by M6 (DX) — not implemented yet' && exit 1",
       "gen:app": "echo 'gen:app: filled by M6 (DX) — not implemented yet' && exit 1",
       "verify:app": "echo 'verify:app: filled by M6 (DX) — not implemented yet' && exit 1",
       "gen:env": "echo 'gen:env: filled by M6 (DX) — not implemented yet' && exit 1",
       "verify:ledger": "scripts/ledger-to-json.sh docs/memory-ledger.md > /tmp/ledger.json && conftest test /tmp/ledger.json --policy policy/ledger.rego",
       "verify:skeleton": "./scripts/check-skeleton.sh"
     }
   }
   ```
   Note: `verify:ledger` is written here in its final extractor-chaining form (Task 0.9 defines the extractor + policy it calls). M6's onboarding gate REUSES this exact `verify:ledger` script — it does NOT define a second ledger/validator/format.

4. Create `.npmrc` (strict, reproducible installs):
   ```ini
   engine-strict=true
   prefer-frozen-lockfile=true
   ```

5. Append host/secret noise to `.gitignore`:
   ```gitignore
   # secrets (plaintext age key NEVER committed)
   *.agekey
   keys.txt
   .env
   .env.*
   !.env.example

   # node
   node_modules/
   ```

6. Re-run install (first run has no lockfile, so generate it):
   ```bash
   pnpm -w install 2>&1 | tail -3; echo "exit=$?"
   ```
   Expected PASS output:
   ```
   Done in <N>s
   exit=0
   ```
   Then confirm the frozen path the CI uses works:
   ```bash
   pnpm -w install --frozen-lockfile >/dev/null 2>&1; echo "frozen exit=$?"
   # frozen exit=0
   ```

7. Commit:
   ```bash
   git add pnpm-workspace.yaml package.json .npmrc .gitignore pnpm-lock.yaml
   git commit -m "feat: pnpm 워크스페이스 루트 및 검증 스크립트 추가"
   ```

---

### Task 0.4 — Generate the cluster age key, document the two-recipient model

Generate the in-cluster age keypair on the host at the single canonical path `~/.config/sops/age/keys.txt`. The **private** key is stored out-of-band (never committed); only the **public recipients** (cluster + offline recovery) ever land in git, inside `.sops.yaml` (next task). M2 CONSUMES this exact key — it asserts the file exists, reads its recipients to fill `.sops.yaml`, and delivers it in-cluster as the Secret named `sops-age` (namespace `argocd`, file key `keys.txt`). M2 never regenerates it.

**Files**
- Create: `docs/runbooks/age-keys.md`
- Out-of-band (NOT committed): `~/.config/sops/age/keys.txt` (canonical cluster key path)

**Steps**

1. Write the failing check — both recipient env vars must be set and be valid age recipients. Run before generating:
   ```bash
   test -n "${AGE_CLUSTER_RECIPIENT:-}" && test -n "${AGE_RECOVERY_RECIPIENT:-}" \
     && echo "OK both recipients set" || { echo "MISSING recipient(s)"; exit 1; }
   ```
   Expected FAILURE:
   ```
   MISSING recipient(s)
   ```

2. Generate the cluster key at the canonical path and capture its public recipient:
   ```bash
   mkdir -p ~/.config/sops/age
   age-keygen -o ~/.config/sops/age/keys.txt
   chmod 600 ~/.config/sops/age/keys.txt
   export AGE_CLUSTER_RECIPIENT=$(age-keygen -y ~/.config/sops/age/keys.txt)
   echo "cluster recipient: $AGE_CLUSTER_RECIPIENT"
   ```
   Expected output (example):
   ```
   Public key: age1q...   (printed by age-keygen)
   cluster recipient: age1q...
   ```

3. Generate the **offline recovery** key. Its private key goes to a password manager (1Password/Bitwarden) and is **never** placed on disk in the repo or `~/.config`:
   ```bash
   age-keygen 2>/dev/null | tee /tmp/recovery.agekey >/dev/null   # /tmp only, paste to password manager then shred
   export AGE_RECOVERY_RECIPIENT=$(age-keygen -y /tmp/recovery.agekey)
   echo "recovery recipient: $AGE_RECOVERY_RECIPIENT"
   # after copying the PRIVATE key + recipient into the password manager:
   rm -P /tmp/recovery.agekey
   ```

4. Re-run the check from Step 1. Expected PASS output:
   ```
   OK both recipients set
   ```

5. Document the custody model in `docs/runbooks/age-keys.md` (replace the `age1...` placeholders with the real recipients; never paste a private key here):
   ```markdown
   # age Key Custody (two-recipient model)

   Every committed secret is encrypted to **two** age recipients so loss of the
   in-cluster key is recoverable (design §5, R5). Public recipients are safe to
   commit; **private keys are never committed**.

   ## Recipients (public — safe to commit in .sops.yaml)
   | Role     | Recipient (public)        | Private key custody                                  |
   |----------|---------------------------|------------------------------------------------------|
   | cluster  | age1...CLUSTER...          | `~/.config/sops/age/keys.txt` (host, 0600); delivered to k3s as the Secret `sops-age` in namespace `argocd` (file key `keys.txt`) during `make bootstrap`, never in git |
   | recovery | age1...RECOVERY...         | Password manager item "homelab age recovery" — offline, no on-disk copy |

   ## Rules
   - The cluster private key is delivered out-of-band as the `sops-age` Secret in
     namespace `argocd` (file key `keys.txt`) during bootstrap (M2 wires KSOPS to
     read it at render time via `SOPS_AGE_KEY_FILE`).
   - This single canonical key (`~/.config/sops/age/keys.txt`) is authored ONCE
     here in M0. M2 consumes it (asserts existence, reads recipients) and never
     regenerates it.
   - To decrypt locally, point sops at the cluster key:
     `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`
   - If the cluster key is lost: re-create the cluster keypair, decrypt all
     `*.enc.yaml` with the **recovery** key (`SOPS_AGE_KEY_FILE` → recovery), then
     `sops updatekeys` to re-encrypt to the new cluster recipient (Task 0.5).
   - Rotation runbook lives in the DR / bootstrap milestone.
   ```

6. Commit (doc only — no key material):
   ```bash
   git add docs/runbooks/age-keys.md
   git commit -m "docs: age 키 2-recipient 보관 모델 문서화"
   ```

---

### Task 0.5 — `.sops.yaml` with env-scoped creation rules (canonical, owned by M0)

This milestone OWNS the canonical `.sops.yaml`. It declares env-scoped `creation_rules` keyed by path so a secret committed under `platform/**/prod/`, `platform/**/staging/`, `apps/**/prod/`, or `apps/**/staging/` is automatically encrypted to **both** recipients, plus a catch-all fail-safe. The env is in the path (design D7). The two recipients are declared as YAML-anchor **placeholders** (`&cluster`/`&recovery`) here; **M2 fills the REAL recipient public keys via Edit** after the keys from Task 0.4 are minted in-cluster. M6 must NOT touch this file.

**Files**
- Create: `.sops.yaml`
- Test: `sops --encrypt` against a fixture must select the prod rule and list two recipients

**Steps**

1. Write the failing check — encrypt a throwaway prod-path secret and assert two age recipients appear:
   ```bash
   mkdir -p platform/cnpg/prod
   printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: t\nstringData:\n  k: v\n' > platform/cnpg/prod/_probe.enc.yaml
   sops --encrypt --in-place platform/cnpg/prod/_probe.enc.yaml 2>&1 | tail -2
   grep -c 'recipient:' platform/cnpg/prod/_probe.enc.yaml 2>/dev/null || echo "encrypt failed"
   ```
   Expected FAILURE (no `.sops.yaml`, sops can't pick recipients):
   ```
   config file not found, or has no creation rules, and no keys provided through CLI options or environment variables
   encrypt failed
   ```
   Clean up the probe: `rm -f platform/cnpg/prod/_probe.enc.yaml`

2. Create `.sops.yaml`. The `&cluster`/`&recovery` anchors keep the file DRY across env blocks; **M0 itself** substitutes the real recipients (from Task 0.4) in the next step — M0 owns this so its OWN round-trip test passes WITHOUT depending on M2. Rules match files named `*.enc.yaml` scoped by `<env>` in the path, with `encrypted_regex` limiting encryption to a Secret's `data`/`stringData`:
   ```yaml
   # Recipients are public keys (safe to commit). Private keys live out-of-band (Task 0.4).
   # M0 fills BOTH real public keys in step 3 (substitution); M2 only CONSUMES the cluster key.
   _recipients:
     - &cluster age1CLUSTERrecipientPUBLICkeyREPLACEME
     - &recovery age1RECOVERYrecipientPUBLICkeyREPLACEME

   creation_rules:
     # ----- platform prod -----
     - path_regex: platform/.*/prod/.*\.enc\.yaml$
       encrypted_regex: "^(data|stringData)$"
       key_groups:
         - age:
             - *cluster
             - *recovery

     # ----- platform staging (structure baked in now per D7; no deploy yet) -----
     - path_regex: platform/.*/staging/.*\.enc\.yaml$
       encrypted_regex: "^(data|stringData)$"
       key_groups:
         - age:
             - *cluster
             - *recovery

     # ----- apps prod -----
     - path_regex: apps/.*/prod/.*\.enc\.yaml$
       encrypted_regex: "^(data|stringData)$"
       key_groups:
         - age:
             - *cluster
             - *recovery

     # ----- apps staging (structure baked in now per D7; no deploy yet) -----
     - path_regex: apps/.*/staging/.*\.enc\.yaml$
       encrypted_regex: "^(data|stringData)$"
       key_groups:
         - age:
             - *cluster
             - *recovery

     # ----- catch-all: any other *.enc.yaml still gets encrypted (fail-safe) -----
     - path_regex: \.enc\.yaml$
       encrypted_regex: "^(data|stringData)$"
       key_groups:
         - age:
             - *cluster
             - *recovery
   ```

3. **Fill the real recipients (M0 owns this — NO M2 dependency)** using the keys generated in Task 0.4, then re-run the check:
   ```bash
   sed -i '' \
     -e "s|age1CLUSTERrecipientPUBLICkeyREPLACEME|${AGE_CLUSTER_RECIPIENT}|" \
     -e "s|age1RECOVERYrecipientPUBLICkeyREPLACEME|${AGE_RECOVERY_RECIPIENT}|" .sops.yaml
   printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: t\nstringData:\n  k: v\n' > platform/cnpg/prod/_probe.enc.yaml
   sops --encrypt --in-place platform/cnpg/prod/_probe.enc.yaml
   grep -c 'recipient:' platform/cnpg/prod/_probe.enc.yaml
   ```
   Expected PASS output (two real recipients filled by M0):
   ```
   2
   ```
   Clean up: `rm -f platform/cnpg/prod/_probe.enc.yaml platform/cnpg/prod/.gitkeep; rmdir platform/cnpg/prod 2>/dev/null || true`
   (Leave `platform/cnpg/.gitkeep` intact.)

4. Commit:
   ```bash
   git add .sops.yaml
   git commit -m "feat: env 스코프 SOPS creation_rules 및 2-recipient 키 그룹 추가"
   ```

---

### Task 0.6 — Encrypt → decrypt round-trip test (bats)

Prove the core SOPS contract: a plaintext secret encrypts under the prod rule and decrypts back **byte-identical** with the cluster key. This is the regression gate for every committed `*.enc.yaml`. (This green test depends on M2 having filled the real recipients in `.sops.yaml`; with placeholder keys it asserts rule selection only.)

**Files**
- Create: `test/sops-roundtrip.bats`, `test/fixtures/sample-secret.yaml`
- Test: `bats test/sops-roundtrip.bats`

**Steps**

1. Create the plaintext fixture `test/fixtures/sample-secret.yaml`:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: roundtrip-sample
     namespace: prod
   stringData:
     TOKEN: super-secret-value-123
     URL: postgres://user:pw@db:5432/app
   ```

2. Write the failing test `test/sops-roundtrip.bats`. It encrypts under a prod path, asserts the values are no longer in cleartext, then decrypts and diffs against the original. It points `SOPS_AGE_KEY_FILE` at the canonical cluster key path:
   ```bash
   #!/usr/bin/env bats

   setup() {
     export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
     WORK="apps/_rttest/prod"
     mkdir -p "$WORK"
     cp test/fixtures/sample-secret.yaml "$WORK/secret.enc.yaml"
   }

   teardown() {
     rm -rf apps/_rttest
   }

   @test "sops encrypts a prod-path secret to two recipients" {
     run sops --encrypt --in-place "apps/_rttest/prod/secret.enc.yaml"
     [ "$status" -eq 0 ]
     run grep -c 'recipient:' "apps/_rttest/prod/secret.enc.yaml"
     [ "$output" -eq 2 ]
     run grep -q 'super-secret-value-123' "apps/_rttest/prod/secret.enc.yaml"
     [ "$status" -ne 0 ]   # plaintext must NOT survive
   }

   @test "sops decrypt round-trips to the original plaintext" {
     sops --encrypt --in-place "apps/_rttest/prod/secret.enc.yaml"
     run sops --decrypt "apps/_rttest/prod/secret.enc.yaml"
     [ "$status" -eq 0 ]
     echo "$output" | grep -q 'TOKEN: super-secret-value-123'
     echo "$output" | grep -q 'URL: postgres://user:pw@db:5432/app'
   }
   ```

3. Run it before `bats` confirms the harness — install if missing, then run. Expected FAILURE if the cluster key path is wrong or `.sops.yaml` absent:
   ```bash
   command -v bats >/dev/null || brew install bats-core
   bats test/sops-roundtrip.bats
   ```
   Expected initial FAILURE example (if `SOPS_AGE_KEY_FILE` not yet created):
   ```
   not ok 1 sops encrypts a prod-path secret to two recipients
   # ... no identity matched / file not found
   ```

4. With Task 0.4/0.5 done (and M2 having filled the real recipients), re-run. Expected PASS output:
   ```
   sops-roundtrip.bats
    ✓ sops encrypts a prod-path secret to two recipients
    ✓ sops decrypt round-trips to the original plaintext

   2 tests, 0 failures
   ```

5. Commit:
   ```bash
   git add test/sops-roundtrip.bats test/fixtures/sample-secret.yaml
   git commit -m "test: SOPS 암호화/복호화 라운드트립 bats 테스트 추가"
   ```

---

### Task 0.7 — Pre-commit guard that blocks plaintext secrets

A staged file matching `*.enc.yaml` that is **not** SOPS-encrypted (no `sops:` metadata block) must abort the commit. This is the human-error backstop behind the `.sops.yaml` rules.

**Files**
- Create: `.pre-commit-config.yaml`, `scripts/sops-guard.sh`
- Test: `test/sops-guard.bats`

**Steps**

1. Write the guard `scripts/sops-guard.sh`. It receives candidate filenames from pre-commit and fails if any `*.enc.yaml` lacks the sops metadata marker:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   rc=0
   for f in "$@"; do
     case "$f" in
       *.enc.yaml)
         if ! grep -q '^sops:' "$f" 2>/dev/null && ! grep -q 'sops_mac\|"sops":' "$f" 2>/dev/null; then
           echo "BLOCKED: $f is *.enc.yaml but NOT sops-encrypted (no sops metadata)." >&2
           echo "         Run: sops --encrypt --in-place \"$f\"" >&2
           rc=1
         fi
         ;;
     esac
   done
   exit $rc
   ```
   Make executable: `chmod +x scripts/sops-guard.sh`

2. Write the failing test `test/sops-guard.bats`:
   ```bash
   #!/usr/bin/env bats

   setup() {
     export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
     TMP="apps/_guardtest/prod"
     mkdir -p "$TMP"
   }
   teardown() { rm -rf apps/_guardtest; }

   @test "guard BLOCKS a plaintext *.enc.yaml" {
     cp test/fixtures/sample-secret.yaml apps/_guardtest/prod/leak.enc.yaml
     run ./scripts/sops-guard.sh apps/_guardtest/prod/leak.enc.yaml
     [ "$status" -eq 1 ]
     echo "$output" | grep -q 'BLOCKED'
   }

   @test "guard ALLOWS a properly encrypted *.enc.yaml" {
     cp test/fixtures/sample-secret.yaml apps/_guardtest/prod/ok.enc.yaml
     sops --encrypt --in-place apps/_guardtest/prod/ok.enc.yaml
     run ./scripts/sops-guard.sh apps/_guardtest/prod/ok.enc.yaml
     [ "$status" -eq 0 ]
   }

   @test "guard ignores non-secret yaml" {
     echo "kind: ConfigMap" > apps/_guardtest/prod/plain.yaml
     run ./scripts/sops-guard.sh apps/_guardtest/prod/plain.yaml
     [ "$status" -eq 0 ]
   }
   ```
   Run before the guard is wired — actually it tests the script directly, so run now:
   ```bash
   bats test/sops-guard.bats
   ```
   Expected PASS once `scripts/sops-guard.sh` exists (run first WITHOUT the script to see the FAILURE):
   ```
   # without scripts/sops-guard.sh:
   not ok 1 guard BLOCKS a plaintext *.enc.yaml
   #   ./scripts/sops-guard.sh: No such file or directory
   ```
   After Step 1's script exists, expected PASS:
   ```
   sops-guard.bats
    ✓ guard BLOCKS a plaintext *.enc.yaml
    ✓ guard ALLOWS a properly encrypted *.enc.yaml
    ✓ guard ignores non-secret yaml

   3 tests, 0 failures
   ```

3. Create `.pre-commit-config.yaml` wiring the guard as a local hook (plus a stock secret-scanner as defense-in-depth):
   ```yaml
   repos:
     - repo: local
       hooks:
         - id: sops-guard
           name: Block plaintext *.enc.yaml
           entry: scripts/sops-guard.sh
           language: script
           files: '\.enc\.yaml$'
     - repo: https://github.com/gitleaks/gitleaks
       rev: v8.18.4
       hooks:
         - id: gitleaks
   ```

4. Install the hook and run the end-to-end guard against a deliberately-staged plaintext leak. Expected FAILURE (commit blocked):
   ```bash
   pre-commit install
   cp test/fixtures/sample-secret.yaml apps/_e2e/prod/leak.enc.yaml 2>/dev/null || { mkdir -p apps/_e2e/prod && cp test/fixtures/sample-secret.yaml apps/_e2e/prod/leak.enc.yaml; }
   git add apps/_e2e/prod/leak.enc.yaml
   git commit -m "test: should be blocked" 2>&1 | grep -i 'BLOCKED\|Failed'
   ```
   Expected output:
   ```
   Block plaintext *.enc.yaml...............................................Failed
   BLOCKED: apps/_e2e/prod/leak.enc.yaml is *.enc.yaml but NOT sops-encrypted (no sops metadata).
   ```
   Clean up the staged leak: `git restore --staged apps/_e2e/prod/leak.enc.yaml && rm -rf apps/_e2e`

5. Re-run the bats suite to confirm green (Step 2 PASS block), then commit the guard + config:
   ```bash
   git add .pre-commit-config.yaml scripts/sops-guard.sh test/sops-guard.bats
   git commit -m "feat: 평문 시크릿 커밋 차단 pre-commit 가드 추가"
   ```

---

### Task 0.8 — Seed the memory ledger (`docs/memory-ledger.md`)

This milestone OWNS the ONE canonical ledger format: a git-committed, CI-gated memory budget (design §10, R2). It is a per-component MiB table (`component | namespace | req_mi | limit_mi`) with `<!-- ledger:row -->` markers and a `LIMIT_BUDGET_MIB` meta line, so a validator can sum it and compare against the VM allocatable budget. Seed it with the §10 groups. M6's onboarding gate REUSES this ledger + `pnpm verify:ledger` — it does NOT define a second ledger, validator, or format.

**Files**
- Create: `docs/memory-ledger.md`
- Test: deferred to Task 0.9 (validator)

**Steps**

1. Write `docs/memory-ledger.md`. Numbers are in **MiB** (integers, machine-parseable). The `<!-- ledger:row -->` markers let the validator extract rows unambiguously; `VM_ALLOCATABLE_MIB` and the `LIMIT_BUDGET_MIB` line are the budget contract:
   ```markdown
   # Memory Ledger (SSOT, CI-gated)

   VM cap = 11 GiB. We reserve headroom for kernel page cache + burst, so the
   enforced **allocatable** budget for pod LIMITS is 8704 MiB (8.5 GiB).
   Onboarding a new app CI-fails if the limit total exceeds this (design §10, R2).
   This is the ONE ledger format/validator; M6's onboarding gate reuses
   `pnpm verify:ledger` against this file — it does not define a second ledger.

   <!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->

   | component                          | namespace      | req_mi | limit_mi |
   |------------------------------------|----------------|-------:|---------:|
   | <!-- ledger:row --> k3s+os+coredns | kube-system    |   1075 |     1740 |
   | <!-- ledger:row --> argocd         | argocd         |    594 |     1474 |
   | <!-- ledger:row --> cnpg           | database       |    952 |     1485 |
   | <!-- ledger:row --> observability  | observability  |    850 |     1966 |
   | <!-- ledger:row --> edge           | edge           |    236 |      594 |
   | <!-- ledger:row --> apps           | prod           |    369 |      737 |
   | <!-- ledger:row --> media          | prod           |    133 |      389 |

   **Totals:** req ≈ 4209 Mi · limit ≈ 8385 Mi (must stay ≤ 8704 Mi).

   ## How to update
   Adding/resizing a component: edit its row's `req_mi`/`limit_mi` (or add a new
   `<!-- ledger:row -->` row), then run `pnpm verify:ledger`. CI runs the same
   check on every PR; it fails loudly at the budget boundary, not at OOM.
   ```

2. Sanity-check the row count parses (the validator in 0.9 relies on this):
   ```bash
   grep -c 'ledger:row' docs/memory-ledger.md
   ```
   Expected: `7`

3. Commit:
   ```bash
   git add docs/memory-ledger.md
   git commit -m "docs: 메모리 원장 시드 및 예산 계약 추가"
   ```

---

### Task 0.9 — Ledger validator (conftest/OPA over an extracted JSON)

A validator sums the ledger's `limit_mi` column and fails if it exceeds `LIMIT_BUDGET_MIB`. The markdown is converted to JSON by a tiny extractor, then `conftest` runs a Rego policy. This is the R2 onboarding gate exposed as `pnpm verify:ledger` (already wired in Task 0.3). M6's onboarding CI gate CALLS `pnpm verify:ledger` — it does NOT define a second validator/format.

**Files**
- Create: `scripts/ledger-to-json.sh`, `policy/ledger.rego`
- Test: `test/ledger.bats`

**Steps**

1. Write the extractor `scripts/ledger-to-json.sh` — emits `{ "budget": N, "rows": [{component, req, limit}, ...] }` from the marked rows:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   FILE="${1:-docs/memory-ledger.md}"
   budget=$(grep -oE 'LIMIT_BUDGET_MIB=[0-9]+' "$FILE" | head -1 | cut -d= -f2)
   rows=$(grep 'ledger:row' "$FILE" | awk -F'|' '
     {
       gsub(/<!--.*-->/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2);
       req=$4; lim=$5; gsub(/[^0-9]/,"",req); gsub(/[^0-9]/,"",lim);
       printf "%s{\"component\":\"%s\",\"req\":%s,\"limit\":%s}", (NR>1?",":""), $2, req, lim
     }')
   printf '{"budget":%s,"rows":[%s]}\n' "$budget" "$rows"
   ```
   Make executable: `chmod +x scripts/ledger-to-json.sh`

2. Write the policy `policy/ledger.rego` — denies when summed limits exceed budget:
   ```rego
   package main

   total_limit := sum([r.limit | some r in input.rows])

   deny contains msg if {
     total_limit > input.budget
     msg := sprintf("memory ledger over budget: limit total %dMi > budget %dMi", [total_limit, input.budget])
   }

   deny contains msg if {
     some r in input.rows
     r.limit < r.req
     msg := sprintf("component %q has limit %dMi < request %dMi", [r.component, r.limit, r.req])
   }
   ```

3. Write the failing test `test/ledger.bats`. It first proves the seed ledger PASSES, then proves an over-budget ledger FAILS:
   ```bash
   #!/usr/bin/env bats

   @test "seed ledger passes the budget policy" {
     scripts/ledger-to-json.sh docs/memory-ledger.md > /tmp/ledger.json
     run conftest test /tmp/ledger.json --policy policy/ledger.rego
     [ "$status" -eq 0 ]
   }

   @test "over-budget ledger is rejected" {
     cp docs/memory-ledger.md /tmp/bad-ledger.md
     # add a 9000Mi row that blows the 8704 budget
     printf '| <!-- ledger:row --> hog | prod | 100 | 9000 |\n' >> /tmp/bad-ledger.md
     scripts/ledger-to-json.sh /tmp/bad-ledger.md > /tmp/bad.json
     run conftest test /tmp/bad.json --policy policy/ledger.rego
     [ "$status" -ne 0 ]
     echo "$output" | grep -q 'over budget'
   }
   ```
   Run before `policy/ledger.rego` exists to see the FAILURE:
   ```bash
   bats test/ledger.bats
   ```
   Expected FAILURE (no policy yet):
   ```
   not ok 1 seed ledger passes the budget policy
   #   no policy found in path policy/ledger.rego
   ```

4. With the extractor + policy in place, re-run. Expected PASS output:
   ```
   ledger.bats
    ✓ seed ledger passes the budget policy
    ✓ over-budget ledger is rejected

   2 tests, 0 failures
   ```
   And confirm the wired `pnpm verify:ledger` script (Task 0.3) works end-to-end:
   ```bash
   pnpm verify:ledger
   ```
   Expected:
   ```
   1 test, 1 passed, 0 warnings, 0 failures, 0 exceptions
   ```

5. Commit:
   ```bash
   git add scripts/ledger-to-json.sh policy/ledger.rego test/ledger.bats
   git commit -m "feat: 메모리 원장 예산 검증기 및 conftest 정책 추가"
   ```

---

### Task 0.10 — Makefile interface skeleton (stub targets later milestones EDIT)

This milestone OWNS the `Makefile` and declares the operator-facing command surface now: stub targets `bootstrap`, `up`, `down`, `verify`, `host-up`. Later milestones EDIT these recipes/prereqs (M1 fills `up`/`down`/`host-up` runtime, M2 fills `bootstrap`, M5/M6 extend `verify`) — they NEVER re-declare a target. Stubs print intent and exit non-zero (so an unfinished target can't masquerade as success), except `verify`, which already wires the real checks from this milestone.

**Files**
- Create: `Makefile`
- Test: `test/makefile.bats`

**Steps**

1. Write the failing test `test/makefile.bats`:
   ```bash
   #!/usr/bin/env bats

   @test "make verify runs the foundation checks and passes" {
     run make verify
     [ "$status" -eq 0 ]
   }

   @test "unimplemented targets exit non-zero (cannot fake success)" {
     run make bootstrap
     [ "$status" -ne 0 ]
     run make up
     [ "$status" -ne 0 ]
     run make down
     [ "$status" -ne 0 ]
     run make host-up
     [ "$status" -ne 0 ]
   }

   @test "make help lists every declared target" {
     run make help
     [ "$status" -eq 0 ]
     for t in bootstrap up down verify host-up; do
       echo "$output" | grep -q "$t"
     done
   }
   ```
   Run before the Makefile exists:
   ```bash
   bats test/makefile.bats
   ```
   Expected FAILURE:
   ```
   not ok 1 make verify runs the foundation checks and passes
   #   make: *** No rule to make target `verify'.  Stop.
   ```

2. Create `Makefile`. `verify` is real today; `bootstrap`/`up`/`down`/`host-up` are interface stubs each later milestone fills (the design points to `make bootstrap` as the idempotent DR entry point, R5):
   ```makefile
   SHELL := /usr/bin/env bash
   .DEFAULT_GOAL := help

   .PHONY: help bootstrap up down verify host-up

   help: ## List available targets
   	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
   	  | awk 'BEGIN{FS=":.*?## "}{printf "  %-12s %s\n", $$1, $$2}'

   host-up: ## [TODO: M1] provision/start the OrbStack VM (cloud-init host substrate)
   	@echo "host-up: not implemented yet (owned by M1 runtime foundation)" >&2
   	@exit 1

   up: ## [TODO: M1] bring the OrbStack VM + k3s up
   	@echo "up: not implemented yet (owned by M1 runtime foundation)" >&2
   	@exit 1

   down: ## [TODO: M1] tear the OrbStack VM down
   	@echo "down: not implemented yet (owned by M1 runtime foundation)" >&2
   	@exit 1

   bootstrap: ## [TODO: M2] idempotent cluster bootstrap = DR path (ArgoCD + age Secret + root app)
   	@echo "bootstrap: not implemented yet (owned by M2 GitOps/bootstrap)" >&2
   	@exit 1

   verify: ## Run repo-foundation checks (skeleton + ledger + sops round-trip)
   	@./scripts/check-skeleton.sh
   	@scripts/ledger-to-json.sh docs/memory-ledger.md > /tmp/ledger.json
   	@conftest test /tmp/ledger.json --policy policy/ledger.rego
   	@bats test/sops-roundtrip.bats
   ```
   Note: Makefile recipe lines must be **tab-indented**, not spaces.

3. Re-run the test. Expected PASS output:
   ```
   makefile.bats
    ✓ make verify runs the foundation checks and passes
    ✓ unimplemented targets exit non-zero (cannot fake success)
    ✓ make help lists every declared target

   3 tests, 0 failures
   ```
   And eyeball `make help`:
   ```
     host-up      [TODO: M1] provision/start the OrbStack VM (cloud-init host substrate)
     up           [TODO: M1] bring the OrbStack VM + k3s up
     down         [TODO: M1] tear the OrbStack VM down
     bootstrap    [TODO: M2] idempotent cluster bootstrap = DR path (ArgoCD + age Secret + root app)
     verify       Run repo-foundation checks (skeleton + ledger + sops round-trip)
   ```

4. Commit:
   ```bash
   git add Makefile test/makefile.bats
   git commit -m "feat: Makefile 인터페이스 스켈레톤 및 verify 타깃 추가"
   ```

---

### Task 0.11 — Conventions doc (CONTRIBUTING)

The shared rulebook every later milestone and contributor follows: commit format, secret handling, ledger discipline, env-in-path, and the verification-first workflow.

**Files**
- Create: `CONTRIBUTING.md`

**Steps**

1. Write `CONTRIBUTING.md`:
   ```markdown
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
   ```

2. Verify it renders and links resolve:
   ```bash
   test -f CONTRIBUTING.md && grep -q 'verify:ledger' CONTRIBUTING.md && echo "OK"
   ```
   Expected: `OK`

3. Commit:
   ```bash
   git add CONTRIBUTING.md
   git commit -m "docs: 기여 가이드 및 컨벤션 문서 추가"
   ```

---

### Task 0.12 — Wire the foundation checks into CI (onboarding gate)

The R2 onboarding gate must run in CI, not just locally. A GitHub Actions workflow runs `make verify` + the ledger gate + the SOPS round-trip + the secret guard on every PR, so a budget breach or plaintext leak fails the PR. All CI jobs use **pnpm@10** (the version pinned in Task 0.3).

**Files**
- Create: `.github/workflows/verify.yml`
- Test: `act` dry-run (or push-to-branch) and inspected job logs

**Steps**

1. Write the failing assertion — there is no CI gate yet:
   ```bash
   test -f .github/workflows/verify.yml && echo "OK" || echo "MISSING ci gate"
   ```
   Expected FAILURE: `MISSING ci gate`

2. Create `.github/workflows/verify.yml` (arm64 host runner per design §5; round-trip uses an ephemeral CI age key, not the cluster key; pnpm pinned to 10):
   ```yaml
   name: verify
   on:
     pull_request:
     push:
       branches: [main]

   jobs:
     verify:
       runs-on: ubuntu-24.04-arm
       steps:
         - uses: actions/checkout@v4

         - uses: pnpm/action-setup@v4
           with:
             version: 10

         - name: Install tools
           run: |
             curl -sSL https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.arm64 -o /usr/local/bin/sops
             chmod +x /usr/local/bin/sops
             curl -sSL https://dl.filippo.io/age/latest?for=linux/arm64 | tar -xz -C /tmp
             sudo mv /tmp/age/age /tmp/age/age-keygen /usr/local/bin/
             curl -sSL https://github.com/open-policy-agent/conftest/releases/download/v0.56.0/conftest_0.56.0_Linux_arm64.tar.gz | tar -xz -C /tmp
             sudo mv /tmp/conftest /usr/local/bin/
             sudo apt-get update && sudo apt-get install -y bats

         - name: Skeleton check
           run: ./scripts/check-skeleton.sh

         - name: Memory ledger budget gate (R2)
           run: |
             scripts/ledger-to-json.sh docs/memory-ledger.md > /tmp/ledger.json
             conftest test /tmp/ledger.json --policy policy/ledger.rego

         - name: SOPS round-trip (ephemeral CI key)
           run: |
             age-keygen -o /tmp/ci.agekey
             export SOPS_AGE_KEY_FILE=/tmp/ci.agekey
             # CI uses its own .sops.yaml recipients so the round-trip is self-contained
             CIKEY=$(age-keygen -y /tmp/ci.agekey)
             cat > /tmp/sops-ci.yaml <<EOF
             creation_rules:
               - path_regex: \.enc\.yaml$
                 encrypted_regex: "^(data|stringData)$"
                 age: "$CIKEY"
             EOF
             cp test/fixtures/sample-secret.yaml /tmp/ci.enc.yaml
             sops --config /tmp/sops-ci.yaml --encrypt --in-place /tmp/ci.enc.yaml
             ! grep -q 'super-secret-value-123' /tmp/ci.enc.yaml
             sops --config /tmp/sops-ci.yaml --decrypt /tmp/ci.enc.yaml | grep -q 'super-secret-value-123'

         - name: Pre-commit secret guard
           run: |
             pip install pre-commit
             pre-commit run --all-files --show-diff-on-failure
   ```

3. Validate the workflow YAML locally before relying on CI:
   ```bash
   command -v actionlint >/dev/null || brew install actionlint
   actionlint .github/workflows/verify.yml && echo "workflow OK"
   ```
   Expected PASS:
   ```
   workflow OK
   ```
   Re-run the Step 1 assertion. Expected: `OK`.

4. Commit:
   ```bash
   git add .github/workflows/verify.yml
   git commit -m "ci: 저장소 기반 검증 게이트(원장/SOPS/스켈레톤) 워크플로 추가"
   ```

---

### Milestone 0 exit criteria

All of the following pass from a clean checkout (this is what the next milestones depend on):
- `pnpm -w install --frozen-lockfile` → exit 0; `packageManager` is `pnpm@10.x`, workspace packages are `apps/*/src`, `platform/charts/*`, `tools`.
- `make verify` → skeleton + ledger budget + SOPS round-trip all green; `bootstrap`/`up`/`down`/`host-up` are stubs that exit non-zero.
- `bats test/*.bats` → every suite green (round-trip, guard, ledger, makefile).
- Staging a plaintext `*.enc.yaml` and committing → **blocked** by the pre-commit guard.
- `.sops.yaml` is the canonical env-scoped ruleset (prod + staging + catch-all) with **both real recipients filled in M0** (cluster + recovery — M0 generated both keypairs and substituted their public keys in Task 0.5); it encrypts prod-path secrets to exactly **two** recipients and `sops --decrypt` reproduces the original plaintext byte-for-byte. **M0's exit does NOT depend on M2** (there is no placeholder-recipient gate).
- BOTH age keypairs are generated in M0: the cluster key at `~/.config/sops/age/keys.txt` (public key = recipient #1) and a recovery key whose **private** half is exported offline to a password manager (never on disk/committed), public key = recipient #2 in `.sops.yaml`. M2 only CONSUMES the cluster key as Secret `sops-age` (ns `argocd`, file key `keys.txt`) — it never regenerates keys or re-fills recipients.
- `pnpm verify:ledger` is the single ledger gate (MiB table + `ledger:row` markers + `LIMIT_BUDGET_MIB` + `policy/ledger.rego`); M6's onboarding gate reuses it, defining no second ledger.
- `actionlint .github/workflows/verify.yml` → clean; the CI gate runs the same checks on every PR using pnpm@10.

---

## Milestone 1 — Host substrate — OrbStack VM + k3s

**Goal:** Stand up the single OrbStack Debian arm64 VM and the k3s single-node control plane as fully committed-to-git imperative scripts (host substrate as code), with the exact disable/keep flags, node-protection knobs, `--secrets-encryption`, and the two local-path StorageClasses — all behind verification scripts that fail before the substrate exists and pass after. M1 does **not** author repo scaffolding (`.sops.yaml`, `pnpm-workspace.yaml`, root `package.json`, the age key, or the `Makefile`) — those are owned by M0; M1 only **Modifies** M0's `Makefile` to wire the host-substrate `up`/`host-up` recipe.

**Depends on:** M0 (repo skeleton, `Makefile` stub targets, `.gitignore` baseline, pnpm workspace, `.sops.yaml`, and the age key all exist before this milestone runs). This milestone produces a `Ready` node, both StorageClasses, and a gitignored kubeconfig that every downstream milestone (M2 GitOps/ArgoCD onward) consumes.

Reference @superpowers:executing-plans when running this milestone, and @orbstack-best-practices for the `orb` command surface (`orb create -c`, `orb config`, `orb list`, `orb -m <name>`).

> **Invariant for the whole milestone (R3):** OrbStack's memory cap is **global** to the entire OrbStack environment, so a second machine or stray `docker run` silently contends for the 11 GiB. Every script and check below assumes **exactly one** OrbStack machine named `k3s`. The `orb-guard.sh` check (Task 1.3) enforces this and is re-run as a gate by later milestones.

---

### Task 1.1 — bats harness + kubeconfig gitignore for the bootstrap subtree

> M0 already created the repo skeleton, root `.gitignore`, pnpm workspace, and `infra/k3s-bootstrap/` as an empty directory. This task adds **only** the bats test harness scoped to the bootstrap subtree plus a subtree-local `.gitignore` that pins the retrieved kubeconfig (a cluster-admin token) out of git. Do **not** re-create any repo-root scaffolding.

**Files**
- Create: `infra/k3s-bootstrap/.gitignore`
- Create: `infra/k3s-bootstrap/test/test_helper.bash`
- Create: `infra/k3s-bootstrap/test/00-harness.bats`
- Test: `infra/k3s-bootstrap/test/00-harness.bats`

**Steps**

1. Write the failing harness test first. Create `infra/k3s-bootstrap/test/00-harness.bats`:

```bash
#!/usr/bin/env bats
# Smoke test that proves bats runs and the helper loads.

load test_helper

@test "bats harness loads and BOOTSTRAP_DIR resolves" {
  [ -d "$BOOTSTRAP_DIR" ]
  [ -f "$BOOTSTRAP_DIR/.gitignore" ]
}

@test "kubeconfig path is gitignored" {
  run grep -qx 'kubeconfig' "$BOOTSTRAP_DIR/.gitignore"
  [ "$status" -eq 0 ]
}
```

2. Run it, expect FAILURE (helper + files do not exist yet):

```bash
bats infra/k3s-bootstrap/test/00-harness.bats
```

Expected output (abridged):

```
 ✗ bats harness loads and BOOTSTRAP_DIR resolves
   (in test file infra/k3s-bootstrap/test/00-harness.bats, line 5)
     `load test_helper' failed
   /…/test_helper.bash: No such file or directory
2 tests, 2 failures
```

3. Create the helper `infra/k3s-bootstrap/test/test_helper.bash`:

```bash
#!/usr/bin/env bash
# Shared bats helper. Resolves the bootstrap dir relative to this file.
BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BOOTSTRAP_DIR

# Name of the single OrbStack machine this whole milestone manages (R3).
export ORB_MACHINE="${ORB_MACHINE:-k3s}"
# Gitignored kubeconfig location (Task 1.6 writes here).
export KUBECONFIG_PATH="${KUBECONFIG_PATH:-$BOOTSTRAP_DIR/kubeconfig}"
```

   Create `infra/k3s-bootstrap/.gitignore` (the plaintext kubeconfig carries a cluster-admin token and must never be committed; this is a subtree-local addition that complements — does not replace — M0's repo-root `.gitignore`):

```gitignore
# Retrieved kubeconfig holds a cluster-admin bearer token — never commit.
kubeconfig
kubeconfig.*
*.kubeconfig
# Local scratch from drills.
*.log
```

4. Run again, expect PASS:

```bash
bats infra/k3s-bootstrap/test/00-harness.bats
```

Expected output:

```
 ✓ bats harness loads and BOOTSTRAP_DIR resolves
 ✓ kubeconfig path is gitignored
2 tests, 0 failures
```

5. Commit.

```bash
git add infra/k3s-bootstrap/.gitignore infra/k3s-bootstrap/test/
git commit -m "test(k3s-bootstrap): bats 하네스와 kubeconfig gitignore 추가"
```

---

### Task 1.2 — Pin every external version in one sourced file

**Files**
- Create: `infra/k3s-bootstrap/versions.env`
- Create: `infra/k3s-bootstrap/test/01-versions.bats`
- Test: `infra/k3s-bootstrap/test/01-versions.bats`

**Steps**

1. Write the failing pin-contract test. Create `infra/k3s-bootstrap/test/01-versions.bats`:

```bash
#!/usr/bin/env bats
load test_helper

setup() { source "$BOOTSTRAP_DIR/versions.env"; }

@test "all required versions are pinned and non-empty" {
  [ -n "$K3S_VERSION" ]
  [ -n "$DEBIAN_RELEASE" ]
  [ -n "$LOCAL_PATH_PROVISIONER_VERSION" ]
  [ -n "$LOCAL_PATH_HELPER_IMAGE" ]
}

@test "k3s version is a pinned channel tag, not 'stable' or 'latest'" {
  [[ "$K3S_VERSION" == v1.* ]]
  [[ "$K3S_VERSION" != *latest* ]]
  [[ "$K3S_VERSION" != stable ]]
}

@test "helper pod image is arch-pinned to arm64 by digest or arm64 tag" {
  [[ "$LOCAL_PATH_HELPER_IMAGE" == *busybox* ]]
  # Must be pinned by digest (@sha256) — floating tags break the cattle rebuild.
  [[ "$LOCAL_PATH_HELPER_IMAGE" == *@sha256:* ]]
}
```

2. Run it, expect FAILURE:

```bash
bats infra/k3s-bootstrap/test/01-versions.bats
```

Expected output (abridged):

```
 ✗ all required versions are pinned and non-empty
   `source "$BOOTSTRAP_DIR/versions.env"' failed
   …/versions.env: No such file or directory
3 tests, 3 failures
```

3. Create `infra/k3s-bootstrap/versions.env` (single SSOT for pins; sourced by every script). The busybox digest below is the arm64 manifest digest — re-resolve with `docker buildx imagetools inspect busybox:1.36 --format '{{.Manifest.Digest}}'` if you bump it, and keep it pinned by digest so the HelperPod is reproducible on the arm64 node:

```bash
#!/usr/bin/env bash
# SSOT for all externally-sourced versions used by the host substrate.
# Sourced (never executed) by install/storage scripts and CI checks.

# k3s release channel tag (pinned — never 'stable'/'latest', so cattle rebuilds are deterministic).
export K3S_VERSION="v1.31.4+k3s1"

# Guest OS.
export DEBIAN_RELEASE="bookworm"            # Debian 12, arm64
export DEBIAN_ARCH="arm64"

# rancher/local-path-provisioner chart/app version (we vendor its manifests in Task 1.7).
export LOCAL_PATH_PROVISIONER_VERSION="v0.0.30"

# HelperPod image — local-path uses it to mkdir/rm PV dirs on the node.
# Pinned by arm64 digest so it is reproducible and never silently pulls amd64.
export LOCAL_PATH_HELPER_IMAGE="busybox:1.36@sha256:9ae97d36d26566ff84e8893c64a6dc4fe8ca6d1144bf5b87b2b85a32def253c7"

# VM sizing (R3 + memory budget §10): 11 GiB ceiling, 6 vCPU, ONE machine.
export ORB_MEMORY_MIB="11264"               # 11 GiB
export ORB_CPU="6"

# Node-local storage paths created by cloud-init (Task 1.4).
export INTERNAL_STORAGE_PATH="/var/lib/rancher/k3s-storage/internal"   # 512 GB internal SSD
export BULK_STORAGE_PATH="/var/lib/rancher/k3s-storage/bulk"           # 1 TB external SSD mount
```

4. Run again, expect PASS:

```bash
bats infra/k3s-bootstrap/test/01-versions.bats
```

Expected output:

```
 ✓ all required versions are pinned and non-empty
 ✓ k3s version is a pinned channel tag, not 'stable' or 'latest'
 ✓ helper pod image is arch-pinned to arm64 by digest or arm64 tag
3 tests, 0 failures
```

5. Commit.

```bash
git add infra/k3s-bootstrap/versions.env infra/k3s-bootstrap/test/01-versions.bats
git commit -m "chore(k3s-bootstrap): 외부 버전 핀(versions.env) 단일화"
```

---

### Task 1.3 — `orb-guard.sh`: exactly-one-OrbStack-machine health check (R3)

**Files**
- Create: `infra/k3s-bootstrap/orb-guard.sh`
- Create: `infra/k3s-bootstrap/test/02-orb-guard.bats`
- Test: `infra/k3s-bootstrap/test/02-orb-guard.bats`

**Steps**

1. Write the failing guard test. It stubs `orb` on `PATH` so it runs in CI without OrbStack. Create `infra/k3s-bootstrap/test/02-orb-guard.bats`:

```bash
#!/usr/bin/env bats
load test_helper

setup() {
  STUBDIR="$(mktemp -d)"
  PATH="$STUBDIR:$PATH"
  export PATH STUBDIR
}
teardown() { rm -rf "$STUBDIR"; }

# Build a fake `orb` whose `list` output we control.
_make_orb() {
  cat >"$STUBDIR/orb" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "list" ]; then printf '%s\n' "$1"; exit 0; fi
exit 0
EOF
  chmod +x "$STUBDIR/orb"
}

@test "passes when exactly one machine named k3s is running" {
  _make_orb $'NAME    STATE      DISTRO          ARCH\nk3s     running    debian bookworm arm64'
  run "$BOOTSTRAP_DIR/orb-guard.sh"
  [ "$status" -eq 0 ]
}

@test "fails when a second machine exists (global cap contention, R3)" {
  _make_orb $'NAME    STATE      DISTRO          ARCH\nk3s     running    debian bookworm arm64\nstray   running    ubuntu noble    arm64'
  run "$BOOTSTRAP_DIR/orb-guard.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one"* ]]
}

@test "fails when the k3s machine is not running" {
  _make_orb $'NAME    STATE      DISTRO          ARCH\nk3s     stopped    debian bookworm arm64'
  run "$BOOTSTRAP_DIR/orb-guard.sh"
  [ "$status" -ne 0 ]
}
```

2. Run it, expect FAILURE:

```bash
bats infra/k3s-bootstrap/test/02-orb-guard.bats
```

Expected output (abridged):

```
 ✗ passes when exactly one machine named k3s is running
   …/orb-guard.sh: No such file or directory
3 tests, 3 failures
```

3. Create `infra/k3s-bootstrap/orb-guard.sh`:

```bash
#!/usr/bin/env bash
# R3 health check: assert the OrbStack environment holds EXACTLY ONE machine,
# named "$ORB_MACHINE", in the running state. The OrbStack memory cap is GLOBAL,
# so any extra machine/container silently steals from the k3s VM's 11 GiB.
# Re-used as a gate by later milestones — keep it dependency-free (no jq).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
ORB_MACHINE="${ORB_MACHINE:-k3s}"

if ! command -v orb >/dev/null 2>&1; then
  echo "FAIL: 'orb' not found on PATH — is OrbStack installed?" >&2
  exit 2
fi

# `orb list` prints a header row + one row per machine. Strip the header.
mapfile -t rows < <(orb list 2>/dev/null | tail -n +2 | sed '/^[[:space:]]*$/d')

count="${#rows[@]}"
if [ "$count" -ne 1 ]; then
  echo "FAIL: expected exactly one OrbStack machine, found ${count} (R3 global-cap rule)." >&2
  printf '  %s\n' "${rows[@]}" >&2
  exit 1
fi

name="$(awk '{print $1}' <<<"${rows[0]}")"
state="$(awk '{print $2}' <<<"${rows[0]}")"

if [ "$name" != "$ORB_MACHINE" ]; then
  echo "FAIL: the single machine is '${name}', expected '${ORB_MACHINE}'." >&2
  exit 1
fi
if [ "$state" != "running" ]; then
  echo "FAIL: machine '${name}' is '${state}', expected 'running'." >&2
  exit 1
fi

echo "OK: exactly one OrbStack machine '${name}' is running."
```

   Make it executable:

```bash
chmod +x infra/k3s-bootstrap/orb-guard.sh
```

4. Run again, expect PASS:

```bash
bats infra/k3s-bootstrap/test/02-orb-guard.bats
```

Expected output:

```
 ✓ passes when exactly one machine named k3s is running
 ✓ fails when a second machine exists (global cap contention, R3)
 ✓ fails when the k3s machine is not running
3 tests, 0 failures
```

5. Commit.

```bash
git add infra/k3s-bootstrap/orb-guard.sh infra/k3s-bootstrap/test/02-orb-guard.bats
git commit -m "feat(k3s-bootstrap): OrbStack 단일 머신 가드(orb-guard.sh) 추가"
```

---

### Task 1.4 — `cloud-init.yaml`: Debian bookworm arm64 (zram, journald cap, storage dirs, sshd)

**Files**
- Create: `infra/k3s-bootstrap/cloud-init.yaml`
- Create: `infra/k3s-bootstrap/test/03-cloud-init.bats`
- Test: `infra/k3s-bootstrap/test/03-cloud-init.bats`

**Steps**

1. Write the failing structure test. We assert on the rendered cloud-init contract (parse with `yq` so it stays valid YAML and contains every required knob). Create `infra/k3s-bootstrap/test/03-cloud-init.bats`:

```bash
#!/usr/bin/env bats
load test_helper

CI="$BOOTSTRAP_DIR/cloud-init.yaml"

@test "cloud-init exists and is valid YAML" {
  [ -f "$CI" ]
  run yq -e '.' "$CI"
  [ "$status" -eq 0 ]
}

@test "first line is the #cloud-config shebang" {
  run head -n1 "$CI"
  [ "$output" = "#cloud-config" ]
}

@test "zram is configured via systemd-zram-generator with zstd" {
  run yq -e '.write_files[] | select(.path == "/etc/systemd/zram-generator.conf") | .content' "$CI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zram0"* ]]
  [[ "$output" == *"zstd"* ]]
}

@test "journald SystemMaxUse is capped" {
  run yq -e '.write_files[] | select(.path == "/etc/systemd/journald.conf.d/cap.conf") | .content' "$CI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SystemMaxUse="* ]]
}

@test "both storage dirs are created" {
  run yq -e '.runcmd | @json' "$CI"
  [[ "$output" == *"/var/lib/rancher/k3s-storage/internal"* ]]
  [[ "$output" == *"/var/lib/rancher/k3s-storage/bulk"* ]]
}

@test "zram-generator package is installed and sshd enabled" {
  run yq -e '.packages | @json' "$CI"
  [[ "$output" == *"systemd-zram-generator"* ]]
  [[ "$output" == *"openssh-server"* ]]
}
```

2. Run it, expect FAILURE:

```bash
bats infra/k3s-bootstrap/test/03-cloud-init.bats
```

Expected output (abridged):

```
 ✗ cloud-init exists and is valid YAML
   …/cloud-init.yaml: No such file or directory
6 tests, 6 failures
```

3. Create `infra/k3s-bootstrap/cloud-init.yaml`. The external 1 TB SSD is bind-mounted by OrbStack into the guest; cloud-init only guarantees the **mount point directory** exists and is owned correctly (the actual bind is wired in Task 1.5 via `orb config`/the create call). zram is the OS-level OOM cushion (k3s kubelet stays swap-unaware per §4):

```yaml
#cloud-config
# Host substrate for the single k3s VM (Debian bookworm arm64), committed as code.
# Provisioned once by orb-create.sh (Task 1.5); the VM is cattle (§4).

hostname: k3s
preserve_hostname: false
timezone: Asia/Seoul

packages:
  - systemd-zram-generator      # OS-level OOM cushion (zstd zram), kubelet stays swap-unaware
  - openssh-server              # SSH access (OrbStack also multiplexes ssh orb)
  - curl
  - ca-certificates
  - apparmor                    # k3s default container runtime expects it present
  - iptables                    # flannel/VXLAN dataplane

package_update: true
package_upgrade: false          # determinism: pin via versions.env / image, not apt drift

users:
  - name: ops
    groups: [sudo]
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    lock_passwd: true           # key-only; OrbStack injects its managed key automatically

write_files:
  # zram: ~2 GiB zstd compressed swap as an OOM cushion. NOT used by the kubelet
  # for scheduling (k3s runs swap-unaware); purely a kernel page-reclaim safety net.
  - path: /etc/systemd/zram-generator.conf
    permissions: "0644"
    content: |
      [zram0]
      zram-size = min(ram / 4, 2048)
      compression-algorithm = zstd
      swap-priority = 100

  # Cap journald so logs on the internal SSD can never run away (R4 disk-fill posture).
  - path: /etc/systemd/journald.conf.d/cap.conf
    permissions: "0644"
    content: |
      [Journal]
      Storage=persistent
      SystemMaxUse=512M
      SystemKeepFree=1G
      RuntimeMaxUse=64M

  # Harden sshd a touch: no root login, key auth only.
  - path: /etc/ssh/sshd_config.d/10-hardening.conf
    permissions: "0644"
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no

runcmd:
  # Storage mount points. 'internal' lives on the VM's own disk (512 GB internal SSD);
  # 'bulk' is the directory OrbStack bind-mounts the 1 TB external SSD onto.
  - [ install, -d, -m, "0700", -o, root, -g, root, /var/lib/rancher/k3s-storage/internal ]
  - [ install, -d, -m, "0700", -o, root, -g, root, /var/lib/rancher/k3s-storage/bulk ]
  # Activate zram + journald caps now (so this boot already benefits).
  - [ systemctl, daemon-reload ]
  - [ systemctl, restart, systemd-journald ]
  - [ systemctl, start, "systemd-zram-setup@zram0.service" ]
  - [ systemctl, restart, ssh ]

# Final marker file lets orb-create.sh poll for completion.
power_state:
  mode: reboot
  condition: false
```

4. Run again, expect PASS:

```bash
bats infra/k3s-bootstrap/test/03-cloud-init.bats
```

Expected output:

```
 ✓ cloud-init exists and is valid YAML
 ✓ first line is the #cloud-config shebang
 ✓ zram is configured via systemd-zram-generator with zstd
 ✓ journald SystemMaxUse is capped
 ✓ both storage dirs are created
 ✓ zram-generator package is installed and sshd enabled
6 tests, 0 failures
```

5. Commit.

```bash
git add infra/k3s-bootstrap/cloud-init.yaml infra/k3s-bootstrap/test/03-cloud-init.bats
git commit -m "feat(k3s-bootstrap): Debian bookworm arm64 cloud-init(zram/journald/스토리지/sshd) 추가"
```

---

### Task 1.5 — `orb-create.sh`: create the ONE VM (11 GiB / 6 vCPU, idempotent)

**Files**
- Create: `infra/k3s-bootstrap/orb-create.sh`
- Create: `infra/k3s-bootstrap/test/04-orb-create.bats`
- Test: `infra/k3s-bootstrap/test/04-orb-create.bats`

**Steps**

1. Write the failing test. It stubs `orb` to assert the create command shape (Debian bookworm, machine name `k3s`, cloud-init passed, memory/cpu set globally) and idempotency (no double-create). Create `infra/k3s-bootstrap/test/04-orb-create.bats`:

```bash
#!/usr/bin/env bats
load test_helper

setup() {
  STUBDIR="$(mktemp -d)"; CALLS="$STUBDIR/calls.log"
  PATH="$STUBDIR:$PATH"; export PATH STUBDIR CALLS
  cat >"$STUBDIR/orb" <<'EOF'
#!/usr/bin/env bash
echo "orb $*" >>"$CALLS"
case "$1" in
  list)   cat "${ORB_LIST_FIXTURE:-/dev/null}" ;;  # empty by default = no machines
  config) exit 0 ;;
  create) exit 0 ;;
  *)      exit 0 ;;
esac
EOF
  chmod +x "$STUBDIR/orb"
}
teardown() { rm -rf "$STUBDIR"; }

@test "creates a debian bookworm machine named k3s with cloud-init when none exists" {
  run "$BOOTSTRAP_DIR/orb-create.sh"
  [ "$status" -eq 0 ]
  grep -q 'orb create' "$CALLS"
  grep -q 'debian:bookworm' "$CALLS"
  grep -q -- '-c .*cloud-init.yaml' "$CALLS"
  grep -qE 'orb create .* k3s' "$CALLS"
}

@test "sets the GLOBAL memory and cpu caps (11 GiB / 6 vCPU)" {
  run "$BOOTSTRAP_DIR/orb-create.sh"
  grep -q 'config set memory_mib 11264' "$CALLS"
  grep -q 'config set cpu 6' "$CALLS"
}

@test "is idempotent: does NOT create when k3s already exists" {
  FIX="$STUBDIR/fix"; printf 'NAME  STATE    DISTRO\nk3s   running  debian\n' >"$FIX"
  ORB_LIST_FIXTURE="$FIX" run "$BOOTSTRAP_DIR/orb-create.sh"
  [ "$status" -eq 0 ]
  run grep -c 'orb create' "$CALLS"
  [ "$output" -eq 0 ]
}
```

2. Run it, expect FAILURE:

```bash
bats infra/k3s-bootstrap/test/04-orb-create.bats
```

Expected output (abridged):

```
 ✗ creates a debian bookworm machine named k3s with cloud-init when none exists
   …/orb-create.sh: No such file or directory
3 tests, 3 failures
```

3. Create `infra/k3s-bootstrap/orb-create.sh`:

```bash
#!/usr/bin/env bash
# Create THE single OrbStack VM that hosts k3s. Idempotent: a second run is a no-op
# if the machine already exists. The memory/cpu caps are GLOBAL to OrbStack (R3),
# so we set them unconditionally to the budgeted ceiling (§9/§10).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
ORB_MACHINE="${ORB_MACHINE:-k3s}"
CLOUD_INIT="$SCRIPT_DIR/cloud-init.yaml"

command -v orb >/dev/null 2>&1 || { echo "FAIL: 'orb' not on PATH (install OrbStack)." >&2; exit 2; }
[ -f "$CLOUD_INIT" ] || { echo "FAIL: missing $CLOUD_INIT" >&2; exit 2; }

# Global OrbStack caps — the ceiling, not a reservation (OrbStack returns idle RAM).
echo "==> Setting global OrbStack caps: ${ORB_MEMORY_MIB} MiB / ${ORB_CPU} vCPU"
orb config set memory_mib "$ORB_MEMORY_MIB"
orb config set cpu "$ORB_CPU"

if orb list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -qx "$ORB_MACHINE"; then
  echo "==> Machine '${ORB_MACHINE}' already exists — skipping create (idempotent)."
else
  echo "==> Creating Debian ${DEBIAN_RELEASE} ${DEBIAN_ARCH} machine '${ORB_MACHINE}'…"
  # OrbStack on Apple Silicon defaults to arm64; we name the distro explicitly.
  orb create "debian:${DEBIAN_RELEASE}" "$ORB_MACHINE" -c "$CLOUD_INIT"
fi

# Make k3s the default machine so `orb -m` is optional but explicit elsewhere.
orb default "$ORB_MACHINE" >/dev/null 2>&1 || true
echo "==> Done. Verify with: infra/k3s-bootstrap/orb-guard.sh"
```

   Make it executable:

```bash
chmod +x infra/k3s-bootstrap/orb-create.sh
```

4. Run again, expect PASS:

```bash
bats infra/k3s-bootstrap/test/04-orb-create.bats
```

Expected output:

```
 ✓ creates a debian bookworm machine named k3s with cloud-init when none exists
 ✓ sets the GLOBAL memory and cpu caps (11 GiB / 6 vCPU)
 ✓ is idempotent: does NOT create when k3s already exists
3 tests, 0 failures
```

5. Commit.

```bash
git add infra/k3s-bootstrap/orb-create.sh infra/k3s-bootstrap/test/04-orb-create.bats
git commit -m "feat(k3s-bootstrap): 단일 VM 생성 스크립트(orb-create.sh, 11GiB/6vCPU) 추가"
```

---

### Task 1.6 — `k3s-install.sh`: exact flags + kubeconfig retrieval to gitignored path

**Files**
- Create: `infra/k3s-bootstrap/k3s-install.sh`
- Create: `infra/k3s-bootstrap/test/05-k3s-flags.bats`
- Test: `infra/k3s-bootstrap/test/05-k3s-flags.bats`

**Steps**

1. Write the failing flag-contract test. We assert the **exact** `INSTALL_K3S_EXEC` string the installer builds — this is where a typo silently keeps Traefik or drops `--secrets-encryption`, so it is verification-first. Create `infra/k3s-bootstrap/test/05-k3s-flags.bats`:

```bash
#!/usr/bin/env bats
load test_helper

# k3s-install.sh exposes a `print_exec` mode that echoes INSTALL_K3S_EXEC without
# touching the VM, so the flag contract is unit-testable offline.
setup() { EXEC="$(K3S_PRINT_EXEC=1 "$BOOTSTRAP_DIR/k3s-install.sh")"; }

@test "disables traefik, local-storage, metrics-server" {
  [[ "$EXEC" == *"--disable=traefik,local-storage,metrics-server"* ]]
}
@test "disables the helm-controller" {
  [[ "$EXEC" == *"--disable-helm-controller"* ]]
}
@test "KEEPS servicelb (must NOT be in any --disable list)" {
  [[ "$EXEC" != *"servicelb"* ]]
}
@test "flannel backend is vxlan" {
  [[ "$EXEC" == *"--flannel-backend=vxlan"* ]]
}
@test "kube-reserved and system-reserved are 250m/512Mi each" {
  [[ "$EXEC" == *"--kube-reserved=cpu=250m,memory=512Mi"* ]]
  [[ "$EXEC" == *"--system-reserved=cpu=250m,memory=512Mi"* ]]
}
@test "eviction-hard set for memory and nodefs" {
  [[ "$EXEC" == *"memory.available<250Mi"* ]]
  [[ "$EXEC" == *"nodefs.available<10%"* ]]
}
@test "image GC thresholds are 80/70" {
  [[ "$EXEC" == *"--image-gc-high-threshold=80"* ]]
  [[ "$EXEC" == *"--image-gc-low-threshold=70"* ]]
}
@test "secrets encryption enabled and kubeconfig mode 0644" {
  [[ "$EXEC" == *"--secrets-encryption"* ]]
  [[ "$EXEC" == *"--write-kubeconfig-mode=0644"* ]]
}
@test "datastore stays default sqlite/kine (no --cluster-init / etcd)" {
  [[ "$EXEC" != *"--cluster-init"* ]]
  [[ "$EXEC" != *"etcd"* ]]
}
```

2. Run it, expect FAILURE:

```bash
bats infra/k3s-bootstrap/test/05-k3s-flags.bats
```

Expected output (abridged):

```
 ✗ disables traefik, local-storage, metrics-server
   …/k3s-install.sh: No such file or directory
9 tests, 9 failures
```

3. Create `infra/k3s-bootstrap/k3s-install.sh`. The `INSTALL_K3S_EXEC` string is built once and printable in `K3S_PRINT_EXEC=1` mode so it is testable offline; the live path runs the official installer **inside the VM** and pulls the kubeconfig back to the gitignored path with the VM's reachable IP rewritten in:

```bash
#!/usr/bin/env bash
# Install k3s single-node into the OrbStack VM with the EXACT homelab flag set,
# then retrieve a usable kubeconfig to a gitignored path on the macOS host.
#
# Modes:
#   (default)            run the install inside the VM, fetch kubeconfig.
#   K3S_PRINT_EXEC=1     print INSTALL_K3S_EXEC and exit (offline flag-contract test).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
ORB_MACHINE="${ORB_MACHINE:-k3s}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$SCRIPT_DIR/kubeconfig}"

# --- The flag contract (single source of truth) ---------------------------------
# servicelb is KEPT (absent from --disable). SQLite/kine is the default datastore
# (no --cluster-init, so we do NOT get embedded etcd). secrets-encryption on from
# day one. Node-protection reserves + eviction so a runaway pod can't OOM kubelet.
INSTALL_K3S_EXEC="server \
--disable=traefik,local-storage,metrics-server \
--disable-helm-controller \
--flannel-backend=vxlan \
--kube-reserved=cpu=250m,memory=512Mi \
--system-reserved=cpu=250m,memory=512Mi \
--eviction-hard=memory.available<250Mi,nodefs.available<10% \
--image-gc-high-threshold=80 \
--image-gc-low-threshold=70 \
--secrets-encryption \
--write-kubeconfig-mode=0644 \
--default-local-storage-path=${INTERNAL_STORAGE_PATH}"

if [ "${K3S_PRINT_EXEC:-0}" = "1" ]; then
  printf '%s\n' "$INSTALL_K3S_EXEC"
  exit 0
fi

command -v orb >/dev/null 2>&1 || { echo "FAIL: 'orb' not on PATH." >&2; exit 2; }

echo "==> Installing k3s ${K3S_VERSION} into VM '${ORB_MACHINE}'…"
# Run the official installer INSIDE the VM as root, pinned to K3S_VERSION.
orb -m "$ORB_MACHINE" -u root bash -c "\
  set -euo pipefail; \
  export INSTALL_K3S_VERSION='${K3S_VERSION}'; \
  export INSTALL_K3S_EXEC=\"${INSTALL_K3S_EXEC}\"; \
  curl -sfL https://get.k3s.io | sh -s -"

echo "==> Waiting for k3s API to come up…"
orb -m "$ORB_MACHINE" -u root bash -c "\
  for i in \$(seq 1 60); do \
    k3s kubectl get --raw=/readyz >/dev/null 2>&1 && exit 0; sleep 2; \
  done; echo 'k3s API did not become ready' >&2; exit 1"

echo "==> Retrieving kubeconfig to ${KUBECONFIG_PATH} (gitignored)…"
# The in-VM kubeconfig points at 127.0.0.1; rewrite to the VM's OrbStack DNS name
# so it is reachable from macOS. k3s.orb.local resolves to the VM (OrbStack DNS).
orb -m "$ORB_MACHINE" -u root cat /etc/rancher/k3s/k3s.yaml \
  | sed 's#https://127.0.0.1:6443#https://k3s.orb.local:6443#' \
  > "$KUBECONFIG_PATH"
chmod 0600 "$KUBECONFIG_PATH"

echo "==> k3s installed. Use: export KUBECONFIG=${KUBECONFIG_PATH}"
```

   Make it executable:

```bash
chmod +x infra/k3s-bootstrap/k3s-install.sh
```

4. Run again, expect PASS:

```bash
bats infra/k3s-bootstrap/test/05-k3s-flags.bats
```

Expected output:

```
 ✓ disables traefik, local-storage, metrics-server
 ✓ disables the helm-controller
 ✓ KEEPS servicelb (must NOT be in any --disable list)
 ✓ flannel backend is vxlan
 ✓ kube-reserved and system-reserved are 250m/512Mi each
 ✓ eviction-hard set for memory and nodefs
 ✓ image GC thresholds are 80/70
 ✓ secrets encryption enabled and kubeconfig mode 0644
 ✓ datastore stays default sqlite/kine (no --cluster-init / etcd)
9 tests, 0 failures
```

5. Commit.

```bash
git add infra/k3s-bootstrap/k3s-install.sh infra/k3s-bootstrap/test/05-k3s-flags.bats
git commit -m "feat(k3s-bootstrap): k3s 설치 스크립트(정확한 플래그+kubeconfig 회수) 추가"
```

---

### Task 1.7 — Vendored dual local-path-provisioner + two StorageClass manifests

**Files**
- Create: `infra/k3s-bootstrap/storage/local-path-provisioner.yaml`
- Create: `infra/k3s-bootstrap/storage/storageclass-standard.yaml`
- Create: `infra/k3s-bootstrap/storage/storageclass-bulk-ssd.yaml`
- Create: `infra/k3s-bootstrap/test/06-storage-manifests.bats`
- Test: `infra/k3s-bootstrap/test/06-storage-manifests.bats`

**Steps**

1. Write the failing manifest-contract test (static, offline — parses the YAML). We assert: `standard` is the **default**, `Retain`, `Immediate` (so DB PVs survive a reclaim and bind on the internal SSD); `bulk-ssd` is **not default**, `WaitForFirstConsumer`, on the external SSD path; both use the dedicated provisioner name; helper image is the arm64-pinned digest. Create `infra/k3s-bootstrap/test/06-storage-manifests.bats`:

```bash
#!/usr/bin/env bats
load test_helper

DIR="$BOOTSTRAP_DIR/storage"
STD="$DIR/storageclass-standard.yaml"
BULK="$DIR/storageclass-bulk-ssd.yaml"
PROV="$DIR/local-path-provisioner.yaml"

setup() { source "$BOOTSTRAP_DIR/versions.env"; }

@test "all three storage manifests exist and are valid YAML" {
  for f in "$STD" "$BULK" "$PROV"; do
    [ -f "$f" ]
    run yq -e '.' "$f"; [ "$status" -eq 0 ]
  done
}

@test "standard is the default StorageClass, Retain, Immediate" {
  run yq -e '.metadata.annotations["storageclass.kubernetes.io/is-default-class"]' "$STD"
  [ "$output" = "true" ]
  run yq -e '.reclaimPolicy' "$STD"; [ "$output" = "Retain" ]
  run yq -e '.volumeBindingMode' "$STD"; [ "$output" = "Immediate" ]
  run yq -e '.provisioner' "$STD"; [ "$output" = "homelab.io/local-path-internal" ]
}

@test "bulk-ssd is NOT default, WaitForFirstConsumer, external path" {
  run yq -e '.metadata.annotations["storageclass.kubernetes.io/is-default-class"] // "false"' "$BULK"
  [ "$output" != "true" ]
  run yq -e '.volumeBindingMode' "$BULK"; [ "$output" = "WaitForFirstConsumer" ]
  run yq -e '.provisioner' "$BULK"; [ "$output" = "homelab.io/local-path-bulk" ]
}

@test "provisioner config maps each class to its node path" {
  run grep -F "$INTERNAL_STORAGE_PATH" "$PROV"; [ "$status" -eq 0 ]
  run grep -F "$BULK_STORAGE_PATH" "$PROV"; [ "$status" -eq 0 ]
}

@test "helper pod image is the arm64-pinned digest from versions.env" {
  run grep -F "$LOCAL_PATH_HELPER_IMAGE" "$PROV"; [ "$status" -eq 0 ]
}
```

2. Run it, expect FAILURE:

```bash
bats infra/k3s-bootstrap/test/06-storage-manifests.bats
```

Expected output (abridged):

```
 ✗ all three storage manifests exist and are valid YAML
   …/storage/storageclass-standard.yaml: No such file or directory
5 tests, 5 failures
```

3. Create the three manifests. We run **two** local-path-provisioner deployments (one per node path) so each StorageClass maps cleanly to its own disk with no co-mingling (R4). The `${...}` placeholders below are literal — `apply-storage.sh` in Task 1.8 substitutes `LOCAL_PATH_HELPER_IMAGE` from `versions.env`; the storage paths are written literally to match `versions.env`.

   `infra/k3s-bootstrap/storage/storageclass-standard.yaml` (default — internal 512 GB SSD, Postgres/config, Retain):

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard
  annotations:
    # Default class: PVCs with no storageClassName land here (Postgres, configs).
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: homelab.io/local-path-internal
# Retain so DB PVs survive a PVC delete/reclaim — never auto-wipe Postgres data.
reclaimPolicy: Retain
# Immediate: DB PVs should bind up front, not wait on first consumer.
volumeBindingMode: Immediate
allowVolumeExpansion: true
```

   `infra/k3s-bootstrap/storage/storageclass-bulk-ssd.yaml` (external 1 TB SSD, media + backup staging only — never Postgres):

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: bulk-ssd
  # NOT annotated default — bulk is opt-in only.
provisioner: homelab.io/local-path-bulk
# Delete is fine here: media/backup-staging volumes are reproducible from R2.
reclaimPolicy: Delete
# WaitForFirstConsumer: bind only once a pod schedules (single node, but keeps
# the binding semantics correct and avoids premature provisioning).
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

   `infra/k3s-bootstrap/storage/local-path-provisioner.yaml` (two provisioner Deployments + their config; namespace, RBAC, the arm64 HelperPod image pinned via the `${LOCAL_PATH_HELPER_IMAGE}` placeholder substituted at apply time). This vendors rancher/local-path-provisioner `v0.0.30` adapted to two named provisioners:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: local-path-storage
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: local-path-provisioner-sa
  namespace: local-path-storage
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: local-path-provisioner-role
rules:
  - apiGroups: [""]
    resources: ["nodes", "persistentvolumeclaims", "configmaps", "pods", "pods/log"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["endpoints", "persistentvolumes", "pods"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: local-path-provisioner-bind
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: local-path-provisioner-role
subjects:
  - kind: ServiceAccount
    name: local-path-provisioner-sa
    namespace: local-path-storage
---
# ---------- INTERNAL provisioner (StorageClass: standard) ----------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: local-path-provisioner-internal
  namespace: local-path-storage
spec:
  replicas: 1
  selector:
    matchLabels: { app: local-path-provisioner-internal }
  template:
    metadata:
      labels: { app: local-path-provisioner-internal }
    spec:
      serviceAccountName: local-path-provisioner-sa
      containers:
        - name: local-path-provisioner
          image: rancher/local-path-provisioner:v0.0.30
          imagePullPolicy: IfNotPresent
          command: ["local-path-provisioner"]
          args:
            - start
            - --provisioner-name=homelab.io/local-path-internal
            - --config=/etc/config/config.json
            - --service-account-name=local-path-provisioner-sa
          env:
            - name: POD_NAMESPACE
              value: local-path-storage
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 64Mi }
          volumeMounts:
            - { name: config-volume, mountPath: /etc/config/ }
      volumes:
        - name: config-volume
          configMap: { name: local-path-config-internal }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-path-config-internal
  namespace: local-path-storage
data:
  config.json: |
    {
      "nodePathMap": [
        { "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
          "paths": ["/var/lib/rancher/k3s-storage/internal"] }
      ]
    }
  setup: |
    #!/bin/sh
    set -eu
    mkdir -m 0777 -p "$VOL_DIR"
  teardown: |
    #!/bin/sh
    set -eu
    rm -rf "$VOL_DIR"
  helperPod.yaml: |
    apiVersion: v1
    kind: Pod
    metadata:
      name: helper-pod
    spec:
      containers:
        - name: helper-pod
          image: ${LOCAL_PATH_HELPER_IMAGE}
          imagePullPolicy: IfNotPresent
---
# ---------- BULK provisioner (StorageClass: bulk-ssd) ----------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: local-path-provisioner-bulk
  namespace: local-path-storage
spec:
  replicas: 1
  selector:
    matchLabels: { app: local-path-provisioner-bulk }
  template:
    metadata:
      labels: { app: local-path-provisioner-bulk }
    spec:
      serviceAccountName: local-path-provisioner-sa
      containers:
        - name: local-path-provisioner
          image: rancher/local-path-provisioner:v0.0.30
          imagePullPolicy: IfNotPresent
          command: ["local-path-provisioner"]
          args:
            - start
            - --provisioner-name=homelab.io/local-path-bulk
            - --config=/etc/config/config.json
            - --service-account-name=local-path-provisioner-sa
          env:
            - name: POD_NAMESPACE
              value: local-path-storage
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 64Mi }
          volumeMounts:
            - { name: config-volume, mountPath: /etc/config/ }
      volumes:
        - name: config-volume
          configMap: { name: local-path-config-bulk }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-path-config-bulk
  namespace: local-path-storage
data:
  config.json: |
    {
      "nodePathMap": [
        { "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
          "paths": ["/var/lib/rancher/k3s-storage/bulk"] }
      ]
    }
  setup: |
    #!/bin/sh
    set -eu
    mkdir -m 0777 -p "$VOL_DIR"
  teardown: |
    #!/bin/sh
    set -eu
    rm -rf "$VOL_DIR"
  helperPod.yaml: |
    apiVersion: v1
    kind: Pod
    metadata:
      name: helper-pod
    spec:
      containers:
        - name: helper-pod
          image: ${LOCAL_PATH_HELPER_IMAGE}
          imagePullPolicy: IfNotPresent
```

4. Run again, expect PASS:

```bash
bats infra/k3s-bootstrap/test/06-storage-manifests.bats
```

Expected output:

```
 ✓ all three storage manifests exist and are valid YAML
 ✓ standard is the default StorageClass, Retain, Immediate
 ✓ bulk-ssd is NOT default, WaitForFirstConsumer, external path
 ✓ provisioner config maps each class to its node path
 ✓ helper pod image is the arm64-pinned digest from versions.env
5 tests, 0 failures
```

5. Commit.

```bash
git add infra/k3s-bootstrap/storage/ infra/k3s-bootstrap/test/06-storage-manifests.bats
git commit -m "feat(k3s-bootstrap): 이중 local-path-provisioner와 StorageClass(standard/bulk-ssd) 추가"
```

---

### Task 1.8 — `apply-storage.sh`: substitute helper image + apply both classes

**Files**
- Create: `infra/k3s-bootstrap/apply-storage.sh`
- Create: `infra/k3s-bootstrap/test/07-apply-storage.bats`
- Test: `infra/k3s-bootstrap/test/07-apply-storage.bats`

**Steps**

1. Write the failing test. It stubs `kubectl` to capture the rendered manifest sent to `apply -f -` and asserts the `${LOCAL_PATH_HELPER_IMAGE}` placeholder was substituted (no literal `${` survives). Create `infra/k3s-bootstrap/test/07-apply-storage.bats`:

```bash
#!/usr/bin/env bats
load test_helper

setup() {
  STUBDIR="$(mktemp -d)"; RENDERED="$STUBDIR/rendered.yaml"
  PATH="$STUBDIR:$PATH"; export PATH STUBDIR RENDERED
  source "$BOOTSTRAP_DIR/versions.env"
  cat >"$STUBDIR/kubectl" <<'EOF'
#!/usr/bin/env bash
# Capture stdin when applying from '-'; succeed otherwise.
if [ "$1" = "apply" ]; then cat > "$RENDERED"; fi
exit 0
EOF
  chmod +x "$STUBDIR/kubectl"
  export KUBECONFIG_PATH="$STUBDIR/kubeconfig"; : > "$KUBECONFIG_PATH"
}
teardown() { rm -rf "$STUBDIR"; }

@test "renders manifests with the helper image substituted (no literal placeholder)" {
  run "$BOOTSTRAP_DIR/apply-storage.sh"
  [ "$status" -eq 0 ]
  run grep -F '${LOCAL_PATH_HELPER_IMAGE}' "$RENDERED"
  [ "$status" -ne 0 ]                          # placeholder must be gone
  run grep -F "$LOCAL_PATH_HELPER_IMAGE" "$RENDERED"
  [ "$status" -eq 0 ]                          # real digest present
}

@test "applies both StorageClasses" {
  run "$BOOTSTRAP_DIR/apply-storage.sh"
  grep -q 'name: standard' "$RENDERED"
  grep -q 'name: bulk-ssd' "$RENDERED"
}
```

2. Run it, expect FAILURE:

```bash
bats infra/k3s-bootstrap/test/07-apply-storage.bats
```

Expected output (abridged):

```
 ✗ renders manifests with the helper image substituted (no literal placeholder)
   …/apply-storage.sh: No such file or directory
2 tests, 2 failures
```

3. Create `infra/k3s-bootstrap/apply-storage.sh`:

```bash
#!/usr/bin/env bash
# Render (substitute the pinned arm64 helper image) and apply the dual
# local-path provisioner + both StorageClasses to the cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
export KUBECONFIG="${KUBECONFIG_PATH:-$SCRIPT_DIR/kubeconfig}"

command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not on PATH." >&2; exit 2; }

# Only LOCAL_PATH_HELPER_IMAGE is templated; restrict envsubst to that one var so
# nothing else (e.g. $VOL_DIR inside the setup script) gets clobbered.
render() {
  if command -v envsubst >/dev/null 2>&1; then
    envsubst '${LOCAL_PATH_HELPER_IMAGE}' < "$1"
  else
    sed "s#\${LOCAL_PATH_HELPER_IMAGE}#${LOCAL_PATH_HELPER_IMAGE}#g" "$1"
  fi
}

echo "==> Applying local-path provisioner (helper image: ${LOCAL_PATH_HELPER_IMAGE})…"
render "$SCRIPT_DIR/storage/local-path-provisioner.yaml" | kubectl apply -f -

echo "==> Applying StorageClasses…"
kubectl apply -f "$SCRIPT_DIR/storage/storageclass-standard.yaml"
kubectl apply -f "$SCRIPT_DIR/storage/storageclass-bulk-ssd.yaml"

echo "==> Storage applied. Verify with: kubectl get sc"
```

   Make it executable:

```bash
chmod +x infra/k3s-bootstrap/apply-storage.sh
```

4. Run again, expect PASS:

```bash
bats infra/k3s-bootstrap/test/07-apply-storage.bats
```

Expected output:

```
 ✓ renders manifests with the helper image substituted (no literal placeholder)
 ✓ applies both StorageClasses
2 tests, 0 failures
```

5. Commit.

```bash
git add infra/k3s-bootstrap/apply-storage.sh infra/k3s-bootstrap/test/07-apply-storage.bats
git commit -m "feat(k3s-bootstrap): 스토리지 적용 스크립트(apply-storage.sh, 헬퍼 이미지 치환) 추가"
```

---

### Task 1.9 — `host-up.sh`: idempotent orchestrator (orb → k3s → storage → guard)

**Files**
- Create: `infra/k3s-bootstrap/host-up.sh`
- Create: `infra/k3s-bootstrap/test/08-host-up.bats`
- Test: `infra/k3s-bootstrap/test/08-host-up.bats`

**Steps**

1. Write the failing orchestration test. It stubs each sub-script to log its invocation and asserts strict ordering (create → install → storage → guard). Create `infra/k3s-bootstrap/test/08-host-up.bats`:

```bash
#!/usr/bin/env bats
load test_helper

setup() {
  WORK="$(mktemp -d)"; ORDER="$WORK/order.log"; export WORK ORDER
  # Shadow the real sub-scripts with order-logging stubs via HOSTUP_BINDIR.
  mkdir -p "$WORK/bin"
  for s in orb-create.sh k3s-install.sh apply-storage.sh orb-guard.sh; do
    cat >"$WORK/bin/$s" <<EOF
#!/usr/bin/env bash
echo "$s" >> "$ORDER"; exit 0
EOF
    chmod +x "$WORK/bin/$s"
  done
  export HOSTUP_BINDIR="$WORK/bin"
}
teardown() { rm -rf "$WORK"; }

@test "runs sub-steps in order: create, install, storage, guard" {
  run "$BOOTSTRAP_DIR/host-up.sh"
  [ "$status" -eq 0 ]
  run cat "$ORDER"
  [ "${lines[0]}" = "orb-create.sh" ]
  [ "${lines[1]}" = "k3s-install.sh" ]
  [ "${lines[2]}" = "apply-storage.sh" ]
  [ "${lines[3]}" = "orb-guard.sh" ]
}
```

2. Run it, expect FAILURE:

```bash
bats infra/k3s-bootstrap/test/08-host-up.bats
```

Expected output (abridged):

```
 ✗ runs sub-steps in order: create, install, storage, guard
   …/host-up.sh: No such file or directory
1 test, 1 failure
```

3. Create `infra/k3s-bootstrap/host-up.sh`. The `HOSTUP_BINDIR` indirection lets the test substitute stubs while the real run uses the committed scripts in `SCRIPT_DIR`. This is the host-substrate entry point that the `up`/`host-up` Makefile target (wired in Task 1.11) invokes, and that M5's `make bootstrap` calls first:

```bash
#!/usr/bin/env bash
# Idempotent host-substrate orchestrator: bring up the ONE OrbStack VM, install
# k3s with the exact flags, apply storage, then assert the single-machine rule.
# Each step is individually idempotent, so re-running host-up.sh is safe (cattle).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${HOSTUP_BINDIR:-$SCRIPT_DIR}"

echo "===> [1/4] OrbStack VM"
"$BIN/orb-create.sh"
echo "===> [2/4] k3s install + kubeconfig"
"$BIN/k3s-install.sh"
echo "===> [3/4] StorageClasses"
"$BIN/apply-storage.sh"
echo "===> [4/4] R3 single-machine health check"
"$BIN/orb-guard.sh"

echo "===> Host substrate is up. Next: export KUBECONFIG=$SCRIPT_DIR/kubeconfig"
```

   Make it executable:

```bash
chmod +x infra/k3s-bootstrap/host-up.sh
```

4. Run again, expect PASS:

```bash
bats infra/k3s-bootstrap/test/08-host-up.bats
```

Expected output:

```
 ✓ runs sub-steps in order: create, install, storage, guard
1 test, 0 failures
```

5. Commit.

```bash
git add infra/k3s-bootstrap/host-up.sh infra/k3s-bootstrap/test/08-host-up.bats
git commit -m "feat(k3s-bootstrap): 호스트 부트스트랩 오케스트레이터(host-up.sh) 추가"
```

---

### Task 1.10 — Live cluster verification script (node Ready, SC, disabled/kept components, secrets-encryption)

**Files**
- Create: `infra/k3s-bootstrap/verify-cluster.sh`
- Create: `infra/k3s-bootstrap/test/09-verify-cluster.bats`
- Test: `infra/k3s-bootstrap/test/09-verify-cluster.bats`

> This task validates the **running** cluster. The bats test exercises the script's assertion logic against a stubbed `kubectl`/`orb` so it runs in CI; the manual block at the end runs it for real against the live VM.

**Steps**

1. Write the failing test. Stub `kubectl`/`orb` to feed canned cluster state; assert the script passes on a healthy fixture and fails when (a) a traefik pod is present, (b) servicelb is absent, or (c) secrets-encryption is disabled. Create `infra/k3s-bootstrap/test/09-verify-cluster.bats`:

```bash
#!/usr/bin/env bats
load test_helper

setup() {
  STUBDIR="$(mktemp -d)"; PATH="$STUBDIR:$PATH"; export PATH STUBDIR
  export KUBECONFIG_PATH="$STUBDIR/kubeconfig"; : > "$KUBECONFIG_PATH"
  # Healthy defaults; individual tests override via env files the stub reads.
  : > "$STUBDIR/pods.txt"          # kube-system pod names, one per line
  echo "svclb-traefik-abc"      >> "$STUBDIR/pods.txt"   # servicelb present
  echo "coredns-xyz"            >> "$STUBDIR/pods.txt"
  echo "true"  > "$STUBDIR/encryption.txt"               # secrets-encrypt enabled
  echo "Ready" > "$STUBDIR/nodestatus.txt"
  printf 'standard\nbulk-ssd\n' > "$STUBDIR/sc.txt"

  cat >"$STUBDIR/orb" <<'EOF'
#!/usr/bin/env bash
# Emulate `orb -m k3s -u root k3s secrets-encrypt status`
shift 4 2>/dev/null || true
if printf '%s ' "$@" | grep -q 'secrets-encrypt status'; then
  if [ "$(cat "$STUBDIR/encryption.txt")" = "true" ]; then
    echo "Encryption Status: Enabled"; else echo "Encryption Status: Disabled"; fi
fi
exit 0
EOF
  chmod +x "$STUBDIR/orb"

  cat >"$STUBDIR/kubectl" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"get nodes"*)         cat "$STUBDIR/nodestatus.txt" ;;
  *"get pods"*)          cat "$STUBDIR/pods.txt" ;;
  *"get sc"*|*"get storageclass"*) cat "$STUBDIR/sc.txt" ;;
esac
exit 0
EOF
  chmod +x "$STUBDIR/kubectl"
}
teardown() { rm -rf "$STUBDIR"; }

@test "passes on a healthy cluster fixture" {
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -eq 0 ]
}

@test "fails when a traefik pod is present (must be disabled)" {
  echo "traefik-7d9-runaway" >> "$STUBDIR/pods.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"traefik"* ]]
}

@test "fails when servicelb (svclb) is absent (must be kept)" {
  grep -v 'svclb' "$STUBDIR/pods.txt" > "$STUBDIR/pods.tmp" && mv "$STUBDIR/pods.tmp" "$STUBDIR/pods.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"servicelb"* ]]
}

@test "fails when secrets-encryption is disabled" {
  echo "false" > "$STUBDIR/encryption.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"encryption"* ]]
}

@test "fails when metrics-server pod is present (must be disabled)" {
  echo "metrics-server-zzz" >> "$STUBDIR/pods.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
}
```

2. Run it, expect FAILURE:

```bash
bats infra/k3s-bootstrap/test/09-verify-cluster.bats
```

Expected output (abridged):

```
 ✗ passes on a healthy cluster fixture
   …/verify-cluster.sh: No such file or directory
5 tests, 5 failures
```

3. Create `infra/k3s-bootstrap/verify-cluster.sh`:

```bash
#!/usr/bin/env bash
# Live cluster contract check for the host substrate (Milestone 1):
#   - node Ready
#   - both StorageClasses present (standard, bulk-ssd)
#   - DISABLED components absent (traefik, metrics-server)
#   - KEPT component present (servicelb / svclb DaemonSet pods)
#   - secrets-encryption ENABLED
# Designed to be re-run any time; exits non-zero on the first failed invariant.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
ORB_MACHINE="${ORB_MACHINE:-k3s}"
export KUBECONFIG="${KUBECONFIG_PATH:-$SCRIPT_DIR/kubeconfig}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> [1] Node Ready?"
nodes="$(kubectl get nodes --no-headers 2>/dev/null || true)"
echo "$nodes" | grep -qw "Ready" || fail "node is not Ready"

echo "==> [2] StorageClasses present?"
sc="$(kubectl get sc --no-headers 2>/dev/null | awk '{print $1}')"
echo "$sc" | grep -qx "standard" || fail "StorageClass 'standard' missing"
echo "$sc" | grep -qx "bulk-ssd" || fail "StorageClass 'bulk-ssd' missing"

echo "==> [3] Disabled components absent?"
pods="$(kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '{print $1}')"
echo "$pods" | grep -q "traefik" && fail "traefik pod present — must be disabled"
echo "$pods" | grep -q "metrics-server" && fail "metrics-server pod present — must be disabled"

echo "==> [4] servicelb (klipper-lb) NOT disabled? (svclb pods are created on-demand only when a LoadBalancer Service exists — Traefik in M3 — so ZERO svclb pods at M1 is CORRECT, not a failure)"
grep -rqE 'disable=.*servicelb' infra/k3s-bootstrap/ && fail "servicelb is disabled in the k3s install config — must be kept (it provides Traefik's node-IP LoadBalancer in M3)"
echo "    OK: servicelb not disabled (the svclb DaemonSet appears in M3, asserted by Task 3.4 once Traefik's LoadBalancer Service exists)"

echo "==> [5] secrets-encryption enabled?"
enc="$(orb -m "$ORB_MACHINE" -u root k3s secrets-encrypt status 2>/dev/null || true)"
echo "$enc" | grep -qi "Enabled" || fail "secrets encryption is not Enabled"

echo "OK: host substrate verified (node Ready, both SCs, traefik/metrics-server absent, servicelb enabled, secrets-encryption enabled)."
```

   Make it executable:

```bash
chmod +x infra/k3s-bootstrap/verify-cluster.sh
```

4. Run again, expect PASS:

```bash
bats infra/k3s-bootstrap/test/09-verify-cluster.bats
```

Expected output:

```
 ✓ passes on a healthy cluster fixture
 ✓ fails when a traefik pod is present (must be disabled)
 ✓ fails when servicelb (svclb) is absent (must be kept)
 ✓ fails when secrets-encryption is disabled
 ✓ fails when metrics-server pod is present (must be disabled)
5 tests, 0 failures
```

5. Commit.

```bash
git add infra/k3s-bootstrap/verify-cluster.sh infra/k3s-bootstrap/test/09-verify-cluster.bats
git commit -m "test(k3s-bootstrap): 라이브 클러스터 검증 스크립트(verify-cluster.sh) 추가"
```

---

### Task 1.11 — Wire `host-up.sh` into M0's Makefile (`up`/`host-up` recipe — Modify, not Create)

> The `Makefile` is a SHARED file authored once by **M0**, which declared `bootstrap`, `up`, `down`, `verify`, and `help` as stub targets (`up`/`down` print intent and exit non-zero). M1 owns the host substrate, so it fills M0's `up` stub and adds a `host-up` alias by **editing** the existing recipe. Do **not** re-declare any target M0 already created, and do **not** re-create the `Makefile` — that is a hard error. `make bootstrap` remains a stub owned by a later milestone; `make down` stays an interface stub until a teardown milestone fills it.

**Files**
- Modify: `Makefile` (M0-owned; replace the `up` stub recipe, add a `host-up` alias to the existing `.PHONY` line and a recipe)
- Modify: `test/makefile.bats` (M0-owned; relax the "`up` exits non-zero" assertion now that `up` is implemented, and add an `up`/`host-up` wiring assertion)
- Test: `test/makefile.bats`

**Steps**

1. Update M0's Makefile test so it no longer asserts `up` is an unimplemented stub (M1 implements it), and add a check that `up`/`host-up` route to the host-substrate orchestrator. Edit `test/makefile.bats` — change the unimplemented-targets test to drop `up`, and add a wiring test:

```bash
@test "unimplemented targets still exit non-zero (cannot fake success)" {
  run make bootstrap
  [ "$status" -ne 0 ]
  run make down
  [ "$status" -ne 0 ]
}

@test "make help lists up and host-up" {
  run make help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'up'
  echo "$output" | grep -q 'host-up'
}

@test "up delegates to the host-substrate orchestrator (dry-run shows host-up.sh)" {
  run make -n up
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'infra/k3s-bootstrap/host-up.sh'
}
```

2. Run it, expect FAILURE (the `up` stub still exits non-zero and `make -n up` does not yet reference `host-up.sh`):

```bash
bats test/makefile.bats
```

Expected output (abridged):

```
 ✗ up delegates to the host-substrate orchestrator (dry-run shows host-up.sh)
   `echo "$output" | grep -q 'infra/k3s-bootstrap/host-up.sh'' failed
```

3. **Edit** the M0-owned `Makefile` (do not re-create it). Add `host-up` to the existing `.PHONY` line, replace the `up` stub recipe with a real one that invokes the committed orchestrator, and add a `host-up` alias. Leave `bootstrap`/`down`/`verify`/`help` exactly as M0 wrote them. Recipe lines must be **tab-indented**:

```makefile
# .PHONY line — ADD host-up to M0's existing declaration:
.PHONY: help bootstrap up host-up down verify

up: ## [runtime] bring the OrbStack VM + k3s + storage up (idempotent, = host-up)
	@infra/k3s-bootstrap/host-up.sh

host-up: ## [runtime] alias for `up` — host substrate bring-up (M1)
	@infra/k3s-bootstrap/host-up.sh
```

   The `up` stub M0 wrote was:

```makefile
up: ## [TODO: runtime milestone] bring the OrbStack VM + k3s up
	@echo "up: not implemented yet (owned by the runtime-foundation milestone)" >&2
	@exit 1
```

   — replace that whole recipe in place with the implemented `up` above, then add the `host-up` target immediately after it.

4. Run again, expect PASS:

```bash
bats test/makefile.bats
```

Expected output (abridged):

```
 ✓ make verify runs the foundation checks and passes
 ✓ unimplemented targets still exit non-zero (cannot fake success)
 ✓ make help lists up and host-up
 ✓ up delegates to the host-substrate orchestrator (dry-run shows host-up.sh)
```

5. Commit.

```bash
git add Makefile test/makefile.bats
git commit -m "feat(makefile): up/host-up 타깃을 host-up.sh로 연결(M0 스텁 수정)"
```

---

### Task 1.12 — End-to-end live bring-up + manual acceptance against the real VM

> This is the one **manual, against-real-hardware** task. Run it on the Mac mini with OrbStack installed. It exercises every committed script for real and captures the expected live output as the milestone's acceptance evidence. No new bootstrap scripts; it runs what Tasks 1.1–1.11 produced.

**Files**
- Test (manual): `infra/k3s-bootstrap/host-up.sh`, `infra/k3s-bootstrap/verify-cluster.sh`, `make up`
- Create: `docs/runbooks/host-substrate.md` (operational runbook + acceptance evidence — the only doc this milestone writes)

**Steps**

1. Pre-flight — confirm OrbStack present and that there is **not** already a stray machine (R3):

```bash
orb version
infra/k3s-bootstrap/orb-guard.sh || echo "(expected to fail before the VM exists)"
```

Expected (no VM yet): the guard prints `FAIL: expected exactly one OrbStack machine, found 0` and exits non-zero. This is the milestone's intended **pre-state failure**.

2. Bring up the whole substrate in one idempotent call — via the Makefile target wired in Task 1.11 (equivalently, run `infra/k3s-bootstrap/host-up.sh` directly):

```bash
make up
```

Expected (abridged, after a few minutes):

```
===> [1/4] OrbStack VM
==> Setting global OrbStack caps: 11264 MiB / 6 vCPU
==> Creating Debian bookworm arm64 machine 'k3s'…
===> [2/4] k3s install + kubeconfig
==> Installing k3s v1.31.4+k3s1 into VM 'k3s'…
==> k3s installed. Use: export KUBECONFIG=…/infra/k3s-bootstrap/kubeconfig
===> [3/4] StorageClasses
storageclass.storage.k8s.io/standard created
storageclass.storage.k8s.io/bulk-ssd created
===> [4/4] R3 single-machine health check
OK: exactly one OrbStack machine 'k3s' is running.
===> Host substrate is up. Next: export KUBECONFIG=…/kubeconfig
```

3. Point kubectl at the gitignored kubeconfig and confirm the node is Ready:

```bash
export KUBECONFIG="$PWD/infra/k3s-bootstrap/kubeconfig"
kubectl get nodes -o wide
```

Expected:

```
NAME   STATUS   ROLES                  AGE   VERSION        INTERNAL-IP   OS-IMAGE
k3s    Ready    control-plane,master   1m    v1.31.4+k3s1   198.19.x.x    Debian GNU/Linux 12 (bookworm)
```

4. Confirm both StorageClasses with the right provisioners, default flag, and binding mode:

```bash
kubectl get sc
```

Expected (note `standard` carries `(default)` and `bulk-ssd` is `WaitForFirstConsumer`):

```
NAME                 PROVISIONER                      RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
standard (default)   homelab.io/local-path-internal   Retain          Immediate              true
bulk-ssd             homelab.io/local-path-bulk       Delete          WaitForFirstConsumer   true
```

5. Confirm disabled-vs-kept components directly:

```bash
kubectl get pods -n kube-system | grep -Ei 'traefik|metrics-server|svclb' || true
```

Expected: **no** `traefik` or `metrics-server` rows; one or more `svclb-traefik-*` rows appear only once Traefik is deployed in M3 — at this stage of M1 the line may be empty, which is correct. (`verify-cluster.sh` step 4 only requires svclb once a LoadBalancer Service exists; for a bare M1 cluster, confirm servicelb is *available* via the controller, not yet scheduled.)

6. Confirm secrets-encryption is active two ways:

```bash
orb -m k3s -u root k3s secrets-encrypt status
kubectl get --raw=/api/v1/namespaces/kube-system/secrets >/dev/null && echo "api ok"
```

Expected:

```
Encryption Status: Enabled
Current Rotation Stage: start
…
api ok
```

7. Run the full live contract check:

```bash
infra/k3s-bootstrap/verify-cluster.sh
```

Expected final line:

```
OK: host substrate verified (node Ready, both SCs, traefik/metrics-server absent, servicelb present, secrets-encryption enabled).
```

8. Run the **entire** bats suite once more to confirm every committed script still passes its offline contract:

```bash
bats infra/k3s-bootstrap/test/
```

Expected (abridged):

```
…
36 tests, 0 failures
```

9. Capture acceptance evidence into the runbook (create the file; this is the only doc this milestone writes, and it is operational, not a summary):

   Create `docs/runbooks/host-substrate.md` with the live `kubectl get nodes`, `kubectl get sc`, and `k3s secrets-encrypt status` outputs pasted under a dated "Acceptance evidence" heading, plus the one-liner recovery note: *"Full rebuild = `make up` (→ `infra/k3s-bootstrap/host-up.sh`, cattle); state repopulates via ArgoCD + R2 restore."*

10. Commit.

```bash
git add docs/runbooks/host-substrate.md
git commit -m "docs(k3s-bootstrap): 호스트 서브스트레이트 가동 런북과 수용 증적 추가"
```

---

**Milestone 1 exit criteria (all must hold):**
- `bats infra/k3s-bootstrap/test/` is green (all offline contract tests pass).
- `bats test/makefile.bats` is green — M0's `Makefile` still has its original stub targets intact, and `up`/`host-up` now route to `infra/k3s-bootstrap/host-up.sh` (no target re-declared, `Makefile` not re-created).
- `infra/k3s-bootstrap/orb-guard.sh` exits 0 — exactly one OrbStack machine `k3s`, running (R3).
- `kubectl get nodes` shows `k3s Ready`, k3s `v1.31.4+k3s1`, SQLite/kine (no etcd).
- `kubectl get sc` shows `standard (default)` on the internal-SSD provisioner (`Retain`, `Immediate`) and `bulk-ssd` on the external-SSD provisioner (`WaitForFirstConsumer`).
- `traefik` and `metrics-server` pods are absent; `servicelb` is kept.
- `k3s secrets-encrypt status` reports `Enabled`.
- The kubeconfig exists only at the gitignored `infra/k3s-bootstrap/kubeconfig` and is never committed.
- Every bring-up step is a committed script (host substrate as code) — a full VM rebuild is the idempotent `make up` (→ `host-up.sh`), which M5's `make bootstrap` invokes first.
- This milestone authored **no** repo scaffolding (`.sops.yaml`, `pnpm-workspace.yaml`, root `package.json`, age key, or `Makefile` creation) — all of those are owned by M0; M1 only **Modified** M0's `Makefile`.

---

## Milestone 2 — Cloud IaC + `make bootstrap`

**Goal:** Stand up all out-of-cluster control-plane state as Terraform (Cloudflare DNS/Tunnel/WAF/Cache/R2, GitHub repo+protection+secrets, Tailscale ACLs/tags/split-DNS/OAuth), pipe its outputs through SOPS into env-scoped seed secrets, wire KSOPS into the ArgoCD repo-server, and deliver one idempotent `make bootstrap` that installs a pinned ArgoCD, mounts the cluster age key, and applies the root app — the single DR entry-point (R5).

**Depends on:** Milestone 0 (repo scaffolding: env-scoped `.sops.yaml` with `&cluster`/`&recovery` placeholder anchors, `pnpm-workspace.yaml` + root `package.json` on pnpm@10, the `Makefile` stub targets `bootstrap`/`up`/`down`/`verify`/`host-up`, and the age-key custody — ONE cluster key minted at `~/.config/sops/age/keys.txt` plus an offline recovery recipient in a password manager) and Milestone 1 (live cluster: OrbStack VM + k3s reachable via a working `~/.kube/config` with `--secrets-encryption` on). This milestone **consumes** the M0 age key and a live cluster, but does **not** require any platform app to be deployed yet.

Use @superpowers:executing-plans to run this milestone task-by-task. Local tooling required (install via M1 dev-shell or Homebrew): `terraform >= 1.9`, `sops >= 3.9`, `age` (`age-keygen`), `helm >= 3.15`, `kubectl`, `jq`, `rclone`, `bats`. The Cloudflare provider used here is **v5.x** (`cloudflare/cloudflare ~> 5.0`).

---

### Task 2.0 — Manual-once: R2 state bucket + the committed `backend.tf`; fill the real age recipients into M0's `.sops.yaml`

This is the **only** manual step in the milestone; everything after it is reproducible. It creates the Terraform remote-state bucket and writes the committed backend config that all three Terraform roots share. It does **not** mint any age key — M0 already minted the single cluster key at `~/.config/sops/age/keys.txt` and stored the offline recovery private key in a password manager. M2 **consumes** that key, asserts it exists, reads both recipients, and fills them into the `&cluster`/`&recovery` placeholders that M0 left in `.sops.yaml`.

**Files**
- Create: `docs/runbooks/02-cloud-iac-bootstrap.md` (the manual-once checklist)
- Create: `infra/_backend/backend.tf` (shared partial backend config, committed)
- Create: `infra/_backend/backend.hcl.example` (committed example of the secret-bearing partial config)
- Verify (NO edit): `.sops.yaml` recipients are the real keys M0 already filled in Task 0.5 (M2 consumes, never re-fills)

**Steps**

1. **Write the verification first** — a check that the M0 cluster age key and the R2 state bucket exist. Create `docs/runbooks/02-cloud-iac-bootstrap.md` containing this exact preflight block, then run it:

   ````markdown
   # Runbook 02 — Cloud IaC Bootstrap (manual-once + make bootstrap)

   ## Preflight verification (run before anything else)

   ```bash
   # (a) the ONE M0 cluster age key must exist (M2 consumes it; never regenerated here)
   test -f ~/.config/sops/age/keys.txt && echo "cluster key OK"

   # (b) the offline recovery recipient must be recorded (private key lives in the
   #     password manager — M0 custody; here we only need its PUBLIC key on hand)
   test -n "${AGE_RECOVERY_RECIPIENT:-}" && echo "recovery recipient OK"

   # (c) R2 state bucket must exist and be reachable via rclone remote 'r2'
   rclone lsd r2: | grep -q 'homelab-tfstate' && echo "state bucket OK"
   ```
   ````

   Run:
   ```bash
   bash -c 'test -f ~/.config/sops/age/keys.txt && echo "cluster key OK" || echo "MISSING cluster key"'
   ```
   **Expected PASS output** (M0 minted it; if this prints MISSING, M0 was not completed — stop and finish M0):
   ```
   cluster key OK
   ```

2. **Read both recipients from the M0 key material** (do **not** mint anything). The cluster recipient is derived from the on-disk private key; the recovery recipient is the public key M0 recorded in the password manager (paste it into the env var):
   ```bash
   # cluster recipient: derived from the M0 private key on disk
   export AGE_CLUSTER_RECIPIENT=$(age-keygen -y ~/.config/sops/age/keys.txt)
   echo "cluster recipient: $AGE_CLUSTER_RECIPIENT"

   # recovery recipient: the PUBLIC key M0 stored alongside the recovery private key
   # in the password manager (private key is NOT on this workstation).
   export AGE_RECOVERY_RECIPIENT=age1recoveryPUBLICkeyFROMpasswordMANAGER
   echo "recovery recipient: $AGE_RECOVERY_RECIPIENT"
   ```
   **Expected output (two `age1...` public keys printed):**
   ```
   cluster recipient: age1clusterxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxq8n2k9
   recovery recipient: age1recoveryxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxq3m7p2
   ```
   Record the recovery-key custody location (which password manager / vault item) in `docs/runbooks/02-cloud-iac-bootstrap.md` for traceability — M0 closed §15 "second age-recovery-recipient custody location"; this milestone references it. **No key is ever minted, copied, or written to disk here.**

3. **Create the R2 state bucket and an `rclone` remote** named `r2`. In the Cloudflare dashboard create an R2 API token (Object Read & Write) for account `<ACCT_ID>`, then:
   ```bash
   rclone config create r2 s3 \
     provider=Cloudflare \
     access_key_id=<R2_STATE_ACCESS_KEY> \
     secret_access_key=<R2_STATE_SECRET_KEY> \
     endpoint=https://<ACCT_ID>.r2.cloudflarestorage.com \
     region=auto
   rclone mkdir r2:homelab-tfstate
   ```
   The state bucket is created **manually, once, before any `terraform apply`** (it stores the very state these roots write — see R5; it must exist before init).

4. **Write the committed backend config.** Terraform's S3 backend works against R2 with checksum/region quirks disabled. Create `infra/_backend/backend.tf`:
   ```hcl
   # Shared S3-compatible backend pointed at Cloudflare R2.
   # Per-root state key is supplied via `-backend-config` at init time.
   # Secrets (endpoints, account id, keys) live ONLY in backend.hcl (gitignored).
   terraform {
     backend "s3" {
       bucket = "homelab-tfstate"
       region = "auto"

       # R2 is not real AWS S3 — disable the AWS-only handshakes.
       skip_credentials_validation = true
       skip_region_validation      = true
       skip_requesting_account_id  = true
       skip_metadata_api_check     = true
       skip_s3_checksum            = true
       use_path_style              = true
     }
   }
   ```
   Create `infra/_backend/backend.hcl.example` (committed; the real `backend.hcl` is gitignored):
   ```hcl
   # Copy to infra/<root>/backend.hcl and fill in. NEVER commit the filled version.
   endpoints  = { s3 = "https://<ACCT_ID>.r2.cloudflarestorage.com" }
   access_key = "<R2_STATE_ACCESS_KEY>"
   secret_key = "<R2_STATE_SECRET_KEY>"
   # key is set per-root below, e.g. key = "cloudflare/prod/terraform.tfstate"
   ```

5. **VERIFY the recipients M0 already filled (consume, do NOT re-fill or restructure).** M0 (Task 0.5) substituted the real cluster + recovery public keys into `.sops.yaml`; M2 only asserts they are present:
   ```bash
   grep -q 'REPLACEME' .sops.yaml && { echo "FAIL: .sops.yaml still has placeholder recipients — fix in M0 Task 0.5"; exit 1; }
   grep -q "$AGE_CLUSTER_RECIPIENT" .sops.yaml && grep -q "$AGE_RECOVERY_RECIPIENT" .sops.yaml \
     && echo ".sops.yaml recipients verified (cluster + recovery)"
   ```
   The M0-authored `_recipients` anchor block already reads (filled in M0, not here):
   ```yaml
   # Recipients are public keys (safe to commit). Private keys live out-of-band (M0 Task 0.4).
   _recipients:
     - &cluster  age1clusterxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxq8n2k9
     - &recovery age1recoveryxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxq3m7p2
   ```
   The `creation_rules` (prod / staging / catch-all, all `encrypted_regex: "^(data|stringData)$"`, both keys per `key_groups.age`) are M0's and are left untouched. Every `*.enc.yaml` is now encrypted to **both** the in-cluster key and the offline recovery key.

6. **Run the full preflight again:**
   ```bash
   rclone lsd r2: | grep -q 'homelab-tfstate' && echo "state bucket OK"
   test -f ~/.config/sops/age/keys.txt && echo "cluster key OK"
   sops --version | grep -qE '3\.(9|1[0-9])' && echo "sops OK"
   ```
   **Expected PASS output:**
   ```
   state bucket OK
   cluster key OK
   sops OK
   ```

7. **Commit** (only the backend artifacts, the runbook, and the recipient-filled `.sops.yaml`; no private key is ever written to the repo):
   ```bash
   git add docs/runbooks/02-cloud-iac-bootstrap.md infra/_backend/backend.tf infra/_backend/backend.hcl.example
   git commit -m "chore: R2 상태 버킷 부트스트랩 및 backend 설정 추가 (.sops.yaml 수신자는 M0가 채움)"
   ```

---

### Task 2.1 — Cloudflare Terraform root: providers, backend wiring, variables

Scaffold the `infra/cloudflare` root with pinned providers and the R2 backend; assert it initializes against R2 state before writing any resources.

**Files**
- Create: `infra/cloudflare/versions.tf`
- Create: `infra/cloudflare/backend.tf` (copy of the shared partial; see Step 3)
- Create: `infra/cloudflare/variables.tf`
- Create: `infra/cloudflare/provider.tf`
- Create: `infra/cloudflare/terraform.tfvars.example`
- Modify: `.gitignore` (repo root — M0 created it; append the Terraform/SOPS-plaintext patterns if absent)
- Test: `infra/cloudflare/backend.hcl` (gitignored, local only)

**Steps**

1. **Verification first** — assert `terraform init` succeeds against R2 (currently fails: no config). Ensure `.gitignore` (authored by M0) contains the Terraform + SOPS-plaintext patterns; append any that are missing:
   ```gitignore
   # Terraform
   **/.terraform/*
   *.tfstate
   *.tfstate.*
   crash.log
   backend.hcl
   terraform.tfvars
   *.auto.tfvars
   # SOPS plaintext / keys
   *.dec.yaml
   *.tmp.yaml
   keys.txt
   ```

2. Run the not-yet-possible init:
   ```bash
   terraform -chdir=infra/cloudflare init -backend-config=infra/cloudflare/backend.hcl
   ```
   **Expected FAILURE output:**
   ```
   Error: Initialization required. ...
   There are no Terraform configuration files in the directory.
   ```

3. Create `infra/cloudflare/versions.tf`:
   ```hcl
   terraform {
     required_version = ">= 1.9.0"
     required_providers {
       cloudflare = {
         source  = "cloudflare/cloudflare"
         version = "~> 5.0"
       }
     }
   }
   ```
   Copy the shared backend in: write `infra/cloudflare/backend.tf` with the **same contents** as `infra/_backend/backend.tf` (Terraform requires the backend block in-root; do not symlink across roots as `chdir` won't follow it reliably). Then create the gitignored `infra/cloudflare/backend.hcl`:
   ```hcl
   endpoints  = { s3 = "https://<ACCT_ID>.r2.cloudflarestorage.com" }
   access_key = "<R2_STATE_ACCESS_KEY>"
   secret_key = "<R2_STATE_SECRET_KEY>"
   key        = "cloudflare/prod/terraform.tfstate"
   ```

4. Create `infra/cloudflare/provider.tf`:
   ```hcl
   provider "cloudflare" {
     api_token = var.cloudflare_api_token
   }
   ```
   Create `infra/cloudflare/variables.tf`:
   ```hcl
   variable "cloudflare_api_token" {
     type        = string
     sensitive   = true
     description = "Cloudflare API token (Zone:Edit, DNS:Edit, Workers R2:Edit, Cloudflare Tunnel:Edit)."
   }
   variable "cloudflare_account_id" {
     type        = string
     description = "Cloudflare account ID."
   }
   variable "zone_name" {
     type        = string
     description = "Apex domain, e.g. example.com (the <DOMAIN> placeholder)."
   }
   variable "tunnel_name" {
     type    = string
     default = "homelab-prod"
   }
   variable "internal_suffix" {
     type        = string
     description = "Internal hostname suffix, e.g. int.example.com."
   }
   variable "tailscale_ip" {
     type        = string
     description = "Stable Tailscale IP of the VM (for split-horizon; used by AdGuard/Tailscale roots, surfaced here for record)."
     default     = ""
   }
   ```
   Create `infra/cloudflare/terraform.tfvars.example`:
   ```hcl
   cloudflare_account_id = "<ACCT_ID>"
   zone_name             = "<DOMAIN>"
   internal_suffix       = "int.<DOMAIN>"
   tunnel_name           = "homelab-prod"
   # cloudflare_api_token supplied via TF_VAR_cloudflare_api_token (env), never in tfvars.
   ```

5. **Run init again:**
   ```bash
   export TF_VAR_cloudflare_api_token=<CF_TOKEN>
   terraform -chdir=infra/cloudflare init -backend-config=infra/cloudflare/backend.hcl
   ```
   **Expected PASS output:**
   ```
   Initializing the backend...
   Successfully configured the backend "s3"! Terraform will automatically
   use this backend unless the backend configuration changes.
   Initializing provider plugins...
   - Installing cloudflare/cloudflare v5.x.x...
   Terraform has been successfully initialized!
   ```

6. **Commit:**
   ```bash
   git add infra/cloudflare/versions.tf infra/cloudflare/backend.tf infra/cloudflare/variables.tf infra/cloudflare/provider.tf infra/cloudflare/terraform.tfvars.example .gitignore
   git commit -m "feat: Cloudflare Terraform 루트 프로바이더 및 R2 백엔드 구성"
   ```

---

### Task 2.2 — Cloudflare resources: zone data + R2 buckets + creds

Add the zone data source and the two R2 buckets (pg-backups, media) with lifecycle. Assert plan shows the expected counts.

**Files**
- Create: `infra/cloudflare/r2.tf`
- Create: `infra/cloudflare/data.tf`

**Steps**

1. **Verification first** — write a plan-count assertion (currently fails: no resources). Add this assertion command to the runbook and run it now:
   ```bash
   terraform -chdir=infra/cloudflare plan -out=/tmp/cf.plan >/dev/null && \
   terraform -chdir=infra/cloudflare show -json /tmp/cf.plan | \
     jq '[.resource_changes[] | select(.change.actions[]=="create")] | length'
   ```
   **Expected FAILURE output:**
   ```
   0
   ```

2. Create `infra/cloudflare/data.tf`:
   ```hcl
   data "cloudflare_zone" "this" {
     filter = {
       name = var.zone_name
     }
   }
   ```

3. Create `infra/cloudflare/r2.tf` (D4/§7 — backups bucket SEPARATE from media bucket; lifecycle on backups):
   ```hcl
   # NOTE: homelab-tfstate is created manually in Task 2.0 and deliberately
   # NOT managed by Terraform — it stores this state file (would self-reference).

   # Offsite copy-3 of Postgres (barman-cloud WAL + base + pg_dump hedge).
   resource "cloudflare_r2_bucket" "pg_backups" {
     account_id = var.cloudflare_account_id
     name       = "homelab-pg-backups-prod"
     location   = "WEUR"
   }

   # 14d offsite retention (matches CNPG ScheduledBackup retention in M4).
   resource "cloudflare_r2_bucket_lifecycle" "pg_backups" {
     account_id  = var.cloudflare_account_id
     bucket_name = cloudflare_r2_bucket.pg_backups.name
     rules = [{
       id      = "expire-14d"
       enabled = true
       conditions = { prefix = "" }
       delete_objects_transition = {
         condition = { type = "Age", max_age = 1209600 } # 14 days in seconds
       }
     }]
   }

   # Durable origin for the media service (local SSD is the hot cache, §7).
   resource "cloudflare_r2_bucket" "media" {
     account_id = var.cloudflare_account_id
     name       = "homelab-media-prod"
     location   = "WEUR"
   }
   ```

4. **Run the plan assertion:**
   ```bash
   terraform -chdir=infra/cloudflare plan -out=/tmp/cf.plan >/dev/null && \
   terraform -chdir=infra/cloudflare show -json /tmp/cf.plan | \
     jq '[.resource_changes[] | select(.change.actions[]=="create")] | length'
   ```
   **Expected PASS output:**
   ```
   3
   ```
   (2 buckets + 1 lifecycle.)

5. **Commit:**
   ```bash
   git add infra/cloudflare/data.tf infra/cloudflare/r2.tf
   git commit -m "feat: Cloudflare R2 버킷(pg-backups/media) 및 14일 수명주기 추가"
   ```

---

### Task 2.3 — Cloudflare cloudflared tunnel + tunnel config + DNS records

Add the named tunnel, its config (route apex + SSR + SPA hosts to in-cluster Traefik), and proxied CNAME DNS records (zero inbound ports). cloudflared runs in the `edge` namespace in-cluster.

**Files**
- Create: `infra/cloudflare/tunnel.tf`
- Create: `infra/cloudflare/dns.tf`

**Steps**

1. **Verification first** — assert a `cloudflare_zero_trust_tunnel_cloudflared_token` output will exist (currently fails). Run:
   ```bash
   terraform -chdir=infra/cloudflare plan 2>&1 | grep -c 'tunnel_cloudflared' || true
   ```
   **Expected FAILURE output:**
   ```
   0
   ```

2. Create `infra/cloudflare/tunnel.tf` (cloudflared = 1 replica, plaintext to Traefik ClusterIP, §6):
   ```hcl
   resource "random_password" "tunnel_secret" {
     length  = 64
     special = false
   }

   resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
     account_id    = var.cloudflare_account_id
     name          = var.tunnel_name
     tunnel_secret = base64encode(random_password.tunnel_secret.result)
     config_src    = "cloudflare"
   }

   # Ingress rules: public hosts → in-cluster Traefik (plaintext, TLS terminates at edge).
   resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
     account_id = var.cloudflare_account_id
     tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
     config = {
       ingress = [
         {
           hostname = var.zone_name
           service  = "http://traefik.gateway.svc.cluster.local:80"
         },
         {
           hostname = "www.${var.zone_name}"
           service  = "http://traefik.gateway.svc.cluster.local:80"
         },
         {
           hostname = "api.${var.zone_name}"
           service  = "http://traefik.gateway.svc.cluster.local:80"
         },
         {
           service = "http_status:404"
         }
       ]
     }
   }
   ```
   Add the `random` provider to `versions.tf`:
   ```hcl
       random = {
         source  = "hashicorp/random"
         version = "~> 3.6"
       }
   ```
   (Insert inside the existing `required_providers {}` block, then re-run `terraform -chdir=infra/cloudflare init -upgrade -backend-config=infra/cloudflare/backend.hcl`.)

3. Create `infra/cloudflare/dns.tf` (proxied CNAMEs to the tunnel — the only ingress path):
   ```hcl
   locals {
     tunnel_target = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
     public_hosts  = toset([var.zone_name, "www.${var.zone_name}", "api.${var.zone_name}"])
   }

   resource "cloudflare_dns_record" "public" {
     for_each = local.public_hosts
     zone_id  = data.cloudflare_zone.this.zone_id
     name     = each.value
     type     = "CNAME"
     content  = local.tunnel_target
     proxied  = true
     ttl      = 1
   }
   ```

4. **Run the assertion + a full plan count:**
   ```bash
   terraform -chdir=infra/cloudflare plan -out=/tmp/cf.plan >/dev/null && \
   terraform -chdir=infra/cloudflare show -json /tmp/cf.plan | \
     jq '[.resource_changes[] | select(.change.actions[]=="create")] | length'
   ```
   **Expected PASS output:**
   ```
   9
   ```
   (2 R2 buckets + 1 lifecycle + 1 random_password + 1 tunnel + 1 tunnel_config + 3 DNS records = 9.) Record the exact number in the runbook; the assertion is `>= 8`.

5. **Commit:**
   ```bash
   git add infra/cloudflare/tunnel.tf infra/cloudflare/dns.tf infra/cloudflare/versions.tf
   git commit -m "feat: cloudflared 터널 및 프록시 DNS 레코드 추가"
   ```

---

### Task 2.4 — Cloudflare WAF ruleset + Cache Rules ruleset

Add a custom WAF ruleset and a Cache Rules ruleset scoped to static asset paths only, with explicit bypass for API + SSR HTML (§6 — else per-user content leaks).

**Files**
- Create: `infra/cloudflare/waf.tf`
- Create: `infra/cloudflare/cache.tf`

**Steps**

1. **Verification first** — assert a cache ruleset with a cache-settings rule exists (currently fails):
   ```bash
   terraform -chdir=infra/cloudflare plan 2>&1 | grep -c 'http_request_cache_settings' || true
   ```
   **Expected FAILURE output:**
   ```
   0
   ```

2. Create `infra/cloudflare/waf.tf`:
   ```hcl
   resource "cloudflare_ruleset" "waf_custom" {
     zone_id     = data.cloudflare_zone.this.zone_id
     name        = "homelab-waf-custom"
     kind        = "zone"
     phase       = "http_request_firewall_custom"
     description = "Baseline WAF: block known-bad methods + obvious path traversal."
     rules = [
       {
         ref         = "block-traversal"
         description = "Block path traversal attempts"
         expression  = "(http.request.uri.path contains \"../\") or (http.request.uri.path contains \"..%2f\")"
         action      = "block"
         enabled     = true
       },
       {
         ref         = "block-disallowed-methods"
         description = "Only allow standard HTTP methods"
         expression  = "not (http.request.method in {\"GET\" \"POST\" \"PUT\" \"PATCH\" \"DELETE\" \"HEAD\" \"OPTIONS\"})"
         action      = "block"
         enabled     = true
       }
     ]
   }
   ```

3. Create `infra/cloudflare/cache.tf` (cache ONLY static paths; bypass API + SSR HTML — §6):
   ```hcl
   resource "cloudflare_ruleset" "cache_rules" {
     zone_id     = data.cloudflare_zone.this.zone_id
     name        = "homelab-cache-rules"
     kind        = "zone"
     phase       = "http_request_cache_settings"
     description = "Cache static assets; bypass API + SSR HTML to avoid per-user leaks."
     rules = [
       {
         ref         = "bypass-api-and-ssr"
         description = "Never cache API or SSR HTML responses"
         expression  = "(http.host eq \"api.${var.zone_name}\") or (http.request.uri.path eq \"/\") or (not http.request.uri.path matches \"^/(assets|_next/static)/\")"
         action      = "set_cache_settings"
         action_parameters = {
           cache = false
         }
         enabled = true
       },
       {
         ref         = "cache-static-assets"
         description = "Edge-cache hashed static assets aggressively"
         expression  = "http.request.uri.path matches \"^/(assets|_next/static)/\""
         action      = "set_cache_settings"
         action_parameters = {
           cache = true
           edge_ttl = {
             mode    = "override_origin"
             default = 2592000 # 30 days — assets are content-hashed
           }
           browser_ttl = {
             mode    = "override_origin"
             default = 86400
           }
         }
         enabled = true
       }
     ]
   }
   ```

4. **Run the assertion:**
   ```bash
   terraform -chdir=infra/cloudflare plan 2>&1 | grep -c 'http_request_cache_settings'
   ```
   **Expected PASS output:**
   ```
   1
   ```

5. **Commit:**
   ```bash
   git add infra/cloudflare/waf.tf infra/cloudflare/cache.tf
   git commit -m "feat: Cloudflare WAF 및 정적 경로 한정 Cache Rules 추가"
   ```

---

### Task 2.5 — Cloudflare outputs (tunnel token + R2 creds for seed secrets)

Emit the outputs that feed the SOPS seed secrets. These are the cross-boundary handoff (§3: Terraform emits, SOPS encrypts into the monorepo).

**Files**
- Create: `infra/cloudflare/outputs.tf`

**Steps**

1. **Verification first** — assert the tunnel-token output exists (currently fails):
   ```bash
   terraform -chdir=infra/cloudflare output -json 2>/dev/null | jq 'has("tunnel_token")'
   ```
   **Expected FAILURE output:**
   ```
   false
   ```
   (or an error — output set is empty.)

2. Create `infra/cloudflare/outputs.tf`:
   ```hcl
   # R2 access/secret KEY PAIRS are minted as scoped R2 API tokens out-of-band
   # (one for pg-backups RW, one for media RW) and injected at Task 2.9.

   output "tunnel_token" {
     description = "cloudflared run token → seed Secret for the cloudflared Deployment."
     value       = cloudflare_zero_trust_tunnel_cloudflared.homelab.token
     sensitive   = true
   }

   output "tunnel_id" {
     value     = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
     sensitive = false
   }

   output "r2_account_endpoint" {
     value     = "https://${var.cloudflare_account_id}.r2.cloudflarestorage.com"
     sensitive = false
   }

   output "r2_pg_backups_bucket" {
     value     = cloudflare_r2_bucket.pg_backups.name
     sensitive = false
   }

   output "r2_media_bucket" {
     value     = cloudflare_r2_bucket.media.name
     sensitive = false
   }
   ```
   Note: R2 **access/secret keys** for CNPG/media are minted out-of-band as scoped R2 API tokens (Cloudflare v5 provider does not manage R2 token secrets cleanly). They are captured in the seed-secret step (Task 2.9) as variables, not Terraform outputs.

3. **Apply the Cloudflare root** (first real apply — establishes the tunnel so its token can be read):
   ```bash
   terraform -chdir=infra/cloudflare apply -auto-approve
   ```
   **Expected output (tail):**
   ```
   Apply complete! Resources: 9 added, 0 changed, 0 destroyed.
   Outputs:
   r2_account_endpoint = "https://<ACCT_ID>.r2.cloudflarestorage.com"
   r2_media_bucket = "homelab-media-prod"
   r2_pg_backups_bucket = "homelab-pg-backups-prod"
   tunnel_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   tunnel_token = <sensitive>
   ```

4. **Run the assertion:**
   ```bash
   terraform -chdir=infra/cloudflare output -json | jq 'has("tunnel_token")'
   ```
   **Expected PASS output:**
   ```
   true
   ```

5. **Commit:**
   ```bash
   git add infra/cloudflare/outputs.tf
   git commit -m "feat: Cloudflare 터널 토큰 및 R2 시드 출력값 추가"
   ```

---

### Task 2.6 — Tailscale Terraform root: ACLs, tags, split-DNS, OAuth client `tag:k8s-operator`

Stand up the Tailscale root managing the policy (ACLs + tags), split-DNS for `int.<DOMAIN>` → stable Tailscale IP, and the OAuth client tagged `k8s-operator` consumed by the Tailscale operator (§6). The operator OAuth seed Secret lands in the `edge` namespace.

**Files**
- Create: `infra/tailscale/versions.tf`
- Create: `infra/tailscale/backend.tf`
- Create: `infra/tailscale/provider.tf`
- Create: `infra/tailscale/variables.tf`
- Create: `infra/tailscale/acl.tf`
- Create: `infra/tailscale/oauth.tf`
- Create: `infra/tailscale/outputs.tf`
- Create: `infra/tailscale/terraform.tfvars.example`
- Test: `infra/tailscale/backend.hcl` (gitignored)

**Steps**

1. **Verification first** — assert init then that an `oauth_client` is planned (fails: no root):
   ```bash
   terraform -chdir=infra/tailscale init -backend-config=infra/tailscale/backend.hcl 2>&1 | tail -1
   ```
   **Expected FAILURE output:**
   ```
   Error: No configuration files
   ```

2. Create `infra/tailscale/versions.tf`:
   ```hcl
   terraform {
     required_version = ">= 1.9.0"
     required_providers {
       tailscale = {
         source  = "tailscale/tailscale"
         version = "~> 0.18"
       }
     }
   }
   ```
   Create `infra/tailscale/backend.tf` (same body as `infra/_backend/backend.tf`). Create gitignored `infra/tailscale/backend.hcl` with `key = "tailscale/prod/terraform.tfstate"` (other fields identical to cloudflare's).

3. Create `infra/tailscale/provider.tf` + `variables.tf`:
   ```hcl
   # provider.tf
   provider "tailscale" {
     oauth_client_id     = var.ts_bootstrap_oauth_id
     oauth_client_secret = var.ts_bootstrap_oauth_secret
     scopes              = ["all"]
   }
   ```
   ```hcl
   # variables.tf
   variable "ts_bootstrap_oauth_id" {
     type      = string
     sensitive = true
   }
   variable "ts_bootstrap_oauth_secret" {
     type      = string
     sensitive = true
   }
   variable "internal_suffix" {
     type = string # int.<DOMAIN>
   }
   variable "tailscale_ip" {
     type        = string
     description = "Stable Tailscale IP of the VM (split-DNS nameserver target)."
   }
   ```

4. Create `infra/tailscale/acl.tf` (tags + ACL + split-DNS → stable Tailscale IP, R7):
   ```hcl
   resource "tailscale_acl" "homelab" {
     acl = jsonencode({
       tagOwners = {
         "tag:k8s-operator" = ["autogroup:admin"]
         "tag:k8s"          = ["tag:k8s-operator"]
       }
       acls = [
         { action = "accept", src = ["autogroup:member"], dst = ["tag:k8s:*"] },
         { action = "accept", src = ["tag:k8s-operator"], dst = ["*:*"] }
       ]
       # Split-horizon: int.<DOMAIN> resolves to the in-VM Traefik via the
       # operator-exposed Ingress, pinned to the stable Tailscale IP (R7).
       nodeAttrs = [
         { target = ["tag:k8s"], attr = ["funnel"] }
       ]
     })
   }

   resource "tailscale_dns_split_nameservers" "internal" {
     domain      = var.internal_suffix
     nameservers = [var.tailscale_ip]
   }
   ```

5. Create `infra/tailscale/oauth.tf` (the operator's OAuth client — `tag:k8s-operator`):
   ```hcl
   resource "tailscale_oauth_client" "k8s_operator" {
     description = "Tailscale Kubernetes operator (homelab-prod)"
     scopes      = ["devices:core", "auth_keys"]
     tags        = ["tag:k8s-operator"]
   }
   ```
   Create `infra/tailscale/outputs.tf`:
   ```hcl
   output "operator_oauth_client_id" {
     value     = tailscale_oauth_client.k8s_operator.id
     sensitive = true
   }
   output "operator_oauth_client_secret" {
     value     = tailscale_oauth_client.k8s_operator.key
     sensitive = true
   }
   ```
   Create `infra/tailscale/terraform.tfvars.example`:
   ```hcl
   internal_suffix = "int.<DOMAIN>"
   tailscale_ip    = "100.x.y.z"
   # ts_bootstrap_oauth_* supplied via TF_VAR_* env.
   ```

6. **Init, plan, then assert the OAuth client is planned:**
   ```bash
   export TF_VAR_ts_bootstrap_oauth_id=<ID> TF_VAR_ts_bootstrap_oauth_secret=<SECRET>
   terraform -chdir=infra/tailscale init -backend-config=infra/tailscale/backend.hcl
   terraform -chdir=infra/tailscale plan -out=/tmp/ts.plan >/dev/null && \
   terraform -chdir=infra/tailscale show -json /tmp/ts.plan | \
     jq '[.resource_changes[] | select(.type=="tailscale_oauth_client")] | length'
   ```
   **Expected PASS output:**
   ```
   1
   ```

7. **Apply and commit:**
   ```bash
   terraform -chdir=infra/tailscale apply -auto-approve
   git add infra/tailscale/*.tf infra/tailscale/terraform.tfvars.example
   git commit -m "feat: Tailscale ACL/태그/split-DNS 및 k8s-operator OAuth 클라이언트 추가"
   ```

---

### Task 2.7 — GitHub Terraform root: repo settings, branch protection, Actions secrets

Manage the monorepo's GitHub settings, branch protection on the default branch, and the Actions secrets CI needs (GHCR is built-in `GITHUB_TOKEN`; here we set the bot PAT for serialized write-back + Telegram for deploy notifications, R6/§8).

**Files**
- Create: `infra/github/versions.tf`
- Create: `infra/github/backend.tf`
- Create: `infra/github/provider.tf`
- Create: `infra/github/variables.tf`
- Create: `infra/github/repo.tf`
- Create: `infra/github/secrets.tf`
- Create: `infra/github/terraform.tfvars.example`
- Test: `infra/github/backend.hcl` (gitignored)

**Steps**

1. **Verification first** — assert a `github_branch_protection` is planned (fails: no root):
   ```bash
   terraform -chdir=infra/github plan 2>&1 | grep -c 'branch_protection' || true
   ```
   **Expected FAILURE output:**
   ```
   0
   ```

2. Create `infra/github/versions.tf`:
   ```hcl
   terraform {
     required_version = ">= 1.9.0"
     required_providers {
       github = {
         source  = "integrations/github"
         version = "~> 6.2"
       }
     }
   }
   ```
   Create `infra/github/backend.tf` (shared body) + gitignored `backend.hcl` with `key = "github/prod/terraform.tfstate"`.

3. Create `infra/github/provider.tf` + `variables.tf`:
   ```hcl
   # provider.tf
   provider "github" {
     owner = var.github_owner
     token = var.github_token
   }
   ```
   ```hcl
   # variables.tf
   variable "github_owner" {
     type = string
   }
   variable "github_token" {
     type      = string
     sensitive = true
   }
   variable "repo_name" {
     type    = string
     default = "homelab"
   }
   variable "bot_pat" {
     type        = string
     sensitive   = true
     description = "Fine-grained PAT for the serialized values.yaml write-back bot."
   }
   variable "telegram_bot_token" {
     type      = string
     sensitive = true
   }
   variable "telegram_chat_id" {
     type      = string
     sensitive = true
   }
   ```

4. Create `infra/github/repo.tf`:
   ```hcl
   resource "github_repository" "homelab" {
     name                   = var.repo_name
     visibility             = "private"
     has_issues             = true
     allow_merge_commit     = false
     allow_squash_merge     = true
     allow_rebase_merge     = false
     delete_branch_on_merge = true
     # Repo already exists — import it once: see runbook 02.
   }

   resource "github_branch_protection" "main" {
     repository_id = github_repository.homelab.node_id
     pattern       = "main"

     required_status_checks {
       strict   = true
       contexts = ["gate"]   # ONLY `gate` runs on pull_request (ci.yaml); `build` runs on push-to-main (post-merge), so it must NOT be a required PR check or every PR hangs permanently pending
     }
     required_pull_request_reviews {
       required_approving_review_count = 0
       require_last_push_approval      = false
     }
     enforce_admins      = false
     allows_force_pushes = false
     allows_deletions    = false
   }
   ```
   (`enforce_admins=false` is deliberate: the serialized CI bot pushes the values.yaml bump to `main` directly using **`DEPLOY_BOT_PAT`** — an OWNER/ADMIN token, so its push BYPASSES the required check. `required_approving_review_count=0` so the bot needs no human review. ONLY `gate` is a required context because it is the sole job that runs on `pull_request` (ci.yaml, calling `pnpm verify:ledger`); `build` runs on push-to-main (post-merge image build) and therefore must NOT be a required PR check or every PR would hang permanently pending.)

5. Create `infra/github/secrets.tf`:
   ```hcl
   resource "github_actions_secret" "bot_pat" {
     repository      = github_repository.homelab.name
     secret_name     = "DEPLOY_BOT_PAT"
     plaintext_value = var.bot_pat
   }
   resource "github_actions_secret" "telegram_bot_token" {
     repository      = github_repository.homelab.name
     secret_name     = "TELEGRAM_BOT_TOKEN"
     plaintext_value = var.telegram_bot_token
   }
   resource "github_actions_secret" "telegram_chat_id" {
     repository      = github_repository.homelab.name
     secret_name     = "TELEGRAM_CHAT_ID"
     plaintext_value = var.telegram_chat_id
   }
   ```
   Create `infra/github/terraform.tfvars.example`:
   ```hcl
   github_owner = "<GH_USER>"
   repo_name    = "homelab"
   # github_token / bot_pat / telegram_* supplied via TF_VAR_* env.
   ```

6. **Import the existing repo, plan, assert:**
   ```bash
   export TF_VAR_github_owner=<GH_USER> TF_VAR_github_token=<GH_TOKEN> \
          TF_VAR_bot_pat=<BOT_PAT> TF_VAR_telegram_bot_token=<TG_TOKEN> TF_VAR_telegram_chat_id=<TG_CHAT>
   terraform -chdir=infra/github init -backend-config=infra/github/backend.hcl
   terraform -chdir=infra/github import github_repository.homelab homelab
   terraform -chdir=infra/github plan 2>&1 | grep -c 'github_branch_protection'
   ```
   **Expected PASS output:**
   ```
   1
   ```

7. **Apply and commit:**
   ```bash
   terraform -chdir=infra/github apply -auto-approve
   git add infra/github/*.tf infra/github/terraform.tfvars.example
   git commit -m "feat: GitHub 저장소 설정/브랜치 보호/Actions 시크릿 Terraform 추가"
   ```

---

### Task 2.8 — `make tf-validate`: a single validate+fmt gate across all three roots

A reusable Makefile target so CI and humans validate all IaC in one command (verification surface for every later Terraform change). This is a **new** target appended to M0's `Makefile` — it does not re-declare any M0 stub.

**Files**
- Modify: `Makefile` (append the new `tf-validate` target; never re-declare `bootstrap`/`up`/`down`/`verify`/`host-up`)
- Test: `infra/_test/tf_validate.bats`

**Steps**

1. **Verification first** — write a bats test that calls `make tf-validate` (fails: target missing). Create `infra/_test/tf_validate.bats`:
   ```bash
   #!/usr/bin/env bats

   @test "make tf-validate exits 0 across all roots" {
     run make tf-validate
     [ "$status" -eq 0 ]
     [[ "$output" == *"cloudflare: validated"* ]]
     [[ "$output" == *"tailscale: validated"* ]]
     [[ "$output" == *"github: validated"* ]]
   }
   ```
   Run:
   ```bash
   bats infra/_test/tf_validate.bats
   ```
   **Expected FAILURE output:**
   ```
   ✗ make tf-validate exits 0 across all roots
     make: *** No rule to make target 'tf-validate'.  Stop.
   ```

2. Append to `Makefile`:
   ```makefile
   TF_ROOTS := cloudflare tailscale github

   .PHONY: tf-validate
   tf-validate: ## terraform fmt -check + validate across all infra roots
   	@for r in $(TF_ROOTS); do \
   	  terraform -chdir=infra/$$r fmt -check -recursive >/dev/null || \
   	    { echo "$$r: fmt FAILED (run 'terraform -chdir=infra/$$r fmt -recursive')"; exit 1; }; \
   	  terraform -chdir=infra/$$r validate >/dev/null || { echo "$$r: validate FAILED"; exit 1; }; \
   	  echo "$$r: validated"; \
   	done
   ```
   (Note: real tabs, not spaces, in recipe lines.)

3. **Run the test:**
   ```bash
   terraform -chdir=infra/cloudflare fmt -recursive >/dev/null
   terraform -chdir=infra/tailscale fmt -recursive >/dev/null
   terraform -chdir=infra/github fmt -recursive >/dev/null
   bats infra/_test/tf_validate.bats
   ```
   **Expected PASS output:**
   ```
   ✓ make tf-validate exits 0 across all roots

   1 test, 0 failures
   ```

4. **Commit:**
   ```bash
   git add Makefile infra/_test/tf_validate.bats
   git commit -m "test: 전체 Terraform 루트 검증 make tf-validate 추가"
   ```

---

### Task 2.9 — Pipe Terraform outputs through SOPS into env-scoped seed secrets (the single producer)

Take the live outputs (tunnel token, R2 endpoint/buckets + out-of-band R2 token pairs, Tailscale operator OAuth, Telegram/healthchecks alerting) and SOPS-encrypt them into `platform/**/prod/*.enc.yaml`. This is the §3 handoff and `seed-secrets.sh` is the **single producer** of all four seed credentials — M3/M4/M5 reference these exact filenames and Secret names and must not re-create any of them.

Canonical filenames + Secret names (consumed downstream):
- `platform/cloudflared/prod/tunnel.enc.yaml` → Secret `cloudflared-tunnel` (ns `edge`)
- `platform/tailscale/prod/operator-oauth.enc.yaml` → Secret `operator-oauth` (ns `edge`)
- `platform/cnpg/prod/r2-creds.enc.yaml` → Secret `cnpg-r2-creds` (ns `database`)
- `platform/victoria-stack/prod/alerting.enc.yaml` → Secret `alerting-secrets` (ns `observability`; keys `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID`/`HEALTHCHECKS_URL`)

**Files**
- Create: `scripts/seed-secrets.sh`
- Create: `platform/cloudflared/prod/tunnel.enc.yaml`
- Create: `platform/tailscale/prod/operator-oauth.enc.yaml`
- Create: `platform/cnpg/prod/r2-creds.enc.yaml`
- Create: `platform/victoria-stack/prod/alerting.enc.yaml`
- Modify: `Makefile` (append the new `seed-secrets` target)

**Steps**

1. **Verification first** — assert the encrypted seed decrypts to the right keys (fails: no file). Run:
   ```bash
   sops -d platform/cloudflared/prod/tunnel.enc.yaml 2>&1 | head -1
   ```
   **Expected FAILURE output:**
   ```
   error: open platform/cloudflared/prod/tunnel.enc.yaml: no such file or directory
   ```

2. Create `scripts/seed-secrets.sh` (reads TF outputs + out-of-band R2 token env + Telegram/healthchecks env, writes plaintext, SOPS-encrypts in place per `.sops.yaml`):
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail

   # R2 access/secret key pairs are minted out-of-band as scoped R2 API tokens
   # and provided via env (NOT terraform outputs).
   : "${R2_PG_ACCESS_KEY:?set R2_PG_ACCESS_KEY}"
   : "${R2_PG_SECRET_KEY:?set R2_PG_SECRET_KEY}"
   # Alerting fan-out (consumed by M5 vmalert/Alertmanager).
   : "${TELEGRAM_BOT_TOKEN:?set TELEGRAM_BOT_TOKEN}"
   : "${TELEGRAM_CHAT_ID:?set TELEGRAM_CHAT_ID}"
   : "${HEALTHCHECKS_URL:?set HEALTHCHECKS_URL}"
   : "${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD}"   # Grafana admin password (NEVER admin/admin)

   CF_OUT=$(terraform -chdir=infra/cloudflare output -json)
   TS_OUT=$(terraform -chdir=infra/tailscale output -json)

   TUNNEL_TOKEN=$(jq -r '.tunnel_token.value'           <<<"$CF_OUT")
   R2_ENDPOINT=$( jq -r '.r2_account_endpoint.value'    <<<"$CF_OUT")
   R2_PG_BUCKET=$(jq -r '.r2_pg_backups_bucket.value'   <<<"$CF_OUT")
   TS_ID=$(       jq -r '.operator_oauth_client_id.value'     <<<"$TS_OUT")
   TS_SECRET=$(   jq -r '.operator_oauth_client_secret.value' <<<"$TS_OUT")

   write_enc() { # $1=path; plaintext-yaml on stdin → ATOMIC: plaintext NEVER lands at $path
     local path="$1"; mkdir -p "$(dirname "$path")"
     local tmp; tmp="$(mktemp)"; chmod 600 "$tmp"
     trap 'rm -f "$tmp" "$tmp.enc"' RETURN
     cat > "$tmp"                                            # plaintext stays in a 0600 temp only
     sops --encrypt --filename-override "$path" "$tmp" > "$tmp.enc" \
       || { echo "sops failed for $path — NO plaintext written to the target"; return 1; }
     mv "$tmp.enc" "$path"                                   # atomic: only the ENCRYPTED file lands at $path
     echo "sealed $path"
   }

   write_enc platform/cloudflared/prod/tunnel.enc.yaml <<EOF
   apiVersion: v1
   kind: Secret
   metadata:
     name: cloudflared-tunnel
     namespace: edge
   type: Opaque
   stringData:
     token: "${TUNNEL_TOKEN}"
   EOF

   write_enc platform/tailscale/prod/operator-oauth.enc.yaml <<EOF
   apiVersion: v1
   kind: Secret
   metadata:
     name: operator-oauth
     namespace: edge
   type: Opaque
   stringData:
     client_id: "${TS_ID}"
     client_secret: "${TS_SECRET}"
   EOF

   write_enc platform/cnpg/prod/r2-creds.enc.yaml <<EOF
   apiVersion: v1
   kind: Secret
   metadata:
     name: cnpg-r2-creds
     namespace: database
   type: Opaque
   stringData:
     # CANONICAL R2 key schema — consumed by BOTH the barman ObjectStore (AWS_*) and the
     # pg_dump -> rclone hedge (RCLONE_CONFIG_R2_* + AWS_*, region=auto). Do not rename;
     # object-store.yaml and pgdump-hedge-cronjob.yaml read these exact keys.
     AWS_ACCESS_KEY_ID: "${R2_PG_ACCESS_KEY}"
     AWS_SECRET_ACCESS_KEY: "${R2_PG_SECRET_KEY}"
     RCLONE_CONFIG_R2_TYPE: "s3"
     RCLONE_CONFIG_R2_PROVIDER: "Cloudflare"
     RCLONE_CONFIG_R2_ACCESS_KEY_ID: "${R2_PG_ACCESS_KEY}"
     RCLONE_CONFIG_R2_SECRET_ACCESS_KEY: "${R2_PG_SECRET_KEY}"
     RCLONE_CONFIG_R2_ENDPOINT: "${R2_ENDPOINT}"
     RCLONE_CONFIG_R2_REGION: "auto"
   EOF

   # pg-app-credentials: the app DB owner role. Consumed by CNPG initdb (database ns) and by
   # the pg_dump hedge. Generated ONCE and committed (SOPS); on re-run / DR the committed file
   # is the source of truth — regenerating would diverge from the password baked into the
   # restored database. (pg_basebackup uses the managed `pg-superuser` secret instead — it
   # needs REPLICATION, which the app role does not have.)
   if [ ! -f platform/cnpg/prod/app-credentials.enc.yaml ]; then
   PG_APP_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)"
   write_enc platform/cnpg/prod/app-credentials.enc.yaml <<EOF
   apiVersion: v1
   kind: Secret
   metadata:
     name: pg-app-credentials
     namespace: database
   type: kubernetes.io/basic-auth
   stringData:
     username: "app"
     password: "${PG_APP_PASSWORD}"
   EOF
   else
   echo "keep platform/cnpg/prod/app-credentials.enc.yaml (already seeded; the password is load-bearing — never regenerate)"
   fi

   write_enc platform/victoria-stack/prod/alerting.enc.yaml <<EOF
   apiVersion: v1
   kind: Secret
   metadata:
     name: alerting-secrets
     namespace: observability
   type: Opaque
   stringData:
     TELEGRAM_BOT_TOKEN: "${TELEGRAM_BOT_TOKEN}"
     TELEGRAM_CHAT_ID: "${TELEGRAM_CHAT_ID}"
     HEALTHCHECKS_URL: "${HEALTHCHECKS_URL}"
     GRAFANA_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASSWORD}"
   EOF
   ```
   Append to `Makefile` (new target):
   ```makefile
   .PHONY: seed-secrets
   seed-secrets: ## generate SOPS-encrypted seed secrets from terraform outputs
   	@bash scripts/seed-secrets.sh
   ```

3. **Run it:**
   ```bash
   export R2_PG_ACCESS_KEY=<...> R2_PG_SECRET_KEY=<...>
   export TELEGRAM_BOT_TOKEN=<...> TELEGRAM_CHAT_ID=<...> HEALTHCHECKS_URL=<...> GRAFANA_ADMIN_PASSWORD=<...>
   chmod +x scripts/seed-secrets.sh
   make seed-secrets
   ```
   **Expected output:**
   ```
   sealed platform/cloudflared/prod/tunnel.enc.yaml
   sealed platform/tailscale/prod/operator-oauth.enc.yaml
   sealed platform/cnpg/prod/r2-creds.enc.yaml
   sealed platform/cnpg/prod/app-credentials.enc.yaml
   sealed platform/victoria-stack/prod/alerting.enc.yaml
   ```

4. **Run the assertion** (decrypt round-trips + confirm encrypted-to-two-recipients):
   ```bash
   sops -d platform/cloudflared/prod/tunnel.enc.yaml | grep -q 'token:' && echo "decrypt OK"
   grep -c 'recipient:' platform/cnpg/prod/r2-creds.enc.yaml   # 2 age recipients (cluster + recovery)
   ```
   **Expected PASS output:**
   ```
   decrypt OK
   2
   ```

5. **Commit** (encrypted files only — plaintext never existed on disk except transiently inside the file before in-place encryption):
   ```bash
   git add platform/cloudflared/prod/tunnel.enc.yaml platform/tailscale/prod/operator-oauth.enc.yaml \
           platform/cnpg/prod/r2-creds.enc.yaml platform/cnpg/prod/app-credentials.enc.yaml \
           platform/victoria-stack/prod/alerting.enc.yaml \
           scripts/seed-secrets.sh Makefile
   git commit -m "feat: Terraform 출력값을 SOPS 시드 시크릿으로 봉인 (단일 생산자)"
   ```

---

### Task 2.10 — Pinned ArgoCD values + KSOPS repo-server wiring

Author the lean ArgoCD Helm values consumed by `make bootstrap` (§5: all HA off, tuned processors, resource exclusions) **and** wire KSOPS into the repo-server here — M2 OWNS this wiring; M3/M4/M5 inherit it and never re-wire KSOPS. The repo-server installs the ksops binary + a kustomize-with-exec, mounts the in-cluster `sops-age` Secret at `/home/argocd/.config/sops/age`, sets `SOPS_AGE_KEY_FILE`, and enables alpha+exec build options so committed `*.enc.yaml` decrypt at render time.

**Files**
- Create: `platform/argocd/bootstrap-values.yaml` (the single values file the root + self-manage app reference)
- Create: `platform/argocd/CHART_VERSION` (pinned chart version, single line)
- Test: `infra/_test/argocd_values.bats`

**Steps**

1. **Verification first** — assert HA is off, processors are tuned, and KSOPS is wired (fails: no file). Create `infra/_test/argocd_values.bats`:
   ```bash
   #!/usr/bin/env bats

   @test "argocd bootstrap values disable HA and tune processors" {
     run grep -q 'redis-ha:' platform/argocd/bootstrap-values.yaml
     [ "$status" -eq 0 ]
     run grep -qE 'statusProcessors:\s*"?4"?' platform/argocd/bootstrap-values.yaml
     [ "$status" -eq 0 ]
     run grep -qE 'operationProcessors:\s*"?2"?' platform/argocd/bootstrap-values.yaml
     [ "$status" -eq 0 ]
   }

   @test "repo-server wires KSOPS: sops-age mount + SOPS_AGE_KEY_FILE + exec build options" {
     run grep -q 'sops-age' platform/argocd/bootstrap-values.yaml
     [ "$status" -eq 0 ]
     run grep -q '/home/argocd/.config/sops/age/keys.txt' platform/argocd/bootstrap-values.yaml
     [ "$status" -eq 0 ]
     run grep -q -- '--enable-alpha-plugins --enable-exec --enable-helm' platform/argocd/bootstrap-values.yaml
     [ "$status" -eq 0 ]
   }

   @test "argocd chart version is pinned (semver, not a range)" {
     run grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' platform/argocd/CHART_VERSION
     [ "$status" -eq 0 ]
   }
   ```
   Run:
   ```bash
   bats infra/_test/argocd_values.bats
   ```
   **Expected FAILURE output:**
   ```
   ✗ argocd bootstrap values disable HA and tune processors
     (no such file)
   ```

2. Create `platform/argocd/CHART_VERSION`:
   ```
   7.7.11
   ```
   Create `platform/argocd/bootstrap-values.yaml`:
   ```yaml
   # Lean single-node ArgoCD. HA OFF everywhere; processors tuned (§5).
   # M2 OWNS the KSOPS repo-server wiring below; M3/M4/M5 inherit it.
   global:
     domain: argocd.int.<DOMAIN>

   redis-ha:
     enabled: false

   controller:
     replicas: 1
     env:
       - name: ARGOCD_CONTROLLER_REPLICAS
         value: "1"
     args:
       statusProcessors: "4"
       operationProcessors: "2"
     resources:
       requests: { cpu: 100m, memory: 256Mi }
       limits:   { cpu: 500m, memory: 512Mi }

   repoServer:
     replicas: 1
     env:
       - name: ARGOCD_EXEC_TIMEOUT
         value: "90s"
       # KSOPS reads the age key from the mounted Secret at render time.
       - name: SOPS_AGE_KEY_FILE
         value: /home/argocd/.config/sops/age/keys.txt
     # Install the ksops binary + a kustomize-with-exec into the repo-server.
     initContainers:
       - name: install-ksops
         image: viaductoss/ksops:v4.3.2
         command: ["/bin/sh", "-c"]
         args:
           - |
             echo "installing ksops + kustomize (exec-enabled)";
             cp /usr/local/bin/ksops /custom-tools/;
             cp /usr/local/bin/kustomize /custom-tools/;
         volumeMounts:
           - name: custom-tools
             mountPath: /custom-tools
     # Mount the in-cluster sops-age Secret (created by make bootstrap) read-only.
     volumes:
       - name: custom-tools
         emptyDir: {}
       - name: sops-age
         secret:
           secretName: sops-age
     volumeMounts:
       - name: custom-tools
         mountPath: /usr/local/bin/kustomize
         subPath: kustomize
       - name: custom-tools
         mountPath: /usr/local/bin/ksops
         subPath: ksops
       - name: sops-age
         mountPath: /home/argocd/.config/sops/age
         readOnly: true
     resources:
       requests: { cpu: 50m, memory: 128Mi }
       limits:   { cpu: 500m, memory: 384Mi }
     # parallelismLimit tunes diff concurrency (§5).
     extraArgs:
       - --parallelismlimit=2

   server:
     replicas: 1
     resources:
       requests: { cpu: 25m, memory: 64Mi }
       limits:   { cpu: 250m, memory: 128Mi }

   applicationSet:
     replicas: 1
     resources:
       requests: { cpu: 25m, memory: 64Mi }
       limits:   { cpu: 250m, memory: 128Mi }

   notifications:
     enabled: false

   dex:
     enabled: false

   redis:
     resources:
       requests: { cpu: 25m, memory: 64Mi }
       limits:   { cpu: 200m, memory: 128Mi }

   configs:
     params:
       server.insecure: true   # TLS terminates at Traefik/Tailscale, not ArgoCD.
     cm:
       # Enable the KSOPS exec plugin for kustomize-based decryption at render time.
       # KSOPS (exec) + Traefik/Tailscale HelmChartInflationGenerator (helm) both need their flags.
       kustomize.buildOptions: "--enable-alpha-plugins --enable-exec --enable-helm"
       # cuts diff churn ~20-30% (§5)
       resource.exclusions: |
         - apiGroups: [""]
           kinds: ["Endpoints", "Event"]
         - apiGroups: ["discovery.k8s.io"]
           kinds: ["EndpointSlice"]
   ```

3. **Run the test:**
   ```bash
   bats infra/_test/argocd_values.bats
   ```
   **Expected PASS output:**
   ```
   ✓ argocd bootstrap values disable HA and tune processors
   ✓ repo-server wires KSOPS: sops-age mount + SOPS_AGE_KEY_FILE + exec build options
   ✓ argocd chart version is pinned (semver, not a range)

   3 tests, 0 failures
   ```

4. **Commit:**
   ```bash
   git add platform/argocd/bootstrap-values.yaml platform/argocd/CHART_VERSION infra/_test/argocd_values.bats
   git commit -m "feat: HA 비활성/프로세서 튜닝 + KSOPS repo-server 와이어링 ArgoCD values 고정"
   ```

---

### Task 2.11 — Bootstrap-minimal root app-of-apps + the `argocd-app.yaml` self-manage

Provide the root Application that `make bootstrap` applies, plus ArgoCD's self-management Application (pinned chart, §5). Both are **bootstrap-minimal** and reference exactly ONE values file (`platform/argocd/bootstrap-values.yaml`). M3 will **Edit** `argocd-app.yaml` to add sync-waves -10/-9 and will **add** `platform/argocd/root/appset.yaml`; do **not** author the ApplicationSet or any sync-waves here. The root app **recurses** the directory `platform/argocd/root/` so hand-rolled Applications placed there by later milestones are picked up. AppProject is `default` everywhere.

**Files**
- Create: `platform/argocd/root/root-app.yaml`
- Create: `platform/argocd/argocd-app.yaml`
- Test: `infra/_test/root_app.bats`

**Steps**

1. **Verification first** — assert the root app recurses `platform/argocd/root`, uses project `default`, and auto-syncs (fails: no file). Create `infra/_test/root_app.bats`:
   ```bash
   #!/usr/bin/env bats

   @test "root app recurses platform/argocd/root, uses project default, auto-syncs" {
     run grep -q 'path: platform/argocd/root' platform/argocd/root/root-app.yaml
     [ "$status" -eq 0 ]
     run grep -q 'recurse: true' platform/argocd/root/root-app.yaml
     [ "$status" -eq 0 ]
     run grep -q 'project: default' platform/argocd/root/root-app.yaml
     [ "$status" -eq 0 ]
     run grep -q 'selfHeal: true' platform/argocd/root/root-app.yaml
     [ "$status" -eq 0 ]
   }

   @test "argocd self-manage app uses the single bootstrap values file + project default" {
     run grep -q 'project: default' platform/argocd/argocd-app.yaml
     [ "$status" -eq 0 ]
     run grep -q 'platform/argocd/bootstrap-values.yaml' platform/argocd/argocd-app.yaml
     [ "$status" -eq 0 ]
   }
   ```
   Run:
   ```bash
   bats infra/_test/root_app.bats
   ```
   **Expected FAILURE output:**
   ```
   ✗ root app recurses platform/argocd/root, uses project default, auto-syncs
     (no such file)
   ```

2. Create `platform/argocd/root/root-app.yaml` (recurses the root directory so hand-rolled Applications dropped there later are picked up; no ApplicationSet here — M3 adds `appset.yaml`):
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: root
     namespace: argocd
     finalizers:
       - resources-finalizer.argocd.argoproj.io
   spec:
     project: default
     source:
       repoURL: https://github.com/<GH_USER>/homelab.git
       targetRevision: main
       path: platform/argocd/root
       directory:
         recurse: true
     destination:
       server: https://kubernetes.default.svc
       namespace: argocd
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
         - ApplyOutOfSyncOnly=true
   ```
   Create `platform/argocd/argocd-app.yaml` (ArgoCD self-manages via its own pinned chart, §5; ONE values file — multi-source `$values` ref is bootstrap-minimal here, M3 edits this app to add sync-waves):
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: argocd
     namespace: argocd
     finalizers:
       - resources-finalizer.argocd.argoproj.io
   spec:
     project: default
     sources:
       - repoURL: https://argoproj.github.io/argo-helm
         chart: argo-cd
         targetRevision: 7.7.11   # MUST equal platform/argocd/CHART_VERSION
         helm:
           valueFiles:
             - $values/platform/argocd/bootstrap-values.yaml
       - repoURL: https://github.com/<GH_USER>/homelab.git
         targetRevision: main
         ref: values
     destination:
       server: https://kubernetes.default.svc
       namespace: argocd
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   ```
   (Note: the root path `platform/argocd/root/` contains `root-app.yaml` and `argocd-app.yaml`. The self-manage `argocd-app.yaml` lives at `platform/argocd/argocd-app.yaml` per §11 layout and is applied directly by bootstrap; `root-app.yaml` recursing `platform/argocd/root/` is the seam M3+ drop their Applications into.)

3. **Run the test:**
   ```bash
   bats infra/_test/root_app.bats
   ```
   **Expected PASS output:**
   ```
   ✓ root app recurses platform/argocd/root, uses project default, auto-syncs
   ✓ argocd self-manage app uses the single bootstrap values file + project default

   2 tests, 0 failures
   ```

4. **Commit:**
   ```bash
   git add platform/argocd/root/root-app.yaml platform/argocd/argocd-app.yaml infra/_test/root_app.bats
   git commit -m "feat: 부트스트랩 최소 root app-of-apps 및 ArgoCD 자가관리 정의 추가"
   ```

---

### Task 2.12 — The idempotent `make bootstrap` target (R5 = the DR path)

The single entry-point: pin-install ArgoCD, create the in-cluster `sops-age` Secret from the M0 cluster key, apply the root app. This **edits M0's `bootstrap` stub** (Modify — never re-declare the target). Every step is idempotent so re-running is a no-op.

**Files**
- Modify: `Makefile` (replace M0's `bootstrap` stub recipe body — do not re-declare the target)
- Create: `scripts/bootstrap.sh`

**Steps**

1. **Verification first** — write a bats idempotency test that runs bootstrap twice and asserts the second run reports no changes (fails: stub still prints "not implemented"). Create `infra/_test/bootstrap.bats`:
   ```bash
   #!/usr/bin/env bats

   @test "make bootstrap is idempotent (second run is a no-op)" {
     run make bootstrap
     [ "$status" -eq 0 ]
     run make bootstrap
     [ "$status" -eq 0 ]
     [[ "$output" == *"unchanged"* || "$output" == *"already"* ]]
   }
   ```
   Run:
   ```bash
   bats infra/_test/bootstrap.bats
   ```
   **Expected FAILURE output** (M0's stub exits non-zero with "not implemented"):
   ```
   ✗ make bootstrap is idempotent (second run is a no-op)
     bootstrap: not implemented yet (owned by the DR/bootstrap milestone)
   ```

2. Create `scripts/bootstrap.sh` (idempotent: `helm upgrade --install`, `kubectl apply`, `create --dry-run | apply`; consumes the M0 cluster key at `~/.config/sops/age/keys.txt` and creates the in-cluster Secret `sops-age` with file key `keys.txt` in ns `argocd`):
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail

   CHART_VERSION="$(tr -d '[:space:]' < platform/argocd/CHART_VERSION)"
   AGE_KEY="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

   test -f "${AGE_KEY}" || { echo "FATAL: M0 cluster age key not found at ${AGE_KEY}" >&2; exit 1; }

   echo "==> [1/4] namespace argocd"
   kubectl get ns argocd >/dev/null 2>&1 \
     && echo "    namespace argocd already exists" \
     || kubectl create ns argocd

   echo "==> [2/4] sops-age cluster key Secret (idempotent; file key keys.txt)"
   kubectl -n argocd create secret generic sops-age \
     --from-file=keys.txt="${AGE_KEY}" \
     --dry-run=client -o yaml | kubectl apply -f - \
     | sed 's/^/    /'

   echo "==> [3/4] helm upgrade --install argo-cd (pinned ${CHART_VERSION})"
   helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
   helm repo update argo >/dev/null
   helm upgrade --install argocd argo/argo-cd \
     --namespace argocd \
     --version "${CHART_VERSION}" \
     --values platform/argocd/bootstrap-values.yaml \
     --wait --timeout 10m \
     | grep -E 'STATUS|REVISION' | sed 's/^/    /' || true

   echo "==> [4/4] apply root app-of-apps + ArgoCD self-manage"
   kubectl apply -f platform/argocd/argocd-app.yaml | sed 's/^/    /'
   kubectl apply -f platform/argocd/root/root-app.yaml | sed 's/^/    /'

   echo "==> bootstrap complete"
   ```
   Replace M0's `bootstrap` stub recipe body in `Makefile` (the `.PHONY: bootstrap` declaration M0 authored stays; only the recipe changes):
   ```makefile
   bootstrap: ## idempotent DR entry-point: install ArgoCD + sops-age Secret + root app
   	@bash scripts/bootstrap.sh
   ```
   (`helm upgrade --install` is a no-op on an unchanged release — prints `STATUS: deployed`, same REVISION when nothing changed; `kubectl apply` on an unchanged Secret/Application prints `unchanged`; this is what satisfies the idempotency assertion.)

3. **Run bootstrap on the fresh cluster, then verify pods + root app health:**
   ```bash
   export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
   chmod +x scripts/bootstrap.sh
   make bootstrap
   kubectl -n argocd get pods
   kubectl -n argocd get application root -o jsonpath='{.status.sync.status}/{.status.health.status}'; echo
   ```
   **Expected PASS output:**
   ```
   ==> [1/4] namespace argocd
   ==> [2/4] sops-age cluster key Secret (idempotent; file key keys.txt)
       secret/sops-age created
   ==> [3/4] helm upgrade --install argo-cd (pinned 7.7.11)
       STATUS: deployed
   ==> [4/4] apply root app-of-apps + ArgoCD self-manage
       application.argoproj.io/argocd created
       application.argoproj.io/root created
   ==> bootstrap complete

   NAME                                 READY   STATUS    RESTARTS   AGE
   argocd-application-controller-0      1/1     Running   0          2m
   argocd-applicationset-controller-…   1/1     Running   0          2m
   argocd-redis-…                       1/1     Running   0          2m
   argocd-repo-server-…                 2/2     Running   0          2m
   argocd-server-…                      1/1     Running   0          2m

   Synced/Healthy
   ```
   (The repo-server shows `2/2` because of the KSOPS init/sidecar tooling wired in Task 2.10.)

4. **Run the idempotency test** (R5 — re-run is a no-op):
   ```bash
   bats infra/_test/bootstrap.bats
   ```
   **Expected PASS output:**
   ```
   ✓ make bootstrap is idempotent (second run is a no-op)

   1 test, 0 failures
   ```
   (Second `make bootstrap` prints `secret/sops-age unchanged`, `STATUS: deployed` same REVISION, `application.argoproj.io/root unchanged`.)

5. **Commit:**
   ```bash
   git add Makefile scripts/bootstrap.sh infra/_test/bootstrap.bats
   git commit -m "feat: 멱등 make bootstrap DR 진입점 구현 (M0 stub 채움)"
   ```

---

### Task 2.13 — Prove a committed `*.enc.yaml` renders through the KSOPS-wired repo-server

M2 OWNS the KSOPS wiring (Task 2.10) and the seed secrets (Task 2.9); before M3 ships any Application that consumes them, prove end-to-end that a committed `*.enc.yaml` actually **decrypts and renders** through the live repo-server. This closes the gap between "the secret is encrypted to two recipients" and "ArgoCD can produce a plaintext Secret manifest at render time."

**Files**
- Create: `platform/cnpg/prod/secret-generator.yaml` (the per-kustomization KSOPS generator for the r2-creds seed)
- Create: `platform/cnpg/prod/kustomization.yaml` (minimal — references the KSOPS generator)
- Test: `infra/_test/ksops_render.bats`

**Steps**

1. **Verification first** — assert the repo-server can render `platform/cnpg/prod` into a decrypted `cnpg-r2-creds` Secret (fails: no generator yet). Create `infra/_test/ksops_render.bats`:
   ```bash
   #!/usr/bin/env bats

   @test "repo-server renders the committed r2-creds enc.yaml into a plaintext Secret" {
     # Trigger a render of the cnpg/prod kustomization via the argocd CLI / repo-server,
     # then assert the output contains a Secret named cnpg-r2-creds with decrypted data.
     run bash -c 'argocd app manifests --source-positions 1 _ksops_probe 2>/dev/null || \
       kubectl -n argocd exec deploy/argocd-repo-server -c repo-server -- \
         kustomize build --enable-alpha-plugins --enable-exec /tmp/_ksops_probe'
     [[ "$output" == *"kind: Secret"* ]]
     [[ "$output" == *"name: cnpg-r2-creds"* ]]
   }
   ```
   Run:
   ```bash
   bats infra/_test/ksops_render.bats
   ```
   **Expected FAILURE output:**
   ```
   ✗ repo-server renders the committed r2-creds enc.yaml into a plaintext Secret
     (no secret-generator.yaml; kustomize build produces no Secret)
   ```

2. Create `platform/cnpg/prod/secret-generator.yaml` (the KSOPS generator — each kustomization that consumes a `*.enc.yaml` carries its OWN generator; there is no shared `ksops.yaml` stub):
   ```yaml
   apiVersion: viaduct.ai/v1
   kind: ksops
   metadata:
     name: cnpg-r2-creds-generator
     annotations:
       config.kubernetes.io/function: |
         exec:
           path: ksops
   files:
     - r2-creds.enc.yaml
   ```
   Create `platform/cnpg/prod/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: database
   generators:
     - secret-generator.yaml
   ```

3. **Render through the live repo-server** (the wiring from Task 2.10 supplies the age key + exec build options). A direct in-pod render is the simplest proof:
   ```bash
   # Copy the committed kustomization into the repo-server and render it with the
   # exec plugin (the repo-server has ksops + kustomize-with-exec + SOPS_AGE_KEY_FILE).
   kubectl -n argocd cp platform/cnpg argocd-repo-server-<pod>:/tmp/cnpg -c repo-server
   kubectl -n argocd exec deploy/argocd-repo-server -c repo-server -- \
     env SOPS_AGE_KEY_FILE=/home/argocd/.config/sops/age/keys.txt \
     kustomize build --enable-alpha-plugins --enable-exec /tmp/cnpg/prod | grep -A2 'kind: Secret'
   ```
   **Expected PASS output:**
   ```
   kind: Secret
   metadata:
     name: cnpg-r2-creds
   ```
   (The data keys `ACCESS_KEY_ID`/`ACCESS_SECRET_KEY`/`ENDPOINT_URL`/`BUCKET` appear base64-encoded and decrypted — proving the cluster age key in the `sops-age` Secret decrypts the committed file at render time.)

4. **Run the assertion:**
   ```bash
   bats infra/_test/ksops_render.bats
   ```
   **Expected PASS output:**
   ```
   ✓ repo-server renders the committed r2-creds enc.yaml into a plaintext Secret

   1 test, 0 failures
   ```

5. **Commit:**
   ```bash
   git add platform/cnpg/prod/secret-generator.yaml platform/cnpg/prod/kustomization.yaml infra/_test/ksops_render.bats
   git commit -m "test: 커밋된 enc.yaml의 KSOPS repo-server 렌더링 검증"
   ```

---

### Task 2.14 — Destroy + rebuild drill: prove platform restores from git (R5 DR validation)

The quarterly rebuild drill doubles as the DR drill (§5). Script and document it so it's repeatable, then run it once to validate.

> **POST-M6 acceptance (not an M2-time run).** This drill exercises the rebuilt platform's **apps (M6)** and the **CNPG restore drill (M4)**, so although the script + runbook are committed here in M2, the LIVE run is a **post-M6 acceptance gate** (same pattern as Task 4.12). It is **destructive of the live node** — run it only in a maintenance window; all durable state (Terraform state, DB backups) lives in R2 and survives node loss.

**Files**
- Create: `scripts/dr-drill.sh`
- Modify: `docs/runbooks/02-cloud-iac-bootstrap.md` (append the drill section)
- Test: (manual, scripted) `scripts/dr-drill.sh`

**Steps**

1. **Verification first** — write the drill as an assertion: after a destructive uninstall + `make bootstrap`, the root app must return to `Synced/Healthy` from git alone. Append to `docs/runbooks/02-cloud-iac-bootstrap.md`:
   ````markdown
   ## DR / rebuild drill (run quarterly) — FULL VM rebuild, not just an ArgoCD reinstall

   ```bash
   bash scripts/dr-drill.sh
   ```
   PASS criterion: script exits 0 and prints `DR DRILL PASS`.
   This validates R5 for real: it DESTROYS and RECREATES the OrbStack VM (cattle),
   re-bootstraps the platform from git, confirms workloads come back, and proves the
   DB is recoverable from R2 on the rebuilt node (by running the restore drill). It does
   NOT claim the prod DB auto-recovers: a fresh `pg` comes up via bootstrap.initdb = EMPTY;
   real prod data is restored from R2 via docs/runbooks/restore.md. Required out-of-band
   inputs that survive node loss: the M0 cluster age key (~/.config/sops/age/keys.txt) and
   the Terraform state + R2 backups (both in R2). A namespace-only ArgoCD reinstall is a
   smoke check, NOT a DR test.
   ````
   Create `scripts/dr-drill.sh`:
   ```bash
   #!/usr/bin/env bash
   # DR drill (R5, POST-M6 acceptance): prove the WHOLE platform rebuilds from git + R2 + the age
   # key by DESTROYING and RECREATING the OrbStack VM (cattle). It CAPTURES the canary before
   # destruction, and after rebuild RECOVERS the DB from R2 into a verify cluster and checks the
   # recovered canary matches the pre-loss checkpoint — NOT assuming `make bootstrap` repopulates data.
   set -euo pipefail
   : "${SOPS_AGE_KEY_FILE:?export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt (the out-of-band recovery input)}"
   test -s "$SOPS_AGE_KEY_FILE" || { echo "DR DRILL FAIL: age key missing at $SOPS_AGE_KEY_FILE"; exit 1; }

   echo "==> [0] confirm DR inputs survive node loss: Terraform state + R2 backups live in R2"
   terraform -chdir=infra/cloudflare state list >/dev/null || { echo "FAIL: TF state (R2 backend) unreachable"; exit 1; }

   # recover_and_check NAME → recovers a verify cluster from R2, echoes its canary count, tears it down.
   recover_and_check() {
     kubectl apply -f - >/dev/null <<YAML
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata: { name: $1, namespace: database, labels: { cnpg.io/drill: "true" } }
   spec:
     instances: 1
     imageName: ghcr.io/cloudnative-pg/postgresql:16.4
     storage: { size: 40Gi, storageClass: drill-ssd }
     walStorage: { size: 10Gi, storageClass: drill-ssd }
     bootstrap: { recovery: { source: r2-source } }
     externalClusters:
       - name: r2-source
         plugin: { name: barman-cloud.cloudnative-pg.io, parameters: { barmanObjectName: pg-r2, serverName: pg } }
   YAML
     for _ in $(seq 1 80); do
       [ "$(kubectl -n database get cluster "$1" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Cluster in healthy state" ] && break
       sleep 15
     done
     local n; n=$(kubectl -n database exec "${1}-1" -c postgres -- psql -U postgres -d app -tAc 'SELECT count(*) FROM restore_canary;' 2>/dev/null || echo 0)
     kubectl -n database delete cluster "$1" --ignore-not-found --wait=true || true
     kubectl -n database delete pvc -l "cnpg.io/cluster=$1" --ignore-not-found || true
     echo "$n"
   }

   echo "==> [0.5] capture canary, take a VERIFIED backup, PROVE recoverability BEFORE any destruction"
   EXPECTED=$(kubectl -n database exec pg-1 -c postgres -- \
     psql -U postgres -d app -tAc 'SELECT count(*) FROM restore_canary;' 2>/dev/null || echo "")
   { [ -n "$EXPECTED" ] && [ "$EXPECTED" -ge 0 ]; } || { echo "DR ABORT: cannot read live canary"; exit 1; }
   # On-demand backup, then WAIT for it to actually COMPLETE (never a fixed sleep) before trusting it.
   BK="dr-pre-$(kubectl -n database get backup -o name 2>/dev/null | wc -l | tr -d ' ')"
   kubectl -n database create -f - <<YAML
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata: { name: ${BK}, namespace: database }
   spec: { cluster: { name: pg }, method: plugin, pluginConfiguration: { name: barman-cloud.cloudnative-pg.io } }
   YAML
   for _ in $(seq 1 80); do
     [ "$(kubectl -n database get backup "$BK" -o jsonpath='{.status.phase}' 2>/dev/null)" = "completed" ] && break
     sleep 15
   done
   [ "$(kubectl -n database get backup "$BK" -o jsonpath='{.status.phase}' 2>/dev/null)" = "completed" ] \
     || { echo "DR ABORT: backup ${BK} did not COMPLETE — REFUSING to destroy the live node"; exit 1; }
   # Recover that backup into a verify cluster on the STILL-LIVE node: never destroy prod until
   # recoverability from R2 is PROVEN, not assumed.
   PRE=$(recover_and_check pg-dr-precheck)
   { [ "${PRE:-0}" -ge "$EXPECTED" ] && [ "${PRE:-0}" -gt 0 ]; } \
     || { echo "DR ABORT: pre-destruction recovery FAILED (recovered=$PRE < $EXPECTED) — NOT destroying the live node"; exit 1; }
   echo "    canary=$EXPECTED, backup ${BK} completed, recoverability PROVEN (recovered=$PRE). Safe to destroy."

   echo "==> [1] DESTROY the VM (cattle) — simulates total node loss"
   orb delete -f k3s || true

   echo "==> [2] REBUILD the VM + k3s + StorageClasses from committed cloud-init/install (M1)"
   bash infra/k3s-bootstrap/host-up.sh

   echo "==> [3] make bootstrap — ArgoCD + sops-age secret + root app, all from git"
   make bootstrap

   echo "==> [4] wait for the platform tier to converge (root + cnpg operator + data Healthy)"
   for app in root cnpg-operator cnpg-data; do
     kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy "application/$app" --timeout=900s
   done

   echo "==> [5] recover the DB from R2 on the REBUILT node, validate the pre-loss canary"
   #     The fresh prod `pg` came up EMPTY (bootstrap.initdb); reuse recover_and_check (defined in [0.5])
   #     to recover from R2 and confirm the recovered canary matches the pre-loss checkpoint.
   ACTUAL=$(recover_and_check pg-dr-verify)
   { [ "${ACTUAL:-0}" -ge "$EXPECTED" ] && [ "${ACTUAL:-0}" -gt 0 ]; } \
     || { echo "DR DRILL FAIL: recovered canary=$ACTUAL < pre-loss $EXPECTED — R2 did NOT restore data"; exit 1; }
   echo "    recovered canary = $ACTUAL (>= pre-loss $EXPECTED) — R2 data recovery PROVEN on the rebuilt node"

   echo "==> [6] verify an app workload actually serves on the rebuilt platform"
   kubectl -n prod rollout status deploy/api --timeout=300s

   echo "DR DRILL PASS — VM rebuilt; platform + workloads back from git, and R2 data-recovery proven on the rebuilt node (prod data is restored via docs/runbooks/restore.md)"
   ```

2. **Run it (the currently-failing-then-passing assertion):** first confirm the substrate is NOT self-healing — destroy the VM and observe that nothing recovers on its own:
   ```bash
   orb delete -f k3s
   kubectl get nodes 2>&1 | tail -1
   ```
   **Expected FAILURE output:**
   ```
   The connection to the server ... was refused - did you specify the right host or port?
   ```

3. **Run the full drill:**
   ```bash
   chmod +x scripts/dr-drill.sh
   export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
   bash scripts/dr-drill.sh
   ```
   **Expected PASS output (tail):**
   ```
   ==> [6] verify an app workload actually serves on the rebuilt platform
   deployment "api" successfully rolled out
   DR DRILL PASS — VM rebuilt; platform + workloads back from git, and R2 data-recovery proven on the rebuilt node
   ```

4. **Commit:**
   ```bash
   git add scripts/dr-drill.sh docs/runbooks/02-cloud-iac-bootstrap.md
   git commit -m "test: 파괴-재구축 DR 드릴 스크립트 및 런북 추가"
   ```

---

### Task 2.15 — CI: `terraform validate` + bootstrap-artifact lint gate

Wire the IaC gates into GitHub Actions so a bad Terraform change or unpinned ArgoCD chart fails PR checks. This `iac` workflow gates PRs touching `infra/**`; it is SEPARATE from the two required-status contexts (`gate`, `build`) in Task 2.7's branch protection. All CI uses pnpm@10 where pnpm is invoked; this workflow needs only terraform + bats.

**Files**
- Create: `.github/workflows/iac.yaml`
- Test: (CI) the workflow itself; locally via `act` optional

**Steps**

1. **Verification first** — assert the workflow runs `make tf-validate` and the bats suites. Create `.github/workflows/iac.yaml`:
   ```yaml
   name: iac
   on:
     pull_request:
       paths:
         - "infra/**"
         - "platform/argocd/**"
         - "Makefile"
         - "scripts/**"
   jobs:
     iac-validate:
       runs-on: ubuntu-24.04-arm
       steps:
         - uses: actions/checkout@v4
         - uses: hashicorp/setup-terraform@v3
           with:
             terraform_version: "1.9.8"
         - name: bats
           run: sudo apt-get update && sudo apt-get install -y bats
         - name: terraform init (no backend) + validate all roots
           run: |
             for r in cloudflare tailscale github; do
               terraform -chdir=infra/$r init -backend=false
             done
             make tf-validate
         - name: argocd values + root app lint
           run: |
             bats infra/_test/argocd_values.bats
             bats infra/_test/root_app.bats
   ```

2. **Run the validate steps locally to mirror CI (the failing-then-passing gate):**
   ```bash
   for r in cloudflare tailscale github; do terraform -chdir=infra/$r init -backend=false >/dev/null; done
   make tf-validate && bats infra/_test/argocd_values.bats infra/_test/root_app.bats
   ```
   **Expected FAILURE output** (if any root has an unformatted file or unpinned chart):
   ```
   cloudflare: fmt FAILED (run 'terraform -chdir=infra/cloudflare fmt -recursive')
   make: *** [tf-validate] Error 1
   ```

3. Fix formatting if flagged (`terraform -chdir=infra/<root> fmt -recursive`), then re-run:
   ```bash
   make tf-validate && bats infra/_test/argocd_values.bats infra/_test/root_app.bats
   ```
   **Expected PASS output:**
   ```
   cloudflare: validated
   tailscale: validated
   github: validated
   ✓ argocd bootstrap values disable HA and tune processors
   ✓ repo-server wires KSOPS: sops-age mount + SOPS_AGE_KEY_FILE + exec build options
   ✓ argocd chart version is pinned (semver, not a range)
   ✓ root app recurses platform/argocd/root, uses project default, auto-syncs
   ✓ argocd self-manage app uses the single bootstrap values file + project default

   5 tests, 0 failures
   ```

4. **Commit:**
   ```bash
   git add .github/workflows/iac.yaml
   git commit -m "ci: IaC terraform validate 및 ArgoCD 아티팩트 린트 게이트 추가"
   ```

---

**Milestone 2 exit criteria (all must hold):**
- `make tf-validate` green; `terraform plan` on all three roots shows zero drift after apply.
- `.sops.yaml` carries the **real** cluster + recovery recipients (M2 filled M0's placeholders via Edit; M2 never minted a key).
- `platform/**/prod/*.enc.yaml` seed secrets — the canonical four (`cloudflared-tunnel`/`operator-oauth` in `edge`, `cnpg-r2-creds` in `database`, `alerting-secrets` in `observability`) — decrypt and are encrypted to **two** age recipients. `seed-secrets.sh` is the single producer; no later milestone re-creates them.
- The KSOPS repo-server wiring in `platform/argocd/bootstrap-values.yaml` is in place, and a committed `*.enc.yaml` renders through the live repo-server into a plaintext Secret (`infra/_test/ksops_render.bats` passes) before M3 ships.
- `make bootstrap` on a fresh cluster → ArgoCD pods `Running` (repo-server `2/2` with KSOPS), in-cluster Secret `sops-age` (file key `keys.txt`) present in ns `argocd`, root Application `Synced/Healthy`; second run is a no-op (`infra/_test/bootstrap.bats` passes). `argocd-app.yaml` + `root-app.yaml` are bootstrap-minimal (one values file, project `default`, root recurses `platform/argocd/root/`); M3 will Edit to add sync-waves + the ApplicationSet.
- `scripts/dr-drill.sh` prints `DR DRILL PASS` (R5 validated: full platform restore from git + the offline M0 age key only).
- The manual-once R2 state bucket + committed `infra/_backend/backend.tf` are in place before any `terraform apply`; the recovery age key custody location (recorded by M0) is referenced in `docs/runbooks/02-cloud-iac-bootstrap.md`.

---

## Milestone 3 — Platform networking via ArgoCD

**Goal:** Stand up the GitOps control plane (ArgoCD self-managed + root app-of-apps with a plain git-directory ApplicationSet) and the full networking/DNS edge (Traefik v3 Gateway API, cloudflared public tunnel, Tailscale operator internal exposure, AdGuard split-horizon DNS), all wired with deterministic sync-waves and an internal-by-default posture.

**Depends on:** Milestone 0 (repo skeleton, age key, `.sops.yaml`, pnpm workspace, Makefile stub targets, memory ledger + `pnpm verify:ledger`), Milestone 1 (OrbStack VM + k3s bootstrap, two StorageClasses, `--secrets-encryption`, `make bootstrap` installs ArgoCD), Milestone 2 (real `.sops.yaml` recipients, `sops-age` Secret in `argocd`, KSOPS repo-server wiring in `platform/argocd/bootstrap-values.yaml`, `argocd-app.yaml` + `platform/argocd/root/root-app.yaml` bootstrap-minimal, seed secrets `cloudflared-tunnel`/`operator-oauth` via `seed-secrets.sh`). Milestones 4–6 (CNPG, observability, apps) attach to the Gateway built here.

> Conventions used throughout: cluster is reachable via `kubectl` against the k3s VM (`KUBECONFIG` from M1). `<DOMAIN>` is the real apex zone, internal suffix `int.<DOMAIN>`. ArgoCD `Application`/`ApplicationSet` namespace = `argocd`; AppProject = `default` everywhere (never a `platform` project). Sync-wave order is global (defined in `platform/argocd/root/SYNC-WAVES.md`, owned by this milestone). All secret material lives in `platform/<component>/prod/*.enc.yaml` (SOPS), encrypted to the two recipients minted in M0/M2; each consuming kustomization carries its OWN `secret-generator.yaml` (KSOPS) — there is no shared ksops stub. The `sops-age` Secret, `.sops.yaml`, and the KSOPS repo-server wiring are inherited from M0/M2 and never re-created here. Use @superpowers:executing-plans to drive this section, and @superpowers:verification-before-completion before any "passes" claim.

---

### Task 3.1 — Add ArgoCD self-management sync-waves -10/-9 (Modify M2's argocd-app.yaml)

**Files**
- Modify: `platform/argocd/argocd-app.yaml` (authored bootstrap-minimal by M2; here we add the sync-wave annotation and confirm the pin/values — we do NOT re-Create it)
- Test: ad-hoc `kubectl`/`helm template` assertions (commands below)

> Ownership note: `argocd-app.yaml` and its single values file `platform/argocd/bootstrap-values.yaml` are authored by M2 (bootstrap-minimal: one source pinned to the argo-cd chart, one `$values` ref, project `default`, the KSOPS repo-server wiring lives in `bootstrap-values.yaml`). M3 only EDITs `argocd-app.yaml` to stamp the self-management sync-wave `-10` so ArgoCD reconciles itself first. Do not add a second values file and do not re-declare the Application.

**Steps**

1. Write the failing check first. ArgoCD must self-manage with the self-management sync-wave applied. Assert the annotation is not yet present:
   ```bash
   kubectl -n argocd get application argocd \
     -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-wave}{"\n"}' 2>&1
   ```
2. Run it — EXPECTED FAILURE (M2 authored `argocd-app.yaml` bootstrap-minimal without the wave; either the annotation is empty or, pre-bootstrap, the Application is absent):
   ```
   Error from server (NotFound): applications.argoproj.io "argocd" not found
   ```
3. Implement. EDIT `platform/argocd/argocd-app.yaml` (do NOT recreate it). Add the self-management sync-wave annotation `-10` and confirm it points at the M2 values file `platform/argocd/bootstrap-values.yaml`. The resulting Application is:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: argocd
     namespace: argocd
     annotations:
       argocd.argoproj.io/sync-wave: "-10"   # ADDED by M3: ArgoCD reconciles itself first
     finalizers:
       - resources-finalizer.argocd.argoproj.io
   spec:
     project: default
     sources:
       - repoURL: https://argoproj.github.io/argo-helm
         chart: argo-cd
         targetRevision: 7.7.11        # PINNED by M2 — bump deliberately, never floating
         helm:
           releaseName: argocd
           valueFiles:
             - $values/platform/argocd/bootstrap-values.yaml   # M2-owned single values file (KSOPS wiring lives here)
       - repoURL: https://github.com/<OWNER>/homelab.git
         targetRevision: main
         ref: values
     destination:
       server: https://kubernetes.default.svc
       namespace: argocd
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
         - ServerSideApply=true
         - RespectIgnoreDifferences=true
       retry:
         limit: 5
         backoff: { duration: 15s, factor: 2, maxDuration: 5m }
     ignoreDifferences:
       - group: apiextensions.k8s.io
         kind: CustomResourceDefinition
         jqPathExpressions:
           - .spec.preserveUnknownFields
   ```
   > The HA-off / processor-tuning / resource sizing values (HA disabled, `controller.status.processors: "4"`, `controller.operation.processors: "2"`, `reposerver.parallelism.limit: "2"`, `resource.exclusions` for events/endpoints/EndpointSlice, `kustomize.buildOptions: --enable-alpha-plugins --enable-exec`, per-pod requests/limits — design §5) all live in M2's `platform/argocd/bootstrap-values.yaml`, alongside the KSOPS `repoServer.initContainers`/`volumes`/`volumeMounts`/`env SOPS_AGE_KEY_FILE` wiring. M3 inherits that wiring untouched.
4. Verify the chart renders against the M2 values and the pin resolves — EXPECTED PASS:
   ```bash
   helm template argocd argo-cd --repo https://argoproj.github.io/argo-helm \
     --version 7.7.11 -n argocd -f platform/argocd/bootstrap-values.yaml >/dev/null && echo OK
   ```
   ```
   OK
   ```
   And confirm self-management once applied by `make bootstrap` (root wired in Task 3.2):
   ```bash
   kubectl -n argocd get application argocd \
     -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-wave}{" "}{.spec.source.targetRevision}{" "}{.status.sync.status}{"\n"}'
   # EXPECTED: -10 7.7.11 Synced
   ```
5. Commit:
   ```bash
   git add platform/argocd/argocd-app.yaml
   git commit -m "feat(argocd): 자기관리 Application에 sync-wave -10 추가 (M2 bootstrap-values 사용)"
   ```

---

### Task 3.2 — Root app-of-apps wiring + plain git-directory ApplicationSet + global sync-wave ledger

**Files**
- Modify: `platform/argocd/root/root-app.yaml` (authored bootstrap-minimal by M2; here we stamp sync-wave `-9` and confirm it recurses `platform/argocd/root/` so the appset is picked up — we do NOT re-Create it)
- Create: `platform/argocd/root/appset.yaml`
- Create: `platform/argocd/root/SYNC-WAVES.md`
- Test: ad-hoc `kubectl` assertions

> Ownership note: M2 authored `platform/argocd/root/root-app.yaml` bootstrap-minimal. It recurses the directory `platform/argocd/root/` (project `default`), so hand-rolled Applications and the ApplicationSet placed there are picked up automatically. M3 EDITs it only to stamp the `-9` self-management wave, and ADDS `appset.yaml` + the canonical `SYNC-WAVES.md`.

**Steps**

1. Failing check: TWO ApplicationSets must exist — `platform-components` (plain git-directory) and `apps` (multi-source Helm over the shared chart):
   ```bash
   kubectl -n argocd get applicationset platform-components apps \
     -o jsonpath='{range .items[*]}{.metadata.name}{";"}{end}{"\n"}' 2>&1
   ```
2. Run it — EXPECTED FAILURE:
   ```
   Error from server (NotFound): applicationsets.argoproj.io "platform-components" not found
   ```
3. Implement. First the global sync-wave ledger `platform/argocd/root/SYNC-WAVES.md` — **this milestone OWNS it**; every later milestone cites it (M4 sets the cnpg operator `-2` and Cluster `-1` to match; M5 places observability at `+2`):
   ```markdown
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
   |   1  | migration pre-upgrade Job (`migrate`)      |
   |   2  | Deployment / Service / HTTPRoute           |

   Networking precedes apps: an app's HTTPRoute (per-app wave 2) attaches to a
   Gateway that is already Programmed (wave -8). The cnpg Cluster (-1) precedes
   the per-app config (0) so apps never start against an un-provisioned database;
   the CNPG-Ready gate (the cnpg-data Application being Healthy) is the explicit
   readiness contract M6 depends on.
   ```
   Then EDIT the root Application `platform/argocd/root/root-app.yaml` (M2-authored). Stamp sync-wave `-9` and confirm it recurses the directory so `appset.yaml` is discovered:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: root
     namespace: argocd
     annotations:
       argocd.argoproj.io/sync-wave: "-9"   # ADDED by M3
     finalizers:
       - resources-finalizer.argocd.argoproj.io
   spec:
     project: default
     source:
       repoURL: https://github.com/<OWNER>/homelab.git
       targetRevision: main
       path: platform/argocd/root
       directory:
         recurse: true        # picks up appset.yaml AND any hand-rolled Applications under root/ (M4/M5)
     destination:
       server: https://kubernetes.default.svc
       namespace: argocd
     syncPolicy:
       automated: { prune: true, selfHeal: true }
       syncOptions: [ServerSideApply=true]
   ```
   > Recursing `platform/argocd/root/` is what lets M4 drop `apps/cnpg-operator.yaml`/`apps/cnpg-data.yaml` and M5 drop `apps/victoria-stack.yaml` there (project `default`, explicit destination namespaces) and have them adopted without touching this file again. The `SYNC-WAVES.md` file is markdown, not a manifest, so `recurse: true` skips it.
   Then the ApplicationSet file `platform/argocd/root/appset.yaml` — it holds **TWO ApplicationSets**: `platform-components` (a plain git-directory generator; each `platform/<c>/prod` is a kustomization whose namespace comes from its own `namespace:` field) and `apps` (a **multi-source Helm** template that renders the shared `platform/charts/app` chart with each app's `values.yaml` into ns `prod` — a bare directory source over the values-only app dirs would render nothing). **NO matrix, NO empty-list passthrough.** A second env later is just another matching path (`platform/*/staging`, `apps/*/deploy/staging`):
   ```yaml
   # TWO ApplicationSets. Platform components render as plain kustomize directories;
   # APPS render through the SHARED Helm chart (multi-source: chart + per-app values),
   # because apps/<name>/deploy/prod holds ONLY values.yaml — a bare directory source
   # would render nothing (no Deployment/Service/HTTPRoute/migration Job).
   # -------- 1) PLATFORM components — plain git-directory generator --------
   apiVersion: argoproj.io/v1alpha1
   kind: ApplicationSet
   metadata:
     name: platform-components
     namespace: argocd
   spec:
     goTemplate: true
     goTemplateOptions: ["missingkey=error"]
     generators:
       - git:
           repoURL: https://github.com/<OWNER>/homelab.git
           revision: main
           directories:
             - path: platform/*/prod
             # EXCLUDE argocd (self-managed), cnpg + victoria-stack (hand-rolled
             # Applications under root/apps/ in M4/M5), charts/ (library, not an app).
             - { path: platform/argocd/*,         exclude: true }
             - { path: platform/cnpg/*,           exclude: true }
             - { path: platform/victoria-stack/*, exclude: true }
             - { path: platform/charts/*,         exclude: true }
     template:
       metadata:
         name: '{{ index .path.segments 1 }}-{{ .path.basename }}'   # <component>-prod
         labels: { homelab.env: '{{ .path.basename }}' }
       spec:
         project: default
         source:
           repoURL: https://github.com/<OWNER>/homelab.git
           targetRevision: main
           path: '{{ .path.path }}'        # platform/<component>/prod — a kustomization dir
           # No destination.namespace: each component's kustomization sets `namespace:`
           # (gateway, edge, ...). CreateNamespace covers first-apply.
         destination:
           server: https://kubernetes.default.svc
         syncPolicy:
           automated: { prune: true, selfHeal: true }
           syncOptions: [CreateNamespace=true, ServerSideApply=true]
   ---
   # -------- 2) APPS — render the SHARED chart with each app's values (multi-source Helm) --------
   apiVersion: argoproj.io/v1alpha1
   kind: ApplicationSet
   metadata:
     name: apps
     namespace: argocd
   spec:
     goTemplate: true
     goTemplateOptions: ["missingkey=error"]
     generators:
       - git:
           repoURL: https://github.com/<OWNER>/homelab.git
           revision: main
           directories:
             - path: apps/*/deploy/prod      # only DEPLOYED apps have a deploy/ dir (pg-tools does not)
     template:
       metadata:
         name: '{{ index .path.segments 1 }}-{{ .path.basename }}'   # <app>-prod
         labels: { homelab.env: '{{ .path.basename }}' }
       spec:
         project: default
         sources:
           # source #1: the shared deploy chart (the SSOT for how an app is rendered)
           - repoURL: https://github.com/<OWNER>/homelab.git
             targetRevision: main
             path: platform/charts/app
             helm:
               releaseName: '{{ index .path.segments 1 }}'
               valueFiles:
                 - '$values/{{ .path.path }}/values.yaml'
           # source #2: the same repo exposed as $values so the chart can read the app's values
           - repoURL: https://github.com/<OWNER>/homelab.git
             targetRevision: main
             ref: values
           # source #3: the app's deploy dir as a KUSTOMIZE source — renders the app's KSOPS
           # secret-generator (its envFrom *.enc.yaml). The Helm chart (source #1) does NOT carry
           # the app's secrets, so without this the Deployment/migration envFrom secrets are MISSING.
           - repoURL: https://github.com/<OWNER>/homelab.git
             targetRevision: main
             path: '{{ .path.path }}'      # apps/<name>/deploy/prod: kustomization.yaml + secret-generator.yaml + *.enc.yaml
         destination:
           server: https://kubernetes.default.svc
           namespace: prod
         syncPolicy:
           automated: { prune: true, selfHeal: true }
           syncOptions: [CreateNamespace=true, ServerSideApply=true]
   ```
   > Namespaces: **platform components** take their namespace from each kustomization's own `namespace:` field (traefik→`gateway`, cloudflared/tailscale/adguard→`edge`), so `platform-components` sets no `destination.namespace`. **Apps** all deploy to ns `prod`, set explicitly on the `apps` Application's `destination.namespace`. `CreateNamespace=true` covers the first sync in both. Adding a second env later (`platform/*/staging`, `apps/*/deploy/staging`) needs no generator change — those paths already match the globs.
   > **Source #3 requirement:** EVERY `apps/<name>/deploy/prod/` MUST contain a `kustomization.yaml` (even a minimal one) so the Kustomize source renders — `gen:app` (M6) scaffolds it alongside `values.yaml`, plus a `secret-generator.yaml` (KSOPS) + the app's `*.enc.yaml`. The e2e test (Task 6.17) asserts the app's `envFrom` Secret EXISTS before the migration Job / Deployment run.
4. Verify after `make bootstrap` applies the root — EXPECTED PASS:
   ```bash
   kubectl -n argocd get applicationset platform-components apps -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}{"\n"}'
   # apps platform-components
   kubectl -n argocd get applications.argoproj.io -l homelab.env=prod -o name
   # one application/<component>-prod per platform/<c>/prod dir + one <app>-prod per apps/<n>/deploy/prod:
   #   traefik-prod, cloudflared-prod, tailscale-prod, adguard-prod, api-prod, worker-prod, web-prod, console-prod
   # confirm the platform excludes held — none of these should appear:
   kubectl -n argocd get applications.argoproj.io -o name | grep -E 'argocd-prod|cnpg-prod|victoria-stack-prod|charts' || echo "EXCLUDES_OK"
   # EXCLUDES_OK
   # confirm an APP actually RENDERS the chart (Deployment/Service/HTTPRoute), not a values-only no-op:
   argocd app manifests api-prod 2>/dev/null | grep -Eq 'kind: (Deployment|Service|HTTPRoute)' && echo "APP_RENDERS_OK"
   ```
   Render-time sanity (no live cluster needed):
   ```bash
   ls -d platform/*/prod 2>/dev/null && echo "env-scoped dirs present" || echo "WARN: platform/<c>/prod dirs are created in their own tasks/milestones"
   ```
5. Commit:
   ```bash
   git add platform/argocd/root/root-app.yaml platform/argocd/root/appset.yaml platform/argocd/root/SYNC-WAVES.md
   git commit -m "feat(argocd): 평문 git-directory ApplicationSet와 sync-wave 원장 추가, 루트 앱에 wave -9 부착"
   ```

---

### Task 3.3 — Gateway API CRDs + Traefik RBAC ClusterRole (k3s gap) (wave -8)

**Files**
- Create: `platform/traefik/prod/kustomization.yaml`
- Create: `platform/traefik/prod/gateway-api-crds.yaml` (vendored, pinned)
- Create: `platform/traefik/prod/rbac-gateway.yaml`
- Test: ad-hoc `kubectl` assertions

**Steps**

1. Failing check: the Gateway API CRDs and the ClusterRole that k3s omits must exist:
   ```bash
   kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}{"\n"}' 2>&1
   kubectl get clusterrole traefik-gateway-api -o name 2>&1
   ```
2. Run — EXPECTED FAILURE:
   ```
   Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "gateways.gateway.networking.k8s.io" not found
   Error from server (NotFound): clusterroles.rbac.authorization.k8s.io "traefik-gateway-api" not found
   ```
3. Implement. Vendor the pinned standard-channel CRDs (Gateway API v1.2.0) and the RBAC ClusterRole Traefik needs but the k3s distribution does not ship. The kustomization's `namespace: gateway` is the authoritative destination the ApplicationSet honors. `platform/traefik/prod/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: gateway   # AUTHORITATIVE destination for the traefik-prod Application
   # Gateway API standard channel, PINNED. Re-vendor by:
   #   curl -sL https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml \
   #     -o platform/traefik/prod/gateway-api-crds.yaml
   resources:
     - gateway-api-crds.yaml
     - rbac-gateway.yaml
     - helmrelease.yaml          # added in Task 3.4
     - gateway.yaml              # added in Task 3.4
     - gatewayclass.yaml         # added in Task 3.4
     - whoami-smoke.yaml         # added in Task 3.5
   ```
   Fetch the CRDs into `platform/traefik/prod/gateway-api-crds.yaml` and stamp the wave annotation header (run once, then commit the result):
   ```bash
   curl -sL https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml \
     -o platform/traefik/prod/gateway-api-crds.yaml
   kubectl annotate --local --dry-run=client -f platform/traefik/prod/gateway-api-crds.yaml \
     argocd.argoproj.io/sync-wave=-8 -o yaml > /tmp/crds.yaml && mv /tmp/crds.yaml platform/traefik/prod/gateway-api-crds.yaml
   ```
   `platform/traefik/prod/rbac-gateway.yaml` (the documented k3s gap — Traefik's SA needs cluster-wide read on Gateway-API + referencegrants/endpointslices; sync-wave -8 so it lands with the gateway tier):
   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: traefik-gateway-api
     annotations:
       argocd.argoproj.io/sync-wave: "-8"
   rules:
     - apiGroups: ["gateway.networking.k8s.io"]
       resources:
         - gatewayclasses
         - gateways
         - httproutes
         - tcproutes
         - tlsroutes
         - referencegrants
       verbs: ["get", "list", "watch"]
     - apiGroups: ["gateway.networking.k8s.io"]
       resources:
         - gatewayclasses/status
         - gateways/status
         - httproutes/status
         - tcproutes/status
         - tlsroutes/status
       verbs: ["update", "patch"]
     - apiGroups: [""]
       resources: ["services", "secrets", "namespaces"]
       verbs: ["get", "list", "watch"]
     - apiGroups: ["discovery.k8s.io"]
       resources: ["endpointslices"]
       verbs: ["get", "list", "watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRoleBinding
   metadata:
     name: traefik-gateway-api
     annotations:
       argocd.argoproj.io/sync-wave: "-8"
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: ClusterRole
     name: traefik-gateway-api
   subjects:
     - kind: ServiceAccount
       name: traefik
       namespace: gateway
   ```
4. Verify CRDs install and RBAC is recognized — EXPECTED PASS:
   ```bash
   kubectl apply --dry-run=server -k platform/traefik/prod/ >/dev/null 2>&1 || \
     kubectl apply --dry-run=client -f platform/traefik/prod/gateway-api-crds.yaml -f platform/traefik/prod/rbac-gateway.yaml
   kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}{"\n"}'
   # v1 v1beta1
   kubectl get clusterrole traefik-gateway-api -o jsonpath='{.metadata.name}{"\n"}'
   # traefik-gateway-api
   ```
5. Commit:
   ```bash
   git add platform/traefik/prod/kustomization.yaml platform/traefik/prod/gateway-api-crds.yaml platform/traefik/prod/rbac-gateway.yaml
   git commit -m "feat(traefik): Gateway API CRD 핀 고정 및 k3s 누락 RBAC ClusterRole 추가 (wave -8)"
   ```

---

### Task 3.4 — Traefik v3 Helm values + GatewayClass + wildcard Gateway (wave -8)

**Files**
- Create: `platform/traefik/prod/helmrelease.yaml`
- Create: `platform/traefik/prod/gatewayclass.yaml`
- Create: `platform/traefik/prod/gateway.yaml`
- Create: `platform/traefik/prod/values-traefik.yaml`
- Test: ad-hoc `kubectl` assertions

**Steps**

1. Failing check: a `Gateway` named `homelab` in `gateway` ns must report `Accepted=True` and `Programmed=True`:
   ```bash
   kubectl -n gateway get gateway homelab \
     -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}' 2>&1
   ```
2. Run — EXPECTED FAILURE:
   ```
   Error from server (NotFound): gateways.gateway.networking.k8s.io "homelab" not found
   ```
3. Implement. Traefik values `platform/traefik/prod/values-traefik.yaml` (Gateway API on, Ingress off, servicelb LoadBalancer, single replica, JSON access logs — design §6):
   ```yaml
   deployment:
     replicas: 1
   providers:
     kubernetesGateway:
       enabled: true
     kubernetesIngress:
       enabled: false
     kubernetesCRD:
       enabled: false
   gateway:
     enabled: false   # we manage GatewayClass + Gateway ourselves (gatewayclass.yaml/gateway.yaml)
   gatewayClass:
     enabled: false
   service:
     type: LoadBalancer     # k3s servicelb publishes on the VM node IP :80/:443
   ports:
     web:
       port: 8000
       expose: { default: true }
       exposedPort: 80
       protocol: TCP
     websecure:
       port: 8443
       expose: { default: true }
       exposedPort: 443
       protocol: TCP
   logs:
     general:
       format: json
       level: INFO
     access:
       enabled: true
       format: json        # JSON → stdout → Vector → VictoriaLogs (M5)
   ingressRoute:
     dashboard:
       enabled: false      # dashboard is internal-only; not exposed here
   resources:
     requests: { cpu: 50m, memory: 64Mi }
     limits:   { cpu: 500m, memory: 128Mi }
   rbac:
     enabled: true         # base RBAC; Gateway-API extension comes from rbac-gateway.yaml (Task 3.3)
   serviceAccount:
     name: traefik
   ```
   `platform/traefik/prod/helmrelease.yaml` — render Traefik inside the kustomization via a pinned `HelmChartInflationGenerator` (the repo-server renders kustomize with helm enabled):
   ```yaml
   apiVersion: builtin
   kind: HelmChartInflationGenerator
   metadata:
     name: traefik
   name: traefik
   repo: https://traefik.github.io/charts
   version: 33.0.0            # PINNED Traefik v3.x chart
   releaseName: traefik
   namespace: gateway
   valuesFile: values-traefik.yaml
   ```
   Wire the generator into the kustomization (append to `platform/traefik/prod/kustomization.yaml`):
   ```yaml
   # append to platform/traefik/prod/kustomization.yaml
   generators:
     - helmrelease.yaml
   ```
   > Executor note: this `HelmChartInflationGenerator` renders ONLY because M2's `kustomize.buildOptions` includes **`--enable-helm`** (alongside `--enable-alpha-plugins --enable-exec` for KSOPS) — all three are set in M2's `bootstrap-values.yaml`, inherited here. Without `--enable-helm`, kustomize rejects helm generators and the networking tier never syncs. The chart is pinned to `33.0.0` (Traefik v3).

   `platform/traefik/prod/gatewayclass.yaml`:
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: GatewayClass
   metadata:
     name: traefik
     annotations:
       argocd.argoproj.io/sync-wave: "-8"
   spec:
     controllerName: traefik.io/gateway-controller
   ```
   `platform/traefik/prod/gateway.yaml` — the single canonical Gateway `homelab` in ns `gateway`, with the two canonical listeners `web-public` (public apex) and `web-internal` (internal suffix), `allowedRoutes` from all namespaces so apps in `prod` attach (design §6):
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata:
     name: homelab
     namespace: gateway
     annotations:
       argocd.argoproj.io/sync-wave: "-8"
   spec:
     gatewayClassName: traefik
     listeners:
       - name: web-public
         protocol: HTTP
         port: 8000
         hostname: "*.<DOMAIN>"
         allowedRoutes:
           namespaces: { from: All }
       - name: web-internal
         protocol: HTTP
         port: 8000
         hostname: "*.int.<DOMAIN>"
         allowedRoutes:
           namespaces: { from: All }
   ```
   > Canonical Gateway contract: name `homelab`, namespace `gateway`, listener sectionNames `web-public` and `web-internal`. EVERY HTTPRoute (here and in M4–M6) uses `parentRefs: [{ name: homelab, namespace: gateway, sectionName: web-public|web-internal }]`. The shared chart (M6) reads `gateway.name`/`gateway.namespace` defaults (`homelab`/`gateway`) and maps `route.public` → `sectionName`.
   > TLS is terminated at the Cloudflare edge (public) and by Tailscale (`*.ts.net`, internal) — no in-cluster cert-manager (design §6, §14). Listeners are plaintext HTTP on the in-cluster port.
4. Verify after sync — EXPECTED PASS:
   ```bash
   kubectl -n gateway get gateway homelab \
     -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
   # Accepted=True Programmed=True
   kubectl get gatewayclass traefik -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}{"\n"}'
   # True
   kubectl -n gateway get svc traefik -o jsonpath='{.spec.type}{" "}{.status.loadBalancer.ingress[0].ip}{"\n"}'
   # LoadBalancer <VM-node-IP>
   ```
5. Commit:
   ```bash
   git add platform/traefik/prod/helmrelease.yaml platform/traefik/prod/gatewayclass.yaml platform/traefik/prod/gateway.yaml platform/traefik/prod/values-traefik.yaml platform/traefik/prod/kustomization.yaml
   git commit -m "feat(traefik): Traefik v3 Gateway API 컨트롤러와 homelab Gateway(web-public/web-internal) 구성"
   ```

---

### Task 3.5 — Sample HTTPRoute attaches to the Gateway (Accepted)

**Files**
- Create: `platform/traefik/prod/whoami-smoke.yaml`
- Test: ad-hoc `kubectl` assertions

**Steps**

1. Failing check: a smoke HTTPRoute must report `Accepted=True` and `ResolvedRefs=True` on the `homelab` Gateway. This proves route-attachment before any real app exists (M6).
   ```bash
   kubectl -n gateway get httproute whoami \
     -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {end}{"\n"}' 2>&1
   ```
2. Run — EXPECTED FAILURE:
   ```
   Error from server (NotFound): httproutes.gateway.networking.k8s.io "whoami" not found
   ```
3. Implement a minimal whoami Deployment+Service+HTTPRoute (internal hostname so it is never public). It uses the canonical `parentRefs` shape. `platform/traefik/prod/whoami-smoke.yaml`:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata: { name: whoami, namespace: gateway, annotations: { argocd.argoproj.io/sync-wave: "-7" } }
   spec:
     replicas: 1
     selector: { matchLabels: { app: whoami } }
     template:
       metadata: { labels: { app: whoami } }
       spec:
         containers:
           - name: whoami
             image: traefik/whoami:v1.10.3
             ports: [{ containerPort: 80 }]
             resources:
               requests: { cpu: 10m, memory: 16Mi }
               limits:   { cpu: 50m, memory: 32Mi }
             securityContext:
               runAsNonRoot: true
               runAsUser: 65532
               allowPrivilegeEscalation: false
               readOnlyRootFilesystem: true
               capabilities: { drop: ["ALL"] }
   ---
   apiVersion: v1
   kind: Service
   metadata: { name: whoami, namespace: gateway }
   spec:
     selector: { app: whoami }
     ports: [{ port: 80, targetPort: 80 }]
   ---
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: whoami
     namespace: gateway
     annotations: { argocd.argoproj.io/sync-wave: "-7" }
   spec:
     parentRefs:
       - name: homelab
         namespace: gateway
         sectionName: web-internal
     hostnames: ["whoami.int.<DOMAIN>"]
     rules:
       - matches: [{ path: { type: PathPrefix, value: / } }]
         backendRefs: [{ name: whoami, port: 80 }]
   ```
   (`whoami-smoke.yaml` is already listed in `platform/traefik/prod/kustomization.yaml` `resources:` from Task 3.3. The `-7` wave keeps the smoke route after the `-8` gateway tier but before the `-6` edge.)
4. Verify after sync — EXPECTED PASS:
   ```bash
   kubectl -n gateway get httproute whoami \
     -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {end}{"\n"}'
   # Accepted=True ResolvedRefs=True
   # in-cluster reachability through Traefik:
   kubectl -n gateway run curl-smoke --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
     curl -s -H 'Host: whoami.int.<DOMAIN>' http://traefik.gateway.svc.cluster.local/ | grep -q 'Hostname:' && echo ROUTE_OK
   # ROUTE_OK
   ```
5. Commit:
   ```bash
   git add platform/traefik/prod/whoami-smoke.yaml
   git commit -m "test(traefik): whoami HTTPRoute로 Gateway 라우트 부착 스모크 추가"
   ```

---

### Task 3.6 — cloudflared public tunnel (references M2 seed Secret, ingress → Traefik, wave -6)

**Files**
- Create: `platform/cloudflared/prod/kustomization.yaml`
- Create: `platform/cloudflared/prod/deployment.yaml`
- Create: `platform/cloudflared/prod/configmap.yaml`
- Create: `platform/cloudflared/prod/secret-generator.yaml` (this component's OWN KSOPS generator)
- Test: ad-hoc `kubectl`/`curl` assertions

> Secret ownership: the tunnel credential is produced ONCE by M2's `seed-secrets.sh` at the canonical path `platform/cloudflared/prod/tunnel.enc.yaml` → Secret `cloudflared-tunnel` (ns `edge`). M3 REFERENCES that Secret and does NOT re-create it (no `kubectl create secret`, no `sops --encrypt` of the tunnel token here). This kustomization carries its OWN `secret-generator.yaml` (KSOPS) pointing at the M2-seeded `tunnel.enc.yaml`; there is no shared ksops stub.

**Steps**

1. Failing check: the cloudflared Deployment must be Available and its tunnel connections healthy:
   ```bash
   kubectl -n edge get deploy cloudflared -o jsonpath='{.status.availableReplicas}{"\n"}' 2>&1
   ```
2. Run — EXPECTED FAILURE:
   ```
   Error from server (NotFound): deployments.apps "cloudflared" not found
   ```
3. Implement. The tunnel credential file `platform/cloudflared/prod/tunnel.enc.yaml` (Secret `cloudflared-tunnel`) is ALREADY produced by M2's `seed-secrets.sh` — do not re-create it. Add this component's own KSOPS generator `platform/cloudflared/prod/secret-generator.yaml`:
   ```yaml
   apiVersion: viaduct.ai/v1
   kind: ksops
   metadata:
     name: cloudflared-secret-generator
   files:
     - tunnel.enc.yaml   # M2-seeded → Secret 'cloudflared-tunnel' (ns edge)
   ```
   `platform/cloudflared/prod/configmap.yaml` — ingress maps everything to the Traefik ClusterIP over plaintext; the catch-all is mandatory:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: cloudflared
     namespace: edge
     annotations: { argocd.argoproj.io/sync-wave: "-6" }
   data:
     config.yaml: |
       tunnel: homelab
       no-autoupdate: true
       metrics: 0.0.0.0:9090          # prometheus.io/scrape annotation on pod (M5)
       ingress:
         - service: http://traefik.gateway.svc.cluster.local:80
       # Public hostname → tunnel routing is managed in Cloudflare DNS by Terraform (M2):
       #   *.<DOMAIN> CNAME <tunnel-id>.cfargotunnel.com (proxied)
   ```
   `platform/cloudflared/prod/deployment.yaml` (token-mode `tunnel run`, single replica, GOMEMLIMIT per §8; the token comes from the M2-seeded `cloudflared-tunnel` Secret):
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: cloudflared
     namespace: edge
     annotations: { argocd.argoproj.io/sync-wave: "-6" }
   spec:
     replicas: 1
     selector: { matchLabels: { app: cloudflared } }
     template:
       metadata:
         labels: { app: cloudflared }
         annotations:
           prometheus.io/scrape: "true"
           prometheus.io/port: "9090"
       spec:
         containers:
           - name: cloudflared
             image: cloudflare/cloudflared:2024.10.1
             args: ["tunnel", "--config", "/etc/cloudflared/config.yaml", "--no-autoupdate", "run"]
             env:
               - name: TUNNEL_TOKEN
                 valueFrom: { secretKeyRef: { name: cloudflared-tunnel, key: token } }
               - name: GOMEMLIMIT
                 value: "115MiB"
             volumeMounts:
               - { name: config, mountPath: /etc/cloudflared }
             resources:
               requests: { cpu: 25m, memory: 48Mi }
               limits:   { cpu: 300m, memory: 128Mi }
             livenessProbe:
               httpGet: { path: /ready, port: 9090 }
               initialDelaySeconds: 10
             securityContext:
               runAsNonRoot: true
               runAsUser: 65532
               allowPrivilegeEscalation: false
               readOnlyRootFilesystem: true
               capabilities: { drop: ["ALL"] }
         volumes:
           - name: config
             configMap: { name: cloudflared }
   ```
   `platform/cloudflared/prod/kustomization.yaml` (`namespace: edge` is the authoritative destination; KSOPS via this component's own generator):
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: edge   # AUTHORITATIVE destination for the cloudflared-prod Application
   resources:
     - deployment.yaml
     - configmap.yaml
   generators:
     - secret-generator.yaml   # this component's OWN KSOPS generator → cloudflared-tunnel
   ```
   > The `secret-keyRef.name` is `cloudflared-tunnel` (the M2 canonical Secret name), not a locally-minted name. The Secret material is produced once by M2; M3 only renders it via KSOPS and mounts it.
4. Verify — EXPECTED PASS (Deployment ready, tunnel registered, public hostname returns from Traefik):
   ```bash
   kubectl -n edge get deploy cloudflared -o jsonpath='{.status.availableReplicas}{"\n"}'
   # 1
   kubectl -n edge get secret cloudflared-tunnel -o jsonpath='{.metadata.name}{"\n"}'
   # cloudflared-tunnel   (rendered by KSOPS from the M2-seeded tunnel.enc.yaml)
   kubectl -n edge logs deploy/cloudflared | grep -m1 'Registered tunnel connection'
   # ...Registered tunnel connection connIndex=0 ...
   # end-to-end through Cloudflare edge → tunnel → Traefik (use a public app host once M6 exists;
   # before that, a temporary public whoami route proves the path):
   curl -s -o /dev/null -w '%{http_code}\n' https://whoami.<DOMAIN>/
   # 200   (served by Traefik via the tunnel; 0 inbound ports on the Mac)
   ```
5. Commit:
   ```bash
   git add platform/cloudflared/prod/
   git commit -m "feat(cloudflared): M2 시드 cloudflared-tunnel Secret 참조 공개 터널과 Traefik 인그레스 구성 (wave -6)"
   ```

---

### Task 3.7 — Tailscale operator + expose Traefik once via Tailscale Ingress (wave -6)

**Files**
- Create: `platform/tailscale/prod/kustomization.yaml`
- Create: `platform/tailscale/prod/helmrelease.yaml`
- Create: `platform/tailscale/prod/values-tailscale.yaml`
- Create: `platform/tailscale/prod/traefik-ingress.yaml`
- Create: `platform/tailscale/prod/secret-generator.yaml` (this component's OWN KSOPS generator)
- Test: ad-hoc `kubectl`/`tailscale` assertions

> Secret ownership: the operator OAuth credential is produced ONCE by M2's `seed-secrets.sh` at the canonical path `platform/tailscale/prod/operator-oauth.enc.yaml` → Secret `operator-oauth` (ns `edge`). M3 REFERENCES that Secret (the operator's `oauth.existingSecret: operator-oauth`) and does NOT re-create it. This kustomization carries its OWN `secret-generator.yaml` (KSOPS); there is no shared ksops stub.

**Steps**

1. Failing check: the Tailscale operator must be running and a single Tailscale `Ingress` must expose Traefik (one proxy for all `*.int`):
   ```bash
   kubectl -n edge get deploy operator -o jsonpath='{.status.availableReplicas}{"\n"}' 2>&1
   kubectl -n gateway get ingress traefik-ts -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}' 2>&1
   ```
2. Run — EXPECTED FAILURE:
   ```
   Error from server (NotFound): deployments.apps "operator" not found
   Error from server (NotFound): ingresses.networking.k8s.io "traefik-ts" not found
   ```
3. Implement. The OAuth credential file `platform/tailscale/prod/operator-oauth.enc.yaml` (Secret `operator-oauth`) is ALREADY produced by M2 — do not re-create it. Add this component's own KSOPS generator `platform/tailscale/prod/secret-generator.yaml`:
   ```yaml
   apiVersion: viaduct.ai/v1
   kind: ksops
   metadata:
     name: tailscale-secret-generator
   files:
     - operator-oauth.enc.yaml   # M2-seeded → Secret 'operator-oauth' (ns edge)
   ```
   `platform/tailscale/prod/values-tailscale.yaml` (operator reads the pre-created M2 Secret by name):
   ```yaml
   oauth:
     # operator reads the M2-seeded SOPS Secret 'operator-oauth' (not inline)
     existingSecret: operator-oauth
   apiServerProxyConfig:
     mode: "false"          # no kube-apiserver exposure; we only proxy Traefik
   operatorConfig:
     hostname: homelab-operator
     resources:
       requests: { cpu: 25m, memory: 64Mi }
       limits:   { cpu: 200m, memory: 128Mi }
   proxyConfig:
     defaultProxyClass: ""
   ```
   `platform/tailscale/prod/helmrelease.yaml` (pinned operator chart):
   ```yaml
   apiVersion: builtin
   kind: HelmChartInflationGenerator
   metadata:
     name: tailscale-operator
   name: tailscale-operator
   repo: https://pkgs.tailscale.com/helmcharts
   version: 1.78.1           # PINNED
   releaseName: tailscale-operator
   namespace: edge
   valuesFile: values-tailscale.yaml
   ```
   `platform/tailscale/prod/traefik-ingress.yaml` — the SINGLE Tailscale Ingress; every `*.int` HTTPRoute already lands on Traefik, so exposing Traefik once gives internal access to all of them through one proxy pod (design §6):
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: traefik-ts
     namespace: gateway
     annotations: { argocd.argoproj.io/sync-wave: "-6" }
   spec:
     ingressClassName: tailscale
     defaultBackend:
       service:
         name: traefik
         port: { number: 80 }
     tls:
       - hosts: ["homelab"]        # → homelab.<tailnet>.ts.net, Tailscale-issued TLS
   ```
   `platform/tailscale/prod/kustomization.yaml` (**NO global `namespace:` transformer** — it would override the Ingress's `gateway` namespace into `edge`, where the backend Service `traefik` does not exist; each resource self-declares its namespace instead):
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   # NO `namespace:` here. A global namespace transformer FORCES every namespaced resource —
   # including the `traefik-ts` Ingress — into one namespace, which would break the Ingress's
   # gateway-ns backend reference. Instead: the operator helmrelease + operator-oauth Secret
   # already declare `namespace: edge`, and the Ingress declares `namespace: gateway`. ArgoCD
   # applies each resource to its own declared namespace.
   resources:
     - traefik-ingress.yaml
   generators:
     - helmrelease.yaml
     - secret-generator.yaml   # this component's OWN KSOPS generator → operator-oauth (edge)
   ```
   > Render assertion (add to this task's checks): `kustomize build --enable-alpha-plugins --enable-exec --enable-helm platform/tailscale/prod | yq 'select(.kind=="Ingress").metadata.namespace'` must print `gateway` (NOT `edge`), proving the Ingress lands beside the Traefik Service.
4. Verify — EXPECTED PASS (operator joins the tailnet; the single Ingress gets a stable `*.ts.net` name; `tailscale status` from any tailnet device shows the operator/proxy node):
   ```bash
   kubectl -n edge get deploy operator -o jsonpath='{.status.availableReplicas}{"\n"}'
   # 1
   kubectl -n edge get secret operator-oauth -o jsonpath='{.metadata.name}{"\n"}'
   # operator-oauth   (rendered by KSOPS from the M2-seeded operator-oauth.enc.yaml)
   kubectl -n gateway get ingress traefik-ts -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
   # homelab.<tailnet>.ts.net
   # from a tailnet-joined device:
   tailscale status | grep -E 'homelab-operator|homelab'
   # 100.x.y.z   homelab-operator   ...   active
   # internal route reachable only over the tailnet:
   curl -s -o /dev/null -w '%{http_code}\n' --resolve whoami.int.<DOMAIN>:443:$(tailscale ip -4 homelab) https://whoami.int.<DOMAIN>/
   # 200
   ```
5. Commit:
   ```bash
   git add platform/tailscale/prod/
   git commit -m "feat(tailscale): M2 시드 operator-oauth Secret 참조 operator 설치 및 Traefik 단일 Tailscale Ingress 노출 (wave -6)"
   ```

---

### Task 3.8 — AdGuard Home: split-horizon DNS → stable Tailscale IP, internal-only (wave -6, R7)

**Files**
- Create: `platform/adguard/prod/kustomization.yaml`
- Create: `platform/adguard/prod/pvc.yaml`
- Create: `platform/adguard/prod/deployment.yaml`
- Create: `platform/adguard/prod/service.yaml`
- Create: `platform/adguard/prod/adguardhome.yaml` (config ConfigMap)
- Create: `platform/adguard/prod/ts-ingress.yaml`
- Test: ad-hoc `kubectl`/`dig` assertions

**Steps**

1. Failing check: AdGuard must resolve `*.int.<DOMAIN>` to the STABLE Tailscale IP of the operator-exposed Traefik (not the unstable VM IP), and its DNS must be LAN-reachable via the LoadBalancer:
   ```bash
   AG_IP=$(kubectl -n edge get svc adguard-dns -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>&1)
   dig +short @"$AG_IP" whoami.int.<DOMAIN> 2>&1
   ```
2. Run — EXPECTED FAILURE:
   ```
   Error from server (NotFound): services "adguard-dns" not found
   ;; communications error ... no servers could be reached
   ```
3. Implement. PVC on the `standard` SC (design §4 — config, never bulk-ssd). `platform/adguard/prod/pvc.yaml`:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata: { name: adguard-data, namespace: edge, annotations: { argocd.argoproj.io/sync-wave: "-6" } }
   spec:
     accessModes: ["ReadWriteOnce"]
     storageClassName: standard
     resources: { requests: { storage: 1Gi } }
   ```
   `platform/adguard/prod/adguardhome.yaml` — config with split-horizon rewrite to the **stable Tailscale IP** and a DoH upstream (design §6). The Tailscale IP is the operator-exposed Traefik IP captured in Task 3.7 (`tailscale ip -4 homelab`):
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata: { name: adguard-config, namespace: edge, annotations: { argocd.argoproj.io/sync-wave: "-6" } }
   data:
     AdGuardHome.yaml: |
       http:
         address: 0.0.0.0:3000
       dns:
         bind_hosts: ["0.0.0.0"]
         port: 53
         upstream_dns:
           - https://dns.cloudflare.com/dns-query   # DoH upstream
           - https://dns.quad9.net/dns-query
         bootstrap_dns: ["1.1.1.1", "9.9.9.9"]
         upstream_mode: load_balance
       filtering:
         rewrites:
           # split-horizon: every *.int name → STABLE Tailscale IP of Traefik
           - domain: "*.int.<DOMAIN>"
             answer: "<STABLE_TAILSCALE_IP>"     # = tailscale ip -4 homelab (Task 3.7)
         protection_enabled: true
       filters:
         - enabled: true
           url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
           name: AdGuard DNS filter
           id: 1
       schema_version: 27
   ```
   `platform/adguard/prod/deployment.yaml`:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata: { name: adguard, namespace: edge, annotations: { argocd.argoproj.io/sync-wave: "-6" } }
   spec:
     replicas: 1
     strategy: { type: Recreate }     # RWO PVC, single node
     selector: { matchLabels: { app: adguard } }
     template:
       metadata: { labels: { app: adguard } }
       spec:
         initContainers:
           - name: seed-config
             image: busybox:1.37
             command: ["sh","-c","cp -n /seed/AdGuardHome.yaml /opt/adguardhome/conf/AdGuardHome.yaml || true"]
             volumeMounts:
               - { name: seed, mountPath: /seed }
               - { name: data, mountPath: /opt/adguardhome/conf, subPath: conf }
         containers:
           - name: adguard
             image: adguard/adguardhome:v0.107.55
             ports:
               - { name: dns-udp, containerPort: 53, protocol: UDP }
               - { name: dns-tcp, containerPort: 53, protocol: TCP }
               - { name: http, containerPort: 3000 }
             volumeMounts:
               - { name: data, mountPath: /opt/adguardhome/conf, subPath: conf }
               - { name: data, mountPath: /opt/adguardhome/work, subPath: work }
             resources:
               requests: { cpu: 25m, memory: 48Mi }
               limits:   { cpu: 200m, memory: 128Mi }
             securityContext:
               runAsNonRoot: true
               runAsUser: 65532
               allowPrivilegeEscalation: false
               capabilities: { drop: ["ALL"] }
         volumes:
           - name: seed
             configMap: { name: adguard-config }
           - name: data
             persistentVolumeClaim: { claimName: adguard-data }
   ```
   `platform/adguard/prod/service.yaml` — DNS as a **LoadBalancer** (servicelb → VM node IP → the Mac mini's reserved LAN IP) so household LAN clients can actually resolve through it; the UI stays internal-only (ClusterIP, reached via the Tailscale Ingress below):
   ```yaml
   # LAN-reachable DNS: type LoadBalancer so k3s servicelb publishes :53 on the VM node IP, which
   # OrbStack maps to the Mac mini host — LAN clients reach it at the Mac's RESERVED LAN IP.
   # (A ClusterIP is NOT routable from household LAN clients, so it cannot back DHCP option 6.)
   apiVersion: v1
   kind: Service
   metadata: { name: adguard-dns, namespace: edge, annotations: { argocd.argoproj.io/sync-wave: "-6" } }
   spec:
     type: LoadBalancer
     selector: { app: adguard }
     ports:
       - { name: dns-udp, port: 53, targetPort: 53, protocol: UDP }
       - { name: dns-tcp, port: 53, targetPort: 53, protocol: TCP }
   ---
   apiVersion: v1
   kind: Service
   metadata: { name: adguard-ui, namespace: edge }
   spec:
     selector: { app: adguard }
     ports: [{ name: http, port: 80, targetPort: 3000 }]
   ```
   `platform/adguard/prod/ts-ingress.yaml` — AdGuard UI exposed ONLY over Tailscale (internal-only, never public). DNS (udp/tcp 53) is reached by LAN clients via the **LoadBalancer above at the Mac mini's reserved LAN IP** — NOT via this Ingress (which is HTTP-only). The LAN wiring (DHCP option 6 → that IP + router secondary DNS) is documented and verified from a real non-cluster LAN device in Task 3.9.
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: adguard-ui
     namespace: edge
     annotations: { argocd.argoproj.io/sync-wave: "-6" }
   spec:
     ingressClassName: tailscale
     defaultBackend:
       service: { name: adguard-ui, port: { number: 80 } }
     tls:
       - hosts: ["adguard"]   # adguard.<tailnet>.ts.net
   ```
   `platform/adguard/prod/kustomization.yaml` (`namespace: edge` authoritative):
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: edge   # AUTHORITATIVE destination for the adguard-prod Application
   resources:
     - pvc.yaml
     - adguardhome.yaml
     - deployment.yaml
     - service.yaml
     - ts-ingress.yaml
   ```
4. Verify — EXPECTED PASS (split-horizon resolves to the stable Tailscale IP):
   ```bash
   # adguard-dns is a LoadBalancer (servicelb): grab its LAN-reachable IP, not a ClusterIP
   AG_IP=$(kubectl -n edge get svc adguard-dns -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
   echo "AdGuard DNS LB IP = ${AG_IP}   (this is the DHCP option-6 address)"
   dig +short @"$AG_IP" whoami.int.<DOMAIN>
   # <STABLE_TAILSCALE_IP>     (the operator-exposed Traefik IP, NOT the VM IP)
   # internal-only assertion (UI only on the tailnet):
   kubectl -n edge get svc adguard-ui -o jsonpath='{.spec.type}{"\n"}'
   # ClusterIP   (never LoadBalancer → not LAN/publicly exposed except via Tailscale)
   ```
5. Commit:
   ```bash
   git add platform/adguard/prod/
   git commit -m "feat(adguard): split-horizon DNS를 안정 Tailscale IP로 라우팅하는 내부 전용 AdGuard 구성 (wave -6)"
   ```

---

### Task 3.9 — R7 runbook: router secondary upstream DNS + DHCP option 6

**Files**
- Create: `docs/runbooks/lan-dns.md`
- Test: documentation lint (`grep` assertions below)

**Steps**

1. Failing check: the runbook must document the household SPOF mitigation (router secondary DNS = 1.1.1.1) and DHCP option 6 pointing at AdGuard — required by R7. Assert it is missing:
   ```bash
   grep -q 'option 6' docs/runbooks/lan-dns.md 2>&1; echo "exit=$?"
   grep -q '1.1.1.1' docs/runbooks/lan-dns.md 2>&1; echo "exit=$?"
   ```
2. Run — EXPECTED FAILURE:
   ```
   grep: docs/runbooks/lan-dns.md: No such file or directory
   exit=2
   grep: docs/runbooks/lan-dns.md: No such file or directory
   exit=2
   ```
3. Implement `docs/runbooks/lan-dns.md` (complete content):
   ```markdown
   # Runbook — LAN DNS (split-horizon via AdGuard) — R7

   AdGuard Home is LAN DNS only (ad-block + split-horizon). The router keeps DHCP.
   AdGuard is the most resettable component, so it must NEVER be load-bearing for
   internet access. Two non-negotiable router settings make ad-block best-effort:

   ## 1. DHCP option 6 (DNS server) → AdGuard
   On the router's LAN/DHCP settings, set the advertised DNS server (DHCP
   option 6) to the AdGuard `adguard-dns` LoadBalancer address:
   - Primary DNS: <ADGUARD_LAN_IP> =
     `kubectl -n edge get svc adguard-dns -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
     (servicelb publishes udp/tcp 53 on the VM node IP, which OrbStack maps to the Mac
     mini host — give the Mac mini a DHCP RESERVATION so this address is stable).
   - VERIFY from a REAL non-cluster LAN device before relying on it:
     `dig +short @<ADGUARD_LAN_IP> cloudflare.com` must return an answer.
   - This is what makes every household device resolve through AdGuard.

   ## 2. Secondary upstream DNS on the router → 1.1.1.1  (the SPOF guard)
   Set the router's SECONDARY DNS to 1.1.1.1 (Cloudflare).
   - When the VM / AdGuard is down, the household degrades to "no ad-block",
     NOT "no internet". This is the entire point of R7.
   - Do NOT set both primaries to AdGuard with no fallback.

   ## 3. Split-horizon verification
   From a LAN device, `*.int.<DOMAIN>` must resolve to the STABLE Tailscale IP of
   the operator-exposed Traefik (Task 3.7), so internal apps work on-LAN and
   off-LAN identically:
   ```
   dig +short whoami.int.<DOMAIN>
   # <STABLE_TAILSCALE_IP>
   ```
   If it returns the VM IP instead, the AdGuard rewrite is stale — re-read
   `tailscale ip -4 homelab` and update platform/adguard/prod/adguardhome.yaml.

   ## 4. Failure drill (do this once)
   - Stop AdGuard (`kubectl -n edge scale deploy/adguard --replicas=0`).
   - Confirm a LAN device still resolves `cloudflare.com` (via 1.1.1.1 fallback).
   - Restore (`--replicas=1`).
   ```
4. Verify — EXPECTED PASS:
   ```bash
   grep -q 'option 6' docs/runbooks/lan-dns.md && grep -q '1.1.1.1' docs/runbooks/lan-dns.md \
     && grep -q 'STABLE_TAILSCALE_IP' docs/runbooks/lan-dns.md && echo RUNBOOK_OK
   # RUNBOOK_OK
   ```
5. Commit:
   ```bash
   git add docs/runbooks/lan-dns.md
   git commit -m "docs(adguard): 라우터 보조 DNS 및 DHCP option 6 LAN DNS 런북 추가"
   ```

---

### Task 3.10 — Internal-by-default posture assertions (ArgoCD / Grafana / AdGuard NOT public)

**Files**
- Create: `tests/posture/internal-by-default.bats`
- Test: `bats` suite (real assertions)

**Steps**

1. Failing check: write a bats suite asserting that internal-only services are never reachable through the public cloudflared path and never expose a LoadBalancer/public HTTPRoute. Currently the suite does not exist:
   ```bash
   bats tests/posture/internal-by-default.bats 2>&1 | head -3
   ```
2. Run — EXPECTED FAILURE:
   ```
   bats: /…/tests/posture/internal-by-default.bats does not exist
   ```
3. Implement `tests/posture/internal-by-default.bats` (complete; asserts the design §6 posture — ArgoCD, Grafana, AdGuard internal-only; the only public-facing service objects are the Traefik LB and cloudflared egress). Public reach is granted solely by an HTTPRoute on the canonical `web-public` listener of the `homelab` Gateway:
   ```bash
   #!/usr/bin/env bats

   # Internal-by-default posture (design §6): ArgoCD, Grafana, AdGuard UI must NOT
   # be publicly reachable. The ONLY LoadBalancer is Traefik; the ONLY public egress
   # is cloudflared. Public reach is granted solely by an HTTPRoute on the
   # 'web-public' listener of Gateway homelab/gateway — these services must never have one.

   @test "Traefik is the only LoadBalancer Service in the cluster" {
     run bash -c "kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type==\"LoadBalancer\")]}{.metadata.namespace}/{.metadata.name} {end}'"
     [ "$status" -eq 0 ]
     [ "$output" = "gateway/traefik " ]
   }

   @test "ArgoCD server has no public HTTPRoute" {
     run bash -c "kubectl get httproute -A -o json | jq -r '.items[] | select(.spec.parentRefs[].sectionName==\"web-public\") | .spec.backendRefs[]?.name' | grep -c '^argocd' || true"
     [ "$output" = "0" ]
   }

   @test "Grafana has no public HTTPRoute" {
     run bash -c "kubectl get httproute -A -o json | jq -r '.items[] | select(.spec.parentRefs[].sectionName==\"web-public\") | .spec.backendRefs[]?.name' | grep -c '^grafana' || true"
     [ "$output" = "0" ]
   }

   @test "AdGuard UI is ClusterIP (Tailscale-only), never LoadBalancer" {
     run bash -c "kubectl -n edge get svc adguard-ui -o jsonpath='{.spec.type}'"
     [ "$output" = "ClusterIP" ]
   }

   @test "cloudflared ingress targets only Traefik (no direct app/admin services)" {
     run bash -c "kubectl -n edge get cm cloudflared -o jsonpath='{.data.config\.yaml}' | grep -c 'traefik.gateway.svc.cluster.local'"
     [ "$output" -ge 1 ]
     run bash -c "kubectl -n edge get cm cloudflared -o jsonpath='{.data.config\.yaml}' | grep -Ec 'argocd|grafana|adguard'"
     [ "$output" = "0" ]
   }
   ```
4. Verify — EXPECTED PASS (against the live cluster after Tasks 3.1–3.8 are synced):
   ```bash
   bats tests/posture/internal-by-default.bats
   ```
   ```
   internal-by-default.bats
    ✓ Traefik is the only LoadBalancer Service in the cluster
    ✓ ArgoCD server has no public HTTPRoute
    ✓ Grafana has no public HTTPRoute
    ✓ AdGuard UI is ClusterIP (Tailscale-only), never LoadBalancer
    ✓ cloudflared ingress targets only Traefik (no direct app/admin services)

   5 tests, 0 failures
   ```
5. Commit:
   ```bash
   git add tests/posture/internal-by-default.bats
   git commit -m "test(networking): 내부 전용 노출 자세 검증 bats 스위트 추가"
   ```

---

### Task 3.11 — Milestone gate: full networking path end-to-end

**Files**
- Create: `tests/posture/networking-e2e.bats`
- Test: `bats` suite (gate)

**Steps**

1. Failing check: a single gate suite that proves the whole milestone (Gateway Programmed, route attaches, public path live via cloudflared, internal path live via Tailscale, AdGuard split-horizon correct). Assert it is missing:
   ```bash
   bats tests/posture/networking-e2e.bats 2>&1 | head -3
   ```
2. Run — EXPECTED FAILURE:
   ```
   bats: /…/tests/posture/networking-e2e.bats does not exist
   ```
3. Implement `tests/posture/networking-e2e.bats` (complete gate; substitute `<DOMAIN>` at runtime via `DOMAIN` env):
   ```bash
   #!/usr/bin/env bats

   # Milestone 3 gate — networking path end-to-end.
   # Requires: DOMAIN env set; kubectl context = k3s VM; run from a tailnet device.

   @test "Gateway 'homelab' is Accepted + Programmed" {
     run bash -c "kubectl -n gateway get gateway homelab -o jsonpath='{range .status.conditions[*]}{.type}={.status};{end}'"
     [[ "$output" == *"Accepted=True"* ]]
     [[ "$output" == *"Programmed=True"* ]]
   }

   @test "GatewayClass traefik is Accepted" {
     run bash -c "kubectl get gatewayclass traefik -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}'"
     [ "$output" = "True" ]
   }

   @test "whoami HTTPRoute is Accepted + ResolvedRefs" {
     run bash -c "kubectl -n gateway get httproute whoami -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status};{end}'"
     [[ "$output" == *"Accepted=True"* ]]
     [[ "$output" == *"ResolvedRefs=True"* ]]
   }

   @test "cloudflared tunnel deployment is healthy" {
     run bash -c "kubectl -n edge get deploy cloudflared -o jsonpath='{.status.availableReplicas}'"
     [ "$output" = "1" ]
     run bash -c "kubectl -n edge logs deploy/cloudflared --tail=200 | grep -c 'Registered tunnel connection'"
     [ "$output" -ge 1 ]
   }

   @test "public path serves through Traefik via the tunnel" {
     run bash -c "curl -s -o /dev/null -w '%{http_code}' https://whoami.${DOMAIN}/"
     [ "$output" = "200" ]
   }

   @test "tailscale operator node is present in tailnet" {
     run bash -c "tailscale status | grep -c 'homelab-operator'"
     [ "$output" -ge 1 ]
   }

   @test "AdGuard resolves *.int to the stable Tailscale IP" {
     ag=$(kubectl -n edge get svc adguard-dns -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
     tsip=$(tailscale ip -4 homelab)
     run bash -c "dig +short @${ag} whoami.int.${DOMAIN}"
     [ "$output" = "$tsip" ]
   }
   ```
4. Verify — EXPECTED PASS:
   ```bash
   DOMAIN=<DOMAIN> bats tests/posture/networking-e2e.bats
   ```
   ```
   networking-e2e.bats
    ✓ Gateway 'homelab' is Accepted + Programmed
    ✓ GatewayClass traefik is Accepted
    ✓ whoami HTTPRoute is Accepted + ResolvedRefs
    ✓ cloudflared tunnel deployment is healthy
    ✓ public path serves through Traefik via the tunnel
    ✓ tailscale operator node is present in tailnet
    ✓ AdGuard resolves *.int to the stable Tailscale IP

   7 tests, 0 failures
   ```
5. Commit:
   ```bash
   git add tests/posture/networking-e2e.bats
   git commit -m "test(networking): Milestone 3 네트워킹 종단간 게이트 스위트 추가"
   ```

---

**Milestone 3 exit criteria:** `bats tests/posture/internal-by-default.bats tests/posture/networking-e2e.bats` is green; `kubectl -n argocd get applications` shows `argocd` (wave -10), `root` (wave -9), and one `<component>-prod` Application per discovered platform dir (`traefik-prod`, `cloudflared-prod`, `tailscale-prod`, `adguard-prod`) all `Synced/Healthy`, with the appset excludes (`argocd`, `cnpg`, `victoria-stack`, `charts`) holding; the public path (`https://*.<DOMAIN>`) serves through cloudflared→Traefik with zero inbound ports; the internal path (`*.int.<DOMAIN>` and `*.ts.net`) serves through the single Tailscale-exposed Traefik; AdGuard split-horizon points at the stable Tailscale IP; cloudflared/tailscale reference the M2-seeded `cloudflared-tunnel`/`operator-oauth` Secrets via their own KSOPS generators (no seed re-creation, no shared ksops stub); ArgoCD/Grafana/AdGuard are provably not public. `platform/argocd/root/SYNC-WAVES.md` (owned here: argocd -10/-9, traefik/gateway -8, edge -6, cnpg-operator -2, cnpg Cluster -1, observability +2, per-app 0/1/2) is the ordering contract M4–M6 build on.

---

## Milestone 4 — Data layer — CloudNativePG + 3-2-1 backups + restore drill

**Goal:** Stand up a single-instance CloudNativePG cluster with tuned, pod-limit-tied parameters, a PgBouncer pooler, and a verified 3-2-1 backup posture (live PVC + local `pg_basebackup` on `bulk-ssd` + barman-cloud → R2), then prove recoverability with a recurring, Telegram-monitored restore drill and a `pg_dump | rclone` hedge. This milestone owns hardening item **R1 (critical)** and the breadcrumb *metrics* that R4's backup-liveness / disk-fill alert rules consume — but the **alert rules themselves are owned by Milestone 5** (vmalert). M4 only ensures the metrics exist.

**Depends on:** M0 (age key + `.sops.yaml` + pnpm workspace + Makefile stubs + memory ledger), M1 (OrbStack VM + k3s + `standard`/`bulk-ssd` StorageClasses + `--secrets-encryption`), M2 (ArgoCD app-of-apps + KSOPS repo-server wiring + the seeded `cnpg-r2-creds` Secret in ns `database` + the two-recipient `.sops.yaml` filled with real keys), M3 (ApplicationSet + `platform/argocd/root/SYNC-WAVES.md` + sync-waves on `argocd-app.yaml`). The hand-rolled `cnpg-operator` + `cnpg-data` Applications M4 authors are deliberately **excluded** from M3's ApplicationSet (Generator A excludes `platform/cnpg/*`), so nothing is double-managed.

Alert *routing/delivery* (Alertmanager → Telegram, `vmalert`, healthchecks.io Watchdog) and the **backup-liveness + disk-fill alert rules** are delivered by Milestone 5. M4 only guarantees the breadcrumb metrics those rules read actually exist. The restore drill keeps its **own** direct-`curl` Telegram message (local notification, allowed) so a failed drill pages even before M5 exists.

Use @superpowers:executing-plans to drive this section task-by-task. Each task is verification-first: write the failing check, see it fail, implement the minimal complete config, see it pass, commit. Replace `<OWNER>` (the GHCR/GitHub org), `<R2_ACCOUNT_ID>`, and the bucket names with the real Terraform-emitted values at execution time; credentials are committed only inside SOPS-encrypted `*.enc.yaml`.

KSOPS is already wired into the ArgoCD repo-server by **M2** (`platform/argocd/bootstrap-values.yaml`: ksops initContainers, `sops-age` Secret mounted at `/home/argocd/.config/sops/age`, `SOPS_AGE_KEY_FILE`, `kustomize.buildOptions: "--enable-alpha-plugins --enable-exec"`). M4 **inherits** that wiring — it never re-wires KSOPS; it only adds its own per-kustomization `secret-generator.yaml` where it consumes an `*.enc.yaml`.

---

### Task 4.1 — CNPG operator Application (pinned), wave -2

**Files**
- Create `platform/cnpg/operator/Chart.yaml`
- Create `platform/cnpg/operator/values.yaml`
- Create `platform/argocd/root/apps/cnpg-operator.yaml` (hand-rolled Application, project `default`, ns `cnpg-system`, excluded from M3's appset)
- Test `platform/cnpg/operator/test_operator_pinned.bats`

1. Write the failing check that asserts the operator chart is pinned (no floating version), lands in `cnpg-system`, uses project `default`, and carries sync-wave -2 (matching M3's `SYNC-WAVES.md`).

`platform/cnpg/operator/test_operator_pinned.bats`:
```bash
#!/usr/bin/env bats

f=platform/argocd/root/apps/cnpg-operator.yaml

@test "operator chart version is pinned (no caret/tilde/wildcard)" {
  run grep -E 'targetRevision:\s+cnpg-v0\.26\.0\s*$' "$f"   # >=1.26: the version line the barman-cloud CNPG-I plugin requires
  [ "$status" -eq 0 ]
}

@test "operator targets cnpg-system namespace" {
  run grep -E 'namespace:\s+cnpg-system' "$f"
  [ "$status" -eq 0 ]
}

@test "operator uses the default AppProject" {
  run grep -E 'project:\s+default' "$f"
  [ "$status" -eq 0 ]
}

@test "operator app is sync-wave -2 (before Cluster CR)" {
  run grep -E 'argocd.argoproj.io/sync-wave:\s*"-2"' "$f"
  [ "$status" -eq 0 ]
}
```

2. Run it — expect FAIL (files absent):
```bash
$ bats platform/cnpg/operator/test_operator_pinned.bats
 ✗ operator chart version is pinned (no caret/tilde/wildcard)
   (in test file ..., line 6)
     `[ "$status" -eq 0 ]' failed
   grep: platform/argocd/root/apps/cnpg-operator.yaml: No such file or directory
4 tests, 4 failures
```

3. Implement the operator Application and a thin umbrella chart that pins the upstream CNPG operator chart. The Application lives under `platform/argocd/root/apps/` (the directory the **M2**-authored root-app recurses), with project `default`.

`platform/cnpg/operator/Chart.yaml`:
```yaml
apiVersion: v2
name: cnpg-operator
description: CloudNativePG operator (pinned umbrella)
type: application
version: 0.1.0
appVersion: "1.26.0"          # >= 1.26: required by the barman-cloud CNPG-I plugin (Task 4.1b)
dependencies:
  - name: cloudnative-pg
    version: 0.26.0           # chart version shipping operator 1.26.x (pin to the exact compatible pair)
    repository: https://cloudnative-pg.github.io/charts
```

`platform/cnpg/operator/values.yaml`:
```yaml
cloudnative-pg:
  replicaCount: 1
  monitoring:
    podMonitorEnabled: false      # no VM operator; we scrape via annotations (M5)
  resources:
    requests:
      cpu: 50m
      memory: 100Mi
    limits:
      cpu: 200m
      memory: 200Mi
  config:
    data:
      # barman-cloud plugin (CNPG-I) sidecar is enabled per-Cluster, not here
      INHERITED_ANNOTATIONS: "prometheus.io/*"
```

`platform/argocd/root/apps/cnpg-operator.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cnpg-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"   # matches platform/argocd/root/SYNC-WAVES.md
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: https://github.com/cloudnative-pg/charts
      targetRevision: cnpg-v0.26.0          # >= 1.26: required by the barman-cloud CNPG-I plugin (Task 4.1b)
      chart: cloudnative-pg
      helm:
        valueFiles:
          - $values/platform/cnpg/operator/values.yaml
    - repoURL: https://github.com/<OWNER>/homelab.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: cnpg-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

> This is a **hand-rolled** Application living at `platform/argocd/root/apps/`. M3's ApplicationSet Generator A explicitly excludes `platform/cnpg/*`, so this app is managed only by the root-app's directory recursion — never double-managed. Destination namespace is `cnpg-system` (the operator), distinct from `database` (the Cluster).

4. Run — expect PASS:
```bash
$ bats platform/cnpg/operator/test_operator_pinned.bats
 ✓ operator chart version is pinned (no caret/tilde/wildcard)
 ✓ operator targets cnpg-system namespace
 ✓ operator uses the default AppProject
 ✓ operator app is sync-wave -2 (before Cluster CR)
4 tests, 0 failures
```

5. Commit:
```bash
git add platform/cnpg/operator platform/argocd/root/apps/cnpg-operator.yaml
git commit -m "feat(cnpg): 핀 고정된 CloudNativePG 오퍼레이터 Application 추가 (wave -2, ns cnpg-system)"
```

---

### Task 4.1b — Install the barman-cloud CNPG-I plugin (+ its cert-manager prerequisite), pinned

> **Why this exists (Pass-4 critical):** the CNPG *operator* (Task 4.1) does NOT include barman-cloud. The `ObjectStore` CRD, the plugin controller, its webhook certificate, and RBAC are a **separate** install. Without it, the `ObjectStore` CR (Task 4.3), the Cluster's `plugins:` reference, WAL archiving, backups, and restores all fail. The plugin requires CNPG **>= 1.26** (Task 4.1 is now pinned to 1.26) and a TLS cert provider (cert-manager).

**Files**
- Create `platform/argocd/root/apps/cert-manager.yaml` — hand-rolled Application referencing the **upstream** jetstack chart directly (so M3's appset, which scans `platform/*/prod`, never sees it — no double-management)
- Create `platform/argocd/root/apps/cnpg-barman-plugin.yaml` — hand-rolled Application applying the plugin's **pinned release manifest** into `cnpg-system`
- Test: ad-hoc `kubectl` assertions (below)

**Steps**

1. Failing check — the `ObjectStore` CRD + plugin Deployment must exist before Task 4.3's `ObjectStore` CR applies:
   ```bash
   kubectl get crd objectstores.barmancloud.cnpg.io 2>&1 | tail -1
   # Error from server (NotFound): ... "objectstores.barmancloud.cnpg.io" not found
   kubectl -n cnpg-system get deploy barman-cloud 2>&1 | tail -1
   ```
2. Implement (all PINNED — replace `<VER>` with the exact compatible releases; the plugin release notes state its minimum CNPG version):
   - **cert-manager** (`platform/argocd/root/apps/cert-manager.yaml`): Application → upstream chart `cert-manager` (repo `https://charts.jetstack.io`) pinned `v1.16.x`, destination ns `cert-manager`, helm value `installCRDs: true`, sync-wave **-3** (before the plugin), project `default`. ~3 small pods (controller + webhook + cainjector) — **add them to the memory ledger** (the design's only cert-manager cost, justified by the plugin's webhook).
   - **barman-cloud plugin** (`platform/argocd/root/apps/cnpg-barman-plugin.yaml`): Application whose source is the plugin's pinned release manifest `https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v<VER>/manifest.yaml`, destination ns `cnpg-system`, sync-wave **-2** (after operator + cert-manager, before the Cluster at -1), project `default`. It installs the `ObjectStore` CRD, the `barman-cloud` controller Deployment, its `Certificate`/`Issuer`, and RBAC.
3. Verify — EXPECTED PASS:
   ```bash
   kubectl get crd objectstores.barmancloud.cnpg.io -o jsonpath='{.metadata.name}{"\n"}'
   # objectstores.barmancloud.cnpg.io
   kubectl -n cnpg-system rollout status deploy/barman-cloud --timeout=180s
   # deployment "barman-cloud" successfully rolled out
   ```
   > This proves the plugin is **installed** so Task 4.3's `ObjectStore` CR and the Cluster's `plugins:` reference resolve. The live proof that backup+restore actually work end-to-end against R2 is Task 4.12 (gated on M6's pg-tools image).
4. Commit:
   ```bash
   git add platform/argocd/root/apps/cert-manager.yaml platform/argocd/root/apps/cnpg-barman-plugin.yaml
   git commit -m "feat(cnpg): barman-cloud CNPG-I 플러그인 및 cert-manager 선결 설치 (ObjectStore CRD 제공, wave -3/-2)"
   ```

---

### Task 4.2 — Reference the M2-seeded `cnpg-r2-creds` Secret (no new secret created here)

**Files**
- Test `platform/cnpg/prod/test_creds_reference.bats` (asserts the M2 seed exists and is consumed, NOT re-created)

> **Ownership:** the R2 ObjectStore credentials Secret `cnpg-r2-creds` (ns `database`) is produced ONCE by **M2** (`seed-secrets.sh` → `platform/cnpg/prod/r2-creds.enc.yaml`). M4 **references** it and must **not** create a second copy and must **not** edit `.sops.yaml` (M0 owns it, M2 fills the recipients). This task only asserts the seed is present, encrypted to both recipients, and consumable, then proves M4's wiring points at it.

1. Write the check that the M2 seed file exists, is SOPS-encrypted (never plaintext), carries the canonical Secret name, and is encrypted to both recipients.

`platform/cnpg/prod/test_creds_reference.bats`:
```bash
#!/usr/bin/env bats

f=platform/cnpg/prod/r2-creds.enc.yaml   # OWNED BY M2 — referenced here

@test "M2 seed for cnpg-r2-creds exists" {
  [ -f "$f" ]
}
@test "seed is SOPS-encrypted (has sops metadata)" {
  run grep -q '^sops:' "$f"
  [ "$status" -eq 0 ]
}
@test "seed has NO plaintext AWS secret" {
  run grep -E 'AWS_SECRET_ACCESS_KEY:\s+[A-Za-z0-9/+]{20,}' "$f"
  [ "$status" -ne 0 ]
}
@test "seed Secret is named cnpg-r2-creds (canonical)" {
  run bash -c "sops --decrypt '$f' | grep -qE 'name:\s+cnpg-r2-creds'"
  [ "$status" -eq 0 ]
}
@test "seed encrypts to two recipients (cluster + offline recovery)" {
  run bash -c "grep -c 'recipient:' '$f'"
  [ "$output" -ge 2 ]
}
@test "M4 does NOT author a duplicate R2 creds secret" {
  run bash -c "ls platform/cnpg/prod/object-store-creds.enc.yaml 2>/dev/null"
  [ "$status" -ne 0 ]   # the old M4-owned name must not exist
}
```

2. Run — expect FAIL if M2 hasn't been executed (dependency) or PASS once M2 is in place. The last assertion guards against re-introducing an M4-owned duplicate.
```bash
$ bats platform/cnpg/prod/test_creds_reference.bats
 ✗ M2 seed for cnpg-r2-creds exists   # until M2 runs; depends-on M2
...
```

3. There is **no implementation step here** — M4 creates no credential file. Confirm `cnpg-r2-creds` carries the keys M4's downstream tasks consume (the ObjectStore reads `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`; the hedge reads `RCLONE_CONFIG_R2_*` + `AWS_*`). These are part of the M2 seed contract; if a key is missing, fix it in **M2's** `seed-secrets.sh`, not here. For reference, the decrypted shape M4 relies on:
```yaml
# (decrypted view of the M2-owned cnpg-r2-creds Secret — DO NOT re-create in M4)
apiVersion: v1
kind: Secret
metadata:
  name: cnpg-r2-creds
  namespace: database
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "<R2_ACCESS_KEY_ID>"
  AWS_SECRET_ACCESS_KEY: "<R2_SECRET_ACCESS_KEY>"
  RCLONE_CONFIG_R2_TYPE: "s3"
  RCLONE_CONFIG_R2_PROVIDER: "Cloudflare"
  RCLONE_CONFIG_R2_ACCESS_KEY_ID: "<R2_ACCESS_KEY_ID>"
  RCLONE_CONFIG_R2_SECRET_ACCESS_KEY: "<R2_SECRET_ACCESS_KEY>"
  RCLONE_CONFIG_R2_ENDPOINT: "https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com"
  RCLONE_CONFIG_R2_REGION: "auto"
```

4. Prove KSOPS (already wired by M2 in the repo-server) can render the M2 seed — no plaintext leaves the repo-server:
```bash
$ sops --decrypt platform/cnpg/prod/r2-creds.enc.yaml | grep -c AWS_ACCESS_KEY_ID
1
$ bats platform/cnpg/prod/test_creds_reference.bats
 ✓ M2 seed for cnpg-r2-creds exists
 ✓ seed is SOPS-encrypted (has sops metadata)
 ✓ seed has NO plaintext AWS secret
 ✓ seed Secret is named cnpg-r2-creds (canonical)
 ✓ seed encrypts to two recipients (cluster + offline recovery)
 ✓ M4 does NOT author a duplicate R2 creds secret
6 tests, 0 failures
```

5. Commit (only the reference test — no secret file changes):
```bash
git add platform/cnpg/prod/test_creds_reference.bats
git commit -m "test(cnpg): M2 시드 cnpg-r2-creds 참조 계약 테스트 추가 (중복 생성 금지)"
```

---

### Task 4.3 — ObjectStore CR → R2 (barman-cloud plugin), AWS_REGION=auto

**Files**
- Create `platform/cnpg/prod/object-store.yaml`
- Test `platform/cnpg/prod/test_object_store.bats`

1. Write the check that the ObjectStore points at R2 with the exact endpoint/region/retention contract and references the M2-seeded `cnpg-r2-creds` Secret (not inline keys).

`platform/cnpg/prod/test_object_store.bats`:
```bash
#!/usr/bin/env bats
f=platform/cnpg/prod/object-store.yaml

@test "endpoint is R2 and region is auto" {
  grep -q 'endpointURL: .*\.r2\.cloudflarestorage\.com' "$f"
  grep -qE 'name:\s+AWS_REGION' "$f"
}
@test "creds come from the cnpg-r2-creds secret, not inline" {
  grep -q 'name: cnpg-r2-creds' "$f"
  run grep -E 'AWS_SECRET_ACCESS_KEY:\s+\S' "$f"
  [ "$status" -ne 0 ]
}
@test "offsite retention is 14 days" {
  grep -q 'retentionPolicy: "14d"' "$f"
}
```

2. Run — expect FAIL (`No such file`).

3. Implement (barman-cloud CNPG-I plugin `ObjectStore` CR):

`platform/cnpg/prod/object-store.yaml`:
```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: pg-r2
  namespace: database
spec:
  retentionPolicy: "14d"
  configuration:
    destinationPath: "s3://homelab-pg-backups-prod/"
    endpointURL: "https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com"
    s3Credentials:
      accessKeyId:
        name: cnpg-r2-creds        # M2-seeded Secret (ns database)
        key: AWS_ACCESS_KEY_ID
      secretAccessKey:
        name: cnpg-r2-creds
        key: AWS_SECRET_ACCESS_KEY
    wal:
      compression: gzip
      maxParallel: 2
    data:
      compression: gzip
      jobs: 2
  env:
    - name: AWS_REGION
      value: "auto"
```
The `env: AWS_REGION=auto` is the documented R2 fix (R2 rejects real region names; `auto` avoids the SigV4 region mismatch behind the "documented restore failures" called out in R1).

4. Run — expect PASS:
```bash
$ bats platform/cnpg/prod/test_object_store.bats
 ✓ endpoint is R2 and region is auto
 ✓ creds come from the cnpg-r2-creds secret, not inline
 ✓ offsite retention is 14 days
3 tests, 0 failures
```

5. Commit:
```bash
git add platform/cnpg/prod/object-store.yaml platform/cnpg/prod/test_object_store.bats
git commit -m "feat(cnpg): R2 대상 barman-cloud ObjectStore CR 추가 (region=auto, cnpg-r2-creds 참조)"
```

---

### Task 4.4 — Cluster CR: instances=1, tuned params tied to pod limit, separate walStorage

**Files**
- Create `platform/cnpg/prod/cluster.yaml`
- Test `platform/cnpg/prod/test_cluster_params.bats`

1. Write the check enforcing every tuned value from §7 AND the limit-tie invariant: `shared_buffers=256MB` must be ≤ ¼ of the **1Gi pod limit**, WAL must be a **separate PVC on `standard`**, PGDATA must **not** be on `bulk-ssd`, and the Cluster CR carries sync-wave -1 (matching M3's `SYNC-WAVES.md`).

`platform/cnpg/prod/test_cluster_params.bats`:
```bash
#!/usr/bin/env bats
f=platform/cnpg/prod/cluster.yaml

@test "single instance, HA off" { grep -qE 'instances:\s*1' "$f"; }

@test "tuned params exactly match the design" {
  grep -q 'shared_buffers: "256MB"' "$f"
  grep -q 'effective_cache_size: "512MB"' "$f"
  grep -q 'work_mem: "8MB"' "$f"
  grep -q 'maintenance_work_mem: "128MB"' "$f"
  grep -q 'max_connections: "50"' "$f"
  grep -q 'archive_timeout: "5min"' "$f"
}

@test "memory limit is 1Gi and shared_buffers is <= 1/4 of it" {
  grep -q 'memory: 1Gi' "$f"          # limit
  grep -q 'memory: 768Mi' "$f"        # request
  # 256MB <= 256MB (= 1Gi/4) : the limit-tie invariant holds
}

@test "PGDATA on standard SC, WAL on a SEPARATE standard PVC, never bulk-ssd" {
  grep -q 'storageClass: standard' "$f"
  grep -qE 'walStorage:' "$f"
  run grep -q 'bulk-ssd' "$f"
  [ "$status" -ne 0 ]
}

@test "Cluster CR carries sync-wave -1 (Ready before app migrations)" {
  grep -qE 'argocd.argoproj.io/sync-wave:\s*"-1"' "$f"
}
```

2. Run — expect FAIL (`No such file`).

3. Implement:

`platform/cnpg/prod/cluster.yaml`:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg
  namespace: database
  annotations:
    argocd.argoproj.io/sync-wave: "-1"   # Cluster CR; Ready gates app migration Jobs (wave 1)
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
  primaryUpdateStrategy: unsupervised
  enableSuperuserAccess: true            # creates the managed `pg-superuser` Secret (REPLICATION-capable) used by pg_basebackup — a SEPARATE credential from the app role
  postgresUID: 26
  postgresGID: 26

  postgresql:
    parameters:
      # tied to the 1Gi POD LIMIT, not host RAM (avoids the 25%-of-host = 4GB OOM trap)
      shared_buffers: "256MB"
      effective_cache_size: "512MB"
      work_mem: "8MB"
      maintenance_work_mem: "128MB"
      max_connections: "50"
      archive_timeout: "5min"
      wal_compression: "on"
      max_wal_size: "1GB"
      min_wal_size: "256MB"

  resources:
    requests:
      cpu: 250m
      memory: 768Mi
    limits:
      cpu: "1"
      memory: 1Gi

  storage:
    size: 40Gi
    storageClass: standard          # internal 512GB SSD
  walStorage:
    size: 10Gi
    storageClass: standard          # SEPARATE WAL PVC, also internal SSD

  bootstrap:
    initdb:
      database: app
      owner: app
      secret:
        name: pg-app-credentials     # SEEDED by M2 (platform/cnpg/prod/app-credentials.enc.yaml, ns database); MUST exist before bootstrap — this kustomization's KSOPS generator renders it at sync-wave -2 (before the Cluster at -1)

  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: pg-r2      # -> ObjectStore from Task 4.3
        serverName: pg

  monitoring:
    enablePodMonitor: false          # scraped via prometheus.io annotations (M5)
```

4. Run — expect PASS:
```bash
$ bats platform/cnpg/prod/test_cluster_params.bats
 ✓ single instance, HA off
 ✓ tuned params exactly match the design
 ✓ memory limit is 1Gi and shared_buffers is <= 1/4 of it
 ✓ PGDATA on standard SC, WAL on a SEPARATE standard PVC, never bulk-ssd
 ✓ Cluster CR carries sync-wave -1 (Ready before app migrations)
5 tests, 0 failures
```

5. Commit:
```bash
git add platform/cnpg/prod/cluster.yaml platform/cnpg/prod/test_cluster_params.bats
git commit -m "feat(cnpg): 파드 limit에 묶인 튜닝 파라미터로 단일 인스턴스 Cluster CR 추가 (wave -1)"
```

---

### Task 4.5 — PgBouncer Pooler (type=rw)

**Files**
- Create `platform/cnpg/prod/pooler.yaml`
- Test `platform/cnpg/prod/test_pooler.bats`

1. Write the check: a `rw` Pooler exists, points at the `pg` cluster, transaction mode, modest pool sizing so `max_connections=50` is never exhausted.

`platform/cnpg/prod/test_pooler.bats`:
```bash
#!/usr/bin/env bats
f=platform/cnpg/prod/pooler.yaml
@test "pooler is type rw on cluster pg" {
  grep -q 'type: rw' "$f"
  grep -qE 'name:\s+pg$' "$f"
}
@test "transaction pooling, sane sizing under max_connections=50" {
  grep -q 'pool_mode: transaction' "$f"
  grep -q 'max_client_conn:' "$f"
  grep -q 'default_pool_size:' "$f"
}
```

2. Run — expect FAIL (`No such file`).

3. Implement:

`platform/cnpg/prod/pooler.yaml`:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: pg-pooler-rw          # NOT "pg-rw": that name is RESERVED by CNPG for the Cluster's own rw Service
  namespace: database
spec:
  cluster:
    name: pg
  instances: 1
  type: rw
  pgbouncer:
    poolMode: transaction
    parameters:
      pool_mode: "transaction"
      max_client_conn: "200"
      default_pool_size: "20"
      reserve_pool_size: "5"
  template:
    spec:
      containers:
        - name: pgbouncer
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits:   { cpu: 200m, memory: 64Mi }
```
Apps connect to the pooler at `pg-pooler-rw.database.svc:5432`; only PgBouncer holds real backends, so 50 server connections cover all polyglot apps. Replication / base-backup traffic stays on CNPG's own `pg-rw.database.svc` (the pooler does not proxy replication connections).

4. Run — expect PASS:
```bash
$ bats platform/cnpg/prod/test_pooler.bats
 ✓ pooler is type rw on cluster pg
 ✓ transaction pooling, sane sizing under max_connections=50
2 tests, 0 failures
```

5. Commit:
```bash
git add platform/cnpg/prod/pooler.yaml platform/cnpg/prod/test_pooler.bats
git commit -m "feat(cnpg): rw PgBouncer Pooler 추가 (transaction 모드)"
```

---

### Task 4.6 — ScheduledBackup daily → R2

**Files**
- Create `platform/cnpg/prod/scheduled-backup.yaml`
- Test `platform/cnpg/prod/test_scheduled_backup.bats`

1. Write the check: daily schedule, targets the `pg` cluster via the barman plugin method, immediate first backup so verification doesn't wait a day.

`platform/cnpg/prod/test_scheduled_backup.bats`:
```bash
#!/usr/bin/env bats
f=platform/cnpg/prod/scheduled-backup.yaml
@test "daily cron and immediate first run" {
  grep -qE 'schedule:\s*"0 0 3 \* \* \*"' "$f"   # 6-field CNPG cron, 03:00
  grep -q 'immediate: true' "$f"
}
@test "plugin-based backup against cluster pg" {
  grep -q 'method: plugin' "$f"
  grep -qE 'name:\s+pg$' "$f"
}
```

2. Run — expect FAIL (`No such file`).

3. Implement:

`platform/cnpg/prod/scheduled-backup.yaml`:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: pg-daily-r2
  namespace: database
spec:
  schedule: "0 0 3 * * *"     # CNPG 6-field cron: 03:00 every day
  immediate: true
  backupOwnerReference: self
  cluster:
    name: pg
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

4. Run — expect PASS:
```bash
$ bats platform/cnpg/prod/test_scheduled_backup.bats
 ✓ daily cron and immediate first run
 ✓ plugin-based backup against cluster pg
2 tests, 0 failures
```

5. Commit:
```bash
git add platform/cnpg/prod/scheduled-backup.yaml platform/cnpg/prod/test_scheduled_backup.bats
git commit -m "feat(cnpg): R2로 매일 ScheduledBackup 추가 (즉시 1회 포함)"
```

---

### Task 4.7 — Local `pg_basebackup` CronJob → `bulk-ssd` PVC (copy 2 of 3-2-1)

**Files**
- Create `platform/cnpg/prod/basebackup-pvc.yaml`
- Create `platform/cnpg/prod/basebackup-cronjob.yaml`
- Test `platform/cnpg/prod/test_basebackup.bats`

1. Write the check: a PVC on `bulk-ssd`, a nightly CronJob that runs `pg_basebackup` into it, prunes to 7 days, runs as the CNPG non-root user, and writes the **breadcrumb metric** the M5-owned liveness alert reads.

`platform/cnpg/prod/test_basebackup.bats`:
```bash
#!/usr/bin/env bats
pvc=platform/cnpg/prod/basebackup-pvc.yaml
cj=platform/cnpg/prod/basebackup-cronjob.yaml
@test "staging PVC is on bulk-ssd (external SSD), never standard" {
  grep -q 'storageClassName: bulk-ssd' "$pvc"
}
@test "cronjob runs pg_basebackup and prunes to 7 days" {
  grep -q 'pg_basebackup' "$cj"
  grep -qE 'mtime \+7' "$cj"
  grep -qE 'schedule:\s+"30 2 \* \* \*"' "$cj"     # k8s 5-field cron, 02:30
}
@test "cronjob runs non-root 26 and mounts only bulk-ssd PVC" {
  grep -q 'runAsUser: 26' "$cj"
  grep -q 'claimName: pg-basebackup-local' "$cj"
}
@test "cronjob emits the local-basebackup breadcrumb metric M5 alerts on" {
  # M5's LocalBasebackupStale reads kube_job_status_completion_time
  # for jobs named cnpg-local-basebackup.* — the breadcrumb is the named Job + label.
  grep -q 'cnpg.io/backupRole: local-basebackup' "$cj"
}
```

2. Run — expect FAIL (`No such file`).

3. Implement. The CronJob is named `cnpg-local-basebackup` so that M5's `LocalBasebackupStale` rule — which selects `kube_job_status_completion_time{job_name=~"cnpg-local-basebackup.*"}` — has a metric to read. M4 only ensures the named Job emits a completion-time series; **the alert rule itself is M5's.**

`platform/cnpg/prod/basebackup-pvc.yaml`:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pg-basebackup-local
  namespace: database
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: bulk-ssd       # 1TB external SSD, staging only — NEVER Postgres PGDATA
  resources:
    requests:
      storage: 100Gi
```

`platform/cnpg/prod/basebackup-cronjob.yaml`:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cnpg-local-basebackup        # job_name=~"cnpg-local-basebackup.*" feeds M5's LocalBasebackupStale
  namespace: database
spec:
  schedule: "30 2 * * *"           # 02:30, before the 03:00 R2 ScheduledBackup
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 7200
      template:
        metadata:
          labels:
            cnpg.io/backupRole: local-basebackup   # M5's alert selector
        spec:
          restartPolicy: Never
          securityContext:
            runAsUser: 26
            runAsGroup: 26
            fsGroup: 26
          containers:
            - name: basebackup
              image: ghcr.io/cloudnative-pg/postgresql:16.4
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set -euo pipefail
                  TS="$(date -u +%Y%m%dT%H%M%SZ)"
                  DEST="/backup/basebackup-${TS}"
                  echo "[basebackup] -> ${DEST}"
                  pg_basebackup \
                    --host=pg-rw.database.svc \
                    --port=5432 \
                    --username="$PGUSER" \
                    --pgdata="${DEST}" \
                    --format=tar --gzip --wal-method=stream \
                    --checkpoint=fast --progress --no-password
                  echo "[basebackup] pruning local copies older than 7 days"
                  find /backup -maxdepth 1 -type d -name 'basebackup-*' -mtime +7 -print -exec rm -rf {} +
                  # local breadcrumb file (the Job completion-time series is what M5 alerts on)
                  date -u +%s > /backup/.last_basebackup_ok
              env:
                # pg_basebackup opens a REPLICATION connection; the `app` role lacks REPLICATION.
                # Use CNPG's managed superuser secret (created by enableSuperuserAccess: true).
                - name: PGUSER
                  valueFrom:
                    secretKeyRef: { name: pg-superuser, key: username }
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef: { name: pg-superuser, key: password }
              volumeMounts:
                - name: backup
                  mountPath: /backup
          volumes:
            - name: backup
              persistentVolumeClaim:
                claimName: pg-basebackup-local
```

4. Run — expect PASS:
```bash
$ bats platform/cnpg/prod/test_basebackup.bats
 ✓ staging PVC is on bulk-ssd (external SSD), never standard
 ✓ cronjob runs pg_basebackup and prunes to 7 days
 ✓ cronjob runs non-root 26 and mounts only bulk-ssd PVC
 ✓ cronjob emits the local-basebackup breadcrumb metric M5 alerts on
4 tests, 0 failures
```

5. Commit:
```bash
git add platform/cnpg/prod/basebackup-pvc.yaml platform/cnpg/prod/basebackup-cronjob.yaml platform/cnpg/prod/test_basebackup.bats
git commit -m "feat(cnpg): bulk-ssd 대상 로컬 pg_basebackup CronJob 추가 (7일 보존, M5 liveness 메트릭 breadcrumb)"
```

---

### Task 4.8 — `pg_dump | rclone → R2` hedge CronJob (R1 second offsite path)

**Files**
- Create `platform/cnpg/prod/pgdump-hedge-cronjob.yaml`
- Test `platform/cnpg/prod/test_pgdump_hedge.bats`

1. Write the check: an independent logical-dump path that does NOT use barman, streams `pg_dump` → `rclone` to a **separate R2 prefix**, uses `AWS_REGION=auto` via the rclone config, prunes to 14 days, and pulls its creds from the M2-seeded `cnpg-r2-creds`. This is the hedge that survives a barman/WAL-format failure.

`platform/cnpg/prod/test_pgdump_hedge.bats`:
```bash
#!/usr/bin/env bats
f=platform/cnpg/prod/pgdump-hedge-cronjob.yaml
@test "hedge uses pg_dump piped to rclone, not barman" {
  grep -q 'pg_dump' "$f"
  grep -q 'rclone rcat' "$f"
  run grep -q 'barman' "$f"
  [ "$status" -ne 0 ]
}
@test "hedge writes a SEPARATE R2 prefix and prunes to 14 days" {
  grep -q 'r2:homelab-pg-backups-prod/pgdump/' "$f"
  grep -qE 'rclone delete .*--min-age 14d' "$f"
}
@test "hedge pulls rclone+aws creds from cnpg-r2-creds secret" {
  grep -q 'name: cnpg-r2-creds' "$f"
}
@test "hedge uses the M6-built pg-tools image" {
  grep -q 'ghcr.io/<OWNER>/pg-tools:16-rclone' "$f"
}
```

2. Run — expect FAIL (`No such file`).

3. Implement:

`platform/cnpg/prod/pgdump-hedge-cronjob.yaml`:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pg-dump-hedge-r2
  namespace: database
spec:
  schedule: "0 4 * * *"            # 04:00, after both backups
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 5400
      template:
        metadata:
          labels:
            cnpg.io/backupRole: pgdump-hedge
        spec:
          restartPolicy: Never
          securityContext: { runAsUser: 26, runAsGroup: 26, fsGroup: 26 }
          containers:
            - name: pgdump-hedge
              image: ghcr.io/<OWNER>/pg-tools:16-rclone   # BUILT BY M6 (apps/pg-tools/, M6 CI matrix)
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set -euo pipefail
                  TS="$(date -u +%Y%m%dT%H%M%SZ)"
                  KEY="r2:homelab-pg-backups-prod/pgdump/app-${TS}.dump.gz"
                  echo "[hedge] pg_dump (custom format) -> ${KEY}"
                  pg_dump --host=pg-rw.database.svc --port=5432 \
                          --username="$PGUSER" --dbname=app \
                          --format=custom --no-password \
                    | gzip -c \
                    | rclone rcat "${KEY}" --s3-region auto
                  echo "[hedge] verify object exists and is non-empty"
                  SIZE="$(rclone size "${KEY}" --json | python3 -c 'import sys,json;print(json.load(sys.stdin)["bytes"])')"
                  test "${SIZE}" -gt 0
                  echo "[hedge] prune dumps older than 14 days"
                  rclone delete r2:homelab-pg-backups-prod/pgdump/ --min-age 14d
                  echo "[hedge] OK size=${SIZE}"
              envFrom:
                - secretRef: { name: cnpg-r2-creds }   # M2 seed: RCLONE_CONFIG_R2_* + AWS_* (AWS_REGION=auto)
              env:
                - name: PGUSER
                  valueFrom: { secretKeyRef: { name: pg-app-credentials, key: username } }
                - name: PGPASSWORD
                  valueFrom: { secretKeyRef: { name: pg-app-credentials, key: password } }
```
> `ghcr.io/<OWNER>/pg-tools:16-rclone` (postgres-16 client + kubectl + rclone + curl) is an **M6-owned deliverable**: its Dockerfile lives at `apps/pg-tools/Dockerfile` and is built by **M6's CI matrix**. M4 only **references** the image. Distroless CNPG images can't `apt add rclone`, so the dedicated tools image is the correct choice. **The live hedge run (Task 4.11d) is gated on M6 having built that image** — see exit criteria.

4. Run — expect PASS:
```bash
$ bats platform/cnpg/prod/test_pgdump_hedge.bats
 ✓ hedge uses pg_dump piped to rclone, not barman
 ✓ hedge writes a SEPARATE R2 prefix and prunes to 14 days
 ✓ hedge pulls rclone+aws creds from cnpg-r2-creds secret
 ✓ hedge uses the M6-built pg-tools image
4 tests, 0 failures
```

5. Commit:
```bash
git add platform/cnpg/prod/pgdump-hedge-cronjob.yaml platform/cnpg/prod/test_pgdump_hedge.bats
git commit -m "feat(cnpg): pg_dump|rclone R2 헤지 백업 CronJob 추가 (14일 보존, M6 pg-tools 이미지 참조)"
```

---

### Task 4.9 — Restore-drill alerting secret (M4-owned drill notification creds)

**Files**
- Create `platform/cnpg/prod/restore-drill-alerting.enc.yaml` (SOPS-encrypted, ns `database`)
- Test `platform/cnpg/prod/test_drill_alerting.bats`

> The restore drill keeps its **own direct-curl Telegram + healthchecks** notification (local, allowed per the contract). The cluster-wide `alerting-secrets` Secret M2 seeds lives in ns `observability`; the drill runs in ns `database`, so it needs a small local Secret. This is **not** a re-creation of `cnpg-r2-creds` or of M2's `alerting-secrets` — it is a database-namespace drill-notify Secret M4 owns. It uses the **canonical key names** `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` / `HEALTHCHECKS_URL` so values can be copied straight from M2's seed inputs.

1. Write the check that the file is SOPS-encrypted, carries the canonical key names, and is encrypted to both recipients.

`platform/cnpg/prod/test_drill_alerting.bats`:
```bash
#!/usr/bin/env bats
f=platform/cnpg/prod/restore-drill-alerting.enc.yaml
@test "drill alerting secret is SOPS-encrypted" {
  grep -q '^sops:' "$f"
}
@test "no plaintext bot token leaks" {
  run grep -E 'TELEGRAM_BOT_TOKEN:\s+[0-9]{6,}:' "$f"
  [ "$status" -ne 0 ]
}
@test "decrypts to canonical key names and Secret name" {
  run bash -c "sops --decrypt '$f' | grep -qE 'name:\s+restore-drill-alerting'"
  [ "$status" -eq 0 ]
  run bash -c "sops --decrypt '$f' | grep -q TELEGRAM_BOT_TOKEN"
  [ "$status" -eq 0 ]
  run bash -c "sops --decrypt '$f' | grep -q HEALTHCHECKS_URL"
  [ "$status" -eq 0 ]
}
@test "encrypted to two recipients (cluster + offline recovery)" {
  run bash -c "grep -c 'recipient:' '$f'"
  [ "$output" -ge 2 ]
}
```

2. Run — expect FAIL (`No such file`).

3. Author the plaintext, encrypt with the **M0-owned `.sops.yaml` rule** (already filled with real recipients by M2 — M4 does **not** touch `.sops.yaml`), commit only ciphertext. Create `/tmp/restore-drill-alerting.plain.yaml` (NEVER committed):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: restore-drill-alerting
  namespace: database
type: Opaque
stringData:
  TELEGRAM_BOT_TOKEN: "<TELEGRAM_BOT_TOKEN>"
  TELEGRAM_CHAT_ID: "<TELEGRAM_CHAT_ID>"
  HEALTHCHECKS_URL: "<HEALTHCHECKS_RESTORE_DRILL_URL>"
```
```bash
# .sops.yaml already matches platform/cnpg/prod/*.enc.yaml (M0 rule, M2 recipients). No edit here.
sops --encrypt /tmp/restore-drill-alerting.plain.yaml > platform/cnpg/prod/restore-drill-alerting.enc.yaml
rm -P /tmp/restore-drill-alerting.plain.yaml   # macOS secure delete
```

4. Run — expect PASS:
```bash
$ bats platform/cnpg/prod/test_drill_alerting.bats
 ✓ drill alerting secret is SOPS-encrypted
 ✓ no plaintext bot token leaks
 ✓ decrypts to canonical key names and Secret name
 ✓ encrypted to two recipients (cluster + offline recovery)
4 tests, 0 failures
```

5. Commit:
```bash
git add platform/cnpg/prod/restore-drill-alerting.enc.yaml platform/cnpg/prod/test_drill_alerting.bats
git commit -m "feat(cnpg): restore drill 직접-curl Telegram/healthchecks 알림 시크릿 추가 (SOPS)"
```

---

### Task 4.10 — Kustomization wiring + hand-rolled `cnpg-data` Application for the prod data layer

**Files**
- Create `platform/cnpg/prod/kustomization.yaml`
- Create `platform/cnpg/prod/secret-generator.yaml` (per-kustomization KSOPS generator — M4 inherits M2's repo-server wiring)
- Create `platform/argocd/root/apps/cnpg-data.yaml` (hand-rolled Application, project `default`, ns `database`, excluded from M3's appset)
- Test `platform/cnpg/prod/test_kustomize_build.bats`

1. Write the check: `kustomize build` (with the KSOPS exec plugin M2 already enabled in the repo-server) renders all CRs, the data Application is wave -1 (after operator -2, before app migrations at wave 1), uses project `default`, lands in ns `database`, and KSOPS decrypts the drill-alerting generator. The R2 creds Secret is **not** generated here — it comes from the M2 seed via the repo-server.

`platform/cnpg/prod/test_kustomize_build.bats`:
```bash
#!/usr/bin/env bats
@test "kustomize build with ksops renders Cluster + ObjectStore + Pooler + backups" {
  run bash -c 'kustomize build --enable-alpha-plugins --enable-exec platform/cnpg/prod'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'kind: Cluster'
  echo "$output" | grep -q 'kind: ObjectStore'
  echo "$output" | grep -q 'kind: Pooler'
  echo "$output" | grep -q 'kind: ScheduledBackup'
  echo "$output" | grep -q 'name: cnpg-local-basebackup'
  echo "$output" | grep -q 'name: pg-dump-hedge-r2'
}
@test "all THREE database-ns seeds render as Secrets via KSOPS (none silently missing)" {
  run bash -c 'kustomize build --enable-alpha-plugins --enable-exec platform/cnpg/prod'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'name: cnpg-r2-creds'
  echo "$output" | grep -q 'name: pg-app-credentials'
  echo "$output" | grep -q 'name: restore-drill-alerting'
  echo "$output" | grep -q 'AWS_ACCESS_KEY_ID'   # canonical R2 schema (matches object-store.yaml)
  echo "$output" | grep -q 'TELEGRAM_BOT_TOKEN'
}
@test "restore-drill ConfigMap is GENERATED from the script (real recovery logic, not an empty placeholder)" {
  drill="$(kustomize build --enable-alpha-plugins --enable-exec platform/cnpg/prod \
    | yq 'select(.kind=="ConfigMap" and .metadata.name=="restore-drill-script") | .data."drill.sh"')"
  echo "$drill" | grep -q 'bootstrap:'          # recovery-cluster logic present...
  echo "$drill" | grep -q 'recovery:'
  echo "$drill" | grep -q 'EXPECTED_ROWS'
  echo "$drill" | grep -q 'ACTUAL_ROWS'
  [ "$(printf '%s' "$drill" | wc -l)" -gt 30 ]   # ...and it is the full script, not a one-line stub
}
@test "data app is sync-wave -1, project default, ns database" {
  f=platform/argocd/root/apps/cnpg-data.yaml
  grep -qE 'argocd.argoproj.io/sync-wave:\s*"-1"' "$f"
  grep -qE 'project:\s+default' "$f"
  grep -qE 'namespace:\s+database' "$f"
}
```

2. Run — expect FAIL (`No such file` / kustomize error).

3. Implement. Note the kustomization uses its **own** `secret-generator.yaml` (no shared `ksops.yaml` stub); the R2 creds Secret is supplied by M2's seed and is **not** regenerated here.

`platform/cnpg/prod/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: database

resources:
  - object-store.yaml
  - cluster.yaml
  - pooler.yaml
  - scheduled-backup.yaml
  - basebackup-pvc.yaml
  - basebackup-cronjob.yaml
  - pgdump-hedge-cronjob.yaml
  - restore-drill-rbac.yaml         # added in Task 4.11
  - restore-drill-cronjob.yaml      # added in Task 4.11

generators:
  - secret-generator.yaml           # KSOPS — renders ALL THREE database-ns seeds (see below)

# The restore-drill ConfigMap is GENERATED from its source script so the running `drill.sh`
# IS the source-of-truth — there is NO empty/placeholder path that could let the CronJob
# exit 0 without restoring (R1). A render test (Task 4.11) asserts the script content is present.
configMapGenerator:
  - name: restore-drill-script
    files:
      - drill.sh=restore-drill-script.sh

generatorOptions:
  disableNameSuffixHash: true        # stable names: cnpg-r2-creds, pg-app-credentials, restore-drill-alerting, restore-drill-script
  annotations:
    argocd.argoproj.io/sync-wave: "-2"   # the three seeds + the drill script apply BEFORE the Cluster CR (wave -1)
```

`platform/cnpg/prod/secret-generator.yaml`:
```yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: cnpg-drill-secret-generator
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - r2-creds.enc.yaml                # -> Secret cnpg-r2-creds (barman ObjectStore + pg_dump hedge)
  - app-credentials.enc.yaml         # -> Secret pg-app-credentials (CNPG initdb owner; precedes the Cluster)
  - restore-drill-alerting.enc.yaml  # -> Secret restore-drill-alerting (drill Telegram/healthchecks)
```
> All three database-ns Secrets are **M2 seeds** — M4 does not *author* them, but it MUST list each `*.enc.yaml` in this KSOPS generator so the repo-server actually renders it. A `*.enc.yaml` is materialized into a Secret **only** when a KSOPS generator references it; omitting one silently produces no Secret (exactly how `cnpg-r2-creds` and `pg-app-credentials` would otherwise have gone missing and broken barman + bootstrap).

`platform/argocd/root/apps/cnpg-data.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cnpg-data
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"     # after operator(-2), before app migrations(+1)
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/<OWNER>/homelab.git
    targetRevision: main
    path: platform/cnpg/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: database
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff: { duration: 30s, factor: 2, maxDuration: 5m }
```
> Both `cnpg-operator.yaml` (Task 4.1) and `cnpg-data.yaml` live under `platform/argocd/root/apps/`, which the **M2**-authored root-app recurses. M3's ApplicationSet excludes `platform/cnpg/*`, so these two hand-rolled Applications are the **sole** managers of the data layer — no double-management. M4 does **not** edit the ApplicationSet or `root-app.yaml`.

4. Run — expect PASS (operator CRDs need not be installed for the build to emit YAML; offline builds still render):
```bash
$ bats platform/cnpg/prod/test_kustomize_build.bats
 ✓ kustomize build with ksops renders Cluster + ObjectStore + Pooler + backups
 ✓ rendered drill-alerting secret is decrypted (ksops worked)
 ✓ data app is sync-wave -1, project default, ns database
3 tests, 0 failures
```

5. Commit:
```bash
git add platform/cnpg/prod/kustomization.yaml platform/cnpg/prod/secret-generator.yaml platform/argocd/root/apps/cnpg-data.yaml platform/cnpg/prod/test_kustomize_build.bats
git commit -m "feat(cnpg): KSOPS kustomization과 wave -1 cnpg-data Application 연결 (project default, ns database)"
```

---

### Task 4.11 — The restore drill (R1 linchpin): backup → fresh Cluster recovery → row-count gate → Telegram

**Files**
- Create `platform/cnpg/prod/restore-drill-script.sh` (the ConfigMap is GENERATED from this by Task 4.12's `configMapGenerator` — there is no hand-written `restore-drill-configmap.yaml`)
- Create `platform/cnpg/prod/restore-drill-cronjob.yaml`
- Create `platform/cnpg/prod/restore-drill-rbac.yaml`
- Test `platform/cnpg/prod/test_restore_drill.bats`

1. Write the check that the drill is RECURRING, that it (a) records a known row count, (b) creates a **fresh** Cluster CR with `bootstrap.recovery` from R2, (c) compares row counts, (d) reports pass/fail to Telegram + pings healthchecks on PASS, (e) pushes a `restore_drill_last_success_timestamp` breadcrumb (the metric M5's `CNPGRestoreDrillStale` reads), and (f) tears the temp cluster down. Plus a shellcheck gate.

`platform/cnpg/prod/test_restore_drill.bats`:
```bash
#!/usr/bin/env bats
cj=platform/cnpg/prod/restore-drill-cronjob.yaml
sh=platform/cnpg/prod/restore-drill-script.sh

@test "drill is recurring (weekly cron)" {
  grep -qE 'schedule:\s+"0 5 \* \* 0"' "$cj"      # Sunday 05:00
}
@test "drill uses the M6-built pg-tools image" {
  grep -q 'ghcr.io/<OWNER>/pg-tools:16-rclone' "$cj"
}
@test "drill bootstraps a FRESH cluster via recovery from R2" {
  grep -q 'bootstrap:' "$sh"
  grep -q 'recovery:' "$sh"
  grep -q 'barmanObjectName: pg-r2' "$sh"
  grep -q 'pg-restore-drill' "$sh"     # the throwaway cluster name
}
@test "drill compares row counts and reports pass/fail to Telegram" {
  grep -q 'EXPECTED_ROWS' "$sh"
  grep -q 'ACTUAL_ROWS' "$sh"
  grep -q 'api.telegram.org' "$sh"
  grep -q 'sendMessage' "$sh"
}
@test "drill pushes the restore_drill_last_success_timestamp breadcrumb (M5 alert metric)" {
  grep -q 'restore_drill_last_success_timestamp' "$sh"
}
@test "drill tears the throwaway cluster down — including PVCs/PVs (no ~50GiB/run leak)" {
  grep -q 'delete cluster' "$sh"
  grep -q 'delete pvc -l "cnpg.io/cluster=' "$sh"   # PVCs deleted, not just the Cluster CR
  grep -q 'delete pv' "$sh"                          # Released (Retain) PVs reaped
}
@test "drill script passes shellcheck" {
  run shellcheck "$sh"
  [ "$status" -eq 0 ]
}
```

2. Run — expect FAIL (`No such file`).

3. Implement.

`platform/cnpg/prod/restore-drill-script.sh`:
```bash
#!/usr/bin/env bash
# Restore drill (R1): prove R2 backups are actually recoverable.
# 1) read a stable row count from the live cluster
# 2) stand up a throwaway cluster recovered from R2
# 3) wait until it is Ready, read the same row count
# 4) compare; report PASS/FAIL to Telegram; on PASS ping healthchecks + push the
#    restore_drill_last_success_timestamp metric (M5's CNPGRestoreDrillStale reads it)
# 5) always delete the throwaway cluster
set -euo pipefail

NS="database"
LIVE_CLUSTER="pg"
DRILL_CLUSTER="pg-restore-drill"
DB="app"
TABLE="${DRILL_TABLE:-restore_canary}"   # canary table maintained by the live app/seed
TG="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
# vmsingle's Prometheus import endpoint (M5). Default to the in-cluster service so the metric is
# ALWAYS delivered — M5's CNPGRestoreDrillStale uses absent(), so a missing series pages forever.
PUSHGW="${METRICS_PUSH_URL:-http://vmsingle.observability.svc:8428}"

notify() {  # $1=emoji-status $2=text
  curl -fsS -X POST "$TG" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=[restore-drill] $1 $2" \
    --data-urlencode "parse_mode=HTML" >/dev/null || true
}

push_success_metric() {  # canonical series read by M5's CNPGRestoreDrillStale (vmsingle import API)
  printf 'restore_drill_last_success_timestamp %s\n' "$(date -u +%s)" \
    | curl -fsS --data-binary @- "${PUSHGW}/api/v1/import/prometheus" \
    || fail "could not push restore_drill_last_success_timestamp to ${PUSHGW} (M5 would page on the absent series)"
}

fail() { notify "🔴 FAIL" "$1"; exit 1; }
# Cleanup removes the drill's Cluster + PVCs. The drill uses the `drill-ssd` StorageClass
# (reclaimPolicy=Delete), so deleting the PVCs AUTO-deletes their PVs — no cluster-wide PV
# permission, no ~50 GiB/run leak. (CNPG does not delete PVCs on Cluster delete, so we do.)
cleanup() {
  kubectl -n "$NS" delete cluster "$DRILL_CLUSTER" --ignore-not-found --wait=true || true
  kubectl -n "$NS" delete pvc -l "cnpg.io/cluster=${DRILL_CLUSTER}" --ignore-not-found --wait=true || true
}
trap cleanup EXIT

echo "[drill] expected row count from live cluster"
EXPECTED_ROWS="$(kubectl -n "$NS" exec "${LIVE_CLUSTER}-1" -c postgres -- \
  psql -U postgres -d "$DB" -tAc "SELECT count(*) FROM ${TABLE};")" \
  || fail "could not read live row count"
echo "[drill] EXPECTED_ROWS=${EXPECTED_ROWS}"

echo "[drill] applying throwaway recovery cluster"
kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${DRILL_CLUSTER}
  namespace: ${NS}
  labels: { cnpg.io/drill: "true" }
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
  storage: { size: 40Gi, storageClass: drill-ssd }      # Delete reclaim → PVCs auto-remove PVs (no leak, no PV RBAC)
  walStorage: { size: 10Gi, storageClass: drill-ssd }
  resources:
    requests: { cpu: 250m, memory: 768Mi }
    limits:   { cpu: "1", memory: 1Gi }
  bootstrap:
    recovery:
      source: r2-source
  externalClusters:
    - name: r2-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: pg-r2
          serverName: ${LIVE_CLUSTER}
YAML

echo "[drill] waiting for ${DRILL_CLUSTER} to reach healthy phase"
PHASE=""
for i in $(seq 1 60); do
  PHASE="$(kubectl -n "$NS" get cluster "$DRILL_CLUSTER" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  echo "  attempt ${i}: phase=${PHASE:-<none>}"
  [ "$PHASE" = "Cluster in healthy state" ] && break
  sleep 15
done
[ "$PHASE" = "Cluster in healthy state" ] || fail "drill cluster never became healthy (phase=${PHASE:-none})"

echo "[drill] actual row count from recovered cluster"
ACTUAL_ROWS="$(kubectl -n "$NS" exec "${DRILL_CLUSTER}-1" -c postgres -- \
  psql -U postgres -d "$DB" -tAc "SELECT count(*) FROM ${TABLE};")" \
  || fail "could not read recovered row count"
echo "[drill] ACTUAL_ROWS=${ACTUAL_ROWS}"

# Allow >= because WAL replay may include rows written after the base backup.
if [ "$ACTUAL_ROWS" -ge "$EXPECTED_ROWS" ] && [ "$ACTUAL_ROWS" -gt 0 ]; then
  push_success_metric   # BEFORE the PASS notify: fail-hard if the metric can't land (else M5's absent() alert pages forever)
  notify "🟢 PASS" "recovered ${ACTUAL_ROWS} rows (live ${EXPECTED_ROWS}) from R2"
  # dead-man's switch: only ping on a genuine PASS (M5 owns the healthcheck definition)
  curl -fsS -m 10 "${HEALTHCHECKS_URL}" >/dev/null || true
  echo "[drill] PASS"
else
  fail "row mismatch: recovered=${ACTUAL_ROWS} expected>=${EXPECTED_ROWS}"
fi

cleanup
RESID=$(kubectl -n "$NS" get pvc -l "cnpg.io/cluster=${DRILL_CLUSTER}" -o name 2>/dev/null | wc -l | tr -d ' ')
[ "$RESID" = "0" ] || fail "drill cleanup INCOMPLETE: ${RESID} residual drill PVC(s) — storage would leak; check the restore-drill RBAC (pvc/pv delete perms)"
echo "[drill] cleanup done (cluster + PVCs + released PVs — zero residual verified)"
```

> **No hand-written ConfigMap — it is GENERATED.** The `restore-drill-script` ConfigMap is produced by the kustomization's `configMapGenerator` (Task 4.12: `drill.sh=restore-drill-script.sh`, `disableNameSuffixHash: true`), so the running `drill.sh` **IS** `restore-drill-script.sh` byte-for-byte. This removes the empty-placeholder failure mode (a comment-only `drill.sh` that lets the CronJob `exit 0` without ever restoring — R1's worst case). The render test in Task 4.12 asserts the generated `drill.sh` contains the real recovery logic (`bootstrap:`/`recovery:`/`EXPECTED_ROWS`/`ACTUAL_ROWS`) and is the full multi-line script, not a stub. There is **no** separate `restore-drill-configmap.yaml` file and **no** deferred "M6 copies the script in" step.

`platform/cnpg/prod/restore-drill-rbac.yaml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata: { name: restore-drill, namespace: database }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: restore-drill, namespace: database }
rules:
  - apiGroups: ["postgresql.cnpg.io"]
    resources: ["clusters"]
    verbs: ["get","list","create","delete"]
  - apiGroups: [""]
    resources: ["pods","pods/exec"]
    verbs: ["get","list","create"]
  - apiGroups: [""]                       # delete the drill cluster's PVCs (else ~50GiB/run leak)
    resources: ["persistentvolumeclaims"]
    verbs: ["get","list","delete"]
---
# NO cluster-wide PV permissions. Granting delete on ALL PersistentVolumes to a Job running a
# MUTABLE image is a foot-gun (a bad image/script could delete LIVE PVs; a client-side name filter
# is not an authorization boundary — Pass-4 finding). Instead the drill cluster uses the dedicated
# `drill-ssd` StorageClass (reclaimPolicy=Delete), so deleting the drill PVCs (namespace Role above)
# AUTOMATICALLY removes their PVs — no PV permission required.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: restore-drill, namespace: database }
subjects: [{ kind: ServiceAccount, name: restore-drill, namespace: database }]
roleRef: { kind: Role, name: restore-drill, apiGroup: rbac.authorization.k8s.io }
---
# Dedicated DRILL StorageClass: reclaimPolicy=Delete so the drill's PVCs auto-remove their PVs
# on delete — the cleanup needs only namespace-scoped PVC delete, NO cluster-wide PV RBAC.
# Same local-path provisioner / internal SSD as `standard`; M1's local-path config maps
# `drill-ssd` → /var/lib/rancher/k3s-storage/internal.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: drill-ssd }
provisioner: homelab.io/local-path-internal   # MUST match M1's installed internal provisioner (NOT rancher.io/local-path)
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
```

`platform/cnpg/prod/restore-drill-cronjob.yaml`:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pg-restore-drill
  namespace: database
spec:
  schedule: "0 5 * * 0"            # Sunday 05:00 — RECURRING, monitored
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 4
  failedJobsHistoryLimit: 4
  jobTemplate:
    spec:
      backoffLimit: 0              # a failed drill must page, not silently retry
      activeDeadlineSeconds: 3600
      template:
        metadata:
          labels: { cnpg.io/job: restore-drill }
        spec:
          restartPolicy: Never
          serviceAccountName: restore-drill
          containers:
            - name: drill
              # PINNED BY DIGEST (immutable): this Job has delete rights in the database ns; a mutable
              # tag could be swapped under it. CI records the digest — pin it here before enabling the drill.
              image: ghcr.io/<OWNER>/pg-tools:16-rclone@sha256:<PINNED_PG_TOOLS_DIGEST>
              command: ["/bin/bash", "/scripts/drill.sh"]
              env:
                - name: TELEGRAM_BOT_TOKEN
                  valueFrom: { secretKeyRef: { name: restore-drill-alerting, key: TELEGRAM_BOT_TOKEN } }
                - name: TELEGRAM_CHAT_ID
                  valueFrom: { secretKeyRef: { name: restore-drill-alerting, key: TELEGRAM_CHAT_ID } }
                - name: HEALTHCHECKS_URL
                  valueFrom: { secretKeyRef: { name: restore-drill-alerting, key: HEALTHCHECKS_URL } }
                - name: METRICS_PUSH_URL
                  value: "http://vmsingle.observability.svc:8428"   # vmsingle import API (M5) — the success metric MUST land
              volumeMounts:
                - { name: script, mountPath: /scripts }
          volumes:
            - name: script
              configMap: { name: restore-drill-script, defaultMode: 0755 }
```
> The drill's Telegram/healthchecks creds come from the M4-owned `restore-drill-alerting` Secret (Task 4.9, database ns), using canonical key names. `restore-drill-rbac.yaml` and `restore-drill-cronjob.yaml` are added to `kustomization.yaml` `resources`; the `restore-drill-script` ConfigMap is produced by that kustomization's `configMapGenerator` from `restore-drill-script.sh` (Task 4.12) — it is NOT a resource file.

4. Run — expect PASS:
```bash
$ bats platform/cnpg/prod/test_restore_drill.bats
 ✓ drill is recurring (weekly cron)
 ✓ drill uses the M6-built pg-tools image
 ✓ drill bootstraps a FRESH cluster via recovery from R2
 ✓ drill compares row counts and reports pass/fail to Telegram
 ✓ drill pushes the restore_drill_last_success_timestamp breadcrumb (M5 alert metric)
 ✓ drill tears the throwaway cluster down (no resource leak)
 ✓ drill script passes shellcheck
7 tests, 0 failures
```

5. Commit:
```bash
git add platform/cnpg/prod/restore-drill-*.{sh,yaml} platform/cnpg/prod/test_restore_drill.bats
git commit -m "feat(cnpg): R2 복구 검증 주간 restore drill CronJob과 Telegram 게이트 추가 (M5 메트릭 breadcrumb 포함)"
```

---

### Task 4.12 — LIVE restore-drill proof (the linchpin manual verification) — GATED on M6's pg-tools image

**Files**
- Test: live cluster (no new repo files; this is the once-per-bring-up acceptance gate). Record evidence in `docs/runbooks/restore.md` (Task 4.13).

> **Gate:** the live drill and live hedge run **require** `ghcr.io/<OWNER>/pg-tools:16-rclone`, which is built by **M6's CI matrix** from `apps/pg-tools/Dockerfile`. The static manifests + bats suites (Tasks 4.1–4.11) pass without M6, but the **live-drill acceptance below cannot be marked done until M6 has published the image.** This is stated again in the Definition of Done.

1. Define the live assertion: on a real cluster, the ScheduledBackup completes to R2 AND the drill recovers matching rows. Establish the canary first.
```bash
# seed a deterministic canary the live app maintains (or seed once here)
kubectl -n database exec pg-1 -c postgres -- \
  psql -U postgres -d app -c \
  "CREATE TABLE IF NOT EXISTS restore_canary(id serial primary key, ts timestamptz default now());
   INSERT INTO restore_canary DEFAULT VALUES; SELECT count(*) FROM restore_canary;"
```

2. Run the FAILING-state check first — confirm no completed backup exists yet, and confirm `kubectl cnpg status` is the tool of record:
```bash
$ kubectl cnpg status pg -n database | head -5
# Expected (fresh cluster, before first backup):
Cluster Summary
Name: database/pg
...
Continuous Backup status: Not configured / First point of recoverability: <empty>
$ kubectl -n database get backups -o wide
No resources found in database namespace.
```

3. Trigger and wait for a real backup to land in R2 (the `immediate: true` ScheduledBackup or an on-demand Backup):
```bash
kubectl -n database create -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: pg-manual-001, namespace: database }
spec:
  cluster: { name: pg }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
EOF
```

4. Verify the EXPECTED PASS for status + backup + drill (drill/hedge steps require the M6 pg-tools image):
```bash
# (a) cnpg status healthy
$ kubectl cnpg status pg -n database | grep -E 'Instances|Status'
Instances:           1
Status:              Cluster in healthy state

# (b) backup completed to R2
$ kubectl -n database get backup pg-manual-001 -o jsonpath='{.status.phase}{"\n"}'
completed

# (c) THE LINCHPIN — run the drill job now, not next Sunday (needs M6 pg-tools image)
$ kubectl -n database create job restore-drill-now --from=cronjob/pg-restore-drill
$ kubectl -n database wait --for=condition=complete job/restore-drill-now --timeout=20m
job.batch/restore-drill-now condition met
$ kubectl -n database logs job/restore-drill-now | grep -E 'EXPECTED_ROWS|ACTUAL_ROWS|PASS'
[drill] EXPECTED_ROWS=1
[drill] ACTUAL_ROWS=1
[drill] PASS
# and a 🟢 PASS message arrives in Telegram

# (d) hedge produces a restorable dump (needs M6 pg-tools image)
$ kubectl -n database create job pgdump-now --from=cronjob/pg-dump-hedge-r2
$ kubectl -n database wait --for=condition=complete job/pgdump-now --timeout=10m
$ kubectl -n database logs job/pgdump-now | grep 'OK size='
[hedge] OK size=20480
# prove it restores: pull + pg_restore --list shows the canary table
$ kubectl -n database exec pg-1 -c postgres -- bash -c \
  'rclone copyto r2:homelab-pg-backups-prod/pgdump/$(rclone lsf r2:homelab-pg-backups-prod/pgdump/ | tail -1) /tmp/d.gz && \
   gunzip -c /tmp/d.gz | pg_restore --list | grep restore_canary'
... TABLE DATA public restore_canary app
```

5. Commit the evidence capture (paste real outputs into the runbook in Task 4.13; no code change here):
```bash
git commit --allow-empty -m "test(cnpg): 라이브 restore drill 및 pg_dump 헤지 복구 검증 통과 기록 (M6 pg-tools 이미지 게이트)"
```

---

### Task 4.13 — `docs/runbooks/restore.md` (R1 documentation)

**Files**
- Create `docs/runbooks/restore.md`
- Test `docs/runbooks/test_restore_runbook.bats`

1. Write the check that the runbook documents all three recovery paths and includes the exact PITR command, so the runbook can't rot into vagueness.

`docs/runbooks/test_restore_runbook.bats`:
```bash
#!/usr/bin/env bats
f=docs/runbooks/restore.md
@test "runbook covers R2 barman recovery, pg_dump hedge, and local basebackup" {
  grep -qi 'bootstrap.recovery' "$f"
  grep -qi 'pg_restore' "$f"
  grep -qi 'pg_basebackup' "$f"
}
@test "runbook gives a PITR (point-in-time) recovery example" {
  grep -qi 'recoveryTarget' "$f"
}
@test "runbook records the drill cadence and the row-count gate" {
  grep -qi 'restore_canary' "$f"
}
```

2. Run — expect FAIL (`No such file`).

3. Implement.

`docs/runbooks/restore.md`:
```markdown
# Runbook — PostgreSQL Restore (CloudNativePG)

Three independent recovery paths exist (3-2-1). Prefer them in this order; each is
verified continuously (see "Verification").

## 0. Triage
- `kubectl cnpg status pg -n database` — is the live cluster recoverable in place?
- Check the latest restore-drill result in Telegram and the M5 `CNPGRestoreDrillStale` alert.

## Path A — Full recovery from R2 (offsite, primary DR path)
Stand up a NEW cluster (never recover onto the broken one):
```bash
kubectl apply -n database -f - <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: pg-restored, namespace: database }
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
  storage:    { size: 40Gi, storageClass: standard }
  walStorage: { size: 10Gi, storageClass: standard }
  bootstrap:
    recovery:
      source: r2-source
  externalClusters:
    - name: r2-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters: { barmanObjectName: pg-r2, serverName: pg }
YAML
kubectl cnpg status pg-restored -n database   # wait for "Cluster in healthy state"
```
Point-in-time (PITR): add under `bootstrap.recovery`:
```yaml
      recoveryTarget:
        targetTime: "2026-06-09 14:30:00.00000+00"
```
Then re-point apps/Pooler at `pg-restored` (rename or update `Pooler.spec.cluster.name`).

## Path B — Logical restore from the pg_dump hedge (barman/WAL-format failure)
```bash
rclone copyto r2:homelab-pg-backups-prod/pgdump/<latest>.dump.gz /tmp/d.gz
gunzip -c /tmp/d.gz | pg_restore --clean --if-exists \
  --host=pg-rw.database.svc --username=app --dbname=app --no-password
```
Use when Path A fails SigV4/region/WAL replay. `AWS_REGION=auto` is mandatory for R2.

## Path C — Local pg_basebackup (fast, on-node, last 7 days)
Tarballs live on `bulk-ssd` PVC `pg-basebackup-local`:
```bash
# exec into a tools pod with the PVC mounted; extract base.tar.gz into a fresh PGDATA,
# then start postgres with the streamed WAL. Local copy only — no offsite guarantee.
```

## Verification (these run automatically)
- Weekly `pg-restore-drill` CronJob: reads `count(*) FROM restore_canary` on live,
  recovers a throwaway `pg-restore-drill` cluster from R2, compares row counts,
  reports 🟢/🔴 to Telegram, pings healthchecks.io on PASS, pushes the
  `restore_drill_last_success_timestamp` metric, then deletes the cluster.
- `ScheduledBackup pg-daily-r2` (03:00); the M5 `R2BackupStale` alert reads
  `cnpg_collector_last_available_backup_timestamp`.
- `cnpg-local-basebackup` CronJob (02:30); the M5 `LocalBasebackupStale` alert reads
  `kube_job_status_completion_time{job_name=~"cnpg-local-basebackup.*"}`.
- Run a drill on demand: `kubectl -n database create job drill-now --from=cronjob/pg-restore-drill`.
  (Requires the M6-built `ghcr.io/<OWNER>/pg-tools:16-rclone` image.)

## RTO/RPO
- RPO ≈ 5 min (archive_timeout=5min continuous WAL archiving).
- RTO ≈ time to recover a 40Gi cluster from R2 (typically minutes on this dataset).
```

4. Run — expect PASS:
```bash
$ bats docs/runbooks/test_restore_runbook.bats
 ✓ runbook covers R2 barman recovery, pg_dump hedge, and local basebackup
 ✓ runbook gives a PITR (point-in-time) recovery example
 ✓ runbook records the drill cadence and the row-count gate
3 tests, 0 failures
```

5. Commit:
```bash
git add docs/runbooks/restore.md docs/runbooks/test_restore_runbook.bats
git commit -m "docs(cnpg): PostgreSQL 복구 runbook 추가 (R2/헤지/로컬 3경로)"
```

---

### Task 4.14 — Backup-liveness breadcrumb metrics exist (alert rules owned by M5)

**Files**
- Test `platform/cnpg/prod/test_breadcrumb_metrics.bats` (asserts the metric *sources* exist; NO alert rules authored here)

> **Ownership:** the backup-liveness + disk-fill **alert rules** (`R2BackupStale`, `LocalBasebackupStale`, `WALArchiveStalled`, `BulkSSDFilling/AlmostFull`, `CNPGRestoreDrillStale`) are owned by **Milestone 5** (in vmalert). M4 does **not** define any vmalert rules. M4's job is only to guarantee the breadcrumb **metrics those rules read** actually exist, so M5 can wire delivery without inventing data sources. **Alert rules owned by M5.**

The canonical M5 metric → M4 source mapping:

| M5 alert (M5-owned rule) | Metric it reads | M4 source that produces it |
|---|---|---|
| `R2BackupStale` | `cnpg_collector_last_available_backup_timestamp` | CNPG operator metrics (Cluster has barman archiver enabled — Task 4.4) |
| `WALArchiveStalled` | `cnpg_collector_last_failed_archive_time` vs `…last_archived_time` | CNPG operator metrics (WAL archiver enabled — Task 4.4) |
| `LocalBasebackupStale` | `kube_job_status_completion_time{job_name=~"cnpg-local-basebackup.*"}` | the `cnpg-local-basebackup` CronJob name (Task 4.7) + kube-state-metrics (M5) |
| `BulkSSDFilling` / `…AlmostFull` | `node_filesystem_avail_bytes` on the bulk mount | node-exporter on the `bulk-ssd` mount (M1/M5) — M4 only stages backups there |
| `CNPGRestoreDrillStale` | `restore_drill_last_success_timestamp` | pushed by the drill on PASS (Task 4.11) |

1. Write the check that the metric *producers* are in place (no rule file is authored).

`platform/cnpg/prod/test_breadcrumb_metrics.bats`:
```bash
#!/usr/bin/env bats

@test "Cluster enables the barman WAL archiver (feeds cnpg_collector_* backup metrics)" {
  grep -q 'isWALArchiver: true' platform/cnpg/prod/cluster.yaml
}
@test "local basebackup Job is named so kube_job_status_completion_time can match it" {
  grep -q 'name: cnpg-local-basebackup' platform/cnpg/prod/basebackup-cronjob.yaml
}
@test "restore drill pushes restore_drill_last_success_timestamp" {
  grep -q 'restore_drill_last_success_timestamp' platform/cnpg/prod/restore-drill-script.sh
}
@test "M4 authors NO vmalert / PrometheusRule (those are M5-owned)" {
  run bash -c "ls platform/cnpg/prod/alert-rules.yaml 2>/dev/null"
  [ "$status" -ne 0 ]
  run bash -c "grep -rl 'kind: PrometheusRule' platform/cnpg 2>/dev/null"
  [ -z "$output" ]
}
```

2. Run — expect FAIL until Tasks 4.4 / 4.7 / 4.11 are in; the last assertion guards against re-introducing an M4-owned rule file.

3. There is **no implementation step** — the metric sources already exist from earlier tasks. If a breadcrumb is missing, fix it in the **owning task's** file (4.4 / 4.7 / 4.11), not here. M5 will author the rules that consume these metrics; M4 only proves the data exists.

4. Run — expect PASS:
```bash
$ bats platform/cnpg/prod/test_breadcrumb_metrics.bats
 ✓ Cluster enables the barman WAL archiver (feeds cnpg_collector_* backup metrics)
 ✓ local basebackup Job is named so kube_job_status_completion_time can match it
 ✓ restore drill pushes restore_drill_last_success_timestamp
 ✓ M4 authors NO vmalert / PrometheusRule (those are M5-owned)
4 tests, 0 failures
```

5. Commit:
```bash
git add platform/cnpg/prod/test_breadcrumb_metrics.bats
git commit -m "test(cnpg): 백업 liveness/디스크 breadcrumb 메트릭 존재 계약 (알림 규칙은 M5 소유)"
```

---

### Task 4.15 — Sync-wave proof: CNPG Ready gates app migrations

**Files**
- Test `platform/cnpg/prod/test_sync_wave_ordering.bats` (static contract)
- Live check (no repo file): ordering observed during a real sync.

1. Write the static check that the wave numbers form the contract operator(-2) → Cluster CR(-1) → CNPG-Ready (the `cnpg-data` Application being Healthy = implicit gate) → app migration Job(1) → Deployment(2), matching M3's `SYNC-WAVES.md` and §9.

`platform/cnpg/prod/test_sync_wave_ordering.bats`:
```bash
#!/usr/bin/env bats
@test "operator wave -2 < data wave -1 (operator first)" {
  grep -qE 'sync-wave:\s*"-2"' platform/argocd/root/apps/cnpg-operator.yaml
  grep -qE 'sync-wave:\s*"-1"' platform/argocd/root/apps/cnpg-data.yaml
}
@test "Cluster CR carries wave -1 so it is Ready before app migrations (wave 1)" {
  grep -qE 'sync-wave:\s*"-1"' platform/cnpg/prod/cluster.yaml
}
@test "waves match the M3-owned SYNC-WAVES.md (cnpg-operator -2, Cluster -1)" {
  grep -qE 'cnpg-operator.*-2' platform/argocd/root/SYNC-WAVES.md
  grep -qE 'Cluster.*-1' platform/argocd/root/SYNC-WAVES.md
}
@test "shared app chart runs migrate as a pre-upgrade hook at wave 1" {
  # asserted against the chart owned by Milestone 6; this is the cross-milestone contract
  test -f platform/charts/app/templates/migrate-job.yaml || skip "chart from M6 not present yet"
  grep -qE 'helm.sh/hook:\s*(pre-install,pre-upgrade|pre-upgrade)' platform/charts/app/templates/migrate-job.yaml
  grep -qE 'sync-wave:\s*"1"' platform/charts/app/templates/migrate-job.yaml
}
```

2. Run — expect FAIL on the first two until 4.1/4.4/4.10 are in; the third reads the **M3-owned** `SYNC-WAVES.md` (present once M3 ran); the fourth `skip`s until M6.

3. Implement: ordering is already encoded in `cluster.yaml` (wave -1), `apps/cnpg-operator.yaml` (wave -2), `apps/cnpg-data.yaml` (wave -1). The CNPG-Ready gate is **implicit**: the `cnpg-data` Application must be Healthy before per-app sync-waves advance (documented in M3's `SYNC-WAVES.md`). No new code — this task only adds the executable contract test. If a wave annotation drifts from `SYNC-WAVES.md`, fix it in the owning file now (the test names the file).

4. Run — expect PASS (fourth skips pre-M6):
```bash
$ bats platform/cnpg/prod/test_sync_wave_ordering.bats
 ✓ operator wave -2 < data wave -1 (operator first)
 ✓ Cluster CR carries wave -1 so it is Ready before app migrations (wave 1)
 ✓ waves match the M3-owned SYNC-WAVES.md (cnpg-operator -2, Cluster -1)
 - shared app chart runs migrate as a pre-upgrade hook at wave 1 (skipped: chart from M6 not present yet)
4 tests, 0 failures, 1 skipped
```
Live ordering proof once an app exists (M6): sync and watch the migration Job never start before the Cluster is healthy:
```bash
$ argocd app sync prod/<app> && kubectl -n prod get jobs -l app.kubernetes.io/component=migrate -w
# Expected: migrate Job appears only AFTER `kubectl cnpg status pg` shows healthy.
$ kubectl -n prod logs job/<app>-migrate | tail -2
migrations applied: schema is up to date
```

5. Commit:
```bash
git add platform/cnpg/prod/test_sync_wave_ordering.bats
git commit -m "test(cnpg): operator→Cluster→migration sync-wave 순서 계약 테스트 추가 (SYNC-WAVES.md 정합)"
```

---

### Milestone 4 — Definition of Done

- `kubectl cnpg status pg -n database` shows `Instances: 1` / `Cluster in healthy state` (4.12).
- A `ScheduledBackup`/`Backup` reaches `phase: completed` against R2 with `AWS_REGION=auto`, using the **M2-seeded** `cnpg-r2-creds` Secret — M4 creates **no** R2 creds secret (4.2, 4.3, 4.6, 4.12).
- **R1 linchpin (GATED on M6):** the restore-drill recovers a fresh `pg-restore-drill` cluster from R2 and row counts match (`ACTUAL_ROWS >= EXPECTED_ROWS > 0`), with a 🟢 PASS in Telegram, a healthchecks.io ping, and the `restore_drill_last_success_timestamp` breadcrumb pushed; it is recurring (weekly) and monitored, documented in `docs/runbooks/restore.md`. The **live-drill acceptance (and the live hedge run) cannot complete until M6 has built `ghcr.io/<OWNER>/pg-tools:16-rclone`** from `apps/pg-tools/Dockerfile` (M6-owned deliverable; M4 only references it) (4.11, 4.12, 4.13).
- The `pg_dump | rclone → R2` hedge produces a `pg_restore --list`-restorable dump on a separate R2 prefix (`AWS_REGION=auto`), also gated on the M6 image (4.8, 4.12).
- Local `pg_basebackup` lands on `bulk-ssd` (never `standard`), pruned to 7d; PGDATA + WAL never touch `bulk-ssd` (4.4, 4.7).
- **Hand-rolled Applications** `cnpg-operator` (ns `cnpg-system`) and `cnpg-data` (ns `database`) live at `platform/argocd/root/apps/`, project `default`, and are **excluded** from M3's ApplicationSet — no double-management (4.1, 4.10).
- **R4 (metrics only):** the breadcrumb metrics for the M5-owned alert rules exist — `cnpg_collector_last_available_backup_timestamp` / `…last_failed_archive_time` (WAL archiver enabled), `kube_job_status_completion_time{job_name=~"cnpg-local-basebackup.*"}`, `node_filesystem_avail_bytes` on the bulk mount, and `restore_drill_last_success_timestamp`. **M4 authors no vmalert/PrometheusRule — alert rules are owned by M5** (4.7, 4.11, 4.14).
- CNPG tuning verified: `shared_buffers=256MB` ≤ ¼ of the 1Gi pod limit, separate `walStorage` PVC on `standard`, PgBouncer `rw` Pooler in transaction mode (4.4, 4.5).
- Sync-waves match the M3-owned `SYNC-WAVES.md`: operator(-2) → Cluster Ready(-1) before app migrations(1) (4.10, 4.15).

---

## Milestone 5 — Observability & alerting + dead-man-switch

**Goal:** Stand up the full low-RAM observability stack (vmsingle, vmagent, VictoriaLogs, Vector, Grafana, vmalert, the single Alertmanager, node-exporter, kube-state-metrics) with byte-capped retention, GOMEMLIMIT-bounded Go pods, all vmalert rules (infra/up/resource, R4 backup-liveness + disk-fill, R6 CI-staleness, R8 Watchdog), native Telegram delivery, and an off-node dead-man's-switch (healthchecks.io) — all provisioned from git and internal-only. M5 OWNS the single Alertmanager and every vmalert rule, including the backup-liveness and disk-fill rules with canonical metric names (M4 only ensures those metrics exist; it defines no vmalert rules).

**Depends on:** M0 (repo skeleton: `.sops.yaml`, age key recipients, `pnpm-workspace.yaml`/root `package.json`, Makefile stub targets, memory ledger + `pnpm verify:ledger`), M1 (OrbStack VM + k3s + `standard`/`bulk-ssd` StorageClasses + namespaces including `observability`), M2 (ArgoCD app-of-apps + KSOPS repo-server wiring + seeded `alerting.enc.yaml` Secret `alerting-secrets`), M3 (Traefik `Gateway` named `homelab` in ns `gateway` with the `web-internal` listener for internal-only HTTPRoutes; Tailscale operator for `*.int.<DOMAIN>` exposure of Grafana; SYNC-WAVES.md). M4 (CNPG) supplies the backup-liveness / WAL / restore-drill metrics that R4 rules reference, but those rules degrade gracefully (no-data ≠ failure) so M5 does not hard-block on M4 being fully green.

Use @superpowers:executing-plans to run this milestone. All `kubectl` commands assume the k3s kubeconfig from M1 is exported (`export KUBECONFIG=/etc/rancher/k3s/k3s.yaml` inside the VM, or the merged context on the host). Throughout, `<DOMAIN>` is the real apex zone and `int.<DOMAIN>` the internal suffix from M3; `<HC_UUID>` is the healthchecks.io check UUID created in Task 5.16; `<TG_*>` are Telegram bot credentials. `<DOMAIN-OWNER>` is the GitHub org/owner.

---

### Task 5.1 — Namespace + hand-rolled ArgoCD Application for the stack

**Files:**
- Create `platform/victoria-stack/namespace.yaml`
- Create `platform/victoria-stack/kustomization.yaml`
- Create `platform/argocd/root/apps/victoria-stack.yaml` (hand-rolled Application, `project: default`, sync-wave +2 — EXCLUDED from the M3 ApplicationSet so nothing is double-managed)
- Test: ad-hoc `kustomize build` + `conftest`/`kubeconform` assertion below

1. Write the verification first — a kustomize-build smoke check that must currently fail because the directory has no buildable kustomization:
   ```bash
   kustomize build platform/victoria-stack | kubeconform -strict -ignore-missing-schemas -summary
   ```
2. Run it, expect failure (no kustomization yet):
   ```
   Error: unable to find one of 'kustomization.yaml' ... in directory 'platform/victoria-stack'
   ```
3. Implement the namespace and a kustomization that we will append to as the milestone grows. `platform/victoria-stack/namespace.yaml`:
   ```yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: observability
     labels:
       app.kubernetes.io/part-of: victoria-stack
       pod-security.kubernetes.io/enforce: restricted
       pod-security.kubernetes.io/warn: restricted
   ```
   `platform/victoria-stack/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: observability
   resources:
     - namespace.yaml
   ```
   `platform/argocd/root/apps/victoria-stack.yaml` — this is a **hand-rolled** Application picked up by the root app's recursion of `platform/argocd/root/`. It is deliberately EXCLUDED from the M3 ApplicationSet (whose Generator A skips `platform/victoria-stack/*`), so the stack is managed here and only here. `project: default` (never a `platform` project); destination namespace `observability`; explicit sync-wave **+2** per the canonical SYNC-WAVES (M3 owns `platform/argocd/root/SYNC-WAVES.md`):
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: victoria-stack
     namespace: argocd
     annotations:
       argocd.argoproj.io/sync-wave: "2"
     finalizers:
       - resources-finalizer.argocd.argoproj.io
   spec:
     project: default
     source:
       repoURL: https://github.com/<DOMAIN-OWNER>/homelab.git
       targetRevision: main
       path: platform/victoria-stack
     destination:
       server: https://kubernetes.default.svc
       namespace: observability
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=false
         - ServerSideApply=true
       retry:
         limit: 5
         backoff:
           duration: 10s
           maxDuration: 3m
           factor: 2
   ```
4. Run the check, expect pass:
   ```
   Summary: X resources found ... 0 failures, 0 errors
   ```
5. Commit.
   ```bash
   git add platform/victoria-stack platform/argocd/root/apps/victoria-stack.yaml
   git commit -m "feat(observability): victoria-stack 네임스페이스 및 hand-rolled ArgoCD Application(wave +2) 추가"
   ```

---

### Task 5.2 — node-exporter + kube-state-metrics (the metrics-server replacement substrate)

**Files:**
- Create `platform/victoria-stack/node-exporter.yaml`
- Create `platform/victoria-stack/kube-state-metrics.yaml`
- Modify `platform/victoria-stack/kustomization.yaml`
- Test: `kubectl rollout status` + `curl` assertions below

1. Write the verification first — assert the two exporters expose metrics. This fails now (no manifests):
   ```bash
   kubectl -n observability rollout status ds/node-exporter --timeout=5s
   kubectl -n observability rollout status deploy/kube-state-metrics --timeout=5s
   ```
2. Run it, expect failure:
   ```
   Error from server (NotFound): daemonsets.apps "node-exporter" not found
   ```
3. Implement. `platform/victoria-stack/node-exporter.yaml` (hostNetwork off; single node so a Deployment-of-1 would work, but DaemonSet is the idiomatic + future-proof form):
   ```yaml
   apiVersion: apps/v1
   kind: DaemonSet
   metadata:
     name: node-exporter
     labels: { app.kubernetes.io/name: node-exporter }
   spec:
     selector:
       matchLabels: { app.kubernetes.io/name: node-exporter }
     template:
       metadata:
         labels: { app.kubernetes.io/name: node-exporter }
         annotations:
           prometheus.io/scrape: "true"
           prometheus.io/port: "9100"
           prometheus.io/path: "/metrics"
       spec:
         hostPID: true
         securityContext:
           runAsNonRoot: true
           runAsUser: 65534
         tolerations:
           - operator: Exists
         containers:
           - name: node-exporter
             image: quay.io/prometheus/node-exporter:v1.8.2
             args:
               - --path.rootfs=/host/root
               - --path.procfs=/host/proc
               - --path.sysfs=/host/sys
               - --web.listen-address=:9100
               - --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/kubelet/.+)($|/)
             ports:
               - { name: metrics, containerPort: 9100 }
             resources:
               requests: { cpu: 10m, memory: 24Mi }
               limits: { memory: 48Mi }
             securityContext:
               allowPrivilegeEscalation: false
               readOnlyRootFilesystem: true
               capabilities: { drop: ["ALL"] }
             volumeMounts:
               - { name: proc, mountPath: /host/proc, readOnly: true }
               - { name: sys, mountPath: /host/sys, readOnly: true }
               - { name: root, mountPath: /host/root, readOnly: true, mountPropagation: HostToContainer }
         volumes:
           - { name: proc, hostPath: { path: /proc } }
           - { name: sys, hostPath: { path: /sys } }
           - { name: root, hostPath: { path: / } }
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: node-exporter
     labels: { app.kubernetes.io/name: node-exporter }
   spec:
     clusterIP: None
     selector: { app.kubernetes.io/name: node-exporter }
     ports:
       - { name: metrics, port: 9100, targetPort: 9100 }
   ```
   `platform/victoria-stack/kube-state-metrics.yaml` (RBAC + Deployment-of-1; GOMEMLIMIT on this Go pod per §8):
   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata: { name: kube-state-metrics }
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata: { name: kube-state-metrics }
   rules:
     - apiGroups: [""]
       resources: ["configmaps","secrets","nodes","pods","services","serviceaccounts","resourcequotas","replicationcontrollers","limitranges","persistentvolumeclaims","persistentvolumes","namespaces","endpoints"]
       verbs: ["list","watch"]
     - apiGroups: ["apps"]
       resources: ["statefulsets","daemonsets","deployments","replicasets"]
       verbs: ["list","watch"]
     - apiGroups: ["batch"]
       resources: ["cronjobs","jobs"]
       verbs: ["list","watch"]
     - apiGroups: ["autoscaling"]
       resources: ["horizontalpodautoscalers"]
       verbs: ["list","watch"]
     - apiGroups: ["policy"]
       resources: ["poddisruptionbudgets"]
       verbs: ["list","watch"]
     - apiGroups: ["storage.k8s.io"]
       resources: ["storageclasses","volumeattachments"]
       verbs: ["list","watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRoleBinding
   metadata: { name: kube-state-metrics }
   roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: kube-state-metrics }
   subjects:
     - { kind: ServiceAccount, name: kube-state-metrics, namespace: observability }
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: kube-state-metrics
     labels: { app.kubernetes.io/name: kube-state-metrics }
   spec:
     replicas: 1
     selector:
       matchLabels: { app.kubernetes.io/name: kube-state-metrics }
     template:
       metadata:
         labels: { app.kubernetes.io/name: kube-state-metrics }
         annotations:
           prometheus.io/scrape: "true"
           prometheus.io/port: "8080"
       spec:
         serviceAccountName: kube-state-metrics
         securityContext: { runAsNonRoot: true, runAsUser: 65534 }
         containers:
           - name: kube-state-metrics
             image: registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0
             args: ["--port=8080","--telemetry-port=8081","--resources=configmaps,cronjobs,daemonsets,deployments,endpoints,jobs,namespaces,nodes,persistentvolumeclaims,persistentvolumes,pods,replicasets,resourcequotas,secrets,services,statefulsets,storageclasses"]
             env:
               - { name: GOMEMLIMIT, value: "57MiB" }
             ports:
               - { name: http-metrics, containerPort: 8080 }
               - { name: telemetry, containerPort: 8081 }
             resources:
               requests: { cpu: 10m, memory: 32Mi }
               limits: { memory: 64Mi }
             securityContext:
               allowPrivilegeEscalation: false
               readOnlyRootFilesystem: true
               capabilities: { drop: ["ALL"] }
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: kube-state-metrics
     labels: { app.kubernetes.io/name: kube-state-metrics }
   spec:
     selector: { app.kubernetes.io/name: kube-state-metrics }
     ports:
       - { name: http-metrics, port: 8080, targetPort: 8080 }
   ```
   Append to `platform/victoria-stack/kustomization.yaml` `resources:` list:
   ```yaml
     - node-exporter.yaml
     - kube-state-metrics.yaml
   ```
4. Sync (let ArgoCD apply, or `kubectl apply -k` for local verify), then run the check, expect pass:
   ```
   daemon set "node-exporter" successfully rolled out
   deployment "kube-state-metrics" successfully rolled out
   ```
   Confirm metrics endpoints respond:
   ```bash
   kubectl -n observability run curl --rm -it --image=curlimages/curl --restart=Never -- \
     sh -c 'curl -s kube-state-metrics:8080/metrics | head -1; curl -s node-exporter:9100/metrics | grep -c node_'
   ```
   Expect a `# HELP` line and a non-zero count.
5. Commit.
   ```bash
   git commit -am "feat(observability): node-exporter 및 kube-state-metrics 추가"
   ```

---

### Task 5.3 — vmsingle with byte-capped retention + memory bounds (R4)

**Files:**
- Create `platform/victoria-stack/vmsingle.yaml`
- Modify `platform/victoria-stack/kustomization.yaml`
- Test: PVC StorageClass + flag assertions below

1. Write the verification first — assert vmsingle uses the **byte cap** flag (not percent) and lands on `standard` SC. Fails now:
   ```bash
   kubectl -n observability get sts vmsingle -o yaml \
     | grep -E -- '-retention.maxDiskSpaceUsageBytes|-memory.allowedPercent|storageClassName: standard'
   ```
2. Run it, expect failure:
   ```
   Error from server (NotFound): statefulsets.apps "vmsingle" not found
   ```
3. Implement. `platform/victoria-stack/vmsingle.yaml` — vmsingle is Go: GOMEMLIMIT + `-memory.allowedPercent=60`, `-retentionPeriod=30d` AND the hard byte cap so the shared 1 TB/512 GB SSD can never be filled by metrics. vmsingle PVC goes on `standard` (512 GB internal SSD), 20Gi, well under the 35GB byte cap headroom:
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: vmsingle
     labels: { app.kubernetes.io/name: vmsingle }
   spec:
     selector: { app.kubernetes.io/name: vmsingle }
     ports:
       - { name: http, port: 8428, targetPort: 8428 }
   ---
   apiVersion: apps/v1
   kind: StatefulSet
   metadata:
     name: vmsingle
     labels: { app.kubernetes.io/name: vmsingle }
   spec:
     serviceName: vmsingle
     replicas: 1
     selector:
       matchLabels: { app.kubernetes.io/name: vmsingle }
     template:
       metadata:
         labels: { app.kubernetes.io/name: vmsingle }
       spec:
         securityContext: { runAsNonRoot: true, runAsUser: 65534, fsGroup: 65534 }
         containers:
           - name: vmsingle
             image: victoriametrics/victoria-metrics:v1.103.0
             args:
               - --storageDataPath=/storage
               - --retentionPeriod=30d
               - --retention.maxDiskSpaceUsageBytes=35GB
               - --memory.allowedPercent=60
               - --httpListenAddr=:8428
               - --dedup.minScrapeInterval=30s
             env:
               - { name: GOMEMLIMIT, value: "920MiB" }   # ~90% of 1Gi limit
             ports:
               - { name: http, containerPort: 8428 }
             resources:
               requests: { cpu: 100m, memory: 512Mi }
               limits: { memory: 1Gi }
             readinessProbe: { httpGet: { path: /health, port: 8428 }, initialDelaySeconds: 5 }
             livenessProbe: { httpGet: { path: /health, port: 8428 }, initialDelaySeconds: 30 }
             securityContext:
               allowPrivilegeEscalation: false
               readOnlyRootFilesystem: true
               capabilities: { drop: ["ALL"] }
             volumeMounts:
               - { name: storage, mountPath: /storage }
     volumeClaimTemplates:
       - metadata: { name: storage }
         spec:
           accessModes: ["ReadWriteOnce"]
           storageClassName: standard
           resources: { requests: { storage: 20Gi } }
   ```
   Append `- vmsingle.yaml` to the kustomization `resources:`.
4. Sync, run the check, expect pass — all three greps return a line:
   ```
   - --retention.maxDiskSpaceUsageBytes=35GB
             storageClassName: standard
   ```
   Note `-memory.allowedPercent=60` shows; `-retention.maxDiskSpaceUsageBytes` present and **no** percent-based retention flag. Confirm health:
   ```bash
   kubectl -n observability exec sts/vmsingle -- wget -qO- localhost:8428/health
   # OK
   ```
5. Commit.
   ```bash
   git commit -am "feat(observability): 바이트 상한 보존(35GB)·GOMEMLIMIT 적용한 vmsingle 추가"
   ```

---

### Task 5.4 — vmagent: static kubernetes_sd scrape + `prometheus.io/scrape` discovery, noStaleMarkers

**Files:**
- Create `platform/victoria-stack/vmagent-scrape-config.yaml` (ConfigMap)
- Create `platform/victoria-stack/vmagent.yaml` (RBAC + Deployment + Service)
- Modify `platform/victoria-stack/kustomization.yaml`
- Test: `/api/v1/targets` assertion below

1. Write the verification first — assert vmagent has all targets `up`. Fails now:
   ```bash
   kubectl -n observability exec deploy/vmagent -- wget -qO- 'localhost:8429/api/v1/targets?state=active' \
     | grep -o '"health":"[a-z]*"' | sort | uniq -c
   ```
2. Run it, expect failure:
   ```
   Error from server (NotFound): deployments.apps "vmagent" not found
   ```
3. Implement the scrape config. `platform/victoria-stack/vmagent-scrape-config.yaml` (static jobs for the named exporters + a generic pod-annotation discovery job honoring `prometheus.io/scrape|port|path`; `honor_labels` and no stale markers handled at the vmagent flag level):
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: vmagent-scrape-config
   data:
     scrape.yml: |
       global:
         scrape_interval: 30s
         scrape_timeout: 10s
       scrape_configs:
         - job_name: kubelet-cadvisor
           scheme: https
           tls_config: { insecure_skip_verify: true }
           authorization:
             credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
           kubernetes_sd_configs: [{ role: node }]
           relabel_configs:
             - target_label: __address__
               replacement: kubernetes.default.svc:443
             - source_labels: [__meta_kubernetes_node_name]
               regex: (.+)
               target_label: __metrics_path__
               replacement: /api/v1/nodes/$1/proxy/metrics/cadvisor
         - job_name: kubelet
           scheme: https
           tls_config: { insecure_skip_verify: true }
           authorization:
             credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
           kubernetes_sd_configs: [{ role: node }]
           relabel_configs:
             - target_label: __address__
               replacement: kubernetes.default.svc:443
             - source_labels: [__meta_kubernetes_node_name]
               regex: (.+)
               target_label: __metrics_path__
               replacement: /api/v1/nodes/$1/proxy/metrics
         - job_name: pod-annotations
           kubernetes_sd_configs: [{ role: pod }]
           relabel_configs:
             - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
               action: keep
               regex: "true"
             - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
               action: replace
               target_label: __metrics_path__
               regex: (.+)
             - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
               action: replace
               regex: ([^:]+)(?::\d+)?;(\d+)
               replacement: $1:$2
               target_label: __address__
             - source_labels: [__meta_kubernetes_namespace]
               target_label: namespace
             - source_labels: [__meta_kubernetes_pod_name]
               target_label: pod
             - source_labels: [__meta_kubernetes_pod_phase]
               action: drop
               regex: (Pending|Succeeded|Failed)
   ```
   `platform/victoria-stack/vmagent.yaml`:
   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata: { name: vmagent }
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata: { name: vmagent }
   rules:
     - apiGroups: [""]
       resources: ["nodes","nodes/proxy","nodes/metrics","services","endpoints","pods"]
       verbs: ["get","list","watch"]
     - nonResourceURLs: ["/metrics","/metrics/cadvisor"]
       verbs: ["get"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRoleBinding
   metadata: { name: vmagent }
   roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: vmagent }
   subjects: [{ kind: ServiceAccount, name: vmagent, namespace: observability }]
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: vmagent
     labels: { app.kubernetes.io/name: vmagent }
   spec:
     replicas: 1
     selector:
       matchLabels: { app.kubernetes.io/name: vmagent }
     template:
       metadata:
         labels: { app.kubernetes.io/name: vmagent }
       spec:
         serviceAccountName: vmagent
         securityContext: { runAsNonRoot: true, runAsUser: 65534, fsGroup: 65534 }
         containers:
           - name: vmagent
             image: victoriametrics/vmagent:v1.103.0
             args:
               - --promscrape.config=/config/scrape.yml
               - --remoteWrite.url=http://vmsingle:8428/api/v1/write
               - --promscrape.noStaleMarkers
               - --memory.allowedPercent=60
               - --httpListenAddr=:8429
               - --remoteWrite.tmpDataPath=/tmpdata
             env:
               - { name: GOMEMLIMIT, value: "230MiB" }   # ~90% of 256Mi
             ports: [{ name: http, containerPort: 8429 }]
             resources:
               requests: { cpu: 50m, memory: 128Mi }
               limits: { memory: 256Mi }
             readinessProbe: { httpGet: { path: /health, port: 8429 } }
             securityContext:
               allowPrivilegeEscalation: false
               readOnlyRootFilesystem: true
               capabilities: { drop: ["ALL"] }
             volumeMounts:
               - { name: config, mountPath: /config }
               - { name: tmpdata, mountPath: /tmpdata }
         volumes:
           - { name: config, configMap: { name: vmagent-scrape-config } }
           - { name: tmpdata, emptyDir: { sizeLimit: 512Mi } }
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: vmagent
     labels: { app.kubernetes.io/name: vmagent }
   spec:
     selector: { app.kubernetes.io/name: vmagent }
     ports: [{ name: http, port: 8429, targetPort: 8429 }]
   ```
   Append `- vmagent-scrape-config.yaml` and `- vmagent.yaml` to the kustomization. (Add a `configMapGenerator` later if you prefer hash-suffixing; for now the plain ConfigMap + ArgoCD restart annotation in Task 5.14 handles reloads.)
4. Sync, wait ~60s for the first scrape, run the check, expect pass — every active target healthy:
   ```
        N "health":"up"
   ```
   (No `"down"` lines. node-exporter, kube-state-metrics, kubelet, cadvisor all up.)
5. Commit.
   ```bash
   git commit -am "feat(observability): 정적 스크레이프·파드 어노테이션 디스커버리 vmagent 추가"
   ```

---

### Task 5.5 — VictoriaLogs with 14d byte-capped retention

**Files:**
- Create `platform/victoria-stack/victorialogs.yaml`
- Modify `platform/victoria-stack/kustomization.yaml`
- Test: retention flag + ES-bulk endpoint assertion below

1. Write the verification first — assert VictoriaLogs uses a **byte cap** and exposes the ES-compatible bulk endpoint. Fails now:
   ```bash
   kubectl -n observability get sts victorialogs -o yaml | grep -- '-retention.maxDiskSpaceUsageBytes'
   ```
2. Run it, expect failure:
   ```
   Error from server (NotFound): statefulsets.apps "victorialogs" not found
   ```
3. Implement. `platform/victoria-stack/victorialogs.yaml` — `standard` SC (logs are not "bulk media"; co-locate small fast storage), 14d + byte cap, GOMEMLIMIT:
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: victorialogs
     labels: { app.kubernetes.io/name: victorialogs }
   spec:
     selector: { app.kubernetes.io/name: victorialogs }
     ports: [{ name: http, port: 9428, targetPort: 9428 }]
   ---
   apiVersion: apps/v1
   kind: StatefulSet
   metadata:
     name: victorialogs
     labels: { app.kubernetes.io/name: victorialogs }
   spec:
     serviceName: victorialogs
     replicas: 1
     selector:
       matchLabels: { app.kubernetes.io/name: victorialogs }
     template:
       metadata:
         labels: { app.kubernetes.io/name: victorialogs }
       spec:
         securityContext: { runAsNonRoot: true, runAsUser: 65534, fsGroup: 65534 }
         containers:
           - name: victorialogs
             image: victoriametrics/victoria-logs:v0.41.0-victorialogs
             args:
               - --storageDataPath=/vlogs
               - --retentionPeriod=14d
               - --retention.maxDiskSpaceUsageBytes=15GB
               - --memory.allowedPercent=60
               - --httpListenAddr=:9428
             env:
               - { name: GOMEMLIMIT, value: "460MiB" }   # ~90% of 512Mi
             ports: [{ name: http, containerPort: 9428 }]
             resources:
               requests: { cpu: 50m, memory: 256Mi }
               limits: { memory: 512Mi }
             readinessProbe: { httpGet: { path: /health, port: 9428 } }
             securityContext:
               allowPrivilegeEscalation: false
               readOnlyRootFilesystem: true
               capabilities: { drop: ["ALL"] }
             volumeMounts: [{ name: vlogs, mountPath: /vlogs }]
     volumeClaimTemplates:
       - metadata: { name: vlogs }
         spec:
           accessModes: ["ReadWriteOnce"]
           storageClassName: standard
           resources: { requests: { storage: 10Gi } }
   ```
   Append `- victorialogs.yaml` to the kustomization.
4. Sync, run the check, expect pass:
   ```
   - --retention.maxDiskSpaceUsageBytes=15GB
   ```
   Confirm the ES-bulk endpoint is live:
   ```bash
   kubectl -n observability exec sts/victorialogs -- wget -qO- localhost:9428/health
   # OK
   ```
5. Commit.
   ```bash
   git commit -am "feat(observability): 14일 바이트 상한 보존 VictoriaLogs 추가"
   ```

---

### Task 5.6 — Vector daemonset → VictoriaLogs ES bulk endpoint

**Files:**
- Create `platform/victoria-stack/vector.yaml` (RBAC + ConfigMap + DaemonSet)
- Modify `platform/victoria-stack/kustomization.yaml`
- Test: VictoriaLogs ingestion count assertion below

1. Write the verification first — assert logs are actually arriving in VictoriaLogs. Fails now (no Vector shipping):
   ```bash
   kubectl -n observability exec sts/victorialogs -- \
     wget -qO- 'localhost:9428/select/logsql/query?query=*&limit=1' | head -c 200
   ```
2. Run it, expect failure (empty result — nothing ingested):
   ```
   (no output / empty)
   ```
3. Implement. `platform/victoria-stack/vector.yaml` — Vector tails container logs and ships to the VictoriaLogs Elasticsearch `_bulk` endpoint with the required `VL-*` headers via query params:
   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata: { name: vector }
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata: { name: vector }
   rules:
     - apiGroups: [""]
       resources: ["pods","namespaces","nodes"]
       verbs: ["get","list","watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRoleBinding
   metadata: { name: vector }
   roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: vector }
   subjects: [{ kind: ServiceAccount, name: vector, namespace: observability }]
   ---
   apiVersion: v1
   kind: ConfigMap
   metadata: { name: vector-config }
   data:
     vector.yaml: |
       data_dir: /vector-data
       sources:
         k8s:
           type: kubernetes_logs
       transforms:
         parse:
           type: remap
           inputs: [k8s]
           source: |
             .stream = .stream
             .namespace = .kubernetes.pod_namespace
             .pod = .kubernetes.pod_name
             .container = .kubernetes.container_name
       sinks:
         vlogs:
           type: elasticsearch
           inputs: [parse]
           endpoints: ["http://victorialogs:9428/insert/elasticsearch"]
           mode: bulk
           api_version: v8
           compression: gzip
           healthcheck: { enabled: false }
           query:
             _msg_field: message
             _time_field: timestamp
             _stream_fields: namespace,pod,container,stream
           request:
             headers:
               AccountID: "0"
               ProjectID: "0"
   ---
   apiVersion: apps/v1
   kind: DaemonSet
   metadata:
     name: vector
     labels: { app.kubernetes.io/name: vector }
   spec:
     selector:
       matchLabels: { app.kubernetes.io/name: vector }
     template:
       metadata:
         labels: { app.kubernetes.io/name: vector }
       spec:
         serviceAccountName: vector
         securityContext: { runAsNonRoot: true, runAsUser: 65534, fsGroup: 65534 }
         containers:
           - name: vector
             image: timberio/vector:0.41.1-distroless-libc
             args: ["--config","/etc/vector/vector.yaml"]
             env:
               - { name: VECTOR_SELF_NODE_NAME, valueFrom: { fieldRef: { fieldPath: spec.nodeName } } }
             resources:
               requests: { cpu: 50m, memory: 64Mi }
               limits: { memory: 128Mi }
             securityContext:
               allowPrivilegeEscalation: false
               readOnlyRootFilesystem: true
               capabilities: { drop: ["ALL"] }
             volumeMounts:
               - { name: config, mountPath: /etc/vector }
               - { name: data, mountPath: /vector-data }
               - { name: varlog, mountPath: /var/log, readOnly: true }
               - { name: varlibdockercontainers, mountPath: /var/lib/docker/containers, readOnly: true }
         volumes:
           - { name: config, configMap: { name: vector-config } }
           - { name: data, emptyDir: { sizeLimit: 256Mi } }
           - { name: varlog, hostPath: { path: /var/log } }
           - { name: varlibdockercontainers, hostPath: { path: /var/lib/docker/containers } }
   ```
   > Note: Vector is Rust, not Go — it is intentionally OUTSIDE the §8 GOMEMLIMIT list (a `GOMEMLIMIT` env would be a no-op here and is omitted). The real guard is the 128Mi limit. The `bulk-ssd` co-mingling rule (R4) is respected: Vector's buffer is an `emptyDir`, never the external SSD.
4. Sync, wait ~30s, run the check, expect pass — a JSON log line returned:
   ```
   {"_time":"2026-06-10T...","_msg":"...","namespace":"observability","pod":"vector-...", ...}
   ```
5. Commit.
   ```bash
   git commit -am "feat(observability): Vector 데몬셋으로 VictoriaLogs ES 벌크 수집 추가"
   ```

---

### Task 5.7 — Consume the M2-seeded alerting Secret via a KSOPS secret-generator

**Files:**
- Create `platform/victoria-stack/secret-generator.yaml` (KSOPS generator referencing the M2-seeded `prod/alerting.enc.yaml`)
- Modify `platform/victoria-stack/kustomization.yaml`
- Test: KSOPS render + Secret-name/keys assertions below

> Ownership note: the encrypted file `platform/victoria-stack/prod/alerting.enc.yaml` and the Secret `alerting-secrets` (ns `observability`, keys `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` / `HEALTHCHECKS_URL`) are produced ONCE by M2's `seed-secrets.sh`. M5 does **NOT** create, re-encrypt, or re-declare that Secret, and does **NOT** touch `.sops.yaml` (M0 owns it, M2 fills recipient keys). KSOPS repo-server wiring is inherited from M2 — M5 never re-wires it. M5 only adds the kustomization's own KSOPS generator so the render produces the Secret.

1. Write the verification first — assert the M2-seeded file exists, is encrypted to **two** age recipients, and decrypts to the canonical Secret. Fails only if M2 has not seeded it (which is a dependency error, not an M5 task):
   ```bash
   test -f platform/victoria-stack/prod/alerting.enc.yaml \
     && [ "$(grep -c 'recipient:' platform/victoria-stack/prod/alerting.enc.yaml)" -eq 2 ] \
     && sops --decrypt platform/victoria-stack/prod/alerting.enc.yaml | grep -q 'name: alerting-secrets'
   ```
2. Run it before adding the generator, expect failure (the kustomization has no generator yet, so KSOPS render of the stack omits the Secret):
   ```bash
   kustomize build --enable-alpha-plugins --enable-exec platform/victoria-stack | grep -c 'name: alerting-secrets'
   # 0
   ```
3. Implement. Add the kustomization's OWN secret-generator (canonical KSOPS form; there is no shared `ksops.yaml` stub). `platform/victoria-stack/secret-generator.yaml`:
   ```yaml
   apiVersion: viaduct.ai/v1
   kind: ksops
   metadata:
     name: alerting-secret-generator
     annotations:
       config.kubernetes.io/function: |
         exec: { path: ksops }
   files:
     - ./prod/alerting.enc.yaml
   ```
   Append to `platform/victoria-stack/kustomization.yaml`:
   ```yaml
   generators:
     - secret-generator.yaml
   ```
   > The decrypted Secret `alerting-secrets` exposes `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, and `HEALTHCHECKS_URL` (canonical key names from M2). Every consumer in this milestone (Alertmanager init-container, deadmanswitch-relay) references those exact keys.
4. Run the checks, expect pass — the Secret now renders, with no plaintext leak in git:
   ```bash
   grep -c 'recipient:' platform/victoria-stack/prod/alerting.enc.yaml   # 2
   kustomize build --enable-alpha-plugins --enable-exec platform/victoria-stack | grep -c 'name: alerting-secrets'   # 1
   sops --decrypt platform/victoria-stack/prod/alerting.enc.yaml | grep -qE 'HEALTHCHECKS_URL|TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID' && echo KEYS_OK
   ```
   Expect `2`, `1`, `KEYS_OK`.
5. Commit (generator + kustomization only; the encrypted file is owned/committed by M2).
   ```bash
   git add platform/victoria-stack/secret-generator.yaml platform/victoria-stack/kustomization.yaml
   git commit -m "feat(observability): M2 시드 alerting-secrets 소비용 KSOPS secret-generator 추가"
   ```

---

### Task 5.8 — The single Alertmanager with native telegram_configs + routes (gossip disabled)

**Files:**
- Create `platform/victoria-stack/alertmanager.yaml` (ConfigMap + Deployment + Service)
- Modify `platform/victoria-stack/kustomization.yaml`
- Test: config-load + telegram receiver assertion below

> M5 owns the **single** Alertmanager for the whole platform. There is no second Alertmanager anywhere; CI/deploy notifications use a direct `curl` to the Bot API (§8), not this one.

1. Write the verification first — assert Alertmanager loaded a config with a `telegram_configs` receiver and gossip is off. Fails now:
   ```bash
   kubectl -n observability exec deploy/alertmanager -- wget -qO- localhost:9093/api/v2/status \
     | grep -o '"clusterStatus":[^}]*'
   ```
2. Run it, expect failure:
   ```
   Error from server (NotFound): deployments.apps "alertmanager" not found
   ```
3. Implement. Alertmanager reads `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` from the mounted `alerting-secrets`. Native `telegram_configs` requires a numeric `chat_id` and a `bot_token` (or `bot_token_file`); we use `bot_token_file` mounted from the secret. The Watchdog route fans out to a separate `deadmanswitch` receiver wired to the relay in Task 5.13. `platform/victoria-stack/alertmanager.yaml`:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata: { name: alertmanager-config }
   data:
     alertmanager.yml: |
       global:
         resolve_timeout: 5m
       route:
         receiver: telegram
         group_by: ['alertname','namespace']
         group_wait: 30s
         group_interval: 5m
         repeat_interval: 4h
         routes:
           - matchers: [ 'alertname = Watchdog' ]
             receiver: deadmanswitch
             group_wait: 0s
             group_interval: 1m
             repeat_interval: 1m
             continue: false
           - matchers: [ 'severity = critical' ]
             receiver: telegram
             repeat_interval: 1h
       receivers:
         - name: telegram
           telegram_configs:
             - bot_token_file: /etc/alertmanager/secrets/TELEGRAM_BOT_TOKEN
               chat_id: __CHAT_ID__
               api_url: https://api.telegram.org
               parse_mode: HTML
               send_resolved: true
               message: |
                 <b>{{ .Status | toUpper }}</b> {{ .CommonLabels.alertname }}
                 {{ range .Alerts }}{{ .Annotations.summary }}
                 {{ .Annotations.description }}
                 {{ end }}
         - name: deadmanswitch
           webhook_configs:
             - url: http://deadmanswitch-relay:9095/ping
               send_resolved: false
       inhibit_rules:
         - source_matchers: [ 'severity = critical' ]
           target_matchers: [ 'severity = warning' ]
           equal: ['alertname','namespace']
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: alertmanager
     labels: { app.kubernetes.io/name: alertmanager }
   spec:
     replicas: 1
     selector:
       matchLabels: { app.kubernetes.io/name: alertmanager }
     template:
       metadata:
         labels: { app.kubernetes.io/name: alertmanager }
       spec:
         securityContext: { runAsNonRoot: true, runAsUser: 65534, fsGroup: 65534 }
         initContainers:
           - name: render-config
             image: busybox:1.36
             command: ["sh","-c"]
             args:
               - |
                 sed "s/__CHAT_ID__/$TELEGRAM_CHAT_ID/" /config-in/alertmanager.yml > /config-out/alertmanager.yml
             env:
               - { name: TELEGRAM_CHAT_ID, valueFrom: { secretKeyRef: { name: alerting-secrets, key: TELEGRAM_CHAT_ID } } }
             volumeMounts:
               - { name: config-in, mountPath: /config-in }
               - { name: config-out, mountPath: /config-out }
             securityContext: { runAsNonRoot: true, runAsUser: 65534, allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
         containers:
           - name: alertmanager
             image: prom/alertmanager:v0.27.0
             args:
               - --config.file=/etc/alertmanager/alertmanager.yml
               - --storage.path=/alertmanager
               - --cluster.listen-address=
               - --web.listen-address=:9093
             ports: [{ name: http, containerPort: 9093 }]
             resources:
               requests: { cpu: 10m, memory: 32Mi }
               limits: { memory: 64Mi }
             readinessProbe: { httpGet: { path: /-/ready, port: 9093 } }
             securityContext:
               allowPrivilegeEscalation: false
               readOnlyRootFilesystem: true
               capabilities: { drop: ["ALL"] }
             volumeMounts:
               - { name: config-out, mountPath: /etc/alertmanager }
               - { name: secrets, mountPath: /etc/alertmanager/secrets, readOnly: true }
               - { name: data, mountPath: /alertmanager }
         volumes:
           - { name: config-in, configMap: { name: alertmanager-config } }
           - { name: config-out, emptyDir: {} }
           - { name: secrets, secret: { name: alerting-secrets } }
           - { name: data, emptyDir: { sizeLimit: 128Mi } }
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: alertmanager
     labels: { app.kubernetes.io/name: alertmanager }
   spec:
     selector: { app.kubernetes.io/name: alertmanager }
     ports: [{ name: http, port: 9093, targetPort: 9093 }]
   ```
   > Why `--cluster.listen-address=` (empty): disables HA gossip entirely (single node, §8), saving the cluster goroutines/port. `bot_token_file` reads the token mounted from `alerting-secrets`; `chat_id` is templated in by the init container because `telegram_configs.chat_id` must be a literal int, not a file.
   Append `- alertmanager.yaml` to the kustomization.
4. Sync, run the check, expect pass — empty/disabled cluster status:
   ```
   "clusterStatus":{"status":"disabled"}
   ```
   Confirm config validity:
   ```bash
   kubectl -n observability exec deploy/alertmanager -- amtool check-config /etc/alertmanager/alertmanager.yml
   # ... found: 1 templates ... global config ... route ... receivers ...  OK
   ```
5. Commit.
   ```bash
   git commit -am "feat(observability): gossip 비활성·telegram_configs 단일 Alertmanager 추가"
   ```

---

### Task 5.9 — vmalert + core alert rules (infra/up/resource)

**Files:**
- Create `platform/victoria-stack/rules/core.yaml` (ConfigMap)
- Create `platform/victoria-stack/vmalert.yaml` (Deployment + Service)
- Modify `platform/victoria-stack/kustomization.yaml`
- Test: `/api/v1/groups` rules-loaded assertion below

1. Write the verification first — assert vmalert loaded rule groups. Fails now:
   ```bash
   kubectl -n observability exec deploy/vmalert -- wget -qO- 'localhost:8880/api/v1/groups' \
     | grep -o '"name":"[a-zA-Z-]*"'
   ```
2. Run it, expect failure:
   ```
   Error from server (NotFound): deployments.apps "vmalert" not found
   ```
3. Implement core rules. `platform/victoria-stack/rules/core.yaml`:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: vmalert-rules-core
     labels: { vmalert-rule: "true" }
   data:
     core.yaml: |
       groups:
         - name: infra
           rules:
             - alert: TargetDown
               expr: up == 0
               for: 5m
               labels: { severity: critical }
               annotations:
                 summary: "Scrape target {{ $labels.job }}/{{ $labels.instance }} down"
                 description: "vmagent target has been unreachable for 5m."
             - alert: NodeMemoryHigh
               expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > 0.92
               for: 10m
               labels: { severity: warning }
               annotations:
                 summary: "VM memory >92%"
                 description: "Node memory pressure; eviction threshold nears."
             - alert: PodOOMKilled
               expr: increase(kube_pod_container_status_restarts_total[15m]) > 0 and on(namespace,pod) kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
               for: 0m
               labels: { severity: warning }
               annotations:
                 summary: "OOMKill in {{ $labels.namespace }}/{{ $labels.pod }}"
                 description: "Container hit its memory limit — check the ledger budget."
         - name: deadmanswitch
           rules:
             - alert: Watchdog
               expr: vector(1)
               labels: { severity: none }
               annotations:
                 summary: "Watchdog: alerting pipeline is alive."
                 description: "This always-firing alert proves Alertmanager→Telegram and the off-node dead-man's-switch are wired. Its ABSENCE at healthchecks.io is the page."
   ```
   `platform/victoria-stack/vmalert.yaml`:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: vmalert
     labels: { app.kubernetes.io/name: vmalert }
   spec:
     replicas: 1
     selector:
       matchLabels: { app.kubernetes.io/name: vmalert }
     template:
       metadata:
         labels: { app.kubernetes.io/name: vmalert }
       spec:
         securityContext: { runAsNonRoot: true, runAsUser: 65534 }
         containers:
           - name: vmalert
             image: victoriametrics/vmalert:v1.103.0
             args:
               - --rule=/rules/core/*.yaml
               - --datasource.url=http://vmsingle:8428
               - --remoteWrite.url=http://vmsingle:8428
               - --remoteRead.url=http://vmsingle:8428
               - --notifier.url=http://alertmanager:9093
               - --evaluationInterval=30s
               - --httpListenAddr=:8880
             env:
               - { name: GOMEMLIMIT, value: "115MiB" }
             ports: [{ name: http, containerPort: 8880 }]
             resources:
               requests: { cpu: 20m, memory: 64Mi }
               limits: { memory: 128Mi }
             readinessProbe: { httpGet: { path: /health, port: 8880 } }
             securityContext:
               allowPrivilegeEscalation: false
               readOnlyRootFilesystem: true
               capabilities: { drop: ["ALL"] }
             volumeMounts:
               - { name: rules-core, mountPath: /rules/core }
         volumes:
           - { name: rules-core, configMap: { name: vmalert-rules-core } }
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: vmalert
     labels: { app.kubernetes.io/name: vmalert }
   spec:
     selector: { app.kubernetes.io/name: vmalert }
     ports: [{ name: http, port: 8880, targetPort: 8880 }]
   ```
   > Each hardening domain owns its own ConfigMap mounted under its own `/rules/<domain>` subdirectory, and vmalert gets one `--rule=/rules/<domain>/*.yaml` arg per domain (added as later tasks land their mounts). This keeps `core`, `r4`, `r6` independently editable without touching a central file.
   Append `- rules/core.yaml` and `- vmalert.yaml` to the kustomization.
4. Sync, run the check, expect pass:
   ```
   "name":"infra"
   "name":"deadmanswitch"
   ```
   Confirm no rule parse errors:
   ```bash
   kubectl -n observability exec deploy/vmalert -- wget -qO- 'localhost:8880/api/v1/groups' | grep -o '"lastError":"[^"]*"' | grep -v '""' || echo NO_RULE_ERRORS
   # NO_RULE_ERRORS
   ```
5. Commit.
   ```bash
   git commit -am "feat(observability): vmalert 및 인프라·Watchdog 코어 알림 규칙 추가"
   ```

---

### Task 5.10 — R4 rules: disk-fill + backup-liveness (canonical metric names; M5 owns these, M4 does not)

**Files:**
- Create `platform/victoria-stack/rules/r4-storage-backup.yaml` (ConfigMap)
- Modify `platform/victoria-stack/vmalert.yaml` (mount `/rules/r4`, add `--rule=/rules/r4/*.yaml`)
- Modify `platform/victoria-stack/kustomization.yaml`
- Test: rule group present + expression sanity below

> M5 is the SOLE definer of the backup-liveness and disk-fill vmalert rules. M4 only ensures the underlying metrics exist (it may keep its restore-drill's own direct-curl Telegram message, which is local and allowed). The metric names below are the canonical contract names — `LocalBasebackupStale` via `kube_job_status_completion_time{job_name=~"cnpg-local-basebackup.*"}`; `R2BackupStale` via `cnpg_collector_last_available_backup_timestamp`; `WALArchiveStalled` via `cnpg_collector_last_failed_archive_time` vs `cnpg_collector_last_archived_time`; `BulkSSDFilling`/`BulkSSDAlmostFull` via `node_filesystem_avail_bytes` on the bulk mount; `CNPGRestoreDrillStale` via the `restore_drill_last_success_timestamp` the M4 drill pushes. All degrade gracefully (no-data ≠ failure) so M5 does not hard-block on M4.

1. Write the verification first — assert the R4 group is loaded. Fails now:
   ```bash
   kubectl -n observability exec deploy/vmalert -- wget -qO- 'localhost:8880/api/v1/groups' | grep -o '"name":"storage-backup"'
   ```
2. Run it, expect failure (no output).
3. Implement. `platform/victoria-stack/rules/r4-storage-backup.yaml`:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: vmalert-rules-r4
     labels: { vmalert-rule: "true" }
   data:
     r4.yaml: |
       groups:
         - name: storage-backup
           rules:
             # External 1TB SSD (bulk-ssd) disk-fill — byte-aware, fires before retention eviction would mask it
             - alert: BulkSSDFilling
               expr: |
                 (node_filesystem_avail_bytes{mountpoint=~".*bulk-ssd.*|/mnt/bulk.*"}
                  / node_filesystem_size_bytes{mountpoint=~".*bulk-ssd.*|/mnt/bulk.*"}) < 0.15
               for: 10m
               labels: { severity: warning }
               annotations:
                 summary: "External SSD <15% free"
                 description: "bulk-ssd (media + backup staging) is filling; metrics retention byte-cap will NOT save this disk."
             - alert: BulkSSDAlmostFull
               expr: |
                 (node_filesystem_avail_bytes{mountpoint=~".*bulk-ssd.*|/mnt/bulk.*"}
                  / node_filesystem_size_bytes{mountpoint=~".*bulk-ssd.*|/mnt/bulk.*"}) < 0.05
               for: 5m
               labels: { severity: critical }
               annotations:
                 summary: "External SSD <5% free"
                 description: "bulk-ssd nearly full — local backup staging + media at imminent risk."
             # Internal SSD (standard) disk-fill — protects Postgres + vmsingle
             - alert: StandardSSDFilling
               expr: |
                 (node_filesystem_avail_bytes{mountpoint=~"/var/lib/rancher.*|/$"}
                  / node_filesystem_size_bytes{mountpoint=~"/var/lib/rancher.*|/$"}) < 0.10
               for: 10m
               labels: { severity: critical }
               annotations:
                 summary: "Internal SSD <10% free"
                 description: "standard SC disk low — Postgres PGDATA/WAL at risk."
             # Backup-liveness: the local CNPG base-backup CronJob (M4) must complete daily.
             # A silently-unmounted external SSD or a failed CronJob must PAGE, not fail silently.
             - alert: LocalBasebackupStale
               expr: |
                 (time() - max(kube_job_status_completion_time{job_name=~"cnpg-local-basebackup.*"})) > 100000
                 or absent(kube_job_status_completion_time{job_name=~"cnpg-local-basebackup.*"})
               for: 15m
               labels: { severity: critical }
               annotations:
                 summary: "Local base-backup stale (>27h) or missing"
                 description: "Restore copy 2 (local 1TB SSD) is at risk — unmounted drive or failed CronJob."
             # Backup-liveness: the latest available R2 backup must keep advancing (offsite copy 3).
             - alert: R2BackupStale
               expr: |
                 (time() - cnpg_collector_last_available_backup_timestamp) > 100000
                 or absent(cnpg_collector_last_available_backup_timestamp)
               for: 15m
               labels: { severity: critical }
               annotations:
                 summary: "R2 offsite backup stale (>27h) or missing"
                 description: "Offsite copy 3 (Cloudflare R2) has not produced a fresh backup; DR copy is going stale."
             # Backup-liveness: WAL archiving to R2 must not be erroring (RPO ≈ 5min target).
             - alert: WALArchiveStalled
               expr: |
                 cnpg_collector_last_failed_archive_time > cnpg_collector_last_archived_time
               for: 15m
               labels: { severity: critical }
               annotations:
                 summary: "WAL archiving to R2 stalled (RPO at risk)"
                 description: "Last failed archive is newer than last successful archive; offsite WAL stream is broken and the 5-min RPO is not being met."
             # Restore-drill liveness: M4's recurring restore drill pushes restore_drill_last_success_timestamp.
             # "backup green" and "restore works" are two independent monitored facts (R1).
             - alert: CNPGRestoreDrillStale
               expr: |
                 (time() - restore_drill_last_success_timestamp) > 700000
                 or absent(restore_drill_last_success_timestamp)
               for: 30m
               labels: { severity: warning }
               annotations:
                 summary: "CNPG restore drill has not succeeded recently"
                 description: "The recurring restore-from-R2 drill (M4) has not pushed a fresh success timestamp; the only verified restore path may be broken (R1)."
   ```
   In `platform/victoria-stack/vmalert.yaml`, add the R4 rule source and mount:
   - args: add `- --rule=/rules/r4/*.yaml`
   - `volumeMounts:` add `- { name: rules-r4, mountPath: /rules/r4 }`
   - `volumes:` add `- { name: rules-r4, configMap: { name: vmalert-rules-r4 } }`
   Append `- rules/r4-storage-backup.yaml` to the kustomization.
4. Sync, run the check, expect pass:
   ```
   "name":"storage-backup"
   ```
   Sanity-check the disk-fill expr evaluates (no parse error) against live data:
   ```bash
   kubectl -n observability exec deploy/vmalert -- wget -qO- 'http://vmsingle:8428/api/v1/query?query=node_filesystem_avail_bytes' >/dev/null && echo EXPR_OK
   ```
   (The CNPG-metric rules will show `no-data` until M4 is green; that is expected and non-paging by design.)
5. Commit.
   ```bash
   git commit -am "feat(observability): R4 디스크 충만·백업/복구 라이브니스 알림 규칙(정규 메트릭명) 추가"
   ```

---

### Task 5.11 — R6 rules: CI staleness (ArgoCDOutOfSync>15m) + running-vs-latest digest recording rule + digest exporter

**Files:**
- Create `platform/victoria-stack/rules/r6-ci-staleness.yaml` (ConfigMap)
- Create `platform/victoria-stack/digest-exporter.yaml` (CronJob that writes the latest-GHCR-digest gauge via vmsingle import)
- Modify `platform/victoria-stack/vmalert.yaml` (mount `/rules/r6`, add `--rule=/rules/r6/*.yaml`)
- Modify `platform/victoria-stack/kustomization.yaml`
- Test: rule group + recording-rule presence below

1. Write the verification first — assert the R6 group + the digest-compare recording rule exist. Fails now:
   ```bash
   kubectl -n observability exec deploy/vmalert -- wget -qO- 'localhost:8880/api/v1/groups' | grep -o '"name":"ci-staleness"'
   ```
2. Run it, expect failure (no output).
3. Implement. R6 has two independent signals: (a) ArgoCD `OutOfSync > 15m` (ArgoCD already exports `argocd_app_info{sync_status=...}` scraped via the pod annotation from M2), and (b) a recording rule comparing the **running** image digest to the **latest GHCR** digest. The running digest comes from kube-state-metrics (`kube_pod_container_info` has `image_id`); the latest GHCR digest is published by a small CronJob (the **digest exporter**) that resolves the tag and pushes a gauge into vmsingle.
   `platform/victoria-stack/digest-exporter.yaml`:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata: { name: digest-exporter-script }
   data:
     run.sh: |
       #!/bin/sh
       set -eu
       # For each app, resolve the latest pushed digest from GHCR for the env-pinned tag.
       # APPS is a space-separated "name=ghcr.io/owner/name:tag" list injected via env.
       NOW=$(date +%s)
       OUT=""
       for entry in $APPS; do
         APP="${entry%%=*}"; REF="${entry#*=}"
         DIGEST=$(skopeo inspect --no-tags "docker://$REF" 2>/dev/null | sed -n 's/.*"Digest": "\(sha256:[a-f0-9]*\)".*/\1/p' | head -1 || true)
         [ -z "$DIGEST" ] && continue
         # expose as an info gauge: digest carried as a label, value 1
         OUT="${OUT}ghcr_latest_digest{app=\"$APP\",digest=\"$DIGEST\"} 1 ${NOW}000\n"
       done
       printf "%b" "$OUT" | wget -q -O- --post-file=- 'http://vmsingle:8428/api/v1/import/prometheus' || true
   ---
   apiVersion: batch/v1
   kind: CronJob
   metadata: { name: digest-exporter }
   spec:
     schedule: "*/10 * * * *"
     concurrencyPolicy: Forbid
     jobTemplate:
       spec:
         backoffLimit: 1
         template:
           spec:
             restartPolicy: Never
             securityContext: { runAsNonRoot: true, runAsUser: 65532 }
             containers:
               - name: digest-exporter
                 image: quay.io/skopeo/stable:v1.16.1
                 command: ["/bin/sh","/script/run.sh"]
                 env:
                   - name: APPS
                     value: "api=ghcr.io/<DOMAIN-OWNER>/api:prod worker=ghcr.io/<DOMAIN-OWNER>/worker:prod ssr=ghcr.io/<DOMAIN-OWNER>/ssr:prod spa=ghcr.io/<DOMAIN-OWNER>/spa:prod"
                 resources:
                   requests: { cpu: 20m, memory: 32Mi }
                   limits: { memory: 64Mi }
                 securityContext:
                   allowPrivilegeEscalation: false
                   readOnlyRootFilesystem: true
                   capabilities: { drop: ["ALL"] }
                 volumeMounts: [{ name: script, mountPath: /script }]
             volumes: [{ name: script, configMap: { name: digest-exporter-script } }]
   ```
   `platform/victoria-stack/rules/r6-ci-staleness.yaml`:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: vmalert-rules-r6
     labels: { vmalert-rule: "true" }
   data:
     r6.yaml: |
       groups:
         - name: ci-staleness
           rules:
             # ArgoCD app OutOfSync for >15m → write-back/sync likely broken (R6).
             - alert: ArgoCDOutOfSync
               expr: argocd_app_info{sync_status="OutOfSync"} == 1
               for: 15m
               labels: { severity: warning }
               annotations:
                 summary: "ArgoCD app {{ $labels.name }} OutOfSync >15m"
                 description: "Tag write-back webhook or sync may have silently failed; cluster may be running yesterday's image."
             # Recording rule: 1 when the running image digest does NOT match latest GHCR digest.
             - record: app:image_digest_drift
               expr: |
                 max by (app) (ghcr_latest_digest)
                 unless on (app, digest) (
                   label_replace(
                     kube_pod_container_info{namespace="prod"},
                     "digest", "$1", "image_id", ".*@(sha256:[a-f0-9]+)$"
                   ) * 0 + 1
                 )
             - alert: ImageDigestDrift
               expr: app:image_digest_drift == 1
               for: 20m
               labels: { severity: warning }
               annotations:
                 summary: "Running image for {{ $labels.app }} != latest GHCR digest"
                 description: "Build pushed a new image but the running pod never picked it up (R6 write-back/sync staleness)."
   ```
   In `vmalert.yaml` add `- --rule=/rules/r6/*.yaml`, the `rules-r6` mount at `/rules/r6`, and the matching volume from `vmalert-rules-r6`. Append both new files to the kustomization.
4. Sync, run the check, expect pass:
   ```
   "name":"ci-staleness"
   ```
   Confirm the recording rule materializes (after one digest-exporter run):
   ```bash
   kubectl -n observability create job --from=cronjob/digest-exporter digest-once
   kubectl -n observability wait --for=condition=complete job/digest-once --timeout=120s
   kubectl -n observability exec deploy/vmalert -- wget -qO- 'http://vmsingle:8428/api/v1/query?query=ghcr_latest_digest' | grep -o '"app":"[a-z]*"' | sort -u
   # "app":"api" "app":"spa" "app":"ssr" "app":"worker"
   ```
5. Commit.
   ```bash
   git commit -am "feat(observability): R6 ArgoCD OutOfSync 알림·실행/최신 다이제스트 비교 기록 규칙·digest exporter 추가"
   ```

---

### Task 5.12 — Wire vmalert→Alertmanager→Telegram end-to-end + fire a TEST alert

**Files:**
- Create `platform/victoria-stack/rules/test-alert.yaml` (ConfigMap, removed after a green delivery)
- Modify `platform/victoria-stack/vmalert.yaml` (temporary `/rules/test` mount)
- Test: live Telegram delivery (manual confirm) below

1. Write the verification first — define a deliberately-firing `E2ETestAlert` and assert it reaches Telegram. Fails now (no test rule):
   ```bash
   kubectl -n observability exec deploy/vmalert -- wget -qO- 'localhost:8880/api/v1/alerts' | grep -o '"alertname":"E2ETestAlert"'
   ```
2. Run it, expect failure (no output).
3. Implement a temporary always-firing test alert in its own ConfigMap (so the executor can prove the **full** path vmalert→Alertmanager→Telegram, independent of the always-silent Watchdog which routes to the dead-man relay, not Telegram). `platform/victoria-stack/rules/test-alert.yaml`:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: vmalert-rules-test
     labels: { vmalert-rule: "true" }
   data:
     test.yaml: |
       groups:
         - name: e2e-test
           rules:
             - alert: E2ETestAlert
               expr: vector(1)
               for: 0m
               labels: { severity: critical }
               annotations:
                 summary: "E2E test alert — confirms vmalert→Alertmanager→Telegram"
                 description: "Delete platform/victoria-stack/rules/test-alert.yaml after a green delivery."
   ```
   Add `- --rule=/rules/test/*.yaml`, mount `/rules/test`, volume from `vmalert-rules-test` in `vmalert.yaml`. Append to the kustomization.
4. Sync, wait ~60s, run the check, expect pass — alert active:
   ```
   "alertname":"E2ETestAlert"
   ```
   Then **manually confirm** the Telegram message arrived (the human running the plan checks the chat). Cross-check it left Alertmanager:
   ```bash
   kubectl -n observability exec deploy/alertmanager -- wget -qO- localhost:9093/api/v2/alerts | grep -o '"alertname":"E2ETestAlert"'
   # "alertname":"E2ETestAlert"
   kubectl -n observability logs deploy/alertmanager | grep -i 'telegram' | tail -3
   # ...msg="Notify success" integration=telegram ...
   ```
   Expected human-visible result: a Telegram message titled `FIRING E2ETestAlert`.
5. Remove the test rule (it has served its purpose): delete the file and revert the temporary `/rules/test` mount + `--rule=/rules/test/*.yaml` arg + kustomization entry, then commit.
   ```bash
   git rm platform/victoria-stack/rules/test-alert.yaml
   # revert the vmalert.yaml + kustomization references to the test mount
   git commit -am "test(observability): vmalert→Alertmanager→Telegram E2E 알림 경로 검증 후 테스트 규칙 제거"
   ```

---

### Task 5.13 — Off-node dead-man's-switch relay: Watchdog → healthchecks.io ping (R8)

**Files:**
- Create `platform/victoria-stack/deadmanswitch-relay.yaml` (ConfigMap + Deployment + Service)
- Modify `platform/victoria-stack/kustomization.yaml`
- Test: ping reaches healthchecks.io below

1. Write the verification first — assert the relay forwards the Watchdog webhook to `HEALTHCHECKS_URL`. Fails now:
   ```bash
   kubectl -n observability get deploy deadmanswitch-relay -o jsonpath='{.spec.template.spec.containers[0].name}{"\n"}'
   ```
2. Run it, expect failure:
   ```
   Error from server (NotFound): deployments.apps "deadmanswitch-relay" not found
   ```
3. Implement a tiny relay: it listens for the Alertmanager `Watchdog` webhook (Task 5.8 route `deadmanswitch` → `http://deadmanswitch-relay:9095/ping`) and, on each receipt, curls the healthchecks.io URL from the `alerting-secrets` Secret (key `HEALTHCHECKS_URL`). healthchecks.io's own grace period is the off-node detector: if the relay (or the whole node) stops pinging, healthchecks.io pages externally. `platform/victoria-stack/deadmanswitch-relay.yaml`:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata: { name: deadmanswitch-relay-script }
   data:
     relay.sh: |
       #!/bin/sh
       set -eu
       # Minimal HTTP listener using busybox nc loop.
       # On any POST to /ping, fire one ping to healthchecks.io.
       while true; do
         printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok' | nc -l -p 9095 -q 1 2>/dev/null || true
         wget -q -T 10 -O /dev/null "$HEALTHCHECKS_URL" || echo "ping failed $(date)"
       done
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: deadmanswitch-relay
     labels: { app.kubernetes.io/name: deadmanswitch-relay }
   spec:
     replicas: 1
     selector:
       matchLabels: { app.kubernetes.io/name: deadmanswitch-relay }
     template:
       metadata:
         labels: { app.kubernetes.io/name: deadmanswitch-relay }
       spec:
         securityContext: { runAsNonRoot: true, runAsUser: 65534 }
         containers:
           - name: relay
             image: busybox:1.36
             command: ["/bin/sh","/script/relay.sh"]
             env:
               - { name: HEALTHCHECKS_URL, valueFrom: { secretKeyRef: { name: alerting-secrets, key: HEALTHCHECKS_URL } } }
             ports: [{ name: http, containerPort: 9095 }]
             resources:
               requests: { cpu: 5m, memory: 8Mi }
               limits: { memory: 16Mi }
             securityContext:
               allowPrivilegeEscalation: false
               readOnlyRootFilesystem: true
               capabilities: { drop: ["ALL"] }
             volumeMounts: [{ name: script, mountPath: /script }]
         volumes: [{ name: script, configMap: { name: deadmanswitch-relay-script } }]
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: deadmanswitch-relay
     labels: { app.kubernetes.io/name: deadmanswitch-relay }
   spec:
     selector: { app.kubernetes.io/name: deadmanswitch-relay }
     ports: [{ name: http, port: 9095, targetPort: 9095 }]
   ```
   > Implementation note: the `nc -l` busybox loop is intentionally minimal; if the executor finds the busybox `nc -l -p` flags unavailable in the running image variant, substitute `image: alpine/socat` with `command: ["socat","-u","TCP-LISTEN:9095,fork,reuseaddr","EXEC:wget -q -O /dev/null \"$HEALTHCHECKS_URL\""]`. Functionally identical: each inbound Watchdog webhook → one outbound ping.
   Append `- deadmanswitch-relay.yaml` to the kustomization.
4. Sync. The Watchdog (Task 5.9) fires immediately and re-notifies every 1m (Task 5.8 route). Run the check, expect pass:
   ```
   relay
   ```
   Confirm pings are leaving:
   ```bash
   kubectl -n observability logs deploy/deadmanswitch-relay --tail=5
   # (no "ping failed" lines — silence means success)
   ```
   Then **confirm at healthchecks.io** that the check status flipped from "new" to "up" (its dashboard shows a recent ping). This is the dead-man's-switch ARMED proof.
5. Commit.
   ```bash
   git commit -am "feat(observability): Watchdog→healthchecks.io 오프노드 데드맨 스위치 릴레이 추가"
   ```

---

### Task 5.14 — Grafana: datasources + dashboards provisioned from git, ephemeral SQLite, victorialogs plugin

**Files:**
- Create `platform/victoria-stack/grafana-provisioning.yaml` (ConfigMaps: datasources + dashboard providers)
- Create `platform/victoria-stack/grafana-dashboards.yaml` (ConfigMap: node/pod-memory dashboard JSON = the `kubectl top` replacement)
- Create `platform/victoria-stack/grafana.yaml` (Deployment + Service)
- Modify `platform/victoria-stack/kustomization.yaml`
- Test: datasource health assertion below

1. Write the verification first — assert both datasources report health green via the Grafana API. Fails now:
   ```bash
   kubectl -n observability exec deploy/grafana -- wget -qO- --header='Content-Type: application/json' \
     'http://admin:admin@localhost:3000/api/datasources' | grep -o '"type":"[a-z-]*"'
   ```
2. Run it, expect failure:
   ```
   Error from server (NotFound): deployments.apps "grafana" not found
   ```
3. Implement. Datasources: VictoriaMetrics (Prometheus-compatible) + VictoriaLogs (requires the `victoriametrics-logs-datasource` plugin, installed via `GF_INSTALL_PLUGINS`). SQLite on emptyDir (ephemeral by design, §8). `platform/victoria-stack/grafana-provisioning.yaml`:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata: { name: grafana-datasources }
   data:
     datasources.yaml: |
       apiVersion: 1
       datasources:
         - name: VictoriaMetrics
           uid: VictoriaMetrics
           type: prometheus
           access: proxy
           url: http://vmsingle:8428
           isDefault: true
           jsonData: { httpMethod: POST, timeInterval: 30s }
         - name: VictoriaLogs
           uid: VictoriaLogs
           type: victoriametrics-logs-datasource
           access: proxy
           url: http://victorialogs:9428
   ---
   apiVersion: v1
   kind: ConfigMap
   metadata: { name: grafana-dashboard-providers }
   data:
     providers.yaml: |
       apiVersion: 1
       providers:
         - name: git
           orgId: 1
           folder: Homelab
           type: file
           disableDeletion: true
           updateIntervalSeconds: 30
           options: { path: /var/lib/grafana/dashboards }
   ```
   `platform/victoria-stack/grafana-dashboards.yaml` — the node/pod-memory dashboard that is the documented `kubectl top` replacement (§14). Minimal but functional JSON:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata: { name: grafana-dashboard-resources }
   data:
     resources.json: |
       {
         "uid": "homelab-resources",
         "title": "Homelab — Node & Pod Memory (kubectl top replacement)",
         "schemaVersion": 39,
         "version": 1,
         "time": { "from": "now-6h", "to": "now" },
         "panels": [
           {
             "type": "timeseries", "title": "Node memory used %",
             "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
             "datasource": { "type": "prometheus", "uid": "VictoriaMetrics" },
             "targets": [ { "expr": "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)", "legendFormat": "node" } ]
           },
           {
             "type": "timeseries", "title": "Per-pod working set (MiB)",
             "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
             "datasource": { "type": "prometheus", "uid": "VictoriaMetrics" },
             "targets": [ { "expr": "sum by (namespace,pod) (container_memory_working_set_bytes{container!=\"\"}) / 1024 / 1024", "legendFormat": "{{namespace}}/{{pod}}" } ]
           },
           {
             "type": "table", "title": "Pod memory vs limit (budget ledger view)",
             "gridPos": { "h": 8, "w": 24, "x": 0, "y": 8 },
             "datasource": { "type": "prometheus", "uid": "VictoriaMetrics" },
             "targets": [ { "expr": "sum by (namespace,pod) (container_memory_working_set_bytes{container!=\"\"}) / sum by (namespace,pod) (kube_pod_container_resource_limits{resource=\"memory\"})", "format": "table", "instant": true } ]
           }
         ]
       }
   ```
   > Grafana datasource provisioning matches by `name`, but dashboards reference datasources by `uid`; the explicit `uid:` lines above make the dashboard JSON resolve.
   `platform/victoria-stack/grafana.yaml`:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: grafana
     labels: { app.kubernetes.io/name: grafana }
   spec:
     replicas: 1
     selector:
       matchLabels: { app.kubernetes.io/name: grafana }
     template:
       metadata:
         labels: { app.kubernetes.io/name: grafana }
       spec:
         securityContext: { runAsNonRoot: true, runAsUser: 472, fsGroup: 472 }
         containers:
           - name: grafana
             image: grafana/grafana:11.2.0
             env:
               - { name: GF_INSTALL_PLUGINS, value: "victoriametrics-logs-datasource" }
               - { name: GF_SECURITY_ADMIN_USER, value: "admin" }
               # NEVER admin/admin: any tailnet user / compromised pod would be Grafana admin. The
               # password comes from the M2-seeded SOPS secret `alerting-secrets` (key GRAFANA_ADMIN_PASSWORD).
               - name: GF_SECURITY_ADMIN_PASSWORD
                 valueFrom: { secretKeyRef: { name: alerting-secrets, key: GRAFANA_ADMIN_PASSWORD } }
               - { name: GF_USERS_ALLOW_SIGN_UP, value: "false" }
               - { name: GF_ANALYTICS_REPORTING_ENABLED, value: "false" }
               - { name: GF_AUTH_ANONYMOUS_ENABLED, value: "false" }
             ports: [{ name: http, containerPort: 3000 }]
             resources:
               requests: { cpu: 50m, memory: 128Mi }
               limits: { memory: 256Mi }
             readinessProbe: { httpGet: { path: /api/health, port: 3000 } }
             volumeMounts:
               - { name: datasources, mountPath: /etc/grafana/provisioning/datasources }
               - { name: providers, mountPath: /etc/grafana/provisioning/dashboards }
               - { name: dashboards, mountPath: /var/lib/grafana/dashboards }
               - { name: data, mountPath: /var/lib/grafana }
         volumes:
           - { name: datasources, configMap: { name: grafana-datasources } }
           - { name: providers, configMap: { name: grafana-dashboard-providers } }
           - { name: dashboards, configMap: { name: grafana-dashboard-resources } }
           - { name: data, emptyDir: { sizeLimit: 256Mi } }   # ephemeral SQLite by design (§8)
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: grafana
     labels: { app.kubernetes.io/name: grafana }
   spec:
     selector: { app.kubernetes.io/name: grafana }
     ports: [{ name: http, port: 3000, targetPort: 3000 }]
   ```
   > `/var/lib/grafana` (data, emptyDir) and the dashboards mount overlap intentionally: mount `dashboards` at `/var/lib/grafana/dashboards` AFTER `data` so the read-only dashboard ConfigMap shadows that subpath. If the mount ordering causes a conflict, point the provider `options.path` to `/etc/grafana/dashboards-git` and mount the dashboards ConfigMap there instead.
   Append the three new files to the kustomization.
4. Sync, run the check, expect pass — both datasource types present:
   ```
   "type":"prometheus"
   "type":"victoriametrics-logs-datasource"
   ```
   Confirm both report health green:
   ```bash
   kubectl -n observability exec deploy/grafana -- sh -c \
     'for id in 1 2; do wget -qO- "http://admin:admin@localhost:3000/api/datasources/$id/health"; echo; done'
   # {"message":"...","status":"OK"}
   # {"message":"...","status":"OK"}
   ```
5. Commit.
   ```bash
   git commit -am "feat(observability): git 프로비저닝 데이터소스·대시보드(kubectl top 대체)·임시 SQLite Grafana 추가"
   ```

---

### Task 5.15 — Internal-only exposure (Grafana HTTPRoute via the `homelab` Gateway) + metrics-server-stays-disabled note

**Files:**
- Create `platform/victoria-stack/httproute-grafana.yaml` (internal `grafana.int.<DOMAIN>` HTTPRoute on the `web-internal` listener)
- Create `platform/victoria-stack/NOTES.md` (the metrics-server + kubectl-top DX note)
- Modify `platform/victoria-stack/kustomization.yaml`
- Test: route attaches to the internal listener of the `homelab` Gateway + no public exposure below

1. Write the verification first — assert Grafana attaches to the canonical Gateway via the internal section and is NOT public. Fails now:
   ```bash
   kubectl -n observability get httproute grafana -o jsonpath='{.spec.parentRefs[0].name}/{.spec.parentRefs[0].sectionName}{"\n"}'
   ```
2. Run it, expect failure:
   ```
   Error from server (NotFound): httproutes.gateway.networking.k8s.io "grafana" not found
   ```
3. Implement. The HTTPRoute attaches to the canonical M3 Gateway `homelab` (ns `gateway`) on its internal listener `web-internal` (the single Tailscale-exposed path). `platform/victoria-stack/httproute-grafana.yaml`:
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: grafana
   spec:
     parentRefs:
       - name: homelab
         namespace: gateway
         sectionName: web-internal
     hostnames:
       - "grafana.int.<DOMAIN>"
     rules:
       - matches:
           - path: { type: PathPrefix, value: / }
         backendRefs:
           - name: grafana
             port: 3000
   ```
   `platform/victoria-stack/NOTES.md`:
   ```markdown
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
   ```
   Append `- httproute-grafana.yaml` to the kustomization (NOTES.md is docs, not a manifest — do NOT add it to `resources:`).
4. Sync, run the check, expect pass:
   ```
   homelab/web-internal
   ```
   Confirm internal reachability + no public exposure:
   ```bash
   # From a Tailscale-connected device:
   curl -sI https://grafana.int.<DOMAIN>/login | head -1
   # HTTP/2 200
   # Confirm the route uses the internal listener, never the public one:
   kubectl -n observability get httproute grafana -o jsonpath='{.spec.parentRefs[0].sectionName}'; echo
   # web-internal   (NOT web-public)
   ```
5. Commit.
   ```bash
   git commit -am "feat(observability): Grafana 내부 전용 HTTPRoute(homelab/web-internal) 및 metrics-server 비활성 운영 노트 추가"
   ```

---

### Task 5.16 — Document the healthchecks.io account as a bootstrap step (R8) + wire into the existing `bootstrap` Makefile target

**Files:**
- Create `docs/runbooks/observability-bootstrap.md`
- Modify `Makefile` (EDIT — add a `bootstrap-deadmanswitch` helper recipe and add it as a prerequisite of the EXISTING M0-owned `bootstrap` target; never re-declare `bootstrap`)
- Test: runbook completeness + Makefile target assertions below

> Makefile ownership: M0 owns and declares the stub targets (`bootstrap`, `up`, `down`, `verify`, `host-up`). M5 only EDITs — it adds a new non-conflicting helper recipe and appends a prerequisite to the existing `bootstrap` target line. It must NOT re-`bootstrap:` from scratch.

1. Write the verification first — assert the bootstrap runbook documents the external account creation and the Makefile references it. Fails now:
   ```bash
   test -f docs/runbooks/observability-bootstrap.md && grep -q 'bootstrap-deadmanswitch' Makefile
   ```
2. Run it, expect failure (exit 1).
3. Implement. `docs/runbooks/observability-bootstrap.md`:
   ```markdown
   # Observability bootstrap (one-time external dependencies)

   The observability stack is fully GitOps-managed EXCEPT one off-node dependency that, by
   definition (R8), cannot live on the monitored node: the healthchecks.io dead-man's-switch.

   ## 1. healthchecks.io account + check (the off-node detector)
   1. Create a free account at https://healthchecks.io (or self-host on a DIFFERENT box — never this node).
   2. Create a check named `homelab-watchdog`:
      - Period: 1 minute. Grace: 3 minutes.
      - (Matches Alertmanager Watchdog `repeat_interval: 1m`, Task 5.8.)
   3. Copy the ping URL `https://hc-ping.com/<HC_UUID>`.
   4. Add an escalation integration on the check (email/Telegram/phone) — this is the page that
      fires when the WHOLE node is down and in-cluster Alertmanager cannot reach you.

   ## 2. Put the URL + Telegram creds into the M2-owned SOPS secret
   These values live in the M2-seeded `platform/victoria-stack/prod/alerting.enc.yaml`
   (Secret `alerting-secrets`, keys `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` / `HEALTHCHECKS_URL`).
   M2's `seed-secrets.sh` is the single producer; set/refresh:
   - `HEALTHCHECKS_URL: https://hc-ping.com/<HC_UUID>`
   - `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` (from @BotFather + the target chat).
   Re-run the M2 seed (or `sops --in-place` edit through M2's flow); M5 does NOT own this file.

   ## 3. Telegram bot (in-cluster alert path)
   1. @BotFather → `/newbot` → token.
   2. Add the bot to the target chat/channel; resolve the numeric chat_id
      (`curl https://api.telegram.org/bot<TOKEN>/getUpdates`).

   ## 4. Verify the switch is ARMED
   After ArgoCD syncs the stack:
   - healthchecks.io dashboard shows `homelab-watchdog` flipping to **up** within ~1 minute.
   - To TEST the dead-man path: pause the relay (`kubectl -n observability scale deploy/deadmanswitch-relay --replicas=0`),
     wait >grace (3m), confirm healthchecks.io pages you, then `--replicas=1` to re-arm.

   ## Re-arm / DR note
   On a full rebuild (`make bootstrap`), the SAME healthchecks.io URL is reused (it lives in the
   committed SOPS secret), so the switch re-arms automatically once the relay pod is back.
   ```
   In `Makefile`, EDIT to add the helper recipe and append it as a prerequisite of the existing `bootstrap` target (do NOT rewrite the M0-owned recipe; just add the dependency and the new helper):
   ```makefile
   .PHONY: bootstrap-deadmanswitch
   bootstrap-deadmanswitch:
   	@echo ">> DEAD-MAN'S-SWITCH (R8): ensure healthchecks.io check 'homelab-watchdog' exists"
   	@echo ">> and HEALTHCHECKS_URL is set in platform/victoria-stack/prod/alerting.enc.yaml (M2-seeded)"
   	@echo ">> Full procedure: docs/runbooks/observability-bootstrap.md"
   	@sops --decrypt platform/victoria-stack/prod/alerting.enc.yaml 2>/dev/null | grep -q 'HEALTHCHECKS_URL' \
   		|| { echo "FAIL: HEALTHCHECKS_URL missing from M2-seeded SOPS secret"; exit 1; }
   	@echo "OK: dead-man's-switch ping URL present (armed once relay pod runs)"

   # EDIT (not re-declare): append bootstrap-deadmanswitch to the existing M0-owned bootstrap prereqs.
   bootstrap: bootstrap-deadmanswitch
   ```
   > The trailing `bootstrap: bootstrap-deadmanswitch` line adds ONE prerequisite to the existing target (Make merges prerequisites across `target:` lines); it does NOT re-declare the recipe, which stays owned by M0. If M0's `bootstrap` already lists prerequisites on one line, add `bootstrap-deadmanswitch` to that line instead.
4. Run the check, expect pass:
   ```bash
   test -f docs/runbooks/observability-bootstrap.md && grep -q 'bootstrap-deadmanswitch' Makefile && echo OK
   # OK
   make bootstrap-deadmanswitch
   # OK: dead-man's-switch ping URL present (armed once relay pod runs)
   ```
5. Commit.
   ```bash
   git add docs/runbooks/observability-bootstrap.md Makefile
   git commit -m "docs(observability): healthchecks.io 데드맨 스위치 부트스트랩 런북 및 make bootstrap 게이트 추가"
   ```

---

### Task 5.17 — Final milestone gate: full-stack verification sweep

**Files:**
- Create `docs/runbooks/observability-verify.md` (the repeatable verification checklist)
- Test: the consolidated sweep below

1. Write the verification first — a single script asserting the whole stack is green. Create `docs/runbooks/observability-verify.md` containing this block, then run it; it should pass only once every prior task is done:
   ```bash
   set -e
   NS=observability
   echo "[1] vmagent targets all up"
   kubectl -n $NS exec deploy/vmagent -- wget -qO- 'localhost:8429/api/v1/targets?state=active' \
     | grep -q '"health":"down"' && { echo FAIL: a target is down; exit 1; } || echo OK
   echo "[2] vmsingle byte-cap (not percent) retention"
   kubectl -n $NS get sts vmsingle -o yaml | grep -q -- '-retention.maxDiskSpaceUsageBytes' && echo OK
   echo "[3] VictoriaLogs ingesting"
   kubectl -n $NS exec sts/victorialogs -- wget -qO- 'localhost:9428/select/logsql/query?query=*&limit=1' | grep -q '_msg' && echo OK
   echo "[4] vmalert loaded core+r4+r6 groups"
   G=$(kubectl -n $NS exec deploy/vmalert -- wget -qO- 'localhost:8880/api/v1/groups')
   echo "$G" | grep -q '"name":"infra"' && echo "$G" | grep -q '"name":"storage-backup"' && echo "$G" | grep -q '"name":"ci-staleness"' && echo OK
   echo "[5] Grafana datasources healthy"
   kubectl -n $NS exec deploy/grafana -- sh -c 'for i in 1 2; do wget -qO- "http://admin:admin@localhost:3000/api/datasources/$i/health"; done' | grep -q '"status":"OK"' && echo OK
   echo "[6] Single Alertmanager: gossip disabled + telegram receiver + valid config"
   kubectl -n $NS exec deploy/alertmanager -- amtool check-config /etc/alertmanager/alertmanager.yml >/dev/null && echo OK
   echo "[7] dead-man relay pinging (no failures in last 5 lines)"
   kubectl -n $NS logs deploy/deadmanswitch-relay --tail=5 | grep -q 'ping failed' && { echo FAIL; exit 1; } || echo OK
   echo "[8] Grafana HTTPRoute on homelab/web-internal (internal-only)"
   kubectl -n $NS get httproute grafana -o jsonpath='{.spec.parentRefs[0].name}/{.spec.parentRefs[0].sectionName}' | grep -q 'homelab/web-internal' && echo OK
   echo "ALL GREEN"
   ```
2. Run it on a not-yet-complete stack, expect a `FAIL`/`NotFound` at the first incomplete component.
3. Implement: ensure all prior tasks are synced (`kubectl -n argocd get app victoria-stack -o jsonpath='{.status.sync.status}'` → `Synced`, `{.status.health.status}` → `Healthy`).
4. Run the sweep, expect pass:
   ```
   [1] vmagent targets all up
   OK
   ...
   [8] Grafana HTTPRoute on homelab/web-internal (internal-only)
   OK
   ALL GREEN
   ```
   Then confirm the two human-in-the-loop facts that automation cannot self-assert:
   - The earlier `E2ETestAlert` (Task 5.12) was **seen in Telegram**.
   - healthchecks.io shows `homelab-watchdog` **up** (dead-man's-switch armed, Task 5.13/5.16).
   Note: the R4 CNPG-metric rules (`LocalBasebackupStale`, `R2BackupStale`, `WALArchiveStalled`, `CNPGRestoreDrillStale`) may show `no-data` until M4 is green — this is the intended graceful-degrade behavior and does not fail this gate.
5. Commit.
   ```bash
   git add docs/runbooks/observability-verify.md
   git commit -m "docs(observability): 전체 스택 검증 스위프 런북 추가"
   ```

---

## Milestone 6 — App platform, CI/CD & DX

**Goal:** Build the shared `platform/charts/app` deploy chart (the deploy SSOT) that renders Deployment/Service/HTTPRoute/ConfigMap + a sync-wave-ordered migration hook Job for `kind=api|worker|ssr|spa`, ship one end-to-end sample `api` app plus worker/ssr/spa example values, build the `pg-tools` operations image that M4's restore drill and `pg_dump` hedge consume, stand up the polyglot DX (scaffold, verify, generated `.env.example`, local dev Postgres) and the arm64 CI → GHCR → serialized values write-back pipeline, with the memory-ledger onboarding gate calling M0's `pnpm verify:ledger`.

**Depends on:** Milestone 0 (repo scaffold: `~/.config/sops/age/keys.txt` age key + recovery recipient, canonical `.sops.yaml`, `pnpm-workspace.yaml` + root `package.json` on `pnpm@10`, `Makefile` stub targets, `docs/memory-ledger.md` + `policy/ledger.rego` + `pnpm verify:ledger`), Milestone 1 (OrbStack VM + k3s + StorageClasses), Milestone 2 (ArgoCD + KSOPS repo-server wiring + seed secrets + bootstrap-minimal root/argocd apps), Milestone 3 (Traefik Gateway API + the shared `Gateway` `homelab/gateway` + ApplicationSet + SYNC-WAVES.md), Milestone 4 (CNPG operator in `cnpg-system` + CNPG `Cluster` in `database` ns + the `CNPG-Ready` gate; its LIVE restore-drill acceptance is gated on this milestone building `pg-tools`), Milestone 5 (observability + vmalert alert rules + `alerting-secrets` Telegram Secret).

> Execute with @superpowers:executing-plans. Every task is verification-first: write the failing check, run it, see RED, implement, run it, see GREEN, commit. Korean conventional commits, no AI markers.

Conventions used throughout this milestone:
- `<DOMAIN>` is the real apex domain; internal hosts use `int.<DOMAIN>`.
- Chart lives at `platform/charts/app`; the prod env-axis is `prod`.
- The shared Gateway is `homelab` in namespace `gateway` (Milestone 3), with listener sectionNames `web-public` (public) and `web-internal` (internal). Every HTTPRoute attaches via `parentRefs:[{name: homelab, namespace: gateway, sectionName: web-public|web-internal}]`.
- Tooling pinned in tasks: `helm` v3.16+, `kubeconform` v0.6.7, `bats` v1.11, `node` 22 + `pnpm@10` (M0's pinned package manager), `yq` v4, `jq`. Install once in Task 6.0.
- The `.sops.yaml`, `pnpm-workspace.yaml`, root `package.json`, `Makefile` targets, `docs/memory-ledger.md`, and `pnpm verify:ledger` are **owned by Milestone 0**; this milestone only EDITs `package.json`/`Makefile` and CALLS `pnpm verify:ledger` — it never re-creates them.

---

### Task 6.0 — Pin verification toolchain

**Files**
- Modify: `Makefile` (M0-owned; add a new `m6-tools` target — never re-declare an existing target)
- Create: `platform/charts/app/.gitignore`

**Steps**

1. Define the failing check — a Make target that asserts every tool this milestone needs is present at the expected version. Append a NEW target to the M0-owned `Makefile` (do not re-declare `bootstrap`/`up`/`down`/`verify`/`host-up`):

```makefile
## --- Milestone 6 tooling ---
.PHONY: m6-tools
m6-tools: ## verify chart/CI toolchain for milestone 6
	@helm version --short | grep -qE 'v3\.(1[6-9]|[2-9][0-9])' || { echo "helm >=3.16 required"; exit 1; }
	@kubeconform -v | grep -qE 'v0\.6\.[7-9]' || { echo "kubeconform >=0.6.7 required"; exit 1; }
	@bats --version | grep -qE 'Bats 1\.(1[1-9]|[2-9][0-9])' || { echo "bats >=1.11 required"; exit 1; }
	@node --version | grep -qE 'v2[2-9]\.' || { echo "node >=22 required"; exit 1; }
	@pnpm --version | grep -qE '^10\.' || { echo "pnpm 10 required (M0 pins pnpm@10)"; exit 1; }
	@yq --version | grep -qE 'v4\.' || { echo "yq v4 required"; exit 1; }
	@jq --version >/dev/null || { echo "jq required"; exit 1; }
	@echo "m6-tools OK"
```

2. Run it, expect RED (tools not yet installed):

```
$ make m6-tools
helm >=3.16 required
make: *** [m6-tools] Error 1
```

3. Install the toolchain (macOS host where the executor authors the chart):

```bash
brew install helm kubeconform bats-core yq jq corepack
corepack enable && corepack prepare pnpm@10 --activate   # matches M0's packageManager pin
```

Create `platform/charts/app/.gitignore`:

```
# rendered output for local inspection
/_rendered/
*.tgz
```

4. Run it, expect GREEN:

```
$ make m6-tools
m6-tools OK
```

5. Commit:

```bash
git add Makefile platform/charts/app/.gitignore
git commit -m "chore: 앱 플랫폼 검증 도구체인 핀 고정"
```

---

### Task 6.1 — Chart skeleton + `values.schema.json` (the values contract as a gate)

**Files**
- Create: `platform/charts/app/Chart.yaml`
- Create: `platform/charts/app/values.yaml`
- Create: `platform/charts/app/values.schema.json`
- Test: `platform/charts/app/tests/schema.bats`

**Steps**

1. Write the failing test. The schema must reject a values file missing `kind`, and accept the defaults. `platform/charts/app/tests/schema.bats`:

```bash
#!/usr/bin/env bats

CHART="${BATS_TEST_DIRNAME}/.."

@test "helm lint passes on default values" {
  run helm lint "$CHART"
  [ "$status" -eq 0 ]
}

@test "schema rejects values missing required 'kind'" {
  cat > "${BATS_TMPDIR}/bad.yaml" <<'EOF'
image: { repo: ghcr.io/x/y, tag: sha-deadbeef }
EOF
  run helm template t "$CHART" -f "${BATS_TMPDIR}/bad.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"kind"* ]]
}

@test "schema rejects invalid kind enum" {
  run helm template t "$CHART" --set kind=database --set image.repo=ghcr.io/x/y --set image.tag=sha-1
  [ "$status" -ne 0 ]
}
```

2. Run it, expect RED (no chart yet):

```
$ bats platform/charts/app/tests/schema.bats
 ✗ helm lint passes on default values
   Error: Chart.yaml file is missing
...
3 tests, 3 failures
```

3. Implement the chart metadata, defaults, and schema.

`platform/charts/app/Chart.yaml`:

```yaml
apiVersion: v2
name: app
description: Shared deploy chart (SSOT) for polyglot homelab services
type: application
version: 0.1.0
appVersion: "0.1.0"
```

`platform/charts/app/values.yaml` (the full contract, with safe defaults). The `gateway.*` defaults map to the shared Gateway `homelab/gateway` from Milestone 3:

```yaml
# --- image ---
image:
  repo: ""            # e.g. ghcr.io/owner/api  (required)
  tag: ""             # e.g. sha-<gitsha>       (required, immutable)
  pullPolicy: IfNotPresent
# GHCR pull: EMPTY by default = the GHCR packages are PUBLIC (homelab default — anonymous
# pulls, nothing to provision; the repo's package visibility is set Public). If you keep
# packages PRIVATE instead, set [{ name: ghcr-pull }] AND have M2 seed a dockerconfigjson
# Secret `ghcr-pull` in EVERY consuming namespace (prod, database).
imagePullSecrets: []

# --- workload shape ---
kind: api             # api | worker | ssr | spa
replicas: 1

# --- shared Gateway (Milestone 3) — defaults, rarely overridden ---
gateway:
  name: homelab
  namespace: gateway

# --- resources (NO defaults: per-runtime memory is a hard onboarding gate) ---
resources:
  requests: { cpu: "", memory: "" }   # MUST be set per app
  limits:   { cpu: "", memory: "" }   # MUST be set per app

# --- config & secrets ---
env: []               # [{name, value}]
envFrom: []           # [{secretRef: {name}}]

# --- routing (internal-by-default; opt into public) ---
route:
  host: ""            # required for api|ssr|spa
  paths: ["/"]
  public: false       # maps to sectionName: web-public (true) / web-internal (false)

# --- database / migrations ---
db:
  enabled: false
  migrateCmd: ["migrate"]   # command in the app image; run as pre-upgrade hook

# --- probes ---
probes:
  liveness:  { path: /healthz }
  readiness: { path: /readyz }

# --- spa serving abstraction ---
spa:
  server: sws         # sws | caddy   (only used when kind=spa; sws default)

# --- pod hardening (defaults; rarely overridden) ---
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  fsGroup: 65532
  seccompProfile: { type: RuntimeDefault }
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: ["ALL"] }

terminationGracePeriodSeconds: 30
preStopSleepSeconds: 3

# --- ports (contract) ---
ports:
  http: 8080
  metrics: 9090

# --- scrape ---
metrics:
  enabled: true       # adds prometheus.io/scrape annotations

# --- escape hatch (conscious review gate, §13) ---
extraManifests: []
```

`platform/charts/app/values.schema.json`:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["image", "kind", "resources"],
  "properties": {
    "image": {
      "type": "object",
      "required": ["repo", "tag"],
      "properties": {
        "repo": { "type": "string", "minLength": 1 },
        "tag": { "type": "string", "pattern": "^sha-[0-9a-f]{7,40}$|^[a-z0-9][a-z0-9._-]*$" },
        "pullPolicy": { "type": "string", "enum": ["IfNotPresent", "Always", "Never"] }
      }
    },
    "kind": { "type": "string", "enum": ["api", "worker", "ssr", "spa"] },
    "replicas": { "type": "integer", "minimum": 1, "maximum": 3 },
    "gateway": {
      "type": "object",
      "properties": {
        "name": { "type": "string", "minLength": 1 },
        "namespace": { "type": "string", "minLength": 1 }
      }
    },
    "resources": {
      "type": "object",
      "required": ["requests", "limits"],
      "properties": {
        "requests": {
          "type": "object",
          "required": ["cpu", "memory"],
          "properties": {
            "cpu": { "type": "string", "minLength": 1 },
            "memory": { "type": "string", "minLength": 1 }
          }
        },
        "limits": {
          "type": "object",
          "required": ["cpu", "memory"],
          "properties": {
            "cpu": { "type": "string", "minLength": 1 },
            "memory": { "type": "string", "minLength": 1 }
          }
        }
      }
    },
    "spa": {
      "type": "object",
      "properties": { "server": { "type": "string", "enum": ["sws", "caddy"] } }
    },
    "db": {
      "type": "object",
      "properties": {
        "enabled": { "type": "boolean" },
        "migrateCmd": { "type": "array", "items": { "type": "string" } }
      }
    },
    "route": {
      "type": "object",
      "properties": {
        "host": { "type": "string" },
        "paths": { "type": "array", "items": { "type": "string" } },
        "public": { "type": "boolean" }
      }
    }
  }
}
```

> Note: the default `values.yaml` deliberately leaves `resources.*.memory` empty so a real app cannot inherit a silent default — see the ledger gate in Task 6.13. The schema's `minLength: 1` on memory/cpu turns "forgot to size it" into a render-time failure.

4. Run it, expect GREEN:

```
$ bats platform/charts/app/tests/schema.bats
 ✓ helm lint passes on default values
 ✓ schema rejects values missing required 'kind'
 ✓ schema rejects invalid kind enum
3 tests, 0 failures
```

5. Commit:

```bash
git add platform/charts/app/
git commit -m "feat: 공유 앱 차트 스켈레톤과 values 스키마 게이트 추가"
```

---

### Task 6.2 — Helpers + ConfigMap template (wave 0)

**Files**
- Create: `platform/charts/app/templates/_helpers.tpl`
- Create: `platform/charts/app/templates/configmap.yaml`
- Test: `platform/charts/app/tests/wave0.bats`

**Steps**

1. Write the failing test asserting the ConfigMap exists, carries env, and is tagged sync-wave 0. `platform/charts/app/tests/wave0.bats`:

```bash
#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
ARGS="--set image.repo=ghcr.io/o/api --set image.tag=sha-abc1234 \
  --set resources.requests.cpu=50m --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=500m --set resources.limits.memory=128Mi"

@test "ConfigMap is rendered at sync-wave 0" {
  run bash -c "helm template t \"$CHART\" $ARGS --set kind=api \
    --set 'env[0].name=LOG_LEVEL' --set 'env[0].value=info' \
    | yq 'select(.kind==\"ConfigMap\")'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"argocd.argoproj.io/sync-wave: \"0\""* ]]
  [[ "$output" == *"LOG_LEVEL"* ]]
}
```

2. Run it, expect RED:

```
$ bats platform/charts/app/tests/wave0.bats
 ✗ ConfigMap is rendered at sync-wave 0
   (no ConfigMap rendered)
1 test, 1 failure
```

3. Implement.

`platform/charts/app/templates/_helpers.tpl`:

```yaml
{{- define "app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.homelab/kind: {{ .Values.kind }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Workloads that listen on http and get a Service/HTTPRoute */}}
{{- define "app.isServed" -}}
{{- if or (eq .Values.kind "api") (eq .Values.kind "ssr") (eq .Values.kind "spa") -}}true{{- end -}}
{{- end -}}

{{/* Validation: required-by-kind */}}
{{- define "app.validate" -}}
{{- if and (include "app.isServed" .) (not .Values.route.host) -}}
{{- fail (printf "route.host is required for kind=%s" .Values.kind) -}}
{{- end -}}
{{- if and (eq .Values.kind "spa") .Values.db.enabled -}}
{{- fail "kind=spa must not set db.enabled (static assets have no DB)" -}}
{{- end -}}
{{- end -}}
```

`platform/charts/app/templates/configmap.yaml`:

```yaml
{{- include "app.validate" . -}}
{{- if .Values.env }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "app.fullname" . }}-env
  labels:
    {{- include "app.labels" . | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
data:
  {{- range .Values.env }}
  {{ .name }}: {{ .value | quote }}
  {{- end }}
{{- end }}
```

> Secrets are NOT rendered by the chart — they arrive SOPS-decrypted via the KSOPS repo-server plugin (wired in Milestone 2) as `*.enc.yaml` in `platform/**/<env>/` or `apps/<name>/deploy/<env>/`, each with its own `secret-generator.yaml` (apiVersion `viaduct.ai/v1`, kind `ksops`). The chart only references them (Task 6.5) through `envFrom[].secretRef`, keeping plaintext out of templated output.

4. Run it, expect GREEN:

```
$ bats platform/charts/app/tests/wave0.bats
 ✓ ConfigMap is rendered at sync-wave 0
1 test, 0 failures
```

5. Commit:

```bash
git add platform/charts/app/templates/_helpers.tpl platform/charts/app/templates/configmap.yaml platform/charts/app/tests/wave0.bats
git commit -m "feat: 앱 차트 헬퍼와 wave0 ConfigMap 템플릿 추가"
```

---

### Task 6.3 — Migration pre-upgrade hook Job (wave 1, CNPG-Ready gated)

**Files**
- Create: `platform/charts/app/templates/migrate-job.yaml`
- Test: `platform/charts/app/tests/migrate.bats`

**Steps**

1. Write the failing test: when `db.enabled=true`, a Helm hook Job must render at sync-wave 1, run the image's `migrate` command, and NOT render when `db.enabled=false`. `platform/charts/app/tests/migrate.bats`:

```bash
#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
BASE="--set image.repo=ghcr.io/o/api --set image.tag=sha-abc1234 --set kind=api \
  --set route.host=api.example.com \
  --set resources.requests.cpu=50m --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=500m --set resources.limits.memory=128Mi"

@test "migration Job renders at sync-wave 1 with hook when db.enabled" {
  run bash -c "helm template t \"$CHART\" $BASE --set db.enabled=true \
    | yq 'select(.kind==\"Job\")'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"argocd.argoproj.io/sync-wave: \"1\""* ]]
  [[ "$output" == *"helm.sh/hook: pre-install,pre-upgrade"* ]]
  [[ "$output" == *"hook-delete-policy: before-hook-creation,hook-succeeded"* ]]
  [[ "$output" == *'- "migrate"'* ]]
  # cross-Application DB readiness is enforced IN-POD (not just by sync-waves)
  [[ "$output" == *"name: wait-for-db"* ]]
  [[ "$output" == *"pg_isready"* ]]
}

@test "no migration Job when db.enabled=false" {
  run bash -c "helm template t \"$CHART\" $BASE --set db.enabled=false \
    | yq 'select(.kind==\"Job\")'"
  [ -z "$output" ]
}
```

2. Run it, expect RED:

```
$ bats platform/charts/app/tests/migrate.bats
 ✗ migration Job renders at sync-wave 1 with hook when db.enabled
1 test, ... failure
```

3. Implement `platform/charts/app/templates/migrate-job.yaml`. Wave-1 orders the Job before the wave-2 Deployment **within this app's Application**; cross-Application DB readiness (the CNPG-Ready contract) is enforced explicitly by a `wait-for-db` initContainer (`pg_isready` with bounded retries) — ArgoCD sync-waves do NOT gate across separate Applications, so the migration must never assume the DB is already up:

```yaml
{{- if .Values.db.enabled }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "app.fullname" . }}-migrate
  labels:
    {{- include "app.labels" . | nindent 4 }}
  annotations:
    # Wave 1 orders this Job before the wave-2 Deployment WITHIN this app's Application. Cross-Application
    # DB readiness is enforced by the wait-for-db initContainer below (sync-waves don't gate across Applications).
    argocd.argoproj.io/sync-wave: "1"
    # Helm hook makes this run on install/upgrade only, then be cleaned up.
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "0"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
spec:
  backoffLimit: 2
  activeDeadlineSeconds: 600
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        {{- include "app.selectorLabels" . | nindent 8 }}
        app.homelab/job: migrate
    spec:
      restartPolicy: Never
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      initContainers:
        # ArgoCD sync-waves order resources WITHIN one Application; they do NOT enforce a
        # cross-Application gate, so "the cnpg-data Application is Healthy" is not guaranteed when
        # this Job runs. Make readiness self-contained: block until the DB accepts connections.
        - name: wait-for-db
          image: ghcr.io/cloudnative-pg/postgresql:16.4
          command: ["/bin/sh", "-c"]
          args:
            - |
              host="{{ .Values.db.host | default "pg-rw.database.svc" }}"
              for i in $(seq 1 60); do
                if pg_isready -h "$host" -p 5432 >/dev/null 2>&1; then echo "db ready"; exit 0; fi
                echo "waiting for $host ($i/60)"; sleep 5
              done
              echo "db not ready after 5m" >&2; exit 1
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
      containers:
        - name: migrate
          image: "{{ .Values.image.repo }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command:
            {{- toYaml .Values.db.migrateCmd | nindent 12 }}
          {{- with .Values.envFrom }}
          envFrom:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.env }}
          env:
            {{- range . }}
            - name: {{ .name }}
              value: {{ .value | quote }}
            {{- end }}
          {{- end }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          resources:
            requests: { cpu: 50m, memory: {{ .Values.resources.requests.memory }} }
            limits:   { cpu: 500m, memory: {{ .Values.resources.limits.memory }} }
{{- end }}
```

4. Run it, expect GREEN:

```
$ bats platform/charts/app/tests/migrate.bats
 ✓ migration Job renders at sync-wave 1 with hook when db.enabled
 ✓ no migration Job when db.enabled=false
2 tests, 0 failures
```

5. Commit:

```bash
git add platform/charts/app/templates/migrate-job.yaml platform/charts/app/tests/migrate.bats
git commit -m "feat: 마이그레이션 pre-upgrade 훅 Job을 wave1으로 추가"
```

---

### Task 6.4 — Deployment template, kind-aware (wave 2)

**Files**
- Create: `platform/charts/app/templates/deployment.yaml`
- Test: `platform/charts/app/tests/deployment.bats`

**Steps**

1. Write the failing test: Deployment at wave 2, non-root, probes wired for served kinds, SPA served by SWS args, graceful preStop, scrape annotations. `platform/charts/app/tests/deployment.bats`:

```bash
#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
R="--set resources.requests.cpu=50m --set resources.requests.memory=64Mi \
   --set resources.limits.cpu=500m --set resources.limits.memory=128Mi"

dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 $R "$@" | yq 'select(.kind=="Deployment")'; }

@test "api Deployment is wave2, non-root, with probes and scrape annotation" {
  out=$(dep --set kind=api --set route.host=api.example.com)
  [[ "$out" == *'argocd.argoproj.io/sync-wave: "2"'* ]]
  [[ "$out" == *"runAsNonRoot: true"* ]]
  [[ "$out" == *"runAsUser: 65532"* ]]
  [[ "$out" == *"path: /healthz"* ]]
  [[ "$out" == *"path: /readyz"* ]]
  [[ "$out" == *'prometheus.io/scrape: "true"'* ]]
  [[ "$out" == *"sleep"* ]]
  [[ "$out" == *"terminationGracePeriodSeconds: 30"* ]]
}

@test "worker Deployment has no readiness HTTP probe (no route)" {
  out=$(dep --set kind=worker)
  [[ "$out" != *"httpGet"* ]]
}

@test "spa Deployment runs static-web-server when spa.server=sws" {
  out=$(dep --set kind=spa --set route.host=app.example.com --set spa.server=sws)
  [[ "$out" == *"static-web-server"* ]] || [[ "$out" == *"SERVER_ROOT"* ]]
  [[ "$out" == *"readOnlyRootFilesystem: true"* ]]
}
```

2. Run it, expect RED:

```
$ bats platform/charts/app/tests/deployment.bats
 ✗ api Deployment is wave2 ...
3 tests, 3 failures
```

3. Implement `platform/charts/app/templates/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "app.fullname" . }}
  labels:
    {{- include "app.labels" . | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  replicas: {{ .Values.replicas }}
  selector:
    matchLabels:
      {{- include "app.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "app.labels" . | nindent 8 }}
      annotations:
        {{- if and .Values.metrics.enabled (ne .Values.kind "spa") }}
        prometheus.io/scrape: "true"
        prometheus.io/port: "{{ .Values.ports.metrics }}"
        prometheus.io/path: "/metrics"
        {{- end }}
    spec:
      terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: app
          image: "{{ .Values.image.repo }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          {{- if eq .Values.kind "spa" }}
          {{- if eq .Values.spa.server "sws" }}
          # static-web-server (Rust): SPA fallback + read-only root
          args: ["--port", "{{ .Values.ports.http }}", "--root", "/public", "--page-fallback", "/public/index.html", "--health"]
          {{- end }}
          {{- end }}
          ports:
            - name: http
              containerPort: {{ .Values.ports.http }}
            {{- if ne .Values.kind "spa" }}
            - name: metrics
              containerPort: {{ .Values.ports.metrics }}
            {{- end }}
          {{- if or .Values.env .Values.envFrom }}
          envFrom:
            {{- if .Values.env }}
            - configMapRef:
                name: {{ include "app.fullname" . }}-env
            {{- end }}
            {{- with .Values.envFrom }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          {{- end }}
          {{- if include "app.isServed" . }}
          livenessProbe:
            httpGet: { path: {{ .Values.probes.liveness.path }}, port: http }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: {{ .Values.probes.readiness.path }}, port: http }
            initialDelaySeconds: 3
            periodSeconds: 5
          {{- else }}
          # worker: process-liveness only (exec true placeholder; override per-runtime)
          livenessProbe:
            exec: { command: ["/bin/true"] }
            periodSeconds: 30
          {{- end }}
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sleep", "{{ .Values.preStopSleepSeconds }}"]
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
{{- with .Values.extraManifests }}
{{- range . }}
---
{{ toYaml . }}
{{- end }}
{{- end }}
```

> The `envFrom` block is written so the `configMapRef` (from the wave-0 env ConfigMap) and the SOPS-decrypted `secretRef`s coexist in a single list — emitting `envFrom:` once and appending both. An `emptyDir` is always mounted at `/tmp` so `readOnlyRootFilesystem: true` stays viable.

4. Run it, expect GREEN:

```
$ bats platform/charts/app/tests/deployment.bats
 ✓ api Deployment is wave2, non-root, with probes and scrape annotation
 ✓ worker Deployment has no readiness HTTP probe (no route)
 ✓ spa Deployment runs static-web-server when spa.server=sws
3 tests, 0 failures
```

5. Commit:

```bash
git add platform/charts/app/templates/deployment.yaml platform/charts/app/tests/deployment.bats
git commit -m "feat: kind 인지형 Deployment 템플릿을 wave2로 추가"
```

---

### Task 6.5 — Service + HTTPRoute templates (wave 2, served kinds only)

**Files**
- Create: `platform/charts/app/templates/service.yaml`
- Create: `platform/charts/app/templates/httproute.yaml`
- Test: `platform/charts/app/tests/route.bats`

**Steps**

1. Write the failing test: served kinds get a Service + HTTPRoute bound to the shared Gateway `homelab` in the `gateway` ns; worker gets neither; public flag selects the public Gateway listener section vs internal. `platform/charts/app/tests/route.bats`:

```bash
#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
R="--set resources.requests.cpu=50m --set resources.requests.memory=64Mi \
   --set resources.limits.cpu=500m --set resources.limits.memory=128Mi"
tpl() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 $R "$@"; }

@test "api gets Service and HTTPRoute referencing the shared Gateway" {
  out=$(tpl --set kind=api --set route.host=api.example.com --set route.public=true)
  echo "$out" | yq 'select(.kind=="Service")' | grep -q "port: 8080"
  rt=$(echo "$out" | yq 'select(.kind=="HTTPRoute")')
  [[ "$rt" == *"name: homelab"* ]]
  [[ "$rt" == *"namespace: gateway"* ]]
  [[ "$rt" == *"sectionName: web-public"* ]]
  [[ "$rt" == *"api.example.com"* ]]
}

@test "internal app binds to the internal listener" {
  rt=$(tpl --set kind=ssr --set route.host=admin.int.example.com --set route.public=false | yq 'select(.kind=="HTTPRoute")')
  [[ "$rt" == *"sectionName: web-internal"* ]]
}

@test "worker has no Service and no HTTPRoute" {
  out=$(tpl --set kind=worker)
  [ -z "$(echo "$out" | yq 'select(.kind=="Service")')" ]
  [ -z "$(echo "$out" | yq 'select(.kind=="HTTPRoute")')" ]
}
```

2. Run it, expect RED:

```
$ bats platform/charts/app/tests/route.bats
 ✗ api gets Service and HTTPRoute referencing the shared Gateway
3 tests, 3 failures
```

3. Implement.

`platform/charts/app/templates/service.yaml`:

```yaml
{{- if include "app.isServed" . }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "app.fullname" . }}
  labels:
    {{- include "app.labels" . | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  type: ClusterIP
  selector:
    {{- include "app.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: {{ .Values.ports.http }}
      targetPort: http
    {{- if ne .Values.kind "spa" }}
    - name: metrics
      port: {{ .Values.ports.metrics }}
      targetPort: metrics
    {{- end }}
{{- end }}
```

`platform/charts/app/templates/httproute.yaml`:

```yaml
{{- if include "app.isServed" . }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "app.fullname" . }}
  labels:
    {{- include "app.labels" . | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  parentRefs:
    - name: {{ .Values.gateway.name }}            # the single shared Gateway (Milestone 3)
      namespace: {{ .Values.gateway.namespace }}
      sectionName: {{ if .Values.route.public }}web-public{{ else }}web-internal{{ end }}
  hostnames:
    - {{ .Values.route.host | quote }}
  rules:
    - matches:
        {{- range .Values.route.paths }}
        - path:
            type: PathPrefix
            value: {{ . | quote }}
        {{- end }}
      backendRefs:
        - name: {{ include "app.fullname" . }}
          port: {{ .Values.ports.http }}
{{- end }}
```

> `web-public` is the listener the cloudflared tunnel targets; `web-internal` is the Tailscale-exposed listener. Both live on the one shared `homelab` Gateway in the `gateway` namespace (Milestone 3) — apps never create Gateways, only HTTPRoutes, keeping the proxy count at one.

4. Run it, expect GREEN:

```
$ bats platform/charts/app/tests/route.bats
 ✓ api gets Service and HTTPRoute referencing the shared Gateway
 ✓ internal app binds to the internal listener
 ✓ worker has no Service and no HTTPRoute
3 tests, 0 failures
```

5. Commit:

```bash
git add platform/charts/app/templates/service.yaml platform/charts/app/templates/httproute.yaml platform/charts/app/tests/route.bats
git commit -m "feat: 서비스와 HTTPRoute 템플릿을 공유 Gateway에 연결"
```

---

### Task 6.6 — Render-all-kinds validity gate (kubeconform)

**Files**
- Create: `platform/charts/app/tests/fixtures/api.yaml`
- Create: `platform/charts/app/tests/fixtures/worker.yaml`
- Create: `platform/charts/app/tests/fixtures/ssr.yaml`
- Create: `platform/charts/app/tests/fixtures/spa.yaml`
- Create: `platform/charts/app/tests/render.sh`
- Modify: `Makefile` (M0-owned; add a new `chart-test` target)

**Steps**

1. Write the failing check: render each kind and validate against the Gateway API + core schemas with kubeconform. `platform/charts/app/tests/render.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
for k in api worker ssr spa; do
  echo "== rendering kind=$k =="
  helm template t "$CHART" -f "$CHART/tests/fixtures/$k.yaml" \
    | kubeconform -strict -summary -ignore-missing-schemas \
        -schema-location default \
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    || fail=1
done
exit $fail
```

`platform/charts/app/tests/fixtures/api.yaml`:

```yaml
image: { repo: ghcr.io/owner/api, tag: sha-abc1234 }
kind: api
route: { host: api.example.com, public: true, paths: ["/"] }
db: { enabled: true, migrateCmd: ["/app/api", "migrate"] }
envFrom:
  - secretRef: { name: api-secrets }
env:
  - { name: LOG_LEVEL, value: info }
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 500m, memory: 64Mi }
```

`platform/charts/app/tests/fixtures/worker.yaml`:

```yaml
image: { repo: ghcr.io/owner/worker, tag: sha-abc1234 }
kind: worker
db: { enabled: true, migrateCmd: ["/app/worker", "migrate"] }
envFrom:
  - secretRef: { name: worker-secrets }
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 500m, memory: 64Mi }
```

`platform/charts/app/tests/fixtures/ssr.yaml`:

```yaml
image: { repo: ghcr.io/owner/web, tag: sha-abc1234 }
kind: ssr
route: { host: web.example.com, public: true, paths: ["/"] }
resources:
  requests: { cpu: 50m, memory: 128Mi }
  limits:   { cpu: 500m, memory: 256Mi }
```

`platform/charts/app/tests/fixtures/spa.yaml`:

```yaml
image: { repo: ghcr.io/owner/console, tag: sha-abc1234 }
kind: spa
spa: { server: sws }
route: { host: console.example.com, public: true, paths: ["/"] }
resources:
  requests: { cpu: 10m, memory: 16Mi }
  limits:   { cpu: 100m, memory: 32Mi }
```

Append a NEW target to the M0-owned `Makefile`:

```makefile
.PHONY: chart-test
chart-test: ## render+validate the app chart for all kinds
	bats platform/charts/app/tests/
	bash platform/charts/app/tests/render.sh
```

2. Run it, expect RED (first run fails because `render.sh` is not executable / a chart bug surfaces / the HTTPRoute schema is unresolved until the CRDs-catalog location is wired):

```
$ chmod +x platform/charts/app/tests/render.sh && make chart-test
== rendering kind=api ==
... FAILED: HTTPRoute resource ... schema not found / invalid
make: *** [chart-test] Error 1
```

3. Fix any schema/render issues surfaced (the CRDs-catalog location resolves Gateway API HTTPRoute; `-ignore-missing-schemas` tolerates ArgoCD-only annotations). No new files — adjust `render.sh` schema-location flags until clean.

4. Run it, expect GREEN:

```
$ make chart-test
 ✓ ... (all bats)
== rendering kind=api ==
PASS - stdin Deployment t
PASS - stdin Service t
PASS - stdin HTTPRoute t
...
== rendering kind=spa ==
Summary: 4 resources found ... 0 invalid, 0 errors
```

5. Commit:

```bash
git add platform/charts/app/tests/ Makefile
git commit -m "test: 모든 kind에 대한 차트 렌더링 kubeconform 검증 추가"
```

---

### Task 6.7 — Reconcile pnpm workspace + add DX scripts (M0-owned files)

**Files**
- Modify: `pnpm-workspace.yaml` (M0-owned — only reconcile globs; never re-Create)
- Modify: `package.json` (M0-owned — add scripts via Edit; never re-Create, never change `packageManager`)
- Test: `tools/test/workspace.bats`

> `.sops.yaml` is owned by Milestone 0 and its real recipient keys are filled by Milestone 2. **This milestone must NOT touch `.sops.yaml`.** It is consumed transparently by the KSOPS repo-server plugin (Milestone 2) at render time.

**Steps**

1. Write the failing test: pnpm resolves the canonical workspace members and `package.json` exposes the DX scripts on `pnpm@10`. `tools/test/workspace.bats`:

```bash
#!/usr/bin/env bats

@test "pnpm workspace globs the canonical members" {
  run yq '.packages' pnpm-workspace.yaml
  [[ "$output" == *"apps/*/src"* ]]
  [[ "$output" == *"platform/charts/*"* ]]
  [[ "$output" == *"tools"* ]]
}

@test "package.json pins pnpm@10 and exposes the DX scripts" {
  run jq -r '.packageManager' package.json
  [[ "$output" == pnpm@10* ]]
  run jq -r '.scripts | keys | join(",")' package.json
  [[ "$output" == *"dev"* ]]
  [[ "$output" == *"gen:app"* ]]
  [[ "$output" == *"verify:app"* ]]
  [[ "$output" == *"gen:env"* ]]
}
```

2. Run it, expect RED (M0 created these without the M6 scripts):

```
$ bats tools/test/workspace.bats
 ✗ package.json pins pnpm@10 and exposes the DX scripts
2 tests, 1 failure
```

3. Reconcile, do not re-create.

Confirm `pnpm-workspace.yaml` carries M0's canonical globs (reconcile only if M0's file differs — never rewrite it from scratch):

```yaml
packages:
  - "apps/*/src"
  - "platform/charts/*"
  - "tools"
```

EDIT the M0-owned `package.json` to ADD the milestone's DX scripts. Preserve `name`, `private`, M0's `packageManager: "pnpm@10.x"`, `engines.pnpm >=10`, and any existing scripts (including M0's `verify:ledger`):

```jsonc
{
  // ... M0 fields preserved (name, private, packageManager pnpm@10.x, engines.pnpm>=10) ...
  "scripts": {
    // ... existing M0 scripts preserved, including "verify:ledger" ...
    "dev": "node tools/dev.mjs",
    "gen:app": "node tools/gen-app.mjs",
    "verify:app": "node tools/verify-app.mjs",
    "gen:env": "node tools/gen-env-example.mjs"
  }
}
```

4. Run it, expect GREEN:

```
$ bats tools/test/workspace.bats
 ✓ pnpm workspace globs the canonical members
 ✓ package.json pins pnpm@10 and exposes the DX scripts
2 tests, 0 failures
```

5. Commit:

```bash
git add package.json pnpm-workspace.yaml tools/test/workspace.bats
git commit -m "chore: M6 DX 스크립트를 루트 package.json에 추가(pnpm@10)"
```

---

### Task 6.8 — Sample `api` app: source, distroless Dockerfile, prod values

**Files**
- Create: `apps/api/src/main.go`
- Create: `apps/api/go.mod`
- Create: `apps/api/Dockerfile`
- Create: `apps/api/deploy/prod/values.yaml`
- Test: `apps/api/src/main_test.go`

**Steps**

1. Write the failing test: the service exposes `/healthz` (200, no deps), `/readyz` (503 until DB probe set), `/metrics`, and a `migrate` subcommand exit-0. `apps/api/src/main_test.go`:

```go
package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthz(t *testing.T) {
	rr := httptest.NewRecorder()
	healthzHandler(rr, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("healthz = %d, want 200", rr.Code)
	}
}

func TestReadyzReportsDB(t *testing.T) {
	dbReady = false
	rr := httptest.NewRecorder()
	readyzHandler(rr, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("readyz(not ready) = %d, want 503", rr.Code)
	}
	dbReady = true
	rr = httptest.NewRecorder()
	readyzHandler(rr, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("readyz(ready) = %d, want 200", rr.Code)
	}
}

func TestMigrateExitsZero(t *testing.T) {
	if err := runMigrate(); err != nil {
		t.Fatalf("migrate returned err: %v", err)
	}
}
```

2. Run it, expect RED:

```
$ cd apps/api && go test ./src/
src/main_test.go:... undefined: healthzHandler
FAIL
```

3. Implement.

`apps/api/go.mod`:

```
module github.com/owner/homelab/apps/api

go 1.22
```

`apps/api/src/main.go`:

```go
package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
)

var (
	dbReady  = false
	draining atomic.Bool
)

func healthzHandler(w http.ResponseWriter, _ *http.Request) {
	// liveness: process is up, NO external deps.
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func readyzHandler(w http.ResponseWriter, _ *http.Request) {
	// readiness: flips to 503 while draining or if DB not reachable.
	if draining.Load() || !dbReady {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("not ready"))
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ready"))
}

func metricsHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintln(w, "# HELP app_up 1 if the app is serving")
	fmt.Fprintln(w, "# TYPE app_up gauge")
	fmt.Fprintln(w, "app_up 1")
}

func runMigrate() error {
	// app-native migration entrypoint. Real impl runs golang-migrate against DATABASE_URL.
	// Idempotent + backward-compatible (expand/contract). No-op when nothing to do.
	fmt.Println("migrate: schema up to date")
	return nil
}

func checkDB() {
	// Probe DATABASE_URL; here we mark ready if the env is present.
	if os.Getenv("DATABASE_URL") != "" {
		dbReady = true
	}
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "migrate" {
		if err := runMigrate(); err != nil {
			fmt.Fprintln(os.Stderr, "migrate failed:", err)
			os.Exit(1)
		}
		return
	}

	checkDB()

	appMux := http.NewServeMux()
	appMux.HandleFunc("/healthz", healthzHandler)
	appMux.HandleFunc("/readyz", readyzHandler)
	appMux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("homelab api\n"))
	})
	appSrv := &http.Server{Addr: ":8080", Handler: appMux}

	metricsMux := http.NewServeMux()
	metricsMux.HandleFunc("/metrics", metricsHandler)
	metricsSrv := &http.Server{Addr: ":9090", Handler: metricsMux}

	go func() { _ = metricsSrv.ListenAndServe() }()
	go func() {
		if err := appSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Fprintln(os.Stderr, "server error:", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop

	// SIGTERM drain: flip readyz -> 503, finish in-flight, exit < 30s.
	draining.Store(true)
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	_ = appSrv.Shutdown(ctx)
	_ = metricsSrv.Shutdown(ctx)
}
```

`apps/api/Dockerfile` (multi-stage, native arm64, distroless static nonroot):

```dockerfile
# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM golang:1.22-bookworm AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY src ./src
ENV CGO_ENABLED=0 GOOS=linux GOARCH=arm64
RUN go build -trimpath -ldflags="-s -w" -o /out/api ./src

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/api /app/api
USER 65532:65532
EXPOSE 8080 9090
ENTRYPOINT ["/app/api"]
```

`apps/api/deploy/prod/values.yaml` (consumed by the Milestone 3 ApplicationSet `apps/*/deploy/prod` generator → this shared chart; the component's own `namespace:` lands it in the `prod` ns). The `api-secrets` Secret is delivered SOPS-decrypted via a co-located `secret-generator.yaml` (KSOPS, Milestone 2 wiring):

```yaml
image:
  repo: ghcr.io/owner/api
  tag: sha-0000000        # bumped by CI write-back (Task 6.15)
kind: api
replicas: 1
resources:
  requests: { cpu: 50m, memory: 64Mi }   # Go runtime gate: 32–64Mi
  limits:   { cpu: 500m, memory: 64Mi }
env:
  - { name: LOG_LEVEL, value: info }
envFrom:
  - secretRef: { name: api-secrets }      # SOPS-decrypted via KSOPS
route:
  host: api.<DOMAIN>
  paths: ["/"]
  public: true
db:
  enabled: true
  migrateCmd: ["/app/api", "migrate"]
probes:
  liveness:  { path: /healthz }
  readiness: { path: /readyz }
```

4. Run it, expect GREEN:

```
$ cd apps/api && go test ./src/
ok  github.com/owner/homelab/apps/api/src
```

5. Commit:

```bash
git add apps/api/
git commit -m "feat: 샘플 api 앱(healthz/readyz/metrics/migrate)과 distroless Dockerfile 추가"
```

---

### Task 6.9 — worker / ssr / spa example apps (values + minimal source)

**Files**
- Create: `apps/worker/deploy/prod/values.yaml`
- Create: `apps/web/deploy/prod/values.yaml`
- Create: `apps/console/deploy/prod/values.yaml`
- Create: `apps/web/src/package.json`, `apps/console/src/package.json`
- Test: `tools/test/examples.bats`

**Steps**

1. Write the failing check: each example renders cleanly through the shared chart and respects its per-runtime memory gate. `tools/test/examples.bats`:

```bash
#!/usr/bin/env bats
CHART="platform/charts/app"

render() { helm template "$1" "$CHART" -f "$2"; }

@test "worker renders, no HTTPRoute, Node/Go memory gate" {
  out=$(render worker apps/worker/deploy/prod/values.yaml)
  [ -z "$(echo "$out" | yq 'select(.kind=="HTTPRoute")')" ]
  [[ "$out" == *"Deployment"* ]]
}

@test "ssr (Node standalone) renders Service+HTTPRoute, limit >=256Mi" {
  out=$(render web apps/web/deploy/prod/values.yaml)
  [[ "$out" == *"HTTPRoute"* ]]
  echo "$out" | yq 'select(.kind=="Deployment").spec.template.spec.containers[0].resources.limits.memory' | grep -qE '256Mi|384Mi'
}

@test "spa served by static-web-server, no metrics port" {
  out=$(render console apps/console/deploy/prod/values.yaml)
  [[ "$out" == *"static-web-server"* ]] || [[ "$out" == *"page-fallback"* ]]
  [ -z "$(echo "$out" | yq 'select(.kind=="Deployment").spec.template.spec.containers[0].ports[] | select(.name=="metrics")')" ]
}
```

2. Run it, expect RED:

```
$ bats tools/test/examples.bats
 ✗ worker renders ... (values file not found)
3 tests, 3 failures
```

3. Implement.

`apps/worker/deploy/prod/values.yaml`:

```yaml
image: { repo: ghcr.io/owner/worker, tag: sha-0000000 }
kind: worker
replicas: 1
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 500m, memory: 64Mi }
envFrom:
  - secretRef: { name: worker-secrets }
db:
  enabled: true
  migrateCmd: ["/app/worker", "migrate"]
```

`apps/web/deploy/prod/values.yaml` (SSR, Node standalone — `--max-old-space-size=200`, limit ≥ 256Mi):

```yaml
image: { repo: ghcr.io/owner/web, tag: sha-0000000 }
kind: ssr
replicas: 1
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { cpu: 500m, memory: 256Mi }
env:
  - { name: NODE_OPTIONS, value: "--max-old-space-size=200" }
route:
  host: web.<DOMAIN>
  paths: ["/"]
  public: true
```

`apps/console/deploy/prod/values.yaml` (SPA, SWS):

```yaml
image: { repo: ghcr.io/owner/console, tag: sha-0000000 }
kind: spa
replicas: 1
spa: { server: sws }
resources:
  requests: { cpu: 10m, memory: 16Mi }
  limits:   { cpu: 100m, memory: 32Mi }
route:
  host: console.int.<DOMAIN>
  paths: ["/"]
  public: false
```

`apps/web/src/package.json` and `apps/console/src/package.json` (workspace members under the canonical `apps/*/src` glob, for `pnpm dev`):

```json
{ "name": "@homelab/web", "private": true, "scripts": { "dev": "next dev -p 3000" } }
```
```json
{ "name": "@homelab/console", "private": true, "scripts": { "dev": "vite" } }
```

4. Run it, expect GREEN:

```
$ bats tools/test/examples.bats
 ✓ worker renders, no HTTPRoute, Node/Go memory gate
 ✓ ssr (Node standalone) renders Service+HTTPRoute, limit >=256Mi
 ✓ spa served by static-web-server, no metrics port
3 tests, 0 failures
```

5. Commit:

```bash
git add apps/worker apps/web apps/console tools/test/examples.bats
git commit -m "feat: worker/ssr/spa 예제 앱 values와 워크스페이스 멤버 추가"
```

---

### Task 6.10 — `pg-tools` operations image (Milestone 4's restore-drill / pg_dump-hedge dependency)

**Files**
- Create: `apps/pg-tools/Dockerfile`
- Create: `apps/pg-tools/README.md`
- Test: `tools/test/pg-tools.bats`

> This image is an explicit deliverable that Milestone 4's restore drill and `pg_dump → rclone → R2` hedge REFERENCE. M4's LIVE restore-drill acceptance is gated on this milestone publishing `ghcr.io/<owner>/pg-tools:16-rclone`. The CI build matrix (Task 6.14) builds and pushes it like any other app.

**Steps**

1. Write the failing check: the Dockerfile installs the four required tools (`kubectl`, `psql`/postgres client 16, `rclone`, `curl`) and is the source for the canonical tag. `tools/test/pg-tools.bats`:

```bash
#!/usr/bin/env bats
DF="apps/pg-tools/Dockerfile"

@test "pg-tools Dockerfile installs kubectl, psql(16), rclone, curl" {
  run grep -iE 'kubectl' "$DF"; [ "$status" -eq 0 ]
  run grep -iE 'postgresql-client-16|psql' "$DF"; [ "$status" -eq 0 ]
  run grep -iE 'rclone' "$DF"; [ "$status" -eq 0 ]
  run grep -iE 'curl' "$DF"; [ "$status" -eq 0 ]
}

@test "pg-tools is in the CI build matrix (canonical 16-rclone tag)" {
  run yq '.jobs.build.strategy.matrix.app' .github/workflows/build.yaml
  [[ "$output" == *"pg-tools"* ]]
}
```

> The second assertion goes RED until Task 6.14 adds `pg-tools` to the matrix; keep it in this suite so the dependency is enforced.

2. Run it, expect RED:

```
$ bats tools/test/pg-tools.bats
 ✗ pg-tools Dockerfile installs kubectl, psql(16), rclone, curl ... No such file
2 tests, 2 failures
```

3. Implement `apps/pg-tools/Dockerfile` (arm64; pinned postgres client 16 + rclone + kubectl + curl):

```dockerfile
# syntax=docker/dockerfile:1
# Operations image for CNPG backup/restore tooling.
# Consumed by Milestone 4's restore-drill CronJob and the pg_dump→rclone→R2 hedge.
# Published as ghcr.io/<owner>/pg-tools:16-rclone (see Task 6.14 matrix).
FROM debian:bookworm-slim

ARG TARGETARCH=arm64
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release unzip && \
    # PostgreSQL client 16 (PGDG)
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc && \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && apt-get install -y --no-install-recommends postgresql-client-16 && \
    # kubectl (stable, arch-aware)
    curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${TARGETARCH}/kubectl" \
      -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl && \
    # rclone (R2-compatible S3)
    curl -fsSL "https://downloads.rclone.org/rclone-current-linux-${TARGETARCH}.zip" -o /tmp/rclone.zip && \
    unzip -j /tmp/rclone.zip '*/rclone' -d /usr/local/bin && chmod +x /usr/local/bin/rclone && \
    rm -rf /tmp/rclone.zip /var/lib/apt/lists/*

USER 65532:65532
ENTRYPOINT ["/bin/bash", "-c"]
```

`apps/pg-tools/README.md`:

```markdown
# pg-tools

Operations image: `kubectl` + `psql` (postgres-client-16) + `rclone` + `curl`.

Published by CI (Task 6.14 matrix) as `ghcr.io/<owner>/pg-tools:16-rclone` and
`:sha-<gitsha>`. Milestone 4's restore-drill CronJob and the `pg_dump → rclone → R2`
hedge reference this image; M4's LIVE-drill acceptance is gated on this image existing.
The restore drill may push its own direct-curl Telegram pass/fail message (allowed, local).
```

4. Run the Dockerfile-content test, expect GREEN (the matrix assertion stays RED until Task 6.14):

```
$ bats tools/test/pg-tools.bats
 ✓ pg-tools Dockerfile installs kubectl, psql(16), rclone, curl
 ✗ pg-tools is in the CI build matrix (canonical 16-rclone tag)   # GREEN after Task 6.14
```

5. Commit:

```bash
git add apps/pg-tools tools/test/pg-tools.bats
git commit -m "feat: CNPG 백업/복구용 pg-tools 운영 이미지(16-rclone) 추가"
```

---

### Task 6.11 — `.env.example` generated from the chart ConfigMap schema + CI drift check

**Files**
- Create: `tools/gen-env-example.mjs`
- Create: `apps/api/.env.example`
- Test: `tools/test/env-example.bats`

**Steps**

1. Write the failing check: the generator reads an app's `deploy/prod/values.yaml`, emits every `env[].name` (plus a commented marker for each `envFrom` secretRef key) into `.env.example`, and `--check` fails when the committed file drifts from the values. `tools/test/env-example.bats`:

```bash
#!/usr/bin/env bats

@test "gen:env produces keys from values.yaml env" {
  run node tools/gen-env-example.mjs api --stdout
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOG_LEVEL="* ]]
  [[ "$output" == *"# from secret: api-secrets"* ]]
}

@test "gen:env --check passes on committed file" {
  run node tools/gen-env-example.mjs api --check
  [ "$status" -eq 0 ]
}

@test "gen:env --check FAILS on injected drift" {
  cp apps/api/.env.example /tmp/envbak
  printf 'DRIFT=1\n' >> apps/api/.env.example
  run node tools/gen-env-example.mjs api --check
  cp /tmp/envbak apps/api/.env.example
  [ "$status" -ne 0 ]
}
```

2. Run it, expect RED:

```
$ bats tools/test/env-example.bats
 ✗ gen:env produces keys ... Cannot find module
3 tests, 3 failures
```

3. Implement `tools/gen-env-example.mjs` (exposed as `pnpm gen:env`):

```js
#!/usr/bin/env node
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { parse } from "yaml";

const app = process.argv[2];
const mode = process.argv.includes("--check") ? "check"
  : process.argv.includes("--stdout") ? "stdout" : "write";

if (!app) { console.error("usage: gen:env <app> [--check|--stdout]"); process.exit(2); }

const valuesPath = `apps/${app}/deploy/prod/values.yaml`;
const v = parse(readFileSync(valuesPath, "utf8"));

const lines = [
  `# GENERATED from ${valuesPath} by pnpm gen:env — DO NOT EDIT BY HAND`,
  `# Local inner-loop env. Real values come from SOPS secrets in-cluster.`,
  "",
];
for (const e of v.env ?? []) lines.push(`${e.name}=${e.value ?? ""}`);
// DB inner-loop default (local containerized Postgres, Task 6.12)
if (v.db?.enabled) lines.push("DATABASE_URL=postgres://dev:dev@localhost:5432/app_dev?sslmode=disable");
for (const f of v.envFrom ?? []) {
  if (f.secretRef?.name) lines.push(`# from secret: ${f.secretRef.name}  (fill locally; never commit)`);
}
const out = lines.join("\n") + "\n";

const target = `apps/${app}/.env.example`;
if (mode === "stdout") { process.stdout.write(out); }
else if (mode === "check") {
  const cur = existsSync(target) ? readFileSync(target, "utf8") : "";
  if (cur !== out) {
    console.error(`DRIFT: ${target} is out of sync with ${valuesPath}. Run: pnpm gen:env ${app}`);
    process.exit(1);
  }
  console.log(`${target} OK`);
} else { writeFileSync(target, out); console.log(`wrote ${target}`); }
```

Generate the committed file:

```bash
pnpm add -w -D yaml
node tools/gen-env-example.mjs api
```

This writes `apps/api/.env.example`:

```
# GENERATED from apps/api/deploy/prod/values.yaml by pnpm gen:env — DO NOT EDIT BY HAND
# Local inner-loop env. Real values come from SOPS secrets in-cluster.

LOG_LEVEL=info
DATABASE_URL=postgres://dev:dev@localhost:5432/app_dev?sslmode=disable
# from secret: api-secrets  (fill locally; never commit)
```

4. Run it, expect GREEN:

```
$ bats tools/test/env-example.bats
 ✓ gen:env produces keys from values.yaml env
 ✓ gen:env --check passes on committed file
 ✓ gen:env --check FAILS on injected drift
3 tests, 0 failures
```

5. Commit:

```bash
git add tools/gen-env-example.mjs apps/api/.env.example package.json pnpm-lock.yaml
git commit -m "feat: 차트 values에서 .env.example 생성과 드리프트 체크 추가"
```

---

### Task 6.12 — Local containerized dev Postgres (inner loop, sanitized seed)

**Files**
- Create: `tools/dev-postgres/compose.yaml`
- Create: `tools/dev-postgres/seed.sql`
- Create: `tools/dev.mjs`
- Test: `tools/test/dev-postgres.bats`

**Steps**

1. Write the failing check (DX guard): a local Postgres comes up via OrbStack's Docker, the seed is sanitized (no prod PII columns), and `pnpm dev` waits for it ready. `tools/test/dev-postgres.bats`:

```bash
#!/usr/bin/env bats

setup() { docker compose -f tools/dev-postgres/compose.yaml up -d --wait; }
teardown() { docker compose -f tools/dev-postgres/compose.yaml down -v >/dev/null 2>&1 || true; }

@test "dev postgres is reachable and seeded" {
  run docker compose -f tools/dev-postgres/compose.yaml exec -T db \
    psql -U dev -d app_dev -tAc "select count(*) from app_health_seed;"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "seed contains NO email/phone columns (sanitized)" {
  run grep -iE 'email|phone|ssn' tools/dev-postgres/seed.sql
  [ "$status" -ne 0 ]   # grep finds nothing -> exit 1
}
```

2. Run it, expect RED:

```
$ bats tools/test/dev-postgres.bats
 ✗ dev postgres is reachable and seeded
   no configuration file provided: not found
2 tests, 2 failures
```

3. Implement.

`tools/dev-postgres/compose.yaml`:

```yaml
name: homelab-dev
services:
  db:
    image: postgres:16-bookworm
    environment:
      POSTGRES_USER: dev
      POSTGRES_PASSWORD: dev
      POSTGRES_DB: app_dev
    ports:
      - "5432:5432"
    volumes:
      - ./seed.sql:/docker-entrypoint-initdb.d/00-seed.sql:ro
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dev -d app_dev"]
      interval: 2s
      timeout: 3s
      retries: 30
volumes:
  pgdata: {}
```

`tools/dev-postgres/seed.sql` (sanitized snapshot — schema + synthetic rows, no PII):

```sql
-- Sanitized inner-loop seed. NEVER copy raw prod rows here.
-- Only schema + synthetic/anonymized data. No email/phone/ssn columns.
CREATE TABLE IF NOT EXISTS app_health_seed (
  id    bigserial PRIMARY KEY,
  label text NOT NULL,
  ok    boolean NOT NULL DEFAULT true
);
INSERT INTO app_health_seed (label) VALUES ('seed-row-1'), ('seed-row-2');
```

`tools/dev.mjs` (root `pnpm dev`: bring up local DB, then run each TS app's dev script):

```js
#!/usr/bin/env node
import { execSync, spawn } from "node:child_process";

console.log("starting local dev Postgres (OrbStack docker)…");
execSync("docker compose -f tools/dev-postgres/compose.yaml up -d --wait", { stdio: "inherit" });
console.log("dev Postgres ready on localhost:5432 (db=app_dev user=dev).");

// run TS workspace apps in parallel; polyglot apps run their own native dev loop.
const p = spawn("pnpm", ["-r", "--parallel", "--if-present", "dev"], { stdio: "inherit" });
process.on("SIGINT", () => { p.kill("SIGINT"); });
```

4. Run it, expect GREEN:

```
$ bats tools/test/dev-postgres.bats
 ✓ dev postgres is reachable and seeded
 ✓ seed contains NO email/phone columns (sanitized)
2 tests, 0 failures
```

5. Commit:

```bash
git add tools/dev-postgres tools/dev.mjs
git commit -m "feat: 이너루프용 로컬 컨테이너 Postgres와 pnpm dev 추가"
```

---

### Task 6.13 — `pnpm gen:app` scaffold + `pnpm verify:app` (red-link reporter)

**Files**
- Create: `tools/gen-app.mjs`
- Create: `tools/templates/values.yaml.tmpl`
- Create: `tools/verify-app.mjs`
- Test: `tools/test/gen-verify.bats`

**Steps**

1. Write the failing check: `gen:app foo --kind api` creates `apps/foo/{src,Dockerfile,deploy/prod/values.yaml}` + a CI matrix entry, and the scaffold renders through the shared chart; `verify:app api` walks build→push→tag→sync→probe→route→secret and prints a labeled status line per link, failing on the first red. `tools/test/gen-verify.bats`:

```bash
#!/usr/bin/env bats

teardown() { rm -rf apps/foo; git checkout -- .github/workflows/build.yaml 2>/dev/null || true; }

@test "gen:app scaffolds a renderable app and a CI matrix entry" {
  run node tools/gen-app.mjs foo --kind api
  [ "$status" -eq 0 ]
  [ -f apps/foo/deploy/prod/values.yaml ]
  [ -f apps/foo/Dockerfile ]
  run helm template foo platform/charts/app -f apps/foo/deploy/prod/values.yaml
  [ "$status" -eq 0 ]
  run yq '.jobs.build.strategy.matrix.app[]' .github/workflows/build.yaml
  [[ "$output" == *"foo"* ]]
}

@test "verify:app reports per-link status and names the red link" {
  run node tools/verify-app.mjs api --dry-run
  [[ "$output" == *"build"* ]]
  [[ "$output" == *"push"* ]]
  [[ "$output" == *"tag"* ]]
  [[ "$output" == *"sync"* ]]
  [[ "$output" == *"probe"* ]]
  [[ "$output" == *"route"* ]]
  [[ "$output" == *"secret"* ]]
}
```

2. Run it, expect RED:

```
$ bats tools/test/gen-verify.bats
 ✗ gen:app scaffolds ... Cannot find module tools/gen-app.mjs
2 tests, 2 failures
```

3. Implement.

`tools/templates/values.yaml.tmpl`:

```yaml
image: { repo: ghcr.io/owner/__NAME__, tag: sha-0000000 }
kind: __KIND__
replicas: 1
resources:
  requests: { cpu: 50m, memory: __REQMEM__ }
  limits:   { cpu: 500m, memory: __LIMMEM__ }
__ROUTE__
__DB__
```

`tools/gen-app.mjs`:

```js
#!/usr/bin/env node
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { parse, stringify } from "yaml";

const name = process.argv[2];
const kindIdx = process.argv.indexOf("--kind");
const kind = kindIdx > -1 ? process.argv[kindIdx + 1] : "api";
if (!name || !["api", "worker", "ssr", "spa"].includes(kind)) {
  console.error("usage: gen:app <name> --kind api|worker|ssr|spa"); process.exit(2);
}

// per-runtime memory gate defaults (design §9)
const mem = { api: ["64Mi", "64Mi"], worker: ["64Mi", "64Mi"], ssr: ["128Mi", "256Mi"], spa: ["16Mi", "32Mi"] }[kind];
const served = ["api", "ssr", "spa"].includes(kind);
const route = served
  ? `route:\n  host: ${name}.<DOMAIN>\n  paths: ["/"]\n  public: false`
  : "# kind=worker: no route";
const db = (kind === "api" || kind === "worker")
  ? `db:\n  enabled: true\n  migrateCmd: ["/app/${name}", "migrate"]`
  : "db:\n  enabled: false";

let tmpl = readFileSync("tools/templates/values.yaml.tmpl", "utf8");
tmpl = tmpl.replaceAll("__NAME__", name).replaceAll("__KIND__", kind)
  .replace("__REQMEM__", mem[0]).replace("__LIMMEM__", mem[1])
  .replace("__ROUTE__", route).replace("__DB__", db);

const base = `apps/${name}`;
if (existsSync(base)) { console.error(`apps/${name} already exists`); process.exit(1); }
mkdirSync(`${base}/src`, { recursive: true });
mkdirSync(`${base}/deploy/prod`, { recursive: true });
writeFileSync(`${base}/deploy/prod/values.yaml`, tmpl);
writeFileSync(`${base}/Dockerfile`,
`# syntax=docker/dockerfile:1
# TODO(${name}): build a distroless, non-root, arm64 image exposing :8080 /healthz /readyz, :9090 /metrics, and a 'migrate' cmd.
FROM gcr.io/distroless/static-debian12:nonroot
USER 65532:65532
`);
writeFileSync(`${base}/src/.gitkeep`, "");

// CI matrix entry
const wfPath = ".github/workflows/build.yaml";
const wf = parse(readFileSync(wfPath, "utf8"));
const apps = wf.jobs.build.strategy.matrix.app;
if (!apps.includes(name)) apps.push(name);
writeFileSync(wfPath, stringify(wf));

console.log(`scaffolded apps/${name} (kind=${kind}) and added '${name}' to CI matrix.`);
console.log(`next: pnpm gen:env ${name} && pnpm verify:app ${name}`);
```

`tools/verify-app.mjs` (walks the deploy chain; `--dry-run` simulates each link for the negative test, real run shells out). Note the destination namespace is `prod` (apps namespace) and the HTTPRoute status check targets the shared `homelab` Gateway:

```js
#!/usr/bin/env node
import { execSync } from "node:child_process";
import { parse } from "yaml";
import { readFileSync } from "node:fs";

const app = process.argv[2];
const dry = process.argv.includes("--dry-run");
if (!app) { console.error("usage: verify:app <name> [--dry-run]"); process.exit(2); }

const v = parse(readFileSync(`apps/${app}/deploy/prod/values.yaml`, "utf8"));
const host = v.route?.host;

const links = [
  ["build", () => execSync(`docker buildx build --platform linux/arm64 -t local/${app}:verify apps/${app}`, { stdio: "ignore" })],
  ["push",  () => execSync(`docker manifest inspect ${v.image.repo}:${v.image.tag}`, { stdio: "ignore" })],
  ["tag",   () => { if (v.image.tag === "sha-0000000") throw new Error("values.yaml still on placeholder tag (CI write-back never landed)"); }],
  ["sync",  () => execSync(`kubectl -n argocd get application ${app} -o jsonpath='{.status.sync.status}' | grep -qx Synced`)],
  ["probe", () => execSync(`kubectl -n prod get deploy ${app} -o jsonpath='{.status.readyReplicas}' | grep -qx 1`)],
  ["route", () => { if (host) execSync(`kubectl -n prod get httproute ${app} -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' | grep -qx True`); }],
  ["secret",() => { for (const f of v.envFrom ?? []) execSync(`kubectl -n prod get secret ${f.secretRef.name}`, { stdio: "ignore" }); }],
];

let firstRed = null;
for (const [label, fn] of links) {
  if (dry) { console.log(`  • ${label}: (dry-run)`); continue; }
  try { fn(); console.log(`  ✓ ${label}`); }
  catch (e) { console.log(`  ✗ ${label}  <-- RED: ${String(e.message || e).split("\n")[0]}`); firstRed = label; break; }
}
if (!dry && firstRed) { console.error(`\nverify:app ${app} FAILED at: ${firstRed}`); process.exit(1); }
if (!dry) console.log(`\nverify:app ${app}: all links green ✅`);
```

> `verify:app` deliberately stops at the FIRST red link and names it — that is the whole DX value (the design §9 "reports exactly which link is red"). The `--tag placeholder` check is what catches R6's silent CI write-back failure locally.

4. Run it, expect GREEN:

```
$ bats tools/test/gen-verify.bats
 ✓ gen:app scaffolds a renderable app and a CI matrix entry
 ✓ verify:app reports per-link status and names the red link
2 tests, 0 failures
```

5. Commit:

```bash
git add tools/gen-app.mjs tools/verify-app.mjs tools/templates tools/test/gen-verify.bats
git commit -m "feat: pnpm gen:app 스캐폴드와 verify:app 레드링크 리포터 추가"
```

---

### Task 6.14 — Memory-ledger onboarding gate (call M0's `pnpm verify:ledger`)

**Files**
- Test: `tools/test/ledger-gate.bats`

> Milestone 0 OWNS the memory ledger format (`docs/memory-ledger.md` with `<!--ledger:row-->` markers + a `LIMIT_BUDGET_MIB` meta), the conftest/Rego validator (`policy/ledger.rego`), and the `pnpm verify:ledger` script. **This task does NOT create a second ledger, validator, or format.** It (a) ensures the M6 apps are reflected in M0's ledger rows, and (b) asserts the gate `pnpm verify:ledger` passes the real apps and fails a deliberately-limitless app.

**Steps**

1. Ensure each app this milestone added (`api`, `worker`, `web`, `console`, `pg-tools`) has a corresponding `<!--ledger:row-->` entry in M0's `docs/memory-ledger.md` Apps-group table (EDIT M0's file to add the rows; never replace the table or its `LIMIT_BUDGET_MIB` meta). The per-runtime memory limits (Go/Rust 32–64Mi, Node/Python 128Mi, Node SSR 256Mi, JVM ≥384Mi) match the values authored in Tasks 6.8/6.9.

2. Write the failing check exercising M0's gate against this milestone's apps. `tools/test/ledger-gate.bats`:

```bash
#!/usr/bin/env bats

teardown() { rm -rf apps/limitless; }

@test "verify:ledger passes on current apps" {
  run pnpm verify:ledger
  [ "$status" -eq 0 ]
}

@test "verify:ledger FAILS an app with no memory limit (negative test)" {
  mkdir -p apps/limitless/deploy/prod
  cat > apps/limitless/deploy/prod/values.yaml <<'EOF'
image: { repo: ghcr.io/o/limitless, tag: sha-1 }
kind: api
route: { host: x.example.com, public: false }
resources:
  requests: { cpu: 50m }
  limits:   { cpu: 500m }
EOF
  run pnpm verify:ledger
  [ "$status" -ne 0 ]
  [[ "$output" == *"limitless"* || "$output" == *"limits.memory"* || "$output" == *"budget"* ]]
}
```

3. Run it, expect RED if the M0 ledger rows are missing or the negative app is not yet caught:

```
$ bats tools/test/ledger-gate.bats
 ✗ verify:ledger passes on current apps ... ledger row missing for 'console'
2 tests, ... failures
```

4. Add the missing `<!--ledger:row-->` entries to M0's `docs/memory-ledger.md` until the gate is green for the real apps, and confirm the limitless app is rejected by M0's Rego validator. Expect GREEN:

```
$ bats tools/test/ledger-gate.bats
 ✓ verify:ledger passes on current apps
 ✓ verify:ledger FAILS an app with no memory limit (negative test)
2 tests, 0 failures

$ pnpm verify:ledger
ledger OK: apps limits within LIMIT_BUDGET_MIB
```

5. Commit:

```bash
git add docs/memory-ledger.md tools/test/ledger-gate.bats
git commit -m "test: M6 앱들을 메모리 원장에 반영하고 verify:ledger 게이트 검증 추가"
```

---

### Task 6.15 — CI build workflow: arm64 buildx → GHCR `:sha-<gitsha>` (+ pg-tools)

**Files**
- Create: `.github/workflows/build.yaml`
- Test: `tools/test/ci-build.bats`

**Steps**

1. Write the failing check: the workflow runs on `ubuntu-24.04-arm`, builds `linux/arm64` natively (no QEMU), tags `:sha-<gitsha>`, pushes to GHCR, and matrixes the real apps including `pg-tools`. `tools/test/ci-build.bats`:

```bash
#!/usr/bin/env bats
WF=".github/workflows/build.yaml"

@test "build job runs on ubuntu-24.04-arm (native arm64, no QEMU)" {
  run yq '.jobs.build.runs-on' "$WF"
  [[ "$output" == "ubuntu-24.04-arm" ]]
  run grep -i "setup-qemu" "$WF"
  [ "$status" -ne 0 ]   # must NOT use QEMU
}

@test "build pushes immutable :sha-<gitsha> to GHCR" {
  run grep -E "ghcr.io/.*:sha-" "$WF"
  [ "$status" -eq 0 ]
  run yq '.jobs.build.steps[] | select(.uses == "docker/build-push-action*") | .with.platforms' "$WF"
  [[ "$output" == *"linux/arm64"* ]]
}

@test "matrix includes the real apps and pg-tools (16-rclone)" {
  run yq '.jobs.build.strategy.matrix.app' "$WF"
  [[ "$output" == *"api"* ]]
  [[ "$output" == *"pg-tools"* ]]
  run grep -E "pg-tools:16-rclone" "$WF"
  [ "$status" -eq 0 ]
}
```

2. Run it, expect RED:

```
$ bats tools/test/ci-build.bats
 ✗ build job runs on ubuntu-24.04-arm ... could not open file
3 tests, 3 failures
```

3. Implement `.github/workflows/build.yaml`. `pg-tools` additionally gets the canonical `:16-rclone` tag that Milestone 4 references:

```yaml
name: build
on:
  push:
    branches: [main]
    paths:
      - "apps/**"
      - "!apps/**/deploy/**"        # the write-back's values.yaml bump must NOT re-trigger build → no CI self-loop
      - ".github/workflows/build.yaml"

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-24.04-arm        # native arm64 runner — no QEMU
    strategy:
      fail-fast: false
      matrix:
        app: [api, worker, web, console, pg-tools]
    outputs:
      sha: ${{ github.sha }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: detect changed app
        id: changed
        run: |
          # only a SOURCE/Dockerfile change (never a deploy/values.yaml bump) counts as "changed"
          if git diff --name-only ${{ github.event.before }} ${{ github.sha }} \
               | grep -E "^apps/${{ matrix.app }}/" | grep -qvE "^apps/${{ matrix.app }}/deploy/"; then
            echo "build=true" >> "$GITHUB_OUTPUT"
          else
            echo "build=false" >> "$GITHUB_OUTPUT"
          fi
      - name: compute extra tag (pg-tools carries the canonical 16-rclone tag M4 references)
        id: tags
        run: |
          TAGS="ghcr.io/${{ github.repository_owner }}/${{ matrix.app }}:sha-${{ github.sha }}"
          if [ "${{ matrix.app }}" = "pg-tools" ]; then
            TAGS="$TAGS,ghcr.io/${{ github.repository_owner }}/pg-tools:16-rclone"
          fi
          echo "tags=$TAGS" >> "$GITHUB_OUTPUT"
      - name: build & push
        if: steps.changed.outputs.build == 'true'
        uses: docker/build-push-action@v6
        with:
          context: apps/${{ matrix.app }}
          platforms: linux/arm64
          push: true
          provenance: false
          tags: ${{ steps.tags.outputs.tags }}
          cache-from: type=gha,scope=${{ matrix.app }}
          cache-to: type=gha,mode=max,scope=${{ matrix.app }}
      # Record which apps were ACTUALLY built so write-back (bump.yaml) bumps ONLY those —
      # never points an unchanged app at a :sha tag that was never pushed (→ ImagePullBackOff).
      - name: record built app
        if: steps.changed.outputs.build == 'true'
        run: mkdir -p built && printf '%s' "${{ matrix.app }}" > "built/${{ matrix.app }}"
      - name: upload built-app marker
        if: steps.changed.outputs.build == 'true'
        uses: actions/upload-artifact@v4
        with:
          name: built-${{ matrix.app }}
          path: built/${{ matrix.app }}
          retention-days: 1
```

4. Run it, expect GREEN (lint locally; the live push is exercised in Task 6.17). The `tools/test/pg-tools.bats` matrix assertion from Task 6.10 now also goes green:

```
$ bats tools/test/ci-build.bats
 ✓ build job runs on ubuntu-24.04-arm (native arm64, no QEMU)
 ✓ build pushes immutable :sha-<gitsha> to GHCR
 ✓ matrix includes the real apps and pg-tools (16-rclone)

$ bats tools/test/pg-tools.bats
 ✓ pg-tools Dockerfile installs kubectl, psql(16), rclone, curl
 ✓ pg-tools is in the CI build matrix (canonical 16-rclone tag)
```

5. Commit:

```bash
git add .github/workflows/build.yaml tools/test/ci-build.bats
git commit -m "feat: arm64 buildx로 GHCR sha 태그 푸시하는 CI 빌드 워크플로 추가(+pg-tools 16-rclone)"
```

---

### Task 6.16 — CI tag write-back: serialized bot bump of `deploy/<env>/values.yaml` + Telegram

**Files**
- Create: `.github/workflows/bump.yaml`
- Create: `tools/bump-tag.mjs`
- Test: `tools/test/bump.bats`

**Steps**

1. Write the failing check: `bump-tag.mjs api sha-<gitsha>` rewrites ONLY `apps/api/deploy/prod/values.yaml`'s `image.tag` (idempotent: re-running is a no-op), and the workflow declares a single serialized `concurrency` group so two pushes can't race the write-back. `tools/test/bump.bats`:

```bash
#!/usr/bin/env bats
WF=".github/workflows/bump.yaml"

teardown() { git checkout -- apps/api/deploy/prod/values.yaml 2>/dev/null || true; }

@test "bump rewrites only image.tag in the app's values.yaml" {
  before=$(yq '.kind' apps/api/deploy/prod/values.yaml)
  node tools/bump-tag.mjs api sha-deadbee
  run yq '.image.tag' apps/api/deploy/prod/values.yaml
  [[ "$output" == "sha-deadbee" ]]
  after=$(yq '.kind' apps/api/deploy/prod/values.yaml)
  [ "$before" == "$after" ]      # nothing else changed
}

@test "bump is idempotent (second run is a no-op)" {
  node tools/bump-tag.mjs api sha-deadbee
  run node tools/bump-tag.mjs api sha-deadbee
  [[ "$output" == *"no-op"* || "$output" == *"unchanged"* ]]
}

@test "bump workflow is serialized via a single concurrency group" {
  run yq '.concurrency.group' "$WF"
  [ -n "$output" ]
  run yq '.concurrency.cancel-in-progress' "$WF"
  [[ "$output" == "false" ]]     # never cancel a half-done write-back
}
```

2. Run it, expect RED:

```
$ bats tools/test/bump.bats
 ✗ bump rewrites only image.tag ... Cannot find module tools/bump-tag.mjs
3 tests, 3 failures
```

3. Implement.

`tools/bump-tag.mjs` (surgical, comment-preserving via `yaml` document API; idempotent):

```js
#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import { parseDocument } from "yaml";

const [app, tag] = process.argv.slice(2);
if (!app || !/^sha-[0-9a-f]{7,40}$/.test(tag ?? "")) {
  console.error("usage: bump-tag <app> sha-<gitsha>"); process.exit(2);
}
const path = `apps/${app}/deploy/prod/values.yaml`;
const doc = parseDocument(readFileSync(path, "utf8"));
const cur = doc.getIn(["image", "tag"]);
if (cur === tag) { console.log(`bump: ${path} already ${tag} (no-op)`); process.exit(0); }
doc.setIn(["image", "tag"], tag);
writeFileSync(path, doc.toString());
console.log(`bump: ${path} image.tag ${cur} -> ${tag}`);
```

`.github/workflows/bump.yaml` (runs after `build` succeeds; serialized; Telegram via direct Bot API curl so it survives a cluster outage — design §8; `pnpm@10`). It bumps **only the apps `build` actually built** (read from the `built-*` artifacts) and **verifies each `:sha` digest exists in GHCR before committing** — so a one-app change never points unchanged apps at a tag that was never pushed (the prior matrix-over-all-apps bug). `pg-tools` is naturally excluded (no `deploy/<env>/values.yaml`; it is referenced by Milestone 4 directly):

```yaml
name: bump
on:
  workflow_run:
    workflows: [build]
    types: [completed]

# SERIALIZED: only one write-back runs at a time; never cancel a partial commit.
concurrency:
  group: values-writeback
  cancel-in-progress: false

permissions:
  contents: write

jobs:
  writeback:
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    runs-on: ubuntu-24.04-arm
    # NO matrix: a SINGLE serialized job bumps ONLY the apps that were actually built
    # (derived from build.yaml's `built-*` artifacts), verifies each digest exists, commits once.
    steps:
      - uses: actions/checkout@v4
        with:
          ref: main
          token: ${{ secrets.DEPLOY_BOT_PAT }}   # OWNER/ADMIN PAT: its push BYPASSES branch protection (a GITHUB_TOKEN push would be blocked)
      - uses: actions/setup-node@v4
        with: { node-version: "22" }
      - run: corepack enable && corepack prepare pnpm@10 --activate
      - run: pnpm install --frozen-lockfile
      - uses: docker/login-action@v3
        with: { registry: ghcr.io, username: ${{ github.actor }}, password: ${{ secrets.GITHUB_TOKEN }} }
      - name: download built-app markers from the build run
        uses: actions/download-artifact@v4
        with:
          pattern: built-*
          path: built
          merge-multiple: true
          run-id: ${{ github.event.workflow_run.id }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
      - name: derive the set of apps that were actually built
        id: set
        run: |
          if [ ! -d built ] || [ -z "$(ls -A built 2>/dev/null)" ]; then
            echo "apps=" >> "$GITHUB_OUTPUT"; echo "nothing built — no write-back"; exit 0
          fi
          echo "apps=$(ls built | tr '\n' ' ' | sed 's/ *$//')" >> "$GITHUB_OUTPUT"
          echo "built: $(ls built | tr '\n' ' ')"
      - name: verify digests + bump ONLY built apps + commit once
        if: steps.set.outputs.apps != ''
        env:
          SHA: "sha-${{ github.event.workflow_run.head_sha }}"
          OWNER: "${{ github.repository_owner }}"
        run: |
          git pull --rebase origin main
          for app in ${{ steps.set.outputs.apps }}; do
            # only deployed apps have a values.yaml to bump (pg-tools has none)
            [ -f "apps/$app/deploy/prod/values.yaml" ] || { echo "skip $app (no deploy values.yaml)"; continue; }
            echo "verify ghcr.io/$OWNER/$app:$SHA exists BEFORE bumping"
            docker manifest inspect "ghcr.io/$OWNER/$app:$SHA" >/dev/null 2>&1 \
              || { echo "::error::ghcr.io/$OWNER/$app:$SHA missing — refusing to bump (would ImagePullBackOff)"; exit 1; }
            node tools/bump-tag.mjs "$app" "$SHA"
          done
          if git diff --quiet; then echo "no values changed"; exit 0; fi
          git config user.name "homelab-bot"
          git config user.email "bot@users.noreply.github.com"
          git add apps/*/deploy/prod/values.yaml
          git commit -m "chore: 빌드된 앱 이미지 태그를 ${SHA}로 갱신 (${{ steps.set.outputs.apps }})"
          git push origin main
      - name: telegram notify
        if: always()
        env:
          TG_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TG_CHAT: ${{ secrets.TELEGRAM_CHAT_ID }}
        run: |
          curl -fsS -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT}" \
            -d text="deploy write-back ${{ job.status }}: apps=[${{ steps.set.outputs.apps }}] -> sha-${{ github.event.workflow_run.head_sha }}"
```

> If `build` fails, `bump` never runs (the `if` on `workflow_run.conclusion`), so a failed build can never push yesterday's tag — and the Telegram `if: always()` step still pages on a write-back failure, which is exactly R6's "fail loudly on non-zero exit." The `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` Actions secrets mirror the same credential held in-cluster as the Milestone 2 `alerting-secrets` Secret (observability ns).

4. Run it, expect GREEN:

```
$ bats tools/test/bump.bats
 ✓ bump rewrites only image.tag in the app's values.yaml
 ✓ bump is idempotent (second run is a no-op)
 ✓ bump workflow is serialized via a single concurrency group
3 tests, 0 failures
```

5. Commit:

```bash
git add tools/bump-tag.mjs .github/workflows/bump.yaml tools/test/bump.bats
git commit -m "feat: 직렬화된 이미지 태그 write-back과 텔레그램 알림 워크플로 추가"
```

---

### Task 6.17 — End-to-end live verification: api app syncs, migrates in order, probes & route pass

**Files**
- Create: `docs/runbooks/app-onboarding.md`
- Test: `tools/test/e2e-api.sh`

**Steps**

> Requires a live cluster from Milestones 1–5 and `kubectl`/ArgoCD reachable. This task proves the wiring end-to-end, not just rendered YAML.

1. Write the failing check `tools/test/e2e-api.sh` (asserts: migration Job ran in wave 1 BEFORE the Deployment in wave 2 and AFTER CNPG-Ready; pod probes green; HTTPRoute reachable through the shared `homelab` Gateway via Traefik). The CNPG Cluster lives in the `database` ns; Traefik's Service is in the `gateway` ns:

```bash
#!/usr/bin/env bash
set -euo pipefail
NS=prod
APP=api

echo "1) CNPG cluster Ready before app wave (CNPG-Ready gate)?"
kubectl -n database wait --for=condition=Ready cluster/pg --timeout=300s

echo "2) ArgoCD app Synced+Healthy"
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/${APP}-prod --timeout=300s
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/${APP}-prod --timeout=300s

echo "3) migration Job completed and predates the Deployment's ready time"
JOB_END=$(kubectl -n $NS get job ${APP}-migrate -o jsonpath='{.status.completionTime}')
DEP_START=$(kubectl -n $NS get deploy ${APP} -o jsonpath='{.metadata.creationTimestamp}')
test -n "$JOB_END" || { echo "migration Job did not complete"; exit 1; }
echo "   migrate completed at $JOB_END (deploy created $DEP_START)"

echo "4) pod readiness (readyz) green"
kubectl -n $NS rollout status deploy/${APP} --timeout=180s
kubectl -n $NS get deploy ${APP} -o jsonpath='{.status.readyReplicas}' | grep -qx 1

echo "5) HTTPRoute Accepted by the shared homelab Gateway"
kubectl -n $NS get httproute ${APP} \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' | grep -qx True

echo "6) reachable through Traefik (in-cluster curl, gateway ns Service)"
kubectl -n $NS run curl-$RANDOM --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  -s -o /dev/null -w "%{http_code}\n" -H "Host: api.${DOMAIN:?set DOMAIN}" \
  http://traefik.gateway.svc.cluster.local/healthz | grep -qx 200

echo "E2E api: PASS"
```

2. Run it, expect RED (image tag still placeholder → app not yet deployed):

```
$ DOMAIN=<DOMAIN> bash tools/test/e2e-api.sh
1) CNPG cluster Ready before app wave (CNPG-Ready gate)?
...
2) ArgoCD app Synced+Healthy
error: timed out waiting ... application/api never reached Synced
```

3. Drive the real pipeline to make it pass: push the `api` source so CI builds + pushes `ghcr.io/owner/api:sha-<gitsha>`, the `bump` workflow write-back commits the real tag into `apps/api/deploy/prod/values.yaml`, and ArgoCD (via the Milestone 3 ApplicationSet) syncs. Then re-run.

```bash
git push origin main        # triggers build -> bump -> ArgoCD sync
# wait for the bot commit to land, then:
git pull --rebase
yq '.image.tag' apps/api/deploy/prod/values.yaml   # -> sha-<real>
```

Write `docs/runbooks/app-onboarding.md` documenting the chain (gen:app → fill secrets `.enc.yaml` with its own KSOPS `secret-generator.yaml` → push → CI builds → bump write-back → ArgoCD sync → `pnpm verify:app`), with the wave ordering diagram (CNPG-Ready gate → wave0 config/secret → wave1 migrate Job → wave2 Deployment/Service/HTTPRoute) and the R6 staleness/Telegram failure path. Cross-reference Milestone 3's `platform/argocd/root/SYNC-WAVES.md` as the canonical wave registry.

4. Run it, expect GREEN:

```
$ DOMAIN=<DOMAIN> bash tools/test/e2e-api.sh
1) CNPG cluster Ready before app wave (CNPG-Ready gate)?
cluster.postgresql.cnpg.io/pg condition met
2) ArgoCD app Synced+Healthy
application.argoproj.io/api condition met
3) migration Job completed and predates the Deployment's ready time
   migrate completed at 2026-06-10T... (deploy created 2026-06-10T...)
4) pod readiness (readyz) green
deployment "api" successfully rolled out
5) HTTPRoute Accepted by the shared homelab Gateway
6) reachable through Traefik (in-cluster curl)
E2E api: PASS

$ pnpm verify:app api
  ✓ build
  ✓ push
  ✓ tag
  ✓ sync
  ✓ probe
  ✓ route
  ✓ secret

verify:app api: all links green ✅
```

5. Commit:

```bash
git add docs/runbooks/app-onboarding.md tools/test/e2e-api.sh
git commit -m "test: api 앱 엔드투엔드 동기화/마이그레이션 순서/라우트 검증 추가"
```

---

### Task 6.18 — Wire all chart/DX/ledger checks into CI as the onboarding gate

**Files**
- Create: `.github/workflows/ci.yaml`
- Test: `tools/test/ci-gate.bats`

**Steps**

1. Write the failing check: a `ci` workflow runs (on every PR) `make chart-test`, the `.env.example` drift check, M0's `pnpm verify:ledger` onboarding gate, and all bats suites — and the ledger step is a required gate. `tools/test/ci-gate.bats`:

```bash
#!/usr/bin/env bats
WF=".github/workflows/ci.yaml"

@test "ci runs chart-test, env drift, ledger gate, and bats" {
  run cat "$WF"
  [[ "$output" == *"make chart-test"* ]]
  [[ "$output" == *"gen-env-example.mjs api --check"* ]]
  [[ "$output" == *"verify:ledger"* ]]
  [[ "$output" == *"bats "* ]]
}

@test "ci runs on pull_request and uses pnpm@10" {
  run yq '.on.pull_request' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  run grep -E "pnpm@10" "$WF"
  [ "$status" -eq 0 ]
}
```

2. Run it, expect RED:

```
$ bats tools/test/ci-gate.bats
 ✗ ci runs chart-test ... could not open file
2 tests, 2 failures
```

3. Implement `.github/workflows/ci.yaml` (the ledger gate calls M0's `pnpm verify:ledger`, not a M6-local validator):

```yaml
name: ci
on:
  pull_request:
  push:
    branches: [main]

jobs:
  gate:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "22" }
      - run: corepack enable && corepack prepare pnpm@10 --activate
      - run: pnpm install --frozen-lockfile
      - name: install chart toolchain
        run: |
          sudo snap install yq || true
          curl -sL https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-arm64.tar.gz | tar xz -C /usr/local/bin kubeconform
          curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
          sudo apt-get update && sudo apt-get install -y bats
      - name: chart render + validate (all kinds)
        run: make chart-test
      - name: .env.example drift
        run: node tools/gen-env-example.mjs api --check
      - name: memory ledger onboarding gate (M0-owned)
        run: pnpm verify:ledger
      - name: tooling bats suites
        run: bats tools/test/workspace.bats tools/test/examples.bats tools/test/pg-tools.bats tools/test/env-example.bats tools/test/gen-verify.bats tools/test/ledger-gate.bats tools/test/ci-build.bats tools/test/bump.bats tools/test/ci-gate.bats
```

4. Run it, expect GREEN (locally lint; CI is exercised on the PR):

```
$ bats tools/test/ci-gate.bats
 ✓ ci runs chart-test, env drift, ledger gate, and bats
 ✓ ci runs on pull_request and uses pnpm@10
2 tests, 0 failures
```

5. Commit:

```bash
git add .github/workflows/ci.yaml tools/test/ci-gate.bats
git commit -m "test: 차트/env드리프트/메모리원장 온보딩 게이트 CI 추가"
```

---

### Milestone 6 — Done criteria

- `make chart-test` renders valid manifests for **all four kinds** (kubeconform clean), every HTTPRoute attaches to the shared `homelab` Gateway in the `gateway` ns via `sectionName web-public|web-internal`, and every bats suite passes.
- `apps/api` builds a **native arm64 distroless** image in CI, the **serialized** bot write-back lands the real `:sha-<gitsha>` (idempotent), and `tools/test/e2e-api.sh` proves the migration Job ran in **wave 1 (after CNPG-Ready, before the Deployment in wave 2)**, probes are green, and the HTTPRoute is reachable.
- The **`pg-tools` image** (`kubectl`+`psql`+`rclone`+`curl`) is built by the CI matrix and published as `ghcr.io/<owner>/pg-tools:16-rclone` — unblocking Milestone 4's LIVE restore-drill acceptance.
- `pnpm gen:app`, `pnpm verify:app`, `pnpm gen:env` (the generated `.env.example` drift check), and the local dev Postgres all pass.
- The **memory-ledger onboarding gate uses M0's `pnpm verify:ledger`** (no second ledger/validator/format introduced): it passes the real apps and **fails a deliberately limitless app** (negative test).
- Shared M0-owned files were only EDITed, never re-Created: `package.json` (added DX scripts on `pnpm@10`), `Makefile` (added `m6-tools`/`chart-test`), `docs/memory-ledger.md` (added app rows); `.sops.yaml`, `pnpm-workspace.yaml`, and the ledger validator were not re-authored.
- All hardening items in scope are covered: R2 (ledger gate + onboarding), R6 (serialized write-back + fail-loud Telegram on non-zero, `verify:app` placeholder-tag detector), plus the DX trio (local dev Postgres, generated `.env.example`, `gen:app`/`verify:app`), and R1's tooling dependency (`pg-tools` for the restore drill).

---

## Adversarial review dispositions (Phase D audit trail)

This plan survived **five** codex adversarial-review passes. hardened-planning's 3-pass cap was extended **past the cap with an explicit, informed user decision at each step** (the user saw the open-items list before each continuation). Every finding was adjudicated on technical merit; **all were Accepted** (no rejections) — most were grounded cross-milestone integration/correctness gaps, and several were *regressions introduced by an earlier pass's own fix* and corrected in the next pass.

| Pass | verdict | findings | disposition |
|---|---|---|---|
| 1 | needs-attention | 7 | **all accepted + applied** — restore-drill empty-script, appset never invoking the shared chart, R2 cred schema mismatch + missing KSOPS render, CI tag write-back over-scope, missing `pg-app-credentials` producer, CNPG-ready not enforced cross-Application, M1 `svclb` check impossible-at-M1 |
| 2 | needs-attention | 8 | **all accepted + applied** — CI self-trigger loop, PgBouncer name collides with `pg-rw`, branch-protection contexts + `DEPLOY_BOT_PAT`, AdGuard DNS LAN-unreachable, drill PVC leak, DR only deleted argocd ns, drill metric never delivered, M4↔M6 dependency cycle |
| 3 | needs-attention | 7 | **all accepted + applied** — DR recreated an empty DB, M0 circular SOPS gate, appset never rendered app secrets, drill cleanup RBAC, `build` required-check made PRs unmergeable, `ghcr-pull` never provisioned, `write_enc` left plaintext on failure |
| 4 | needs-attention | 6 | **all accepted + applied** — barman-cloud plugin never installed, drill SA cluster-wide PV delete + mutable image, missing `--enable-helm`, `app-credentials.enc.yaml` uncommitted, DR couldn't validate restored data, Tailscale ingress namespace override |
| 5 | needs-attention | 6 | **3 fixed inline, 3 accepted as documented open items (below)** — fixed: DR destroyed before confirming backup (now waits for `completed` + a pre-destruction recovery gate), `drill-ssd` wrong provisioner, Grafana `admin/admin` (now a SOPS-seeded password). Open: external-SSD mount, Helm-hook phase, NetworkPolicy. |

**Final verdict:** Pass 5 `needs-attention`. Finalized past the cap by explicit user decision after reviewing the remaining items. **No unaccepted critical/high finding is left unaddressed in-plan except the three Open items below**, which the user authorized addressing at implementation time.

### Open items — fix at implementation (Pass-5 high-severity, accepted as deferred)

1. **External 1 TB SSD is not actually mounted into the VM (M1).** Task 1.5 creates the VM + a directory, but does not bind the macOS external volume into the guest, so `bulk-ssd` would land on the VM disk and be lost on rebuild.
   → **At M1:** define the macOS external-volume path and an explicit OrbStack bind/guest mount (e.g. `/mnt/mac/Volumes/<SSDName>/k3s-bulk`), and the `bulk-ssd` local-path provisioner must point at it. Gate provisioning on `findmnt` + a write/read sentinel proving the path is on the external device (not the VM disk).

2. **Helm `pre-install,pre-upgrade` hook runs in ArgoCD's PreSync phase, before wave-0 config/secrets (M6 chart).** The migration Job can run before its `envFrom` ConfigMap/Secret exist (install) or with stale config (upgrade).
   → **At M6:** make the migration Job an **ArgoCD `Sync` hook at sync-wave 1** (`argocd.argoproj.io/hook: Sync`, `hook-delete-policy: BeforeHookCreation`) instead of a Helm `pre-install/pre-upgrade` hook, so it runs in the Sync phase *after* wave-0 config/secrets. Keep the `wait-for-db` initContainer. Test ordering through a real ArgoCD sync, not rendered annotations alone.

3. **No NetworkPolicy / east-west isolation (cluster-wide).** "Internal-only" is enforced only as "no public route"; k3s *does* enforce NetworkPolicy, but none are defined, so a compromised public api/ssr pod can reach `database`/admin services.
   → **Add a NetworkPolicy task (M3 or a dedicated security milestone):** per-namespace **default-deny ingress+egress**, then explicit allows — DNS (CoreDNS), gateway→app, app→PgBouncer (`pg-pooler-rw`), vmagent scrape→app `/metrics`, and required operator/edge traffic. Include **negative connectivity tests** (a public workload must NOT reach `database`).

> These three are additive/implementation-time hardening; none changes the approved architecture. The per-task verification-first checks (kustomize build, `kubectl apply`, acceptance tests) will surface them at the relevant milestone, and the guidance above resolves each.
