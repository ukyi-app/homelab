# NUC 임시 VM: 시나리오 13 검증 클러스터 만들기와 지우기

시나리오 13(빈 환경 재구축 + DB 복구)의 `vm` 클러스터를 운영 NUC 안의 임시 KVM VM으로 세우고, 시험 뒤 흔적 없이 지운다. 결정은 사용자(2026-10-26, NUC 임시 VM, tailnet 밖, 시험 뒤 삭제)와 lead(2026-10-26, libvirt NAT, NUC 본체 브리지 변경 없음, 운영자 확인은 NUC에서)다. 근거는 설계 E8 "VM 격리"와 F D-12다.

모든 단계는 사람이 한다. NUC에서 sudo가 필요한 단계(1·6절)와 VM 안에서 sudo가 필요한 단계(2절)가 있다. 블록은 bootstrap.md 0.0처럼 `bash -euo pipefail`로 돌리고, 실패하면 다음 블록으로 가지 않는다. 명령은 NUC의 작업 사본(저장소 루트)에서 한다.

## 0. 값과 근거

| 무엇 | 값 | 어디서 쓰나 |
|---|---|---|
| libvirt 도메인(VM) | `homelab-vm` | 1·6절 |
| libvirt 네트워크 | `homelab-vm`, 브리지 `virbr-hlvm`, 192.168.122.0/24, NAT 출구 = `prod.env`의 `NODE_IFACE` | 1·6절 |
| VM MAC → 주소 | `52:54:00:13:00:10` → `192.168.122.10`(DHCP 예약) | `vm.env`의 `NODE_IP` |
| VM 노드 이름·인터페이스 | `vm-node`, `enp1s0` | `vm.env`의 `NODE_NAME`·`NODE_IFACE` |
| 크기 | vCPU 4, 메모리 16 GiB, 디스크 80 GiB(qcow2, 쓴 만큼만 찬다) | 1.4 |
| 디스크·seed | `/var/lib/libvirt/images/homelab-vm.qcow2`, `homelab-vm-seed.iso` | 1.3, 6절 |
| 이미지 | Ubuntu 26.04 클라우드 이미지 `release-20261016`, sha256 `5645d031…7eb5`(1.3에 전체) | 1.3 |
| NUC 쪽 상태 | `~/.local/state/homelab-vm/`(새로 깐 패키지 목록, VM SSH known_hosts). 저장소 밖 | 1·6절 |
| VM kubeconfig(NUC) | `~/.kube/homelab-vm.yaml`, context `homelab-vm` | 3·4절 |

**크기 근거(2026-10-26 NUC 실측).** NUC는 14코어(Core Ultra 5 225H, 하이퍼스레딩 없음), 메모리 60 GiB에 MemAvailable 46 GiB, 부하 평균 1.4~2.7이다. 운영 노드 요청은 CPU 1065m(7%), 메모리 3302Mi이고 메모리 limit 합은 8554Mi다.

- **vCPU 4:** VM이 다 써도 운영에 10코어가 남는다. 단일 노드 k3s와 복구 Job에는 충분하다.
- **메모리 16 GiB:** VM 안 워크로드가 운영과 같으므로 운영 limit 합 8.5 GiB에 kubelet 예약 1 GiB(`system-reserved`), 축출 여유 0.5 GiB, OS를 더하고 남게 잡았다. 만들 때 MemAvailable이 32 GiB 이상인지 본다. 그러면 VM을 띄운 뒤에도 운영에 16 GiB 이상 남는다.
- **디스크 80 GiB:** 운영 PV 요청 합이 58 GiB다. local-path는 크기를 강제하지 않아 실제 사용은 더 작고, qcow2는 쓴 블록만 NUC 디스크(여유 512 GiB)를 쓴다.

**네트워크 근거.**

