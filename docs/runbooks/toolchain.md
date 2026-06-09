# Host Toolchain (macOS, arm64)

These tools run on the developer Mac (host side), not inside the OrbStack VM.

Install:

```bash
brew install sops age conftest pre-commit ksops bash yq bats-core
```

> `bash` (>= 5) is required: the host-substrate scripts (`infra/k3s-bootstrap/*`)
> use bash 4+ features (`mapfile`, etc.) that macOS's stock `/bin/bash` 3.2 lacks.
> Homebrew's `bash` lands in `/opt/homebrew/bin`, which precedes `/bin` on PATH,
> so `/usr/bin/env bash` resolves to it.

> Note: `ksops` now ships in `homebrew-core` (formula `ksops`). The older
> `viaduct-ai/ksops/ksops` tap was removed (404), so install it from core.

| Tool       | Pinned version | Purpose                                   |
|------------|----------------|-------------------------------------------|
| sops       | 3.13.1         | Encrypt/decrypt committed secrets         |
| age        | 1.3.1          | Encryption backend for sops               |
| age-keygen | 1.3.1 (bundled)| Generate age keypairs                     |
| ksops      | 4.5.1          | Kustomize exec plugin (ArgoCD repo-server)|
| conftest   | 0.68.2         | OPA/Rego policy checks (ledger validator) |
| pre-commit | 4.6.0          | Git pre-commit hook framework             |
| bash       | 5.3.12         | Host-substrate scripts need bash 4+       |
| yq         | 4.53.2         | YAML assertions in bootstrap bats tests   |
| bats-core  | 1.13.0         | Shell test harness                        |

## Re-verify

```bash
for b in sops age age-keygen ksops conftest pre-commit; do command -v "$b" && "$b" --version 2>/dev/null | head -1; done
```
