#!/usr/bin/env bats
load test_helper

# k3s-install.sh는 VM을 건드리지 않고 INSTALL_K3S_EXEC를 출력하는 `print_exec`
# 모드를 제공하므로, 플래그 계약을 오프라인에서 단위 테스트할 수 있다.
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
# kube-reserved/system-reserved/eviction-hard/image-gc-* 는 KUBELET 플래그라서
# 반드시 --kubelet-arg= 로 전달해야 한다 (k3s server는 단독 플래그로 주면 거부한다).
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
# kubelet 플래그가 k3s server 단독 플래그로 나타나면 안 된다 (라이브 bringup 때의 버그)
@test "kubelet flags are NOT passed as bare k3s server flags" {
  [[ "$EXEC" != *"--kube-reserved="* ]]
  [[ "$EXEC" != *"--system-reserved="* ]]
  [[ "$EXEC" != *"--eviction-hard="* ]]
}
@test "secrets encryption enabled and kubeconfig mode 0600 (private admin kubeconfig)" {
  [[ "$EXEC" == *"--secrets-encryption"* ]]
  [[ "$EXEC" == *"--write-kubeconfig-mode=0600"* ]]
}
@test "datastore stays default sqlite/kine (no --cluster-init / etcd)" {
  [[ "$EXEC" != *"--cluster-init"* ]]
  [[ "$EXEC" != *"etcd"* ]]
}

@test "does NOT pass --default-local-storage-path (built-in local-storage provisioner is disabled → flag is a no-op)" {
  [[ "$EXEC" != *"--default-local-storage-path"* ]]
}