- **NAT라 NUC 본체 설정을 바꾸지 않는다.** 라우팅 NAT라 Wi-Fi(`wlo1`)에서도 되고 브리지를 만들지 않는다. libvirt NAT는 밖에서 VM으로 새 연결을 넘기지 않아 VM은 NUC에서만 닿는다. 그래서 운영자 기기의 LAN 접근 대신 NUC에서 SSH·kubeconfig·port-forward로 확인한다(설계 E8 VM 위치).
- **출구를 NUC의 LAN 인터페이스로 묶는다(`<forward mode='nat' dev=…>`).** 묶지 않으면 VM이 100.64.0.0/10으로 보낸 패킷이 NUC의 tailscale0로 라우팅되고, libvirt masquerade가 출발지를 NUC의 tailnet 주소로 바꾼다. 그러면 VM이 tailnet에서 NUC(`tag:nuc`)로 보이고, ACL의 `tag:nuc → tag:k8s:443`으로 운영 내부 UI에 닿는다. 설계 E8 VM 격리 4번이 막으려는 길이다. `dev`를 주면 libvirt가 그 인터페이스 밖으로 나가는 VM forward를 거부한다. 1.5에서 확인한다.
- **운영 nftables(P4)와 겹치지 않는다.** P4 규칙은 forward에서 출발지 10.42.0.0/16만 거른다. VM 트래픽은 VM 안 flannel이 파드 주소를 VM 노드 주소로 바꾼 뒤 나오므로 NUC에서 출발지가 192.168.122.10이라 그 규칙에 걸리지 않는다. libvirt 규칙은 `virbr-hlvm`을 지나는 패킷만 보므로 운영 파드 트래픽(cni0 → wlo1)에 닿지 않는다.
- **192.168.122.0/24를 공개 저장소에 적어도 된다.** libvirt가 모든 호스트에 같은 값으로 까는 기본 NAT 대역이고 NUC 안에서만 쓰인다. LAN·tailnet 주소가 아니라 위치나 신원을 드러내지 않는다(D-23). MAC 접두 52:54:00은 QEMU 기본이다.
- 같은 대역을 쓰는 libvirt `default` 네트워크는 1.2에서 내리고 지운다. 둘이 함께 뜨지 못한다.
- host-config 전 VM의 DNS는 DHCP가 주는 192.168.122.1(libvirt dnsmasq)이다. NUC의 servicelb가 노드 :53을 AdGuard로 DNAT하므로 실제로는 운영 AdGuard가 답할 수 있다(추측). host-config 뒤에는 1.1.1.1·9.9.9.9로 바로 간다. 시나리오 14(AdGuard 정지)와 겹쳐 돌리지 않는다.

## 1. 만들기 (NUC, sudo)

### 1.1 확인과 패키지

시험 전에 NUC에 가상화 패키지가 없어야 한다. 6절은 이 블록이 새로 깐 패키지만 정확히 지워 NUC를 시험 전 상태로 돌린다(D-12: NUC에 가상화 구성 요소를 남기지 않는다).

```bash
bash -euo pipefail <<'EOF'
state="$HOME/.local/state/homelab-vm"
for p in libvirt-daemon-system qemu-system-x86 virt-install; do
  if [ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null | cut -c2)" = i ]; then
    echo "${p}가 이미 깔려 있다. 6절이 시험 전부터 있던 것까지 지우게 된다. 멈춘다"; exit 1
  fi
done
test -c /dev/kvm || { echo "/dev/kvm이 없다(BIOS의 VT-x를 본다)"; exit 1; }
# VM에 16 GiB를 주고도 운영에 16 GiB 이상 남아야 한다(0절 크기 근거)
awk '/^MemAvailable:/ { exit !($2 >= 32 * 1024 * 1024) }' /proc/meminfo || { echo "MemAvailable이 32 GiB보다 작다"; exit 1; }
install -d -m 0700 "$state"
sudo apt-get update
# 버전은 2026-10-26 resolute 저장소의 후보로 고정한다. 저장소가 넘어가 이 버전이 없으면 설치가 실패한다.
# 그때는 apt-cache policy로 새 후보를 보고 이 목록을 PR로 고친다.
# systemd-container는 지금 깔린 systemd와 같은 버전으로 묶는다. 후보를 그대로 받으면 systemd·udev·resolved까지
# 새 버전으로 올라가 운영 노드의 systemd가 재실행되고 resolved가 다시 시작된다(2026-10-26 apt-get -s로 확인).
sysd="$(dpkg-query -W -f='${Version}' systemd)"
pkgs=(qemu-system-x86=1:10.2.1+ds-1ubuntu3.3 qemu-utils=1:10.2.1+ds-1ubuntu3.3
  libvirt-daemon-system=12.0.0-1ubuntu5.6 libvirt-clients=12.0.0-1ubuntu5.6
  virt-install=1:5.1.0-1 cloud-image-utils=0.33-1build1 "systemd-container=${sysd}")
# 먼저 흉내만 낸다. 이미 깔린 패키지를 하나라도 올리거나 지우면 운영 노드가 바뀌므로 멈춘다
sim="$(LC_ALL=C apt-get -s install --no-install-recommends "${pkgs[@]}")"
if ! grep -Eq '^0 upgraded, [0-9]+ newly installed, 0 to remove' <<<"$sim"; then
  grep -E '^Remv |^Inst [^ ]+ \[' <<<"$sim" || true
  echo "기존 패키지가 바뀐다. 멈춘다"; exit 1
fi
dpkg-query -W -f='${Package}\n' | LC_ALL=C sort >"$state/packages-before"
# needrestart를 목록만 내는 모드로 둔다. 기본 모드는 옛 라이브러리를 쥔 서비스(k3s 포함)를 이 설치 김에 다시 시작한다.
# noninteractive: debconf가 묻지 않게 한다. 이 bash의 stdin은 스크립트라 물으면 다음 줄을 답으로 먹는다
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y --no-install-recommends "${pkgs[@]}"
dpkg-query -W -f='${Package}\n' | LC_ALL=C sort >"$state/packages-after"
LC_ALL=C comm -13 "$state/packages-before" "$state/packages-after" >"$state/packages-new"
grep -qx libvirt-daemon-system "$state/packages-new"
echo "새로 깐 패키지 $(wc -l <"$state/packages-new")개. 6절이 이 목록만 지운다: $state/packages-new"
EOF
```

