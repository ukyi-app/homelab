# Runbook 02 — Cloud IaC Bootstrap (manual-once + make bootstrap)

> Status: Terraform roots are authored and offline-validated. The **live** steps
> below (R2 state bucket, `terraform apply`, `make bootstrap`) require real
> Cloudflare/GitHub/Tailscale credentials + a domain and are performed once the
> operator supplies them.

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

## Recipients (consume M0's key material — never mint)

```bash
# cluster recipient: derived from the M0 private key on disk
export AGE_CLUSTER_RECIPIENT=$(age-keygen -y ~/.config/sops/age/keys.txt)

# recovery recipient: the PUBLIC key M0 stored alongside the recovery private key
# in the password manager (private key is NOT on this workstation).
export AGE_RECOVERY_RECIPIENT=age1recoveryPUBLICkeyFROMpasswordMANAGER
```

`.sops.yaml` already carries BOTH real recipients (filled by M0 Task 0.5). M2 only
verifies them — it never re-fills or restructures the file:

```bash
grep -q 'REPLACEME' .sops.yaml && { echo "FAIL: .sops.yaml still has placeholders (fix in M0 Task 0.5)"; exit 1; }
grep -q "$AGE_CLUSTER_RECIPIENT" .sops.yaml && grep -q "$AGE_RECOVERY_RECIPIENT" .sops.yaml \
  && echo ".sops.yaml recipients verified (cluster + recovery)"
```

Recovery-key custody: record which password-manager vault item holds the recovery
private key (M0 §15). No key is ever minted, copied, or written to disk here.

## Manual-once: R2 state bucket + rclone remote `r2`

In the Cloudflare dashboard create an R2 API token (Object Read & Write) for
account `<ACCT_ID>`, then:

```bash
rclone config create r2 s3 \
  provider=Cloudflare \
  access_key_id=<R2_STATE_ACCESS_KEY> \
  secret_access_key=<R2_STATE_SECRET_KEY> \
  endpoint=https://<ACCT_ID>.r2.cloudflarestorage.com \
  region=auto
rclone mkdir r2:homelab-tfstate
```

The state bucket is created manually, once, **before** any `terraform apply` — it
stores the very state these roots write (R5), so it must exist before `init`.

## Backend config

`infra/_backend/backend.tf` is the shared partial S3 backend (committed). Each
root copies it in and supplies the secret-bearing partial via a gitignored
`backend.hcl` (template: `infra/_backend/backend.hcl.example`) at init:

```bash
terraform -chdir=infra/<root> init -backend-config=infra/<root>/backend.hcl
```

Per-root state keys: `cloudflare/prod/terraform.tfstate`,
`tailscale/prod/terraform.tfstate`, `github/prod/terraform.tfstate`.

## Offline validation (no credentials needed)

```bash
make tf-validate    # fmt -check + validate -backend=false across all three roots
```
