# External SSD for the `bulk-ssd` storage tier (Pass-5 Open Item #1)

The `bulk-ssd` StorageClass (CNPG local `pg_basebackup` staging, backup hedge, reproducible
media) must live on an **external SSD**, not the VM's own disk — otherwise a cattle rebuild of
the `k3s` OrbStack VM (`make up`) wipes it. OrbStack shares the macOS filesystem into the VM over
**virtiofs**, so the external volume mounted at `/Volumes/homelab` on macOS appears inside the VM
at `/mnt/mac/Volumes/homelab`. `apply-storage.sh` **gates** on that path being a writable virtiofs
mount before it wires the bulk provisioner, so a missing/unwritable SSD fails loudly instead of
silently landing bulk on the VM disk.

This is a **host setup** step (needs `sudo` + a macOS privacy grant); it is required before the
M4 CNPG bulk/backup workloads run live. It does **not** need to be done for inner-loop dev (see the
`BULK_ALLOW_VM_DISK=1` fallback below).

Canonical paths (pinned in `infra/k3s-bootstrap/versions.env`):

| Where | Path |
|-------|------|
| macOS (host)      | `/Volumes/homelab/k3s-bulk` |
| VM (virtiofs)     | `/mnt/mac/Volumes/homelab/k3s-bulk` (`BULK_STORAGE_PATH`) |
| VM mount to gate  | `/mnt/mac/Volumes/homelab` (`BULK_EXTERNAL_MOUNT`) |

## 1. Find the external APFS container

```sh
diskutil list external physical
```

Note the external **APFS Container** disk id (on this host: `disk5`, a 2 TB drive whose only other
volume is `ukkiee`). APFS volumes in one container **share free space**, so adding a `homelab`
volume is non-destructive — **`ukkiee` (or any existing volume) is left untouched.**

## 2. Create the dedicated `homelab` APFS volume

> A bare `mkdir /Volumes/homelab` would land on the **internal** boot disk (because `/Volumes` is a
> directory on `/`). To put the data on the **external** SSD you must add a real APFS volume:

```sh
diskutil apfs addVolume disk5 APFS homelab     # adjust disk5 to your container from step 1
```

It mounts at `/Volumes/homelab`. Verify it is on the external device:

```sh
diskutil info /Volumes/homelab | grep -E 'Part of Whole|Mount Point'   # "Part of Whole" must be the external disk
```

## 3. Create the bulk base dir, owned by your user

The virtiofs share maps VM root → the macOS user running OrbStack, so the dir must be writable by
that user:

```sh
sudo mkdir -p /Volumes/homelab/k3s-bulk
sudo chown -R "$(id -u)":"$(id -g)" /Volumes/homelab
chmod -R u+rwX /Volumes/homelab
```

## 4. Grant OrbStack access to the external (removable) volume

macOS TCC blocks apps from writing removable volumes until granted (symptom: writes fail with
`Operation not permitted`). In **System Settings → Privacy & Security**:

- **Files and Folders** (or **Full Disk Access**): enable **OrbStack** (and your terminal app).
- If a **Removable Volumes** prompt appears for OrbStack, **Allow**.

Then restart OrbStack/the VM so the grant takes effect:

```sh
orb restart k3s     # or: make up   (cattle rebuild)
```

## 5. Verify the gate passes

The gate has two halves — a macOS-side external-device check and a VM-side virtiofs+writability probe:

```sh
# (1) HOST: the path must be on a physically EXTERNAL disk (this is what distinguishes the real
#     external SSD from a bare dir on the internal/boot disk — a virtiofs FSTYPE cannot).
diskutil info /Volumes/homelab | grep 'Device Location'      # must print: External

# (2) VM: the share resolves to virtiofs (findmnt -T, because the subdir is not its own mountpoint)
#     and is writable from inside the VM. This runs the exact probe apply-storage.sh uses:
orb -m k3s -u root env BULK_EXTERNAL_MOUNT=/mnt/mac/Volumes/homelab \
  BULK_STORAGE_PATH=/mnt/mac/Volumes/homelab/k3s-bulk \
  sh -s < infra/k3s-bootstrap/bulk-gate-probe.sh            # must print: external-bulk-probe-ok

# Or just run the real apply (the gate runs first, then applies the provisioner + StorageClasses):
infra/k3s-bootstrap/apply-storage.sh
kubectl get sc          # standard (default) + bulk-ssd present
```

A healthy gate prints `==> Host check: /Volumes/homelab Device Location = External` and
`==> External bulk SSD OK (external disk, virtiofs, writable).`

## Notes

- **Persistence across rebuild:** the external volume survives `make up` (the VM is cattle, the SSD
  is not). bulk PVs are re-bound to the same on-SSD paths. The `bulk-ssd` StorageClass uses
  `reclaimPolicy: Delete` for reproducible data; CNPG's own backups (R2) remain the source of truth.
- **Dev / inner-loop without the SSD:** `BULK_ALLOW_VM_DISK=1 infra/k3s-bootstrap/apply-storage.sh`
  skips the gate and points bulk at the VM disk (`/var/lib/rancher/k3s-storage/bulk`). This is
  **non-persistent** across rebuild — never use it for real data.
- **`ukkiee` is never used or modified** by this setup; only the new `homelab` volume is touched.
