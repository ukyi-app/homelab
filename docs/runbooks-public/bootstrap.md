# 부트스트랩: 빈 호스트에서 k3s와 Argo CD까지

새 호스트(또는 k3s를 지운 호스트)에 클러스터를 세우는 순서다. 운영 NUC는 2026-10-19 T07에서 이 순서로 세웠다. 시나리오 13(VM에서 다시 세우기)의 입력이기도 하다. 근거는 설계 [C.3.2](../plans/2026-10-17-homelab-rebuild/platform/design.md)(호스트·k3s)와 C.3.3(Argo CD)이다.

이 문서 밖의 수동 단계를 두지 않는다. 실행하다 문서와 다르게 한 것이 있으면 이 문서를 먼저 고친다.

## 0. 클러스터 이름 고르기

| 클러스터 | 이름 | 호스트 값 | 클러스터 값 | root 파일 |
|---|---|---|---|---|
| 운영 NUC | `prod` | `host/clusters/prod.env` | `platform/root/values-prod.yaml` | `platform/root/root-prod.yaml` |
| 시나리오 13 VM | `vm` | `host/clusters/vm.env` | `platform/root/values-vm.yaml` | `platform/root/root-vm.yaml` |

아래 `<이름>`은 이 이름 하나다. 스크립트와 매니페스트에는 클러스터 이름 분기가 없고, 값 파일만 바뀐다.

- VM은 NUC 안의 임시 KVM VM이다(사용자 2026-10-26). 만들기·지우기와 `vm.env` 값의 근거는 [vm.md](vm.md)다. env 파일에 `CHANGE_ME`가 남아 있으면 host 스크립트가 멈춘다.
- `values-vm.yaml`은 ci가 VM 프로필로 단언한다(`platform/root/templates/cluster-check.yaml`): 접두 `vm-`, Infisical `homelab-dev`/`dev`, 버킷과 serverName이 운영과 다름. 하나라도 어긋나면 root-vm 렌더가 실패해 ci와 Argo CD sync가 멈춘다. 복구 원본(`recoverySource`)은 [restore.md](restore.md) 3절의 VM 복구 PR이 넣는다. 그 PR이 main에 병합되기 전에는 `root-vm.yaml`을 apply하지 않는다.
- VM 호스트는 tailnet에 넣지 않는다(`TAILNET_JOIN=false`). VM은 libvirt NAT 뒤라 NUC에서만 닿는다. 접근은 NUC에서 `vm.env`의 노드 IP(SSH)나 `virsh console`로 한다.

### 0.0 작업 사본과 필요한 패키지

이 문서의 여러 줄짜리 명령은 모두 한 단계라도 실패하면 멈추게 적는다. 대화형 셸에 줄을 붙여 넣으면 앞 명령이 실패해도 다음 줄이 돌기 때문이다. 그래서 `&&`로 잇거나 `set -euo pipefail`을 건 별도 bash(`bash -euo pipefail <<'EOF'`)로 돌린다. 블록이 실패하면 다음 블록으로 가지 않는다.

새로 설치한 호스트에는 스크립트가 쓰는 도구를 먼저 깔고, 작업 사본이 없으면 만든다(Ubuntu 26.04 기준). `openssh-server`는 `host/install.sh --host-config`가 sshd 설정을 검사(`sshd -t`)하는 데 필요하고, `nftables`(`nft`)는 `--egress`가 파드 egress 규칙을 올리는 데, `bind9-dnsutils`(`dig`)는 `--k3s`를 다시 돌려 재시작한 뒤 클러스터 DNS를 확인하는 데 필요하다. 최소 설치나 VM에는 없을 수 있다.

```bash
sudo apt-get update \
  && sudo apt-get install -y git jq curl gnupg openssh-server nftables bind9-dnsutils \
  && { [ -d ~/homelab/.git ] || git clone https://github.com/ukyi-app/homelab ~/homelab; } \
  && cd ~/homelab
```

작업 사본이 최신 `main`과 같아야 한다. 오래된 사본으로 시작하면 호스트·k3s는 옛 값으로, Argo CD는 최신 main으로 깔려 두 층의 revision이 어긋난다. 스크립트는 `host/`에 커밋 안 한 변경이 없는지만 보고 `origin/main`과는 비교하지 않으므로, 아래로 직접 확인한다. fetch가 실패하면 예전에 받아 둔 `origin/main`과 비교하게 되므로, 실패하면 여기서 멈춘다. 이 문서의 명령은 모두 이 저장소 루트에서 한다.

```bash
bash -euo pipefail <<'EOF'
git fetch --no-tags origin main
git switch main
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
git diff --quiet origin/main
echo "main과 같음"
EOF
```

### 0.1 운영 NUC를 OS부터 다시 설치했을 때만

tailnet에 이미 있으면 건너뛴다.

1. Tailscale 콘솔에서 옛 NUC 기기를 먼저 지운다. 남아 있으면 새 이름에 `-1`이 붙고, 나중에 지워도 이름이 돌아오지 않는다.
2. Tailscale을 서명된 apt 저장소에서 깔고 등록한다. 설치 스크립트를 `curl | sh`로 돌리지 않는다. 배포 경로가 침해되면 그 스크립트가 root로 무엇이든 실행하고, 이어서 sudo로 도는 `host/install.sh`까지 바꿀 수 있기 때문이다. 대신 저장소 서명 키를 지문으로 확인하고, 패키지는 그 키로 서명된 저장소에서만 받는다.

   ```bash
   bash -euo pipefail <<'EOF'
   codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"   # 26.04는 resolute
   key="$(mktemp)"
   curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" -o "$key"
   # signed-by에 키링 파일을 주면 APT는 그 안의 모든 키를 서명자로 믿는다. 그래서 첫 키만 보지 않고,
   # 기본 키가 정확히 하나이고 그 지문이 Tailscale 저장소 서명 키(2026-10-19 확인, 운영 NUC 설치본과 같음)인지 본다
   pubs="$(gpg --show-keys --with-colons "$key" | awk -F: '/^pub/ { n++ } END { print n + 0 }')"
   fpr="$(gpg --show-keys --with-colons "$key" | awk -F: '/^pub/ { getline; print $10; exit }')"
   test "$pubs" = 1 && test "$fpr" = 2596A99EAAB33821893C0A79458CA832957F5868 \
     || { echo "키링이 예상과 다르다: 기본 키 ${pubs}개, 첫 지문 ${fpr}"; exit 1; }
   sudo install -m 0644 "$key" /usr/share/keyrings/tailscale-archive-keyring.gpg
   echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu ${codename} main" \
     | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
   sudo apt-get update
   sudo apt-get install -y tailscale
   # 공유기 경로를 넘기려면 IP 포워딩이 재부팅 뒤에도 켜져 있어야 한다. k3s도 켜지만 그보다 먼저 경로를 광고한다
   echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale-subnet.conf >/dev/null
   sudo sysctl -p /etc/sysctl.d/99-tailscale-subnet.conf
   # 검증된 설치가 끝난 뒤에만 등록한다. 블록 밖에 두면 설치가 실패해도 남아 있던 옛 바이너리로 등록된다
   # --accept-dns=false: 등록 순간부터 노드 DNS를 tailnet(AdGuard)과 떼어 둔다(H5)
   # --ssh는 주지 않는다: 원격 접속은 tailnet 주소의 sshd(키 인증, root 로그인 금지, H4)다(D-11, 사용자 2026-10-21).
   # 켜면 tailnet 22번을 Tailscale SSH가 가로채 ACL의 ssh 규칙만으로(키 없이 root까지) 들어온다
   # --advertise-tags: NUC는 tag:nuc다(D-11 (c)). 태그 규칙이 ACL에 먼저 있어야 등록 뒤 원격 접속이 된다
   # --advertise-routes: 공유기 관리 화면(ACL grant와 autoApprovers가 짝이다)
   sudo tailscale up --hostname=<prod.env의 TAILNET_DEVICE_NAME(비면 NODE_NAME)> --accept-dns=false \
     --advertise-tags=tag:nuc --advertise-routes=192.168.117.1/32
   EOF
   ```

   외부 패키지를 깐 뒤에는 0.0의 `origin/main` 일치 확인을 다시 한다.
