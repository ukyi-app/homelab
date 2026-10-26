# 부트스트랩: 빈 호스트에서 k3s와 Argo CD까지

새 호스트(또는 k3s를 지운 호스트)에 클러스터를 세우는 순서다. 운영 NUC는 2026-10-19 T07에서 이 순서로 세웠다. 시나리오 13(VM에서 다시 세우기)의 입력이기도 하다. 근거는 설계 [C.3.2](../plans/2026-10-17-homelab-rebuild/platform/design.md)(호스트·k3s)와 C.3.3(Argo CD)이다.

이 문서 밖의 수동 단계를 두지 않는다. 실행하다 문서와 다르게 한 것이 있으면 이 문서를 먼저 고친다.

## 0. 클러스터 이름 고르기

| 클러스터 | 이름 | 호스트 값 | 클러스터 값 | root 파일 |
|---|---|---|---|---|
| 운영 NUC | `prod` | `host/clusters/prod.env` | `platform/root/values-prod.yaml` | `platform/root/root-prod.yaml` |
| 시나리오 13 VM | `vm` | `host/clusters/vm.env` | `platform/root/values-vm.yaml` | `platform/root/root-vm.yaml` |

아래 `<이름>`은 이 이름 하나다. 스크립트와 매니페스트에는 클러스터 이름 분기가 없고, 값 파일만 바뀐다.

- `vm.env`의 `CHANGE_ME`는 VM을 준비할 때 채운다. 남아 있으면 host 스크립트가 멈춘다.
- `values-vm.yaml`은 아직 자동 검사가 없다. 지금은 키 모양만 있고 값이 비어 있다. T13이 VM 값을 채우면서 빈 값을 막는 검사도 더한다. 그 전에는 `root-vm.yaml`을 apply하지 않는다.
- VM 호스트는 tailnet에 넣지 않는다(`TAILNET_JOIN=false`). VM 접근은 LAN 주소나 콘솔로 한다.

### 0.0 작업 사본과 필요한 패키지

이 문서의 여러 줄짜리 명령은 모두 한 단계라도 실패하면 멈추게 적는다. 대화형 셸에 줄을 붙여 넣으면 앞 명령이 실패해도 다음 줄이 돌기 때문이다. 그래서 `&&`로 잇거나 `set -euo pipefail`을 건 별도 bash(`bash -euo pipefail <<'EOF'`)로 돌린다. 블록이 실패하면 다음 블록으로 가지 않는다.

새로 설치한 호스트에는 스크립트가 쓰는 도구를 먼저 깔고, 작업 사본이 없으면 만든다(Ubuntu 26.04 기준). `openssh-server`는 `host/install.sh --host-config`가 sshd 설정을 검사(`sshd -t`)하는 데 필요하고, `nftables`(`nft`)는 `--egress`가 파드 egress 규칙을 올리는 데 필요하다. 최소 설치나 VM에는 없을 수 있다.

```bash
sudo apt-get update \
  && sudo apt-get install -y git jq curl gnupg openssh-server nftables \
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
   sudo tailscale up --hostname=<prod.env의 NODE_NAME> --accept-dns=false \
     --advertise-tags=tag:nuc --advertise-routes=192.168.117.1/32
   EOF
   ```

   외부 패키지를 깐 뒤에는 0.0의 `origin/main` 일치 확인을 다시 한다.
3. 이름을 확인한다. 아래 명령의 첫 라벨이 `prod.env`의 `NODE_NAME`과 같아야 한다.

   ```bash
   tailscale status --self --peers=false --json | jq -r '.Self.DNSName | rtrimstr(".")'
   ```

   전체 이름은 tailnet 이름을 담으므로 공개 저장소에 적지 않는다.
4. Tailscale 콘솔에서 이 기기의 태그가 `tag:nuc` 하나이고 키 만료가 꺼져 있는지 확인한다(태그 기기는 기본으로 꺼진다). 공유기 경로가 승인됐는지도 본다.
   이미 가입한 NUC(이 절을 건너뛴 경우)는 `tailscale debug prefs`의 `AdvertiseRoutes`에 `192.168.117.1/32`가 있는지 보고, 없으면 `sudo tailscale set --advertise-routes=192.168.117.1/32`로 광고한다. 같은 출력의 `RunSSH`가 true면 `sudo tailscale set --ssh=false`로 끄고 false인지 다시 본다(D-11: 원격 SSH는 sshd다. `--ssh`를 빼고 다시 등록해도 기존 설정은 꺼지지 않는다). `autoApprovers`는 광고된 경로를 승인할 뿐 광고하지 않는다.
   경로를 넘기려면 IP 포워딩이 영구로 켜져 있어야 한다. `/etc/sysctl.d/99-tailscale-subnet.conf`(`net.ipv4.ip_forward = 1`)가 없으면 위 블록의 두 줄로 만든다. 지금은 k3s가 실행 중에만 켜 둔다.
5. Tailscale IP가 바뀌었으면 DNS Terraform(`infra/tailscale-dns`, T08a 이후)을 apply해 전역 nameserver의 NUC 주소를 갱신한다.

