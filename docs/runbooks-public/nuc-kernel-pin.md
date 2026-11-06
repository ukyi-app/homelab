# NUC 커널 고정

운영 NUC는 2026-11-06부터 커널 `7.0.0-38`로 고정돼 있다. `7.0.0-42`에서 AppArmor가 컨테이너 시그널을 막아 Postgres가 멈췄기 때문이다.
이 문서는 증상 확인, 지금의 고정 상태, 고정을 옮기거나 푸는 절차다.

## 언제 쓰나

- Postgres가 `too many clients`(`53300`)를 내고 백엔드 슬롯이 전부 `authentication`에서 멈췄을 때. 봇은 DB를 기다리다 `CrashLoopBackOff`가 된다.
- 재부팅 뒤 DB가 이렇게 멈췄을 때. 대기 중이던 새 커널이 그 재부팅에서 처음 떴을 수 있다.
- 고정을 풀거나 다른 버전으로 옮길 때.

## 확인

```sh
uname -r
journalctl -k -b --no-pager | grep -c 'apparmor="DENIED" operation="signal".*comm="postgres"'
```

0이 아니면 이 문제다. 차단 줄은 `profile="cri-containerd.apparmor.d"`, `peer="cri-containerd.apparmor.d//&unconfined"`, `signal=urg` 또는 `signal=term`이다.

- **파드 재시작은 소용없다.** 새로 뜬 postmaster도 첫 시그널부터 막혔다. 커널을 바꿔 재부팅해야 한다.
- **`comm="manager"`의 `signal=urg` 차단만으로는 이 문제가 아니다.** `7.0.0-38`에서도 7일에 111건 있었고 운영에 영향이 없었다.

## 2026-11-06 실측

| 부팅 (Asia/Seoul) | 커널 | 길이 | `comm="postgres"` 시그널 차단 |
|---|---|---|---|
| 10-30 10:04 ~ 11-06 14:38 | `7.0.0-38` | 7일 | 0건 |
| 11-06 14:40 ~ 15:03 | `7.0.0-42` | 23분 | 959건(`urg` 807, `term` 152) |
| 11-06 15:03 ~ | `7.0.0-38` | 고정 뒤 | 0건 |

**추론의 한계:** 커널 변경이 원인이라는 것은 이 전후 차이에서 나온 추론이다. 공개된 같은 결함 보고는 찾지 못했다.

`7.0.0-42`는 11-04에 자동 설치돼 재부팅을 기다리고 있었고, 14:38 크래시로 처음 떴다. 같은 부팅에서 Postgres는 redo를 바로 끝내고도 ready까지 정확히 5분 걸렸다(`checkpoint_timeout`과 같다). 체크포인터를 깨우는 시그널이 막힌 탓으로 추정한다.

## 지금의 고정 상태

`/etc/default/grub.d/99-homelab-kernel.cfg`:

```sh
GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 7.0.0-38-generic"
```

`linux-image-7.0.0-38-generic`, `linux-modules-7.0.0-38-generic`, `linux-main-modules-zfs-7.0.0-38-generic`은 `apt-mark manual`이다. 자동 제거로 고정한 커널이 사라지지 않게 한다.

**`host/install.sh`는 이 고정을 관리하지 않는다.** 호스트 OS를 다시 설치하면 이 파일부터 다시 판단한다.

**대가 둘:**

- **보안 패치 지연:** 자동 업그레이드가 새 커널을 설치해도 고정을 옮기기 전에는 `7.0.0-38`로 부팅한다.
- **크래시 재발 가능:** `7.0.0-38`은 2026-11-06 14:38 `list_del corruption`과 `folio_lruvec_lock_irqsave` GPF로 크래시했다. 원인은 확정되지 않았다. 전체 시험·변이·podman을 여러 작업자가 동시에 돌리던 중이었으니 NUC에서 그런 부하를 겹치지 않는다. 덤프는 `/var/crash/202611061439`에 있다.

## 고정을 옮기거나 풀기

사람이 승인한 뒤 한다. 재부팅으로 DB와 봇이 끊기고, 새 커널에 같은 문제가 있으면 DB가 멈춘 채로 되돌릴 때까지 간다.

1. 올릴 버전이 부팅 메뉴에 있는지 본다(`sudo grep -c "Linux <버전>-generic" /boot/grub/grub.cfg`).
2. 고정 파일의 버전을 고치고 `sudo update-grub`, `sudo systemctl reboot`.
3. 부팅 뒤 위 "확인" 명령을 돌린다. `7.0.0-42`에서는 DB가 뜨자마자 쌓였으니 DB가 뜬 뒤 10분 동안 본다.
4. `kubectl -n database get pod pg-1`, `kubectl -n app-homelab-bot get pods`, `kubectl get applications -A`로 복귀를 본다.
5. **차단이 있으면** 고정 파일을 `7.0.0-38`로 되돌리고 `sudo update-grub`, `sudo systemctl reboot`. SSH는 그 상태에서도 된다.
6. **차단이 0건이고 며칠 무사하면** 고정 파일을 지우고 `sudo update-grub`, `apt-mark auto`로 옛 패키지 표시를 되돌린다.
7. 시각과 결과를 승인 기록(approvals.md)에 남긴다.