3. 이름을 확인한다. 아래 명령의 첫 라벨이 `prod.env`의 `TAILNET_DEVICE_NAME`(비면 `NODE_NAME`)과 같아야 한다. 콘솔에서 기기 이름을 일부러 바꾸면 이 값도 같은 PR에서 바꾼다. MagicDNS 이름이 바뀌어 운영자 kubeconfig의 `server`와 k3s 인증서 SAN이 어긋나므로 1절 끝의 안내대로 `--k3s`를 다시 돌려 새 이름을 SAN에 더한다.

   ```bash
   tailscale status --self --peers=false --json | jq -r '.Self.DNSName | rtrimstr(".")'
   ```

   전체 이름은 tailnet 이름을 담으므로 공개 저장소에 적지 않는다.
4. Tailscale 콘솔에서 이 기기의 태그가 `tag:nuc` 하나이고 키 만료가 꺼져 있는지 확인한다(태그 기기는 기본으로 꺼진다). 공유기 경로가 승인됐는지도 본다.
   이미 가입한 NUC(이 절을 건너뛴 경우)는 `tailscale debug prefs`의 `AdvertiseRoutes`에 `192.168.117.1/32`가 있는지 보고, 없으면 `sudo tailscale set --advertise-routes=192.168.117.1/32`로 광고한다. 같은 출력의 `RunSSH`가 true면 `sudo tailscale set --ssh=false`로 끄고 false인지 다시 본다(D-11: 원격 SSH는 sshd다. `--ssh`를 빼고 다시 등록해도 기존 설정은 꺼지지 않는다). `autoApprovers`는 광고된 경로를 승인할 뿐 광고하지 않는다.
   경로를 넘기려면 IP 포워딩이 영구로 켜져 있어야 한다. `/etc/sysctl.d/99-tailscale-subnet.conf`(`net.ipv4.ip_forward = 1`)가 없으면 위 블록의 두 줄로 만든다. 지금은 k3s가 실행 중에만 켜 둔다.
5. Tailscale IP가 바뀌었으면 DNS Terraform(`infra/tailscale-dns`, T08a 이후)을 apply해 전역 nameserver의 NUC 주소를 갱신한다.

### 0.2 사람 확인

- 공유기 DHCP 예약이 `NODE_IP`를 이 기기에 고정하는가. k3s의 node-ip는 설치 때만 정해진다(2026-10-19 운영: 예약 확인, 공유기 DNS 폴백 1.1.1.1). VM은 libvirt 네트워크의 DHCP 예약이다([vm.md](vm.md) 1.2).
- LAN SSH는 키로만 들어온다(sshd drop-in이 비밀번호 로그인을 끈다). 새 VM은 키나 콘솔을 먼저 마련한다.

## 1. 호스트 설정과 k3s

저장소 루트에서 한다. sudo가 필요한 단계는 파이프에 넣지 않는다. 한 단계라도 실패하면 다음으로 가지 않게 `&&`로 잇는다(2026-10-19 운영 설치도 이렇게 돌렸다).

```bash
host/preflight.sh --cluster <이름> --before \
  && sudo host/install.sh --cluster <이름> --host-config \
  && host/preflight.sh --cluster <이름> --after \
  && sudo host/install.sh --cluster <이름> --egress \
  && sudo host/install.sh --cluster <이름> --k3s \
  && host/verify.sh --cluster <이름>
```

- `--before`: 노드 IP와 인터페이스, k3s 잔여 경로(`/var/lib/rancher/k3s`, `/var/lib/rancher/k3s-storage`, `/etc/rancher/k3s`) 부재.
- `--host-config`: `host/etc/` drop-in 복사, sysctl(inotify 인스턴스 한도 8192)을 `sysctl --load`로 바로 걸기, 스왑 끄기, 타임존, `tailscale set --accept-dns=false`(`TAILNET_JOIN=true`일 때), resolv.conf, networkd drop-in 적용. **이때 클러스터 인터페이스가 약 2초 끊긴다.** 원격 세션이 잠깐 멈췄다 돌아오는 것이 정상이다.
- `--after`: 스왑 없음, 타임존, resolved 스텁 꺼짐, resolv.conf가 loopback·tailnet·자기 주소 아님, 링크가 DHCP DNS를 거부.
- `--egress`: 파드 egress 규칙(1.1절)을 `/etc/homelab/egress.nft`로 렌더하고 `homelab-egress.service`(k3s보다 먼저 뜸)로 올린다. k3s보다 먼저 두어 첫 파드부터 규칙 아래서 뜬다.
- `--k3s`: `host/versions.env`의 `INSTALL_K3S_VERSION` 고정 설치(채널 없음), `host/k3s-config.yaml`을 렌더해 `/etc/rancher/k3s/config.yaml`(0600)로 씀, `local-retain` StorageClass를 자동 배포 매니페스트로 둠, kubeconfig를 `~/.kube/<KUBE_CONTEXT>.yaml`(0600)로 씀. 이미 깔린 k3s에 다시 돌려 config 값이 바뀌면 이전 config를 `/var/lib/homelab/backup/k3s-config.<시각>.yaml`(root 0600)에 두고 경로를 출력한다. 같은 버전에서 tls-san만 바뀌면 설치 스크립트 없이 config만 바꿔 재시작한다(1절 끝).
- `verify`: 노드 Ready, k3s 버전, 라이브 node-args = 렌더한 config, serving cert SAN, `local-retain`, egress 유닛·규칙 파일·대역·커널 표, inotify 인스턴스 한도(설치된 sysctl 파일과 커널 값). 커널 표는 `sudo -n nft`로 읽는다. 앞 단계의 sudo 자격이 남아 있으면 그대로 읽고, 없으면 실패 없이 **종료 코드 2(미검증)** 로 끝난다. 2는 통과가 아니다.
- `--k3s`가 중간에 실패하면 `/etc/rancher/k3s`가 남아 `--before`가 막힌다. `--k3s`를 그대로 다시 실행하거나, `k3s-uninstall.sh`로 지우고 잔여 경로가 없는지 본 뒤 1부터 다시 한다.