### 0.2 사람 확인

- 공유기 DHCP 예약이 `NODE_IP`를 이 기기에 고정하는가. k3s의 node-ip는 설치 때만 정해진다(2026-10-19 운영: 예약 확인, 공유기 DNS 폴백 1.1.1.1).
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
- `--host-config`: `host/etc/` drop-in 복사, 스왑 끄기, 타임존, `tailscale set --accept-dns=false`(`TAILNET_JOIN=true`일 때), resolv.conf, networkd drop-in 적용. **이때 클러스터 인터페이스가 약 2초 끊긴다.** 원격 세션이 잠깐 멈췄다 돌아오는 것이 정상이다.
- `--after`: 스왑 없음, 타임존, resolved 스텁 꺼짐, resolv.conf가 loopback·tailnet·자기 주소 아님, 링크가 DHCP DNS를 거부.
- `--egress`: 파드 egress 규칙(1.1절)을 `/etc/homelab/egress.nft`로 렌더하고 `homelab-egress.service`(k3s보다 먼저 뜸)로 올린다. k3s보다 먼저 두어 첫 파드부터 규칙 아래서 뜬다.
- `--k3s`: `host/versions.env`의 `INSTALL_K3S_VERSION` 고정 설치(채널 없음), `host/k3s-config.yaml`을 렌더해 `/etc/rancher/k3s/config.yaml`(0600)로 씀, `local-retain` StorageClass를 자동 배포 매니페스트로 둠, kubeconfig를 `~/.kube/<KUBE_CONTEXT>.yaml`(0600)로 씀.
- `verify`: 노드 Ready, k3s 버전, 라이브 node-args = 렌더한 config, serving cert SAN, `local-retain`, egress 유닛·규칙 파일·대역.
- `--k3s`가 중간에 실패하면 `/etc/rancher/k3s`가 남아 `--before`가 막힌다. `--k3s`를 그대로 다시 실행하거나, `k3s-uninstall.sh`로 지우고 잔여 경로가 없는지 본 뒤 1부터 다시 한다.

이후 `kubectl`은 이 kubeconfig로 부른다.

```bash
export KUBECONFIG=~/.kube/<KUBE_CONTEXT>.yaml   # prod는 homelab, vm은 homelab-vm
kubectl config current-context
```

파괴적인 명령 전에는 `host/verify.sh --cluster <이름> --identity`로 context와 노드 이름이 맞는지 본다. VM 검증 기간에는 두 클러스터가 함께 있다.

운영자 기기에서 tailnet으로 쓰려면 이 파일을 복사하고 `server`를 `https://<MagicDNS 이름>:6443`으로 바꾼다. 그 이름은 k3s SAN에 들어 있다. 저장소와 Infisical에는 두지 않는다.

### 1.1 파드 egress 규칙(노드 nftables)

새 파드는 시작 직후 약 1초 동안 NetworkPolicy가 붙기 전이라 egress가 모두 열린다(설계 B.8 E5). `--egress`는 그 틈을 노드에서 막는다. 파드 대역(`POD_CIDR`)에서 노드 밖으로 나가는 forward만 보고, 아래 허용이 아니면 버린다. 노드 자신의 트래픽은 건드리지 않는다. 규칙 원본은 `host/egress/egress.nft`, 값은 `host/clusters/<이름>.env`(`NODE_IP`, `POD_CIDR`, `SERVICE_CIDR`)와 `host/versions.env`(`NODE_UPSTREAM_DNS`)다.

| 허용(순서대로) | 쓰는 곳 |
|---|---|
| 들어온 연결의 반환(`ct established,related`), 파드·서비스 대역 | svclb·hostPort 응답, 파드끼리, DNS·DB·Valkey |
| `NODE_IP` TCP 6443·10250 | kube API, kubelet 수집(지금 경로에서는 INPUT이라 이 줄에 오지 않는다) |
| `NODE_UPSTREAM_DNS`(1.1.1.1·9.9.9.9) UDP·TCP 53 | CoreDNS 업스트림, AdGuard bootstrap |
| 공개 TCP 443, 공개 TCP·UDP 7844 | R2·Infisical·GitHub·Telegram·Tailscale DERP, cloudflared 터널 |

그 밖은 모두 버린다: tailnet `100.64.0.0/10`, LAN 사설 대역, link-local, 공개 대역의 443·7844 밖 포트. Tailscale direct(UDP 41641)·STUN(3478)도 열지 않아 Tailscale 프록시는 DERP 443으로만 붙는다.

**이미 도는 클러스터에 켜기.** k3s를 다시 시작하지 않는다. 0.0의 main 확인 블록을 먼저 돌린다.

```bash
sudo host/install.sh --cluster <이름> --egress \
  && host/verify.sh --cluster <이름>
```

