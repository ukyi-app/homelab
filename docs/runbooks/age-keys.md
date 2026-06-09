# age Key Custody (two-recipient model)

Every committed secret is encrypted to **two** age recipients so loss of the
in-cluster key is recoverable (design §5, R5). Public recipients are safe to
commit; **private keys are never committed**.

## Recipients (public — safe to commit in .sops.yaml)
| Role     | Recipient (public)        | Private key custody                                  |
|----------|---------------------------|------------------------------------------------------|
| cluster  | `age1n3j7p70f0unl5dgrjhtr9jxrdntz2a67dtntu446qus9c3jd3fnsp8z960` | `~/.config/sops/age/keys.txt` (host, 0600); delivered to k3s as the Secret `sops-age` in namespace `argocd` (file key `keys.txt`) during `make bootstrap`, never in git |
| recovery | `age154tu9q7922xu46x0rkfm5l9x3ulf9u5at5qvxeaqfx9sgtm7cumq75jdwc` | Password manager item "homelab age recovery" — offline, no on-disk copy |

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
