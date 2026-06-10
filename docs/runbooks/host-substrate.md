# Host Substrate Runbook (OrbStack VM + k3s)

The host substrate is **cattle, as code**. One OrbStack Debian bookworm arm64 VM
(`k3s`, 11 GiB / 6 vCPU) runs single-node k3s (SQLite/kine). Every bring-up step
is a committed script under `infra/k3s-bootstrap/`.

## Bring up / rebuild (idempotent)

```bash
make up          # → infra/k3s-bootstrap/host-up.sh : orb-create → k3s-install → apply-storage → orb-guard
```

A full rebuild is just `make up` again — the VM is disposable; cluster state
repopulates via ArgoCD + R2 restore (M2+). M5's `make bootstrap` calls `make up`
first.

## Host access to the cluster

```bash
export KUBECONFIG="$PWD/infra/k3s-bootstrap/kubeconfig"   # gitignored (cluster-admin token)
kubectl get nodes
```

OrbStack auto-forwards the VM's listening `:6443` to the host's `127.0.0.1:6443`,
and the k3s serving cert lists `127.0.0.1` as a SAN — so the retrieved kubeconfig
points at `https://127.0.0.1:6443` and works from macOS as-is (no `*.orb.local`
DNS; that domain does not exist for OrbStack machines and is not a cert SAN).

## Acceptance evidence — 2026-06-10

`kubectl get nodes -o wide`:

```
NAME   STATUS   ROLES                  AGE   VERSION        INTERNAL-IP       OS-IMAGE                         CONTAINER-RUNTIME
k3s    Ready    control-plane,master   6m    v1.31.4+k3s1   192.168.139.194   Debian GNU/Linux 12 (bookworm)   containerd://1.7.23-k3s2
```

`kubectl get sc`:

```
NAME                 PROVISIONER                      RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
bulk-ssd             homelab.io/local-path-bulk       Delete          WaitForFirstConsumer   true
standard (default)   homelab.io/local-path-internal   Retain          Immediate              true
```

`kubectl get pods -n kube-system | grep -Ei 'traefik|metrics-server|svclb'`:
empty — traefik and metrics-server are disabled; `svclb-*` pods appear only once
Traefik's LoadBalancer Service exists (M3).

`k3s secrets-encrypt status`:

```
Encryption Status: Enabled
Current Rotation Stage: start
Server Encryption Hashes: All hashes match
```

`infra/k3s-bootstrap/verify-cluster.sh` → `OK: host substrate verified (node
Ready, both SCs, traefik/metrics-server absent, servicelb kept,
secrets-encryption enabled).`

## Notes carried from the live bring-up (OrbStack 2.x realities)

- **k3s node-protection knobs are kubelet flags** (`kube-reserved`,
  `system-reserved`, `eviction-hard`, `image-gc-*`) and are delivered via
  `--kubelet-arg=…`; passing them as bare k3s server flags is fatal.
- **`orb list` prints no header when piped** — parsing drops blank/`NAME` lines
  rather than `tail -n +2`.
- **Global OrbStack caps** (`orb config set memory_mib/cpu`) take effect after an
  OrbStack restart; the create call applies them at boot.
