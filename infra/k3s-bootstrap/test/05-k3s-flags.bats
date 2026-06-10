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
# kube-reserved/system-reserved/eviction-hard/image-gc-* are KUBELET flags and
# must be delivered via --kubelet-arg= (k3s server rejects them as bare flags).
@test "kube-reserved and system-reserved go through --kubelet-arg" {
  [[ "$EXEC" == *"--kubelet-arg=kube-reserved=cpu=250m,memory=512Mi"* ]]
  [[ "$EXEC" == *"--kubelet-arg=system-reserved=cpu=250m,memory=512Mi"* ]]
}
@test "eviction-hard set for memory and nodefs via --kubelet-arg" {
  [[ "$EXEC" == *"--kubelet-arg=eviction-hard=memory.available<250Mi,nodefs.available<10%"* ]]
}
@test "image GC thresholds are 80/70 via --kubelet-arg" {
  [[ "$EXEC" == *"--kubelet-arg=image-gc-high-threshold=80"* ]]
  [[ "$EXEC" == *"--kubelet-arg=image-gc-low-threshold=70"* ]]
}
# bare kubelet flags must NOT appear as k3s server flags (the live-bringup bug)
@test "kubelet flags are NOT passed as bare k3s server flags" {
  [[ "$EXEC" != *"--kube-reserved="* ]]
  [[ "$EXEC" != *"--system-reserved="* ]]
  [[ "$EXEC" != *"--eviction-hard="* ]]
}
@test "secrets encryption enabled and kubeconfig mode 0644" {
  [[ "$EXEC" == *"--secrets-encryption"* ]]
  [[ "$EXEC" == *"--write-kubeconfig-mode=0644"* ]]
}
@test "datastore stays default sqlite/kine (no --cluster-init / etcd)" {
  [[ "$EXEC" != *"--cluster-init"* ]]
  [[ "$EXEC" != *"etcd"* ]]
}