2026-10-26 흉내 결과는 새 패키지 78개, 올림 0, 지움 0이었다.

### 1.2 libvirt 네트워크

`virsh`는 모두 sudo로 부른다. 사람을 `libvirt` 그룹에 넣지 않는다(그 그룹은 root와 같고, 시험 뒤 되돌릴 것이 하나 는다).

```bash
bash -euo pipefail <<'EOF'
iface="$(. host/clusters/prod.env && echo "$NODE_IFACE")"
# NAT 출구가 실제 기본 경로와 같아야 VM이 밖으로 나간다
test "$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' | sort -u)" = "$iface" \
  || { echo "기본 경로가 ${iface}가 아니다. prod.env NODE_IFACE와 ip route를 본다"; exit 1; }
# 패키지가 같은 대역(192.168.122.0/24)의 default 네트워크를 만들고 켠다. 이 시험은 쓰지 않으므로 내리고 지운다
if info="$(sudo virsh net-info default 2>/dev/null)"; then
  if grep -Eq '^Active:[[:space:]]+yes' <<<"$info"; then sudo virsh net-destroy default; fi
  sudo virsh net-undefine default
fi
xml="$(mktemp)"; trap 'rm -f "$xml"' EXIT
# dev: NAT 출구를 NUC의 LAN 인터페이스로만 묶는다. 없으면 VM이 tailscale0로 나가 NUC의 tailnet 신원을 쓴다(0절)
# autostart는 켜지 않는다. 임시 VM이라 NUC가 재부팅되면 사람이 다시 켠다(1.5)
cat >"$xml" <<XML
<network>
  <name>homelab-vm</name>
  <forward mode='nat' dev='${iface}'/>
  <bridge name='virbr-hlvm' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.100' end='192.168.122.254'/>
      <host mac='52:54:00:13:00:10' name='vm-node' ip='192.168.122.10'/>
    </dhcp>
  </ip>
</network>
XML
sudo virsh net-define "$xml"
sudo virsh net-start homelab-vm
grep -Eq "<forward [^>]*dev='${iface}'" <<<"$(sudo virsh net-dumpxml homelab-vm)"
EOF
```

`<host>`가 DHCP 예약이다. k3s의 node-ip는 설치 때만 정해지므로 VM 주소가 바뀌면 k3s가 뜨지 못한다. 예약 주소는 범위(`.100`~`.254`) 밖에 두어 다른 임대와 겹치지 않는다.

### 1.3 이미지·디스크·seed

