# 부트스트랩: 빈 호스트에서 k3s와 Argo CD까지

새 호스트(또는 k3s를 지운 호스트)에 클러스터를 세우는 순서다. 운영 NUC는 2026-10-19 T07에서 이 순서로 세웠다. 시나리오 13(VM에서 다시 세우기)의 입력이기도 하다. 근거는 설계 [C.3.2](../plans/2026-10-17-homelab-rebuild/platform/design.md)(호스트·k3s)와 C.3.3(Argo CD)이다.

이 문서 밖의 수동 단계를 두지 않는다. 실행하다 문서와 다르게 한 것이 있으면 이 문서를 먼저 고친다.

## 0. 클러스터 이름 고르기

| 클러스터 | 이름 | 호스트 값 | 클러스터 값 | root 파일 |
|---|---|---|---|---|
| 운영 NUC | `prod` | `host/clusters/prod.env` | `platform/root/values-prod.yaml` | `platform/root/root-prod.yaml` |
| 시나리오 13 VM | `vm` | `host/clusters/vm.env` | `platform/root/values-vm.yaml` | `platform/root/root-vm.yaml` |

아래 `<이름>`은 이 이름 하나다. 스크립트와 매니페스트에는 클러스터 이름 분기가 없고, 값 파일만 바뀐다.

- `vm.env`·`values-vm.yaml`의 `CHANGE_ME`는 VM을 준비할 때 채운다. 남아 있으면 스크립트가 멈춘다.
- VM 호스트는 tailnet에 넣지 않는다(`TAILNET_JOIN=false`). VM 접근은 LAN 주소나 콘솔로 한다.
- 작업 사본은 `origin/main`과 같아야 하고, `host/`에 커밋 안 한 변경이 없어야 한다. install·verify가 확인하고 멈춘다.

### 0.1 운영 NUC를 OS부터 다시 설치했을 때만

tailnet에 이미 있으면 건너뛴다.

1. Tailscale 콘솔에서 옛 NUC 기기를 먼저 지운다. 남아 있으면 새 이름에 `-1`이 붙고, 나중에 지워도 이름이 돌아오지 않는다.
2. `sudo tailscale up --hostname=<prod.env의 NODE_NAME>`으로 등록한다.
3. 이름을 확인한다. 아래 명령의 첫 라벨이 `prod.env`의 `NODE_NAME`과 같아야 한다.

   ```bash
   tailscale status --self --peers=false --json | jq -r '.Self.DNSName | rtrimstr(".")'
   ```

   전체 이름은 tailnet 이름을 담으므로 공개 저장소에 적지 않는다.
4. Tailscale 콘솔에서 이 기기의 키 만료를 해제한다.
5. Tailscale IP가 바뀌었으면 DNS Terraform(`infra/tailscale-dns`, T08a 이후)을 apply해 전역 nameserver의 NUC 주소를 갱신한다.

### 0.2 사람 확인

- 공유기 DHCP 예약이 `NODE_IP`를 이 기기에 고정하는가. k3s의 node-ip는 설치 때만 정해진다(2026-10-19 운영: 예약 확인, 공유기 DNS 폴백 1.1.1.1).
- LAN SSH는 키로만 들어온다(sshd drop-in이 비밀번호 로그인을 끈다). 새 VM은 키나 콘솔을 먼저 마련한다.

## 1. 호스트 설정과 k3s

저장소 루트에서 한다. sudo가 필요한 단계는 파이프에 넣지 않는다. 한 단계라도 실패하면 다음으로 가지 않는다.

```bash
host/preflight.sh --cluster <이름> --before
sudo host/install.sh --cluster <이름> --host-config
host/preflight.sh --cluster <이름> --after
sudo host/install.sh --cluster <이름> --k3s
host/verify.sh --cluster <이름>
```

- `--before`: 노드 IP와 인터페이스, k3s 잔여 경로(`/var/lib/rancher/k3s`, `/var/lib/rancher/k3s-storage`, `/etc/rancher/k3s`) 부재.
- `--host-config`: `host/etc/` drop-in 복사, 스왑 끄기, 타임존, `tailscale set --accept-dns=false`(`TAILNET_JOIN=true`일 때), resolv.conf, networkd drop-in 적용. **이때 클러스터 인터페이스가 약 2초 끊긴다.** 원격 세션이 잠깐 멈췄다 돌아오는 것이 정상이다.
- `--after`: 스왑 없음, 타임존, resolved 스텁 꺼짐, resolv.conf가 loopback·tailnet·자기 주소 아님, 링크가 DHCP DNS를 거부.
- `--k3s`: `host/versions.env`의 `INSTALL_K3S_VERSION` 고정 설치(채널 없음), `host/k3s-config.yaml`을 렌더해 `/etc/rancher/k3s/config.yaml`(0600)로 씀, `local-retain` StorageClass를 자동 배포 매니페스트로 둠, kubeconfig를 `~/.kube/<KUBE_CONTEXT>.yaml`(0600)로 씀.
- `verify`: 노드 Ready, k3s 버전, 라이브 node-args = 렌더한 config, serving cert SAN, `local-retain`.
- `--k3s`가 중간에 실패하면 `/etc/rancher/k3s`가 남아 `--before`가 막힌다. `--k3s`를 그대로 다시 실행하거나, `k3s-uninstall.sh`로 지우고 잔여 경로가 없는지 본 뒤 1부터 다시 한다.

