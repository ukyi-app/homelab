# T11 데이터 서비스

- 단계: P2 플랫폼 구축 (재분해 T05 2026-10-18)
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: T08a, T09, T10
  - T08a: cert-manager와 R2 백업 버킷 `homelab-backups`(lifecycle 포함).
  - T09: 플랫폼 시크릿 전달(ESO, Infisical `homelab`).
  - T10: 배포 흐름, 공유 차트의 연결 배선, 손으로 등록한 시험 앱 `homelab-probe`.
  - 관측(T08b)은 선행이 아니다. T11 완료는 T12(CLI)를 기다리지 않는다(설계 E.2).
- 선행 결정: D-05 (확정(사용자 2026-10-18, T05): 공유 PostgreSQL 인스턴스 + 앱별 DB·역할), D-06 (확정(사용자 2026-10-18, T05): 영속 Valkey는 AOF everysec + 하루 1회 RDB를 R2로), D-12 (확정(사용자 2026-10-18, T05): `/mnt/bulk`는 비우고 쓰지 않음), D-22 (확정(사용자 2026-10-18, T05): 앱 DB 마이그레이션은 Sync 단계 hook Job), 백업 보존 (확정(사용자 2026-10-18, T05): PostgreSQL·Valkey 14일, R2 버킷 `homelab-backups` 하나)
- 연결 AC: AC-P9
- 수행: 에이전트 + 사람 (R2 백업 버킷 전용 토큰 발급, 시험 비밀번호를 Infisical에 직접 생성, 손 PR 검토·병합, 복원 절차 실행)

## 목표

앱에 PostgreSQL과 Valkey를 붙이는 흐름을 만들고, 데이터 수명을 앱 수명과 분리한다.

## 범위

- 만들 것(설계 E6): `platform/cnpg`(operator, Barman Cloud Plugin, ObjectStore, Cluster `pg`, ScheduledBackup, NetworkPolicy), `platform/root/values-prod.yaml`의 CNPG 키(버킷, serverName. Cluster `pg`가 이 값으로 렌더된다), `platform/charts/app-data`와 태그 `data-chart-v1.0.0`, ApplicationSet `data`, 영속 Valkey 백업 CronJob 템플릿, `docs/runbooks-public/restore.md`(설계 C.5.6, C.5.7, C.6.4의 빈 NUC 복구 순서와 복구·정리 PR).
- CNPG 설치와 공유 인스턴스 (D-05, 확정(사용자 2026-10-18, T05)). DB·역할은 CNPG 선언형 기능으로 관리한다. 버전과 리소스 모양은 설계 C.5.3.
  - 공유 Cluster `pg` 하나에 앱마다 `Database`·`DatabaseRole`을 둔다(봇 포함). 역할 이름은 앱 이름이고 DB owner다. owner를 앱끼리 공유하지 않는다.
  - 전용 Cluster는 설계 C.5.2의 조건 넷 중 하나라도 걸릴 때만 둔다: (1) 독립 PITR이나 빠른 복원이 필요하다, (2) 데이터가 10GB를 넘거나 쓰기가 많다, (3) 다른 PostgreSQL major나 확장이 필요하다, (4) 다른 보존 기간이 필요하다.
  - Cluster `pg`는 다른 플랫폼 구성 요소처럼 자동 동기화로 둔다. 빈 NUC 복구는 root apply 전 복구 PR → 복구 확인 → 정리 PR 순서다(설계 C.6.4). 복구 PR은 복구 원본(지금 Git의 serverName)을 넣고 serverName을 새 세대 `pg-<복구일>`로 바꾼다. 정리 PR은 복구 원본을 지워 렌더 결과를 `initdb`로 되돌린다. 수동 sync 대안(자동 동기화를 끈 별도 Application)은 고르지 않았다. 이 순서를 `restore.md`에 적는다.