이후 `kubectl`은 이 kubeconfig로 부른다.

```bash
export KUBECONFIG=~/.kube/<KUBE_CONTEXT>.yaml   # prod는 homelab, vm은 homelab-vm
kubectl config current-context
```

파괴적인 명령 전에는 `host/verify.sh --cluster <이름> --identity`로 context와 노드 이름이 맞는지 본다. VM 검증 기간에는 두 클러스터가 함께 있다.

운영자 기기에서 tailnet으로 쓰려면 이 파일을 복사하고 `server`를 `https://<MagicDNS 이름>:6443`으로 바꾼다. 그 이름은 설치 때의 MagicDNS 이름으로 k3s SAN에 들어간다. 저장소와 Infisical에는 두지 않는다.

설치 뒤 Tailscale 기기 이름을 바꾸면(prod는 2026-10-26 `nuc-pro`로 바꿈) 옛 MagicDNS 이름은 더 풀리지 않고, 새 이름은 아직 SAN에 없어 x509 오류가 난다. `--k3s`를 다시 돌리면 새 이름이 인증서에 더해진다. k3s는 재시작 뒤 설정 SAN 가운데 인증서에 없는 이름을 기존 SAN에 더해 다시 서명하고 옛 SAN은 지우지 않는다. 그래서 옛 MagicDNS 이름도 인증서에 남는다(무해하다. 근거는 `host/install.sh` `check_install_time_keys` 주석).

`--k3s`가 고르는 경로. 기존 config와의 비교는 주석과 빈 줄만 빼고 한다. 따옴표만 다른 값(`"0600"`은 문자열, `0600`은 8진수 정수), 빈 값 키(`cluster-domain: ""`, 항목 없는 `key:`), 목록 순서가 달라도 값이 바뀐 것으로 본다.