이미지는 버전 디렉터리와 sha256으로 고정한다. 이 sha256은 2026-10-26에 `SHA256SUMS`를 Ubuntu 클라우드 이미지 서명 키(`D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81`, 패키지 `ubuntu-keyring`의 `ubuntu-cloudimage-keyring.gpg`)로 검증해 옮겼다. 그 디렉터리가 미러에서 빠지면 새 `release-*`의 `SHA256SUMS`를 같은 키로 검증하고 이 두 값을 PR로 고친다.

cloud-init 값(사용자, SSH 공개 키, 콘솔 비밀번호 해시)은 실행 때 만들어 seed에만 넣는다. 저장소와 셸 기록에 남기지 않는다. 비밀번호는 콘솔 로그인과 VM 안 sudo에 쓴다(SSH는 키만). host-config가 VM 네트워크를 다시 구성하다 SSH가 끊기면 콘솔이 유일한 길이다.

```bash
bash -euo pipefail <<'EOF'
url=https://cloud-images.ubuntu.com/releases/resolute/release-20261016/ubuntu-26.04-server-cloudimg-amd64.img
sha=5645d0318ad21f643ebb1ac4567514620e9893380b07b0201fda163baa5b7eb5
pub="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
test -f "$pub" || { echo "SSH 공개 키 ${pub}가 없다. SSH_PUBKEY_FILE로 고른다"; exit 1; }
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$w/base.img" "$url"
echo "${sha}  $w/base.img" | sha256sum -c --quiet -
# 비밀번호는 화면·argv·파일에 두지 않는다. 해시(SHA-512 crypt)만 seed로 간다
# 이 bash의 stdin은 스크립트 자체라 터미널에서 읽는다
read -rs -p 'VM 콘솔·sudo 비밀번호: ' pw1 </dev/tty; echo
read -rs -p '한 번 더: ' pw2 </dev/tty; echo
[ -n "$pw1" ] && [ "$pw1" = "$pw2" ] || { echo "비었거나 둘이 다르다"; exit 1; }
PW_HASH="$(printf '%s' "$pw1" | openssl passwd -6 -stdin)"; unset pw1 pw2
SSH_PUB="$(head -n 1 "$pub")"
export PW_HASH SSH_PUB
# 사용자 ubuntu는 sudo 그룹(비밀번호 sudo)이다. 클라우드 이미지 기본 사용자의 NOPASSWD sudo는 쓰지 않는다.
# JSON은 YAML이라 cloud-config로 읽힌다. 값을 jq가 넣어 따옴표·특수 문자가 깨지지 않는다
{ echo '#cloud-config'
  jq -n '{hostname: "vm-node", ssh_pwauth: false, disable_root: true,
          users: [{name: "ubuntu", groups: ["sudo"], shell: "/bin/bash", lock_passwd: false,
                   hashed_passwd: env.PW_HASH, ssh_authorized_keys: [env.SSH_PUB]}]}'
} >"$w/user-data"
printf 'instance-id: homelab-vm-%s\nlocal-hostname: vm-node\n' "$(date +%Y%m%d%H%M%S)" >"$w/meta-data"
# MAC으로 찾아 enp1s0으로 이름을 고정한다. netplan ID가 곧 10-netplan-enp1s0.network 이름이고,
# host/etc의 networkd drop-in 디렉터리가 그 이름에 묶인다(vm.env NODE_IFACE)
cat >"$w/network-config" <<'NET'
version: 2
ethernets:
  enp1s0:
    match:
      macaddress: "52:54:00:13:00:10"
    set-name: enp1s0
    dhcp4: true
NET
cloud-localds --network-config="$w/network-config" "$w/seed.iso" "$w/user-data" "$w/meta-data"
# 뒷받침 파일 없는 독립 qcow2로 만든다. 받은 이미지는 블록 끝에서 지운다
sudo qemu-img convert -O qcow2 "$w/base.img" /var/lib/libvirt/images/homelab-vm.qcow2
sudo qemu-img resize /var/lib/libvirt/images/homelab-vm.qcow2 80G
sudo install -m 0600 -o root -g root "$w/seed.iso" /var/lib/libvirt/images/homelab-vm-seed.iso
EOF
```

seed는 VM을 지울 때까지 붙여 둔다. 떼면 다음 부팅에 cloud-init이 새 인스턴스로 보고 SSH 호스트 키 등을 다시 만든다.

