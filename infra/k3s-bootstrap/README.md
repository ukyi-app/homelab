# infra/k3s-bootstrap

**역할** — 호스트 substrate 부트스트랩: 호스트 설정(`host-config.sh` + `host-config/` 트리) + 전제 확인(`host-preflight.sh`) + k3s 설치(`k3s-install.sh`) + 스토리지(local-path-provisioner, standard/bulk-ssd StorageClass) + 라이브 계약 검증(`verify-cluster.sh`). terraform이 아닌 셸 스크립트 계층. 진입점은 `host-up.sh`(= `make up`).

**적용 방식** — **bootstrap 스크립트(owner 로컬)**: `host-up.sh`로 k3s·스토리지를 올리고 `verify-cluster.sh`로 검증. 버전 핀은 `versions.env`. CI 아님.

**호스트 설정 계층** — `cloud-init.yaml`의 후계다. NUC은 이미 설치·부팅된 기계이고 `cloud-init status`가 `disabled`라(실측) first-boot 데이터는 실행될 기회가 없다. 그래서 **실파일 트리 + 멱등 설치기**다:
- `host-config/` — 그대로 `/`에 놓이는 드롭인 트리(resolved · journald · sshd). `diff`가 곧 리뷰이고 **트리 열거가 곧 검사 도메인**이다.
- `host-config.sh --check` (기본) — 선언 ↔ 디스크 **드리프트 검사**. sudo 불요.
- `host-config.sh --apply` — 상태를 만든다(트리 설치 · 타임존 · 스왑 제거 · tailnet DNS 분리 · storage dir · 유닛 반영). **대화형 sudo 필요** — owner의 sudo가 패스워드를 요구하므로(실측) 자동화 경로가 아니다. 노드 프로비저닝 시 한 번 돌린다.

역할 경계: `--check`는 "커밋된 파일이 디스크에 그대로 있는가", `host-preflight.sh`는 "실효값이 맞는가". `host-up.sh`가 부르는 것은 후자다.

**라이브 디버그** — 셸 스크립트 로그 + `verify-cluster.sh`. 런북 `docs/runbooks/host-substrate.md`(OrbStack VM/k3s 계층), `docs/runbooks/external-ssd.md`, `docs/runbooks/storage-verify.md`. 테스트는 `infra/k3s-bootstrap/tests/`.

**함정 SSOT** — docs/traps-detail.md. 베어메탈 이전으로 OrbStack 고유 함정(포트포워드·VM IP 비라우팅·virtiofs)은 소멸했고, 대신 **CNI hostPort DNAT가 `--dst-type LOCAL`로 노드 자신의 :53 질의까지 끌어가는** 콜드스타트 교착이 자리를 대신한다(`host-preflight.sh` 헤더가 기전의 SSOT). 모든 PV가 hostPath라 `kubelet_volume_stats`는 여전히 부재.
