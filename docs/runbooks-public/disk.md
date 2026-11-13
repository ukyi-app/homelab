# NUC 디스크 여유 확보

디스크가 차면 먼저 큰 경로를 재고, 다시 만들 수 있는 캐시·이미지부터 정리한다.
PV·DB·삭제 원장은 파일을 직접 지워 공간을 만드는 대상이 아니다.
이 문서는 관리자가 실행하는 런북이다. 에이전트(봇)는 확인 결과와 다음 순서를 관리자에게 안내하고, 호스트 명령을 대신 실행하지 않는다.

작성 기준: 2026-11-14, 저장소 `5f85a642b09364606b6990aa73af9927df23dbbd`.
`[확인]`은 저장소의 파일:줄 또는 읽기 측정 근거, `[추론]`은 그 근거에서 낸 판단이다.
`[미확인: 돌려 보지 않음]`은 문서·도움말로 문법만 확인한 명령이다. 삭제·이동·sudo 명령은 작성 중 실행하지 않았다.
아래 `<…>`는 관리자가 확인한 값으로 바꾼다. 경로·세션 내용·덤프 내용·원장 내용은 공개 기록에 복사하지 않는다.

## 언제 쓰나

- `NodeFilesystemAlmostFull`이 울렸을 때. 쓰기 가능한 ext4·xfs·btrfs의 **가용 공간이 전체의 10% 미만으로 15분** 이어지면 발화한다. [확인] [platform/observability/stack/vmalert/rules/core.yaml:69](../../platform/observability/stack/vmalert/rules/core.yaml#L69).
- 아직 경보가 없어도 여유가 계속 줄어들 때. [확인] kubelet의 `nodefs.available<10%` 퇴거 설정도 있다([host/k3s-config.yaml:25](../../host/k3s-config.yaml#L25)). [추론] 경보가 울릴 때까지 기다리면 파드 퇴거와 겹칠 수 있다.
- `/`와 `/mnt/bulk` 중 **찬 파일시스템을 먼저 고른다.** SSD에서 지운 파일은 루트의 여유를 늘리지 않는다.

## 1. 먼저 확인

### 어느 파일시스템이 얼마나 찼나

[확인] 아래 명령은 2026-11-14 읽기 실행에 성공했다.

```sh
df -hT / /mnt/bulk
df -i / /mnt/bulk
df -hT /var/lib/taskstate/mnt
journalctl --disk-usage
findmnt -n -r -o SOURCE,FSTYPE,OPTIONS,LABEL --mountpoint /mnt/bulk
```

`df`는 파일시스템 전체, `du`는 읽을 수 있는 파일의 할당 공간을 잰다. `du`의 권한 오류·시간 초과를 0으로 해석하지 않는다.
inode가 찼다면 작은 파일이 많은 경로도 본다. `du -x`는 다른 파일시스템을 건너뛰므로 작업 상태 loop 볼륨과 SSD는 따로 잰다.
같은 파일의 하드링크, 열린 채 삭제된 파일, 파일시스템 메타데이터 때문에 `df`와 여러 `du`의 단순 합은 같지 않을 수 있다.
문법은 실행한 `du --help`에서 확인했다.

**2026-11-14 측정:**

- 루트: **913GiB 중 540GiB 사용, 327GiB 가용, `df` 사용률 63%, inode 7% 사용**. `df`의 사용률과 `avail/size`는 예약 공간 때문에 정확한 보수가 아니다. 경보와 비교할 때는 가용 바이트를 쓴다.
- `/mnt/bulk`: 약 **1.8TiB**, 사용 약 **2.1MiB**. 작업 상태 loop 파일시스템은 **2.0GiB**, 사용 **564KiB**였다.
- journald: **496.3MiB**. `/var/crash`: `du -x -h --max-depth=1 /var/crash`로 **약 1.4GiB**, 날짜 디렉터리 둘을 확인했다. 덤프의 조사 완료 여부는 확인하지 않았다.
- 홈 폴더 **약 321GiB**, 그중 홈 폴더의 개인 작업 폴더가 가장 크고 rootless Podman 저장소가 **약 62GiB**라는 수치는 2026-11-14에 따로 잰 값이다. 이 문서를 쓴 환경의 홈 전체 `du`는 35초 제한으로 끝내지 못했다. Podman 경로는 **약 61.1GiB까지** 읽었지만 권한 오류가 있어 하한값이다.
- 직접 읽은 홈 하위 합계: `~/.cache` **약 2.0GiB**, `~/.bun/install/cache` **약 3.1GiB**, `~/.npm` **약 1.5GiB**, `~/.codex/sessions` **약 3.3GiB**, `~/.claude/projects` **약 2.0GiB**. `~/.codex/archived_sessions`는 없었다. 개인 작업 폴더의 파일 내용은 열지 않았다.

**2026-11-14 관리자 sudo 측정(2절의 명령, 읽기만):**

- 루트 540GiB의 큰 덩어리는 둘이다. `/home` **361GiB**, `/var` **168GiB**. 나머지(`/usr` 등)는 합쳐 10GiB가 안 된다.
- `/var`의 대부분은 k3s containerd다. `/var/lib/rancher/k3s/agent/containerd` **160GiB**(스냅샷 114GiB, content 46GiB). 이미지를 자주 올린 흔적이다.
- PV 전체(`/var/lib/rancher/k3s/storage`)는 **2GiB**, kubelet 파드 2GiB, `/var/crash` 2GiB, 파드 로그 1GiB 미만이다. 데이터가 아니라 이미지가 디스크를 쓰고 있다.
- rootless Podman(`podman system df`): 이미지 376개 중 5개만 쓰는 중이고 **85.7GB 가운데 84.1GB가 회수 가능**하다. 볼륨은 380개 중 5개만 쓰는 중이고 19.5GB 가운데 19.4GB가 회수 가능으로 나온다. 일반 계정의 `du`는 Podman 저장소를 다 읽지 못해 `/home`을 약 40GiB 적게 잰다.

[추론] 가장 크게, 가장 안전하게 돌려받을 수 있는 것은 안 쓰는 Podman 이미지(3.1)와 안 쓰는 k3s 이미지(3.2)다. Podman 볼륨은 시험이 남긴 데이터일 수 있어 이미지와 따로 판단한다.
샌드박스의 `findmnt`에는 SSD가 `ro`로 보였다. **호스트 자체가 읽기 전용이라는 판정은 하지 않았다.** 관리자가 호스트 셸에서 같은 명령으로 `rw`·장치·라벨을 다시 확인한다.

### 얼마나 빨리 늘어나나

Grafana의 메트릭 조회에서 다음 질의를 쓴다. 여러 시계열이면 해당 노드·`mountpoint`·`device`를 골라 보고 서로 합하지 않는다.
아래 질의는 **[미확인: 돌려 보지 않음]**. 지표·임계값은 위 경보 규칙, `deriv`는 [Prometheus 공식 함수 문서](https://prometheus.io/docs/prometheus/latest/querying/functions/#deriv)가 근거다.

```promql
# 파일시스템별 가용 비율(%)
100 * node_filesystem_avail_bytes{fstype=~"ext4|xfs|btrfs"}
  / node_filesystem_size_bytes{fstype=~"ext4|xfs|btrfs"}

# 루트 가용 공간(GiB), 최근 10일 그래프로 본다
node_filesystem_avail_bytes{mountpoint="/",fstype="ext4"} / 1024^3

# 최근 10일 회귀선으로 본 일일 가용 공간 감소량(GiB/일). 양수면 차는 중
-deriv(node_filesystem_avail_bytes{mountpoint="/",fstype="ext4"}[10d]) * 86400 / 1024^3

# 경보 발화 여부
ALERTS{alertname="NodeFilesystemAlmostFull",alertstate="firing"}
```

[확인: 지표 저장소 질의, 2026-11-14] 최근 열흘 동안 약 **15GiB/일** 증가했다.
[추론] 같은 속도라면 현재 가용 327GiB에서 10% 여유인 약 91GiB까지 `(327 - 91) / 15`, **약 16일**이다.
예측 기한이 아니다. 최근 24시간과 10일 추세를 함께 보고, 청소·빌드 버스트·지표 누락이 있는 구간은 따로 해석한다.

## 2. 무엇이 디스크를 쓰나

### 시스템 경로: 관리자가 sudo로 한 번 나눠 재기

아래 블록은 전부 **[미확인: 돌려 보지 않음]**, 읽기 전용이다. `du` 옵션은 로컬 도움말, 경로는 아래 저장소 근거와 PV 조회가 근거다.
한 번에 큰 재귀 조회를 여러 개 겹치지 않고 순서대로 실행한다. 첫 줄에서 큰 경로를 찾은 뒤 관련 줄만 이어서 재도 된다.

```sh
sudo du -x -h --max-depth=1 /
sudo du -x -h --max-depth=1 /var
sudo du -x -h --max-depth=1 /var/lib/rancher/k3s
sudo du -x -h --max-depth=1 /var/lib/rancher/k3s/agent/containerd
sudo du -x -h --max-depth=1 /var/lib/rancher/k3s/storage
sudo du -x -h --max-depth=1 /var/lib/kubelet/pods
sudo du -x -h --max-depth=1 /var/log/pods
sudo du -x -h --max-depth=1 /var/crash
sudo du -x -h -s /var/lib/vector /var/lib/taskstate/volume.img
sudo du -x -h --max-depth=1 /var/lib/taskstate/mnt/data
sudo journalctl --disk-usage
```

**k3s containerd 이미지·스냅샷.** [확인] k3s와 containerd의 고정 버전 짝은 [host/versions.env:11](../../host/versions.env#L11), 상태 기본 경로를 바꾸지 않는 설정은 [host/k3s-config.yaml:14](../../host/k3s-config.yaml#L14)다.
기본 이미지 저장소는 `/var/lib/rancher/k3s/agent/containerd` 아래다([K3s 저장 배치](https://docs.k3s.io/reference/resource-profiling), [K3s agent 기본 경로](https://docs.k3s.io/cli/agent)).
위 `du`에서 content·snapshotter 하위 경로를 구분한다. **스냅샷에는 실행 중 컨테이너의 쓰기 계층도 있으므로 디렉터리를 지우지 않는다.** 이 작성 환경에서는 agent 아래 크기를 읽지 못했다.

**파드 임시 저장소·로그.** [확인] kubelet 경로는 [host/lib.sh:47](../../host/lib.sh#L47), 로그는 `/var/log/pods`, Vector 체크포인트는 `/var/lib/vector`다([platform/observability/stack/vector.yaml:83](../../platform/observability/stack/vector.yaml#L83)).
디스크 `emptyDir`는 앱 64MiB, 두 작업자 각각 256MiB이고, 작업자의 `firewall-run` 1MiB는 메모리다([platform/charts/app/templates/deployment.yaml:85](../../platform/charts/app/templates/deployment.yaml#L85), [platform/sandbox/templates/worker-deployment.yaml:135](../../platform/sandbox/templates/worker-deployment.yaml#L135), [platform/sandbox/templates/task-worker-deployment.yaml:133](../../platform/sandbox/templates/task-worker-deployment.yaml#L133)).
[추론] `/var/lib/kubelet/pods` 안에는 PV 마운트도 있으므로 그 합계를 전부 임시 파일로 부르면 안 된다. containerd 쓰기 계층과 파드 로그도 별도 합계다.

**local-path 계열 PV.** [확인] `local-retain`은 `rancher.io/local-path`, `Retain`, `WaitForFirstConsumer`이며 실제 경로는 `/var/lib/rancher/k3s/storage` 아래다.
**PVC 용량을 강제하지 않고 `kubelet_volume_stats`도 없다**([host/k3s-manifests/local-retain.yaml:5](../../host/k3s-manifests/local-retain.yaml#L5)).
2026-11-14의 ConfigMap·PV·PVC 읽기 조회도 이 경로와 모든 PVC의 `Bound`를 확인했다. 실제 PVC와 호스트 경로는 다음처럼 연결한다. UUID가 든 PV 경로를 문서에서 복사해 고정하지 않는다.

[확인] 다음 조회는 실행 성공했다.

```sh
KUBECONFIG=$HOME/.kube/homelab.yaml kubectl get pvc -A
KUBECONFIG=$HOME/.kube/homelab.yaml kubectl get pv -o custom-columns='NAME:.metadata.name,SC:.spec.storageClassName,RECLAIM:.spec.persistentVolumeReclaimPolicy,NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,HOSTPATH:.spec.hostPath.path,LOCAL:.spec.local.path'
KUBECONFIG=$HOME/.kube/homelab.yaml kubectl get configmap local-path-config -n kube-system -o jsonpath='{.data.config\.json}'
```

특정 PVC 크기는 **[미확인: 돌려 보지 않음]** `sudo du -x -h -s '<위 조회의 HOSTPATH 또는 LOCAL 절대 경로>'`로 잰다.
그 밖에 `grafana-data`·`adguard-data`도 같은 루트의 PV다([platform/observability/stack/grafana.yaml:16](../../platform/observability/stack/grafana.yaml#L16), [platform/adguard/templates/pvc.yaml:8](../../platform/adguard/templates/pvc.yaml#L8)).

**VictoriaLogs·vmsingle.** [확인] `observability/victorialogs-data`는 요청량 **10Gi**, 보존 **14d**, 디스크 기반 보존 목표 **8GiB**다([platform/observability/stack/victorialogs.yaml:18](../../platform/observability/stack/victorialogs.yaml#L18), [같은 파일:61](../../platform/observability/stack/victorialogs.yaml#L61)).
`observability/vmsingle-data`는 요청량 **20Gi**, 보존 **30d**다. 배포한 커뮤니티판에는 `retention.maxDiskSpaceUsageBytes`를 넣지 않는다([platform/observability/stack/vmsingle.yaml:49](../../platform/observability/stack/vmsingle.yaml#L49), [같은 파일:91](../../platform/observability/stack/vmsingle.yaml#L91)).
각 PVC의 실제 경로를 위 조회에서 골라 `du`로 잰다. VictoriaLogs의 8GiB도 하드 쿼터가 아니다. 최근 이틀 데이터를 남기는 동작 때문에 초과할 수 있다([공식 보존 문서](https://docs.victoriametrics.com/victorialogs/#retention-by-disk-space-usage)).

**Postgres 데이터·WAL.** [확인] `database/pg-1` 요청량 **20Gi**, `database/pg-1-wal` **5Gi**이며 둘 다 `local-retain`이다.
`archive_timeout: 5min`, `wal_compression: on`, `max_wal_size: 1GB`다([platform/cnpg/cluster/templates/cluster.yaml:28](../../platform/cnpg/cluster/templates/cluster.yaml#L28)).
[추론] 별도 PVC여도 이 NUC에서는 같은 루트 파일시스템을 쓴다. 5Gi·1GB를 디스크 고갈 방지 상한으로 믿으면 안 된다.
`max_wal_size`는 아카이브 실패 등에서 넘을 수 있는 소프트 한도다([PostgreSQL 공식 WAL 설정](https://www.postgresql.org/docs/18/runtime-config-wal.html#GUC-MAX-WAL-SIZE)).
두 PVC를 각각 재고, WAL만 크게 늘면 아카이브·백업 상태 조사로 전환한다. `pg_wal`을 수동 삭제하지 않는다. 복구 절차는 [restore.md](restore.md) 2·3절이다.

**작업 상태 볼륨.** [확인] `sandbox/worker-task-state`는 `/var/lib/taskstate/volume.img` **2GiB 고정 파일**을 loop로 마운트한 `/var/lib/taskstate/mnt/data`다.
`volume.uuid`가 짝이며, `discard`를 쓰지 않는다([host/lib.sh:53](../../host/lib.sh#L53), [host/task-state/var-lib-taskstate-mnt.mount:9](../../host/task-state/var-lib-taskstate-mnt.mount#L9)).
[추론] 안의 완료 작업을 지워도 loop 안 여유만 늘고, 루트에 이미 할당한 2GiB가 바로 줄지는 않는다. 루트 청소 목적으로 이미지 파일·UUID·마운트를 없애지 않는다.
[확인] 진행 중 세션·nonce·receipt가 들어가며, 별도 `sandbox/codex-home` PVC도 nonce와 프로필에 따른 자격을 보존한다([platform/sandbox/templates/task-worker-pvc.yaml:2](../../platform/sandbox/templates/task-worker-pvc.yaml#L2), [platform/sandbox/templates/worker-pvc.yaml:1](../../platform/sandbox/templates/worker-pvc.yaml#L1)).

**journald·kdump.** [확인] journald 목표는 persistent **512MiB**, 루트에 남기는 공간 **1GiB**, runtime **64MiB**다([host/etc/systemd/journald.conf.d/10-k3s-node.conf:5](../../host/etc/systemd/journald.conf.d/10-k3s-node.conf#L5)).
커널 크래시 덤프는 `/var/crash`에 있고, 2026-11-06 크래시 원인은 미확정이라고 기록돼 있다([nuc-kernel-pin.md:51](nuc-kernel-pin.md#L51)).
위의 `du`는 할당 공간이다. 덤프 파일의 표시 크기만 보고 그만큼 회수된다고 계산하지 않는다.

### 홈 폴더: 관리자 계정으로 재기

**rootless Podman.** [확인] 저장소 복원 시험에서도 Podman을 쓴다([restore.md:1182](restore.md#L1182)).
호스트 기본 rootless 저장소는 `~/.local/share/containers/storage`다([Podman 공식 저장 경로](https://docs.podman.io/en/latest/markdown/podman.1.html)). root의 Podman·k3s containerd와 다르다.

아래 세 조회는 **실행을 시도했지만 실패**했다. 샌드박스의 `/run/user/…/libpod`가 읽기 전용이라 Podman 초기화가 막혔다.
관리자가 일반 호스트 셸에서 같은 계정으로 다시 실행한다. sudo로 바꾸면 다른 저장소를 보므로 해결책이 아니다.

```sh
podman system df
podman images --format '{{.ID}} {{.Size}}'
podman ps -a --format '{{.ID}} {{.Status}}'
```

이미지 이름까지 대조할 때는 **[미확인: 돌려 보지 않음]** `podman images`, `podman ps -a`를 쓴다.
문법은 로컬 Podman 매뉴얼과 [system df](https://docs.podman.io/en/stable/markdown/podman-system-df.1.html)에서 확인했다. 공유 레이어 때문에 `RECLAIMABLE`은 실제 회수량보다 클 수 있다.

**worktree·빌드 산출물·패키지 캐시.** [확인] 이 저장소의 재생성 대상은 `cli/dist/`와 `node_modules/`다([.gitignore:37](../../.gitignore#L37), [cli/build.ts:2](../../cli/build.ts#L2)).
CI Terraform 플러그인 캐시 기본값은 `~/.cache/homelab-ci/terraform-plugins`이며 환경변수로 바꿀 수 있다([tools/ci/main.ts:600](../../tools/ci/main.ts#L600)). Bun 캐시 경로 조회 `bun pm cache`는 실행 성공했고 기본 경로였다.
개인 작업 폴더의 빌드 구조·삭제 가능 여부는 이 저장소가 정하지 않는다.

다음 형태의 `du`는 직접 실행했다. 홈 전체는 시간 초과, Podman은 일부 권한 오류, 나머지는 성공했다. 서로 겹치는 부모·자식 합계를 더하지 않는다.

```sh
du -sx --block-size=1 "$HOME"
du -sx --block-size=1 "$HOME/.local/share/containers"
du -sx --block-size=1 "$HOME/.cache"
du -sx --block-size=1 "$HOME/.bun/install/cache"
du -sx --block-size=1 "$HOME/.npm"
du -sx --block-size=1 "$HOME/.codex/sessions"
du -sx --block-size=1 "$HOME/.claude/projects"
bun pm cache
```

관리자가 특정 작업 폴더 하나를 고른 뒤 크기만 재는 명령은 **[미확인: 돌려 보지 않음]** `du -x -h -s "$HOME/<작업 폴더>"`다.
빌드·의존성만 따로 재려면 **[미확인: 돌려 보지 않음]** `du -x -h -s "$HOME/<작업 사본>/cli/dist" "$HOME/<작업 사본>/node_modules"`를 쓴다. 문법은 로컬 `du --help`, 경로는 위 `.gitignore`·빌드 코드가 근거다. 경로를 자동으로 찾아 일괄 삭제하지 않는다.

**에이전트 CLI 세션 기록.** [확인] 위 두 세션 경로는 이 머신에서 크기만 읽었다. 저장소는 개인 `~/.claude*`·`~/.codex*`를 봇 자격과 섞지 않는다고 정한다([rotate.md:208](rotate.md#L208), [../plans/2026-10-17-homelab-rebuild/spec.md:550](../plans/2026-10-17-homelab-rebuild/spec.md#L550)).
개인 CLI의 세션 보존 기간은 이 저장소에서 관리하지 않는다. 기록은 캐시와 달리 대화·재개·조사 근거일 수 있으므로 마지막 관리자 판단 항목이다. 디렉터리 전체나 자격·설정 파일을 일괄 삭제하지 않는다.

## 3. 청소 순서

[추론] **재생성 가능한 빌드 산출물·Podman → 미사용 k3s 이미지 → 완료 worktree·패키지 캐시 → 조사 완료 덤프 → journald → 관측 보존 PR → 개인 자료·세션** 순서로 한다.
홈 작업 자료가 가장 크고 덤프·journal은 각각 약 1.4GiB·0.5GiB이므로, 조사 증거를 잃기 전에 재생성 대상을 확인하는 편이 낫다.
각 단계 뒤 `df -hT / /mnt/bulk`로 실제 회수량을 보고, 필요한 여유를 확보하면 다음 삭제는 멈춘다. 실행 시각·대상 종류·전후 용량·관리자 승인은 승인 기록에 남기되 개인 경로는 쓰지 않는다.

### 3.1 빌드 산출물과 안 쓰는 Podman 이미지

1. **지울 것:** 끝난 빌드의 재생성 산출물, 필요 없는 dangling 이미지, 선택적으로 미사용 이미지와 빌드 캐시.
2. **먼저 확인:** 빌드·시험·컨테이너 작업이 모두 끝났는지, 소스·lockfile과 재다운로드 경로가 있는지, 로컬에만 있는 이미지나 롤백용 이미지가 없는지 본다. `podman system df`와 `images`·`ps -a` 결과를 대조한다.
3. **명령:** 아래는 전부 **[미확인: 돌려 보지 않음]**. Podman은 [image prune 공식 문서](https://docs.podman.io/en/stable/markdown/podman-image-prune.1.html)와 설치된 매뉴얼의 옵션을 확인했다. `rm`은 [공식 문서](https://www.gnu.org/software/coreutils/manual/html_node/rm-invocation.html)와 로컬 `rm --help`가 근거다.

   ```sh
   # 아래 경로는 관리자가 재생성 가능함을 확인한 이 저장소 사본의 cli/dist만 지정한다.
   rm -rI -- "$HOME/<작업 사본>/cli/dist"
   podman image prune
   # 위 단계로 부족하고 모든 미사용 이미지가 재생성 가능할 때만 선택한다.
   podman image prune --all
   # 실행 중 빌드가 없고 cache mount 내용도 버려도 될 때만 선택한다.
   podman image prune --build-cache
   ```

4. **되돌리기:** 삭제 취소는 없다. 캐시는 다시 만들고 이미지는 다시 받거나 빌드한다. 그동안 네트워크·빌드 시간이 필요하다. `--all`은 생성한 지 오래되지 않은 미사용 이미지도 지운다.
5. **지우지 않을 것:** 컨테이너·볼륨·bind mount 데이터, 실행 중 빌드, 재현할 수 없는 로컬 이미지. `podman system prune --volumes`, `podman system reset`, `--external`로 범위를 넓히거나 저장소 디렉터리를 직접 지우지 않는다. `--build-cache`는 일반 dangling 이미지 정리도 포함한다.

### 3.2 안 쓰는 k3s 이미지

1. **지울 것:** CRI가 미사용으로 판단한 이미지. containerd 디렉터리 삭제가 아니다.
2. **먼저 확인:** 2절의 containerd `du`로 큰지 보고 배포·롤백·파드 시작이 진행 중이면 미룬다. 운영과 예정 배포의 digest를 다시 받을 수 있어야 한다. replicas 0인 서비스의 이미지도 미사용일 수 있다.
3. **명령:** 아래는 전부 **[미확인: 돌려 보지 않음]**. [K3s 내장 CLI](https://docs.k3s.io/cli), [cri-tools 명령 문서](https://github.com/kubernetes-sigs/cri-tools/blob/master/docs/crictl.md), [`rmi --prune` 구현](https://github.com/kubernetes-sigs/cri-tools/blob/master/cmd/crictl/image.go)이 근거다. 읽기 조회를 먼저 하고 관리자가 마지막 줄만 별도로 실행한다.

   ```sh
   sudo k3s crictl images
   sudo k3s crictl ps -a
   sudo k3s crictl rmi --help
   sudo k3s crictl rmi --prune
   ```

4. **되돌리기:** 삭제 취소는 없다. 필요한 이미지를 다음 시작 때 다시 받으며 레지스트리 장애·네트워크 단절이면 시작·롤백이 늦거나 실패한다. `--prune`에는 삭제 대상만 미리 보여 주는 dry-run이 없으므로 `images`를 후보 목록으로 오해하지 않는다.
5. **지우지 않을 것:** 실행 중 컨테이너·스냅샷·content 파일, PV, k3s 서버 데이터. `rmi --all`이나 `ctr`로 강제 삭제하지 않는다. 회수가 작다고 snapshotter 폴더를 지우지 않는다.

[확인] Kubernetes는 kubelet의 이미지 GC 사용을 권장하고 외부 청소 도구와의 충돌을 경고한다([공식 GC 문서](https://kubernetes.io/docs/concepts/architecture/garbage-collection/#garbage-collection-of-unused-containers-and-images)).
[추론] 위 prune은 관리자 확인을 거친 일회성 공간 확보로만 쓰고 cron으로 반복하지 않는다. 반복 문제는 7절의 kubelet 설정으로 다룬다.

### 3.3 끝난 worktree와 패키지 캐시

1. **지울 것:** 종료한 linked worktree, 다시 받을 수 있는 패키지 캐시. 홈의 개인 작업 폴더 전체가 대상은 아니다.
2. **먼저 확인:** 관리자와 에이전트의 진행 중 작업·터미널·빌드가 없는지, 로컬 커밋·미추적 파일·ignored 파일·복구 자료를 보존했는지 확인한다. `.gitignore`는 버려도 된다는 목록이 아니다. `.env`·state·키도 무시되기 때문이다([확인] [.gitignore:1](../../.gitignore#L1)).
3. **명령:** 아래 worktree 명령은 전부 **[미확인: 돌려 보지 않음]**, 공식 [Git worktree](https://git-scm.com/docs/git-worktree)·[git status](https://git-scm.com/docs/git-status)·[git log](https://git-scm.com/docs/git-log) 문서가 근거다. 관리자만 개인 사본에서 실행하고 출력은 공개하지 않는다.

   ```sh
   git -C "$HOME/<저장소 사본>" worktree list
   git -C "$HOME/<완료 worktree>" status --short --untracked-files=all --ignored
   git -C "$HOME/<완료 worktree>" log --oneline HEAD --not --remotes
   git -C "$HOME/<저장소 사본>" worktree remove "$HOME/<완료 worktree>"
   ```

   원격 추적 참조가 오래됐으면 로그 결과만으로 보존됐다고 판정하지 않는다. 원격의 실제 커밋도 대조한다.
   `worktree remove`가 거부하면 `--force`로 넘어가지 않는다. ignored 파일도 삭제될 수 있으므로 앞 단계에서 별도로 보존한다.
   `git worktree prune`은 이미 없는 worktree의 등록 정보 정리이며, 남아 있는 큰 작업 폴더를 지우는 명령이 아니다.

   Bun 캐시 삭제는 **[미확인: 돌려 보지 않음]** `bun pm cache rm`이다([Bun 공식 문서](https://bun.sh/docs/pm/cli/pm#cache)). 먼저 실행 확인된 `bun pm cache`로 대상을 본다.
   **`globalStore = true`로 캐시를 참조하는 프로젝트는 링크가 끊겨 다시 설치해야 한다.** 그런 프로젝트를 확인하지 못했으면 이 단계는 건너뛴다. 하드링크로 남아 있는 패키지는 캐시를 지워도 공간이 바로 회수되지 않을 수 있다([Bun 캐시 설명](https://bun.sh/docs/pm/global-cache)).
   `~/.npm`은 크기만 확인했고 이 저장소는 Bun을 사용하므로 npm 전체 삭제 명령을 제시하지 않는다. Terraform 캐시도 실행 중인 plan·apply·CI와의 공유 여부를 확인한 뒤 별도 판단한다.

4. **되돌리기:** worktree의 파일 삭제는 취소할 수 없다. 보존된 커밋으로 사본을 만들 수 있어도 미추적·ignored 파일은 돌아오지 않는다. 패키지는 재다운로드가 가능할 때만 재생성할 수 있다.
5. **지우지 않을 것:** 주 작업 사본, 진행 중·잠긴 worktree, `.git`, lockfile, 자격·state·로컬 런북, 복구 자산. 무차별 `git clean -fdx`를 쓰지 않는다.

### 3.4 조사가 끝난 커널 덤프

1. **지울 것:** 관리자가 조사를 종료했고 필요한 사본을 NUC 밖에 확인한 특정 덤프 디렉터리 하나.
2. **먼저 확인:** 날짜가 오래됐다는 이유만으로 종료됐다고 판단하지 않는다. [확인] [nuc-kernel-pin.md:51](nuc-kernel-pin.md#L51)의 원인 미확정 크래시는 기본 보존 대상이다. 다른 날짜 덤프도 관리자가 조사 상태를 확인한다.
3. **명령:** 조회 `ls -l /var/crash`, `du -x -h --max-depth=1 /var/crash`는 실행 성공했다. 삭제는 **[미확인: 돌려 보지 않음]**, [GNU rm](https://www.gnu.org/software/coreutils/manual/html_node/rm-invocation.html)이 근거다.

   ```sh
   sudo rm -rI -- '/var/crash/<조사가 끝난 덤프 디렉터리>'
   ```

4. **되돌리기:** 다른 사본이 없으면 조사 원본을 잃는다. 덤프에는 메모리의 민감한 내용이 있을 수 있으므로 공개 저장소·공개 이슈에 보관하지 않는다.
5. **지우지 않을 것:** `/var/crash` 전체, 진행 중 조사 덤프, 날짜가 같은 주변 보고서·설정의 일괄 glob. 청소를 위해 kdump를 끄거나 고정 커널을 제거하지 않는다.

### 3.5 journald

1. **지울 것:** 오래된 archived journal. 현재 측정은 약 496MiB라 이 단계의 회수 효과는 작다.
2. **먼저 확인:** 장애 조사에 필요한 시간대의 로그를 별도 비공개 위치에 보존했는지 보고, 관리자 권한의 `journalctl --disk-usage`로 전체를 다시 잰다. 이미 설정 상한 근처라면 건너뛰어도 된다.
3. **명령:** **[미확인: 돌려 보지 않음]**. 256MiB는 이 런북의 일회성 축소 예시이며 영구 설정을 바꾸지 않는다. [systemd journalctl 문서](https://www.freedesktop.org/software/systemd/man/latest/journalctl.html#--vacuum-size=)가 근거다.

   ```sh
   sudo journalctl --rotate --vacuum-size=256M
   ```

4. **되돌리기:** 지워진 로그는 사본이 없으면 복구할 수 없다. vacuum은 archived 파일에 적용되며 `--rotate`가 활성 파일을 먼저 회전한다. 실제 합계가 목표와 정확히 같다고 기대하지 않는다.
5. **지우지 않을 것:** `/var/log/journal` 자체, 파드 로그 파일, 조사 중인 시간대 로그. `rm`·`truncate`로 활성 로그를 비우지 않는다. journald 축소는 `/var/log/pods`나 VictoriaLogs 데이터를 줄이지 않는다.

### 3.6 관측 데이터 보존 기간 줄이기: 저장소 PR

1. **지울 것:** 새 보존 기간 밖의 로그·메트릭. PV 파일을 직접 지우지 않고 각 서비스의 보존 처리를 이용한다.
2. **먼저 확인:** 해당 PVC가 실제로 큰지, 조사·추세 비교에 필요한 기간, 아직 백필하지 않은 데이터가 있는지 확인한다. 관리자와 기간을 정한다.
3. **변경:** **[미확인: 돌려 보지 않음]** 아래는 PR의 설정 변경 예시이며 승인된 목표값이 아니다. 2절의 매니페스트가 변경 자리다.

   ```yaml
   # platform/observability/stack/victorialogs.yaml의 args 중 해당 항목
   - -retentionPeriod=7d
   # platform/observability/stack/vmsingle.yaml의 args 중 해당 항목
   - -retentionPeriod=14d
   ```

   검토·승인·병합 뒤 Argo CD가 적용한다. 라이브 `kubectl edit`로 먼저 바꾸지 않는다.
   VictoriaLogs의 8GiB 보존 목표 조정도 가능하지만 최근 이틀 예외가 있다. vmsingle의 PVC 요청량을 줄여도 디스크 상한이 생기지 않는다.
4. **되돌리기:** 설정은 PR로 되돌릴 수 있지만 이미 삭제된 데이터는 돌아오지 않는다. 보존 축소가 즉시 공간 회수를 보장하지 않는다. vmsingle은 월별 파티션과 백그라운드 병합에 따라 삭제된다([공식 보존 문서](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#retention)).
5. **지우지 않을 것:** PVC·PV·스토리지 디렉터리. 공간이 모자란 상태에서 강제 병합을 청소 수단으로 쓰지 않는다. 추가 디스크·I/O가 필요할 수 있다([공식 강제 병합 설명](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#forced-merge)).

### 3.7 개인 자료와 CLI 세션: 관리자 판단

1. **지울 것:** 관리자가 보존 불필요를 확인한 개인 자료·종료 세션 파일만. 빌드 캐시로 취급하지 않는다.
2. **먼저 확인:** 재개할 세션·작업 인계·조사 증거·원격 없는 소스인지 보고, 필요한 자료는 NUC 밖 사본을 확인한다. 개인 폴더 내용은 관리자만 검토한다.
3. **명령:** **[미확인: 돌려 보지 않음]** `rm -i -- "$HOME/<관리자가 확인한 불필요 파일>"`. [GNU rm](https://www.gnu.org/software/coreutils/manual/html_node/rm-invocation.html)의 파일 하나 삭제만 제시한다. 세션 저장소가 인덱스·DB와 연결돼 있으면 CLI가 제공하는 정리 절차를 먼저 확인하고 수동 삭제를 보류한다.
4. **되돌리기:** 사본이 없으면 기록·대화·재개 가능성을 잃는다. 설정만 복구해도 세션 내용은 돌아오지 않는다.
5. **지우지 않을 것:** `~/.codex`·`~/.claude` 전체, 자격 파일·설정·진행 중 세션, 복구 자산·백업. 파일 이름·나이만으로 자동 삭제하지 않는다.

## 4. 두 번째 SSD로 옮기는 선택

[확인] `/mnt/bulk`는 `LABEL=bulk-ssd`, ext4, **`nofail,nodev,nosuid,noexec`**로 관리한다.
SSD가 없어도 부팅은 계속되므로, 마운트되지 않은 같은 경로에 쓰면 **루트 디스크를 다시 채운다**([host/lib.sh:345](../../host/lib.sh#L345)).
설치기는 루트 쪽 마운트 지점의 잔여물을 발견하면 가리지 않고 멈춘다([host/install.sh:825](../../host/install.sh#L825), [restore.md:2027](restore.md#L2027)).

[추론] 현재 옵션에 맞는 첫 후보는 **종료한 작업의 보관 사본·실행하지 않는 큰 자료**다.
worktree의 빌드 산출물·패키지 실행 파일·Podman 저장소를 그대로 옮기면 `noexec` 때문에 실행이 깨질 수 있다.
삭제 원장 전용으로 정한 사용 범위를 넓히는 일이므로 관리자가 결정하고, 마운트 옵션을 몰래 바꾸지 않는다([확인] [../plans/2026-10-17-homelab-rebuild/spec.md:182](../plans/2026-10-17-homelab-rebuild/spec.md#L182)).

1. 관리자 호스트 셸에서 1절의 `findmnt --mountpoint /mnt/bulk`를 실행한다. **한 개의 실제 SSD, ext4, `rw`, 라벨 `bulk-ssd`**를 확인한다. `df /mnt/bulk`나 `findmnt -T`만으로는 SSD 마운트를 증명하지 못한다. 라벨·장치를 읽지 못하면 멈춘다([확인] [host/lib.sh:359](../../host/lib.sh#L359)).
2. 대상은 `/mnt/bulk/<별도 보관 영역>`처럼 **삭제 원장과 다른 디렉터리**로 정한다. `/mnt/bulk/homelab-bot/deletion-ledger` 안에는 원장 두 파일 외의 자료를 넣지 않는다. SSD의 여유도 계속 관찰한다.
3. 쓰는 프로세스를 종료하고 원본 크기·소유·권한·심링크·하드링크·희소 파일 보존 요구를 확인한다. 먼저 복사하고 파일 수·내용·권한을 검증한 다음 원본 삭제를 별도로 결정한다. 이 문서는 범용 `mv`·`rsync --delete` 명령을 제공하지 않는다. 자료마다 복사 조건과 중단 방법이 달라 실행 계약을 따로 정한다.
4. 이후 계속 쓰는 서비스라면 시작할 때 마운트 원본을 검증하고, SSD가 빠지면 **실패하며 멈추도록** 만든다. 단순 심링크·자동 디렉터리 생성은 이 조건을 대신하지 못한다. 시작 전 검사만으로 실행 중 SSD 장애까지 막지는 못한다.
5. k3s data-dir·containerd·PV·Postgres·Podman graphroot 이관은 이 청소 절차에서 수행하지 않는다. 서비스 정지, 백업 검증, 런타임 경로 설정, PV 매핑, UID·권한, 부팅 순서, 복귀 시험을 포함한 별도 변경으로 다룬다. PVC의 크기나 provisioner 기본 경로를 바꿔도 기존 데이터가 이동하지 않는다.

같은 NUC의 두 번째 SSD는 NUC 전체 유실에 대비한 백업이 아니다. 삭제 원장은 DB 백업보다 최신이어야 하고, SSD를 잃으면 지운 기억이 복구 DB에서 되살아날 수 있다([확인] [restore.md:1075](restore.md#L1075), [restore.md:2042](restore.md#L2042)).

## 5. 지우면 안 되는 것

- **PV와 DB:** `/var/lib/rancher/k3s/storage`, PV 조회에 나온 `hostPath`·`local.path`, PGDATA·WAL. `Released` PV도 삭제 승인이라는 뜻이 아니다. `Retain`은 PVC 삭제 뒤 보존하라는 정책이다([확인] [host/k3s-manifests/local-retain.yaml:5](../../host/k3s-manifests/local-retain.yaml#L5)). `k3s-uninstall.sh`는 청소 명령이 아니며 이 경로도 지운다([같은 파일:14](../../host/k3s-manifests/local-retain.yaml#L14)).
- **삭제 원장:** `/mnt/bulk/homelab-bot/deletion-ledger`, `deletions.jsonl`, `ledger.json`, 해당 PV·PVC. 원장은 일반 앱 데이터 purge에도 넣지 않는다([확인] [data/homelab-bot/values.yaml:4](../../data/homelab-bot/values.yaml#L4), [restore.md:2011](restore.md#L2011)). 빈 원장 생성·과거 사본 덮어쓰기로 청소하지 않는다.
- **작업 상태와 수집 위치:** `/var/lib/taskstate/volume.img`·`volume.uuid`, 진행 중 작업·nonce·receipt, `codex-home`, `/var/lib/vector`. 작업 상태는 재개에, Vector 체크포인트는 로그 재수집 방지에 필요하다([확인] [platform/sandbox/templates/task-worker-pvc.yaml:2](../../platform/sandbox/templates/task-worker-pvc.yaml#L2), [platform/observability/stack/vector.yaml:96](../../platform/observability/stack/vector.yaml#L96)).
- **백업·복구 자산:** 로컬 런북·키·Terraform state·Infisical 암호화 내보내기·마지막 정상 사본. 보관 규칙은 [recovery-assets.md:5](recovery-assets.md#L5), [같은 파일:36](recovery-assets.md#L36)이다. [확인] R2 백업 보존 `14d`는 원격 base backup·WAL의 정책이다([platform/cnpg/cluster/templates/objectstore.yaml:14](../../platform/cnpg/cluster/templates/objectstore.yaml#L14)). 이를 줄여도 루트 디스크는 비워지지 않는다.
- **조사 원본·고정 커널:** 원인 미확정 덤프·필요한 journal, 부팅에 쓰는 고정 커널. [확인] 커널과 덤프의 보존 이유는 [nuc-kernel-pin.md:41](nuc-kernel-pin.md#L41)이다. 디스크 청소에 무조건적인 커널 자동 제거를 끼워 넣지 않는다.

## 6. 끝난 뒤 확인

1. **공간:** 1절의 `df`·`df -i`를 다시 실행해 대상 파일시스템의 전후 수치를 남긴다. [추론] 이번 대응의 목표는 10% 경보선만 넘기는 것보다 여유를 두는 것이다. 우선 **20% 이상 가용**을 권장하되 일일 증가량을 줄이지 못하면 청소 완료로 끝내지 않는다. 이는 새 경보 임계값이 아니라 운영 판단이다.
2. **경보:** 1절의 `ALERTS`와 가용 비율을 다시 본다. firing이 없어도 node-exporter 수집이 끊겼다면 해소 증거가 아니다. **[미확인: 돌려 보지 않음]** `up{job="node-exporter"}`가 1이고 파일시스템 지표가 최신인지 함께 본다(수집 누락 경보 근거: [platform/observability/stack/vmalert/rules/core.yaml:35](../../platform/observability/stack/vmalert/rules/core.yaml#L35)).
3. **클러스터:** 아래 읽기 명령은 작성 시 실행 성공했다. 청소 뒤 관리자가 다시 확인한다.

   ```sh
   KUBECONFIG=$HOME/.kube/homelab.yaml kubectl get nodes -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,DISKPRESSURE:.status.conditions[?(@.type=="DiskPressure")].status'
   KUBECONFIG=$HOME/.kube/homelab.yaml kubectl get pods -A
   KUBECONFIG=$HOME/.kube/homelab.yaml kubectl get pvc -A
   KUBECONFIG=$HOME/.kube/homelab.yaml kubectl get cluster -n database pg -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.readyInstances'
   KUBECONFIG=$HOME/.kube/homelab.yaml kubectl get applications -A -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
   ```

   기대값은 노드 Ready·DiskPressure False, 필요한 파드 Ready, PVC Bound, PG healthy, 적용한 Argo CD App Synced·Healthy다. 새 Pending·Evicted·CrashLoopBackOff·ImagePullBackOff가 없는지 본다.
   **2026-11-14 측정:** 위 조건은 정상이고, 게시 서버·두 작업자는 의도적으로 replicas 0이었다. 없는 파드를 청소 장애로 오인해 켜지 않는다([확인] [apps/homelab-bot/values.yaml:5](../../apps/homelab-bot/values.yaml#L5), [platform/sandbox/values.yaml:66](../../platform/sandbox/values.yaml#L66), [같은 파일:144](../../platform/sandbox/values.yaml#L144)).
4. **추세:** 다음 24시간·며칠 뒤 같은 경로 크기와 일일 증가량을 비교한다. 삭제했는데 `df`가 줄지 않으면 열린 삭제 파일·하드링크·다른 파일시스템을 먼저 조사한다. 재부팅이나 PV 삭제로 해결하려 하지 않는다.

## 7. 다시 차지 않게

### 저장소 PR로 정할 것

- **관측 보존:** `victorialogs.yaml`의 14d·8GiB, `vmsingle.yaml`의 30d를 실제 증가량과 필요한 조회 기간에 맞춘다. 로그를 과다 생성하는 앱·수집 범위도 함께 본다. 이 경로는 병합 뒤 Argo CD가 적용한다. 3.6의 데이터 유실 조건을 PR에 적는다.
- **kubelet 이미지 GC·로그 회전:** [확인] 현재 [host/k3s-config.yaml:25](../../host/k3s-config.yaml#L25)에는 reserved·eviction만 명시돼 있고 이미지 GC·컨테이너 로그 회전의 별도 값은 없다. 기본값을 라이브 실측값이라고 쓰지 않는다. [추론] `imageGCHighThresholdPercent`·`imageGCLowThresholdPercent`, 필요하면 `imageMaximumGCAge`, `containerLogMaxSize`·`containerLogMaxFiles`를 검토한다([KubeletConfiguration 공식 필드](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/), [K3s 설정 방법](https://docs.k3s.io/installation/configuration#kubelet-configuration-files)). `host/`의 설정·설치·검증을 함께 바꾸는 PR이며 **병합만으로 호스트에 적용되지 않는다.** 사용 중 이미지·홈 데이터는 이미지 GC가 줄이지 못한다.
- **호스트 journal 목표:** [host/etc/systemd/journald.conf.d/10-k3s-node.conf:5](../../host/etc/systemd/journald.conf.d/10-k3s-node.conf#L5)의 512MiB가 이미 작다. [추론] 이번 측정에서는 우선 축소 대상이 아니다. 바꾸면 호스트 적용 단계도 필요하다.
- **추세 경보·임시 저장소:** [추론] 10% 도달 전에 증가 속도로 알리는 규칙을 `vmalert/rules/core.yaml`에 추가할 수 있다. 재시작·빌드·수집 누락 반례와 `vmalert/tests/core.test.yaml`의 시험을 함께 둔다. 파드 임시 쓰기가 원인이면 위 `emptyDir`와 앱의 `ephemeral-storage` 요청·제한을 검토한다. PVC 요청량 축소로 대체하지 않는다.

### 호스트에서 관리자가 적용·관리할 것

- **호스트 설정 적용:** PR을 검토한 뒤 관리자가 적용한다. k3s 설정 반영은 **[미확인: 돌려 보지 않음]** `sudo host/install.sh --cluster prod --k3s`이며 k3s 재시작 가능성을 고려한다([확인] [bootstrap.md:125](bootstrap.md#L125)). journal 변경을 포함한 호스트 설정은 **[미확인: 돌려 보지 않음]** `sudo host/install.sh --cluster prod --host-config`다. 이 단계는 journal 외 설정도 적용하고 네트워크가 약 2초 끊길 수 있어 단순 journal 청소용으로 실행하지 않는다([확인] [bootstrap.md:118](bootstrap.md#L118), [host/install.sh:181](../../host/install.sh#L181)).
- **개인 작업 수명:** 작업 종료 때 worktree·빌드 산출물의 보존 여부를 정하고, Podman·패키지·CLI 기록 크기를 주기적으로 비교한다. 자동 삭제를 붙이기 전에 진행 중 작업·유일 사본·세션 보존 예외를 정한다. 개인 도구의 저장 경로와 보존 설정은 이 저장소의 Argo CD가 관리하지 않는다.
- **덤프·SSD:** kdump는 조사 종료·사본 확인 후 선별 정리한다. 자동 보존 정책은 현재 저장소에 없으므로 실제 호스트 설정을 먼저 확인한다. SSD 사용 범위·마운트 의존성·중단 시 동작은 4절 조건을 충족하는 별도 변경으로 관리한다.
- **원인 확정:** 시스템 sudo 측정으로 가장 큰 경로를 찾고, 같은 명령의 다음 측정과 차이를 비교한다. 데이터·WAL이 원인이면 백업·아카이브·앱 쓰기를 고치고, 캐시 정리만 주기적으로 반복하지 않는다.
