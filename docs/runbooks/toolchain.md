# Host Toolchain (macOS, arm64)

These tools run on the developer Mac (host side), not inside the OrbStack VM.

Install:

```bash
brew install sops age conftest pre-commit ksops
```

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

## Re-verify

```bash
for b in sops age age-keygen ksops conftest pre-commit; do command -v "$b" && "$b" --version 2>/dev/null | head -1; done
```
