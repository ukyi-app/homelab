# infra/k3s-bootstrap

**역할** — 호스트 substrate 부트스트랩: OrbStack VM 생성(`orb-create.sh`/`orb-guard.sh`) + cloud-init + k3s 설치(`k3s-install.sh`) + 스토리지(local-path-provisioner, standard/bulk-ssd StorageClass). terraform이 아닌 셸 스크립트 계층.

**적용 방식** — **bootstrap 스크립트(owner 로컬)**: `host-up.sh`로 VM·k3s·스토리지를 올리고 `verify-cluster.sh`로 검증. 버전 핀은 `versions.env`. CI 아님.

**라이브 디버그** — 셸 스크립트 로그 + `verify-cluster.sh`. 런북 `docs/runbooks/host-substrate.md`(OrbStack VM/k3s 계층), `docs/runbooks/external-ssd.md`, `docs/runbooks/storage-verify.md`. 테스트는 `infra/k3s-bootstrap/test/`.

**함정 SSOT** — AGENTS.md "라이브에서 검증된 함정": OrbStack은 VM에서 LISTEN 중인 포트만 Mac으로 포워딩(servicelb/hostPort iptables DNAT는 트리거 안 됨 → `dns-forward-trigger.service`), VM IP(192.168.139.x)는 Mac에서 직접 라우팅 안 됨. 모든 PV가 hostPath라 `kubelet_volume_stats` 부재, 외장 SSD는 virtiofs라 VM서 측정 불가.