`--egress`는 렌더한 규칙을 `nft -c`로 먼저 검사하고, 올린 뒤 커널의 표 모양(forward hook, 파드 대역만 넘김, 첫 줄 established, 끝 줄 drop)을 확인하고 표를 출력한다. 다시 실행하면 `reload`로 표를 통째 바꾼다(규칙이 빈 순간 없음).

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
| 커널 규칙 | `sudo nft list table inet homelab_egress` | 허용 줄의 카운터가 오른다(6443·10250 줄은 0이 정상) |

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
# 대조: 노드에서는 열린다
for t in "$LAN_GW 80" "$LAN_GW 443" "1.1.1.1 80" "github.com 22" ${TS_IP:+"$TS_IP 443"}; do
  nc -z -w 3 $t || { echo "대조 실패(노드에서도 닫힘): $t"; exit 1; }
done
kubectl create namespace egress-probe
kubectl label namespace egress-probe pod-security.kubernetes.io/enforce=restricted
sed -e "s/@LAN_GW@/$LAN_GW/g" -e "s/@NODE_IP@/$NODE_IP/g" -e "s/@TS_IP@/$TS_IP/g" <<'YAML' | kubectl -n egress-probe apply -f -
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
          c open node-api-input @NODE_IP@ 6443
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

첫 줄(`lan-gw`)은 컨테이너가 시작하자마자 나간다. `node-api-input`이 열리는 것은 정상이다(아래 한계 1). 실패하면 ns가 남으니 본 뒤 `kubectl delete namespace egress-probe`로 지운다.

**남는 한계.**

1. 파드 → 노드 자신은 INPUT 경로라 이 규칙 밖이다. 1초 공백 동안 새 파드는 노드 IP의 열린 포트(sshd 22, kube API 6443, kubelet 10250)와 노드의 tailnet 주소에 닿는다. NetworkPolicy도 이 경로를 막지 못한다(설계 B.8 E4). 각 포트의 인증은 남는다.
2. 업스트림 DNS 53(1.1.1.1·9.9.9.9)은 모든 파드에 열려 있다. AdGuard를 거치지 않는 평문 DNS와 그 위의 유출 경로가 남는다.
3. 공개 443·7844는 모든 파드에 열려 있다(정상 정책도 대부분 공개 443을 연다).
4. Tailscale 프록시는 DERP로만 붙는다(direct·STUN 막음). 지연이 늘 수 있다. 공개 UDP 443(QUIC)도 막혀 TCP로 넘어간다.
5. 부팅 때 규칙이 못 올라와도 k3s는 뜬다(fail-open, 유닛에 `Requires`를 두지 않음). 그때는 NetworkPolicy만 남은 이전 상태이고 `verify`가 유닛 상태로 잡는다.

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

**vm 분기(시나리오 13)는 이 절에서 아래를 이 순서로 더 한다**(설계 C.3.3 "vm 분기의 추가 단계"). T11·T13이 명령을 채운다.

1. ESO Secret 전에, 운영 클러스터의 ExternalSecret 키 목록과 `homelab-dev`의 키를 대조한다. 빠진 키가 0이어야 한다. 하나라도 빠지면 멈춘다. 값은 출력하지 않는다.
2. ESO Secret의 값은 `eso-homelab-dev`이다.
3. root apply 전에 복구 원본 R2 읽기 자격 Secret을 넣는다. 복구가 끝나면 지운다.

### 2.3 root apply

```bash
kubectl apply -f platform/root/root-<이름>.yaml
```

- root가 `argocd` Application까지 소유한다. 이후 Argo CD 변경은 PR → main이다. Argo CD는 공개 webhook 없이 main을 60초마다 본다(jitter 0).
- **예외: root Application 자신은 Git에서 저절로 맞춰지지 않는다.** `root-prod.yaml`·`root-vm.yaml`은 차트의 `templates/` 밖에 있어 root가 렌더하지 않기 때문이다(운영 root가 VM root를 만들지 않게 하려는 배치). 그래서 이 두 파일(source, `valueFiles`, sync 정책)을 바꾸는 PR은 병합 뒤 `kubectl apply -f platform/root/root-<이름>.yaml`로 다시 적용하고, 그 PR 본문에 이 단계를 적는다. `templates/`와 값 파일 변경은 다시 적용할 필요가 없다.

## 3. 확인

다른 블록처럼 한 항목이라도 틀리면 멈추고, 모든 항목(prod의 Tailscale DNS 포함)이 맞을 때만 마지막에 `확인 통과`를 출력한다. 재부팅 뒤 새 셸에서도 이 블록을 그대로 돌린다(`KUBECONFIG`를 안에서 잡는다).

```bash
bash -euo pipefail <<'EOF'
export KUBECONFIG=~/.kube/<KUBE_CONTEXT>.yaml   # prod는 homelab, vm은 homelab-vm
host/preflight.sh --cluster <이름> --after      # 스왑, 타임존, resolved 스텁, resolv.conf, 링크가 DHCP DNS 거부(drop-in 로드)
host/verify.sh --cluster <이름>                 # 노드 Ready, k3s 버전, node-args, SAN, local-retain, egress
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