### 1.4 VM 시작

```bash
bash -euo pipefail <<'EOF'
# osinfo-db(0.20250606)에 ubuntu26.04가 없어 24.04에서 파생된 일반 항목 linux2024를 쓴다.
# q35 + virtio NIC라 인터페이스가 enp1s0이고, network-config가 MAC으로 같은 이름을 고정한다.
# --autostart를 주지 않는다. 임시 VM이 NUC 재부팅 뒤 저절로 자원을 쓰지 않게 한다
sudo virt-install --name homelab-vm --osinfo linux2024 --machine q35 --cpu host-passthrough \
  --vcpus 4 --memory 16384 \
  --disk path=/var/lib/libvirt/images/homelab-vm.qcow2,format=qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/homelab-vm-seed.iso,device=cdrom \
  --network network=homelab-vm,mac=52:54:00:13:00:10,model=virtio \
  --graphics none --console pty,target_type=serial \
  --import --noautoconsole
EOF
```

### 1.5 접속과 격리 확인

VM SSH는 NUC 전용 known_hosts를 쓴다. 6절이 상태 디렉터리째 지우므로 `~/.ssh/known_hosts`에 흔적이 남지 않는다. 이 NAT 대역은 NUC 밖에서 닿지 않아 첫 접속의 호스트 키를 그대로 받아도 끼어들 자리가 NUC root뿐이다. 새 셸마다 이 함수를 먼저 정의한다.

```bash
vmssh() { ssh -o UserKnownHostsFile="$HOME/.local/state/homelab-vm/known_hosts" -o StrictHostKeyChecking=accept-new ubuntu@192.168.122.10 "$@"; }
```

```bash
bash -euo pipefail <<'EOF'
# -n: 이 bash의 stdin은 스크립트라, 없으면 ssh가 남은 줄을 VM으로 보내 버린다
vmssh() { ssh -n -o UserKnownHostsFile="$HOME/.local/state/homelab-vm/known_hosts" -o StrictHostKeyChecking=accept-new ubuntu@192.168.122.10 "$@"; }
i=0
until timeout 3 bash -c '</dev/tcp/192.168.122.10/22' 2>/dev/null; do
  [ "$i" -lt 60 ] || { echo "5분 안에 SSH가 열리지 않았다. sudo virsh console homelab-vm으로 본다"; exit 1; }
  sleep 5; i=$((i + 1))
done
# cloud-init이 끝났는지, vm.env 값(이름·인터페이스·주소)이 그대로인지 본다.
# status --wait는 경고만 있어도 2로 끝나므로 종료 코드 대신 출력을 본다
st="$(vmssh 'cloud-init status --wait' || true)"
grep -qx 'status: done' <<<"$st" || { echo "cloud-init: ${st}"; exit 1; }
test "$(vmssh hostname)" = vm-node
grep -qF ' 192.168.122.10/24 ' <<<"$(vmssh 'ip -4 -o addr show dev enp1s0')"
# 격리: VM에서 tailnet 주소로 가는 길이 막혀야 한다(0절 NAT 출구). 100.100.100.100은 NUC의 tailscaled가 답하는 주소다
if vmssh "timeout 5 bash -c '</dev/tcp/100.100.100.100/53'" 2>/dev/null; then
  echo "VM이 tailnet 주소에 닿는다. 1.2의 forward dev를 본다"; exit 1
fi
# 밖으로는 나가야 한다
vmssh 'curl -fsS -o /dev/null --max-time 10 https://github.com'
echo "VM 준비 통과"
EOF
```

- **콘솔:** `sudo virsh console homelab-vm`(나가기 `Ctrl+]`), 사용자 `ubuntu`와 1.3의 비밀번호.
- **NUC가 재부팅됐으면:** `sudo virsh net-start homelab-vm && sudo virsh start homelab-vm`. 둘 다 autostart가 꺼져 있다.

## 2. VM 안 호스트 단계

`vmssh`로 들어가 VM 안에서 [bootstrap.md](bootstrap.md) 0.0(패키지, 작업 사본, main 일치)을 하고 1절을 `<이름>` = `vm`으로 한다. 순서는 preflight → host-config → k3s → verify다. 1절이 기준이다. 그 절에 단계가 더해지면(예: 노드 egress) 그 순서를 따른다.

