# infra/k3s-bootstrap

**역할** — 호스트 substrate 부트스트랩: 전제 확인(`host-preflight.sh`) + k3s 설치(`k3s-install.sh`) + 스토리지(local-path-provisioner, standard/bulk-ssd StorageClass) + 라이브 계약 검증(`verify-cluster.sh`). terraform이 아닌 셸 스크립트 계층. 진입점은 `host-up.sh`(= `make up`).

**적용 방식** — **bootstrap 스크립트(owner 로컬)**: `host-up.sh`로 VM·k3s·스토리지를 올리고 `verify-cluster.sh`로 검증. 버전 핀은 `versions.env`. CI 아님.

**라이브 디버그** — 셸 스크립트 로그 + `verify-cluster.sh`. 런북 `docs/runbooks/host-substrate.md`(OrbStack VM/k3s 계층), `docs/runbooks/external-ssd.md`, `docs/runbooks/storage-verify.md`. 테스트는 `infra/k3s-bootstrap/tests/`.

**함정 SSOT** — docs/traps-detail.md. 베어메탈 이전으로 OrbStack 고유 함정(포트포워드·VM IP 비라우팅·virtiofs)은 소멸했고, 대신 **CNI hostPort DNAT가 `--dst-type LOCAL`로 노드 자신의 :53 질의까지 끌어가는** 콜드스타트 교착이 자리를 대신한다(`host-preflight.sh` 헤더가 기전의 SSOT). 모든 PV가 hostPath라 `kubelet_volume_stats`는 여전히 부재.
