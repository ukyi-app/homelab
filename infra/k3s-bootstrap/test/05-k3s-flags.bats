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