```bash
host/preflight.sh --cluster vm --before \
  && sudo host/install.sh --cluster vm --host-config \
  && host/preflight.sh --cluster vm --after \
  && sudo host/install.sh --cluster vm --k3s \
  && host/verify.sh --cluster vm
```

- `--host-config`가 `enp1s0`을 다시 구성하는 약 2초 동안 SSH가 멈췄다 돌아온다. DHCP 예약이라 주소는 그대로다. 돌아오지 않으면 콘솔로 본다.
- `install.sh`가 VM 안 `~/.kube/homelab-vm.yaml`(context `homelab-vm`, server 127.0.0.1)을 쓴다.

## 3. kubeconfig를 NUC로

운영자 확인과 4절은 NUC에서 한다. VM kubeconfig는 운영 파일과 **다른 파일**(`~/.kube/homelab-vm.yaml`)로 둔다. 운영 파일과 콜론으로 합치지 않는다. 합치면 current-context가 앞 파일의 것이 되어 `--context` 없이 부른 명령이 다른 클러스터로 간다(B.8 E2). VM 블록은 모두 첫 두 줄에서 `KUBECONFIG`를 이 파일로 고정하고 정체성(context `homelab-vm`, 노드 `vm-node` 하나)을 본다.

```bash
bash -euo pipefail <<'EOF'
vmssh() { ssh -n -o UserKnownHostsFile="$HOME/.local/state/homelab-vm/known_hosts" -o StrictHostKeyChecking=accept-new ubuntu@192.168.122.10 "$@"; }
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
vmssh 'cat .kube/homelab-vm.yaml' >"$tmp"
# install.sh가 각인한 파일인지 본다. 다른 클러스터의 파일이면 여기서 멈춘다
test "$(KUBECONFIG="$tmp" kubectl config current-context)" = homelab-vm
# VM 안 server는 127.0.0.1이다. NUC에서는 VM의 NAT 주소로 간다(vm.env NODE_IP, k3s TLS SAN에 있다)
KUBECONFIG="$tmp" kubectl config set-cluster homelab-vm --server=https://192.168.122.10:6443 >/dev/null
install -m 0600 "$tmp" "$HOME/.kube/homelab-vm.yaml"
export KUBECONFIG="$HOME/.kube/homelab-vm.yaml"
host/verify.sh --cluster vm --identity
EOF
```

## 4. Argo CD와 root (NUC)

NUC 작업 사본이 main과 같은지 bootstrap.md 0.0의 두 번째 블록으로 본 뒤, 같은 셸에서 대상을 VM으로 고정한다.

```bash
export KUBECONFIG=~/.kube/homelab-vm.yaml && host/verify.sh --cluster vm --identity
```

그 셸에서 [bootstrap.md](bootstrap.md) 2.1 → 2.2(vm 분기 1~4단계)를 한다. vm 분기의 블록은 스스로 대상을 다시 고정한다. 2.2 vm 분기 3단계 전에 [restore.md](restore.md) 3절의 VM 복구 PR이 main에 병합돼 있어야 한다.

## 5. 확인

- VM 안(`vmssh`)에서 bootstrap.md 3절 블록을 `<이름>` = `vm`, `<KUBE_CONTEXT>` = `homelab-vm`으로 돌린다. `host/preflight.sh`가 VM 호스트를 보므로 NUC에서 돌리지 않는다.
- 공개 경로·시험 터널(설계 E8 VM 격리 5번)과 복구 확인(restore.md 3절)은 NUC에서 `KUBECONFIG=~/.kube/homelab-vm.yaml`로 한다. port-forward도 NUC의 127.0.0.1에 열린다.

## 6. 지우기 (NUC, sudo)

VM 밖 자원(tailnet의 `vm-*` 기기, VM 전용 R2 버킷, `eso-homelab-dev` client secret, 읽기 전용 R2 토큰, values-vm 복구 원본 정리 PR)은 설계 E8 "되돌리는 방법"을 따른다. VM을 먼저 지우면 VM operator가 기기를 정리하지 못하므로 `vm-*` 기기는 Tailscale 콘솔에서 지운다. 이 절은 NUC에 남는 것을 0으로 만든다.