- R2 백업과 앱 단위 복원 절차. 보존은 확정(사용자 2026-10-18, T05)대로 PostgreSQL·Valkey 14일, 운영 버킷은 `homelab-backups` 하나다(설계 C.3.8).
  - PostgreSQL: Barman Cloud Plugin의 base backup + WAL 연속 아카이브. `homelab-backups`의 `pg/` prefix, serverName `pg-<YYYYMMDD>`. 매일 03:00 KST(ScheduledBackup은 UTC라 `0 0 18 * * *`), 14일(ObjectStore `retentionPolicy`).
  - 영속 Valkey: 같은 버킷 `valkey/<app>/`, 매일 03:30 KST, 14일(R2 lifecycle, prefix `valkey/` 명시. `prefix = ""`는 버킷 전체 만료다).
  - 백업 CronJob 이름에 `valkey-backup`을 넣는다. T08b의 경보 ValkeyBackupStale이 `kube_cronjob_status_last_successful_time{cronjob=~".*valkey-backup.*"}`로 본다(`platform/observability/stack/vmalert/rules/platform.yaml`). 다른 이름을 쓰면 같은 PR에서 룰과 그 단위 시험을 고친다. 아니면 백업이 멈춰도 경보가 울리지 않는다.
  - 앱 하나 복원은 임시 클러스터 PITR → 그 DB만 덤프·복원이다(설계 C.5.7). 복원 리소스(임시 Cluster `pg-restore-*`, 덤프·복원 Job, Valkey 복원 Job)는 GitOps 밖의 일회성 객체이고 라벨 `homelab.ukyi.app/restore=<실행 id>`를 붙인다.
  - 복원 드릴은 자동화하지 않는다. 시나리오 10이 첫 실행이다(설계 C.3.8).
- Valkey 캐시용·영속용 기본값 (D-06, 확정(사용자 2026-10-18, T05)). 값은 설계 C.5.6 표.
  - 캐시: PVC 없음, `allkeys-lru`. 앱과 함께 생기고 사라진다.
  - 영속: AOF `everysec` + 하루 1회 RDB를 R2로, 14일 보존. 재시작 손실 약 1초, 디스크 유실 최대 24시간. 큐 유실이 치명적이면 그 데이터는 PostgreSQL에 둔다.
  - 남는 위험: 영속 Valkey가 있는 앱 ns에 R2 백업 토큰이 간다(설계 C.3.8, F D-06).
- 마이그레이션 (D-22, 확정(사용자 2026-10-18, T05)). 설계 C.5.4.
  - Argo CD Sync 단계 hook Job(`hook-delete-policy: BeforeHookCreation`). wave 순서는 ExternalSecret(0) → 마이그레이션 Job(1) → Deployment(2). 접속은 `pg-rw.database.svc` 직결이다.
  - 앱은 시작 때 스키마 버전만 확인한다. expand/contract는 필수다.
  - 이미 self-migration인 앱(`migration.command` 없음)은 replicas 1에서 선택으로 허용한다.
  - Job은 T10의 공유 차트가 `migration.command`로 렌더한다. 이 티켓은 시나리오 2에서 Job 성공과, 데이터 Application이 늦을 때 Job이 한 번 실패한 뒤 retry로 수렴하는지 확인한다.
  - hook은 selective sync에서 돌지 않는다. 운영 절차에서 부분 sync를 쓰지 않는다.
- 자격증명 원본은 Infisical, 사용 위치별 Secret은 자동 전달.
- 앱 삭제와 데이터 폐기의 분리(설계 C.5.5).
- 데이터 저장 위치. 입력은 디스크 배치다: 루트 LV 913G, 별도 1.8T 디스크 `/mnt/bulk`. `/mnt/bulk`는 T06에서 비우고 fstab 항목을 지운 뒤 쓰지 않는다(D-12 확정(사용자 2026-10-18, T05), 명세 §4.5).

## 필요한 자격

- R2 백업 버킷 전용 Object Read & Write 토큰: 이 티켓의 사람 작업. 대시보드에서 발급해 Infisical `homelab`의 `/platform/backup`에 넣는다. CNPG(`database` ns)와 영속 Valkey가 있는 앱 ns에만 ESO로 전달한다(설계 C.3.8).
- R2 버킷 `homelab-backups`와 lifecycle: 준비 T08a(Terraform `infra/cloudflare`).
- ESO와 ClusterSecretStore, Infisical `homelab`/`prod`: 준비 T09.
- `homelab-probe`의 DB·Valkey 비밀번호: CLI 대신 사람이 Infisical `homelab`/`prod`의 `/apps/homelab-probe/postgres/PASSWORD`·`/apps/homelab-probe/valkey/PASSWORD`에 직접 만든다. 값은 화면·셸 기록에 남기지 않는다.
- 복원 절차에는 사람 kubeconfig의 `database` ns 쓰기 권한(`clusters.postgresql.cnpg.io`·`jobs` create·get·delete, `persistentvolumeclaims` get·delete)이 필요하다. 봇 읽기 계정과 CI에는 없다(설계 C.5.7).

