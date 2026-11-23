# NUC 커널 고정과 AppArmor 시그널 차단

운영 NUC는 2026-11-23부터 커널 `7.0.0-44`로 고정돼 있다. `7.0.0-42`와 `7.0.0-44`에서는 AppArmor가 컨테이너 안 시그널을 막아 Postgres가 멈춘다. containerd 기본 프로필의 덮개가 깔려 있으면 막히지 않는다.
이 문서는 증상 확인, 복구, 지금의 고정 상태, 고정을 옮기거나 푸는 절차다.

## 언제 쓰나

- Postgres가 `too many clients`(`53300`)를 내고 백엔드 슬롯이 전부 `authentication`에서 멈췄을 때. DB를 쓰는 앱은 기다리다 `CrashLoopBackOff`가 된다.
- 재부팅 뒤 DB가 이렇게 멈췄을 때. 대기 중이던 새 커널이 그 재부팅에서 처음 떴을 수 있다.
- 고정을 풀거나 다른 버전으로 옮길 때.

## 확인

```sh
uname -r
journalctl -k -b --no-pager | grep -c 'apparmor="DENIED" operation="signal".*comm="postgres"'
```

0이 아니면 이 문제다. 차단 줄은 `profile="cri-containerd.apparmor.d"`, `peer="cri-containerd.apparmor.d//&unconfined"`, `signal=urg` 또는 `signal=term`이다.

- **원인은 겹친 라벨이다.** 이 커널들에서 컨테이너 프로세스의 라벨이 `cri-containerd.apparmor.d//&unconfined`가 된다. containerd 기본 프로필은 `peer=cri-containerd.apparmor.d`만 허용하고, peer는 겹친 라벨 문자열 전체와 맞춰 보므로 같은 컨테이너 안 시그널이 거부된다. 라벨이 왜 겹치는지는 확인하지 못했다.
- **덮개 없이는 파드 재시작이 소용없다.** 새로 뜬 postmaster도 첫 시그널부터 막힌다.
- **`comm="manager"`의 `signal=urg` 차단만으로는 이 문제가 아니다.** `7.0.0-38`에서도 7일에 111건 있었고 운영에 영향이 없었다.

## 복구

**1. 덮개를 깐다.** 재부팅하지 않는다. `apparmor_parser -r`이 도는 파드의 규칙을 그 자리에서 바꾼다.

```sh
sudo host/install.sh --cluster prod --sandbox-profiles
```

덮개는 `host/sandbox-profiles/apparmor-default/cri-containerd.apparmor.d`이고, 기본값에 `peer=**cri-containerd.apparmor.d**`의 signal·ptrace 규칙 둘을 더한 것이다. containerd는 같은 이름이 커널에 이미 있으면 자기 기본값을 올리지 않는다. 깐 뒤 위 "확인"의 건수가 더 늘지 않는지 본다.

**2. 멈춘 Postgres를 깨운다.** 차단이 멈춰도 저절로 풀리지 않는다. 막혔던 깨우기 시그널은 다시 오지 않는다. 2026-11-23에는 덮개를 깐 뒤에도 새 연결이 계속 `authentication`에서 멈췄고, 파드 삭제는 종료 전 체크포인트에서 멈췄다(종료 유예 1800초).

```sh
kubectl -n database exec pg-1 -c postgres -- sh -c \
  'for p in /proc/[0-9]*; do tr "\0" " " <"$p/cmdline" 2>/dev/null | grep -q "^postgres" && kill -URG "${p#/proc/}"; done'
```

`SIGURG`는 Postgres가 래치를 깨울 때 쓰는 시그널이다. 깨울 일이 없는 프로세스는 그대로 다시 기다린다.

**3. 파드를 다시 띄운다.** `kubectl -n database delete pod pg-1` 뒤 `kubectl -n database get cluster pg`가 `Cluster in healthy state`인지 본다.

**순서의 한계:** 2026-11-23에는 삭제를 먼저 요청했고, 멈춘 연결 100개에 `SIGTERM`을 보낸 뒤(슬롯은 비었지만 새 연결이 다시 멈췄다) `SIGURG`를 보내자 바로 정상 종료하고 새 파드가 떴다. 삭제 없이 `SIGURG`만으로 복귀하는지는 재지 않았다.

## 실측

| 부팅 (Asia/Seoul) | 커널 | 길이 | `comm="postgres"` 시그널 차단 |
|---|---|---|---|
| 10-30 10:04 ~ 11-06 14:38 | `7.0.0-38` | 7일 | 0건 |
| 11-06 14:40 ~ 15:03 | `7.0.0-42` | 23분 | 959건(`urg` 807, `term` 152) |
| 11-06 15:03 ~ 11-09 22:48 | `7.0.0-38` | 3일 | 0건 |
| 11-09 22:50 ~ 11-23 10:04 | `7.0.0-38` | 13일 | 0건 |
| 11-23 10:05 ~ 10:15 | `7.0.0-44`, 덮개 없음 | 10분 | 362건(`urg` 213, `term` 149) |
| 11-23 10:15 ~ | `7.0.0-44`, 덮개 있음 | 덮개 뒤 | 0건 |