- **같은 k3s 버전에서 tls-san만 바뀜(이 경우):** 공식 설치 스크립트를 부르지 않는다. 이전 config를 백업하고, 새 config를 임시 파일에 쓴 뒤 `mv`로 바꾸고, `systemctl restart k3s`(180초 상한) → `/readyz` → 클러스터 DNS(kube-dns Service로 `kubernetes.default`를 물어 kubernetes Service IP가 나오는지)와 Service(그 IP의 443)를 확인한다. 이 확인은 Service 조회부터 마지막 재시도까지 합쳐 60초 상한이고, 넘으면 되돌리기 명령을 내고 멈춘다. 이어서 6443 서빙 인증서(SNI 없이)에 렌더의 tls-san이 모두 나올 때까지 기다린다(60초 상한, 넘으면 되돌리기 명령을 내고 멈춘다). 재시작 직후에는 k3s가 Secret을 갱신하기 전까지 옛 인증서가 잠시 나가서, 바로 돌린 verify의 SAN 검사가 실패할 수 있었다(2026-10-27). 설치 스크립트의 `KUBE-`·`flannel` 일괄 제거는 피하고, 유닛이 `KillMode=process`라 컨테이너는 계속 돈다.
- **그 밖의 값이나 k3s 버전이 바뀜:** 지금처럼 설치 스크립트를 부른다. config 값이 바뀌었으면 강제 재시작으로 부르고, 버전만 바뀌었으면 강제가 없어도 설치 스크립트가 바이너리를 바꾸며 스스로 재시작한다(바이너리·유닛·env 해시 비교, k3s v1.36.5+k3s1 `install.sh:1097-1099`·`1150-1153`). 설치 스크립트는 재시작 전에 `KUBE-`·`flannel`이 든 iptables 줄을 지우고 복원한다(`install.sh:1150-1163`). k3s가 다시 만들 때까지 Service·DNS 통신이 끊길 수 있다. 버전을 올린 뒤 실패하면 config 백업으로는 버전이 돌아가지 않는다. k3s의 버전 되돌리기는 바이너리와 데이터스토어를 함께 되돌린다([Rolling Back K3s](https://docs.k3s.io/upgrades/roll-back)).

**이미 설치된 k3s가 다시 떴으면 경로와 상관없이 위 DNS·Service 확인을 하고, tls-san이 바뀌었으면 SAN 대기도 한다.** 다시 떴는지는 config 비교로 정하지 않고 `k3s.service`의 시작 시각(`InactiveExitTimestampMonotonic`)을 실행 앞뒤로 비교해 정한다. 버전만 바뀐 실행도 여기 걸린다. 처음 설치(기존 config나 k3s 바이너리가 없음)는 CoreDNS가 아직 없어 하지 않는다.

**두 경로 모두 재시작 때 iptables가 잠깐 비는 자리가 있다.** k3s가 시작할 때 flannel(v0.28.4)이 자기 체인 `FLANNEL-POSTRTG`(nat)·`FLANNEL-FWD`(filter)를 비우고(`-F`) 곧 다시 채운다. 설치 스크립트를 건너뛰는 경로도 마찬가지다. 그 틈에 파드가 새로 여는 외부 연결은 SNAT(MASQUERADE) 없이 나가 실패할 수 있다. 이미 맺힌 연결은 conntrack에 남은 NAT로 이어진다. FORWARD 쪽 영향은 나머지 규칙에 달렸다. 틈의 길이는 재지 않았다. 노드에서 하는 DNS·Service 확인은 이 길을 지나지 않으므로 아래 새 파드 확인을 한다.

0.0의 main 확인 블록 뒤에 돌린다.

```bash
sudo host/install.sh --cluster <이름> --k3s       # 경로, tls-san 차이, 백업 경로 출력 → 재시작 → /readyz → 클러스터 DNS·Service 확인(60초 상한) → 서빙 인증서 SAN 대기(60초 상한)
sudo -v && host/verify.sh --cluster <이름>        # node-args·SAN ok
openssl s_client -connect <NODE_IP>:6443 -noservername </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName       # 새 MagicDNS 이름이 있다. 출력에 tailnet 이름이 있어 공개 기록에 붙이지 않는다
curl -s -o /dev/null -w '%{http_code}\n' https://edge-probe.ukyi.app/   # prod 공개 URL(터널) 200. VM은 E8 VM 격리 5번의 port-forward 확인
```

**재시작 뒤 새 파드의 새 외부 연결.** 위 확인은 이미 맺힌 터널과 노드 출발 연결이라 flannel이 비웠다 다시 채운 MASQUERADE를 지나지 않는다. 재시작이 끝난 뒤 새 파드를 띄워 클러스터 DNS로 공개 이름을 풀고 공개 443에 새로 연결한다. 실패하면 ns가 남는다. `kubectl -n net-check describe pod probe`와 `logs`를 본 뒤 `kubectl delete namespace net-check`로 지운다.

```bash
bash -euo pipefail <<'EOF'
export KUBECONFIG=~/.kube/<KUBE_CONTEXT>.yaml   # prod는 homelab, vm은 homelab-vm
kubectl create namespace net-check
kubectl label namespace net-check pod-security.kubernetes.io/enforce=restricted
kubectl -n net-check apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata: { name: probe }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 65532, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: probe
      image: docker.io/nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
      command: [sh, -c]
      # 셋 다 되어야 Succeeded: 클러스터 DNS로 공개 이름(IPv4 답), 그 이름의 443, 공개 주소의 443
      args: ["dig +time=3 +tries=1 +short github.com | grep -qE '^[0-9.]+$' && nc -z -w 3 github.com 443 && nc -z -w 3 1.1.1.1 443"]
YAML
kubectl -n net-check wait --for=jsonpath='{.status.phase}'=Succeeded pod/probe --timeout=120s
kubectl delete namespace net-check
echo "새 파드 외부 연결 통과"
EOF
```

**되돌리기:** `--k3s`가 출력한 백업을 제자리로 놓고 재시작한다. Git을 되돌려 `--k3s`를 다시 돌리는 것으로는 돌아가지 않는다(렌더가 그때의 `tailscale status`에서 MagicDNS 이름을 다시 읽는다). 인증서에 더한 새 이름은 남지만 무해하다.

```bash
sudo install -m 0600 -o root -g root /var/lib/homelab/backup/k3s-config.<시각>.yaml /etc/rancher/k3s/config.yaml \
  && sudo systemctl restart k3s
```

그다음 운영자 기기 kubeconfig의 `server`를 `https://<새 MagicDNS 이름>:6443`으로 바꾼다. `--k3s`를 다시 돌리기 전에 급히 붙어야 하면 같은 cluster 항목에 `tls-server-name: <NODE_NAME>`(인증서에 있는 이름, prod는 `nuc-15-pro`)을 더하면 통과한다(2026-10-26 NUC에서 tailnet 주소로 `/readyz` 확인). SAN을 맞춘 뒤에는 지운다(둬도 동작한다).

### 1.1 파드 egress 규칙(노드 nftables)

새 파드는 시작 직후 약 1초 동안 NetworkPolicy가 붙기 전이라 egress가 모두 열린다(설계 B.8 E5). `--egress`는 그 틈을 노드에서 막는다. 파드 대역(`POD_CIDR`)에서 출발한 패킷 가운데 노드 밖으로 나가는 것(forward)과 노드 자신으로 들어오는 것(input)을 보고, 아래 허용이 아니면 버린다. 노드 자신으로 가는 길은 NetworkPolicy가 늘 막지 못하던 길이라(설계 B.8 E4) 1초 공백과 상관없이 여기서만 막힌다. 노드가 시작한 연결과 관리자의 LAN·tailnet SSH는 출발이 파드 대역이 아니라 건드리지 않는다. 규칙 원본은 `host/egress/egress.nft`, 값은 `host/clusters/<이름>.env`(`NODE_IP`, `POD_CIDR`, `SERVICE_CIDR`)와 `host/versions.env`(`NODE_UPSTREAM_DNS`)다.

| 허용(순서대로) | 쓰는 곳 |
|---|---|
| **파드 → 노드 밖(forward)** | |
| 들어온 연결의 반환(`ct established,related`), 파드·서비스 대역 | svclb·hostPort 응답, 파드끼리, DNS·DB·Valkey |
| `NODE_IP` TCP 6443·10250 | 지금 경로에서는 input이라 이 줄에 오지 않는다(경로가 바뀔 때를 대비해 둠) |
| `NODE_UPSTREAM_DNS`(1.1.1.1·9.9.9.9) UDP·TCP 53 | CoreDNS 업스트림, AdGuard bootstrap |
| 공개 TCP 443, 공개 TCP·UDP 7844 | R2·Infisical·GitHub·Telegram·Tailscale DERP, cloudflared 터널 |
| **파드 → 노드 자신(input)** | |
| 노드가 시작한 연결의 응답(`ct established,related`) | kubelet probe, apiserver → webhook, port-forward |
| `NODE_IP` TCP 6443·10250 | kube API(`kubernetes` Service가 노드 IP:6443으로 DNAT), vmsingle의 kubelet 수집 |

그 밖은 모두 버린다: tailnet `100.64.0.0/10`, LAN 사설 대역, link-local, 공개 대역의 443·7844 밖 포트, 노드 자신의 나머지 포트(sshd 22 등. 노드 LAN 주소, cni0 게이트웨이, 노드 tailnet 주소 모두). Tailscale direct(UDP 41641)·STUN(3478)도 열지 않아 Tailscale 프록시는 DERP 443으로만 붙는다. hostPort(svclb-adguard `:53`)는 PREROUTING에서 파드로 DNAT되어 forward로 가므로 따로 열지 않았다. 2026-10-26 운영 조사: hostNetwork 파드 0, hostPort는 svclb-adguard 하나, node-exporter는 파드 IP로 수집, 파드가 쓰는 노드 IP 목적지는 `kubernetes` Endpoint 6443과 kubelet 10250뿐이다.

**이미 도는 클러스터에 켜기.** k3s를 다시 시작하지 않는다. 0.0의 main 확인 블록을 먼저 돌린다.

```bash
sudo host/install.sh --cluster <이름> --egress \
  && host/verify.sh --cluster <이름>
```

`--egress`는 렌더한 규칙을 `nft -c`로 먼저 검사하고, 올린 뒤 커널 표를 `verify`와 같은 판정으로 확인하고 표를 출력한다. 판정: 표 comment의 렌더 해시가 지금 Git 렌더와 같다(파일만 바꾸고 reload를 빠뜨리면 걸림), 표에 flags가 없다(`dormant`면 규칙이 남아도 표 전체가 꺼진다), forward·input hook 둘, 체인마다 규칙이 렌더와 자리까지 같다(로그 자리는 verdict 없는 로그, 클러스터 대역은 두 CIDR의 합집합. nft가 인접 CIDR을 합친 것은 같게, 넓힌 것은 다르게 본다), `nonpublic` 원소. 다시 실행하면 `reload`로 표를 통째 바꾼다(규칙이 빈 순간 없음).

`verify`는 같은 판정을 `sudo -n nft`로 한다. 위처럼 sudo 바로 뒤에 같은 터미널에서 돌리면 읽힌다. sudo를 쓸 수 없는 쪽(에이전트 등)이 돌리면 egress 커널 줄이 `SKIP`이고 종료 코드가 2다. 그때 커널 표는 사람이 `sudo -v && host/verify.sh --cluster <이름>`으로 본다.

**되돌리기(한 명령).** 유닛을 끄고 표와 파일을 지운다. 그 뒤는 NetworkPolicy만 남은 이전 상태이고 `verify`는 egress 항목에서 실패한다. 작업 사본에 커밋 안 한 변경이 있어도 막지 않는다.

```bash
sudo host/install.sh --cluster <이름> --egress-off
```

**적용 뒤 확인.** 이미 맺힌 연결은 `established`로 계속 통과하므로, 그대로 두면 확인이 헛통과한다. 새 연결을 만들게 cloudflared와 Tailscale 프록시 하나를 다시 띄운 뒤 본다. cloudflared가 다시 붙는 몇 초 동안 공개 URL이 끊긴다.

```bash
bash -euo pipefail <<'EOF'
export KUBECONFIG=~/.kube/<KUBE_CONTEXT>.yaml   # prod는 homelab, vm은 homelab-vm
kubectl -n cloudflared rollout restart deploy/cloudflared
kubectl -n cloudflared rollout status deploy/cloudflared --timeout=180s
# Tailscale 프록시 하나(StatefulSet이 다시 만든다). VM은 vm- 접두
kubectl -n tailscale delete "$(kubectl -n tailscale get pods -o name | grep '^pod/ts-grafana-')"
# 새 base backup(R2 443)
kubectl -n database create -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: egress-check-$(date +%Y%m%d%H%M), namespace: database }
spec: { cluster: { name: pg }, method: plugin, pluginConfiguration: { name: barman-cloud.cloudnative-pg.io } }
YAML
# Telegram 시험 경보(Alertmanager -> api.telegram.org 443). 휴대폰에 2분 안에 와야 한다
kubectl -n observability exec deploy/alertmanager -c alertmanager -- \
  amtool alert add alertname=EgressCheck severity=warning --alertmanager.url=http://localhost:9093
echo "다시 띄움·백업·시험 경보 보냄"
EOF
```

그다음 아래를 본다. 사람 기기가 필요한 둘(Telegram 수신, tailnet UI)만 사람이 보고, 나머지는 읽기 명령이라 누가 봐도 된다.

| 항목 | 확인 | 통과 |
|---|---|---|
| 공개 URL(터널 7844) | `curl -s -o /dev/null -w '%{http_code}\n' https://edge-probe.ukyi.app/`(prod. VM은 E8 VM 격리 5번의 port-forward 확인) | `200`, cloudflared 로그에 `Registered tunnel connection` |
| 클러스터 DNS(53) | 아래 시험 파드의 `cluster-dns` 줄, `kubectl -n kube-system logs deploy/coredns --since=10m` | 해석 성공, 업스트림 `i/o timeout` 없음 |
| Argo CD 동기화(GitHub 443) | 2분 뒤 3절의 `Synced/Healthy` 줄 | 모든 Application `Synced/Healthy` |
| R2 백업(443) | `kubectl -n database get backups`, `kubectl -n database get cluster pg -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}'` | `egress-check-*`가 `completed`, `True` |
| Alertmanager → Telegram(443) | 휴대폰 | `EgressCheck` 2분 안 수신 |
| tailnet UI(DERP) | 운영자 기기에서 `grafana` tailnet 주소 열기, `tailscale ping grafana` | 열림, `via DERP(...)`(direct가 아니어도 정상) |
| 막힌 연결 | `journalctl -k -g homelab-egress --since '-15min'` | 위 경로의 목적지가 없다. 있으면 그 목적지·포트를 보고 판단한다 |
| 커널 규칙 | `sudo -v && host/verify.sh --cluster <이름>`, `sudo nft list table inet homelab_egress` | verify 종료 코드 0, 허용 줄의 카운터가 오른다(`pod_egress`의 6443·10250 줄은 0이 정상) |

**시작 즉시 연결하는 시험 파드.** NetworkPolicy가 없는 임시 ns에서 파드가 뜨자마자 연결한다. 그 ns에는 정책이 없으므로 결과는 노드 규칙만의 효과이고, 1초 공백 동안의 상태와 같다. 막혔다고 나온 대상이 원래 닫힌 포트라서가 아님을 보이려고, 같은 대상에 노드에서 먼저 연결해 본다(대조).

```bash
bash -euo pipefail <<'EOF'
export KUBECONFIG=~/.kube/<KUBE_CONTEXT>.yaml   # prod는 homelab, vm은 homelab-vm
. host/clusters/<이름>.env
LAN_GW="${NODE_IP%.*}.1"
# tailnet 대상(Argo CD 프록시)은 실행 때 얻는다. 저장소에 Tailscale IP를 두지 않는다. VM은 tailnet 밖이라 건너뛴다
TS_IP=""
if [ "$TAILNET_JOIN" = true ]; then
  TS_IP="$(tailscale status --json | jq -r '.Peer[] | select((.DNSName // "") | startswith("argocd.")) | .TailscaleIPs[] | select(startswith("100."))')"
  test -n "$TS_IP"
fi
# 노드 자신의 주소: cni0 게이트웨이(노드 podCIDR의 .1), tailnet 주소(prod만, 실행 때 얻는다)
CNI_GW="$(kubectl get node "$NODE_NAME" -o jsonpath='{.spec.podCIDR}' | sed -E 's|\.0/[0-9]+$|.1|')"
TS_NODE=""
if [ "$TAILNET_JOIN" = true ]; then TS_NODE="$(tailscale ip -4)"; test -n "$TS_NODE"; fi
# 대조: 노드에서는 열린다
for t in "$LAN_GW 80" "$LAN_GW 443" "1.1.1.1 80" "github.com 22" ${TS_IP:+"$TS_IP 443"} \
  "$NODE_IP 22" "$CNI_GW 22" ${TS_NODE:+"$TS_NODE 22"}; do
  nc -z -w 3 $t || { echo "대조 실패(노드에서도 닫힘): $t"; exit 1; }
done
kubectl create namespace egress-probe
kubectl label namespace egress-probe pod-security.kubernetes.io/enforce=restricted
sed -e "s/@LAN_GW@/$LAN_GW/g" -e "s/@NODE_IP@/$NODE_IP/g" -e "s/@TS_IP@/$TS_IP/g" \
  -e "s/@CNI_GW@/$CNI_GW/g" -e "s/@TS_NODE@/$TS_NODE/g" <<'YAML' | kubectl -n egress-probe apply -f -
apiVersion: v1
kind: Pod
metadata: { name: probe }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 65532, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: probe
      image: docker.io/nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
      command: [sh, -c]
      args:
        - |
          c() { if nc -z -w 3 "$3" "$4" 2>/dev/null; then g=open; else g=blocked; fi
                [ "$g" = "$1" ] && echo "ok   $g $2 $3:$4" || echo "FAIL $g(기대 $1) $2 $3:$4"; }
          # dig +short는 실패도 ";;" 줄로 stdout에 낸다. IPv4 답만 성공으로 센다. 셋째 인자가 없으면 클러스터 DNS다.
          d() { if dig +time=3 +tries=1 +short ${3:+"$3"} github.com | grep -qE '^[0-9.]+$'; then g=open; else g=blocked; fi
                [ "$g" = "$1" ] && echo "ok   $g $2" || echo "FAIL $g(기대 $1) $2"; }
          c blocked lan-gw @LAN_GW@ 80
          c blocked lan-gw @LAN_GW@ 443
          [ -z "@TS_IP@" ] || c blocked tailnet @TS_IP@ 443
          c blocked public-80 1.1.1.1 80
          c open public-443 1.1.1.1 443
          d open cluster-dns
          c blocked public-22 github.com 22
          c open tunnel-7844 region1.v2.argotunnel.com 7844
          d open upstream-dns @1.1.1.1
          d blocked other-dns @8.8.8.8
          c blocked node-ssh @NODE_IP@ 22
          c blocked cni-gw-ssh @CNI_GW@ 22
          [ -z "@TS_NODE@" ] || c blocked node-tailnet-ssh @TS_NODE@ 22
          c open node-api @NODE_IP@ 6443
          c open kube-api-svc kubernetes.default.svc.cluster.local 443
YAML
kubectl -n egress-probe wait --for=jsonpath='{.status.phase}'=Succeeded pod/probe --timeout=180s
# grep -q를 파이프 끝에 두지 않는다. 먼저 끝난 grep이 앞 명령을 SIGPIPE로 죽여 pipefail이 결과를 뒤집는다.
out="$(kubectl -n egress-probe logs probe)"
printf '%s\n' "$out"
if grep -q '^FAIL' <<<"$out"; then echo "egress 시험 실패"; exit 1; fi
kubectl delete namespace egress-probe
echo "egress 시험 통과"
EOF
```

첫 줄(`lan-gw`)은 컨테이너가 시작하자마자 나간다. `node-api`·`kube-api-svc`가 열리는 것은 정상이다(아래 한계 1). 실패하면 ns가 남으니 본 뒤 `kubectl delete namespace egress-probe`로 지운다.

**남는 한계.**

1. 파드 → 노드 자신은 kube API 6443과 kubelet 10250만 열려 있다. 모든 파드(1초 공백의 새 파드 포함)가 이 둘에 닿고, 각자의 인증만 남는다. 앱 파드만 골라 막으려면 출발 파드를 가리는 장치가 따로 필요하다. 파드 대역만으로는 컨트롤러·vmsingle과 앱을 가를 수 없다.
2. 업스트림 DNS 53(1.1.1.1·9.9.9.9)은 모든 파드에 열려 있다. AdGuard를 거치지 않는 평문 DNS와 그 위의 유출 경로가 남는다.
3. 공개 443·7844는 모든 파드에 열려 있다(정상 정책도 대부분 공개 443을 연다).
4. Tailscale 프록시는 DERP로만 붙는다(direct·STUN 막음). 지연이 늘 수 있다. 공개 UDP 443(QUIC)도 막혀 TCP로 넘어간다.
5. 부팅 때 규칙이 못 올라와도 k3s는 뜬다(fail-open, 유닛에 `Requires`를 두지 않음). 그때는 NetworkPolicy만 남은 이전 상태이고 `verify`가 커널 표로 잡는다. k3s만 다시 시작해도 규칙은 되살아나지 않는다. `--egress`를 다시 실행한다.
6. 규칙을 켜기 전에 맺힌 연결은 `established`로 계속 통과한다. 그래서 적용 뒤 확인에서 cloudflared와 Tailscale 프록시를 다시 띄운다.

## 2. Argo CD 설치와 root

순서는 설계 C.3.3 그대로다: Argo CD 설치 → (T09 이후) 손으로 넣는 Secret → root apply. root가 먼저 생기면 자동 동기화가 Secret 없이 시작해 Store와 뒤 Application이 오류 상태로 들어간다.

각 블록은 `set -euo pipefail`을 건 별도 bash로 돌리고, 블록이 실패하면 다음 블록으로 가지 않는다. `<이름>`은 먼저 바꿔 넣는다. 재부팅 뒤 새 셸이면 1절의 `export KUBECONFIG=...`부터 다시 한다.

### 2.1 Argo CD 설치

```bash
bash -euo pipefail <<'EOF'
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts --field-manager=argocd-controller -k platform/argocd
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=300s
kubectl -n argocd rollout status sts/argocd-application-controller --timeout=300s
EOF
```

- **`--field-manager=argocd-controller`를 빼지 않는다.** 기본 manager(`kubectl`)로 깔면 모든 필드를 Argo CD와 함께 소유한다. 그러면 나중에 Git에서 뺀 필드가 라이브에 영구히 남는다. 설치 뒤에는 managedFields를 손으로 고쳐야 한다.
- `admin`은 꺼져 있고 사람 계정은 `owner`다. `owner` 비밀번호는 T09가 ExternalSecret으로 넣는다. 그 전까지는 `kubectl`이나 `argocd --core`로만 다룬다.

### 2.2 root보다 먼저 손으로 넣는 Secret (T09 이후)

T09 전(2026-10-19 운영 최초 설치)에는 건너뛴다. 평상시 사람이 손으로 넣는 Secret은 ESO 부트스트랩 Secret 하나다.

**먼저 Infisical 쪽을 확인한다.** 클러스터가 읽는 프로젝트·환경(운영 `homelab`/`prod`, VM `homelab-dev`/`dev`)에 폴더 `/platform`과 `/apps`가 있어야 한다. ClusterSecretStore는 Ready 판정 때 그 폴더 목록을 읽어, 폴더가 없으면 404로 Ready=False가 되고 root가 wave -7에서 멈춘다. Git의 ExternalSecret이 읽는 키도 모두 있어야 한다(지금은 `/platform/argocd`의 `OWNER_PASSWORD_BCRYPT`·`OWNER_PASSWORD_MTIME`). 하나라도 빠지면 그 Application이 Degraded가 되고 root가 뒤 wave로 넘어가지 않는다.

ESO 자격 값은 복구 자산([recovery-assets.md](recovery-assets.md))에서 오고(VM은 VM 준비 자산의 `eso-homelab-dev` 값), 출력하지 않는다. 변수는 `export`해야 아래 bash가 받는다. 비었으면 Secret을 만들지 않고 멈춘다.

```bash
bash -euo pipefail <<'EOF'
: "${ESO_CLIENT_ID:?ESO_CLIENT_ID가 비었다}" "${ESO_CLIENT_SECRET:?ESO_CLIENT_SECRET가 비었다}"
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
# 값을 명령행 인자로 넘기지 않는다(ps·/proc로 보인다). jq가 환경변수에서 읽어 stdin으로 넘긴다
jq -n '{apiVersion: "v1", kind: "Secret", type: "Opaque",
        metadata: {name: "infisical-universal-auth", namespace: "external-secrets"},
        stringData: {clientId: env.ESO_CLIENT_ID, clientSecret: env.ESO_CLIENT_SECRET}}' \
  | kubectl apply --server-side --field-manager=bootstrap -f -
EOF
```

다시 실행해도 같은 Secret을 덮어쓸 뿐 멈추지 않는다. 값은 `kubectl`의 명령행 인자에 들어가지 않고(`--from-literal`은 `ps`·`/proc`로 보인다), `--server-side`로 적용해 client-side apply가 남기는 `last-applied-configuration` 주석에 값이 한 벌 더 복사되지도 않는다. T09가 2026-10-20에 이 방식을 확정했다(시나리오 7의 장애 주입과 복구가 같은 방식이었다. ESO를 재시작하지 않아도 Secret 교체 약 1분 20초 뒤 Store가 Ready였다). 자격을 바꾸는 순서는 [rotate.md](rotate.md) 1절이다.

**vm 분기(시나리오 13)는 이 절에서 아래를 이 순서로 더 한다**(설계 C.3.3 "vm 분기의 추가 단계"). 위의 일반 ESO 블록 대신 아래 2단계 블록을 쓰고, 2.3 대신 4단계 블록을 쓴다.

NUC의 작업 사본에서 한다. Infisical CLI와 yq는 NUC의 mise에만 있고 VM에는 없다. NUC에는 운영 kubeconfig도 있으므로 VM에 쓰는 블록은 모두 첫 두 줄에서 `KUBECONFIG`를 VM 파일로 고정하고 정체성(context `homelab-vm`, `vm.env`의 노드 이름 하나)을 본다. VM kubeconfig를 NUC에 두는 방법은 [vm.md](vm.md) 3절이다. **운영 kubeconfig로 2단계를 돌리면 운영 ESO 자격이 dev identity로 바뀌어 운영의 모든 ExternalSecret 갱신이 멈춘다.**

1. **ESO Secret 전에 키를 대조한다.** 운영 클러스터(main을 동기화한 결과)의 ExternalSecret이 읽는 키를 Infisical 경로로 바꾸고, `homelab-dev`/`dev`의 같은 폴더 키 이름과 `comm -23`으로 대조한다(설계 E8 VM 격리 2번). 운영 클러스터는 읽기만 한다. 값은 출력하지 않고, 빠진 키가 하나라도 있으면 그 이름만 내고 멈춘다. `infisical login`(사람 계정)을 먼저 한다. `homelab-smoke` 키는 시나리오 2·3 뒤에 생기므로 그 뒤의 대조에 들어간다.

   ```bash
   bash -euo pipefail <<'EOF'
   # 운영은 읽기만 한다. VM 블록과 섞이지 않게 kubeconfig와 context를 호출마다 적는다
   prod() { kubectl --kubeconfig "$HOME/.kube/homelab.yaml" --context homelab --request-timeout=15s "$@"; }
   # 이 bash의 stdin은 스크립트 자체라 터미널에서 읽는다. ID는 저장소에 두지 않는다
   [ -n "${HOMELAB_DEV_PROJECT_ID:-}" ] || read -r -p 'Infisical homelab-dev project ID: ' HOMELAB_DEV_PROJECT_ID </dev/tty
   [[ "$HOMELAB_DEV_PROJECT_ID" =~ ^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$ ]] || { echo "project ID가 UUID 형식이 아니다"; exit 1; }
   # infra/README.md 2절과 같은 잠금. 로그인 사용자의 CLI 0.44.2는 조회한 값을 ~/.infisical/secrets-backup/에 남긴다
   mkdir -p ~/.infisical
   if [ -d ~/.infisical/secrets-backup ]; then chmod 0700 ~/.infisical/secrets-backup; find ~/.infisical/secrets-backup -type f -delete; fi
   mkdir -p ~/.infisical/secrets-backup && chmod 0500 ~/.infisical/secrets-backup
   if touch ~/.infisical/secrets-backup/.probe 2>/dev/null; then
     rm -f ~/.infisical/secrets-backup/.probe; echo "백업 폴더가 쓰기 가능하다. 멈춘다"; exit 1
   fi
   d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
   # 운영 ExternalSecret의 키를 Infisical 절대 경로로. store의 secretsPath를 앞에 붙이고, /로 시작하는 키는 그대로다(U06).
   # dataFrom이나 namespaced SecretStore는 이 방법으로 키 이름을 셀 수 없어 멈춘다(지금은 없다)
   stores="$(prod get clustersecretstore -o json \
     | jq -c '[.items[] | {key: .metadata.name, value: .spec.provider.infisical.secretsScope.secretsPath}] | from_entries')"
   prod get externalsecret -A -o json | jq -r --argjson s "$stores" '
     .items[] | . as $e | "\($e.metadata.namespace)/\($e.metadata.name)" as $n
     | if ($e.spec.secretStoreRef.kind // "SecretStore") != "ClusterSecretStore" then error("ClusterSecretStore가 아니다: \($n)")
       elif ($e.spec.dataFrom // []) != [] then error("dataFrom은 키 이름을 셀 수 없다: \($n)")
       else ($s[$e.spec.secretStoreRef.name] // error("store 경로를 모른다: \($n)")) as $p
         | $e.spec.data[]?.remoteRef.key | if startswith("/") then . else "\($p)/\(.)" end
       end' | LC_ALL=C sort -u >"$d/want"
   test -s "$d/want"
   # homelab-dev의 같은 폴더에서 키 이름만. 목록 JSON에는 값도 오지만 jq가 이름만 남긴다(화면·파일에 값 없음).
   # 가져온(import) 키와 개인 덮어쓰기는 빼고 이 폴더의 shared 키만 센다. ESO identity는 개인 덮어쓰기를 보지 못하고,
   # 사람 로그인으로 그것까지 세면 빠진 shared 키를 놓친다. 폴더가 없어 CLI가 실패해도 멈춘다
   while IFS= read -r dir; do
     infisical secrets --path "$dir" --env dev --projectId "$HOMELAB_DEV_PROJECT_ID" --silent -o json \
         --include-imports=false --expand=false --secret-overriding=false </dev/null \
       | jq -r --arg dir "$dir" '(. // [])[] | "\($dir)/\(.secretKey)"'
     if [ "$(find ~/.infisical/secrets-backup -type f | wc -l)" -ne 0 ]; then
       chmod 0700 ~/.infisical/secrets-backup; find ~/.infisical/secrets-backup -type f -delete; chmod 0500 ~/.infisical/secrets-backup
       echo "Infisical 백업 파일이 생겼다. 지우고 멈춘다" >&2; exit 1
     fi
   done < <(sed 's|/[^/]*$||' "$d/want" | LC_ALL=C sort -u) | LC_ALL=C sort -u >"$d/have"
   missing="$(LC_ALL=C comm -23 "$d/want" "$d/have")"
   if [ -n "$missing" ]; then
     printf 'homelab-dev/dev에 없는 키 %s개(이름만):\n%s\n' "$(wc -l <<<"$missing")" "$missing"; exit 1
   fi
   echo "빠진 키 0 (운영 키 $(wc -l <"$d/want")개)"
   EOF
   ```

2. **ESO Secret의 값은 `eso-homelab-dev`이다.** VM 준비 자산의 client ID·secret을 대화형 셸에서 `read -rs ESO_CLIENT_ID`, `read -rs ESO_CLIENT_SECRET`로 받고 `export ESO_CLIENT_ID ESO_CLIENT_SECRET`한 뒤 돌린다. 운영 자격을 잘못 넣으면 그 identity가 `homelab-dev`에 없어 Store가 Ready가 되지 않는다(조용히 운영 값을 읽지 않는다).

   ```bash
   bash -euo pipefail <<'EOF'
   export KUBECONFIG=~/.kube/homelab-vm.yaml
   host/verify.sh --cluster vm --identity
   : "${ESO_CLIENT_ID:?ESO_CLIENT_ID가 비었다}" "${ESO_CLIENT_SECRET:?ESO_CLIENT_SECRET가 비었다}"
   kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
   jq -n '{apiVersion: "v1", kind: "Secret", type: "Opaque",
           metadata: {name: "infisical-universal-auth", namespace: "external-secrets"},
           stringData: {clientId: env.ESO_CLIENT_ID, clientSecret: env.ESO_CLIENT_SECRET}}' \
     | kubectl apply --server-side --field-manager=bootstrap -f -
   EOF
   ```

3. **root apply 전에 복구 원본 R2 읽기 전용 Secret을 넣는다.** 복구 자산의 운영 버킷(`homelab-backups`) 읽기 전용 토큰을 2단계처럼 `R2_RO_ACCESS_KEY_ID`·`R2_RO_SECRET_ACCESS_KEY`·`R2_RO_ENDPOINT`(S3 API endpoint URL)로 export한다. Infisical에 두지 않는 Secret 하나다(설계 E8 VM 격리 3번). 이름과 키는 values-vm의 `recoverySource.credentialsSecret`, CNPG 차트가 읽는 키(`platform/cnpg/cluster/templates/_helpers.tpl`)와 같다. 그래서 main의 values-vm에 복구 PR이 없으면 넣지 않고 멈춘다. `database` ns는 root의 namespaces(wave -9)가 만들기 전이라 여기서 만들고, 나중에 root가 라벨을 붙여 인수한다. 같은 블록이 [restore.md](restore.md) 3절에도 있다. 고치면 둘을 함께 고친다.

   ```bash
   bash -euo pipefail <<'EOF'
   export KUBECONFIG=~/.kube/homelab-vm.yaml
   host/verify.sh --cluster vm --identity
   : "${R2_RO_ACCESS_KEY_ID:?R2_RO_ACCESS_KEY_ID가 비었다}" "${R2_RO_SECRET_ACCESS_KEY:?R2_RO_SECRET_ACCESS_KEY가 비었다}" "${R2_RO_ENDPOINT:?R2_RO_ENDPOINT가 비었다}"
   git fetch -q origin main
   src=$(git show origin/main:platform/root/values-vm.yaml | yq -o json '.cluster.cnpg.recoverySource // {}')
   [ "$(jq -r '.credentialsSecret' <<<"$src")" = r2-source-readonly ] && [ "$(jq -r '.bucket' <<<"$src")" = homelab-backups ] \
     || { echo "main의 values-vm.yaml에 복구 PR(recoverySource.bucket·credentialsSecret)이 없다. 먼저 병합한다" >&2; exit 1; }
   kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -
   jq -n '{apiVersion: "v1", kind: "Secret", type: "Opaque",
           metadata: {name: "r2-source-readonly", namespace: "database"},
           stringData: {ACCESS_KEY_ID: env.R2_RO_ACCESS_KEY_ID, SECRET_ACCESS_KEY: env.R2_RO_SECRET_ACCESS_KEY, ENDPOINT_URL: env.R2_RO_ENDPOINT}}' \
     | kubectl apply --server-side --field-manager=bootstrap -f -
   EOF
   ```

   넣은 뒤 [restore.md](restore.md) 3절 3단계의 쓰기 거부 시험을 하고 4단계(root apply)로 간다. 이 Secret은 복구가 끝나면 restore.md 3절의 정리 단계에서 지운다. 끝나면 셸의 자격 변수를 `unset`한다.

4. **root apply는 `root-vm.yaml`이다.** 2.3의 명령 대신 이 블록으로 한다. 2.3의 나머지 설명은 그대로다.

   ```bash
   bash -euo pipefail <<'EOF'
   export KUBECONFIG=~/.kube/homelab-vm.yaml
   host/verify.sh --cluster vm --identity
   kubectl apply -f platform/root/root-vm.yaml
   EOF
   ```

### 2.3 root apply

```bash
kubectl apply -f platform/root/root-<이름>.yaml
```

- root가 `argocd` Application까지 소유한다. 이후 Argo CD 변경은 PR → main이다. Argo CD는 공개 webhook 없이 main을 60초마다 본다(jitter 0).
- **예외: root Application 자신은 Git에서 저절로 맞춰지지 않는다.** `root-prod.yaml`·`root-vm.yaml`은 차트의 `templates/` 밖에 있어 root가 렌더하지 않기 때문이다(운영 root가 VM root를 만들지 않게 하려는 배치). 그래서 이 두 파일(source, `valueFiles`, sync 정책)을 바꾸는 PR은 병합 뒤 `kubectl apply -f platform/root/root-<이름>.yaml`로 다시 적용하고, 그 PR 본문에 이 단계를 적는다. `templates/`와 값 파일 변경은 다시 적용할 필요가 없다.

## 3. 확인

다른 블록처럼 한 항목이라도 틀리면 멈추고, 모든 항목(prod의 Tailscale DNS 포함)이 맞을 때만 마지막에 `확인 통과`를 출력한다. 재부팅 뒤 새 셸에서도 이 블록을 그대로 돌린다(`KUBECONFIG`를 안에서 잡는다). `verify`가 egress 커널 표를 `sudo -n nft`로 읽으므로 블록 앞에서 `sudo -v`를 한 번 한다. 하지 않으면 `verify`가 2(미검증)로 끝나 블록이 멈춘다.

```bash
bash -euo pipefail <<'EOF'
export KUBECONFIG=~/.kube/<KUBE_CONTEXT>.yaml   # prod는 homelab, vm은 homelab-vm
host/preflight.sh --cluster <이름> --after      # 스왑, 타임존, resolved 스텁, resolv.conf, 링크가 DHCP DNS 거부(drop-in 로드)
host/verify.sh --cluster <이름>                 # 노드 Ready, k3s 버전, node-args, SAN, local-retain, egress(커널 표), inotify 한도. 2는 미검증
kubectl -n argocd get applications
# 모든 Application이 Synced·Healthy
test "$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.status.sync.status}/{.status.health.status}{"\n"}{end}' | sort -u)" = "Synced/Healthy"
# 공개 webhook 없이 60초 폴링, jitter 0
test "$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation} {.data.timeout\.reconciliation\.jitter}')" = "60s 0"
# 노드 DNS는 공용 DNS 직접
resolvectl status | grep -F 'DNS Servers: 1.1.1.1 9.9.9.9'
# TAILNET_JOIN=true(prod)만: Tailscale DNS를 받지 않는다. 받으면 노드 DNS가 AdGuard에 다시 묶인다.
# VM은 tailnet에 없고 Tailscale도 깔지 않으므로 건너뛴다
if [ "$(. host/clusters/<이름>.env && echo "$TAILNET_JOIN")" = true ]; then
  tailscale dns status | grep -Fx 'Tailscale DNS: disabled.'
fi
echo "확인 통과"
EOF
```

재부팅 뒤에도 `preflight --after`부터 같은 확인을 모두 한다(시나리오 12). `resolvectl`의 전역 DNS 줄만으로는 부팅 때 networkd drop-in이 안 실려 링크 DNS가 DHCP로 되살아난 경우를 못 잡는다. 그것은 `preflight --after`가 본다. k3s는 enabled라 부팅 때 시작하고, Argo CD가 모든 Application을 다시 맞춘다.
