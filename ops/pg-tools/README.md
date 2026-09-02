# pg-tools

> **빌드-전용 ops 이미지** (`ops/`, `deploy/` 없음) — ArgoCD가 워크로드로 싱크하지 않는다(배포 앱은 `apps/`).
> CronJob 등이 GHCR 이미지로만 참조한다. 경계는 [`../../apps/README.md`](../../apps/README.md) 참고.

운영(ops) 이미지: `kubectl` + `psql` (postgresql-client-18) + `rclone` + `curl`.

CI(Task 6.15 matrix)가 `ghcr.io/ukyi-app/pg-tools:18-rclone`과 `:sha-<gitsha>`로
게시한다. Milestone 4의 restore-drill CronJob, `pg_dump → rclone → R2` 헤지, 그리고
캐시(Valkey) 백업 CronJob(`platform/cache/prod/backup-cronjob.yaml` — kubectl discover +
rclone R2 업로드)이 이 이미지를 참조한다(M4의 LIVE drill 수용 기준은 이 이미지의 존재를 전제).

## 버전을 올릴 때 — 그리고 왜 체크섬을 하드코딩하지 않는가

이미지 안에서 `curl`로 받는 두 바이너리는 **버전이 핀돼 있다**(`ARG KUBECTL_VERSION`·`ARG RCLONE_VERSION`).
부동 채널(`release/stable`·`rclone-current`)이던 옛 형태는 같은 커밋의 두 빌드가 다른 바이너리를 담았고,
그 재빌드 하나가 restore-drill을 두 번(8/22·8/25) 결정적으로 죽였다 —
`platform/cnpg/prod/restore-drill-script.sh`의 헤더가 그 사고의 기록이다.

- `KUBECTL_VERSION`: 독립 소유자를 **주지 않는다**. `infra/k3s-bootstrap/versions.env`의 `K3S_VERSION`에서
  `+k3sN`을 뗀 값과 같아야 하고, `tools/tests/test_pg-tools.bats`가 그 등식을 강제한다. k3s bump PR이
  이 줄을 안 따라오면 그 PR이 red가 된다 — 서버와의 ±1 minor skew가 구조적으로 열리지 않는다.
- `RCLONE_VERSION`: `renovate.json`의 customManager(github-releases `rclone/rclone`)가 소유한다.
  `custom.regex`는 automerge 금지 규칙에 걸려 있어 항상 리뷰 후 머지다.

체크섬(`sha256sum -c`)은 **의도적으로 넣지 않았다**. `setup-toolchain`이 SHA를 리터럴로 박아 얻는 성질은
"미러/계정 침해 시 변조 차단"인데, 그건 **git에 리뷰된 채 시간적으로 분리된** 해시에서만 나온다.
여기서 손이 닿는 형태 — 같은 오리진(`dl.k8s.io`·`downloads.rclone.org`)의 `.sha256`/`SHA256SUMS`를 받아
대조하기 — 는 바이너리를 바꿀 수 있는 주체가 체크섬 파일도 바꾸므로 그 위협에 대한 증분이 0이고,
남는 이득은 TLS가 이미 덮는 전송 손상뿐이다. 멀티아치라 리터럴 SHA는 바이너리당 2개(총 4개)를 손으로
유지해야 하는데, 그 비용은 이 이미지가 지는 위험보다 크다. 실제 하중은 보안이 아니라 **결정성**이었고,
그건 위의 버전 핀 두 줄이 닫는다.
(cf. `ops/skopeo/README.md`가 정당화하는 것은 apk/apt 배포판 패키지의 무핀이지 원격 `curl` 바이너리가 아니다 —
그 비대칭이 이 문단이 없던 이유였다.)