## 완료 조건

- 아래 CLI 없는 동등 절차로 시나리오 2, 3, 4, 8, 9, 10을 통과한다.
- 첫 base backup이 `completed`다.
- R2에서 새 클러스터로 복원이 성공한다.
- 어느 항목도 T12의 CLI를 쓰지 않는다.

## 검증

설계 E6 표 아래 "CLI 없는 동등 절차"를 따른다. T10의 `homelab-probe`를 이어 쓰고, G의 확인 명령을 `homelab-probe`로 바꾼다. 앱 확인은 port-forward로 `/healthz/db`·`/healthz/cache`를 부른다.

- 테스트 앱에 DB와 캐시를 붙이고 접속을 확인한다.
  - 시나리오 2: 손 PR(`data/homelab-probe/values.yaml`에 `postgres.enabled: true`, `apps/homelab-probe/values.yaml`에 `uses.postgres: true`) 병합 → G의 kubectl·`psql` 확인.
  - 시나리오 3: 손 PR(`apps/homelab-probe/values.yaml`에 `cache:`와 `uses.valkey: true`) 병합 → G의 확인.
  - 시나리오 4: G 명령은 CLI를 쓰지 않는다. 복원은 `restore.md`의 C.5.6 절차를 사람이 따른다.
- 비밀번호 회전 뒤 실제 앱 접속까지 확인한다.
  - 시나리오 8: `homelab db rotate` 대신 `rotate.md`의 DB 비밀번호 순서(설계 C.6.5)를 사람이 따른다 → G의 확인.
- 앱을 지운 뒤 DB가 남아 있는지 확인한다.
  - 시나리오 9: `homelab app remove` 대신 `apps/homelab-probe/`를 지우는 손 PR → G의 kubectl·`psql` 확인. `homelab data list` 대신 `kubectl -n database get database,databaserole`과 `kubectl -n app-homelab-probe get pvc`. 재등록은 그 PR의 revert PR → 표식 행 같음.
- 공유 인스턴스에서 한 앱의 DB만 복원한다.
  - 시나리오 10: 두 번째 DB는 손 PR `data/homelab-probe2/values.yaml`(DB만). `homelab db restore` 대신 `restore.md`의 C.5.7 단계를 사람이 `kubectl`로 따른다(복원 리소스는 GitOps 밖) → G의 확인.
- `kubectl -n database get backups`로 첫 base backup `completed`를 본다.
- 복원 뒤 `kubectl -n database get cluster,job,pvc -l homelab.ukyi.app/restore=<실행 id>` → 0개.
- 이 단계에서 확인할 미검증 항목: U15(`DatabaseRole` 필드와 status), U16(Barman Cloud Plugin v0.15.1 + R2 새 클러스터 복원), U17(비밀번호 변경 뒤 열린 연결 유지), U18(Valkey RDB 복원 절차), U26(복원 시험의 임시 Cluster에서 `bootstrap`을 `initdb`로 바꾸는 변경이 거부되지 않는지). 결과가 틀리면 설계 부록 1의 "틀리면" 열대로 간다.

## 되돌리는 방법

설계 E6 "되돌리는 방법"을 따른다.

- revert PR로 되돌린다. 데이터 리소스(`Database`, `DatabaseRole`, Valkey PVC, `Cluster`, `ObjectStore`)는 보호 주석(`Prune=false,Delete=false`)이 있어 revert로 지워지지 않는다.
- 클러스터를 다시 만들면 serverName을 새 값으로 바꾼다. 같은 serverName에 다시 쓰면 "Expected empty archive" 오류로 멈춘다(설계 C.6.4).
- 실패한 복원 시험은 임시 Cluster·PVC 삭제를 확인한다(위 라벨로 0개).