VM은 운영 DB 사본을 담고 있다. 지운 뒤에는 되돌릴 수 없다. 남길 증거(결과표, 로그)를 먼저 옮긴다.

### 6.1 VM·디스크·네트워크

```bash
bash -euo pipefail <<'EOF'
if sudo virsh dominfo homelab-vm >/dev/null 2>&1; then
  if [ "$(sudo virsh domstate homelab-vm)" != "shut off" ]; then sudo virsh destroy homelab-vm; fi
  sudo virsh undefine homelab-vm
fi
sudo rm -f /var/lib/libvirt/images/homelab-vm.qcow2 /var/lib/libvirt/images/homelab-vm-seed.iso
if info="$(sudo virsh net-info homelab-vm 2>/dev/null)"; then
  if grep -Eq '^Active:[[:space:]]+yes' <<<"$info"; then sudo virsh net-destroy homelab-vm; fi
  sudo virsh net-undefine homelab-vm
fi
rm -f "$HOME/.kube/homelab-vm.yaml"
EOF
```

### 6.2 패키지와 libvirt 잔여

1.1이 기록한 목록만 지운다. 그사이 다른 패키지가 이 목록에 기대게 됐으면 그것까지 지워지므로 먼저 흉내로 보고 멈춘다. libvirt 경로는 1.1이 "시험 전에 libvirt가 없었다"를 확인했으므로 이 시험이 만든 것뿐이다.

```bash
bash -euo pipefail <<'EOF'
state="$HOME/.local/state/homelab-vm"
grep -qx libvirt-daemon-system "$state/packages-new"
mapfile -t new <"$state/packages-new"
sim="$(LC_ALL=C apt-get -s purge "${new[@]}" | awk '$1 == "Purg" { print $2 }' | LC_ALL=C sort)"
if [ "$sim" != "$(LC_ALL=C sort "$state/packages-new")" ]; then
  diff <(LC_ALL=C sort "$state/packages-new") <(printf '%s\n' "$sim") || true
  echo "목록과 다른 패키지가 지워진다. 멈춘다"; exit 1
fi
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get purge -y "${new[@]}"
sudo rm -rf /etc/libvirt /var/lib/libvirt /var/log/libvirt /var/cache/libvirt
# libvirt nft 테이블은 실행 중 상태라 패키지를 지워도 재부팅 전까지 남을 수 있다. libvirt 것만 지운다
sudo nft list tables | awk '$3 ~ /^libvirt/ { print $2, $3 }' | while read -r fam name; do
  sudo nft delete table "$fam" "$name"
done
EOF
```

### 6.3 남은 것 0 확인

```bash
bash -euo pipefail <<'EOF'
state="$HOME/.local/state/homelab-vm"
left=0
while IFS= read -r p; do
  s="$(dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null || true)"
  if [ -n "$s" ] && [ "${s:1:1}" != n ]; then echo "패키지가 남았다: ${p} (${s})"; left=1; fi
done <"$state/packages-new"
for d in /etc/libvirt /var/lib/libvirt /var/log/libvirt /var/cache/libvirt; do
  if sudo test -e "$d"; then echo "경로가 남았다: ${d}"; left=1; fi
done
for b in virbr-hlvm virbr0; do
  if ip link show "$b" >/dev/null 2>&1; then echo "브리지가 남았다: ${b}"; left=1; fi
done
# 출력을 먼저 받는다. grep -q가 일찍 끝나면 쓰는 쪽이 SIGPIPE로 죽고 pipefail이 "없음"으로 읽는다
if grep -q libvirt <<<"$(sudo nft list tables)"; then echo "libvirt nft 테이블이 남았다"; left=1; fi
if grep -q LIBVIRT <<<"$(sudo iptables-save)"; then echo "libvirt iptables 체인이 남았다(재부팅하면 사라진다)"; left=1; fi
if [ -e "$HOME/.kube/homelab-vm.yaml" ]; then echo "VM kubeconfig가 남았다"; left=1; fi
test "$left" -eq 0
rm -rf "$state"
echo "남은 것 0"
EOF
```

패키지가 만든 시스템 계정(`libvirt-qemu`, `libvirt-dnsmasq` 등)은 Debian 정책상 purge해도 남는다. 로그인 셸이 없고 파일을 갖지 않아 그대로 둔다.