**추론의 한계:** 커널 변경이 원인이라는 것은 이 전후 차이에서 나온 추론이다. 공개된 같은 결함 보고는 찾지 못했다. `7.0.0-39`~`7.0.0-41`과 `7.0.0-43`은 재지 않았다.

`7.0.0-42`는 11-04에 자동 설치돼 재부팅을 기다리고 있었고, 11-06 14:38 크래시로 처음 떴다. 같은 부팅에서 Postgres는 redo를 바로 끝내고도 ready까지 정확히 5분 걸렸다(`checkpoint_timeout`과 같다). 체크포인터를 깨우는 시그널이 막힌 탓으로 추정한다.

`7.0.0-44`는 CVE-2026-98432(IPv4 TCP use-after-free, Ubuntu 26.04는 `7.0.0-43.43`에서 수정) 때문에 올렸다. 11-23 10:15:33에 덮개를 올렸고 10:25에 Postgres가 복귀했다.

## 지금의 고정 상태

`/etc/default/grub.d/99-homelab-kernel.cfg`:

```sh
GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 7.0.0-44-generic"
```

`linux-image-7.0.0-38-generic`, `linux-modules-7.0.0-38-generic`, `linux-main-modules-zfs-7.0.0-38-generic`은 `apt-mark manual`로 남아 있다. `7.0.0-44`는 `linux-image-generic`이 지금 가리키는 버전이다.

**`host/install.sh`는 이 고정을 관리하지 않는다.** 호스트 OS를 다시 설치하면 이 파일부터 다시 판단한다. 덮개는 `--sandbox-profiles`가 깔고 `host/verify.sh`가 파일 해시와 enforce 적재를 본다.

**대가와 한계:**

- **보안 패치 지연:** 자동 업그레이드가 새 커널을 설치해도 고정을 옮기기 전에는 `7.0.0-44`로 부팅한다.
- **`7.0.0-38`로 되돌리지 않는다:** CVE-2026-98432에 취약하다. 또 2026-11-06 14:38과 11-09 22:48에 부하 중 크래시했다(`list_del corruption`, `folio_lruvec_lock_irqsave` GPF). 원인은 확정되지 않았다. 덤프는 `/var/crash/202611061439`, `/var/crash/202611092248`에 있다. `7.0.0-44`에서 같은 크래시가 나는지는 아직 모르므로 전체 시험·변이·podman을 여러 작업자가 동시에 돌리지 않는다.
- **덮개를 깐 뒤의 재부팅은 아직 없었다:** 재부팅 없이 본 것은 셋이다. `apparmor_parser -N /etc/apparmor.d`가 `cri-containerd.apparmor.d`를 올릴 이름으로 낸다. 2026-11-23 부팅에서 `apparmor.service`는 10:05:04에 끝났고 k3s는 10:05:08에 시작했다(containerd가 기본값을 올린 것은 10:05:13). 덮개를 올린 뒤 기본 프로필로 뜬 파드(`pg-1` 10:25)에서 containerd는 이 이름을 다시 올리지 않았다. 다음 재부팅에서 위 "확인"으로 본다.

## 고정을 옮기거나 풀기

사람이 승인한 뒤 한다. 재부팅으로 DB와 앱이 끊기고, 새 커널에 같은 문제가 있으면 DB가 멈춘 채로 복구할 때까지 간다.

1. `host/verify.sh --cluster prod`로 덮개가 Git과 같고 enforce로 올라 있는지 본다.
2. 올릴 버전이 부팅 메뉴에 있는지 본다(`sudo grep -c "Linux <버전>-generic" /boot/grub/grub.cfg`).
3. 고정 파일의 버전을 고치고 `sudo update-grub`, `sudo systemctl reboot`.
4. 부팅 뒤 위 "확인" 명령을 돌린다. 덮개가 없던 `7.0.0-42`·`7.0.0-44`에서는 DB가 뜨자마자 쌓였으니 DB가 뜬 뒤 10분 동안 본다.
5. `kubectl -n database get pod pg-1`, `kubectl get pods -A`, `kubectl get applications -A`로 복귀를 본다.
6. **차단이 있으면** 위 "복구"를 한다. 차단 줄의 `profile=`이 `cri-containerd.apparmor.d`가 아니면 그 프로필에 같은 규칙이 없는 것이다(`host/sandbox-profiles/apparmor/`). 복구되지 않을 때만 고정 파일을 이전 버전으로 되돌리고 재부팅한다. SSH는 그 상태에서도 된다.
7. **차단이 0건이고 며칠 무사하면** 고정 파일을 지우고 `sudo update-grub`, `apt-mark auto`로 옛 패키지 표시를 되돌린다.
8. 시각과 결과를 승인 기록(approvals.md)에 남긴다.
