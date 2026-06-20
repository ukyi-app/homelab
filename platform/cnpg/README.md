# cnpg

**역할** — CloudNativePG 데이터 계층. `platform/cnpg/prod`은 PostgreSQL Cluster(NS `database`)이고, operator/플러그인은 별도 manifest로 분리된다. R2 백업(barman-cloud plugin).

**싱크 Application · sync-wave** — 전부 `platform/argocd/root/apps/`의 **수동 Application**(appset에서 `platform/cnpg/*` 제외): `cert-manager` **-3** → `cnpg-operator` **-2** + `cnpg-barman-plugin` **-2** → `cnpg-data` Cluster **-1**. CNPG-Ready 게이트(cnpg-data Healthy)는 차트 `wait-for-db` initContainer가 앱별로 강제.

**라이브 디버그** — `argo` 스킬(sync/health). 런북 `docs/runbooks/restore.md`(복구 R1·DR 핵심), `docs/runbooks/storage-verify.md`.

**함정 SSOT** — docs/traps-detail.md: `chart:` 사용 시 repoURL=Helm 레지스트리·targetRevision=차트 semver, barman ObjectStore `spec.env` SSA 거부, 기본 pg_hba는 replication을 streaming_replica(cert)만 허용(pg_basebackup엔 postgres 항목 추가), barman-cloud plugin이 in-tree `cnpg_collector_*` 백업 메트릭 deprecate(→`barman_cloud_*`/pg_stat_archiver, WAL-size collector는 생존).
