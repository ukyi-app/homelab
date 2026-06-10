# Storage — full live verification (both StorageClasses, end-to-end)

Proves the k3s storage tier actually provisions volumes — not just that the manifests render. The
offline tests (`infra/k3s-bootstrap/test/*.bats`) only render/grep; they CANNOT catch runtime
provisioner failures, so this live sweep is the real gate. Run after `make up` (and, for `bulk-ssd`,
after the external SSD is set up per `docs/runbooks/external-ssd.md`).

LIVE: needs `KUBECONFIG=infra/k3s-bootstrap/kubeconfig` and the `k3s` OrbStack VM running.

```bash
export KUBECONFIG=infra/k3s-bootstrap/kubeconfig
```

## 1. Health sweep (both provisioners + both StorageClasses)

```bash
set -e
NS=local-path-storage
echo "[1] both provisioner pods Running (not CrashLoopBackOff)"
for d in internal bulk; do
  kubectl -n $NS rollout status deploy/local-path-provisioner-$d --timeout=60s >/dev/null && echo "  $d OK"
done
echo "[2] no fatal in provisioner logs (missing --configmap-name regresses here)"
kubectl -n $NS logs -l 'app in (local-path-provisioner-internal,local-path-provisioner-bulk)' --tail=50 \
  | grep -i 'level=fatal' && { echo FAIL; exit 1; } || echo OK
echo "[3] both StorageClasses present, WaitForFirstConsumer (local-path supports nothing else)"
kubectl get sc standard  -o jsonpath='{.volumeBindingMode}' | grep -qx WaitForFirstConsumer && echo "  standard OK"
kubectl get sc bulk-ssd  -o jsonpath='{.volumeBindingMode}' | grep -qx WaitForFirstConsumer && echo "  bulk-ssd OK"
kubectl get sc standard  -o jsonpath='{.reclaimPolicy}'     | grep -qx Retain && echo "  standard=Retain OK"
kubectl get sc bulk-ssd  -o jsonpath='{.reclaimPolicy}'     | grep -qx Delete && echo "  bulk-ssd=Delete OK"
echo "HEALTH GREEN"
```

## 2. bulk-ssd external-SSD backing check

`bulk-ssd` must land on the external SSD, never the VM disk. This is the same gate `apply-storage.sh`
runs (`docs/runbooks/external-ssd.md` §5):

```bash
# HOST: external device (a virtiofs FSTYPE alone cannot distinguish external from internal)
diskutil info /Volumes/homelab | grep 'Device Location' | grep -q External && echo "host=External OK"
# VM: virtiofs share resolves (findmnt -T) and is writable
orb -m k3s -u root env BULK_EXTERNAL_MOUNT=/mnt/mac/Volumes/homelab \
  BULK_STORAGE_PATH=/mnt/mac/Volumes/homelab/k3s-bulk \
  sh -s < infra/k3s-bootstrap/bulk-gate-probe.sh    # prints: external-bulk-probe-ok
```

## 3. End-to-end provisioning test (create → write → read → reclaim)

Provisions a real PVC on each class, writes a sentinel, reads it back, confirms the data is on the
EXPECTED node path, then cleans up honouring each class's reclaim policy.

```bash
e2e_sc() {  # $1=storageClass  $2=node-path-prefix (in the VM)  $3=reclaim(Retain|Delete)
  sc="$1"; prefix="$2"; reclaim="$3"; name="verify-$sc"
  echo "== e2e: $sc (expect $reclaim, path $prefix) =="
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: $name, namespace: default }
spec: { storageClassName: $sc, accessModes: [ReadWriteOnce], resources: { requests: { storage: 64Mi } } }
---
apiVersion: v1
kind: Pod
metadata: { name: $name, namespace: default }
spec:
  restartPolicy: Never
  containers: [{ name: w, image: busybox:1.36, command: ["sh","-c","echo $name-proof > /data/proof.txt; sleep 300"], volumeMounts: [{ name: d, mountPath: /data }] }]
  volumes: [{ name: d, persistentVolumeClaim: { claimName: $name } }]
EOF
  kubectl -n default wait --for=condition=Ready pod/$name --timeout=120s >/dev/null
  pv=$(kubectl -n default get pvc $name -o jsonpath='{.spec.volumeName}')
  path=$(kubectl get pv "$pv" -o jsonpath='{.spec.hostPath.path}')
  echo "  Bound: $pv -> $path"
  case "$path" in "$prefix"*) echo "  on expected backing OK" ;; *) echo "  FAIL: wrong path"; return 1 ;; esac
  # Read the data from inside the VM (the sandboxed host shell can't read /Volumes/* due to macOS TCC).
  orb -m k3s -u root sh -c "cat '$path/proof.txt'" | grep -qx "$name-proof" && echo "  data on disk OK"
  kubectl -n default exec $name -- cat /data/proof.txt | grep -qx "$name-proof" && echo "  pod read OK"
  # teardown
  kubectl -n default delete pod $name --grace-period=0 --force >/dev/null 2>&1
  kubectl -n default delete pvc $name >/dev/null 2>&1
  if [ "$reclaim" = Delete ]; then
    # the teardown helper pod runs async (~5-10s); poll up to ~30s until the dir is gone
    for _ in $(seq 1 15); do orb -m k3s -u root sh -c "ls '$path' 2>/dev/null" >/dev/null 2>&1 || break; sleep 2; done
    orb -m k3s -u root sh -c "ls '$path' 2>/dev/null" >/dev/null 2>&1 \
      && { echo "  FAIL: Delete-reclaim left data"; return 1; } || echo "  Delete-reclaim cleaned OK"
  else
    kubectl delete pv "$pv" >/dev/null 2>&1; orb -m k3s -u root sh -c "rm -rf '$path'"  # Retain keeps it; remove by hand
    echo "  Retain PV+data removed by hand OK"
  fi
}

e2e_sc standard /var/lib/rancher/k3s-storage/internal Retain
e2e_sc bulk-ssd /mnt/mac/Volumes/homelab/k3s-bulk     Delete
echo "STORAGE E2E GREEN"
```

## Gotchas (each is a real bug this runbook has caught)

- **`--configmap-name` is mandatory.** Our configmaps are renamed (`local-path-config-{internal,bulk}`),
  so each provisioner Deployment MUST pass `--configmap-name=…` (and `--helper-pod-file`). Without it
  the daemon fatals and every helper pod `FailedMount`s the default `local-path-config`. Guarded by
  `test/06`'s flag/mount-consistency case.
- **`Immediate` binding is unsupported.** local-path creates the hostPath PV on the consumer's node,
  so an `Immediate` SC fails `"configuration error, no node was specified"`. Both classes are
  `WaitForFirstConsumer`.
- **The sandboxed Bash tool cannot read `/Volumes/*`** (macOS TCC EPERM). Always inspect the external
  SSD from inside the VM with `orb -m k3s -u root …`; OrbStack itself holds the TCC grant.
- **`bulk-ssd` is `Delete`-reclaim, `standard` is `Retain`.** Deleting a `standard` PVC leaves the PV
  `Released` and the data on disk — clean it up by hand (the e2e function does).
```
