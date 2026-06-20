# network-policies

**역할** — 클러스터 NetworkPolicy(default-deny + 컴포넌트별 ingress/egress 허용). kube-router가 nftables로 강제한다.

**싱크 Application · sync-wave** — `platform-components` ApplicationSet이 `platform/network-policies/prod`을 `network-policies-prod` Application으로 자동 발견. sync-wave 미지정 → 기본 **0**.

**라이브 디버그** — `argo` 스킬(sync/health). NP 라이브 동작/테스트 노트는 [prod/NOTES.md](prod/NOTES.md). 라이브 검증은 `prod/test_netpol.bats`.

**함정 SSOT** — docs/traps-detail.md: (1) ipBlock에 pod CIDR(`10.42.0.0/16`)을 넣으면 "전체 파드 허용"으로 default-deny 무력화 — kubelet probe 소스는 노드(`cni0=10.42.0.1`)뿐, kube-router는 노드발 트래픽을 정책 평가 전에 이미 허용, (2) kube-router는 새 파드 방화벽 룰을 수 초 늦게 설치 → NP 테스트는 `sleep 8` 후 연결, kube-router v2는 sync마다 체인 이름이 바뀌어 라이브 디버깅은 원자 스냅샷(`nft list` 1회)에서 카운터 확인.