이후 `kubectl`은 이 kubeconfig로 부른다.

```bash
export KUBECONFIG=~/.kube/<KUBE_CONTEXT>.yaml   # prod는 homelab, vm은 homelab-vm
kubectl config current-context
```

파괴적인 명령 전에는 `host/verify.sh --cluster <이름> --identity`로 context와 노드 이름이 맞는지 본다. VM 검증 기간에는 두 클러스터가 함께 있다.

운영자 기기에서 tailnet으로 쓰려면 이 파일을 복사하고 `server`를 `https://<MagicDNS 이름>:6443`으로 바꾼다. 그 이름은 k3s SAN에 들어 있다. 저장소와 Infisical에는 두지 않는다.

## 2. Argo CD 설치와 root

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts --field-manager=argocd-controller -k platform/argocd
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=300s
kubectl -n argocd rollout status sts/argocd-application-controller --timeout=300s
# (T09 뒤) ESO 부트스트랩 Secret. 아래 2.1
kubectl apply -f platform/root/root-<이름>.yaml
```

- **`--field-manager=argocd-controller`를 빼지 않는다.** 기본 manager(`kubectl`)로 깔면 모든 필드를 Argo CD와 함께 소유한다. 그러면 나중에 Git에서 뺀 필드가 라이브에 영구히 남는다. 설치 뒤에는 managedFields를 손으로 고쳐야 한다.
- root가 `argocd` Application까지 소유한다. 이후 Argo CD 변경은 PR → main이다. Argo CD는 공개 webhook 없이 main을 60초마다 본다(jitter 0).
- `admin`은 꺼져 있고 사람 계정은 `owner`다. `owner` 비밀번호는 T09가 ExternalSecret으로 넣는다. 그 전까지는 `kubectl`이나 `argocd --core`로만 다룬다.

### 2.1 ESO 부트스트랩 Secret (T09에서 생김)

root apply 전에 복구 자산의 값으로 한 번 넣는다. VM은 VM 준비 자산의 `eso-homelab-vm` 값이다. 값은 출력하지 않는다.

```bash
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-secrets create secret generic infisical-universal-auth \
  --from-literal=clientId="$ESO_CLIENT_ID" --from-literal=clientSecret="$ESO_CLIENT_SECRET"
```

평상시 사람이 손으로 넣는 Secret은 이것 하나다. T09가 이 단계를 확정하면 이 절을 고친다.

### 2.2 vm 분기의 추가 단계 (시나리오 13)

설계 C.3.3 "vm 분기의 추가 단계"를 이 순서로 한다.

1. 2.1 전에, 운영 클러스터의 ExternalSecret 키 목록과 `homelab-dev`의 키를 대조한다. 빠진 키가 0이어야 한다. 하나라도 빠지면 멈춘다. 값은 출력하지 않는다.
2. 2.1의 ESO 자격은 `eso-homelab-vm` 값이다.
3. root apply 전에, 복구 원본 R2 읽기 자격 Secret을 넣는다. 복구가 끝나면 지운다.
4. `root-vm.yaml`을 apply한다.

T11·T13이 이 절의 명령을 채운다.

## 3. 확인

```bash
host/verify.sh --cluster <이름>
kubectl -n argocd get applications            # argocd, namespaces, root-<이름> 모두 Synced·Healthy
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation} {.data.timeout\.reconciliation\.jitter}'   # 60s 0
resolvectl status | grep 'DNS Servers'        # 1.1.1.1 9.9.9.9
tailscale dns status | grep 'Tailscale DNS'   # Tailscale DNS: disabled. (TAILNET_JOIN=true일 때)
```

재부팅 뒤에도 같은 확인을 한다(시나리오 12). k3s는 enabled라 부팅 때 시작하고, Argo CD가 모든 Application을 다시 맞춘다.
