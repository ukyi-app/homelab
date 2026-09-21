# 로그인 k3s 상태

`00-ukyi`는 NUC의 기존 MOTD 화면을 보존한 소스이고, `k3s-status.py`가 Kubernetes JSON을 집계한다.
의존성은 호스트의 Bash, Python 3 표준 라이브러리, k3s다. 고양이 아트와 기존
`motd-refresh.timer`는 `/usr/local/share/ukyi-motd/` 및 systemd에 설치된 것을 사용한다.

## 판정

- `node R/N`: Ready 노드 수/전체 노드 수.
- `P ready`: Running이면서 Ready이고 삭제 중이 아닌 파드 수.
- `B bad`: 완료·복구 기록을 제외한 나머지 파드 수. Pending, Running/NotReady, 미복구 Failed 포함.
- `Jobs F recovered failures`: 실패 파드의 Job→CronJob 소유 UID가 모두 일치하고, 실패 종료 후
  해당 CronJob의 후속 성공이 확인된 기록 수. 미래 성공 시각은 증거로 인정하지 않는다.
- API 오류·부분 조회 실패·잘못된 JSON·노드 부재: `k3s unreachable`, `Jobs unknown`.

실패 Job/Pod는 삭제하지 않는다. `failedJobsHistoryLimit`과 `CronJobFlapping` 관측 창을 보존한다.
이 화면은 파드 상태 요약이며 서비스 요청의 종단 검증은 아니다.

## 읽기 전용 프리뷰

레포 루트에서 실행한다. worktree이면 `K3S_KUBECONFIG`는 canonical 체크아웃의 파일을 지정한다.
CPU 스냅샷만 임시 디렉토리에 쓰므로 운영 MOTD와 상태 파일을 수정하지 않는다.

```bash
preview_dir=$(mktemp -d)
K3S_KUBECONFIG=/home/ukyi/workspace/homelab/infra/k3s-bootstrap/kubeconfig \
MOTD_K3S_HELPER="$PWD/infra/k3s-bootstrap/motd/k3s-status.py" \
CPU_STATE="$preview_dir/cpu" bash infra/k3s-bootstrap/motd/00-ukyi
```

## 호스트 반영

리뷰된 체크아웃에서 아래 두 파일만 설치한다. 전체 `host-config.sh --apply`는 필요 없다.
기존 대상이 다른 작업으로 변경되지 않았는지 먼저 대조하고, 기존 MOTD를 백업한다.

```bash
backup_path="/usr/local/share/ukyi-motd/00-ukyi.before-k3s-health.$(date +%Y%m%d%H%M%S)"
sudo cp -p /etc/update-motd.d/00-ukyi "$backup_path"
sudo install -m 0644 infra/k3s-bootstrap/motd/k3s-status.py /usr/local/share/ukyi-motd/k3s-status.py
sudo install -m 0755 infra/k3s-bootstrap/motd/00-ukyi /etc/update-motd.d/00-ukyi
sudo systemctl start motd-refresh.service
```

이후 `/run/motd.dynamic` 또는 새 SSH 로그인에서 표시를 확인한다. 되돌릴 때는 위
`backup_path` 파일을 `/etc/update-motd.d/00-ukyi`로 복원하고 같은 refresh 서비스를 실행한다.
클러스터 변경·k3s 재시작은 없다.
